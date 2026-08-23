#!/usr/bin/env bash
# Bench the arm64 slice ON THIS Apple Silicon workstation and append a row
# to benchmarks/results.csv, same schema as bench.sh.
#
# usage: scripts/bench-arm64-local.sh <demo> <WxH> [<runs>]
#   demo: demo1 | demo2 | demo3
#   res:  WxH  e.g. 1920x1080
#   runs: default 3
#
# env: EXTRA_CVARS          per-run cvar overrides, same contract as bench.sh
#      QS_ARM64_BENCH_DIR   basedir holding Quakespasm.app + id1/pak0.pak
#                           (default ~/Desktop/qs-arm64-bench)
#      FULLSCREEN=1         run fullscreen (default windowed: this machine is
#                           the orchestration workstation and usually in use)
#
# WHY A SEPARATE SCRIPT (issue #29): bench.sh drives fleet machines over ssh
# and claims them via pick-bench-host.sh. The arm64 slice runs only on this
# workstation, which is not a fleet machine: no ssh, no bench lock, and its
# game content is a LOCAL copy of the user's own pak data (approved
# 2026-08-23), kept outside the repo per ADR 0012 -- we ship code, not
# content. Grafting a local branch through bench.sh's 300 lines of
# ssh-shaped logic would double its paths; this mirrors its contract
# (3 runs, median of 2+3, same CSV columns, raw logs kept) in a fraction
# of the surface.
#
# Machine name in the CSV is "arm64-local": distinct from every fleet alias
# and honest that the numbers come from whatever Apple Silicon Mac
# orchestrates the fleet (currently Mac17,4 / M5). Cross-machine
# comparability caveats live with the rows, not hidden.

set -euo pipefail

DEMO="${1:?usage: $0 <demo1|demo2|demo3> <WxH> [runs]}"
RES="${2:?usage: $0 <demo1|demo2|demo3> <WxH> [runs]}"
RUNS="${3:-3}"
W="${RES%x*}"
H="${RES#*x}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="${QS_ARM64_BENCH_DIR:-$HOME/Desktop/qs-arm64-bench}"
APP="$BASE/Quakespasm.app"
BIN_SRC="$REPO_ROOT/build/quakespasm-arm64"
BIN="$APP/Contents/MacOS/quakespasm"

[ "$(uname -m)" = "arm64" ] || { echo "[bench-arm64] this script runs on the Apple Silicon workstation only" >&2; exit 2; }
[ -f "$BASE/id1/pak0.pak" ] || { echo "[bench-arm64] no game content at $BASE/id1 (set QS_ARM64_BENCH_DIR)" >&2; exit 2; }
[ -f "$BIN_SRC" ] || { echo "[bench-arm64] build/quakespasm-arm64 missing -- run scripts/build-arm64.sh" >&2; exit 2; }
[ -d "$APP" ] || { echo "[bench-arm64] no staged Quakespasm.app at $BASE -- stage one first (see issue #29)" >&2; exit 2; }

# Refuse a stale slice, same rule build-fat.sh enforces (ADR 0014): a binary
# that doesn't match this tree produces a number attributed to the wrong code.
. "$REPO_ROOT/scripts/source-stamp.sh"
. "$REPO_ROOT/scripts/source-stamp-excludes.sh"
WANT="$(source_stamp_compute "$REPO_ROOT" "$SOURCE_STAMP_EXCLUDES")"
GOT="$(source_stamp_read "$REPO_ROOT/build/stamps/arm64")"
if [ "$WANT" != "$GOT" ]; then
  echo "[bench-arm64] arm64 slice is STALE (built from different source than this tree)" >&2
  echo "[bench-arm64]   rebuild: scripts/build-arm64.sh" >&2
  exit 1
fi

# Refresh the staged app's binary from the verified build and re-sign.
# Library Validation refuses an unsigned or seal-broken bundle on Apple
# Silicon (same reason make-dmg.sh signs, and the deploy.sh gap in #30).
cp "$BIN_SRC" "$BIN"
codesign --force --sign - "$APP" >/dev/null 2>&1
codesign -v "$APP" >/dev/null 2>&1 || { echo "[bench-arm64] staged bundle signature does not validate" >&2; exit 1; }

# Stage the shipped arm64 autoexec, comment-stripped the way deploy.sh ships
# it, so the bench measures the configuration players actually get.
# EXTRA_CVARS still wins (stuffcmds run after autoexec.cfg). -noarchautoexec
# keeps the CFBundle layer from double-applying, same as bench.sh.
mkdir -p "$BASE/id1"
sed -e 's,//.*,,' -e 's/[[:space:]]*$//' "$REPO_ROOT/scripts/bundle/autoexec-arm64.cfg" \
  | grep -v '^[[:space:]]*$' > "$BASE/id1/autoexec.cfg"

# Snapshot/restore id1/config.cfg around the run: Host_WriteConfiguration
# archives every CVAR_ARCHIVE cvar on exit and a pinned bench value would
# stick for later runs (issue #28, same protection bench.sh has).
if [ -f "$BASE/id1/config.cfg" ]; then
  cp -f "$BASE/id1/config.cfg" "$BASE/id1/config.cfg.qsbench-orig"
else
  rm -f "$BASE/id1/config.cfg.qsbench-orig"
  touch "$BASE/id1/.qsbench-no-config"
fi
cleanup () {
  # Engine first (a leftover instance would hold the next run's files), then
  # config restore, then the staged autoexec so a manual launch of the staged
  # app doesn't inherit bench state.
  if [ -n "${PID:-}" ] && kill -0 "$PID" 2>/dev/null; then
    kill -TERM "$PID" 2>/dev/null; sleep 2; kill -KILL "$PID" 2>/dev/null
  fi
  if [ -f "$BASE/id1/config.cfg.qsbench-orig" ]; then
    mv -f "$BASE/id1/config.cfg.qsbench-orig" "$BASE/id1/config.cfg"
  elif [ -f "$BASE/id1/.qsbench-no-config" ]; then
    rm -f "$BASE/id1/config.cfg"
  fi
  rm -f "$BASE/id1/.qsbench-no-config" "$BASE/id1/autoexec.cfg"
}
trap cleanup EXIT INT TERM

COMMIT="${COMMIT:-$(git -C "$REPO_ROOT" rev-parse --short HEAD)}"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RAW_DIR="$REPO_ROOT/benchmarks/raw"
CSV="$REPO_ROOT/benchmarks/results.csv"
mkdir -p "$RAW_DIR"
( set -C; echo "timestamp,commit,machine,demo,res,run1_fps,run2_fps,run3_fps,median_fps,extra_cvars" > "$CSV" ) 2>/dev/null || true

FS_ARGS="+vid_fullscreen 0"
[ "${FULLSCREEN:-0}" = "1" ] && FS_ARGS="+vid_fullscreen 1"

declare -a FPS
for i in $(seq 1 "$RUNS"); do
  echo "[bench-arm64 $DEMO $RES] run $i/$RUNS"
  rm -f "$BASE/qconsole.log"
  # shellcheck disable=SC2086
  "$BIN" -nolauncher -basedir "$BASE" -nosound -condebug -noarchautoexec \
    +vid_width "$W" +vid_height "$H" $FS_ARGS \
    ${EXTRA_CVARS:+$EXTRA_CVARS }+timedemo "$DEMO" > /dev/null 2>&1 &
  PID=$!
  j=0
  while [ $j -lt 60 ]; do
    if [ -f "$BASE/qconsole.log" ] && grep -q 'frames.*seconds.*fps\|Quake Error' "$BASE/qconsole.log" 2>/dev/null; then break; fi
    sleep 1; j=$((j+1))
  done
  kill -TERM "$PID" 2>/dev/null || true; sleep 1; kill -KILL "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
  PID=""

  CVAR_TAG=""
  if [ -n "${EXTRA_CVARS:-}" ]; then
    CVAR_SLUG="$(printf '%s' "$EXTRA_CVARS" | tr -cs 'A-Za-z0-9' '_' | sed 's/^_//; s/_$//')"
    if [ "${#CVAR_SLUG}" -gt 60 ]; then
      CVAR_HASH="$(printf '%s' "$EXTRA_CVARS" | shasum -a 256 | cut -c1-8)"
      CVAR_SLUG="$(printf '%s' "$CVAR_SLUG" | cut -c1-60)_$CVAR_HASH"
    fi
    CVAR_TAG="_$CVAR_SLUG"
  fi
  LOG_NAME="${COMMIT}_arm64-local_${DEMO}_${RES}${CVAR_TAG}_run${i}.log"
  # Delete-then-copy: a missing log is NA, never a stale number (bench.sh's
  # 2026-08-22 lesson).
  rm -f "$RAW_DIR/$LOG_NAME"
  if [ -f "$BASE/qconsole.log" ]; then
    cp "$BASE/qconsole.log" "$RAW_DIR/$LOG_NAME"
    FPS_VAL=$(grep -E 'frames.*seconds.*fps' "$RAW_DIR/$LOG_NAME" 2>/dev/null | tail -1 | awk '{print $5}' || true)
  else
    FPS_VAL=""
    echo "[bench-arm64] WARNING: no qconsole.log for run $i -- recording NA" >&2
  fi
  FPS+=("${FPS_VAL:-NA}")
  echo "  -> ${FPS_VAL:-NA} fps"
done

# Median rule, same as bench.sh: RUNS>=3 mean(run2,run3); ==2 mean(1,2); ==1 run1.
R1="${FPS[0]:-NA}"; R2="${FPS[1]:-NA}"; R3="${FPS[2]:-NA}"
if [ "$RUNS" -ge 3 ] && [ "$R2" != "NA" ] && [ "$R3" != "NA" ]; then
  MEDIAN=$(awk "BEGIN{printf \"%.2f\", ($R2+$R3)/2}")
elif [ "$RUNS" -eq 2 ] && [ "$R1" != "NA" ] && [ "$R2" != "NA" ]; then
  MEDIAN=$(awk "BEGIN{printf \"%.2f\", ($R1+$R2)/2}")
elif [ "$R1" != "NA" ]; then
  MEDIAN="$R1"
else
  MEDIAN="NA"
fi

EXTRA_CSV=$(printf '%s' "${EXTRA_CVARS:-}" | tr -d '"')
echo "$TS,$COMMIT,arm64-local,$DEMO,$RES,$R1,$R2,$R3,$MEDIAN,\"$EXTRA_CSV\"" >> "$CSV"
echo "[bench-arm64] median = $MEDIAN fps  →  $CSV"
