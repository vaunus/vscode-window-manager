"use strict";

// VSCode Window Manager: registers this VSCode window for the bar app.
// It writes windows/<id>.json with this window's folders and title bar
// colors. The bar reads it. The bar writes requests/<id>.json to show a
// Claude tab in this window.

const vscode = require("vscode");
const fs = require("fs");
const path = require("path");

const state = require("./lib/state");
const store = require("./lib/store");
const theme = require("./lib/theme");
const modal = require("./lib/modal");
const git = require("./lib/git");
const activity = require("./lib/activity");

// Workspace state key: when something last changed in the window.
const ACTIVE_AT_KEY = "activeAt";
// Write the window file at most this often for activity (edits).
const ACTIVITY_WRITE_MS = 5000;
// No activity for this long after the window opens. See ctx.quietUntil.
const STARTUP_QUIET_MS = 10000;
// The Claude extension's command to show a session. With the id of a
// session that has a tab, it brings that tab to the front. The
// vscode://anthropic.claude-code/open?session=<id> link runs it too.
const CLAUDE_SHOW_SESSION = "claude-vscode.primaryEditor.open";

// Settings that can change the title bar color.
const COLOR_SETTINGS = [
  "workbench.colorTheme",
  "workbench.colorCustomizations",
  "workbench.preferredLightColorTheme",
  "workbench.preferredDarkColorTheme",
  "workbench.preferredHighContrastColorTheme",
  "workbench.preferredHighContrastLightColorTheme",
  "window.autoDetectColorScheme",
  "window.titleBarStyle",
];

// Runtime state for this window. Null when not active.
let ctx = null;

function log(message) {
  if (ctx && ctx.output)
    ctx.output.appendLine(`${new Date().toISOString()} ${message}`);
}

// One id per window. The pid keeps it unique even if sessionId repeats.
function makeWindowId() {
  const sid = String(vscode.env.sessionId || "").replace(/[^A-Za-z0-9_-]/g, "");
  return `${process.pid}-${sid || "window"}`.slice(0, 200);
}

function fileFolders() {
  return (vscode.workspace.workspaceFolders || [])
    .filter((f) => f.uri.scheme === "file")
    .map((f) => f.uri.fsPath);
}

function workspaceFilePath() {
  const wf = vscode.workspace.workspaceFile;
  return wf && wf.scheme === "file" ? wf.fsPath : null;
}

// This window's title bar colors, { active, inactive } as "#RRGGBB", or null.
function titleBarColors() {
  try {
    const cfg = vscode.workspace.getConfiguration();
    return theme.titleBarColors({
      extensions: vscode.extensions.all,
      kind: vscode.window.activeColorTheme.kind,
      settings: {
        colorTheme: cfg.get("workbench.colorTheme"),
        colorCustomizations: cfg.get("workbench.colorCustomizations"),
        preferredLightColorTheme: cfg.get("workbench.preferredLightColorTheme"),
        preferredDarkColorTheme: cfg.get("workbench.preferredDarkColorTheme"),
        preferredHighContrastColorTheme: cfg.get(
          "workbench.preferredHighContrastColorTheme",
        ),
        preferredHighContrastLightColorTheme: cfg.get(
          "workbench.preferredHighContrastLightColorTheme",
        ),
        autoDetectColorScheme: cfg.get("window.autoDetectColorScheme"),
        titleBarStyle: cfg.get("window.titleBarStyle"),
      },
    });
  } catch (err) {
    log(`Could not read the title bar colors: ${err.message}`);
    return null;
  }
}

// Work out the title bar colors again (the theme or a color setting
// changed), and write the window file. Kept in ctx.colors, so a modal
// opening or closing does not read the theme files again.
function refreshColors() {
  if (!ctx) return;
  ctx.colors = titleBarColors();
  writeOwnWindow();
}

// The editor groups, for the modal guess in lib/modal.js.
function tabGroups() {
  return vscode.window.tabGroups.all.map((g) => ({
    viewColumn: g.viewColumn,
    tabs: g.tabs.map((t) => ({
      label: t.label,
      known: t.input !== undefined,
      active: t.isActive,
    })),
  }));
}

// A VSCode modal (for example Settings) opened or closed: the title bar
// colors change, so write the window file again.
function updateModal() {
  if (!ctx) return;
  let open = false;
  try {
    open = modal.isModalOpen(tabGroups());
  } catch (err) {
    log(`Could not check for a modal: ${err.message}`);
  }
  if (open === ctx.modal) return;
  ctx.modal = open;
  writeOwnWindow();
}

// Git's status changed: write the window file if the count is new. New
// changed files or a new commit in a repository count as activity. A
// repository's first status does not: before it, git has not loaded the
// status yet (no HEAD), and the lists are empty.
function updateChanges() {
  if (!ctx || !ctx.git) return;
  const repos = ctx.git.repositories;
  let changed = false;
  for (const repo of repos) {
    if (!repo.state.HEAD) continue;
    const key = repo.rootUri.toString();
    const sig = git.changeSignature(repo);
    if (ctx.gitSignatures.has(key) && ctx.gitSignatures.get(key) !== sig) changed = true;
    ctx.gitSignatures.set(key, sig);
  }
  ctx.changedPaths = git.changedPaths(repos);
  if (changed) noteActivity();
  const count = git.countChanges(repos);
  if (count === ctx.changes) return;
  ctx.changes = count;
  writeOwnWindow();
}

// The git API gives a new object for a repository each time, so the
// repositories are kept by their root folder.
function watchRepo(repo) {
  const key = repo.rootUri.toString();
  if (!ctx || ctx.repos.has(key)) return;
  ctx.repos.set(key, repo.state.onDidChange(updateChanges));
  updateChanges();
}

function unwatchRepo(repo) {
  if (!ctx) return;
  const key = repo.rootUri.toString();
  const sub = ctx.repos.get(key);
  if (sub) sub.dispose();
  ctx.repos.delete(key);
  ctx.gitSignatures.delete(key);
  updateChanges();
}

// Count the uncommitted changes with VSCode's git extension, for the
// number after the branch in the bar. No count while git is off.
async function watchGit(context) {
  try {
    const ext = vscode.extensions.getExtension("vscode.git");
    if (!ext) return;
    const exports = ext.isActive ? ext.exports : await ext.activate();
    if (!ctx || !exports || !exports.enabled) return;
    ctx.git = exports.getAPI(1);
    // VSCode disposes these after deactivate(), when ctx is already null.
    const repos = ctx.repos;
    context.subscriptions.push(
      ctx.git.onDidOpenRepository(watchRepo),
      ctx.git.onDidCloseRepository(unwatchRepo),
      { dispose: () => repos.forEach((sub) => sub.dispose()) },
    );
    ctx.git.repositories.forEach(watchRepo);
    updateChanges();
  } catch (err) {
    log(`Could not watch git: ${err.message}`);
  }
}

// For the bar's auto sleep. The bar does not close a window by itself while
// it has unsaved files, or while something runs in a terminal or a task.
function hasUnsaved() {
  return (
    vscode.workspace.textDocuments.some((d) => d.isDirty) ||
    vscode.workspace.notebookDocuments.some((d) => d.isDirty) ||
    vscode.window.tabGroups.all.some((g) => g.tabs.some((t) => t.isDirty))
  );
}

// A terminal without shell integration counts as busy, because the
// extension cannot see its commands.
function isBusy() {
  return (
    vscode.tasks.taskExecutions.length > 0 ||
    ctx.running.size > 0 ||
    vscode.window.terminals.some((t) => !t.exitStatus && !t.shellIntegration)
  );
}

// For the bar's "working" with a terminal icon: a task, or a command that
// the extension sees in a terminal. Not Claude Code in a terminal, because
// the bar shows Claude's own status.
function isRunning() {
  return (
    vscode.tasks.taskExecutions.length > 0 ||
    [...ctx.running.values()].some((r) => !activity.isClaudeCommand(r.command))
  );
}

function updateSleepInfo() {
  if (!ctx) return;
  const unsaved = hasUnsaved();
  const busy = isBusy();
  const running = isRunning();
  if (unsaved === ctx.unsaved && busy === ctx.busy && running === ctx.runningNow) return;
  ctx.unsaved = unsaved;
  ctx.busy = busy;
  ctx.runningNow = running;
  writeOwnWindow();
}

// Something changed in the window: an edit, a save, a file, git, or a
// command. The bar shows "working" for a short while, then "idle" and how
// long. Edits come with each key press, so the window file and VSCode's
// saved copy are written at most once per ACTIVITY_WRITE_MS.
function noteActivity() {
  if (!ctx || Date.now() < ctx.quietUntil) return;
  ctx.activeAt = new Date().toISOString();
  if (ctx.activityTimer) return;
  const wait = Math.max(0, ctx.activityWrittenAt + ACTIVITY_WRITE_MS - Date.now());
  ctx.activityTimer = setTimeout(() => {
    if (!ctx) return;
    ctx.activityTimer = null;
    ctx.activityWrittenAt = Date.now();
    ctx.workspaceState.update(ACTIVE_AT_KEY, ctx.activeAt);
    writeOwnWindow();
  }, wait);
}

// Only changes to the text of files. Not output panels, and not a save,
// which changes only the dirty state.
function documentChanged(e) {
  const scheme = e.document.uri.scheme;
  if (e.contentChanges.length && (scheme === "file" || scheme === "untitled")) noteActivity();
  updateSleepInfo();
}

function documentSaved() {
  noteActivity();
  updateSleepInfo();
}

// A file changed on disk, by any tool. Only files with git changes count:
// git leaves out node_modules, build output and other ignored files. A file
// that had no changes before shows in git's next status, see updateChanges.
function fileChanged(uri) {
  if (ctx && ctx.changedPaths.has(uri.fsPath)) noteActivity();
}

function taskChanged() {
  noteActivity();
  updateSleepInfo();
}

function commandStarted(e) {
  if (!ctx) return;
  const command = e.execution.commandLine ? e.execution.commandLine.value : "";
  ctx.running.set(e.execution, { terminal: e.terminal, command });
  noteActivity();
  updateSleepInfo();
}

function commandEnded(e) {
  if (!ctx) return;
  ctx.running.delete(e.execution);
  noteActivity();
  updateSleepInfo();
}

// A closed terminal sends no end for its commands.
function terminalClosed(terminal) {
  if (!ctx) return;
  for (const [execution, r] of ctx.running) {
    if (r.terminal === terminal) ctx.running.delete(execution);
  }
  updateSleepInfo();
}

function tabsChanged() {
  updateModal();
  updateSleepInfo();
}

// True for an empty window: no folder and no workspace, for example a new
// window on the Welcome page.
function isEmptyWindow() {
  return (
    !(vscode.workspace.workspaceFolders || []).length &&
    !vscode.workspace.workspaceFile
  );
}

// This window's record. Null for a window with only remote folders. An
// empty window has no name. The bar names it.
function ownRecord() {
  const folders = fileFolders();
  const workspaceFile = workspaceFilePath();
  const empty = isEmptyWindow();
  if (!empty && !folders.length && !workspaceFile) return null;
  let colors = ctx.colors;
  // Under a modal's shade, the title bar is darker.
  if (colors && ctx.modal) colors = theme.shade(colors);
  return {
    id: ctx.id,
    pid: process.pid,
    name: empty
      ? null
      : vscode.workspace.name || path.basename(folders[0] || workspaceFile),
    empty,
    folders,
    workspaceFile,
    titleBarColor: colors && colors.active,
    titleBarInactiveColor: colors && colors.inactive,
    // Uncommitted changes, like the number on VSCode's Source Control icon.
    // Null while git is not ready.
    changes: ctx.changes,
    // For the bar's auto sleep. Null until known.
    unsaved: ctx.unsaved,
    busy: ctx.busy,
    startedAt: ctx.startedAt,
    // When something last changed in the window (see noteActivity), also
    // from before VSCode or the bar started. Null when not known. The bar
    // shows it, and auto sleep counts from it.
    activeAt: ctx.activeAt,
    // A command runs in a terminal or a task (see isRunning).
    running: ctx.runningNow,
    // Empty windows all look the same to the bar. When one gets the focus,
    // the bar takes the focused VSCode window as this one.
    focusedAt: empty ? ctx.focusedAt : null,
    updatedAt: new Date().toISOString(),
  };
}

// This window got or lost the focus. The bar needs it for empty windows,
// see focusedAt. A focus alone is not use, so auto sleep does not count it.
function updateFocus(windowState) {
  if (!ctx || windowState.focused === Boolean(ctx.focusedAt)) return;
  ctx.focusedAt = windowState.focused ? new Date().toISOString() : null;
  writeOwnWindow();
}

function writeOwnWindow() {
  if (!ctx) return;
  const rec = ownRecord();
  ctx.own = rec;
  try {
    const file = store.windowFile(ctx.paths, ctx.id);
    if (rec) {
      store.ensureDirs(ctx.paths);
      store.writeJsonAtomic(file, rec);
    } else {
      store.removeFile(file);
    }
  } catch (err) {
    log(`Could not write window file: ${err.message}`);
  }
}

// The bar asks this window to show a Claude tab: you clicked a row whose
// Claude tab needs you or is done. The request is used once.
function showRequestedTab() {
  if (!ctx) return;
  const file = store.requestFile(ctx.paths, ctx.id);
  const req = store.readJson(file);
  if (!req) return;
  store.removeFile(file);
  const session = store.isSafeId(req.sessionId)
    ? store.readJson(store.sessionFile(ctx.paths, req.sessionId))
    : null;
  if (!state.canShowTab(req, session, process.pid)) return;
  vscode.commands.executeCommand(CLAUDE_SHOW_SESSION, req.sessionId).then(undefined, (err) =>
    log(`Could not show the Claude tab: ${err && err.message}`),
  );
}

// All windows watch the same folder, so each one checks for its own file.
function watchRequests(context) {
  try {
    const own = `${ctx.id}.json`;
    const watcher = fs.watch(ctx.paths.requests, (event, name) => {
      if (!name || String(name) === own) showRequestedTab();
    });
    watcher.on("error", (err) => log(`Request watch failed: ${err.message}`));
    context.subscriptions.push({ dispose: () => watcher.close() });
  } catch (err) {
    log(`Could not watch for requests: ${err.message}`);
  }
}

// Remove own window file and sessions no other window contains.
function cleanUpOwnFiles() {
  try {
    if (ctx.own) {
      const others = store
        .readWindows(ctx.paths)
        .filter((w) => w.id !== ctx.id && store.isPidAlive(w.pid));
      const sessions = store.readSessions(ctx.paths);
      for (const s of state.sessionsOnlyIn(ctx.id, sessions, [
        ...others,
        ctx.own,
      ])) {
        store.removeFile(store.sessionFile(ctx.paths, s.sessionId));
      }
    }
    store.removeFile(store.windowFile(ctx.paths, ctx.id));
    store.removeFile(store.requestFile(ctx.paths, ctx.id));
  } catch (err) {
    log(`Clean-up failed: ${err.message}`);
  }
}

function activate(context) {
  ctx = {
    id: makeWindowId(),
    paths: store.paths(),
    output: vscode.window.createOutputChannel("VSCode Window Manager"),
    own: null,
    modal: false,
    colors: null,
    // VSCode's git API, its repositories and their change listeners, and
    // the count of changes.
    git: null,
    repos: new Map(),
    changes: null,
    // Unsaved files, and something that runs in a terminal or a task. The
    // running terminal commands, and their terminals.
    unsaved: null,
    busy: null,
    running: new Map(),
    // A command (not Claude Code) or a task runs. See isRunning.
    runningNow: null,
    // Activity: when something last changed, kept by VSCode for the
    // workspace, and when the window file last had it. See noteActivity.
    activeAt: context.workspaceState.get(ACTIVE_AT_KEY) || null,
    activityWrittenAt: 0,
    activityTimer: null,
    // While VSCode opens the window, it restores files and terminals, and
    // git loads. None of that is a change by you, so it is not activity.
    quietUntil: Date.now() + STARTUP_QUIET_MS,
    // Per repository root: its commit and changed files. And the paths of
    // all changed files. See updateChanges.
    gitSignatures: new Map(),
    changedPaths: new Set(),
    startedAt: new Date().toISOString(),
    // When this window got the focus. Null while it does not have it.
    focusedAt: vscode.window.state.focused ? new Date().toISOString() : null,
    // Kept by VSCode for the workspace, so activeAt is known after a restart.
    workspaceState: context.workspaceState,
  };

  try {
    store.ensureDirs(ctx.paths);
    store.pruneOldSessions(ctx.paths);
    store.pruneDeadWindows(ctx.paths);
  } catch (err) {
    log(`Startup clean-up failed: ${err.message}`);
  }

  context.subscriptions.push(
    ctx.output,
    // New folders can bring workspace color settings.
    vscode.workspace.onDidChangeWorkspaceFolders(refreshColors),
    vscode.window.onDidChangeActiveColorTheme(refreshColors),
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (COLOR_SETTINGS.some((name) => e.affectsConfiguration(name)))
        refreshColors();
    }),
    // A theme extension was added or removed.
    vscode.extensions.onDidChange(refreshColors),
    vscode.window.tabGroups.onDidChangeTabGroups(updateModal),
    vscode.window.tabGroups.onDidChangeTabs(tabsChanged),
    vscode.window.onDidChangeWindowState(updateFocus),
    vscode.workspace.onDidChangeTextDocument(documentChanged),
    vscode.workspace.onDidSaveTextDocument(documentSaved),
    vscode.workspace.onDidCloseTextDocument(updateSleepInfo),
    // Files made, deleted or renamed in VSCode, for example in the Explorer.
    vscode.workspace.onDidCreateFiles(noteActivity),
    vscode.workspace.onDidDeleteFiles(noteActivity),
    vscode.workspace.onDidRenameFiles(noteActivity),
    vscode.window.onDidOpenTerminal(updateSleepInfo),
    vscode.window.onDidCloseTerminal(terminalClosed),
    vscode.window.onDidChangeTerminalShellIntegration(updateSleepInfo),
    vscode.window.onDidStartTerminalShellExecution(commandStarted),
    vscode.window.onDidEndTerminalShellExecution(commandEnded),
    vscode.tasks.onDidStartTask(taskChanged),
    vscode.tasks.onDidEndTask(taskChanged),
  );
  // Files changed on disk by any tool. See fileChanged.
  const files = vscode.workspace.createFileSystemWatcher("**/*");
  context.subscriptions.push(
    files,
    files.onDidChange(fileChanged),
    files.onDidCreate(fileChanged),
    files.onDidDelete(fileChanged),
  );
  refreshColors();
  updateSleepInfo();
  watchGit(context);
  watchRequests(context);
  log(`Active. Window id ${ctx.id}. Status dir ${ctx.paths.base}`);
}

function deactivate() {
  if (!ctx) return;
  clearTimeout(ctx.activityTimer);
  if (ctx.activeAt) ctx.workspaceState.update(ACTIVE_AT_KEY, ctx.activeAt);
  cleanUpOwnFiles();
  ctx = null;
}

module.exports = { activate, deactivate };
