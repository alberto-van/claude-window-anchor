#!/bin/zsh
# launchd starts jobs with a bare PATH; add the usual places Claude Code installs to.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# The folder this script lives in (zsh: absolute path of $0, then its parent).
REPO_DIR="${0:A:h}"
cd "$REPO_DIR" || exit 1

# A scheduled wake on battery is a dark wake that sleeps again after a few
# seconds. Hold the Mac awake (idle and system sleep) until this script exits.
caffeinate -is -w $$ &

# Long-lived token from `claude setup-token` (valid 1 year). Kept in its own
# chmod-600 file so it never sits in the script. Without it, the script falls
# back to the interactive login, which expires every few weeks.
TOKEN_FILE="$REPO_DIR/oauth-token"
if [ -r "$TOKEN_FILE" ]; then
  export CLAUDE_CODE_OAUTH_TOKEN="$(tr -d '[:space:]' <"$TOKEN_FILE")"
fi

# Fail fast rather than stall. Claude Code's own defaults are generous:
# API_TIMEOUT_MS is 600000 (10 min) and CLAUDE_CODE_MAX_RETRIES is 10, so a
# stalled request outlives the watchdog below and gets killed with no error to
# log -- exactly what happened on 2026-11-25. Keep the API timeout and retries
# inside ATTEMPT_TIMEOUT so the CLI reports a real failure first, and let this
# script's own backoff do the retrying.
export API_TIMEOUT_MS=45000
export CLAUDE_CODE_MAX_RETRIES=2
export CLAUDE_CODE_NONSTREAMING_TIMEOUT_RETRIES=0
export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=5000   # don't idle 10 min after READY

# Drop startup network calls this ping doesn't need: updates, telemetry, error
# reporting, feature flags, claude.ai connectors, the session-title request.
# (Not --bare: that mode ignores CLAUDE_CODE_OAUTH_TOKEN, which we rely on.)
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export DISABLE_AUTOUPDATER=1
export CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1
export ENABLE_CLAUDEAI_MCP_SERVERS=false
export CLAUDE_CODE_DISABLE_CLAUDE_MDS=1
export CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS=1
export CLAUDE_CODE_DISABLE_AUTO_MEMORY=1
export CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1
export CLAUDE_CODE_DISABLE_CRON=1

# anthropics/claude-code#78903: a launchd -p run can park waiting on a
# `/bin/zsh -c -l` shell-snapshot child. Workaround; root cause unconfirmed.
export SHELL=/bin/sh
export CLAUDE_CODE_DISABLE_SHELL_HEAD_START=1

ATTEMPT_TIMEOUT=180                      # blind kill; above API_TIMEOUT_MS*retries so the CLI errors first
NETWORK_WAIT_MAX=600                     # wait up to this long for api.anthropic.com to be reachable
RETRY_DELAYS=(60 180 300 600 900 900)    # pauses before attempts 2..7 (~63 min total)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S %z')] $1"; }

notify() {
  osascript -e "display notification \"$1\" with title \"Claude window anchor\"" 2>/dev/null
}

# Guard against a missed weekday job firing on a weekend wake.
case "$(date '+%u')" in
  6|7) log "weekend ($(date '+%A')) — skipping"; exit 0 ;;
esac

CLAUDE_BIN="$(command -v claude)"
if [ -z "$CLAUDE_BIN" ]; then
  log "claude not found — install Claude Code or add it to PATH"
  notify "claude not found. Install Claude Code or add it to PATH."
  exit 1
fi

# Run claude with a hard timeout. Writes output to $1, returns 124 on timeout.
run_claude() {
  local out_file="$1" pid waited=0
  # Minimal ping: no MCP servers, plugins, settings, skills, tools or saved
  # session, so startup can't hang on connectors. OAuth login still applies.
  "$CLAUDE_BIN" -p 'Reply with only the word READY. Do not use any tools.' \
    --model haiku --max-turns 1 \
    --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
    --setting-sources "" --disable-slash-commands --tools "" \
    --permission-prompts none \
    --no-chrome --no-session-persistence >"$out_file" 2>&1 &
  pid=$!
  while kill -0 $pid 2>/dev/null; do
    if [ $waited -ge $ATTEMPT_TIMEOUT ]; then
      kill -9 $pid 2>/dev/null
      wait $pid 2>/dev/null
      echo "timed out after ${ATTEMPT_TIMEOUT}s" >"$out_file"
      return 124
    fi
    sleep 2
    waited=$((waited + 2))
  done
  wait $pid
}

OUT_FILE="$(mktemp -t claude-window)"
trap 'rm -f "$OUT_FILE"' EXIT

# No cutoff on purpose: anchoring late still beats waiting for the first
# real prompt, and if the window is already open the call is a no-op.
# After a scheduled wake the network may not be up yet. Any HTTP response
# (even 404) means the API host is reachable.
wait_for_network() {
  local waited=0 code
  while :; do
    # curl verifies TLS, so any status here came from the real host, not a portal.
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 https://api.anthropic.com/v1/messages)"
    [ -n "$code" ] && [ "$code" != "000" ] && break
    if [ $waited -ge $NETWORK_WAIT_MAX ]; then
      log "network still unreachable after ${NETWORK_WAIT_MAX}s — trying anyway"
      return 1
    fi
    sleep 10
    waited=$((waited + 10))
  done
  [ $waited -gt 0 ] && log "network reachable (HTTP $code) after ${waited}s"
  return 0
}

# One-line snapshot of the API path, logged when a call times out so a repeat
# of 2026-11-25 leaves evidence instead of a bare "timed out".
probe_api() {
  curl -s -o /dev/null --max-time 10 \
    -w 'HTTP %{http_code} dns=%{time_namelookup}s tls=%{time_appconnect}s total=%{time_total}s' \
    https://api.anthropic.com/v1/messages 2>&1 || echo "curl failed (exit $?)"
}

MAX_ATTEMPTS=$(( ${#RETRY_DELAYS} + 1 ))
for attempt in $(seq 1 $MAX_ATTEMPTS); do
  wait_for_network
  log "attempt $attempt/$MAX_ATTEMPTS (model haiku) at $(date '+%H:%M')"
  if run_claude "$OUT_FILE"; then
    log "anchored -> $(tr -d '\n' <"$OUT_FILE")"
    exit 0
  fi

  OUT="$(tr -d '\n' <"$OUT_FILE")"
  log "failed -> $OUT"

  # A timeout tells us nothing on its own; record the network path right now.
  case "$OUT" in
    *"timed out after"*)
      log "diag: api.anthropic.com -> $(probe_api)"
      # anthropics/claude-code#91987: a concurrent interactive session can hold
      # a version-directory lock and stall a headless start.
      log "diag: other claude processes -> $(pgrep -fl claude 2>/dev/null | grep -cv start-window)"
      ;;
  esac

  # An expired token will not fix itself in 30s — stop and tell the user.
  case "$OUT" in
    *[Aa]uthenticate*|*401*|*[Oo][Aa]uth*)
      log "AUTH EXPIRED — run 'claude setup-token' and save the new token to $TOKEN_FILE"
      notify "Auth expired. Run claude setup-token and save it to oauth-token."
      exit 2
      ;;
  esac

  if [ $attempt -lt $MAX_ATTEMPTS ]; then
    delay=${RETRY_DELAYS[$attempt]}      # zsh arrays are 1-indexed
    log "retrying in ${delay}s"
    sleep $delay
  fi
done

log "gave up after $MAX_ATTEMPTS attempts"
notify "Failed to anchor the usage window after $MAX_ATTEMPTS attempts."
exit 1
