# VSCode Window Manager

If you, like me, would prefer to keep using VSCode in an age of agentic AI tooling.

VSCode Window Manager is a tab bar app for macOS that gathers your open VSCode windows letting you quickly see their working state and switch between them. Featuring built in support for Claude Code.

https://github.com/user-attachments/assets/ce16364b-daf0-4db4-b90f-fe83bfc22365

> **Live Claude Code status.** Each tab shows what Claude Code is doing in that window, as it happens: **working**, **needs you** (a permission prompt or a question), or **done**.

- One tab per VSCode window, with its git branch, changed files and Claude status. Choose in the settings: a bar across the top of the screen, or a side bar on the left. The branch, changed files and status can be hidden.
- Click a tab to bring that window to the front.
- New VSCode windows are gathered as soon as they open.
- Global shortcut to bring the manager to the front.
- Minimising hides all VSCode windows at once.
- Drag tabs to reorder them, or give them colors so they're easier to find.
- Automatically close idle VSCode windows to free system memory.
- The bar and its VSCode windows move as one window. Drag, resize or tile it.

## Requirements

- macOS 14 or later
- [Visual Studio Code](https://code.visualstudio.com)
- [Claude Code](https://claude.com/claude-code)
- [Node.js](https://nodejs.org). It runs the Claude Code hook.
- Xcode Command Line Tools: `xcode-select --install`

## Install

From the folder with this README:

```sh
./install.sh
```

Then:

1. If macOS asks, allow Accessibility for **VSCode Window Manager**. The bar needs it to move and raise VSCode windows.
2. Reload each open VSCode window: **Cmd+Shift+P** > **Developer: Reload Window**.
3. Optional: click the gear in the bar and turn on **Open at login**.

To update, get the new code and run `./install.sh` again.

The installer:

- builds the bar app and copies it to `/Applications`,
- installs the VSCode extension,
- adds the status hooks to `~/.claude/settings.json`. It keeps your other hooks and saves a backup next to the file.

Options:

| Variable  | Use                                                                                      |
| --------- | ---------------------------------------------------------------------------------------- |
| `APP_DIR` | Install the app to another folder. Example: `APP_DIR=~/Applications ./install.sh`        |
| `NODE`    | Use a specific Node.js for the hook. Example: `NODE=/opt/homebrew/bin/node ./install.sh` |
| `SIGN_ID` | Use a specific code signing identity.                                                    |

## Uninstall

```sh
./uninstall.sh
```

This removes the app, the VSCode extension, the status hooks, and the saved settings. Your other Claude Code hooks stay.

## Troubleshooting

- **The bar shows "Allow Accessibility".** Open System Settings > Privacy & Security > Accessibility and turn on VSCode Window Manager.
- **macOS asks for Accessibility after each install.** You have no code signing identity, so the app is signed ad hoc. Add a free Apple Development certificate in Xcode (Settings > Accounts), then install again.
- **A row shows no status.** Send that Claude session a new message. It sends its status on its next action.

## How it works

- The VSCode extension writes each window's folders to `~/.claude/window-status/windows/`, with when something last changed in it and if a terminal command runs. It never stores file contents or commands.
- A Claude Code hook writes each session's state to `~/.claude/window-status/sessions/`. It stores session ids, folder paths and state only. It never stores prompts or tool input.
- The bar reads both folders once per second. It matches each Claude tab to the window that runs it, and each other session to the window that holds its folder.

## Development

```sh
npm test                           # run the tests
mac/build.sh                       # build "build/VSCode Window Manager.app"
scripts/package-extension.sh       # build the .vsix in build/
```

## License

[MIT](LICENSE)
