#!/usr/bin/env bash
# dream-cycle-runner.sh — Observable wrapper for the Dream Cycle agent
#
# Runs the Dream Cycle cron payload as a shell-supervised job with:
#   - Persistent tailable log (logs/dream-cycle-run.log)
#   - Structured stage markers with timestamps
#   - Start/end time capture for duration tracking
#   - Append-only log format (one block per run)
#
# Usage:
#   OPENCLAW_WORKSPACE=/path/to/workspace bash dream-cycle-runner.sh
#
# Tail during a run:
#   tail -f ~/.openclaw/workspace/logs/dream-cycle-run.log

set -euo pipefail

OPENCLAW_WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}"
SKILL_DIR="$OPENCLAW_WORKSPACE/skills/total-recall"
LOG_FILE="$OPENCLAW_WORKSPACE/logs/dream-cycle-run.log"
DREAM_PROMPT="$SKILL_DIR/prompts/dream-cycle-prompt.md"

# Load .env for OBSERVER_MODEL etc.
if [ -f "$OPENCLAW_WORKSPACE/.env" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$OPENCLAW_WORKSPACE/.env"
  set +a
fi

mkdir -p "$(dirname "$LOG_FILE")"

# ── Timestamp helpers ──────────────────────────────────────────────────────────

ts()      { date '+%Y-%m-%d %H:%M:%S'; }
ts_iso()  { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
ts_date() { date '+%Y-%m-%d'; }

# ── Logging helpers ────────────────────────────────────────────────────────────

# Write to both the log file and stdout (so cron summary captures it too)
log() {
  local level="$1"; shift
  local msg="$*"
  printf '[%s] [%-7s] %s\n' "$(ts)" "$level" "$msg" | tee -a "$LOG_FILE"
}

log_raw() {
  printf '%s\n' "$*" | tee -a "$LOG_FILE"
}

# ── Run header/footer ──────────────────────────────────────────────────────────

RUN_ID="$(ts_date)-$(date '+%H%M%S')"
START_EPOCH=$(date +%s)

write_run_header() {
  log_raw ""
  log_raw "════════════════════════════════════════════════════════════"
  log_raw "  Dream Cycle Run — $RUN_ID"
  log_raw "  Started : $(ts)"
  log_raw "  Workspace: $OPENCLAW_WORKSPACE"
  log_raw "════════════════════════════════════════════════════════════"
}

write_run_footer() {
  local status="$1"
  local end_epoch
  end_epoch=$(date +%s)
  local duration=$(( end_epoch - START_EPOCH ))
  local mins=$(( duration / 60 ))
  local secs=$(( duration % 60 ))

  log_raw "────────────────────────────────────────────────────────────"
  log_raw "  Run ID  : $RUN_ID"
  log_raw "  Status  : $status"
  log_raw "  Duration: ${mins}m ${secs}s (${duration}s)"
  log_raw "  Ended   : $(ts)"

  # Append a one-line summary to the run history CSV
  local history_file="$OPENCLAW_WORKSPACE/logs/dream-cycle-history.csv"
  if [ ! -f "$history_file" ]; then
    printf 'run_id,start_epoch,end_epoch,duration_seconds,status,obs_before_bytes,obs_after_bytes\n' > "$history_file"
  fi

  local obs_before_bytes=0 obs_after_bytes=0
  if [ -f "$OPENCLAW_WORKSPACE/memory/observations.md" ]; then
    obs_after_bytes=$(wc -c < "$OPENCLAW_WORKSPACE/memory/observations.md")
  fi

  # Read pre-dream backup size if present
  local backup="$OPENCLAW_WORKSPACE/memory/.dream-backups/observations.pre-dream.md"
  if [ -f "$backup" ]; then
    obs_before_bytes=$(wc -c < "$backup")
  fi

  printf '%s,%s,%s,%s,%s,%s,%s\n' \
    "$RUN_ID" "$START_EPOCH" "$end_epoch" "$duration" \
    "$status" "$obs_before_bytes" "$obs_after_bytes" \
    >> "$history_file"

  log_raw "════════════════════════════════════════════════════════════"
  log_raw ""
}

# ── Stage marker ──────────────────────────────────────────────────────────────

stage() {
  log INFO "── STAGE: $* ──"
}

# ── Pre-flight size check (mirrors hc-runbook §1) ─────────────────────────────

preflight_size_check() {
  local obs="$OPENCLAW_WORKSPACE/memory/observations.md"
  [ -f "$obs" ] || { log WARN "observations.md not found — skipping size check"; return; }

  local bytes words
  bytes=$(wc -c < "$obs")
  words=$(wc -w < "$obs")

  log INFO "observations.md — ${bytes} bytes / ${words} words"

  if [ "$bytes" -gt 40960 ]; then
    log WARN "❌ observations.md OVER ceiling (${bytes}B > 40960B) — Dream Cycle may time out"
    log WARN "   Run preflight-archive.sh first, or manual archive pass required"
  elif [ "$bytes" -gt 34000 ]; then
    log WARN "⚠️  observations.md approaching ceiling (${bytes}B)"
  else
    log INFO "✅ observations.md within ceiling"
  fi
}

# ── Dream Cycle script hooks ───────────────────────────────────────────────────
# We watch the script subcommands as they're called and emit stage markers.
# Since the Dream Cycle runs as an LLM agent (not shell), we can't intercept
# its calls directly — but we can log the before/after state of each artifact.

watch_artifacts() {
  local phase="$1"  # "before" or "after"

  local obs="$OPENCLAW_WORKSPACE/memory/observations.md"
  local backup_dir="$OPENCLAW_WORKSPACE/memory/.dream-backups"
  local archive_dir="$OPENCLAW_WORKSPACE/memory/archive/observations"
  local log_dir="$OPENCLAW_WORKSPACE/memory/dream-logs"
  local metrics_dir="$OPENCLAW_WORKSPACE/research/dream-cycle-metrics/daily"

  log INFO "[$phase] Artifact state:"

  if [ -f "$obs" ]; then
    log INFO "  observations.md : $(wc -c < "$obs") bytes / $(wc -w < "$obs") words"
  else
    log INFO "  observations.md : NOT FOUND"
  fi

  # Most recent archive file
  local latest_archive
  latest_archive=$(ls -t "$archive_dir"/*.md 2>/dev/null | head -1 || echo "none")
  if [ "$latest_archive" != "none" ] && [ -f "$latest_archive" ]; then
    log INFO "  latest archive  : $(basename "$latest_archive") ($(wc -c < "$latest_archive") bytes)"
  fi

  # Most recent dream log
  local latest_log
  latest_log=$(ls -t "$log_dir"/*.md 2>/dev/null | head -1 || echo "none")
  if [ "$latest_log" != "none" ] && [ -f "$latest_log" ]; then
    local log_mtime
    log_mtime=$(date -r "$latest_log" '+%H:%M:%S' 2>/dev/null || stat -f '%Sm' -t '%H:%M:%S' "$latest_log" 2>/dev/null || echo "?")
    log INFO "  latest dream log: $(basename "$latest_log") (modified $log_mtime)"
  fi

  # Most recent metrics
  local today_metrics="$metrics_dir/$(ts_date).json"
  if [ -f "$today_metrics" ]; then
    local archived reduction
    archived=$(python3 -c "import json,sys; d=json.load(open('$today_metrics')); print(d.get('observations_archived','?'))" 2>/dev/null || echo "?")
    reduction=$(python3 -c "import json,sys; d=json.load(open('$today_metrics')); print(d.get('reduction_pct','?'))" 2>/dev/null || echo "?")
    log INFO "  metrics (today) : archived=$archived reduction=${reduction}%"
  fi
}

# ── Poll loop: watch for run completion ───────────────────────────────────────
# The Dream Cycle runs as an isolated LLM agent. We can't join its process —
# instead we poll for the post-run artifact changes. Poll every 15s for up to
# MAX_WAIT_SECS (20 min default, matching cron 1200s timeout).

poll_for_completion() {
  local max_wait="${DREAM_RUNNER_MAX_WAIT:-1200}"
  local poll_interval=15
  local elapsed=0
  local obs="$OPENCLAW_WORKSPACE/memory/observations.md"
  local backup="$OPENCLAW_WORKSPACE/memory/.dream-backups/observations.pre-dream.md"
  local metrics_file="$OPENCLAW_WORKSPACE/research/dream-cycle-metrics/daily/$(ts_date).json"

  # Capture the modification time of observations.md before the run
  local before_mtime
  before_mtime=$(stat -f '%m' "$obs" 2>/dev/null || stat -c '%Y' "$obs" 2>/dev/null || echo "0")

  # Capture pre-run metrics timestamp if present (we look for a newer one)
  local before_metrics_mtime=0
  [ -f "$metrics_file" ] && before_metrics_mtime=$(stat -f '%m' "$metrics_file" 2>/dev/null || stat -c '%Y' "$metrics_file" 2>/dev/null || echo "0")

  log INFO "Polling for run completion (max ${max_wait}s, interval ${poll_interval}s)..."
  log INFO "Watching: observations.md mtime + metrics file"

  while [ "$elapsed" -lt "$max_wait" ]; do
    sleep "$poll_interval"
    elapsed=$(( elapsed + poll_interval ))

    local current_mtime
    current_mtime=$(stat -f '%m' "$obs" 2>/dev/null || stat -c '%Y' "$obs" 2>/dev/null || echo "0")

    local current_metrics_mtime=0
    [ -f "$metrics_file" ] && current_metrics_mtime=$(stat -f '%m' "$metrics_file" 2>/dev/null || stat -c '%Y' "$metrics_file" 2>/dev/null || echo "0")

    # Run is complete when EITHER observations.md has been updated OR a new metrics file appeared
    if [ "$current_mtime" != "$before_mtime" ] || [ "$current_metrics_mtime" -gt "$before_metrics_mtime" ]; then
      log INFO "✅ Run complete detected at ${elapsed}s"
      return 0
    fi

    # Progress heartbeat every minute
    if [ $(( elapsed % 60 )) -eq 0 ]; then
      log INFO "  ...still waiting (${elapsed}s elapsed)"
    fi
  done

  log WARN "⚠️  Timeout reached after ${max_wait}s — run may still be in progress"
  return 1
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  write_run_header

  stage "Pre-flight checks"
  preflight_size_check

  stage "Artifact state (before run)"
  watch_artifacts "before"

  stage "Trigger check"
  log INFO "Dream Cycle is managed as an OpenClaw cron job."
  log INFO "Trigger: use 'openclaw cron run total-recall-dream-cycle' or wait for 5 AM schedule."
  log INFO "This wrapper observes the run — it does not invoke the LLM agent directly."
  log INFO ""
  log INFO "If you want to trigger AND observe in one step:"
  log INFO "  1. Run: openclaw cron run total-recall-dream-cycle (or via cron tool)"
  log INFO "  2. Then: tail -f $LOG_FILE"
  log INFO ""
  log INFO "This wrapper is typically invoked AFTER triggering the cron job, to:"
  log INFO "  - Record pre/post artifact state"
  log INFO "  - Poll for completion"
  log INFO "  - Capture duration in history CSV"

  stage "Polling for completion"
  local poll_status="ok"
  poll_for_completion || poll_status="timeout"

  stage "Artifact state (after run)"
  watch_artifacts "after"

  # Summarize the diff
  stage "Run delta"
  local backup="$OPENCLAW_WORKSPACE/memory/.dream-backups/observations.pre-dream.md"
  local obs="$OPENCLAW_WORKSPACE/memory/observations.md"
  if [ -f "$backup" ] && [ -f "$obs" ]; then
    local before_bytes after_bytes delta
    before_bytes=$(wc -c < "$backup")
    after_bytes=$(wc -c < "$obs")
    delta=$(( before_bytes - after_bytes ))
    if [ "$delta" -gt 0 ]; then
      local pct
      pct=$(python3 -c "print(round($delta/$before_bytes*100,1))" 2>/dev/null || echo "?")
      log INFO "Size: ${before_bytes}B → ${after_bytes}B (saved ${delta}B / ${pct}% reduction)"
    elif [ "$delta" -lt 0 ]; then
      log WARN "Size GREW: ${before_bytes}B → ${after_bytes}B (+$(( -delta ))B)"
    else
      log INFO "Size unchanged: ${before_bytes}B"
    fi
  fi

  local final_status="ok"
  [ "$poll_status" = "timeout" ] && final_status="timeout"

  write_run_footer "$final_status"
}

main "$@"
