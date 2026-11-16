# claude-window-anchor

Sends Claude a one-word prompt at 06:00 every weekday so the usage window
starts before the workday does. Works on macOS and Windows.

Both versions do the same thing: run `claude -p` on Haiku with no tools, MCP
servers or settings, wait for the network, retry up to 4 times, and show a
notification if they fail or the login has expired.

| | macOS | Windows |
|---|---|---|
| Script | `start-window.sh` | `windows/start-window.ps1` |
| Scheduler | `launchd/com.alberto.claude-window.plist` (launchd) | `windows/install-task.ps1` (Task Scheduler) |
| Log | `~/Library/Logs/claude-window.log` | `%LOCALAPPDATA%\claude-window\claude-window.log` |
| Token file | `~/.claude-trigger/oauth-token` | `%USERPROFILE%\.claude-trigger\oauth-token` |

Exit codes (both platforms): `0` anchored, `1` gave up after 4 attempts,
`2` login expired or token invalid.

---

## Installing with an AI agent

This section is written for a coding agent (Claude Code or similar) asked to
"install this". Follow it top to bottom. Every step is safe to re-run.

### Rules

- **Never read, print, log, copy or commit the token.** Only the user handles
  it (step 4). You may check that the file exists and has the right shape
  without printing it.
- **Do not commit the path edits from step 2.** They are local to this machine.
  The repo keeps the original author's paths.
- Ask the user before changing the schedule time if they haven't given one.
- Don't stop at "installed": finish with the verification in step 5 and report
  the exit code and the last log lines.

### 1. Check prerequisites

macOS:

```bash
command -v claude && claude --version   # Claude Code must be installed
command -v git
```

Windows (PowerShell):

```powershell
Get-Command claude, git
```

If `claude` is missing, stop and tell the user to install Claude Code first.

### 2. Get the repo into place

The repo must live at `~/.claude-trigger` (macOS) or
`%USERPROFILE%\.claude-trigger` (Windows). If that folder already exists and
is this repo, run `git pull` in it instead of cloning.

macOS:

```bash
REPO="$HOME/.claude-trigger"
[ -d "$REPO/.git" ] && git -C "$REPO" pull --ff-only \
  || git clone git@github.com:alberto-van/claude-window-anchor.git "$REPO"
```

On macOS, `start-window.sh` and the plist hard-code the author's home folder
(`/Users/ordenador12`) and `claude` at `/opt/homebrew/bin/claude`. Rewrite them
for this machine. The plist is written straight to `~/Library/LaunchAgents`,
so the repo copy stays untouched:

```bash
REPO="$HOME/.claude-trigger"
CLAUDE_BIN="$(command -v claude)"
sed -i '' -e "s#/Users/ordenador12#$HOME#g" -e "s#/opt/homebrew/bin/claude#$CLAUDE_BIN#g" \
  "$REPO/start-window.sh"
sed -e "s#/Users/ordenador12#$HOME#g" \
  "$REPO/launchd/com.alberto.claude-window.plist" \
  > "$HOME/Library/LaunchAgents/com.alberto.claude-window.plist"
plutil -lint "$HOME/Library/LaunchAgents/com.alberto.claude-window.plist"
chmod +x "$REPO/start-window.sh"
```

Line 2 of `start-window.sh` sets `PATH` and includes folders from the author's
machine. They are harmless if missing; only `claude`'s own folder matters, and
the script calls `claude` by its full path anyway.

Windows:

```powershell
$Repo = "$HOME\.claude-trigger"
if (Test-Path "$Repo\.git") { git -C $Repo pull --ff-only }
else { git clone git@github.com:alberto-van/claude-window-anchor.git $Repo }
```

The Windows scripts use no hard-coded paths.

### 3. Register the schedule

macOS (`bootout` first so re-running replaces an old copy):

```bash
PLIST="$HOME/Library/LaunchAgents/com.alberto.claude-window.plist"
launchctl bootout "gui/$(id -u)/com.alberto.claude-window" 2>/dev/null
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl print "gui/$(id -u)/com.alberto.claude-window" | grep -E 'state|path'
```

To change the time, edit the `Hour` and `Minute` values in that plist (there
is one block per weekday), then repeat the `bootout` and `bootstrap` lines.

Windows (`-Force` inside the script replaces an existing task):

```powershell
powershell -ExecutionPolicy Bypass -File "$HOME\.claude-trigger\windows\install-task.ps1"
Get-ScheduledTask -TaskName 'Claude window anchor' | Select-Object TaskName, State
```

For another time, add `-At 07:30`.

### 4. Token (the user does this)

Without a token file the scripts use the interactive `claude auth login`,
which expires every few weeks. With one, they keep working for a year.

Check whether a token file already exists, without reading it:

```bash
test -s "$HOME/.claude-trigger/oauth-token" && echo present || echo missing
```

```powershell
if ((Test-Path "$HOME\.claude-trigger\oauth-token") -and (Get-Item "$HOME\.claude-trigger\oauth-token").Length -gt 0) { 'present' } else { 'missing' }
```

If it is missing, ask the user to run these themselves. Do not run them
for the user, and do not ask them to paste the token into the chat.

1. Run `claude setup-token` and copy the token it prints.
2. Save it:
   - macOS: `pbpaste > ~/.claude-trigger/oauth-token && chmod 600 ~/.claude-trigger/oauth-token`
   - Windows: `Get-Clipboard | Set-Content -NoNewline "$HOME\.claude-trigger\oauth-token"`

A line break inside the token, from the terminal wrapping it, is fine: both
scripts strip all whitespace.

To check it without printing it (macOS), the stripped length should be
around 108 and it should start with `sk-ant-oat`:

```bash
t="$(tr -d '[:space:]' < ~/.claude-trigger/oauth-token)"; echo "${#t} ${t:0:10}"
```

### 5. Verify

Run the script once by hand. It sends one real prompt to Haiku.

macOS:

```bash
~/.claude-trigger/start-window.sh; echo "exit=$?"
tail -3 ~/Library/Logs/claude-window.log
```

Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.claude-trigger\windows\start-window.ps1"; "exit=$LASTEXITCODE"
Get-Content "$env:LOCALAPPDATA\claude-window\claude-window.log" -Tail 3
```

Success is `exit=0` and a log line ending `anchored -> READY`. On a weekend
the script logs `skipping` and exits 0 without calling Claude; that is
expected, so say so rather than calling it verified.

On Windows, also check that the scheduler can start it:

```powershell
Start-ScheduledTask -TaskName 'Claude window anchor'
Start-Sleep 30; Get-ScheduledTaskInfo -TaskName 'Claude window anchor' | Select-Object LastRunTime, LastTaskResult
```

`LastTaskResult` 0 means success; 267009 means it is still running.

### Troubleshooting

| Log says | Cause | Fix |
|---|---|---|
| `AUTH EXPIRED`, exit 2 | Token missing, expired or mistyped, or login expired | User redoes step 4 |
| `contains a line break` | Old copy of the Windows script | `git pull` |
| `claude not found`, exit 1 | Claude Code not installed or not on PATH | Install it, or fix `CLAUDE_BIN` in step 2 |
| `timed out after 120s` on every attempt | Claude hangs on start | Run `claude -p hi` by hand to see why |
| `network still unreachable` | No connection to api.anthropic.com | Check network, VPN or proxy |
| Nothing in the log at 06:00 (macOS) | Agent not loaded | Re-run step 3 and check `launchctl print` |

### Uninstall

macOS:

```bash
launchctl bootout "gui/$(id -u)/com.alberto.claude-window"
rm ~/Library/LaunchAgents/com.alberto.claude-window.plist
```

Windows:

```powershell
powershell -ExecutionPolicy Bypass -File "$HOME\.claude-trigger\windows\install-task.ps1" -Uninstall
```

The repo folder, token and log are left in place; delete them by hand if wanted.
