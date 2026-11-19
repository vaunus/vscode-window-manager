# Shared names and helpers for the build, install and uninstall scripts.

APP_NAME="VSCode Window Manager.app"
APP_BIN="VSCodeWindowManager"
BUNDLE_ID="local.vscode-window-manager"
EXT_ID="local.vscode-window-manager"
STATUS_DIR="$HOME/.claude/window-status"

say() { printf '==> %s\n' "$*"; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

# Absolute path of a file or folder that exists.
abs_path() { (cd "$(dirname "$1")" && printf '%s/%s\n' "$(pwd)" "$(basename "$1")"); }

# The VSCode command line tool: "code" on PATH, else the one inside VSCode.
# Prints nothing if VSCode is not found.
find_code() {
  if command -v code >/dev/null 2>&1; then
    command -v code
    return 0
  fi
  local app cli
  app="$(mdfind "kMDItemCFBundleIdentifier == 'com.microsoft.VSCode'" 2>/dev/null | head -n 1 || true)"
  [ -n "$app" ] || app="/Applications/Visual Studio Code.app"
  cli="$app/Contents/Resources/app/bin/code"
  if [ -x "$cli" ]; then printf '%s\n' "$cli"; fi
  return 0
}

# Quit the bar app and wait until it is gone.
quit_app() {
  pkill -f "MacOS/$APP_BIN" 2>/dev/null || return 0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "MacOS/$APP_BIN" >/dev/null || return 0
    sleep 0.3
  done
}
