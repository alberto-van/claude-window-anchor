# claude-window-anchor

Claude's usage limits run in windows that start with your first message.
This sends Claude a one-word prompt at 05:59 every weekday, so the window has
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
  wake. The job is set for 05:59, so wake the Mac at 06:00 on weekdays (needs
  an admin password, and applies to the whole Mac):

  ```bash
  sudo pmset repeat wakeorpoweron MTWRF 06:00:00
  ```

  Wake *after* the job time, not before: on battery a scheduled wake is a
  dark wake that sleeps again within seconds, so a 05:58 wake is over before
  a 06:00 job is due and the run slips to the next background wake (often
  ~06:14). Waking at 06:00 finds the 05:59 job overdue, launchd runs it
  immediately, and the script holds the Mac awake with `caffeinate` until it
  finishes.

  Undo with `sudo pmset repeat cancel`. Check with `pmset -g sched`.

To see whether it's actually helping, look at the times in the log: runs at
the set time mean it works; runs at whatever time you opened the laptop mean
it doesn't.

## What it does, and what it touches

Each run executes this, with no tools, MCP servers, plugins or settings loaded:

```
claude -p "Reply with only the word READY. Do not use any tools." --model haiku --max-turns 1
```

It waits for the network, retries up to 7 times over about an hour, writes a log, and shows a
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

Exit codes: `0` anchored, `1` gave up after 7 attempts or `claude` not
found, `2` login expired or token invalid.

## Why the scripts set these environment variables

Both scripts export a block of Claude Code environment variables before the
call. Each one closes a way this job failed, or could fail silently.

On 25 November 2026 a run fired on time at 06:00:01 and then all four attempts
died with `timed out after 120s` and nothing else. The network was fine and the
same command worked by hand minutes later, but the log gave no clue why. The
cause was a mismatch of budgets: Claude Code's own `API_TIMEOUT_MS` defaults to
600000 (10 minutes) and `CLAUDE_CODE_MAX_RETRIES` to 10, so a stalled request
will sit there far longer than this script's watchdog allows. The watchdog
always won, killed the process, and threw the error away with it.

| Variable | Set to | Why |
|---|---|---|
| `API_TIMEOUT_MS` | `45000` | Default is 10 minutes. The CLI has to give up, and report, before the script's blind kill. |
| `CLAUDE_CODE_MAX_RETRIES` | `2` | Default is 10. The script's own backoff should own the retrying, not the CLI. |
| `CLAUDE_CODE_NONSTREAMING_TIMEOUT_RETRIES` | `0` | Fail on the first timeout instead of re-sending. |
| `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS` | `5000` | Print mode otherwise waits up to 10 minutes for background work after the final turn, which looks exactly like a hang after `READY`. |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, `DISABLE_AUTOUPDATER`, `CLAUDE_CODE_DISABLE_TERMINAL_TITLE`, `ENABLE_CLAUDEAI_MCP_SERVERS=false` | off | Every startup network call is another chance to hang right after a scheduled wake. Disabling the terminal title also skips a background small-model request. |
| `CLAUDE_CODE_DISABLE_CLAUDE_MDS`, `_GIT_INSTRUCTIONS`, `_AUTO_MEMORY`, `_BACKGROUND_TASKS`, `_CRON` | off | Nothing a one-word ping needs. Together these took startup from about 4s to 2s. |
| `SHELL=/bin/sh`, `CLAUDE_CODE_DISABLE_SHELL_HEAD_START` (macOS only) | | Workaround for [#78903](https://github.com/anthropics/claude-code/issues/78903): a launchd `-p` run can park waiting on a `/bin/zsh -c -l` shell-snapshot child. |

`--permission-prompts none` is passed for the same reason: without it a
headless run waits for a permission host to answer.

**Not `--bare`.** It would cut startup further, but it ignores
`CLAUDE_CODE_OAUTH_TOKEN`, so it breaks the token file and falls back to the
interactive login that the token exists to avoid.

### Known upstream hangs

These issues are open, so the settings above improve the odds and make a
failure legible. They are not a guaranteed fix.

- [#78903](https://github.com/anthropics/claude-code/issues/78903) launchd run parks before the first token; `SHELL=/bin/sh` works around it
- [#86074](https://github.com/anthropics/claude-code/issues/86074) no API request timeout in print mode; a black-holed TCP connection stalled a run for about 4 hours
- [#79610](https://github.com/anthropics/claude-code/issues/79610) headless hang with zero output even under `--debug`
- [#91987](https://github.com/anthropics/claude-code/issues/91987) startup hang when a concurrent interactive session holds a version-directory lock
- [#89537](https://github.com/anthropics/claude-code/issues/89537) startup deadlock under launchd where `SHELL=/bin/sh` did not help

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
~/.claude-trigger/install.sh            # 05:59 Mon-Fri
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
| `timed out after 180s` on every attempt | Claude hangs on start | Read the `diag:` line logged under it, then see [Why the scripts set these environment variables](#why-the-scripts-set-these-environment-variables) |
| `diag: ... HTTP 405 ...` after a timeout | API was reachable, so the hang was inside the CLI | Known upstream issue; see the list below that section |
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
