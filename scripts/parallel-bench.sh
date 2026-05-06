#!/usr/bin/env bash
# Run the v2 baseline matrix on G3 and G4 concurrently.
# Cuts wall time roughly in half versus full-bench.sh both (which is sequential).
#
# usage: scripts/parallel-bench.sh [--keep-csv]
#   default: clears benchmarks/raw/ and benchmarks/results.csv before running
#   --keep-csv: preserves existing results.csv (appends new rows instead)
#
# pre: bundles deployed to both targets (scripts/deploy.sh g3 && scripts/deploy.sh g4)
#
# Safety:
#   - CSV header init in bench.sh is atomic (bash noclobber); pre-creating the
#     CSV here is belt-and-suspenders.
#   - CSV row appends (>>) are atomic on Linux/macOS for writes < PIPE_BUF (4 KB);
#     our rows are ~80 B so rows from the two machines won't interleave.
#   - Raw log filenames include the machine name, so g3/g4 logs never collide.
#   - SSH connections to g4 and PowerMacG3 are independent.

set -euo pipefail

KEEP_CSV=0
if [ "${1:-}" = "--keep-csv" ]; then
  KEEP_CSV=1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CSV="$REPO_ROOT/benchmarks/results.csv"
RAW="$REPO_ROOT/benchmarks/raw"

if [ "$KEEP_CSV" -eq 0 ]; then
  rm -rf "$RAW"
  mkdir -p "$RAW"
  echo "timestamp,commit,machine,demo,res,run1_fps,run2_fps,run3_fps,median_fps" > "$CSV"
  echo "[parallel-bench] cleared raw/ and reset results.csv"
else
  mkdir -p "$RAW"
  # Pre-create CSV header (atomic) so neither bench.sh races on init.
  ( set -C; echo "timestamp,commit,machine,demo,res,run1_fps,run2_fps,run3_fps,median_fps" > "$CSV" ) 2>/dev/null || true
  echo "[parallel-bench] keeping existing results.csv"
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

"$REPO_ROOT/scripts/full-bench.sh" g4 > "$G4_LOG" 2>&1 &
PID_G4=$!
"$REPO_ROOT/scripts/full-bench.sh" g3 > "$G3_LOG" 2>&1 &
PID_G3=$!

echo "[parallel-bench] g4 pid=$PID_G4, g3 pid=$PID_G3"

# Wait for both regardless of failure.
G4_RC=0; G3_RC=0
wait "$PID_G4" || G4_RC=$?
wait "$PID_G3" || G3_RC=$?

echo "[parallel-bench] g4 exit=$G4_RC   g3 exit=$G3_RC"
echo "[parallel-bench] done: $(date)"
echo
echo "=== final results.csv ==="
column -t -s, "$CSV"

# Non-zero if either machine failed; preserves both CSV and raw logs.
if [ "$G4_RC" -ne 0 ] || [ "$G3_RC" -ne 0 ]; then
  exit 1
fi
