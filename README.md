# Claude Code notifications for Windows

Get a Windows toast and a flashing taskbar button when Claude Code finishes a turn or is
waiting on you. Clicking the toast brings the exact VS Code window that session lives in to
the front, switching virtual desktops if needed.

Works with Claude Code in VS Code on Windows 10/11. No extra modules required.

## Install

1. Download or clone this folder.
2. Open a terminal in it and run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install.ps1
   ```

3. Restart Claude Code (or run `/hooks` once inside it) so it loads the new hooks.

You should see a test toast right away. Everything is installed for the current user only:
scripts go to `%USERPROFILE%\.claude\notify`, hooks are merged into
`%USERPROFILE%\.claude\settings.json` (a `settings.json.bak` copy is written first), and a
`claude-notify:` URL protocol is registered under `HKCU`.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
```

Removes the hooks, the protocol registration and the scripts. Other settings are untouched.

## How it works

Three Claude Code hooks are added to your user settings:

| Hook | Script | What it does |
|------|--------|--------------|
| `UserPromptSubmit` | `notify-record.ps1` | Remembers which VS Code window was in the foreground when you sent the prompt. |
| `Stop` | `notify.ps1` | Toast "Finished" and flash that window. |
| `Notification` | `notify.ps1` | Toast with Claude's message (permission prompt, idle) and flash that window. |

Recording the foreground window on each prompt is what makes this precise: it works even
when the same workspace is open in two windows, which is something title or folder matching
cannot tell apart.

Clicking a toast opens a `claude-notify:activate?hwnd=...` link. Windows routes that to
`notify-activate.ps1`, which restores and focuses the window. If the window lives on another
virtual desktop and Windows did not switch on its own, the script moves it to your current
desktop.

All hooks run asynchronously, so they never delay Claude.

## Customising

- **Flash until focused vs. a few blinks:** in `notify-common.ps1`, `Flash()` uses
  `FLASHW_ALL | FLASHW_TIMERNOFG` (flash until the window gets focus). Change `dwFlags` to
  `0x3` and `uCount` to e.g. `5` for a short burst instead.
- **Messages:** edit the `-Message` arguments in `settings.json`, or remove the `Notification`
  hook if you only want the end-of-turn toast.
- **Install location:** `install.ps1 -Dest C:\some\other\folder`.

## Notes

- Hooks run under Windows PowerShell 5.1 (`powershell.exe`), which ships with Windows and has
  the built-in toast API. PowerShell 7 is not required.
- Expect a brief console flicker when clicking a toast; the protocol handler is a hidden
  PowerShell process.
- The toast is attributed to "Windows PowerShell" in the notification centre, since scripts
  cannot register their own app identity without an installer package.
- If nothing appears after installing, run `/hooks` inside Claude Code to reload settings, or
  check `%USERPROFILE%\.claude\settings.json` for a JSON error.
