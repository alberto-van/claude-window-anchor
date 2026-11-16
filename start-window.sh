#!/bin/zsh
export PATH="/Users/ordenador12/Library/pnpm/bin:/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home/bin:/Users/ordenador12/Repositorios/scripts/bin:/Users/ordenador12/.nvm/versions/node/v24.19.0/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/System/Cryptexes/App/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin:/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/local/bin:/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/bin:/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/appleinternal/bin:/pkg/env/global/bin:/Library/Apple/usr/bin:/Users/ordenador12/.local/bin:/opt/homebrew/opt/fzf/bin:/Users/ordenador12/Library/Android/sdk/emulator:/Users/ordenador12/Library/Android/sdk/platform-tools:/Users/ordenador12/Library/Android/sdk/cmdline-tools/latest/bin:/Users/ordenador12/.nvm/versions/node/v20.20.2/bin:/Users/ordenador12/.nvm/versions/node/v22.23.1/bin:/Users/ordenador12/.nvm/versions/node/v24.17.0/bin:/Users/ordenador12/Library/pnpm:/Users/ordenador12/bin:/Users/ordenador12/.claude/plugins/cache/claude-plugins-official/figma/2.2.87/bin:/Users/ordenador12/Library/Application Support/Claude/local-agent-mode-sessions/skills-plugin/394f91d2-9e13-4a00-a14c-c942eedda4a0/d629ac72-9bf6-4123-a0ee-f0eac01ca6c2/bin"
cd "/Users/ordenador12/.claude-trigger" || exit 1

# Long-lived token from `claude setup-token` (valid 1 year). Kept in its own
# chmod-600 file so it never sits in the script. Without it, the script falls
# back to the interactive login, which expires every few weeks.
TOKEN_FILE="/Users/ordenador12/.claude-trigger/oauth-token"
if [ -r "$TOKEN_FILE" ]; then
  export CLAUDE_CODE_OAUTH_TOKEN="$(tr -d '[:space:]' <"$TOKEN_FILE")"
fi

ATTEMPT_TIMEOUT=120                      # kill a hung claude call after this many seconds
NETWORK_WAIT_MAX=600                     # wait up to this long for api.anthropic.com to be reachable
RETRY_DELAYS=(60 180 300)                # pause before attempts 2, 3 and 4

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S %z')] $1"; }

notify() {
  osascript -e "display notification \"$1\" with title \"Claude window anchor\"" 2>/dev/null
}

# Guard against a missed weekday job firing on a weekend wake.
case "$(date '+%u')" in
  6|7) log "weekend ($(date '+%A')) — skipping"; exit 0 ;;
esac

# Run claude with a hard timeout. Writes output to $1, returns 124 on timeout.
run_claude() {
  local out_file="$1" pid waited=0
  # Minimal ping: no MCP servers, plugins, settings, skills, tools or saved
  # session, so startup can't hang on connectors. OAuth login still applies.
  "/opt/homebrew/bin/claude" -p 'Reply with only the word READY. Do not use any tools.' \
    --model haiku --max-turns 1 \
    --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
    --setting-sources "" --disable-slash-commands --tools "" \
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
  local waited=0
  until curl -s -o /dev/null --max-time 5 https://api.anthropic.com; do
    if [ $waited -ge $NETWORK_WAIT_MAX ]; then
      log "network still unreachable after ${NETWORK_WAIT_MAX}s — trying anyway"
      return 1
    fi
    sleep 10
    waited=$((waited + 10))
  done
  [ $waited -gt 0 ] && log "network reachable after ${waited}s"
  return 0
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
