'use strict';

// Claude Code hook. Records session state for the VS Code Window Manager bar.
// Rules: never print to stdout, never throw, always exit 0.
// Output on PreToolUse or PermissionRequest could approve or deny tools.

const STDIN_TIMEOUT_MS = 3000;

function done() {
  process.exit(0);
}

process.on('uncaughtException', done);
process.on('unhandledRejection', done);

function handle(text) {
  const { changeFromHook, buildSession, shouldSkipWrite } = require('../lib/state');
  const store = require('../lib/store');

  if (!text.trim()) return;
  const input = JSON.parse(text);
  const ch = changeFromHook(input);
  if (!ch || !store.isSafeId(input.session_id)) return;

  const p = store.paths();
  const file = store.sessionFile(p, input.session_id);

  if (ch.action === 'delete') {
    store.removeFile(file);
    return;
  }

  const next = buildSession(input, ch, process.env.CLAUDE_PROJECT_DIR);
  if (!next) return;
  if (shouldSkipWrite(store.readJson(file), next, undefined, input.hook_event_name)) return;

  store.ensureDirs(p);
  store.writeJsonAtomic(file, next);
}

function finish(chunks) {
  try {
    handle(Buffer.concat(chunks).toString('utf8'));
  } catch {
    // Bad input or a write error: ignore it.
  }
  done();
}

function main() {
  if (process.stdin.isTTY) done();
  const chunks = [];
  setTimeout(() => finish(chunks), STDIN_TIMEOUT_MS);
  process.stdin.on('data', (c) => chunks.push(c));
  process.stdin.on('end', () => finish(chunks));
  process.stdin.on('error', done);
}

main();
