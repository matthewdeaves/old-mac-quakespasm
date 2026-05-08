#!/usr/bin/env bash
# Run a benchmark matrix sweep on G3 + G4 + Lion (or any subset).
#
# usage: scripts/full-bench.sh [g3|g4|lion|both|all] [--quick]
#   both:  g3 + g4 (PPC pair, the historical default)
#   all:   g3 + g4 + lion (adds the Intel reference)
#
# default matrix: demo1+demo2+demo3 × 1024x768+640x480 × 3 runs
# --quick:        demo1 only      × 1024x768+640x480 × 3 runs   (~5–10× faster)
#
# env-var overrides (take precedence over both default and --quick):
#   DEMOS="demo1 demo3"   (default: "demo1 demo2 demo3"; --quick: "demo1")
#   RESES="640x480"       (default: "1024x768 640x480")
#   RUNS=2                (default: 3)
#
# pre: build/quakespasm-{g3,g4,lion} must exist and bundle deployed
#      to whichever targets you're benching.

set -euo pipefail

TARGETS=both
QUICK=0
for arg in "$@"; do
  case "$arg" in
    g3|g4|lion|both|all) TARGETS=$arg ;;
    --quick)    QUICK=1 ;;
    -h|--help)  sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "$TARGETS" in
  both) MACHINES="g4 g3" ;;                # PPC pair; G4 first (finishes faster)
  all)  MACHINES="lion g4 g3" ;;           # Lion smokes through fastest, then G4, then G3
  g3|g4|lion) MACHINES="$TARGETS" ;;
esac

if [ "$QUICK" -eq 1 ]; then
  DEMOS="${DEMOS:-demo1}"
  RESES="${RESES:-1024x768 640x480}"
  RUNS="${RUNS:-3}"
  LABEL="quick"
else
  DEMOS="${DEMOS:-demo1 demo2 demo3}"
  RESES="${RESES:-1024x768 640x480}"
  RUNS="${RUNS:-3}"
  LABEL="full"
fi

echo "[full-bench] mode=$LABEL  machines=$MACHINES  demos=$DEMOS  reses=$RESES  runs=$RUNS"
echo "[full-bench] start: $(date)"

for M in $MACHINES; do
  for R in $RESES; do
    for D in $DEMOS; do
      "$REPO_ROOT/scripts/bench.sh" "$M" "$D" "$R" "$RUNS"
    done
  done
done

echo "[full-bench] done: $(date)"
echo "[full-bench] results: $REPO_ROOT/benchmarks/results.csv"
column -t -s, "$REPO_ROOT/benchmarks/results.csv" | tail -25
