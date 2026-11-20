#!/bin/zsh
# Installs (or removes) the launchd job that runs start-window.sh at 05:59
# Monday to Friday. The macOS counterpart of windows/install-task.ps1.
# 05:59 sits one minute before the 06:00 pmset wake (see README), so the job is
# already overdue when the Mac wakes and launchd runs it at once.
#
#   ./install.sh                 install or update, 05:59
#   ./install.sh --at 07:30      install or update, another time
#   ./install.sh --uninstall     remove the job (keeps this folder, token and log)

set -e

LABEL="local.claude-window-anchor"
OLD_LABEL="com.alberto.claude-window"          # name used before 2026-11
REPO_DIR="${0:A:h}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/claude-window.log"
DOMAIN="gui/$(id -u)"
AT="05:59"

case "$1" in
  --uninstall)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Removed $LABEL."
    exit 0 ;;
  --at)
    AT="$2" ;;
  "") ;;
  *) echo "Usage: $0 [--at HH:MM | --uninstall]" >&2; exit 64 ;;
esac

if [[ ! "$AT" =~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' ]]; then
  echo "--at must be HH:MM (24h), got '$AT'" >&2; exit 64
fi
HOUR=$((10#${AT%%:*})); MINUTE=$((10#${AT##*:}))

command -v claude >/dev/null || PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
if ! command -v claude >/dev/null; then
  echo "claude not found. Install Claude Code first." >&2; exit 1
fi

chmod +x "$REPO_DIR/start-window.sh"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

# One calendar entry per weekday (1 = Monday ... 5 = Friday).
INTERVALS=""
for day in 1 2 3 4 5; do
  INTERVALS+="
        <dict>
            <key>Weekday</key><integer>$day</integer>
            <key>Hour</key><integer>$HOUR</integer>
            <key>Minute</key><integer>$MINUTE</integer>
        </dict>"
done

cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$REPO_DIR/start-window.sh</string>
    </array>
    <key>StartCalendarInterval</key>
    <array>$INTERVALS
    </array>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
EOF
plutil -lint -s "$PLIST"

# Replace any running copy, including one installed under the old name.
launchctl bootout "$DOMAIN/$OLD_LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$OLD_LABEL.plist"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"

echo "Installed $LABEL: $AT, Monday to Friday."
echo "Script: $REPO_DIR/start-window.sh"
echo "Log:    $LOG"
echo "Test:   $REPO_DIR/start-window.sh; echo \"exit=\$?\""
