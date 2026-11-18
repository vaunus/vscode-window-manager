#!/bin/bash
# Builds and signs "build/VS Code Window Manager.app".
# The Claude Code hook (hook/ and lib/) goes inside the app, in Contents/Resources,
# so the installed hook does not depend on where this repo is.
# Signs with the first code signing identity, so macOS keeps the Accessibility
# permission after a rebuild. Set SIGN_ID to pick one. With no identity it signs
# ad hoc, and macOS asks for the permission again after each install.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/common.sh"

APP="$ROOT/build/$APP_NAME"
RES="$APP/Contents/Resources"
VERSION="$(plutil -extract version raw -o - "$ROOT/package.json")"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RES/hook" "$RES/lib"
cp "$ROOT/mac/Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
cp "$ROOT/hook/claude-status.js" "$RES/hook/"
cp "$ROOT/lib/state.js" "$ROOT/lib/store.js" "$RES/lib/"

# -no_adhoc_codesign: codesign signs the whole app below.
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" -Xlinker -no_adhoc_codesign \
  -framework AppKit -framework SwiftUI -framework ApplicationServices -framework ServiceManagement \
  "$ROOT"/mac/Sources/*.swift -o "$APP/Contents/MacOS/$APP_BIN"

ID="${SIGN_ID:-$(security find-identity -v -p codesigning | awk '/^ *[0-9]+\) /{print $2; exit}')}"
codesign --force --sign "${ID:--}" "$APP"
echo "Built $APP"
