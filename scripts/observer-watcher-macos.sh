#!/usr/bin/env bash
# observer-watcher-macos.sh — fswatch-based reactive observer trigger for macOS
# Equivalent of observer-watcher.sh (Linux/inotify) but uses FSEvents via fswatch.
# Requires: brew install fswatch

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SKILL_DIR/scripts/_compat.sh"

if ! command -v fswatch &>/dev/null; then
  echo "ERROR: fswatch not found. Install with: brew install fswatch"
  exit 1
fi

WORKSPACE="${OPENCLAW_WORKSPACE:-$(cd "$SKILL_DIR/../.." && pwd)}"
SESSIONS_DIR="${SESSIONS_DIR:-$HOME/.openclaw/agents/main/sessions}"
SESSIONS_INDEX="$SESSIONS_DIR/sessions.json"
MARKER_FILE="/tmp/observer-watcher-macos-lastrun"
COOLDOWN_SECS="${OBSERVER_COOLDOWN_SECS:-300}"
DREAM_LOCK_FILE="$WORKSPACE/logs/dream-cycle.lock"
# shellcheck source=config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
DREAM_LOCK_MAX_AGE=$TR_LOCK_MAX_AGE

# Read expiry from self-describing lock file (format: PID:CREATED:EXPIRES)
# Falls back to mtime-based check for legacy lock files.
# NOTE: Keep in sync with dream-cycle.sh, preflight-archive.sh, observer-agent.sh
# See: cre/TRStrategyBootstrap.md §Lock Format
dream_lock_is_active() {
  local lock_file="$1"
  [ -f "$lock_file" ] || return 1
  local expires
  expires=$(cut -d: -f3 "$lock_file" 2>/dev/null)
  if [[ "$expires" =~ ^[0-9]+$ ]]; then
    [ "$(date +%s)" -lt "$expires" ]
  else
    local age=$(( $(date +%s) - $(file_mtime "$lock_file") ))
    [ "$age" -lt "$DREAM_LOCK_MAX_AGE" ]
  fi
}
LINE_THRESHOLD="${OBSERVER_LINE_THRESHOLD:-40}"
LOG="$WORKSPACE/logs/observer-watcher.log"
PIDFILE="/tmp/total-recall-watcher-macos-$(id -u).pid"
ACCUMULATED_LINES=0

# Safe env loading
if [ -f "$WORKSPACE/.env" ]; then
  set -a
  eval "$(grep -E '^OPENROUTER_API_KEY=' "$WORKSPACE/.env" 2>/dev/null)" || true
  set +a
fi

mkdir -p "$WORKSPACE/logs"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

# --- PID management ---
if [ -f "$PIDFILE" ]; then
  OLD_PID=$(cat "$PIDFILE" 2>/dev/null || echo "")
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Watcher already running (PID $OLD_PID). Exiting."
    exit 0
  fi
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"; log "Watcher stopped (PID $$)"; exit 0' EXIT INT TERM

# --- Validate sessions directory ---
if [ ! -d "$SESSIONS_DIR" ]; then
  log "Sessions directory does not exist: $SESSIONS_DIR — waiting..."
  for i in $(seq 1 30); do
    [ -d "$SESSIONS_DIR" ] && break
    sleep 10
  done
  if [ ! -d "$SESSIONS_DIR" ]; then
    log "Sessions directory still missing after 5 min, exiting"
    exit 1
  fi
fi

get_main_session_ids() {
  if [ -f "$SESSIONS_INDEX" ]; then
    jq -r 'to_entries[]
      | select(.key | test("subagent|cron|topic") | not)
      | .value.sessionId' "$SESSIONS_INDEX" 2>/dev/null | sort -u
  fi
}

is_main_session_path() {
  local filepath="$1"
  local filename
  filename=$(basename "$filepath")
  [[ "$filename" == *.jsonl ]] || return 1
  local session_id="${filename%.jsonl}"
  if [ -z "${MAIN_IDS:-}" ] || [ $(( $(date +%s) - ${CACHE_TIME:-0} )) -gt 60 ]; then
    MAIN_IDS=$(get_main_session_ids || true)
    CACHE_TIME=$(date +%s)
  fi
  [ -n "${MAIN_IDS:-}" ] && echo "$MAIN_IDS" | grep -qF "$session_id"
}

in_cooldown() {
  [ -f "$MARKER_FILE" ] || return 1
  local last_run elapsed
  last_run=$(file_mtime "$MARKER_FILE")
  elapsed=$(( $(date +%s) - last_run ))
  [ "$elapsed" -lt "$COOLDOWN_SECS" ]
}

dream_cycle_running() {
  [ -f "$DREAM_LOCK_FILE" ] || return 1
  if dream_lock_is_active "$DREAM_LOCK_FILE"; then
    return 0  # lock is fresh — dream cycle running
  fi
  # Stale lock — remove it and return false
  local expires
  expires=$(cut -d: -f3 "$DREAM_LOCK_FILE" 2>/dev/null || echo "?")
  log "Stale Dream Cycle lock (expires: ${expires}), removing"
  rm -f "$DREAM_LOCK_FILE"
  return 1
}

dc_cooldown_active() {
  local cooldown_file="$WORKSPACE/$TR_DC_COOLDOWN_FILE"
  [ -f "$cooldown_file" ] || return 1
  local ends
  ends=$(cut -d: -f2 "$cooldown_file" 2>/dev/null)
  if [[ "$ends" =~ ^[0-9]+$ ]]; then
    [ "$(date +%s)" -lt "$ends" ]
  else
    return 1  # unparseable — treat as not active
  fi
}

write_dc_cooldown() {
  local now ends
  now=$(date +%s)
  ends=$(( now + TR_DC_TRIGGER_COOLDOWN_SECS ))
  echo "${now}:${ends}" > "$WORKSPACE/$TR_DC_COOLDOWN_FILE"
  log "DC cooldown set: lifts at epoch ${ends} ($(date -r "$ends" '+%H:%M:%S' 2>/dev/null || echo ${ends}))"
}

maybe_trigger_dream_cycle() {
  local obs="$WORKSPACE/memory/observations.md"
  [ -f "$obs" ] || return

  local bytes
  bytes=$(wc -c < "$obs" | tr -d ' ')
  if [ "$bytes" -lt "$TR_OBS_TRIGGER_BYTES" ]; then
    return  # file healthy, no trigger needed
  fi

  if dream_cycle_running; then
    log "DC size trigger suppressed — Dream Cycle already running (${bytes}B > ${TR_OBS_TRIGGER_BYTES}B)"
    return
  fi

  if dc_cooldown_active; then
    local ends
    ends=$(cut -d: -f2 "$WORKSPACE/$TR_DC_COOLDOWN_FILE" 2>/dev/null || echo "?")
    log "DC size trigger suppressed — cooldown active until epoch ${ends} (${bytes}B > ${TR_OBS_TRIGGER_BYTES}B)"
    return
  fi

  log "DC size trigger FIRED: observations.md ${bytes}B > ${TR_OBS_TRIGGER_BYTES}B — triggering Dream Cycle"
  write_dc_cooldown

  # Use openclaw CLI to trigger the cron job
  if command -v openclaw &>/dev/null; then
    openclaw cron run "$TR_DREAM_CYCLE_JOB_ID" >> "$LOG" 2>&1 &
    log "Dream Cycle cron enqueued (job: $TR_DREAM_CYCLE_JOB_ID)"
  else
    log "WARNING: openclaw CLI not found — cannot trigger Dream Cycle automatically"
  fi
}

trigger_observer() {
  if dream_cycle_running; then
    log "Dream Cycle lock active — suppressing reactive observer trigger (lines: $ACCUMULATED_LINES)"
    return
  fi
  if in_cooldown; then
    log "Cooldown active (${COOLDOWN_SECS}s). Skipping. Lines: $ACCUMULATED_LINES"
    return
  fi
  log "TRIGGER: $ACCUMULATED_LINES lines. Firing observer."
  touch "$MARKER_FILE"
  ACCUMULATED_LINES=0
  OPENCLAW_WORKSPACE="$WORKSPACE" "$SKILL_DIR/scripts/observer-agent.sh" >> "$LOG" 2>&1 &
  log "Observer started (PID $!)"

  # After firing Observer, check if observations.md warrants a Dream Cycle trigger
  maybe_trigger_dream_cycle
}

check_cron_ran() {
  if [ -f "$MARKER_FILE" ]; then
    local marker_time
    marker_time=$(file_mtime "$MARKER_FILE")
    if [ "${LAST_MARKER_TIME:-0}" != "$marker_time" ] && [ "${LAST_MARKER_TIME:-0}" != "0" ]; then
      log "External observer run detected. Resetting line counter."
      ACCUMULATED_LINES=0
    fi
    LAST_MARKER_TIME="$marker_time"
  fi
}

log "macOS watcher started (PID $$). Threshold: ${LINE_THRESHOLD} lines, Cooldown: ${COOLDOWN_SECS}s"
log "Watching: $SESSIONS_DIR"

MAIN_IDS=$(get_main_session_ids || true)
CACHE_TIME=$(date +%s)

# fswatch: -r recursive, -0 null-separated, --event Updated
# We pipe into a while loop that reads full paths
fswatch -r -0 --event Updated "$SESSIONS_DIR" | while IFS= read -r -d '' filepath; do
  is_main_session_path "$filepath" || continue
  ACCUMULATED_LINES=$(( ACCUMULATED_LINES + 1 ))
  check_cron_ran
  if [ "$ACCUMULATED_LINES" -ge "$LINE_THRESHOLD" ]; then
    trigger_observer
  fi
done
