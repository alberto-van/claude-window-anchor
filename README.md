# claude-window-anchor

Sends Claude a one-word prompt at 06:00 every weekday so the usage window
starts before the workday does.

- `start-window.sh` runs `claude -p` on Haiku with no tools, MCP servers or
  settings. It waits for the network, retries up to 4 times, and shows a
  macOS notification if it fails or the login has expired.
- `launchd/com.alberto.claude-window.plist` runs the script at 06:00,
  Monday to Friday.
- Log: `~/Library/Logs/claude-window.log`

## Install on a new Mac

```bash
git clone <this repo> ~/.claude-trigger
cp ~/.claude-trigger/launchd/com.alberto.claude-window.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.alberto.claude-window.plist
```

The paths in both files assume the user `ordenador12`. Change them if the
username differs, and check that `claude` is at `/opt/homebrew/bin/claude`.

## Token

The script reads a long-lived token from `~/.claude-trigger/oauth-token`.
It is not in this repo (`.gitignore`). To create one:

```bash
claude setup-token
pbpaste > ~/.claude-trigger/oauth-token && chmod 600 ~/.claude-trigger/oauth-token
```

The token lasts a year. Without the file the script falls back to the
interactive `claude auth login`, which expires every few weeks.

## Test

```bash
~/.claude-trigger/start-window.sh
```

It should log `anchored -> READY` and exit 0.
