# VSCode Window Manager

If you, like me, would prefer to keep using VSCode in an age of agentic AI tooling.

VSCode Window Manager is a side bar app for macOS that gathers your open VSCode windows letting you quickly see their working state and switch between them. Featuring built in support for the Claude VSCode extension.

https://github.com/user-attachments/assets/b3a2af99-814f-4506-a58a-b553eb49095d

> **Live Claude Code status.** Each row shows what Claude Code is doing in that window, as it happens: **working**, **needs you** (a permission prompt or a question), or **done**.

- One row per VS Code window, with its git branch.
- Click a row to bring that window to the front, sized to fill the screen next to the bar.
- Pick the bar's screen in the settings. VS Code windows go to the same screen.
- Drag rows to reorder them, and give them colors.
- New VS Code windows go next to the bar as soon as they open.
- VS Code windows stay next to the bar. If you move or resize one, it goes back when you release the mouse. Full screen still works.
- A global shortcut brings VS Code and the bar to the front.
- Close and minimize buttons at the top of the bar, in place of VS Code's own. Minimize hides all VS Code windows at once, with no animation. Close quits the bar and leaves VS Code open.
- **Add window**, under the rows, opens a new VS Code window. It shows at the top of the bar as **Empty window** until you pick a folder on its Welcome page. Each empty window gets its own row.
- To close a VS Code window, put the mouse on its row and click the **x**, then click the red **Close** button. Or right-click the row and choose **Close Window**. If files are not saved, the window comes to the front and VS Code asks what to do.

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

1. If macOS asks, allow Accessibility for **VS Code Window Manager**. The bar needs it to move and raise VS Code windows.
2. Reload each open VS Code window: **Cmd+Shift+P** > **Developer: Reload Window**.
3. Optional: click the gear in the bar and turn on **Open at login**.

To update, get the new code and run `./install.sh` again.

The installer:

- builds the bar app and copies it to `/Applications`,
- installs the VS Code extension,
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

This removes the app, the VS Code extension, the status hooks, and the saved settings. Your other Claude Code hooks stay.

## Troubleshooting

- **The bar shows "Allow Accessibility".** Open System Settings > Privacy & Security > Accessibility and turn on VS Code Window Manager.
- **macOS asks for Accessibility after each install.** You have no code signing identity, so the app is signed ad hoc. Add a free Apple Development certificate in Xcode (Settings > Accounts), then install again.
- **A row shows no status.** Send that Claude session a new message. It sends its status on its next action.

## How it works

- The VS Code extension writes each window's folders to `~/.claude/window-status/windows/`.
- A Claude Code hook writes each session's state to `~/.claude/window-status/sessions/`. It stores session ids, folder paths and state only. It never stores prompts or tool input.
- The bar reads both folders once per second and matches each session to the window that holds its folder.

## Development

```sh
npm test                           # run the tests
mac/build.sh                       # build "build/VS Code Window Manager.app"
scripts/package-extension.sh       # build the .vsix in build/
```

## License

[MIT](LICENSE)
