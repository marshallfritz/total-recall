#!/usr/bin/env bash
# config.sh — Shared constants for Total Recall scripts
#
# Source this file at the top of any TR script:
#   source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
#
# Change cascade: editing any constant here propagates to all sourcing scripts.
# See: cre/TRStrategyBootstrap.md §Lock Format and Change Cascade Registry
#
# Scripts that source this file:
#   - dream-cycle.sh
#   - dream-cycle-runner.sh
#   - preflight-archive.sh
#   - observer-agent.sh
#   - observer-watcher-macos.sh

# ── Lock settings ─────────────────────────────────────────────────────────────

# Max age for a valid dream-cycle.lock (seconds).
# Must exceed cron timeout (1200s) to prevent false stale-lock detection.
TR_LOCK_MAX_AGE=1500  # 25 min

# ── File size thresholds ──────────────────────────────────────────────────────

# Hard ceiling — Dream Cycle reliably fails above this
TR_OBS_CEILING_BYTES=40960       # 40KB

# Safe floor — proven completion threshold for Haiku/Gemini Flash
TR_OBS_SAFE_BYTES=34000          # 34KB

# Phase 2 trigger threshold — after Phase 1, if file still above this,
# flag Phase 2 as warranted (combined with age spread check)
TR_OBS_PHASE2_THRESHOLD=25600    # 25KB

# Mid-band decay trigger — if after Pass 1 (strip <3.0) file exceeds this,
# run Pass 2 deterministic decay (Class A-D rules)
TR_OBS_DECAY_THRESHOLD=34000     # same as safe floor

# ── Observer settings ─────────────────────────────────────────────────────────

# Minimum importance score for Observer to write an item
# Empirically validated: 6.5 produces ~115 lines/heavy session vs 300 at no floor
TR_IMPORTANCE_FLOOR=6.5

# Phase 2 trigger: minimum calendar day spread in observations to warrant pattern scan
TR_PHASE2_MIN_AGE_SPREAD_DAYS=7

# ── Cron job IDs (for manual trigger reference) ───────────────────────────────

TR_DREAM_CYCLE_JOB_ID="a50a6e7b-0446-4274-9344-a9cfaba62a3b"
