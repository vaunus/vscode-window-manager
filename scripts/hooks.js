'use strict';

// Adds or removes the status hooks in Claude Code's user settings.
//   node scripts/hooks.js add <node path> <hook script path>
//   node scripts/hooks.js remove
// Other hooks and settings stay as they are. Before a change, the old file
// is copied to settings.json.vscode-window-manager.bak.

const fs = require('fs');
const os = require('os');
const path = require('path');

// A hook is ours if its command runs this script, from any folder.
const HOOK_FILE = 'claude-status.js';
const TOOL_EVENTS = ['PreToolUse', 'PermissionRequest', 'PostToolUse', 'PostToolUseFailure'];
const OTHER_EVENTS = ['SessionStart', 'UserPromptSubmit', 'Notification', 'Stop', 'StopFailure', 'SessionEnd'];
const TIMEOUT_S = 5;

function settingsFile() {
  const dir = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
  return path.join(dir, 'settings.json');
}

// Quote for sh. Safe for spaces, $ and quotes in paths.
function shellQuote(s) {
  return `'${String(s).replace(/'/g, `'\\''`)}'`;
}

function hookCommand(node, script) {
  return `${shellQuote(node)} ${shellQuote(script)}`;
}

function isOurs(hook) {
  return Boolean(hook) && typeof hook.command === 'string' && hook.command.includes(HOOK_FILE);
}

// Settings without our hooks. Groups and events that only had our hooks go too.
function removeHooks(settings) {
  const out = { ...settings };
  if (!out.hooks || typeof out.hooks !== 'object' || Array.isArray(out.hooks)) return out;
  const hooks = {};
  for (const [event, groups] of Object.entries(out.hooks)) {
    if (!Array.isArray(groups)) {
      hooks[event] = groups;
      continue;
    }
    const kept = [];
    for (const g of groups) {
      if (!g || !Array.isArray(g.hooks) || !g.hooks.some(isOurs)) {
        kept.push(g);
        continue;
      }
      const rest = g.hooks.filter((h) => !isOurs(h));
      if (rest.length) kept.push({ ...g, hooks: rest });
    }
    if (kept.length) hooks[event] = kept;
  }
  if (Object.keys(hooks).length) out.hooks = hooks;
  else delete out.hooks;
  return out;
}

// Settings with our hooks on each event, and no older copies of them.
function addHooks(settings, command) {
  const out = removeHooks(settings);
  const hooks = { ...(out.hooks || {}) };
  const entry = { type: 'command', command, timeout: TIMEOUT_S };
  for (const event of [...TOOL_EVENTS, ...OTHER_EVENTS]) {
    const group = TOOL_EVENTS.includes(event) ? { matcher: '*', hooks: [entry] } : { hooks: [entry] };
    hooks[event] = [...(Array.isArray(hooks[event]) ? hooks[event] : []), group];
  }
  out.hooks = hooks;
  return out;
}

function readSettings(file) {
  if (!fs.existsSync(file)) return {};
  const data = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (!data || typeof data !== 'object' || Array.isArray(data)) throw new Error(`${file} is not a JSON object`);
  return data;
}

// Write through a symlink (for dotfile setups), keep the file mode.
function writeSettings(file, data) {
  let target = file;
  let mode = 0o644;
  if (fs.existsSync(file)) {
    target = fs.realpathSync(file);
    mode = fs.statSync(target).mode & 0o777;
    fs.copyFileSync(target, `${file}.vscode-window-manager.bak`);
  } else {
    fs.mkdirSync(path.dirname(file), { recursive: true });
  }
  const tmp = `${target}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(data, null, 2) + '\n', { mode });
  fs.renameSync(tmp, target);
}

function main(args) {
  const [action, node, script] = args;
  const file = settingsFile();
  const before = readSettings(file);
  let after;
  if (action === 'add' && node && script) {
    after = addHooks(before, hookCommand(node, script));
  } else if (action === 'remove') {
    after = removeHooks(before);
  } else {
    throw new Error('Usage: hooks.js add <node path> <hook script path> | hooks.js remove');
  }
  if (JSON.stringify(after) === JSON.stringify(before)) {
    console.log(`No hook changes needed in ${file}`);
    return;
  }
  writeSettings(file, after);
  console.log(`${action === 'add' ? 'Added hooks to' : 'Removed hooks from'} ${file}`);
}

if (require.main === module) {
  try {
    main(process.argv.slice(2));
  } catch (err) {
    console.error(`Error: ${err.message}`);
    process.exit(1);
  }
}

module.exports = { TOOL_EVENTS, OTHER_EVENTS, shellQuote, hookCommand, isOurs, addHooks, removeHooks, main };
