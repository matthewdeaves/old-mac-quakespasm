#!/usr/bin/env bash
# Run timedemo benchmarks on a target PPC machine and append results to the CSV.
# Assumes the bundle is already deployed (run scripts/deploy.sh first).
#
# usage: scripts/bench.sh <g3|g4> <demo> <res> [<runs>]
#   demo: demo1 | demo2 | demo3
#   res:  WxH  e.g. 1024x768, 640x480
#   runs: default 3
#
# output: appends row to benchmarks/results.csv,
#         saves raw qconsole.log to benchmarks/raw/

set -euo pipefail

TARGET="${1:?usage: $0 <g3|g4> <demo> <WxH> [runs]}"
DEMO="${2:?demo name required (demo1|demo2|demo3)}"
RES="${3:?resolution required (e.g. 1024x768)}"
RUNS="${4:-3}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

W="${RES%x*}"
H="${RES#*x}"

case "$TARGET" in
  g3) HOST="PowerMacG3"; TIMEOUT=240 ;;
  g4) HOST="g4";         TIMEOUT=120 ;;
  *) echo "unknown target: $TARGET" >&2; exit 2 ;;
esac

# Stable hash through a long matrix run: callers (parallel-bench.sh,
# bench-and-commit.sh) resolve HEAD once and export $COMMIT so every cell
# tags consistently, even if a side commit lands during the bench.
# Standalone invocations fall back to resolving HEAD here.
COMMIT="${COMMIT:-$(git -C "$REPO_ROOT" rev-parse --short HEAD)}"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RAW_DIR="$REPO_ROOT/benchmarks/raw"
CSV="$REPO_ROOT/benchmarks/results.csv"
mkdir -p "$RAW_DIR"

# CSV header (initialize once). Atomic via bash noclobber (`set -C` →
# O_CREAT|O_EXCL), so two parallel bench.sh procs racing on a missing
# CSV will result in exactly one header row.
( set -C; echo "timestamp,commit,machine,demo,res,run1_fps,run2_fps,run3_fps,median_fps" > "$CSV" ) 2>/dev/null || true

declare -a FPS
for i in $(seq 1 $RUNS); do
  echo "[bench $TARGET $DEMO $RES] run $i/$RUNS"
  # Belt-and-suspenders: pkill any stale quakespasm before each run.
  # Poll: integer `sleep 1` because Panther's /bin/sleep is integer-only
  # (sleep 0.2 returns instantly → busy-spin, kills demo at ~20s in).
  # On match: SIGKILL immediately — the log is already on disk because Quake's
  # qconsole.log uses raw write() (no stdio buffering, see Quake/console.c:473).
  # `cd` MUST run BEFORE `&` (own line) so the parent shell's cwd is
  # ~/Desktop/quake — otherwise `[ -f qconsole.log ]` checks $HOME and never
  # matches. (`cd && X &` backgrounds the whole chain in a subshell.)
  ssh "$HOST" "killall -KILL quakespasm 2>/dev/null
    sleep 1
    cd ~/Desktop/quake
    rm -f qconsole.log
    ./Quakespasm.app/Contents/MacOS/quakespasm -nolauncher -basedir . -nosound -condebug \\
      -fullscreen -width $W -height $H \\
      +vid_wait 0 \\
      +timedemo $DEMO > /dev/null 2>&1 &
    PID=\$!
    j=0
    while [ \$j -lt $TIMEOUT ]; do
      if [ -f qconsole.log ] && grep -q 'frames.*seconds.*fps\\|Quake Error' qconsole.log 2>/dev/null; then break; fi
      sleep 1; j=\$((j+1))
    done
    # PPC port -- Panther's Rage 128 driver leaves the display LUT
    # corrupt if Quake is hard-killed in fullscreen mode. Send TERM
    # first so SDL_Quit has a chance to restore display state, then
    # KILL the SDL/CoreAudio threads that don't respond to TERM.
    killall -TERM quakespasm 2>/dev/null
    sleep 2
    killall -KILL quakespasm 2>/dev/null
    wait \$PID 2>/dev/null
    true" 2>&1 | grep -v "^$" | tail -3 || true

  LOG_NAME="${COMMIT}_${TARGET}_${DEMO}_${RES}_run${i}.log"
  scp -q "$HOST:Desktop/quake/qconsole.log" "$RAW_DIR/$LOG_NAME" || true
  FPS_VAL=$(grep -E 'frames.*seconds.*fps' "$RAW_DIR/$LOG_NAME" 2>/dev/null | tail -1 | awk '{print $5}' || true)
  FPS+=("${FPS_VAL:-NA}")
  echo "  -> ${FPS_VAL:-NA} fps"
done

# Median rule:
#   RUNS>=3: mean(run2, run3)        — drops the cold/warmup run 1
#   RUNS==2: mean(run1, run2)        — both kept (warmup bias is noise at this scale)
#   RUNS==1: run1
if [ "$RUNS" -ge 3 ] && [ "${FPS[1]:-NA}" != "NA" ] && [ "${FPS[2]:-NA}" != "NA" ]; then
  MEDIAN=$(awk -v a="${FPS[1]}" -v b="${FPS[2]}" 'BEGIN{printf "%.2f", (a+b)/2}')
  MEDIAN_LABEL="median(run2,run3)"
elif [ "$RUNS" -eq 2 ] && [ "${FPS[0]:-NA}" != "NA" ] && [ "${FPS[1]:-NA}" != "NA" ]; then
  MEDIAN=$(awk -v a="${FPS[0]}" -v b="${FPS[1]}" 'BEGIN{printf "%.2f", (a+b)/2}')
  MEDIAN_LABEL="mean(run1,run2)"
else
  MEDIAN="${FPS[$((RUNS-1))]:-NA}"
  MEDIAN_LABEL="run${RUNS}"
fi

echo "$TS,$COMMIT,$TARGET,$DEMO,$RES,${FPS[0]:-NA},${FPS[1]:-NA},${FPS[2]:-NA},$MEDIAN" >> "$CSV"
echo "[bench] $MEDIAN_LABEL = $MEDIAN fps  →  $CSV"

# Surface NA runs so the orchestrator (parallel-bench.sh) exits non-zero
# instead of silently shipping a half-failed grid. A timeout, crash, or
# missing fps line in qconsole.log all collapse to NA — without this
# check, a run that didn't actually happen looks like a successful row.
NA_COUNT=0
for v in "${FPS[@]}"; do [ "$v" = "NA" ] && NA_COUNT=$((NA_COUNT+1)); done
if [ "$NA_COUNT" -gt 0 ]; then
  echo "[bench] FAIL: $NA_COUNT/${RUNS} run(s) returned NA on $TARGET $DEMO $RES" >&2
  echo "[bench]       check $RAW_DIR/${COMMIT}_${TARGET}_${DEMO}_${RES}_run*.log" >&2
  exit 1
fi
