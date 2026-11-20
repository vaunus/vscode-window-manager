'use strict';

// True for Claude Code in a terminal. The bar shows Claude's own status for
// it, so it does not show the window as "working" while it runs.
function isClaudeCommand(commandLine) {
  return typeof commandLine === 'string' && /^\s*(\S*\/)?claude(\s|$)/.test(commandLine);
}

module.exports = { isClaudeCommand };
