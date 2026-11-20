'use strict';

// Pure logic: hook input -> state change, which sessions belong only to
// one window (for clean-up when that window closes), and requests from the
// bar to show a Claude tab.

const fs = require('fs');
const path = require('path');

const NEEDS_INPUT_NOTIFICATIONS = new Set([
  'permission_prompt',
  'elicitation_dialog',
  'elicitation_url_dialog',
  'agent_needs_input',
]);

const DETAIL_MAX = 80;
const SKIP_WINDOW_MS = 30 * 1000;
const COMPARE_KEYS = ['state', 'reason', 'detail', 'projectDir', 'cwd', 'entrypoint', 'hostPid'];

// CLAUDE_CODE_ENTRYPOINT of a session in a tab of the Claude extension.
// A session in a terminal has another value.
const TAB_ENTRYPOINT = 'claude-vscode';
// The bar's request to show a tab is old after this. The window may have
// been reloading, and a late tab would surprise you.
const REQUEST_MAX_AGE_MS = 10 * 1000;

function trimText(value, max = DETAIL_MAX) {
  if (typeof value !== 'string') return null;
  const text = value.replace(/\s+/g, ' ').trim();
  if (!text) return null;
  return text.length > max ? text.slice(0, max - 1) + '…' : text;
}

function change(state, reason = null, detail = null) {
  return { action: 'write', state, reason, detail };
}

// Tools that ask the engineer something directly.
function askReason(tool) {
  if (tool === 'AskUserQuestion') return 'question';
  if (tool === 'ExitPlanMode') return 'plan';
  return null;
}

// Map one hook input to a change. Null means "no change".
function changeFromHook(input) {
  if (!input || typeof input !== 'object') return null;
  const tool = typeof input.tool_name === 'string' ? input.tool_name : null;

  switch (input.hook_event_name) {
    case 'SessionStart':
      // Compaction can run mid-turn, so keep the current state.
      return input.source === 'compact' ? null : change('idle');
    case 'UserPromptSubmit':
      return change('working');
    case 'PreToolUse': {
      const ask = askReason(tool);
      return ask ? change('needs_input', ask) : change('working');
    }
    case 'PermissionRequest': {
      const ask = askReason(tool);
      return ask ? change('needs_input', ask) : change('needs_input', 'permission', trimText(tool));
    }
    case 'PostToolUse':
    case 'PostToolUseFailure':
      return change('working');
    case 'Notification': {
      const type = input.notification_type;
      if (NEEDS_INPUT_NOTIFICATIONS.has(type)) {
        return change('needs_input', type, trimText(input.message));
      }
      if (type === 'idle_prompt') return change('done');
      return null;
    }
    case 'Stop':
      return change('done');
    case 'StopFailure':
      // Stop does not fire on API errors.
      return change('done', 'error', trimText(input.error));
    case 'SessionEnd':
      return { action: 'delete' };
    default:
      return null;
  }
}

// Build the session record. Stores only ids, paths and state.
// host: { entrypoint, hostPid }, see hook/claude-status.js.
function buildSession(input, ch, projectDirEnv, now = new Date(), host = {}) {
  const cwd = typeof input.cwd === 'string' && input.cwd ? input.cwd : null;
  const projectDir = typeof projectDirEnv === 'string' && projectDirEnv ? projectDirEnv : cwd;
  if (!projectDir) return null;
  return {
    sessionId: input.session_id,
    projectDir,
    cwd,
    state: ch.state,
    reason: ch.reason,
    detail: ch.detail,
    // How Claude Code runs. TAB_ENTRYPOINT for a tab of the Claude extension.
    entrypoint: trimText(host.entrypoint, 40),
    // Tabs only: the pid of the window's extension host, the same pid as
    // in its window file. Null when not known.
    hostPid: Number.isInteger(host.hostPid) && host.hostPid > 0 ? host.hostPid : null,
    updatedAt: now.toISOString(),
  };
}

// "ps -A -o pid=,ppid=" output as a Map of pid -> parent pid.
function parsePsTable(text) {
  const table = new Map();
  for (const line of String(text).split('\n')) {
    const m = /^\s*(\d+)\s+(\d+)\s*$/.exec(line);
    if (m) table.set(Number(m[1]), Number(m[2]));
  }
  return table;
}

// The VSCode extension host above startPid: the ancestor whose parent is
// VSCode's main process (VSCODE_PID). The Claude extension starts each
// tab's claude process from the extension host of its window. Null if
// there is none.
function findHostPid(table, startPid, mainPid) {
  let pid = startPid;
  for (let i = 0; i < 20 && pid > 1; i++) {
    const parent = table.get(pid);
    if (parent === undefined) return null;
    if (parent === mainPid) return pid;
    pid = parent;
  }
  return null;
}

// True if the bar's request asks this window (extension host pid) to show
// the session's tab, and the session is a live tab in this window. For any
// other session, the Claude extension would open a new tab and start a
// second Claude on the same chat.
function canShowTab(request, session, pid, now = Date.now(), maxAgeMs = REQUEST_MAX_AGE_MS) {
  if (!request || typeof request !== 'object' || !session || typeof session !== 'object') return false;
  if (typeof request.sessionId !== 'string' || request.sessionId !== session.sessionId) return false;
  const age = now - Date.parse(request.at);
  if (!(age >= -maxAgeMs && age <= maxAgeMs)) return false;
  return session.entrypoint === TAB_ENTRYPOINT && session.hostPid === pid;
}

// Skip the write if nothing changed and the old file is still fresh.
// Also skip a late Notification for a wait or a finish that is already
// recorded: it keeps the short detail and the first time. The idle_prompt
// Notification comes about 60 s after Stop. A new time would make the bar
// show the "done" tab again on click.
function shouldSkipWrite(prev, next, maxAgeMs = SKIP_WINDOW_MS, event = null) {
  if (!prev || typeof prev !== 'object') return false;
  if (event === 'Notification' && prev.state === next.state
      && (next.state === 'needs_input' || next.state === 'done')) return true;
  const same = COMPARE_KEYS.every((k) => (prev[k] ?? null) === (next[k] ?? null));
  if (!same) return false;
  const age = Date.parse(next.updatedAt) - Date.parse(prev.updatedAt);
  return age >= 0 && age < maxAgeMs;
}

function resolvePath(p) {
  try {
    return fs.realpathSync(p);
  } catch {
    return path.resolve(p);
  }
}

// Cache realpath calls for one pass.
function cachedResolver(resolve = resolvePath) {
  const cache = new Map();
  return (p) => {
    if (!cache.has(p)) cache.set(p, resolve(p));
    return cache.get(p);
  };
}

// True if p equals folder or is below it.
function isInside(p, folder) {
  if (p === folder) return true;
  const base = folder.endsWith(path.sep) ? folder : folder + path.sep;
  return p.startsWith(base);
}

function sessionPath(session) {
  const p = session && (session.projectDir || session.cwd);
  return typeof p === 'string' && p ? p : null;
}

function windowFolders(win) {
  return Array.isArray(win.folders) ? win.folders.filter((f) => typeof f === 'string' && f) : [];
}

// Sessions inside this window and inside no other open window. A Claude
// tab belongs to the window whose pid is its hostPid.
function sessionsOnlyIn(windowId, sessions, windows, resolve = resolvePath) {
  const res = cachedResolver(resolve);
  const own = windows.find((w) => w.id === windowId);
  if (!own) return [];
  const others = windows.filter((w) => w.id !== windowId);
  return sessions.filter((s) => {
    const host = Number.isInteger(s.hostPid) ? windows.find((w) => w.pid === s.hostPid) : null;
    if (host) return host === own;
    const p = sessionPath(s);
    if (!p) return false;
    const target = res(p);
    const inside = (w) => windowFolders(w).some((f) => isInside(target, res(f)));
    return inside(own) && !others.some(inside);
  });
}

module.exports = {
  DETAIL_MAX,
  TAB_ENTRYPOINT,
  trimText,
  changeFromHook,
  buildSession,
  shouldSkipWrite,
  parsePsTable,
  findHostPid,
  canShowTab,
  isInside,
  sessionsOnlyIn,
};
