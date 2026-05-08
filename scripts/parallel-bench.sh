#!/usr/bin/env bash
# Run the bench matrix on G3, G4, and Lion concurrently.
# Cuts wall time roughly to the slowest leg vs running them sequentially.
# Lion finishes fastest, G4 mid, G3 slowest — so wall time tracks G3.
#
# usage: scripts/parallel-bench.sh [--reset] [--quick] [--no-lion]
#   default:    appends to the rolling benchmarks/results.csv (history grows
#               across phases — that's how we see improvement over time).
#   --reset:    starts fresh epoch — wipes results.csv + raw/ first, but
#               backs up results.csv to results.csv.bak.<ts> if non-empty.
#               Use only when starting a brand new optimization round.
#   --keep-csv: deprecated no-op (kept for backward compat with old muscle memory).
#   --quick:    demo1 only × both res × 3 runs (forwarded to full-bench.sh)
#   --no-lion:  skip the Lion leg (useful if Lion is offline or building)
#
# env vars (DEMOS / RESES / RUNS) are forwarded to full-bench.sh — see that
# script for the full set of overrides.
#
# pre: bundles deployed to all targets you're benching (scripts/deploy.sh
#      g3 && scripts/deploy.sh g4 && scripts/deploy.sh lion).
#
# Hash stability: HEAD is resolved once at script start and exported as $COMMIT
# so every cell of the grid tags consistently in results.csv, even if a side
# commit lands while the bench is running. (Without this, cells that ran after
# the side commit would tag with the new hash and split the baseline.)
#
# Safety:
#   - CSV header init in bench.sh is atomic (bash noclobber); pre-creating the
#     CSV here is belt-and-suspenders.
#   - CSV row appends (>>) are atomic on Linux/macOS for writes < PIPE_BUF (4 KB);
#     our rows are ~80 B so rows from the three machines won't interleave.
#   - Raw log filenames include the machine name, so legs never collide.
#   - SSH connections to g4, PowerMacG3, and lion are independent.

set -euo pipefail

RESET=0
NO_LION=0
PASSTHRU=()  # extra flags forwarded to each full-bench.sh invocation (--quick etc)
for arg in "$@"; do
  case "$arg" in
    --reset)    RESET=1 ;;
    --keep-csv) ;;  # deprecated no-op; keep accepting it so old commands still work
    --quick)    PASSTHRU+=("$arg") ;;
    --no-lion)  NO_LION=1 ;;
    -h|--help)  sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CSV="$REPO_ROOT/benchmarks/results.csv"
RAW="$REPO_ROOT/benchmarks/raw"

# Pin the commit hash for the whole grid. bench.sh honors $COMMIT if exported,
# else falls back to its own `git rev-parse`. Exporting here means side commits
# during the bench can't drift the tags.
COMMIT=$(git -C "$REPO_ROOT" rev-parse --short HEAD)
export COMMIT
echo "[parallel-bench] tagging all rows with commit $COMMIT"

if [ "$RESET" -eq 1 ]; then
  if [ -s "$CSV" ] && [ "$(wc -l < "$CSV")" -gt 1 ]; then
    BACKUP="$CSV.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    cp "$CSV" "$BACKUP"
    echo "[parallel-bench] --reset: backed up existing results.csv → $BACKUP"
  fi
  rm -rf "$RAW"
  mkdir -p "$RAW"
  echo "timestamp,commit,machine,demo,res,run1_fps,run2_fps,run3_fps,median_fps" > "$CSV"
  echo "[parallel-bench] --reset: wiped raw/ and results.csv (fresh epoch)"
else
  mkdir -p "$RAW"
  # Pre-create CSV header (atomic) so neither bench.sh races on init.
  ( set -C; echo "timestamp,commit,machine,demo,res,run1_fps,run2_fps,run3_fps,median_fps" > "$CSV" ) 2>/dev/null || true
  EXISTING_ROWS=$(($(wc -l < "$CSV") - 1))
  echo "[parallel-bench] appending to rolling results.csv ($EXISTING_ROWS existing rows)"
fi

# Pre-flight: kill any stale quakespasm on all benched machines.
echo "[parallel-bench] pre-flight: clearing stale quakespasm processes"
ssh -o ConnectTimeout=5 g4         'killall -KILL quakespasm 2>/dev/null || true' &
ssh -o ConnectTimeout=5 PowerMacG3 'killall -KILL quakespasm 2>/dev/null || true' &
if [ "$NO_LION" -eq 0 ]; then
  ssh -o ConnectTimeout=5 lion     'killall -KILL quakespasm 2>/dev/null || true' &
fi
wait

mkdir -p /tmp/parallel-bench-logs
G4_LOG=/tmp/parallel-bench-logs/g4.log
G3_LOG=/tmp/parallel-bench-logs/g3.log
LION_LOG=/tmp/parallel-bench-logs/lion.log

echo "[parallel-bench] start: $(date)"
echo "[parallel-bench] G4   log: $G4_LOG"
echo "[parallel-bench] G3   log: $G3_LOG"
[ "$NO_LION" -eq 0 ] && echo "[parallel-bench] Lion log: $LION_LOG"

"$REPO_ROOT/scripts/full-bench.sh" g4 "${PASSTHRU[@]}" > "$G4_LOG" 2>&1 &
PID_G4=$!
"$REPO_ROOT/scripts/full-bench.sh" g3 "${PASSTHRU[@]}" > "$G3_LOG" 2>&1 &
PID_G3=$!
PID_LION=""
if [ "$NO_LION" -eq 0 ]; then
  "$REPO_ROOT/scripts/full-bench.sh" lion "${PASSTHRU[@]}" > "$LION_LOG" 2>&1 &
  PID_LION=$!
  echo "[parallel-bench] g4 pid=$PID_G4, g3 pid=$PID_G3, lion pid=$PID_LION"
else
  echo "[parallel-bench] g4 pid=$PID_G4, g3 pid=$PID_G3 (lion skipped)"
fi

# Wait for all legs regardless of failure.
G4_RC=0; G3_RC=0; LION_RC=0
wait "$PID_G4" || G4_RC=$?
wait "$PID_G3" || G3_RC=$?
if [ -n "$PID_LION" ]; then
  wait "$PID_LION" || LION_RC=$?
fi

if [ -n "$PID_LION" ]; then
  echo "[parallel-bench] g4 exit=$G4_RC   g3 exit=$G3_RC   lion exit=$LION_RC"
else
  echo "[parallel-bench] g4 exit=$G4_RC   g3 exit=$G3_RC   (lion skipped)"
fi
echo "[parallel-bench] done: $(date)"
echo
echo "=== rows for $COMMIT ==="
{ head -1 "$CSV"; grep ",$COMMIT," "$CSV" || true; } | column -t -s,

# Non-zero if any benched machine failed; preserves CSV and raw logs.
if [ "$G4_RC" -ne 0 ] || [ "$G3_RC" -ne 0 ] || [ "$LION_RC" -ne 0 ]; then
  echo "[parallel-bench] FAIL: at least one leg returned non-zero (g4=$G4_RC g3=$G3_RC lion=$LION_RC)" >&2
  echo "[parallel-bench]       inspect $G4_LOG / $G3_LOG / $LION_LOG and benchmarks/raw/ for details" >&2
  exit 1
fi
