#!/usr/bin/env bash
# Run timedemo benchmarks on a target machine and append results to the CSV.
# Assumes the bundle is already deployed (run scripts/deploy.sh first).
#
# usage: scripts/bench.sh <quad-leopard|yosemite|yosemite-tiger|sawtooth|quicksilver|mini-g4|mini-intel|imac-2019|imac-g5> <demo> <res> [<runs>]
#   demo: demo1 | demo2 | demo3
#   res:  WxH  e.g. 1024x768, 640x480
#   runs: default 3
#
# Machines (Apple-codename / form-factor naming):
#   yosemite     PowerMac1,1   B&W G3 449 MHz / Rage 128 / 10.3.9 Panther
#   yosemite-tiger  SAME BOX as yosemite, 2nd partition on 10.4.11 Tiger. Only
#                   one OS is booted at a time, so these two legs can never run
#                   concurrently — it is a separate CSV row for the Panther/Tiger
#                   A/B, not a separate machine.
#   sawtooth     PowerMac3,1   G4 AGP 500 MHz / GeForce2 MX / 10.4.11 Tiger
#   quicksilver  PowerMac3,5   G4 QS  733 MHz / Radeon 9000 / 10.4.11 Tiger
#   mini-g4      PowerMac10,1  Mac mini G4 1.25 GHz / Radeon 9200 / 10.4.11
#   mini-intel   Macmini2,1    C2D 2.33 GHz / GMA 950 / 10.7.5 Lion
#   imac-g5      PowerMac8,2   iMac G5 2.0 GHz / Radeon 9600 128 MB / 10.5.8 Leopard
#
# env: EXTRA_CVARS  optional cmdline cvar overrides spliced into the launch
#                   line right before +timedemo. Spliced as stuffcmds, so
#                   these run AFTER the per-machine autoexec — use to
#                   override individual cvars for A/B (e.g. shadows off):
#                     EXTRA_CVARS="+r_shadows 0" \
#                       scripts/bench.sh yosemite demo3 1024x768 3
#
# Per-machine autoexec: bench stages the per-arch + per-machine cfg
# concatenation as a temp `id1/autoexec.cfg` on the target before the run
# (loaded by quake.rc → exec autoexec.cfg). This makes bench fps reflect
# real-world play conditions (shadows, dlights, water alpha, etc.) instead
# of vanilla engine defaults. Resolution + per-run overrides still win
# because they're stuffcmds (`+vid_width N`, EXTRA_CVARS), which run AFTER
# exec autoexec.cfg. -noarchautoexec is kept so the CFBundle layer doesn't
# double-apply on top of the staged file. Cleanup removes the temp on exit.
#
# output: appends row to benchmarks/results.csv,
#         saves raw qconsole.log to benchmarks/raw/

set -euo pipefail

TARGET="${1:?usage: $0 <yosemite|yosemite-tiger|sawtooth|quicksilver|mini-g4|mini-intel> <demo> <WxH> [runs]}"

# Claim this machine for the whole run. See scripts/pick-bench-host.sh.
#
# Re-exec under the picker rather than acquire-here-and-trap: bash traps REPLACE
# rather than compose, so a release trap installed at the top of a script that
# later sets its own trap is silently discarded, and the machine stays claimed
# until the stale reclaim. `--run` makes the lock a property of the INVOCATION,
# so it is released however this exits, and no caller has to remember to do it.
#
# The lock lives on the target, so it serialises across repos, agents and
# workstations, not just this checkout. It also refuses a host booted into an OS
# its alias does not name, which the multi-boot machines otherwise allow.
#
# RETRO_BENCH_LOCK guards against the re-exec recursing.
# BENCH_NO_LOCK=1 skips the lock, for when the picker itself is what you are
# debugging. It is not a way to get past a machine someone else is using.
_PICK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pick-bench-host.sh"
if [ "${RETRO_BENCH_LOCK:-}" != "$TARGET" ] && [ "${BENCH_NO_LOCK:-0}" != 1 ] && [ -x "$_PICK" ]; then
	export RETRO_BENCH_LOCK="$TARGET"
	exec "$_PICK" --run "$TARGET" "bench" -- "$0" "$@"
fi
DEMO="${2:?demo name required (demo1|demo2|demo3)}"
RES="${3:?resolution required (e.g. 1024x768)}"
RUNS="${4:-3}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

W="${RES%x*}"
H="${RES#*x}"

# Reject a malformed resolution instead of silently benching nonsense. In the
# Quake II port, `bench.sh mini-g4 demo1 1` (meaning "1 run" — runs is the FOURTH
# arg) split to W=1 H=1, so the engine rendered a 1x1 pixel frame and reported
# 108-128 fps. Nine such rows were recorded and then quoted in the docs and
# machine configs as evidence for a config decision. A bench that measures the
# wrong thing is worse than no bench, because it gets quoted downstream.
case "$RES" in
  [0-9]*x[0-9]*) ;;
  *) echo "bench.sh: resolution must be WxH (e.g. 1024x768), got '$RES'" >&2
     echo "  usage: $0 <machine> <demo> <WxH> [runs]  — runs is the FOURTH arg" >&2
     exit 2 ;;
esac

# TARGET == SSH alias after the rename round; TIMEOUT scales with CPU class
# (Lion finishes timedemo in seconds; the G3 needs minutes).
#
# MACHINE_CFG is the per-machine autoexec overlay to stage, and defaults to
# TARGET. It differs only where one physical Mac appears under two TARGETs: the
# G3 has a Panther and a Tiger install, and the overlay is chosen at runtime by
# `sysctl hw.model`, which reports PowerMac1,1 on both — so both legs must stage
# autoexec-yosemite.cfg or the bench wouldn't match what a Finder launch does.
case "$TARGET" in
  yosemite)    HOST="yosemite";    TIMEOUT=240; ARCH_CFG="ppc750"; COOLDOWN=5 ;;
  yosemite-tiger)
               HOST="yosemite-tiger"; TIMEOUT=240; ARCH_CFG="ppc750"; COOLDOWN=5
               MACHINE_CFG="yosemite" ;;  # same PowerMac1,1, Tiger partition
  sawtooth)    HOST="sawtooth";    TIMEOUT=180; ARCH_CFG="ppc7400"; COOLDOWN=3 ;;  # 500 MHz G4 AGP — slower than other G4s
  quicksilver) HOST="quicksilver"; TIMEOUT=120; ARCH_CFG="ppc7400"; COOLDOWN=2 ;;
  mini-g4)     HOST="mini-g4";     TIMEOUT=120; ARCH_CFG="ppc7400"; COOLDOWN=2 ;;
  mini-intel)  HOST="mini-intel";  TIMEOUT=60;  ARCH_CFG="x86_64";  COOLDOWN=1 ;;
  imac-2019)   HOST="imac-2019";   TIMEOUT=45;  ARCH_CFG="x86_64";  COOLDOWN=1 ;;  # i5-9600K + Radeon Pro 580X — fastest
  imac-g5)     HOST="imac-g5";     TIMEOUT=110; ARCH_CFG="ppc970";  COOLDOWN=2 ;;  # 2 GHz G5 + Radeon 9600 — fastest PPC, Leopard
  quad-leopard)
               HOST="quad-leopard"; TIMEOUT=110; ARCH_CFG="ppc970"; COOLDOWN=2 ;;  # PowerMac11,2 quad 2.5 GHz + GeForce 6600, Leopard
  *) echo "unknown target: $TARGET" >&2; exit 2 ;;
esac
MACHINE_CFG="${MACHINE_CFG:-$TARGET}"
# COOLDOWN = settle time AFTER each run, before the next launch. The Rage 128
# (G3) and R300 (G5) drivers leave the display in a fragile state for a few
# seconds after a fullscreen exit, and launching straight back into fullscreen
# can hang the machine. The Quake II port has carried these values for months;
# this script had none. Default is deliberately non-zero so a machine added to
# the table above without a COOLDOWN still gets a settle.
COOLDOWN="${COOLDOWN:-2}"

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
( set -C; echo "timestamp,commit,machine,demo,res,run1_fps,run2_fps,run3_fps,median_fps,extra_cvars" > "$CSV" ) 2>/dev/null || true

# Stage temp id1/autoexec.cfg on the target = per-arch baseline + per-machine
# overlay concatenated. quake.rc's `exec autoexec.cfg` runs it BEFORE
# stuffcmds, so bench's `+vid_width N` / EXTRA_CVARS still win. -noarchautoexec
# below suppresses the CFBundle layer so the staged cfg is the only source
# of per-machine settings — no double-apply. EXIT trap cleans up so a normal
# Finder launch after the bench falls back to the bundle path (no stale id1/
# autoexec to double-apply on top of CFBundle).
TMP_AE=$(mktemp -t qsbenchae.XXXXXX)
# The per-machine overlay is OPTIONAL. A machine that has no tuned config of
# its own (quad-leopard is the first) benches on the per-arch baseline alone
# rather than failing the whole run on a missing file. Same spirit as the
# COOLDOWN default above: adding a row to the table should be enough.
cat "$REPO_ROOT/scripts/bundle/autoexec-$ARCH_CFG.cfg" > "$TMP_AE"
if [ -f "$REPO_ROOT/scripts/bundle/autoexec-$MACHINE_CFG.cfg" ]; then
  cat "$REPO_ROOT/scripts/bundle/autoexec-$MACHINE_CFG.cfg" >> "$TMP_AE"
else
  echo "[bench] no per-machine autoexec-$MACHINE_CFG.cfg — using autoexec-$ARCH_CFG.cfg only" >&2
fi
scp -q "$TMP_AE" "$HOST:Desktop/quake/id1/autoexec.cfg" || \
  echo "[bench] WARN: failed to stage autoexec.cfg on $HOST — bench will run vanilla" >&2
rm -f "$TMP_AE"
cleanup_autoexec () {
  # Also stop an engine left running. The per-run teardown covers the normal
  # path; this only matters when the SCRIPT dies (Ctrl-C, parent shell gone,
  # killed background job) with quakespasm still up on the target. That orphan
  # keeps the display captured and the next thing to launch goes fullscreen on
  # top of it — the Rage 128 / R300 wedge. Same TERM-grace-KILL policy as the
  # run loop. Costs nothing normally: there is no engine left to find.
  ssh -o ConnectTimeout=10 "$HOST" 'if killall -TERM quakespasm 2>/dev/null; then sleep 3; fi
    killall -KILL quakespasm 2>/dev/null
    rm -f ~/Desktop/quake/id1/autoexec.cfg
    true' 2>/dev/null || true
}
trap cleanup_autoexec EXIT INT TERM

declare -a FPS
for i in $(seq 1 $RUNS); do
  echo "[bench $TARGET $DEMO $RES] run $i/$RUNS"
  # Belt-and-suspenders: kill any stale quakespasm before each run.
  # Poll: integer `sleep 1` because Panther's /bin/sleep is integer-only
  # (sleep 0.2 returns instantly → busy-spin, kills demo at ~20s in).
  # Pre-run kill is the gentle TERM-grace-KILL pattern (same as the
  # post-run pattern below). A prior aborted run can leave quakespasm
  # in fullscreen; bare KILL without TERM trips Panther's Rage 128 LUT
  # corruption (black screen, mouse moves, OS up — recoverable only via
  # ~/bin/qsreboot.sh). `killall -TERM` returns 0 if anything matched,
  # so the `if` only sleeps when there's actually a stale process to
  # clean up. Costs 0s on the common case.
  # On qconsole.log match: SIGKILL — log is already on disk because Quake's
  # qconsole.log uses raw write() (no stdio buffering, see Quake/console.c:473).
  # `cd` MUST run BEFORE `&` (own line) so the parent shell's cwd is
  # ~/Desktop/quake — otherwise `[ -f qconsole.log ]` checks $HOME and never
  # matches. (`cd && X &` backgrounds the whole chain in a subshell.)
  ssh "$HOST" "if killall -TERM quakespasm 2>/dev/null; then sleep 2; fi
    killall -KILL quakespasm 2>/dev/null || true
    sleep 1
    cd ~/Desktop/quake
    rm -f qconsole.log
    ./Quakespasm.app/Contents/MacOS/quakespasm -nolauncher -basedir . -nosound -condebug \\
      -fullscreen \\
      -noarchautoexec \\
      +vid_width $W +vid_height $H +vid_wait 0 \\
      ${EXTRA_CVARS:+$EXTRA_CVARS }+timedemo $DEMO > /dev/null 2>&1 &
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
    # Settle before the next run: the display driver needs a few seconds after a
    # fullscreen exit, and going straight into the next launch can hang the box.
    sleep $COOLDOWN
    true" 2>&1 | grep -v "^$" | tail -3 || true

  # Tag the log with the cvars when this is an A/B leg. Without it both legs
  # write ${COMMIT}_${TARGET}_${DEMO}_${RES}_runN.log and the second leg
  # silently overwrites the first leg's raw evidence.
  # Long sweeps blow past the filesystem's 255-byte name limit, so cap the
  # readable part and append a hash of the FULL cvar string for uniqueness.
  # Short A/B legs keep their fully readable names.
  CVAR_TAG=""
  if [ -n "${EXTRA_CVARS:-}" ]; then
    CVAR_SLUG="$(printf '%s' "$EXTRA_CVARS" | tr -cs 'A-Za-z0-9' '_' | sed 's/^_//; s/_$//')"
    if [ "${#CVAR_SLUG}" -gt 60 ]; then
      CVAR_HASH="$(printf '%s' "$EXTRA_CVARS" | shasum -a 256 | cut -c1-8)"
      CVAR_SLUG="$(printf '%s' "$CVAR_SLUG" | cut -c1-60)_$CVAR_HASH"
    fi
    CVAR_TAG="_$CVAR_SLUG"
  fi
  LOG_NAME="${COMMIT}_${TARGET}_${DEMO}_${RES}${CVAR_TAG}_run${i}.log"

  # Delete first, and treat a failed fetch as a failed run. Previously this
  # was `scp || true` followed by a grep of $LOG_NAME: when the copy failed
  # the grep read whatever file was already at that path -- the previous
  # leg's log, or the previous run's -- and reported ITS fps as this run's.
  # That is not a missing number, it is a plausible number belonging to a
  # different configuration, written into results.csv without a warning.
  # Measured 2026-08-22 on yosemite: a decals-OFF leg recorded 34.6 fps for
  # run 3, which was the decals-ON leg's run 3, because qconsole.log was
  # missing on the target that run.
  rm -f "$RAW_DIR/$LOG_NAME"
  if scp -q "$HOST:Desktop/quake/qconsole.log" "$RAW_DIR/$LOG_NAME" 2>/dev/null; then
    FPS_VAL=$(grep -E 'frames.*seconds.*fps' "$RAW_DIR/$LOG_NAME" 2>/dev/null | tail -1 | awk '{print $5}' || true)
  else
    FPS_VAL=""
    echo "[bench] WARNING: could not fetch qconsole.log for run $i -- recording NA" >&2
    echo "[bench]          (target wrote no log; this run did NOT produce a number)" >&2
  fi
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

# extra_cvars is the LAST column on purpose: the 750 rows written before it
# existed have nine fields and stay parseable, and anything reading by index
# is unaffected. Without it the two arms of a cvar A/B are byte-identical in
# metadata and differ only in fps, which is indistinguishable from a noisy
# repeat -- and ADR 0009 requires that A/B as the evidence for a regression
# verdict. Measured 2026-08-22 on a decal A/B whose two rows could not be told
# apart afterwards. Quoted, and any embedded quote stripped, so a value
# containing a comma cannot shift the columns.
EXTRA_CSV=$(printf '%s' "${EXTRA_CVARS:-}" | tr -d '"')
echo "$TS,$COMMIT,$TARGET,$DEMO,$RES,${FPS[0]:-NA},${FPS[1]:-NA},${FPS[2]:-NA},$MEDIAN,\"$EXTRA_CSV\"" >> "$CSV"
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
