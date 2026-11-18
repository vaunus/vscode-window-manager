'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const h = require('../scripts/hooks');

const SCRIPT = path.join(__dirname, '..', 'scripts', 'hooks.js');
const CMD = h.hookCommand('/usr/local/bin/node', '/Applications/VS Code Window Manager.app/Contents/Resources/hook/claude-status.js');
const ALL_EVENTS = [...h.TOOL_EVENTS, ...h.OTHER_EVENTS];
const sound = { type: 'command', command: '/x/stop-sound.sh' };
const ours = (command) => ({ type: 'command', command, timeout: 5 });

function countOurs(settings) {
  return Object.values(settings.hooks || {})
    .flat()
    .flatMap((g) => g.hooks)
    .filter(h.isOurs).length;
}

test('shellQuote handles spaces and quotes', () => {
  assert.equal(h.shellQuote('/a b/c'), `'/a b/c'`);
  assert.equal(h.shellQuote(`it's`), `'it'\\''s'`);
  assert.equal(h.shellQuote('$HOME'), `'$HOME'`);
});

test('addHooks adds one hook to each event', () => {
  const out = h.addHooks({}, CMD);
  assert.deepEqual(Object.keys(out.hooks).sort(), [...ALL_EVENTS].sort());
  assert.equal(countOurs(out), ALL_EVENTS.length);
  assert.equal(out.hooks.PreToolUse[0].matcher, '*');
  assert.equal(out.hooks.Stop[0].matcher, undefined);
  assert.equal(out.hooks.Stop[0].hooks[0].command, CMD);
});

test('addHooks keeps other settings and hooks, and replaces old copies', () => {
  const before = {
    model: 'opus',
    hooks: {
      Stop: [{ matcher: '', hooks: [sound] }, { hooks: [ours(`"$HOME/.n/bin/node" "$HOME/old-repo/hook/claude-status.js"`)] }],
      TaskCompleted: [{ matcher: '', hooks: [sound] }],
    },
  };
  const out = h.addHooks(before, CMD);
  assert.equal(out.model, 'opus');
  assert.deepEqual(out.hooks.TaskCompleted, before.hooks.TaskCompleted);
  assert.deepEqual(out.hooks.Stop, [{ matcher: '', hooks: [sound] }, { hooks: [ours(CMD)] }]);
  assert.equal(countOurs(out), ALL_EVENTS.length);
  assert.deepEqual(h.addHooks(out, CMD), out, 'a second add changes nothing');
});

test('removeHooks removes only ours, and empty groups and events', () => {
  const before = {
    hooks: {
      Stop: [{ hooks: [sound, ours(CMD)] }],
      SessionEnd: [{ hooks: [ours(CMD)] }],
    },
  };
  assert.deepEqual(h.removeHooks(before), { hooks: { Stop: [{ hooks: [sound] }] } });
  assert.deepEqual(h.removeHooks(h.addHooks({ a: 1 }, CMD)), { a: 1 });
  assert.deepEqual(h.removeHooks({}), {});
});

function runCli(t, args, setup) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'vwm-hooks-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  if (setup) setup(dir);
  const r = spawnSync(process.execPath, [SCRIPT, ...args], {
    env: { ...process.env, CLAUDE_CONFIG_DIR: dir },
    encoding: 'utf8',
  });
  return { dir, r, file: path.join(dir, 'settings.json') };
}

test('cli add then remove round-trips the settings file, with a backup', (t) => {
  const original = { model: 'opus', hooks: { Stop: [{ hooks: [sound] }] } };
  const { dir, r, file } = runCli(t, ['add', '/n/node', '/a b/claude-status.js'], (d) =>
    fs.writeFileSync(path.join(d, 'settings.json'), JSON.stringify(original)));
  assert.equal(r.status, 0, r.stderr);
  const added = JSON.parse(fs.readFileSync(file, 'utf8'));
  assert.equal(countOurs(added), ALL_EVENTS.length);
  assert.deepEqual(JSON.parse(fs.readFileSync(`${file}.vscode-window-manager.bak`, 'utf8')), original);

  const r2 = spawnSync(process.execPath, [SCRIPT, 'remove'], { env: { ...process.env, CLAUDE_CONFIG_DIR: dir }, encoding: 'utf8' });
  assert.equal(r2.status, 0, r2.stderr);
  assert.deepEqual(JSON.parse(fs.readFileSync(file, 'utf8')), original);
});

test('cli writes through a symlinked settings file', (t) => {
  const { r, file, dir } = runCli(t, ['add', '/n/node', '/h/claude-status.js'], (d) => {
    fs.writeFileSync(path.join(d, 'real.json'), '{}');
    fs.symlinkSync(path.join(d, 'real.json'), path.join(d, 'settings.json'));
  });
  assert.equal(r.status, 0, r.stderr);
  assert.ok(fs.lstatSync(file).isSymbolicLink());
  assert.equal(countOurs(JSON.parse(fs.readFileSync(path.join(dir, 'real.json'), 'utf8'))), ALL_EVENTS.length);
});

test('cli creates a missing settings file', (t) => {
  const { r, file } = runCli(t, ['add', '/n/node', '/h/claude-status.js']);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(countOurs(JSON.parse(fs.readFileSync(file, 'utf8'))), ALL_EVENTS.length);
});

test('cli leaves invalid JSON alone and fails', (t) => {
  const { r, file } = runCli(t, ['add', '/n/node', '/h/claude-status.js'], (d) =>
    fs.writeFileSync(path.join(d, 'settings.json'), '{oops'));
  assert.equal(r.status, 1);
  assert.equal(fs.readFileSync(file, 'utf8'), '{oops');
});
