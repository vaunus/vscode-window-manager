'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const store = require('../lib/store');

function tempPaths(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'vwm-store-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const p = store.paths(dir);
  store.ensureDirs(p);
  return p;
}

test('paths uses VSCODE_WINDOW_MANAGER_DIR when set', (t) => {
  const old = process.env.VSCODE_WINDOW_MANAGER_DIR;
  t.after(() => {
    if (old === undefined) delete process.env.VSCODE_WINDOW_MANAGER_DIR;
    else process.env.VSCODE_WINDOW_MANAGER_DIR = old;
  });
  process.env.VSCODE_WINDOW_MANAGER_DIR = '/x/status';
  assert.deepEqual(store.paths(), {
    base: '/x/status',
    sessions: '/x/status/sessions',
    windows: '/x/status/windows',
    requests: '/x/status/requests',
  });
  delete process.env.VSCODE_WINDOW_MANAGER_DIR;
  assert.equal(store.paths().base, path.join(os.homedir(), '.claude', 'window-status'));
});

test('isSafeId blocks path tricks', () => {
  assert.equal(store.isSafeId('0a1b2c3d-4e5f-6789-abcd-ef0123456789'), true);
  assert.equal(store.isSafeId('abc.123'), true);
  for (const bad of ['', '.', '..', '../x', 'a/b', '.hidden', 'a b', null, 5]) {
    assert.equal(store.isSafeId(bad), false, String(bad));
  }
  assert.throws(() => store.sessionFile(store.paths('/x'), '../evil'));
  assert.throws(() => store.requestFile(store.paths('/x'), '../evil'));
});

test('writeJsonAtomic writes 0600 and leaves no temp file', (t) => {
  const p = tempPaths(t);
  const file = store.sessionFile(p, 's1');
  store.writeJsonAtomic(file, { a: 1 });
  store.writeJsonAtomic(file, { a: 2 });
  assert.deepEqual(store.readJson(file), { a: 2 });
  assert.equal(fs.statSync(file).mode & 0o777, 0o600);
  assert.deepEqual(fs.readdirSync(p.sessions), ['s1.json']);
});

test('readJson returns null for missing or bad files', (t) => {
  const p = tempPaths(t);
  const bad = path.join(p.sessions, 'bad.json');
  fs.writeFileSync(bad, '{nope');
  assert.equal(store.readJson(bad), null);
  assert.equal(store.readJson(path.join(p.sessions, 'missing.json')), null);
});

test('readSessions and readWindows skip temp and bad files', (t) => {
  const p = tempPaths(t);
  store.writeJsonAtomic(store.sessionFile(p, 's1'), { sessionId: 'other', state: 'working' });
  fs.writeFileSync(path.join(p.sessions, 's2.json.123.tmp'), '{}');
  fs.writeFileSync(path.join(p.sessions, 's3.json'), 'not json');
  fs.writeFileSync(path.join(p.sessions, 's4.json'), '[1]');
  store.writeJsonAtomic(store.windowFile(p, 'w1'), { pid: 1, name: 'x' });

  // The id always comes from the file name.
  assert.deepEqual(store.readSessions(p), [{ sessionId: 's1', state: 'working' }]);
  assert.deepEqual(store.readWindows(p), [{ id: 'w1', pid: 1, name: 'x' }]);
  assert.deepEqual(store.readSessions(store.paths('/does/not/exist')), []);
});

test('removeFile ignores missing files', (t) => {
  const p = tempPaths(t);
  const file = store.sessionFile(p, 's1');
  store.writeJsonAtomic(file, {});
  assert.equal(store.removeFile(file), true);
  assert.equal(store.removeFile(file), false);
});

test('isPidAlive', () => {
  assert.equal(store.isPidAlive(process.pid), true);
  const child = spawnSync(process.execPath, ['-e', '']);
  assert.equal(store.isPidAlive(child.pid), false);
  assert.equal(store.isPidAlive(0), false);
  assert.equal(store.isPidAlive(-1), false);
  assert.equal(store.isPidAlive('123'), false);
  assert.equal(store.isPidAlive(undefined), false);
});

test('pruneDeadWindows deletes windows with a dead pid', (t) => {
  const p = tempPaths(t);
  store.writeJsonAtomic(store.windowFile(p, 'live'), { pid: 100 });
  store.writeJsonAtomic(store.windowFile(p, 'dead'), { pid: 200 });
  store.writeJsonAtomic(store.windowFile(p, 'nopid'), {});
  store.writeJsonAtomic(store.requestFile(p, 'live'), {});
  store.writeJsonAtomic(store.requestFile(p, 'dead'), {});
  const removed = store.pruneDeadWindows(p, (pid) => pid === 100);
  assert.deepEqual(removed.sort(), ['dead', 'nopid']);
  assert.deepEqual(fs.readdirSync(p.windows), ['live.json']);
  assert.deepEqual(fs.readdirSync(p.requests), ['live.json']);
});

test('pruneOldSessions deletes files older than 24 h', (t) => {
  const p = tempPaths(t);
  const now = Date.now();
  const old = new Date(now - store.DAY_MS - 60 * 1000);
  store.writeJsonAtomic(store.sessionFile(p, 'old'), {});
  store.writeJsonAtomic(store.sessionFile(p, 'new'), {});
  fs.writeFileSync(path.join(p.sessions, 'x.json.1.tmp'), '');
  fs.utimesSync(store.sessionFile(p, 'old'), old, old);
  fs.utimesSync(path.join(p.sessions, 'x.json.1.tmp'), old, old);
  const removed = store.pruneOldSessions(p, store.DAY_MS, now);
  assert.deepEqual(removed.sort(), ['old.json', 'x.json.1.tmp']);
  assert.deepEqual(fs.readdirSync(p.sessions), ['new.json']);
});
