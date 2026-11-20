'use strict';

// Runs the real hook script as a child process.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const HOOK = path.join(__dirname, '..', 'hook', 'claude-status.js');

function setup(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'vwm-hook-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const env = { ...process.env, VSCODE_WINDOW_MANAGER_DIR: dir };
  delete env.CLAUDE_PROJECT_DIR;
  delete env.CLAUDE_CODE_ENTRYPOINT;
  delete env.VSCODE_PID;
  const run = (input, extraEnv = {}) => {
    const r = spawnSync(process.execPath, [HOOK], {
      input: typeof input === 'string' ? input : JSON.stringify(input),
      env: { ...env, ...extraEnv },
      timeout: 10000,
    });
    assert.equal(r.status, 0, 'exit code');
    assert.equal(r.stdout.length, 0, 'stdout must be empty');
    assert.equal(r.stderr.length, 0, 'stderr must be empty');
    return r;
  };
  const file = (id) => path.join(dir, 'sessions', `${id}.json`);
  const read = (id) => JSON.parse(fs.readFileSync(file(id), 'utf8'));
  return { dir, run, file, read };
}

test('PermissionRequest writes needs_input', (t) => {
  const h = setup(t);
  h.run({ session_id: 't1', cwd: '/tmp', hook_event_name: 'PermissionRequest', tool_name: 'Bash', tool_input: { command: 'secret' } });
  const rec = h.read('t1');
  assert.equal(rec.state, 'needs_input');
  assert.equal(rec.reason, 'permission');
  assert.equal(rec.detail, 'Bash');
  assert.equal(rec.projectDir, '/tmp');
  assert.equal(fs.statSync(h.file('t1')).mode & 0o777, 0o600);
  assert.ok(!fs.readFileSync(h.file('t1'), 'utf8').includes('secret'));
});

test('CLAUDE_PROJECT_DIR sets projectDir', (t) => {
  const h = setup(t);
  h.run({ session_id: 't1', cwd: '/w/app/sub', hook_event_name: 'Stop' }, { CLAUDE_PROJECT_DIR: '/w/app' });
  assert.equal(h.read('t1').projectDir, '/w/app');
  assert.equal(h.read('t1').cwd, '/w/app/sub');
});

test('empty, invalid and unsafe input writes nothing', (t) => {
  const h = setup(t);
  h.run('');
  h.run('{not json');
  h.run('null');
  h.run('[]');
  h.run({ session_id: '../evil', cwd: '/tmp', hook_event_name: 'Stop' });
  h.run({ cwd: '/tmp', hook_event_name: 'Stop' });
  h.run({ session_id: 't1', hook_event_name: 'Stop' });
  h.run({ session_id: 't1', cwd: '/tmp', hook_event_name: 'Notification', notification_type: 'auth_success' });
  assert.equal(fs.existsSync(path.join(h.dir, 'sessions')), false);
});

test('UserPromptSubmit does not store the prompt', (t) => {
  const h = setup(t);
  h.run({ session_id: 't1', cwd: '/tmp', hook_event_name: 'UserPromptSubmit', prompt: 'top secret prompt' });
  assert.equal(h.read('t1').state, 'working');
  assert.ok(!fs.readFileSync(h.file('t1'), 'utf8').includes('secret'));
});

test('same state within 30 s does not rewrite the file', (t) => {
  const h = setup(t);
  const input = { session_id: 't1', cwd: '/tmp', hook_event_name: 'PreToolUse', tool_name: 'Read' };
  h.run(input);
  const first = h.read('t1').updatedAt;
  h.run({ ...input, hook_event_name: 'PostToolUse' });
  assert.equal(h.read('t1').updatedAt, first);
  h.run({ ...input, hook_event_name: 'Stop' });
  assert.equal(h.read('t1').state, 'done');
});

test('a late permission Notification keeps the short detail', (t) => {
  const h = setup(t);
  h.run({ session_id: 't1', cwd: '/tmp', hook_event_name: 'PermissionRequest', tool_name: 'Bash' });
  h.run({ session_id: 't1', cwd: '/tmp', hook_event_name: 'Notification', notification_type: 'permission_prompt', message: 'Claude needs your permission to use Bash' });
  assert.equal(h.read('t1').detail, 'Bash');
});

test('SessionEnd deletes the file', (t) => {
  const h = setup(t);
  h.run({ session_id: 't1', cwd: '/tmp', hook_event_name: 'SessionStart', source: 'startup' });
  assert.equal(h.read('t1').state, 'idle');
  h.run({ session_id: 't1', cwd: '/tmp', hook_event_name: 'SessionEnd', reason: 'other' });
  assert.equal(fs.existsSync(h.file('t1')), false);
  // A second SessionEnd is still silent.
  h.run({ session_id: 't1', cwd: '/tmp', hook_event_name: 'SessionEnd', reason: 'other' });
});

test('a write error is silent', (t) => {
  const h = setup(t);
  // A file where the dir should be makes mkdir fail.
  fs.writeFileSync(path.join(h.dir, 'sessions'), '');
  h.run({ session_id: 't1', cwd: '/tmp', hook_event_name: 'Stop' });
});

test('a Claude tab records the pid of its extension host', (t) => {
  const h = setup(t);
  // The hook is a child of this test process. With the test runner as
  // "VSCode", this test process is the "extension host".
  const tab = { CLAUDE_CODE_ENTRYPOINT: 'claude-vscode', VSCODE_PID: String(process.ppid) };
  h.run({ session_id: 't1', cwd: '/tmp', hook_event_name: 'SessionStart', source: 'startup' }, tab);
  assert.equal(h.read('t1').entrypoint, 'claude-vscode');
  assert.equal(h.read('t1').hostPid, process.pid);
  // Later events keep it.
  h.run({ session_id: 't1', cwd: '/tmp', hook_event_name: 'PermissionRequest', tool_name: 'Bash' }, tab);
  assert.equal(h.read('t1').hostPid, process.pid);
});

test('a terminal session records no host pid', (t) => {
  const h = setup(t);
  h.run({ session_id: 't1', cwd: '/tmp', hook_event_name: 'Stop' }, { CLAUDE_CODE_ENTRYPOINT: 'cli', VSCODE_PID: String(process.ppid) });
  assert.equal(h.read('t1').entrypoint, 'cli');
  assert.equal(h.read('t1').hostPid, null);
});
