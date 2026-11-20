"use strict";

// Claude Code hook. Records session state for the VSCode Window Manager bar.
// Rules: never print to stdout, never throw, always exit 0.
// Output on PreToolUse or PermissionRequest could approve or deny tools.

const STDIN_TIMEOUT_MS = 3000;
const PS_TIMEOUT_MS = 1000;

function done() {
  process.exit(0);
}

process.on("uncaughtException", done);
process.on("unhandledRejection", done);

// The pid of the VSCode window (extension host) that runs this Claude
// tab, from the process tree. Null if not found.
function findHost() {
  const { parsePsTable, findHostPid } = require("../lib/state");
  const mainPid = Number(process.env.VSCODE_PID);
  if (!Number.isInteger(mainPid) || mainPid <= 1) return null;
  try {
    const out = require("child_process").execFileSync("/bin/ps", ["-A", "-o", "pid=,ppid="], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: PS_TIMEOUT_MS,
    });
    return findHostPid(parsePsTable(out), process.pid, mainPid);
  } catch {
    return null;
  }
}

// How Claude Code runs, and for a Claude tab the window that runs it. The
// process tree stays the same while the claude process runs. A new claude
// process (a resume, a reload) starts with SessionStart, so look again then.
function hostInfo(prev, event) {
  const { TAB_ENTRYPOINT } = require("../lib/state");
  const entrypoint = process.env.CLAUDE_CODE_ENTRYPOINT || null;
  if (entrypoint !== TAB_ENTRYPOINT) return { entrypoint, hostPid: null };
  const known = event !== "SessionStart" && prev && Number.isInteger(prev.hostPid);
  return { entrypoint, hostPid: known ? prev.hostPid : findHost() };
}

function handle(text) {
  const {
    changeFromHook,
    buildSession,
    shouldSkipWrite,
  } = require("../lib/state");
  const store = require("../lib/store");

  if (!text.trim()) return;
  const input = JSON.parse(text);
  const ch = changeFromHook(input);
  if (!ch || !store.isSafeId(input.session_id)) return;

  const p = store.paths();
  const file = store.sessionFile(p, input.session_id);

  if (ch.action === "delete") {
    store.removeFile(file);
    return;
  }

  const prev = store.readJson(file);
  const next = buildSession(
    input,
    ch,
    process.env.CLAUDE_PROJECT_DIR,
    undefined,
    hostInfo(prev, input.hook_event_name),
  );
  if (!next) return;
  if (shouldSkipWrite(prev, next, undefined, input.hook_event_name)) return;

  store.ensureDirs(p);
  store.writeJsonAtomic(file, next);
}

function finish(chunks) {
  try {
    handle(Buffer.concat(chunks).toString("utf8"));
  } catch {
    // Bad input or a write error: ignore it.
  }
  done();
}

function main() {
  if (process.stdin.isTTY) done();
  const chunks = [];
  setTimeout(() => finish(chunks), STDIN_TIMEOUT_MS);
  process.stdin.on("data", (c) => chunks.push(c));
  process.stdin.on("end", () => finish(chunks));
  process.stdin.on("error", done);
}

main();
