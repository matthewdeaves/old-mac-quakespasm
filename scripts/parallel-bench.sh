#!/usr/bin/env bash
# Run the bench matrix on G3, G4 (Quicksilver), G4 mini, and Lion concurrently.
# Cuts wall time roughly to the slowest leg vs running them sequentially.
# Lion finishes fastest, G4/G4mini mid, G3 slowest — so wall time tracks G3.
#
# usage: scripts/parallel-bench.sh [--reset] [--quick] [--no-lion] [--no-g4mini]
#                                  [--no-g4] [--no-g3]
#   default:      runs all 4 legs (g3, g4, g4mini, lion) and appends to the
#                 rolling benchmarks/results.csv. History grows across phases —
#                 that's how we see improvement over time.
#   --reset:      starts fresh epoch — wipes results.csv + raw/ first, but
#                 backs up results.csv to results.csv.bak.<ts> if non-empty.
#                 Use only when starting a brand new optimization round.
#   --keep-csv:   deprecated no-op (kept for backward compat with old muscle memory).
#   --quick:      demo1 only × both res × 3 runs (forwarded to full-bench.sh).
#   --no-lion:    skip the Lion leg (useful if Lion is offline or building).
#   --no-g4mini:  skip the G4 mini leg (useful if it's offline).
#   --no-g4:      skip the Quicksilver G4 leg.
#   --no-g3:      skip the G3 leg (rarely wanted — G3 is the playability floor).
#
# env vars (DEMOS / RESES / RUNS) are forwarded to full-bench.sh — see that
# script for the full set of overrides.
#
# pre: bundles deployed to every target you're benching (scripts/deploy.sh
#      g3 && scripts/deploy.sh g4 && scripts/deploy.sh g4mini && scripts/deploy.sh lion).
#      g4mini reuses build/quakespasm-g4 (same arch/SDK as Quicksilver), so no
#      separate build step is required for it.
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
#     our rows are ~80 B so rows from the four machines won't interleave.
#   - Raw log filenames include the machine name, so legs never collide.
#   - SSH connections to g4, g4mini, PowerMacG3, and lion are independent.

set -euo pipefail

RESET=0
NO_LION=0
NO_G4MINI=0
NO_G4=0
NO_G3=0
PASSTHRU=()  # extra flags forwarded to each full-bench.sh invocation (--quick etc)
for arg in "$@"; do
  case "$arg" in
    --reset)      RESET=1 ;;
    --keep-csv)   ;;  # deprecated no-op; keep accepting it so old commands still work
    --quick)      PASSTHRU+=("$arg") ;;
    --no-lion)    NO_LION=1 ;;
    --no-g4mini)  NO_G4MINI=1 ;;
    --no-g4)      NO_G4=1 ;;
    --no-g3)      NO_G3=1 ;;
    -h|--help)    sed -n '2,25p' "$0"; exit 0 ;;
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

# Active-leg map. Skipping all four is silly but legal — the resulting bench is
# a no-op and bench-and-commit.sh will exit 1 because no rows landed.
ACTIVE_LEGS=()
[ "$NO_G3"     -eq 0 ] && ACTIVE_LEGS+=(g3)
[ "$NO_G4"     -eq 0 ] && ACTIVE_LEGS+=(g4)
[ "$NO_G4MINI" -eq 0 ] && ACTIVE_LEGS+=(g4mini)
[ "$NO_LION"   -eq 0 ] && ACTIVE_LEGS+=(lion)

if [ "${#ACTIVE_LEGS[@]}" -eq 0 ]; then
  echo "[parallel-bench] all legs skipped — nothing to do" >&2
  exit 2
fi

# Pre-flight: kill any stale quakespasm on every active machine.
# Each leg's host alias is identical to its tag, except g3 maps to PowerMacG3.
host_for_leg() {
  case "$1" in
    g3)     echo PowerMacG3 ;;
    g4)     echo g4 ;;
    g4mini) echo g4mini ;;
    lion)   echo lion ;;
  esac
}

echo "[parallel-bench] pre-flight: clearing stale quakespasm processes"
for LEG in "${ACTIVE_LEGS[@]}"; do
  HOST=$(host_for_leg "$LEG")
  ssh -o ConnectTimeout=5 "$HOST" 'killall -KILL quakespasm 2>/dev/null || true' &
done
wait

mkdir -p /tmp/parallel-bench-logs
declare -A LEG_LOG LEG_PID LEG_RC
for LEG in "${ACTIVE_LEGS[@]}"; do
  LEG_LOG[$LEG]="/tmp/parallel-bench-logs/${LEG}.log"
done

echo "[parallel-bench] start: $(date)"
echo "[parallel-bench] active legs: ${ACTIVE_LEGS[*]}"
for LEG in "${ACTIVE_LEGS[@]}"; do
  printf "[parallel-bench] %-7s log: %s\n" "$LEG" "${LEG_LOG[$LEG]}"
done

# Launch each active leg in the background; full-bench.sh handles the per-target
# matrix sweep and bench.sh writes its rows directly to the shared CSV (atomic
# small appends — see header comment).
for LEG in "${ACTIVE_LEGS[@]}"; do
  "$REPO_ROOT/scripts/full-bench.sh" "$LEG" "${PASSTHRU[@]}" > "${LEG_LOG[$LEG]}" 2>&1 &
  LEG_PID[$LEG]=$!
  printf "[parallel-bench] %-7s pid=%s\n" "$LEG" "${LEG_PID[$LEG]}"
done

# Wait for all legs regardless of failure — we want the partial CSV either way.
for LEG in "${ACTIVE_LEGS[@]}"; do
  RC=0
  wait "${LEG_PID[$LEG]}" || RC=$?
  LEG_RC[$LEG]=$RC
done

EXIT_LINE="[parallel-bench]"
for LEG in g3 g4 g4mini lion; do
  if [[ -n "${LEG_PID[$LEG]:-}" ]]; then
    EXIT_LINE+=" $LEG=${LEG_RC[$LEG]}"
  else
    EXIT_LINE+=" $LEG=skipped"
  fi
done
echo "$EXIT_LINE"
echo "[parallel-bench] done: $(date)"
echo
echo "=== rows for $COMMIT ==="
{ head -1 "$CSV"; grep ",$COMMIT," "$CSV" || true; } | column -t -s,

# Non-zero if any benched machine failed; preserves CSV and raw logs.
ANY_FAIL=0
for LEG in "${ACTIVE_LEGS[@]}"; do
  [ "${LEG_RC[$LEG]}" -ne 0 ] && ANY_FAIL=1
done
if [ "$ANY_FAIL" -ne 0 ]; then
  echo "[parallel-bench] FAIL: at least one leg returned non-zero" >&2
  for LEG in "${ACTIVE_LEGS[@]}"; do
    if [ "${LEG_RC[$LEG]}" -ne 0 ]; then
      echo "[parallel-bench]       $LEG (rc=${LEG_RC[$LEG]}): ${LEG_LOG[$LEG]}" >&2
    fi
  done
  echo "[parallel-bench]       also see benchmarks/raw/ for per-cell qconsole logs" >&2
  exit 1
fi
