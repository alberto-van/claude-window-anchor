# claude-window-anchor

Sends Claude a one-word prompt at 06:00 every weekday so the usage window
starts before the workday does. Works on macOS and Windows.

Both versions do the same thing: run `claude -p` on Haiku with no tools, MCP
servers or settings, wait for the network, retry up to 4 times, and show a
notification if they fail or the login has expired.

| | macOS | Windows |
|---|---|---|
| Script | `start-window.sh` | `windows/start-window.ps1` |
| Scheduler | `launchd/com.alberto.claude-window.plist` | `windows/install-task.ps1` (Task Scheduler) |
| Log | `~/Library/Logs/claude-window.log` | `%LOCALAPPDATA%\claude-window\claude-window.log` |

Clone the repo to `~/.claude-trigger` (macOS) or `%USERPROFILE%\.claude-trigger`
(Windows). Both scripts read the token from `oauth-token` in that folder.

## Token

The scripts read a long-lived token from `oauth-token` in the repo folder.
It is not in this repo (`.gitignore`). Create one with `claude setup-token`,
copy it, then save it:

macOS:

```bash
pbpaste > ~/.claude-trigger/oauth-token && chmod 600 ~/.claude-trigger/oauth-token
```

Windows (PowerShell):

```powershell
Get-Clipboard | Set-Content -NoNewline "$HOME\.claude-trigger\oauth-token"
```

The token lasts a year. Without the file the scripts fall back to the
interactive `claude auth login`, which expires every few weeks.

## Install on macOS

```bash
git clone git@github.com:alberto-van/claude-window-anchor.git ~/.claude-trigger
cp ~/.claude-trigger/launchd/com.alberto.claude-window.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.alberto.claude-window.plist
```

The paths in both files assume the user `ordenador12`. Change them if the
username differs, and check that `claude` is at `/opt/homebrew/bin/claude`.

Test: `~/.claude-trigger/start-window.sh` should log `anchored -> READY` and exit 0.

## Install on Windows

Needs Claude Code installed (native installer or npm). The script looks for
`%USERPROFILE%\.local\bin\claude.exe` first, then `claude` on PATH.

```powershell
git clone git@github.com:alberto-van/claude-window-anchor.git "$HOME\.claude-trigger"
powershell -ExecutionPolicy Bypass -File "$HOME\.claude-trigger\windows\install-task.ps1"
```

This registers a task called **Claude window anchor** for 06:00 Monday to
Friday. It runs as you, only while you're signed in, and if the PC was off or
asleep at 06:00 it runs as soon as it can.

- Other time: add `-At 07:30`
- Remove it: add `-Uninstall`
- Test now: `Start-ScheduledTask -TaskName 'Claude window anchor'`, then check the log

To test the script directly and see its output:

```powershell
powershell -ExecutionPolicy Bypass -File "$HOME\.claude-trigger\windows\start-window.ps1"
```

Exit codes (both platforms): 0 anchored, 1 gave up, 2 login expired.
