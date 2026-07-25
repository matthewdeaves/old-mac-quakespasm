#!/usr/bin/env bash
# Run a benchmark matrix sweep on the bench machines (or any subset).
#
# Machines (Apple-codename / form-factor naming):
#   yosemite     PowerMac G3 B&W 449 MHz, Rage 128, 10.3.9 Panther
#   yosemite-tiger  the SAME G3, booted from its 10.4.11 Tiger partition
#   sawtooth     PowerMac G4 AGP 500 MHz, GeForce2 MX, 10.4.11 Tiger
#   quicksilver  PowerMac G4    733 MHz, Radeon 9000, 10.4.11 Tiger
#   mini-g4      Mac mini G4   1.25 GHz, Radeon 9200, 10.4.11 Tiger
#   mini-intel   Mac mini Intel 2.33 GHz Core 2 Duo, GMA 950, 10.7.5 Lion
#   imac-2019    iMac 27" 2019, i5-9600K @ 3.70 GHz, Radeon Pro 580X 8GB, 15.7.5 Sequoia
#   imac-g5      iMac G5 PowerMac8,2 2.0 GHz, Radeon 9600 128MB, 10.5.8 Leopard
#
# usage: scripts/full-bench.sh [<machine>|ppc|all] [--quick]
#   ppc:    yosemite + sawtooth + quicksilver + mini-g4 + imac-g5 (skip the Intel boxes)
#   intel:  mini-intel + imac-2019 (Intel-only sweep)
#   all:    all 7 machines (default)
#
# `yosemite-tiger` is deliberately NOT in the ppc/all sets: it is the same
# physical Mac as `yosemite` with a different OS booted, so the two can never be
# reached in the same run. Ask for it by name when the G3 is booted into Tiger.
#
# default matrix: demo1+demo2+demo3 × 1024x768+640x480 × 3 runs
# --quick:        demo1 only      × 1024x768+640x480 × 3 runs   (~5–10× faster)
#
# env-var overrides (take precedence over both default and --quick):
#   DEMOS="demo1 demo3"   (default: "demo1 demo2 demo3"; --quick: "demo1")
#   RESES="640x480"       (default: "1024x768 640x480")
#   RUNS=2                (default: 3)
#
# pre: build/quakespasm-{g3,g4,lion} must exist and the bundle deployed
#      to each machine being benched. The three G4 machines (sawtooth,
#      quicksilver, mini-g4) all share build/quakespasm-g4.

set -euo pipefail

TARGETS=all
QUICK=0
for arg in "$@"; do
  case "$arg" in
    yosemite|yosemite-tiger|sawtooth|quicksilver|mini-g4|mini-intel|imac-2019|imac-g5|ppc|intel|all) TARGETS=$arg ;;
    --quick)    QUICK=1 ;;
    -h|--help)  sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Order: fastest → slowest (so the long-pole G3 finishes last when invoked
# sequentially; parallel-bench.sh launches them concurrently regardless).
case "$TARGETS" in
  ppc)   MACHINES="imac-g5 quicksilver mini-g4 sawtooth yosemite" ;;
  intel) MACHINES="imac-2019 mini-intel" ;;
  all)   MACHINES="imac-2019 mini-intel imac-g5 quicksilver mini-g4 sawtooth yosemite" ;;
  yosemite|yosemite-tiger|sawtooth|quicksilver|mini-g4|mini-intel|imac-2019|imac-g5) MACHINES="$TARGETS" ;;
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
