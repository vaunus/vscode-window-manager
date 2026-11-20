# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
npm test                                   # all tests (node --test, no npm dependencies)
node --test test/state.test.js             # one test file
node --test --test-name-pattern="idle" test/state.test.js   # tests whose name matches
mac/build.sh                               # build and sign "build/VSCode Window Manager.app"
scripts/package-extension.sh               # build build/<name>-<version>.vsix (a plain zip, no vsce)
./install.sh                               # build both, install app + extension, add Claude Code hooks
./uninstall.sh                             # remove app, extension, hooks, saved settings, status files
```

There is no linter and no Swift test suite. The Swift app builds with one `swiftc` call in `mac/build.sh` (no Xcode project, no SwiftPM). To try a change end to end, run `./install.sh`, then reload each VSCode window (Developer: Reload Window).

`VSCODE_WINDOW_MANAGER_DIR` overrides the status folder (default `~/.claude/window-status`) in the JS code and in the Swift app. The tests use it with a temp folder.

## Architecture

Three separate programs talk only through JSON files in the status folder. Nothing calls anything else directly.

1. **VSCode extension** (`extension.js` + `lib/`). One copy runs in each VSCode window. It writes `windows/<pid>-<sessionId>.json`: folders, workspace file, title bar colors, git change count, unsaved/busy/running flags, `usedAt`/`activeAt`/`focusedAt` times. It removes its file and the sessions only it holds on `deactivate`. It watches `requests/` too: when the bar writes `requests/<its id>.json`, it shows that Claude tab (`showRequestedTab`).
2. **Claude Code hook** (`hook/claude-status.js`). Claude Code runs it on each hook event. It maps the event to a state (`lib/state.js` `changeFromHook`) and writes `sessions/<session_id>.json`. For a tab of the Claude extension (`CLAUDE_CODE_ENTRYPOINT=claude-vscode`) it also saves `hostPid`, the pid of the window's extension host. It finds it with one `ps` call per claude process. `scripts/hooks.js` adds and removes it in `~/.claude/settings.json`. It finds its own hooks by the `claude-status.js` file name.
3. **macOS bar app** (`mac/Sources/*.swift`, SwiftUI + AppKit). It reads both folders once per second (`loadRows` in `Status.swift`). It matches a Claude tab to the window whose `pid` is its `hostPid`, and other sessions to the window whose folder holds the session's `projectDir`/`cwd` (longest folder match). A click on a "needs you" row of a Claude tab writes `requests/<window id>.json` (`requestTab`). It moves, raises, closes and hides VSCode windows with the Accessibility API (`Windows.swift`).

### Rules that span files

- **The JSON files are a contract between JS and Swift.** A new or renamed field in `ownRecord()` (`extension.js`) or `buildSession()` (`lib/state.js`) must also change the parsing in `loadRows()` (`Status.swift`). `Status.swift` repeats rules from `lib/state.js` (host pid match, folder match, state order). Keep them the same. The bar writes `requests/` and the extension reads it.
- **Showing a Claude tab uses `claude-vscode.primaryEditor.open`**, which is not a public API of the Claude extension. For a session with no tab, it opens a new tab and starts a second Claude on the same chat. So `canShowTab` (`lib/state.js`) allows only a fresh request for a tab that runs in the same window.
- **The hook must never print to stdout, never throw, and always exit 0.** Output on `PreToolUse` or `PermissionRequest` can approve or deny tools. `test/hook.test.js` runs the real script and checks that stdout and stderr are empty.
- **The hook runs from inside the app bundle**, not from this repo. `mac/build.sh` copies `hook/claude-status.js`, `lib/state.js` and `lib/store.js` into `Contents/Resources`. If the hook needs another `lib/` file, add it to that `cp` line.
- **The extension ships with no `node_modules`.** `scripts/package-extension.sh` copies only `package.json`, `extension.js` and `lib/`. Use Node built-ins only.
- **Keep the VSCode API out of `lib/`.** `extension.js` reads VSCode state and passes plain data to `lib/theme.js`, `lib/modal.js`, `lib/git.js`, `lib/activity.js`, so the tests run without VSCode.
- **Write files with `store.writeJsonAtomic`** (temp file, then rename). The bar watches the `windows/` file list, and a rename is what makes it redraw at once. Ids go through `store.isSafeId` before they become file names.
- **Privacy:** session files hold only ids, paths and state. Window files hold no file contents or commands. Do not add prompts, tool input or command text to them.
- **Saved names in the Swift app must not change.** The row color names in `Settings.swift` and the `UserDefaults` keys (bundle id `local.vscode-window-manager`) are saved on the user's Mac.

## Style

- Write "VSCode", not "VS Code".
- Comments use short, plain sentences that say why. Follow the style already in the file.
- Commit messages use `feat:`, `fix:` or `chore:` prefixes.
