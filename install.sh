#!/bin/bash
# Installs VSCode Window Manager: the bar app, the VSCode extension and the
# Claude Code hooks. Run it again to update.
#
# Options (environment variables):
#   APP_DIR  where the app goes. Default: /Applications, or ~/Applications
#            if /Applications is not writable.
#   NODE     the Node.js that runs the Claude Code hook. Default: node on PATH.
#   SIGN_ID  the code signing identity. Default: the first one found, else ad hoc.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
. "$ROOT/scripts/common.sh"

[ "$(uname -s)" = Darwin ] || fail "This runs on macOS only."
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ] || fail "This needs macOS 14 or later."
xcrun --find swiftc >/dev/null 2>&1 || fail "This needs the Xcode Command Line Tools. Run: xcode-select --install"

NODE="${NODE:-$(command -v node || true)}"
[ -n "$NODE" ] && [ -x "$NODE" ] || fail "This needs Node.js. Install it, or set NODE=/path/to/node."
NODE="$(abs_path "$NODE")"

CODE="$(find_code)"
[ -n "$CODE" ] || fail "This needs Visual Studio Code. Install it, then run this again."

if [ -z "${APP_DIR:-}" ]; then
  if [ -w /Applications ]; then APP_DIR=/Applications; else APP_DIR="$HOME/Applications"; fi
fi
mkdir -p "$APP_DIR"
APP_DIR="$(cd "$APP_DIR" && pwd)"
APP="$APP_DIR/$APP_NAME"

say "Building the bar app"
"$ROOT/mac/build.sh" >/dev/null

say "Packaging the VSCode extension"
VSIX="$("$ROOT/scripts/package-extension.sh")"

say "Installing the app to $APP_DIR"
quit_app
rm -rf "$APP"
ditto "$ROOT/build/$APP_NAME" "$APP"

say "Installing the VSCode extension"
# Show VSCode's output only if it fails. It prints Node warnings otherwise.
if ! out="$("$CODE" --install-extension "$VSIX" --force 2>&1)"; then
  printf '%s\n' "$out" >&2
  fail "VSCode did not install the extension."
fi

say "Adding the Claude Code hooks"
"$NODE" "$ROOT/scripts/hooks.js" add "$NODE" "$APP/Contents/Resources/hook/claude-status.js"

open "$APP"

cat <<EOF

Done. Next:
  1. If macOS asks, allow Accessibility for VSCode Window Manager.
     (System Settings > Privacy & Security > Accessibility)
  2. Quit and re-open VSCode.
  3. Optional: in the bar settings, turn on "Open at login".
EOF
