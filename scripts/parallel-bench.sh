#!/usr/bin/env bash
# Run the bench matrix on all 6 machines concurrently.
# Cuts wall time roughly to the slowest leg (G3) vs sequential.
#
# Machines (Apple-codename / form-factor naming):
#   yosemite     PowerMac G3 B&W 449 MHz, Rage 128, 10.3.9 Panther
#   yosemite-tiger  the SAME G3, booted from its 10.4.11 Tiger partition (opt-in)
#   sawtooth     PowerMac G4 AGP 500 MHz, GeForce2 MX, 10.4.11 Tiger
#   quicksilver  PowerMac G4    733 MHz, Radeon 9000, 10.4.11 Tiger
#   mini-g4      Mac mini G4   1.25 GHz, Radeon 9200, 10.4.11 Tiger
#   mini-intel   Mac mini Intel 2.33 GHz Core 2 Duo, GMA 950, 10.7.5 Lion
#   imac-2019    iMac 27" 2019, i5-9600K @ 3.70 GHz, Radeon Pro 580X 8GB, 15.7.5 Sequoia
#
# usage: scripts/parallel-bench.sh [--reset] [--quick] [--no-<machine> ...]
#   default:    runs all 6 machines and appends to rolling benchmarks/results.csv.
#               History grows across phases — that's how we see improvement.
#   --reset:    starts fresh epoch — wipes results.csv + raw/ first, but backs
#               up results.csv to results.csv.bak.<ts> if non-empty.
#               Use only when starting a brand new optimization round.
#   --keep-csv: deprecated no-op (kept for backward compat with old muscle memory).
#   --quick:    demo1 only × both res × 3 runs (forwarded to full-bench.sh).
#   --no-yosemite     skip the G3 leg (rarely wanted — G3 is the playability floor)
#   --yosemite-tiger  bench the G3 from its Tiger partition INSTEAD of Panther.
#                     Both are the same Mac on the same IP with one OS booted, so
#                     they are mutually exclusive: this flag implies --no-yosemite.
#   --no-sawtooth     skip the Sawtooth G4 leg
#   --no-quicksilver  skip the Quicksilver G4 leg
#   --no-mini-g4      skip the Mac mini G4 leg
#   --no-mini-intel   skip the Intel Mac mini leg (use if Lion is offline)
#   --no-imac-2019    skip the 2019 iMac leg
#
# env vars (DEMOS / RESES / RUNS) are forwarded to full-bench.sh — see that
# script for the full set of overrides.
#
# pre: bundles deployed to every target you're benching (scripts/deploy.sh
#      <machine> for each). All three G4 machines share build/quakespasm-g4.
#
# Hash stability: HEAD is resolved once at script start and exported as $COMMIT
# so every cell tags consistently in results.csv, even if a side commit lands
# while the bench is running.
#
# Safety:
#   - CSV header init in bench.sh is atomic (bash noclobber); pre-creating the
#     CSV here is belt-and-suspenders.
#   - CSV row appends (>>) are atomic on Linux/macOS for writes < PIPE_BUF (4 KB);
#     our rows are ~80 B so rows from machines won't interleave.
#   - Raw log filenames include the machine name, so legs never collide.
#   - SSH connections to all 5 hosts are independent.

set -euo pipefail

RESET=0
declare -A SKIP
SKIP[yosemite]=0
# Opt-in only: same physical Mac as yosemite, so it can never run alongside it.
SKIP[yosemite-tiger]=1
SKIP[sawtooth]=0
SKIP[quicksilver]=0
SKIP[mini-g4]=0
SKIP[mini-intel]=0
SKIP[imac-2019]=0
SKIP[imac-g5]=0
PASSTHRU=()  # extra flags forwarded to full-bench.sh (--quick etc)
for arg in "$@"; do
  case "$arg" in
    --reset)            RESET=1 ;;
    --keep-csv)         ;;  # deprecated no-op
    --quick)            PASSTHRU+=("$arg") ;;
    --no-yosemite)      SKIP[yosemite]=1 ;;
    --yosemite-tiger)   SKIP[yosemite-tiger]=0; SKIP[yosemite]=1 ;;
    --no-yosemite-tiger) SKIP[yosemite-tiger]=1 ;;
    --no-sawtooth)      SKIP[sawtooth]=1 ;;
    --no-quicksilver)   SKIP[quicksilver]=1 ;;
    --no-mini-g4)       SKIP[mini-g4]=1 ;;
    --no-mini-intel)    SKIP[mini-intel]=1 ;;
    --no-imac-2019)     SKIP[imac-2019]=1 ;;
    --no-imac-g5)       SKIP[imac-g5]=1 ;;
    -h|--help)          sed -n '2,33p' "$0"; exit 0 ;;
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
  ( set -C; echo "timestamp,commit,machine,demo,res,run1_fps,run2_fps,run3_fps,median_fps" > "$CSV" ) 2>/dev/null || true
  EXISTING_ROWS=$(($(wc -l < "$CSV") - 1))
  echo "[parallel-bench] appending to rolling results.csv ($EXISTING_ROWS existing rows)"
fi

# Active legs — preserve fastest → slowest order so the wall-time tail
# corresponds to the G3.
ALL_LEGS=(imac-2019 mini-intel imac-g5 quicksilver mini-g4 sawtooth yosemite yosemite-tiger)
ACTIVE_LEGS=()
for LEG in "${ALL_LEGS[@]}"; do
  [ "${SKIP[$LEG]}" -eq 0 ] && ACTIVE_LEGS+=("$LEG")
done

# yosemite and yosemite-tiger are two OS installs on ONE Mac at one IP. Running
# both would have two legs fighting over the same box (and only one could
# possibly be booted), so refuse rather than produce a half-bogus grid.
if [ "${SKIP[yosemite]}" -eq 0 ] && [ "${SKIP[yosemite-tiger]}" -eq 0 ]; then
  echo "[parallel-bench] yosemite and yosemite-tiger are the same machine — pick one" >&2
  exit 2
fi

if [ "${#ACTIVE_LEGS[@]}" -eq 0 ]; then
  echo "[parallel-bench] all legs skipped — nothing to do" >&2
  exit 2
fi

# Pre-flight: kill any stale quakespasm on every active machine.
# Each leg's machine name == its SSH alias after the rename round.
#
# Through the picker, one claim per leg. This kill used to run bare, before the
# legs below claim anything, so it killed the engine on machines this run did
# not hold -- truncating another repo's timedemo mid-flight, silently, with no
# error on either side. A shortened run does not look like a failure; it looks
# like a slow machine. See issue #18.
#
# Claiming here also means a leg whose machine is genuinely busy is skipped by
# the picker rather than cleared out from under its owner.
#
# RETRO_BENCH_LOCK guard, and it is load-bearing rather than decoration.
# pick-bench-host.sh:246 ends try_acquire with a bare `mkdir "$L" || exit 1`, so
# acquiring is NOT reentrant: it fails even when the caller already holds the
# lock. And cmd_run at :306 releases UNCONDITIONALLY when its command finishes,
# so a nested --run would hand the machine away while the outer work is still
# running. Both checked in this repo's copy of the picker. So a script that is a
# STEP INSIDE already-claimed work must not re-claim, and the guard is what
# tells the two cases apart.
echo "[parallel-bench] pre-flight: clearing stale quakespasm processes (TERM-grace-KILL — Rage 128 LUT fix)"
_PICK="$REPO_ROOT/scripts/pick-bench-host.sh"
for LEG in "${ACTIVE_LEGS[@]}"; do
  if [ -z "${RETRO_BENCH_LOCK:-}" ] && [ "${BENCH_NO_LOCK:-0}" != 1 ] && [ -x "$_PICK" ]; then
    "$_PICK" --run "$LEG" "preflight" -- \
      ssh -o ConnectTimeout=5 "$LEG" 'if killall -TERM quakespasm 2>/dev/null; then sleep 2; fi
        killall -KILL quakespasm 2>/dev/null || true' &
  else
    ssh -o ConnectTimeout=5 "$LEG" 'if killall -TERM quakespasm 2>/dev/null; then sleep 2; fi
      killall -KILL quakespasm 2>/dev/null || true' &
  fi
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
  printf "[parallel-bench] %-12s log: %s\n" "$LEG" "${LEG_LOG[$LEG]}"
done

# Launch each active leg in the background; full-bench.sh handles the per-target
# matrix sweep and bench.sh writes its rows directly to the shared CSV (atomic
# small appends — see header comment).
for LEG in "${ACTIVE_LEGS[@]}"; do
  "$REPO_ROOT/scripts/full-bench.sh" "$LEG" "${PASSTHRU[@]}" > "${LEG_LOG[$LEG]}" 2>&1 &
  LEG_PID[$LEG]=$!
  printf "[parallel-bench] %-12s pid=%s\n" "$LEG" "${LEG_PID[$LEG]}"
done

# Wait for all legs regardless of failure — we want the partial CSV either way.
for LEG in "${ACTIVE_LEGS[@]}"; do
  RC=0
  wait "${LEG_PID[$LEG]}" || RC=$?
  LEG_RC[$LEG]=$RC
done

EXIT_LINE="[parallel-bench]"
for LEG in "${ALL_LEGS[@]}"; do
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
