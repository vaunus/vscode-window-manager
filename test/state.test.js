'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

const s = require('../lib/state');

const base = { session_id: 'abc', cwd: '/w/app' };
const ev = (extra) => s.changeFromHook({ ...base, ...extra });
const write = (state, reason = null, detail = null) => ({ action: 'write', state, reason, detail });

test('changeFromHook maps each hook event', () => {
  assert.deepEqual(ev({ hook_event_name: 'SessionStart', source: 'startup' }), write('idle'));
  assert.deepEqual(ev({ hook_event_name: 'UserPromptSubmit', prompt: 'x' }), write('working'));
  assert.deepEqual(ev({ hook_event_name: 'PreToolUse', tool_name: 'AskUserQuestion' }), write('needs_input', 'question'));
  assert.deepEqual(ev({ hook_event_name: 'PreToolUse', tool_name: 'ExitPlanMode' }), write('needs_input', 'plan'));
  assert.deepEqual(ev({ hook_event_name: 'PreToolUse', tool_name: 'Bash' }), write('working'));
  assert.deepEqual(ev({ hook_event_name: 'PermissionRequest', tool_name: 'Bash' }), write('needs_input', 'permission', 'Bash'));
  assert.deepEqual(ev({ hook_event_name: 'PostToolUse', tool_name: 'Bash' }), write('working'));
  assert.deepEqual(ev({ hook_event_name: 'PostToolUseFailure', tool_name: 'Bash' }), write('working'));
  assert.deepEqual(ev({ hook_event_name: 'Stop' }), write('done'));
  assert.deepEqual(ev({ hook_event_name: 'StopFailure', error: 'rate_limit' }), write('done', 'error', 'rate_limit'));
  assert.deepEqual(ev({ hook_event_name: 'SessionEnd', reason: 'other' }), { action: 'delete' });
});

test('PermissionRequest for ask tools keeps the ask reason', () => {
  assert.deepEqual(ev({ hook_event_name: 'PermissionRequest', tool_name: 'AskUserQuestion' }), write('needs_input', 'question'));
  assert.deepEqual(ev({ hook_event_name: 'PermissionRequest', tool_name: 'ExitPlanMode' }), write('needs_input', 'plan'));
});

test('Notification types', () => {
  for (const type of ['permission_prompt', 'elicitation_dialog', 'elicitation_url_dialog', 'agent_needs_input']) {
    assert.deepEqual(
      ev({ hook_event_name: 'Notification', notification_type: type, message: 'Claude needs your permission' }),
      write('needs_input', type, 'Claude needs your permission')
    );
  }
  assert.deepEqual(ev({ hook_event_name: 'Notification', notification_type: 'idle_prompt', message: 'x' }), write('done'));
  assert.equal(ev({ hook_event_name: 'Notification', notification_type: 'auth_success', message: 'x' }), null);
  assert.equal(ev({ hook_event_name: 'Notification', message: 'x' }), null);
});

test('Notification message is trimmed to 80 chars', () => {
  const ch = ev({ hook_event_name: 'Notification', notification_type: 'permission_prompt', message: 'a'.repeat(200) });
  assert.equal(ch.detail.length, s.DETAIL_MAX);
  assert.ok(ch.detail.endsWith('…'));
  assert.equal(s.trimText('  two\n lines  '), 'two lines');
  assert.equal(s.trimText('   '), null);
  assert.equal(s.trimText(42), null);
});

test('SessionStart from compaction keeps the current state', () => {
  assert.equal(ev({ hook_event_name: 'SessionStart', source: 'compact' }), null);
});

test('unknown or bad input gives no change', () => {
  assert.equal(s.changeFromHook(null), null);
  assert.equal(s.changeFromHook('x'), null);
  assert.equal(s.changeFromHook({}), null);
  assert.equal(ev({ hook_event_name: 'SubagentStop' }), null);
});

test('buildSession stores only the allowed fields', () => {
  const input = { ...base, hook_event_name: 'PermissionRequest', tool_name: 'Bash', tool_input: { command: 'secret' }, prompt: 'secret' };
  const now = new Date('2026-11-17T10:00:00.000Z');
  const rec = s.buildSession(input, s.changeFromHook(input), '/w/root', now);
  assert.deepEqual(rec, {
    sessionId: 'abc',
    projectDir: '/w/root',
    cwd: '/w/app',
    state: 'needs_input',
    reason: 'permission',
    detail: 'Bash',
    entrypoint: null,
    hostPid: null,
    updatedAt: '2026-11-17T10:00:00.000Z',
  });
  assert.ok(!JSON.stringify(rec).includes('secret'));
});

test('buildSession stores the entrypoint and the host pid', () => {
  const ch = write('idle');
  const rec = s.buildSession(base, ch, undefined, undefined, { entrypoint: 'claude-vscode', hostPid: 4321 });
  assert.equal(rec.entrypoint, 'claude-vscode');
  assert.equal(rec.hostPid, 4321);
  for (const bad of [0, -1, 1.5, '4321', null]) {
    assert.equal(s.buildSession(base, ch, undefined, undefined, { hostPid: bad }).hostPid, null, String(bad));
  }
});

test('findHostPid walks up to the child of the main process', () => {
  // hook 50 -> sh 40 -> claude 30 -> extension host 20 -> VSCode 10 -> launchd 1
  const table = s.parsePsTable('   50    40\n   40    30\n   30    20\n   20    10\n   10     1\nbad line\n');
  assert.equal(table.get(30), 20);
  assert.equal(s.findHostPid(table, 50, 10), 20);
  assert.equal(s.findHostPid(table, 30, 10), 20);
  // A terminal session outside VSCode: no ancestor is VSCode.
  assert.equal(s.findHostPid(table, 50, 99), null);
  assert.equal(s.findHostPid(table, 77, 10), null);
  // A loop in the table ends.
  assert.equal(s.findHostPid(new Map([[5, 6], [6, 5]]), 5, 10), null);
});

test('canShowTab only allows a fresh request for a tab in this window', () => {
  const now = Date.parse('2026-11-20T10:00:00.000Z');
  const tab = { sessionId: 'abc', entrypoint: 'claude-vscode', hostPid: 20 };
  const req = { sessionId: 'abc', at: '2026-11-20T09:59:58.000Z' };
  assert.equal(s.canShowTab(req, tab, 20, now), true);
  // Another window.
  assert.equal(s.canShowTab(req, tab, 21, now), false);
  // A terminal session, or a session from an old hook.
  assert.equal(s.canShowTab(req, { ...tab, entrypoint: 'cli' }, 20, now), false);
  assert.equal(s.canShowTab(req, { ...tab, hostPid: null }, 20, now), false);
  // Another session, an old or bad time, missing parts.
  assert.equal(s.canShowTab({ ...req, sessionId: 'xyz' }, tab, 20, now), false);
  assert.equal(s.canShowTab({ ...req, at: '2026-11-20T09:59:00.000Z' }, tab, 20, now), false);
  assert.equal(s.canShowTab({ ...req, at: 'soon' }, tab, 20, now), false);
  assert.equal(s.canShowTab(null, tab, 20, now), false);
  assert.equal(s.canShowTab(req, null, 20, now), false);
});

test('buildSession falls back to cwd, and needs a path', () => {
  const ch = write('idle');
  assert.equal(s.buildSession(base, ch, undefined).projectDir, '/w/app');
  assert.equal(s.buildSession(base, ch, '').projectDir, '/w/app');
  assert.equal(s.buildSession({ session_id: 'abc' }, ch, undefined), null);
});

test('shouldSkipWrite', () => {
  const prev = { projectDir: '/a', cwd: '/a', state: 'working', reason: null, detail: null, updatedAt: '2026-11-17T10:00:00.000Z' };
  const at = (iso, extra = {}) => ({ ...prev, ...extra, updatedAt: iso });
  assert.equal(s.shouldSkipWrite(prev, at('2026-11-17T10:00:10.000Z')), true);
  assert.equal(s.shouldSkipWrite(prev, at('2026-11-17T10:00:31.000Z')), false);
  assert.equal(s.shouldSkipWrite(prev, at('2026-11-17T10:00:10.000Z', { state: 'done' })), false);
  assert.equal(s.shouldSkipWrite(prev, at('2026-11-17T10:00:10.000Z', { detail: 'Bash' })), false);
  assert.equal(s.shouldSkipWrite(null, at('2026-11-17T10:00:10.000Z')), false);
  assert.equal(s.shouldSkipWrite({ ...prev, updatedAt: 'bad' }, at('2026-11-17T10:00:10.000Z')), false);
});

test('a late Notification does not replace a recorded wait', () => {
  const prev = { projectDir: '/a', cwd: '/a', state: 'needs_input', reason: 'permission', detail: 'Bash', updatedAt: '2026-11-17T09:00:00.000Z' };
  const next = { ...prev, reason: 'permission_prompt', detail: 'Claude needs your permission to use Bash', updatedAt: '2026-11-17T10:00:00.000Z' };
  assert.equal(s.shouldSkipWrite(prev, next, undefined, 'Notification'), true);
  assert.equal(s.shouldSkipWrite(prev, next, undefined, 'PermissionRequest'), false);
  assert.equal(s.shouldSkipWrite({ ...prev, state: 'working' }, next, undefined, 'Notification'), false);
  assert.equal(s.shouldSkipWrite(prev, { ...next, state: 'done' }, undefined, 'Notification'), false);
});

test('a late idle_prompt keeps the first done time', () => {
  const prev = { projectDir: '/a', cwd: '/a', state: 'done', reason: 'error', detail: 'x', updatedAt: '2026-11-17T09:00:00.000Z' };
  const next = { ...prev, reason: null, detail: null, updatedAt: '2026-11-17T09:01:00.000Z' };
  assert.equal(s.shouldSkipWrite(prev, next, undefined, 'Notification'), true);
  assert.equal(s.shouldSkipWrite(prev, next, undefined, 'Stop'), false);
  assert.equal(s.shouldSkipWrite({ ...prev, state: 'working' }, next, undefined, 'Notification'), false);
});

test('isInside uses a path boundary', () => {
  assert.equal(s.isInside('/w/mega-mentor', '/w/mega-mentor'), true);
  assert.equal(s.isInside('/w/mega-mentor/src', '/w/mega-mentor'), true);
  assert.equal(s.isInside('/w/mega-mentor-2', '/w/mega-mentor'), false);
  assert.equal(s.isInside('/w/x', '/'), true);
});

const id = (p) => p;
const win = (wid, folders) => ({ id: wid, name: wid, folders, workspaceFile: null });

test('sessionsOnlyIn skips sessions another window also contains', () => {
  const windows = [win('outer', ['/w/mono']), win('inner', ['/w/mono/pkg']), win('other', ['/w/x'])];
  const sessions = [
    { sessionId: '1', projectDir: '/w/mono/pkg' },
    { sessionId: '2', projectDir: '/w/x' },
    { sessionId: '3', projectDir: '/w/mono' },
    { sessionId: '4', projectDir: '/w/x/.claude/worktrees/a' },
  ];
  assert.deepEqual(s.sessionsOnlyIn('inner', sessions, windows, id), []);
  assert.deepEqual(s.sessionsOnlyIn('other', sessions, windows, id).map((x) => x.sessionId), ['2', '4']);
  assert.deepEqual(s.sessionsOnlyIn('outer', sessions, windows, id).map((x) => x.sessionId), ['3']);
  assert.deepEqual(s.sessionsOnlyIn('missing', sessions, windows, id), []);
});

test('sessionsOnlyIn gives a Claude tab to the window that runs it', () => {
  const windows = [
    { ...win('outer', ['/w/mono']), pid: 10 },
    { ...win('inner', ['/w/mono/pkg']), pid: 20 },
  ];
  // Runs in "outer", though "inner" has the longer folder match.
  const tab = { sessionId: '1', projectDir: '/w/mono/pkg', hostPid: 10 };
  // Its window is gone: the folder rule applies, and both windows hold it.
  const orphan = { sessionId: '2', projectDir: '/w/mono/pkg', hostPid: 99 };
  assert.deepEqual(s.sessionsOnlyIn('outer', [tab, orphan], windows, id).map((x) => x.sessionId), ['1']);
  assert.deepEqual(s.sessionsOnlyIn('inner', [tab, orphan], windows, id), []);
});

test('sessionsOnlyIn resolves symlinks with realpath', () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'vwm-state-'));
  try {
    const real = fs.realpathSync(tmp);
    fs.mkdirSync(path.join(real, 'repo'));
    fs.symlinkSync(path.join(real, 'repo'), path.join(real, 'link'));
    const windows = [win('a', [path.join(real, 'repo')])];
    const viaLink = { sessionId: '1', projectDir: path.join(real, 'link') };
    // os.tmpdir() on macOS is under /var, which is a symlink to /private/var.
    const viaVar = { sessionId: '2', projectDir: path.join(tmp, 'repo') };
    assert.deepEqual(s.sessionsOnlyIn('a', [viaLink, viaVar], windows).map((x) => x.sessionId), ['1', '2']);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});
