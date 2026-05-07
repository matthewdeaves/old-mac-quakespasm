#!/usr/bin/env bash
# Run the bench matrix on G3 and G4 concurrently.
# Cuts wall time roughly in half versus full-bench.sh both (which is sequential).
#
# usage: scripts/parallel-bench.sh [--reset] [--quick]
#   default:    appends to the rolling benchmarks/results.csv (history grows
#               across phases — that's how we see improvement over time).
#   --reset:    starts fresh epoch — wipes results.csv + raw/ first, but
#               backs up results.csv to results.csv.bak.<ts> if non-empty.
#               Use only when starting a brand new optimization round.
#   --keep-csv: deprecated no-op (kept for backward compat with old muscle memory).
#   --quick:    demo1 only × both res × 3 runs (forwarded to full-bench.sh)
#
# env vars (DEMOS / RESES / RUNS) are forwarded to full-bench.sh — see that
# script for the full set of overrides.
#
# pre: bundles deployed to both targets (scripts/deploy.sh g3 && scripts/deploy.sh g4)
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
#     our rows are ~80 B so rows from the two machines won't interleave.
#   - Raw log filenames include the machine name, so g3/g4 logs never collide.
#   - SSH connections to g4 and PowerMacG3 are independent.

set -euo pipefail

RESET=0
PASSTHRU=()  # extra flags forwarded to each full-bench.sh invocation (--quick etc)
for arg in "$@"; do
  case "$arg" in
    --reset)    RESET=1 ;;
    --keep-csv) ;;  # deprecated no-op; keep accepting it so old commands still work
    --quick)    PASSTHRU+=("$arg") ;;
    -h|--help)  sed -n '2,18p' "$0"; exit 0 ;;
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

# Pre-flight: kill any stale quakespasm on both machines.
echo "[parallel-bench] pre-flight: clearing stale quakespasm processes"
ssh -o ConnectTimeout=5 g4         'killall -KILL quakespasm 2>/dev/null || true' &
ssh -o ConnectTimeout=5 PowerMacG3 'killall -KILL quakespasm 2>/dev/null || true' &
wait

mkdir -p /tmp/parallel-bench-logs
G4_LOG=/tmp/parallel-bench-logs/g4.log
G3_LOG=/tmp/parallel-bench-logs/g3.log

echo "[parallel-bench] start: $(date)"
echo "[parallel-bench] G4 log: $G4_LOG"
echo "[parallel-bench] G3 log: $G3_LOG"

"$REPO_ROOT/scripts/full-bench.sh" g4 "${PASSTHRU[@]}" > "$G4_LOG" 2>&1 &
PID_G4=$!
"$REPO_ROOT/scripts/full-bench.sh" g3 "${PASSTHRU[@]}" > "$G3_LOG" 2>&1 &
PID_G3=$!

echo "[parallel-bench] g4 pid=$PID_G4, g3 pid=$PID_G3"

# Wait for both regardless of failure.
G4_RC=0; G3_RC=0
wait "$PID_G4" || G4_RC=$?
wait "$PID_G3" || G3_RC=$?

echo "[parallel-bench] g4 exit=$G4_RC   g3 exit=$G3_RC"
echo "[parallel-bench] done: $(date)"
echo
echo "=== rows for $COMMIT ==="
{ head -1 "$CSV"; grep ",$COMMIT," "$CSV" || true; } | column -t -s,

# Non-zero if either machine failed; preserves both CSV and raw logs.
if [ "$G4_RC" -ne 0 ] || [ "$G3_RC" -ne 0 ]; then
  echo "[parallel-bench] FAIL: at least one leg returned non-zero (g4=$G4_RC g3=$G3_RC)" >&2
  echo "[parallel-bench]       inspect $G4_LOG / $G3_LOG and benchmarks/raw/ for details" >&2
  exit 1
fi
