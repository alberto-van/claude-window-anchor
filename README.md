# claude-window-anchor

Claude's usage limits run in windows that start with your first message.
This sends Claude a one-word prompt at 06:00 every weekday, so the window has
already started when you begin work and resets earlier in the day.

Works on macOS and Windows.

## Will it help you?

Only if both are true:

1. **You regularly hit your Claude usage limit during the workday.** If you
   don't, you don't need this.
2. **Your computer is on or asleep at the set time, with you signed in.** A
   locked screen is fine. If it's shut down overnight, the run happens when
   you turn it on, about when you'd send your first message anyway, so you
   gain nothing.

Sleep needs one more thing, because a sleeping computer doesn't run
scheduled jobs on its own:

- **Windows:** the installer sets the task to wake the PC (`WakeToRun`). This
  only works if wake timers are allowed: *Power Options → Change plan
  settings → Change advanced power settings → Sleep → Allow wake timers →
  Enable*, for both battery and plugged in. Many laptops with Modern Standby
  don't honour wake timers reliably, and on a work PC IT may have them
  turned off.
- **macOS:** launchd doesn't wake the Mac; a missed run happens at the next
  wake. To wake it a couple of minutes early on weekdays (needs an admin
  password, and applies to the whole Mac):

  ```bash
  sudo pmset repeat wakeorpoweron MTWRF 05:58:00
  ```

  Undo with `sudo pmset repeat cancel`. Check with `pmset -g sched`.

To see whether it's actually helping, look at the times in the log: runs at
the set time mean it works; runs at whatever time you opened the laptop mean
it doesn't.

## What it does, and what it touches

Each run executes this, with no tools, MCP servers, plugins or settings loaded:

```
claude -p "Reply with only the word READY. Do not use any tools." --model haiku --max-turns 1
```

It waits for the network, retries up to 4 times, writes a log, and shows a
notification if it fails or your login has expired. That's all. It sends
nothing anywhere except that prompt to Claude, through the official Claude
Code CLI you already have installed.

| | macOS | Windows |
|---|---|---|
| Script | `start-window.sh` | `windows/start-window.ps1` |
| Installer | `install.sh` (launchd job) | `windows/install-task.ps1` (Task Scheduler) |
| Scheduled job | `~/Library/LaunchAgents/local.claude-window-anchor.plist` | Task named `Claude window anchor` |
| Log | `~/Library/Logs/claude-window.log` | `%LOCALAPPDATA%\claude-window\claude-window.log` |
| Token file (optional) | `oauth-token` in the repo folder | `oauth-token` in the repo folder |

The job runs as you, only while you're signed in. No admin rights needed.

Exit codes: `0` anchored, `1` gave up after 4 attempts or `claude` not
found, `2` login expired or token invalid.

## Security notes

Read these before installing, especially on a work computer.

- **Work computers:** a scheduled job that signs in to an account may need
  your IT team's approval. Check before installing on a managed device.
- **The token is optional, and it is a credential.** Without it the scripts
  use your normal `claude` login, which expires every few weeks; you then sign
  in again with `claude auth login`. With it, you don't have to, but the
  token gives access to your Claude account for a year to anyone who gets the
  file. It's stored as plain text in your user folder: `chmod 600` on macOS,
  your user profile's default permissions on Windows. If that isn't
  acceptable on your machine, skip the token.
- **Windows execution policy:** the scheduled task starts PowerShell with
  `-ExecutionPolicy Bypass` for that one process only. Windows blocks
  unsigned scripts by default and these scripts aren't signed. It doesn't
  change the policy for anything else. Read `windows/start-window.ps1`
  before installing.
- **Read the scripts first.** They're short: about 400 lines in total,
  installers included.

## Install

The steps are the same whether you do them yourself or ask a coding agent to
do them for you. Every step is safe to re-run.

### 1. Check you have Claude Code and git

```bash
claude --version && git --version
```

```powershell
Get-Command claude, git
```

### 2. Get the repo

The folder can be anywhere; the scripts find their own location. These
commands use `~/.claude-trigger`.

```bash
git clone https://github.com/alberto-van/claude-window-anchor.git ~/.claude-trigger
```

```powershell
git clone https://github.com/alberto-van/claude-window-anchor.git "$HOME\.claude-trigger"
```

Already cloned? `git pull` inside the folder instead.

### 3. Install the schedule

macOS:

```bash
~/.claude-trigger/install.sh            # 06:00 Mon-Fri
~/.claude-trigger/install.sh --at 07:30 # another time
```

Windows:

```powershell
powershell -ExecutionPolicy Bypass -File "$HOME\.claude-trigger\windows\install-task.ps1"
powershell -ExecutionPolicy Bypass -File "$HOME\.claude-trigger\windows\install-task.ps1" -At 07:30
```

Running it again replaces the existing job.

### 4. Token (optional, do this yourself)

Skip this to use your normal login. Otherwise run `claude setup-token` in
your own terminal, copy the token, and save it:

```bash
pbpaste > ~/.claude-trigger/oauth-token && chmod 600 ~/.claude-trigger/oauth-token
```

```powershell
Get-Clipboard | Set-Content -NoNewline "$HOME\.claude-trigger\oauth-token"
```

A line break inside the token from the terminal wrapping it is fine; both
scripts strip whitespace. If an agent is helping you install, don't paste the
token into the chat.

### 5. Test

This sends one real prompt to Haiku.

macOS:

```bash
~/.claude-trigger/start-window.sh; echo "exit=$?"
```

Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.claude-trigger\windows\start-window.ps1"; "exit=$LASTEXITCODE"
```

Success is `exit=0` and a log line ending `anchored -> READY`. On a weekend
the script logs `skipping` and exits 0 without calling Claude.

To check the scheduler itself can start it:

```bash
launchctl kickstart "gui/$(id -u)/local.claude-window-anchor"; sleep 15; tail -2 ~/Library/Logs/claude-window.log
```

```powershell
Start-ScheduledTask -TaskName 'Claude window anchor'; Start-Sleep 30
Get-ScheduledTaskInfo -TaskName 'Claude window anchor' | Select-Object LastRunTime, LastTaskResult
```

On Windows, `LastTaskResult` 0 means success and 267009 means still running.

## Troubleshooting

| Log says | Cause | Fix |
|---|---|---|
| `AUTH EXPIRED`, exit 2 | Login or token expired, or token mistyped | `claude auth login`, or redo step 4 |
| `claude not found`, exit 1 | Claude Code not installed where the script looks | Install it; the scripts check `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin` and PATH |
| `timed out after 120s` on every attempt | Claude hangs on start | Run `claude -p hi` by hand to see why |
| `network still unreachable` | No connection to api.anthropic.com | Check network, VPN or proxy |
| Nothing in the log at the set time (macOS) | Job not loaded | Re-run `install.sh` |
| Runs logged when you open the laptop, not at the set time | Computer was asleep and didn't wake, or was shut down | See [Will it help you?](#will-it-help-you) |

## Uninstall

```bash
~/.claude-trigger/install.sh --uninstall
```

```powershell
powershell -ExecutionPolicy Bypass -File "$HOME\.claude-trigger\windows\install-task.ps1" -Uninstall
```

If you set a wake schedule with `pmset` on macOS, undo it separately with
`sudo pmset repeat cancel`.

This removes the scheduled job. The repo folder, token and log stay; delete
them by hand if you want.

## License

MIT. See [LICENSE](LICENSE).
