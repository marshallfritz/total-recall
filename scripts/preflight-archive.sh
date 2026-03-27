#!/usr/bin/env bash
# preflight-archive.sh — Pre-Dream Cycle size gate
# Runs at 4:30 AM EDT daily. If observations.md > 40KB, archives items
# with dc:importance < 3.0 (minimal band: no-ops, duplicates, expired).
# Items >= 3.0 are untouched. Dream Cycle runs at 5 AM on cleaned file.
#
# Usage:
#   OPENCLAW_WORKSPACE=/path/to/workspace bash preflight-archive.sh

set -uo pipefail

WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}"
OBSERVATIONS="$WORKSPACE/memory/observations.md"
ARCHIVE_DIR="$WORKSPACE/memory/archive/observations"
BACKUP_DIR="$WORKSPACE/memory/.dream-backups"
LOG_FILE="$WORKSPACE/logs/preflight-archive.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DREAM_CYCLE="$SCRIPT_DIR/dream-cycle.sh"
TODAY="$(date +%Y-%m-%d)"
NOW="$(date '+%Y-%m-%dT%H:%M:%S')"
SIZE_CEILING_BYTES=40960  # 40KB

mkdir -p "$ARCHIVE_DIR" "$BACKUP_DIR" "$(dirname "$LOG_FILE")"

log() {
  echo "[$(date '+%Y-%m-%dT%H:%M:%S')] [preflight-archive] $*" | tee -a "$LOG_FILE"
}

log "=== Preflight archive START ==="

# ── Check file exists ────────────────────────────────────────────────────────
if [[ ! -f "$OBSERVATIONS" ]]; then
  log "observations.md not found at $OBSERVATIONS — nothing to do"
  log "=== Preflight archive END (no-op) ==="
  exit 0
fi

# ── Check size ───────────────────────────────────────────────────────────────
CURRENT_BYTES=$(wc -c < "$OBSERVATIONS" | tr -d ' ')
CURRENT_WORDS=$(wc -w < "$OBSERVATIONS" | tr -d ' ')
log "observations.md: ${CURRENT_BYTES} bytes / ${CURRENT_WORDS} words"

if (( CURRENT_BYTES <= SIZE_CEILING_BYTES )); then
  log "Size ${CURRENT_BYTES}B is within ceiling ${SIZE_CEILING_BYTES}B — no archive needed"
  log "=== Preflight archive END (no-op) ==="
  exit 0
fi

log "⚠️  Size ${CURRENT_BYTES}B exceeds ceiling ${SIZE_CEILING_BYTES}B — running minimal archive pass"

# ── Backup before any changes ────────────────────────────────────────────────
BACKUP_FILE="$BACKUP_DIR/observations.pre-preflight-${TODAY}.md"
cp "$OBSERVATIONS" "$BACKUP_FILE"
log "Backup written: $BACKUP_FILE"

# ── Extract items with dc:importance < 3.0 ──────────────────────────────────
# Strategy: identify observation lines with explicit dc:importance scores below 3.0
# These are the "minimal" band: no-ops, duplicates, superseded, trivial entries.
# Lines without dc:importance are left untouched (conservative).

ARCHIVE_FILE="$ARCHIVE_DIR/${TODAY}-preflight.md"
TEMP_OBS=$(mktemp)
TEMP_ARCHIVE=$(mktemp)
ARCHIVED_COUNT=0
RETAINED_COUNT=0

# Write archive header
cat > "$TEMP_ARCHIVE" <<EOF
# Preflight Archive — ${TODAY}
Archived by preflight-archive.sh (auto) — minimal band (dc:importance < 3.0) only.
Size at run time: ${CURRENT_BYTES} bytes.
---
EOF

# Python script to split observations into archive/retain
python3 - "$OBSERVATIONS" "$TEMP_OBS" "$TEMP_ARCHIVE" <<'PYEOF'
import sys, re

obs_file = sys.argv[1]
retain_file = sys.argv[2]
archive_file = sys.argv[3]

IMPORTANCE_PATTERN = re.compile(r'dc:importance=(\d+\.?\d*)')
THRESHOLD = 3.0

with open(obs_file, 'r', encoding='utf-8') as f:
    lines = f.readlines()

retain_lines = []
archive_lines = []
archived = 0
retained = 0

i = 0
while i < len(lines):
    line = lines[i]
    # Check if this line has an importance score
    match = IMPORTANCE_PATTERN.search(line)
    if match:
        importance = float(match.group(1))
        if importance < THRESHOLD:
            archive_lines.append(line)
            archived += 1
        else:
            retain_lines.append(line)
            retained += 1
    else:
        retain_lines.append(line)
        retained += 1
    i += 1

with open(retain_file, 'w', encoding='utf-8') as f:
    f.writelines(retain_lines)

with open(archive_file, 'a', encoding='utf-8') as f:
    f.writelines(archive_lines)

print(f"archived={archived} retained={retained}")
PYEOF

RESULT=$(python3 - "$OBSERVATIONS" "$TEMP_OBS" "$TEMP_ARCHIVE" 2>&1 <<'PYEOF'
import sys, re

obs_file = sys.argv[1]
retain_file = sys.argv[2]
archive_file = sys.argv[3]

IMPORTANCE_PATTERN = re.compile(r'dc:importance=(\d+\.?\d*)')
THRESHOLD = 3.0

with open(obs_file, 'r', encoding='utf-8') as f:
    lines = f.readlines()

retain_lines = []
archive_lines = []
archived = 0
retained = 0

for line in lines:
    match = IMPORTANCE_PATTERN.search(line)
    if match:
        importance = float(match.group(1))
        if importance < THRESHOLD:
            archive_lines.append(line)
            archived += 1
        else:
            retain_lines.append(line)
            retained += 1
    else:
        retain_lines.append(line)
        retained += 1

with open(retain_file, 'w', encoding='utf-8') as f:
    f.writelines(retain_lines)

with open(archive_file, 'a', encoding='utf-8') as f:
    f.writelines(archive_lines)

print(f"archived={archived} retained={retained}")
PYEOF
)

ARCHIVED_COUNT=$(echo "$RESULT" | grep -o 'archived=[0-9]*' | cut -d= -f2)
RETAINED_COUNT=$(echo "$RESULT" | grep -o 'retained=[0-9]*' | cut -d= -f2)

if [[ -z "$ARCHIVED_COUNT" || "$ARCHIVED_COUNT" -eq 0 ]]; then
  log "No items scored < 3.0 found — nothing archived"
  rm -f "$TEMP_OBS" "$TEMP_ARCHIVE"
  log "=== Preflight archive END (no minimal items) ==="
  exit 0
fi

# ── Atomic write ─────────────────────────────────────────────────────────────
mv "$TEMP_OBS" "$OBSERVATIONS"
cat "$TEMP_ARCHIVE" >> "$ARCHIVE_FILE"
rm -f "$TEMP_ARCHIVE"

NEW_BYTES=$(wc -c < "$OBSERVATIONS" | tr -d ' ')
NEW_WORDS=$(wc -w < "$OBSERVATIONS" | tr -d ' ')
REDUCTION=$(( CURRENT_BYTES - NEW_BYTES ))

log "✅ Archive complete: removed=$ARCHIVED_COUNT retained=$RETAINED_COUNT"
log "   Before: ${CURRENT_BYTES}B / ${CURRENT_WORDS} words"
log "   After:  ${NEW_BYTES}B / ${NEW_WORDS} words (saved ${REDUCTION}B)"
log "   Archive: $ARCHIVE_FILE"
log "   Backup:  $BACKUP_FILE"

if (( NEW_BYTES > SIZE_CEILING_BYTES )); then
  log "⚠️  File still above ceiling after minimal archive (${NEW_BYTES}B > ${SIZE_CEILING_BYTES}B)"
  log "   Manual archive of items 3.0–5.0 may be needed before Dream Cycle"
fi

log "=== Preflight archive END ==="
exit 0
