'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { isClaudeCommand } = require('../lib/activity');

test('claude and its options or a path to it: Claude Code', () => {
  for (const c of ['claude', 'claude --resume', '  claude -c', '/usr/local/bin/claude', '~/.local/bin/claude chat']) {
    assert.equal(isClaudeCommand(c), true, c);
  }
});

test('other commands: not Claude Code', () => {
  for (const c of ['pnpm dev', 'claude-code-router start', 'echo claude', 'vim claude.md', '', null, undefined]) {
    assert.equal(isClaudeCommand(c), false, String(c));
  }
});
