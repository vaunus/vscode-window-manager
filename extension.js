'use strict';

// VS Code Window Manager: registers this VS Code window for the bar app.
// It writes windows/<id>.json with this window's folders and title bar
// colors. The bar reads it.

const vscode = require('vscode');
const path = require('path');

const state = require('./lib/state');
const store = require('./lib/store');
const theme = require('./lib/theme');
const modal = require('./lib/modal');

// Settings that can change the title bar color.
const COLOR_SETTINGS = [
  'workbench.colorTheme',
  'workbench.colorCustomizations',
  'workbench.preferredLightColorTheme',
  'workbench.preferredDarkColorTheme',
  'workbench.preferredHighContrastColorTheme',
  'workbench.preferredHighContrastLightColorTheme',
  'window.autoDetectColorScheme',
  'window.titleBarStyle',
];

// Runtime state for this window. Null when not active.
let ctx = null;

function log(message) {
  if (ctx && ctx.output) ctx.output.appendLine(`${new Date().toISOString()} ${message}`);
}

// One id per window. The pid keeps it unique even if sessionId repeats.
function makeWindowId() {
  const sid = String(vscode.env.sessionId || '').replace(/[^A-Za-z0-9_-]/g, '');
  return `${process.pid}-${sid || 'window'}`.slice(0, 200);
}

function fileFolders() {
  return (vscode.workspace.workspaceFolders || [])
    .filter((f) => f.uri.scheme === 'file')
    .map((f) => f.uri.fsPath);
}

function workspaceFilePath() {
  const wf = vscode.workspace.workspaceFile;
  return wf && wf.scheme === 'file' ? wf.fsPath : null;
}

// This window's title bar colors, { active, inactive } as "#RRGGBB", or null.
function titleBarColors() {
  try {
    const cfg = vscode.workspace.getConfiguration();
    return theme.titleBarColors({
      extensions: vscode.extensions.all,
      kind: vscode.window.activeColorTheme.kind,
      settings: {
        colorTheme: cfg.get('workbench.colorTheme'),
        colorCustomizations: cfg.get('workbench.colorCustomizations'),
        preferredLightColorTheme: cfg.get('workbench.preferredLightColorTheme'),
        preferredDarkColorTheme: cfg.get('workbench.preferredDarkColorTheme'),
        preferredHighContrastColorTheme: cfg.get('workbench.preferredHighContrastColorTheme'),
        preferredHighContrastLightColorTheme: cfg.get('workbench.preferredHighContrastLightColorTheme'),
        autoDetectColorScheme: cfg.get('window.autoDetectColorScheme'),
        titleBarStyle: cfg.get('window.titleBarStyle'),
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
    tabs: g.tabs.map((t) => ({ label: t.label, known: t.input !== undefined, active: t.isActive })),
  }));
}

// A VS Code modal (for example Settings) opened or closed: the title bar
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

// True for an empty window: no folder and no workspace, for example a new
// window on the Welcome page.
function isEmptyWindow() {
  return !(vscode.workspace.workspaceFolders || []).length && !vscode.workspace.workspaceFile;
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
    name: empty ? null : vscode.workspace.name || path.basename(folders[0] || workspaceFile),
    empty,
    folders,
    workspaceFile,
    titleBarColor: colors && colors.active,
    titleBarInactiveColor: colors && colors.inactive,
    startedAt: ctx.startedAt,
    // Empty windows all look the same to the bar. When one gets the focus,
    // the bar takes the focused VS Code window as this one.
    focusedAt: empty ? ctx.focusedAt : null,
    updatedAt: new Date().toISOString(),
  };
}

// This window got or lost the focus. Only an empty window writes it.
function updateFocus(windowState) {
  if (!ctx || windowState.focused === Boolean(ctx.focusedAt)) return;
  ctx.focusedAt = windowState.focused ? new Date().toISOString() : null;
  if (ctx.own && ctx.own.empty) writeOwnWindow();
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

// Remove own window file and sessions no other window contains.
function cleanUpOwnFiles() {
  try {
    if (ctx.own) {
      const others = store.readWindows(ctx.paths).filter((w) => w.id !== ctx.id && store.isPidAlive(w.pid));
      const sessions = store.readSessions(ctx.paths);
      for (const s of state.sessionsOnlyIn(ctx.id, sessions, [...others, ctx.own])) {
        store.removeFile(store.sessionFile(ctx.paths, s.sessionId));
      }
    }
    store.removeFile(store.windowFile(ctx.paths, ctx.id));
  } catch (err) {
    log(`Clean-up failed: ${err.message}`);
  }
}

function activate(context) {
  ctx = {
    id: makeWindowId(),
    paths: store.paths(),
    output: vscode.window.createOutputChannel('VS Code Window Manager'),
    own: null,
    modal: false,
    colors: null,
    startedAt: new Date().toISOString(),
    // When this window got the focus. Null while it does not have it.
    focusedAt: vscode.window.state.focused ? new Date().toISOString() : null,
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
      if (COLOR_SETTINGS.some((name) => e.affectsConfiguration(name))) refreshColors();
    }),
    // A theme extension was added or removed.
    vscode.extensions.onDidChange(refreshColors),
    vscode.window.tabGroups.onDidChangeTabGroups(updateModal),
    vscode.window.tabGroups.onDidChangeTabs(updateModal),
    vscode.window.onDidChangeWindowState(updateFocus),
  );
  refreshColors();
  log(`Active. Window id ${ctx.id}. Status dir ${ctx.paths.base}`);
}

function deactivate() {
  if (!ctx) return;
  cleanUpOwnFiles();
  ctx = null;
}

module.exports = { activate, deactivate };
