#!/bin/bash
# Removes VSCode Window Manager: the bar app, the VSCode extension, the
# Claude Code hooks, and the saved settings and status files.
# Other Claude Code hooks and settings stay. Set APP_DIR if you installed
# the app somewhere other than /Applications or ~/Applications.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
. "$ROOT/scripts/common.sh"

say "Quitting the bar app"
quit_app

for dir in "${APP_DIR:-}" /Applications "$HOME/Applications"; do
  [ -n "$dir" ] && [ -d "$dir/$APP_NAME" ] || continue
  say "Removing $dir/$APP_NAME"
  "$dir/$APP_NAME/Contents/MacOS/$APP_BIN" --remove-login-item 2>/dev/null || true
  rm -rf "${dir:?}/$APP_NAME"
done

CODE="$(find_code)"
if [ -n "$CODE" ]; then
  say "Removing the VSCode extension"
  "$CODE" --uninstall-extension "$EXT_ID" >/dev/null 2>&1 || true
fi

NODE="${NODE:-$(command -v node || true)}"
if [ -n "$NODE" ]; then
  say "Removing the Claude Code hooks"
  "$NODE" "$ROOT/scripts/hooks.js" remove
else
  echo "Node.js not found. Remove the claude-status.js hooks from ~/.claude/settings.json by hand."
fi

say "Removing saved settings and status files"
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
rm -rf "$STATUS_DIR"
tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true

echo
echo "Done. Reload open VSCode windows to stop the extension in them."
