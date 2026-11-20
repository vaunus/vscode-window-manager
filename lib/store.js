'use strict';

// Status dir paths, atomic read/write, pruning.

const fs = require('fs');
const os = require('os');
const path = require('path');

const DAY_MS = 24 * 60 * 60 * 1000;
// No path separators, and no leading dot (blocks "." and "..").
const SAFE_ID = /^[A-Za-z0-9_-][A-Za-z0-9._-]{0,199}$/;

function statusDir() {
  return process.env.VSCODE_WINDOW_MANAGER_DIR || path.join(os.homedir(), '.claude', 'window-status');
}

function paths(base = statusDir()) {
  return {
    base,
    sessions: path.join(base, 'sessions'),
    windows: path.join(base, 'windows'),
    // The bar asks a window to show a Claude tab: requests/<window id>.json.
    requests: path.join(base, 'requests'),
  };
}

function ensureDirs(p) {
  fs.mkdirSync(p.sessions, { recursive: true, mode: 0o700 });
  fs.mkdirSync(p.windows, { recursive: true, mode: 0o700 });
  fs.mkdirSync(p.requests, { recursive: true, mode: 0o700 });
}

function isSafeId(id) {
  return typeof id === 'string' && SAFE_ID.test(id);
}

function idFile(dir, id) {
  if (!isSafeId(id)) throw new Error(`Unsafe id: ${JSON.stringify(id)}`);
  return path.join(dir, `${id}.json`);
}

function sessionFile(p, id) {
  return idFile(p.sessions, id);
}

function windowFile(p, id) {
  return idFile(p.windows, id);
}

function requestFile(p, id) {
  return idFile(p.requests, id);
}

function removeFile(file) {
  try {
    fs.unlinkSync(file);
    return true;
  } catch {
    return false;
  }
}

// Write a temp file in the same dir, then rename over the target.
function writeJsonAtomic(file, data) {
  const suffix = `${process.pid}.${Date.now()}.${Math.random().toString(36).slice(2)}`;
  const tmp = `${file}.${suffix}.tmp`;
  try {
    fs.writeFileSync(tmp, JSON.stringify(data, null, 2) + '\n', { mode: 0o600 });
    fs.renameSync(tmp, file);
  } catch (err) {
    removeFile(tmp);
    throw err;
  }
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
}

// Parsed *.json records in a dir. The id comes from the file name.
function readAll(dir, idKey) {
  let names;
  try {
    names = fs.readdirSync(dir);
  } catch {
    return [];
  }
  const out = [];
  for (const name of names) {
    if (!name.endsWith('.json')) continue;
    const id = name.slice(0, -'.json'.length);
    if (!isSafeId(id)) continue;
    const data = readJson(path.join(dir, name));
    if (data && typeof data === 'object' && !Array.isArray(data)) {
      out.push({ ...data, [idKey]: id });
    }
  }
  return out;
}

function readSessions(p) {
  return readAll(p.sessions, 'sessionId');
}

function readWindows(p) {
  return readAll(p.windows, 'id');
}

function isPidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    // EPERM means the process exists but belongs to someone else.
    return err.code !== 'ESRCH';
  }
}

// Delete window files whose extension host is gone, and their requests.
// Returns removed ids.
function pruneDeadWindows(p, alive = isPidAlive) {
  const removed = [];
  for (const win of readWindows(p)) {
    if (alive(win.pid)) continue;
    removeFile(requestFile(p, win.id));
    if (removeFile(windowFile(p, win.id))) removed.push(win.id);
  }
  return removed;
}

// Delete files older than maxAgeMs (by mtime). Covers stale temp files too.
function pruneOldFiles(dir, maxAgeMs, now = Date.now()) {
  let names;
  try {
    names = fs.readdirSync(dir);
  } catch {
    return [];
  }
  const removed = [];
  for (const name of names) {
    const file = path.join(dir, name);
    try {
      const st = fs.statSync(file);
      if (st.isFile() && now - st.mtimeMs > maxAgeMs && removeFile(file)) removed.push(name);
    } catch {
      // File vanished or unreadable: skip it.
    }
  }
  return removed;
}

function pruneOldSessions(p, maxAgeMs = DAY_MS, now = Date.now()) {
  return pruneOldFiles(p.sessions, maxAgeMs, now);
}

module.exports = {
  DAY_MS,
  paths,
  ensureDirs,
  isSafeId,
  sessionFile,
  windowFile,
  requestFile,
  removeFile,
  writeJsonAtomic,
  readJson,
  readSessions,
  readWindows,
  isPidAlive,
  pruneDeadWindows,
  pruneOldSessions,
};
