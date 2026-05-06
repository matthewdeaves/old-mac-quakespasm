#!/usr/bin/env bash
# Run the full v2 baseline matrix: G3 + G4 × demo1/demo2/demo3 × 1024x768 + 640x480.
# Each cell is 3 runs. ~24 runs/machine, ~30+ min wall on G3.
#
# usage: scripts/full-bench.sh [g3|g4|both]   default both
# pre:   build/quakespasm-{g3,g4} must exist and bundle deployed.

set -euo pipefail

TARGETS="${1:-both}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "$TARGETS" in
  both) MACHINES="g4 g3" ;;        # G4 first; finishes faster
  g3|g4) MACHINES="$TARGETS" ;;
  *) echo "usage: $0 [g3|g4|both]" >&2; exit 2 ;;
esac

DEMOS="demo1 demo2 demo3"
RESES="1024x768 640x480"

echo "[full-bench] matrix: machines=$MACHINES demos=$DEMOS reses=$RESES"
echo "[full-bench] start: $(date)"

for M in $MACHINES; do
  for R in $RESES; do
    for D in $DEMOS; do
      "$REPO_ROOT/scripts/bench.sh" "$M" "$D" "$R" 3
    done
  done
done

echo "[full-bench] done: $(date)"
echo "[full-bench] results: $REPO_ROOT/benchmarks/results.csv"
column -t -s, "$REPO_ROOT/benchmarks/results.csv" | tail -25
