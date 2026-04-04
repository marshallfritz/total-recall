#!/usr/bin/env bash
# Session Recovery — catches missed sessions on /new or /reset
# Part of Total Recall skill
#
# Phase 2 (dual-path): also injects Pensive context on every session start.
# Remove the pensive_inject() call at each exit point when Phase 3 cutover is done.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SKILL_DIR/scripts/_compat.sh"

WORKSPACE="${OPENCLAW_WORKSPACE:-$(cd "$SKILL_DIR/../.." && pwd)}"
MEMORY_DIR="${MEMORY_DIR:-$WORKSPACE/memory}"
SESSIONS_DIR="${SESSIONS_DIR:-$HOME/.openclaw/agents/main/sessions}"
HASH_FILE="$MEMORY_DIR/.observer-last-hash"
RECOVERY_LOG="$WORKSPACE/logs/session-recovery.log"

mkdir -p "$WORKSPACE/logs"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$RECOVERY_LOG"
}

# ── Phase 2: Pensive dual-path context injection ──────────────────────────────
# Called unconditionally before every exit. Non-fatal — observations.md unchanged.
# Dual-path validation: run both until 5-session spot-check confirms recall quality,
# then tombstone observations.md injection (Phase 3).
# Remove this function and its calls when Phase 3 cutover is complete.
pensive_inject() {
  local pensive_url="${PENSIVE_URL:-}"
  local pensive_token="${PENSIVE_TOKEN:-}"

  # Source workspace .env if vars not already set
  local workspace_env="$WORKSPACE/.env"
  if [ -z "$pensive_token" ] && [ -f "$workspace_env" ]; then
    while IFS='=' read -r key val; do
      [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
      key="${key%%[[:space:]]*}"
      val="${val%%[[:space:]]*}"
      case "$key" in
        PENSIVE_URL)   pensive_url="$val" ;;
        PENSIVE_TOKEN) pensive_token="$val" ;;
      esac
    done < "$workspace_env"
  fi

  pensive_url="${pensive_url:-http://localhost:8000}"

  if [ -z "$pensive_token" ]; then
    log "[pensive] PENSIVE_TOKEN not set — skipping dual-path injection"
    return 0
  fi

  local response
  response=$(curl -sf --max-time 5 \
    -H "Authorization: Bearer $pensive_token" \
    "${pensive_url}/api/v1/context?q=" 2>/dev/null) || {
    log "[pensive] API unreachable or error — skipping dual-path injection"
    return 0
  }

  [ -z "$response" ] && return 0

  local formatted
  # Pass JSON via env var to avoid pipe+heredoc stdin conflict
  formatted=$(_PENSIVE_RESP="$response" python3 <<'PYEOF'
import json, os, sys
try:
    d = json.loads(os.environ['_PENSIVE_RESP'])
    data = d.get("data", {})
    permanent = data.get("permanent", [])
    active_ops = data.get("active_ops", [])
    ephemeral = data.get("ephemeral", [])

    lines = ["<!-- pensive-context: dual-path Phase 2 -->"]

    if permanent:
        lines.append("## Pensive: PERMANENT")
        for item in permanent:
            lines.append(f"- \U0001f534 [{item.get('band','?')}] {item.get('content','')}")

    if active_ops:
        lines.append("## Pensive: ACTIVE OPS")
        for item in active_ops:
            fc = item.get("forget_clause") or ""
            fc_note = f" [forget: {fc[:80]}]" if fc else ""
            lines.append(f"- \U0001f7e1 [{item.get('band','?')}] {item.get('content','')}{fc_note}")

    if ephemeral:
        lines.append("## Pensive: EPHEMERAL (top matches)")
        for item in ephemeral:
            lines.append(f"- \U0001f7e2 [{item.get('band','?')}] {item.get('content','')}")

    if len(lines) > 1:
        print("\n".join(lines))
except Exception as e:
    print(f"<!-- pensive-context: parse error: {e} -->", file=sys.stderr)
PYEOF
  )

  if [ -n "$formatted" ]; then
    echo ""
    echo "$formatted"
    log "[pensive] Dual-path injection complete ($(echo "$formatted" | wc -l | tr -d ' ') lines)"
  fi
}

log "Session recovery check starting"

# Find most recent session file (filter out subagent/cron/topic)
LAST_SESSION=""
for f in $(find "$SESSIONS_DIR" -maxdepth 1 -name "*.jsonl" -type f 2>/dev/null | sort -r); do
  BASENAME=$(basename "$f" .jsonl)
  if echo "$BASENAME" | grep -qE "(topic|subagent|cron)"; then
    continue
  fi
  LAST_SESSION="$f"
  break
done

if [ -z "$LAST_SESSION" ]; then
  log "No main session files found"
  pensive_inject
  exit 0
fi

CURRENT_HASH=$(tail -50 "$LAST_SESSION" 2>/dev/null | md5_hash || echo "")

if [ -z "$CURRENT_HASH" ]; then
  log "Could not hash session file"
  pensive_inject
  exit 0
fi

if [ -f "$HASH_FILE" ]; then
  STORED_HASH=$(cat "$HASH_FILE" 2>/dev/null || echo "")
  if [ "$CURRENT_HASH" = "$STORED_HASH" ]; then
    log "Last session already observed (hash match)"
    pensive_inject
    exit 0
  fi
fi

log "Unobserved session detected: $(basename "$LAST_SESSION") (hash: ${CURRENT_HASH:0:8})"
log "Triggering emergency observer capture..."

bash "$SKILL_DIR/scripts/observer-agent.sh" --recover "$LAST_SESSION" 2>/dev/null || {
  log "Observer recovery failed, attempting direct capture..."
  CUTOFF_ISO=$(date_minutes_ago 240)

  OBSERVATIONS_FILE="$MEMORY_DIR/observations.md"
  RECENT_MESSAGES=$(jq -r --arg cutoff "$CUTOFF_ISO" '
    select(.timestamp != null and (.timestamp > $cutoff)) |
    select(.message.role == "user" or .message.role == "assistant") |
    .message as $m |
    (if $m.role == "user" then "USER" else "ASSISTANT" end) as $who |
    (
      if ($m.content | type) == "array" then
        [$m.content[] | select(.type == "text") | .text] | join(" ")
      elif ($m.content | type) == "string" then
        $m.content
      else
        ""
      end
    ) as $text |
    select($text != "" and ($text | length) > 5) |
    select($text != "HEARTBEAT_OK" and $text != "NO_REPLY") |
    "\($who): \($text[0:400])"
  ' "$LAST_SESSION" 2>/dev/null | head -100 || true)

  if [ -n "$RECENT_MESSAGES" ]; then
    echo "" >> "$OBSERVATIONS_FILE"
    echo "<!-- Session Recovery Capture: $(date '+%Y-%m-%d %H:%M') -->" >> "$OBSERVATIONS_FILE"
    echo "$RECENT_MESSAGES" >> "$OBSERVATIONS_FILE"
    echo "$CURRENT_HASH" > "$HASH_FILE"
    log "Emergency capture complete ($(echo "$RECENT_MESSAGES" | wc -l) lines)"
  fi
}

log "Session recovery complete"
pensive_inject
