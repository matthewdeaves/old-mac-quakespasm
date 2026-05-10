#!/usr/bin/env bash
#
# profile-pass.sh — capture per-function hot lists across the bench matrix.
#
# Two profilers per target class:
#   - G3 (yosemite): gprof via -pg-instrumented binary. Runs Quake with
#     `+timedemo demo3 +quit` so the program exits cleanly and libgmon
#     writes gmon.out next to the binary. Then gprof on Ubuntu (the
#     cross-build host has the symbols, but we run gprof here for
#     portability — gmon.out is architecture-agnostic in format and the
#     binary carries the symbol table).
#   - G4 trio (sawtooth/quicksilver/mini-g4): Apple `sample(1)` —
#     statistical stack sampler, no recompilation needed. Attaches to a
#     running PID for N seconds, prints stack-aggregation report.
#
# Output:
#   benchmarks/profile/<commit>/<host>_<demo>_<res>.gprof   (G3)
#   benchmarks/profile/<commit>/<host>_<demo>_<res>.sample  (G4 trio)
#   benchmarks/profile/<commit>/SUMMARY.md                  (top-30 cross-machine)
#
# Pre-requisites:
#   - For G3: build/quakespasm-g3 must be `BUILD_PG=1` instrumented.
#     Build with: `BUILD_PG=1 scripts/build.sh g3` then deploy to yosemite.
#   - For G4 trio: standard build/quakespasm-g4 deployed already.
#   - Ubuntu workstation must have gprof (binutils package) for G3 post-process.
#
# Usage:
#   scripts/profile-pass.sh [--demo demoN] [--res WxH] [--sample-secs N]
#                           [--no-yosemite] [--no-sawtooth] [--no-quicksilver]
#                           [--no-mini-g4]
#   Defaults: demo3 1024x768, sample 30 seconds.
#
# Why demo3: dlight-heavy demo where the renderer hot loops are exercised.
# Different demos surface different hot lists (demo1 = brush-heavy,
# demo2 = water-heavy, demo3 = dlight-heavy + alias-heavy); rerun for
# multiple demos to triangulate.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DEMO=demo3
RES=1024x768
SAMPLE_SECS=30
SKIP_YOSEMITE=0
SKIP_SAWTOOTH=0
SKIP_QUICKSILVER=0
SKIP_MINI_G4=0

while [ $# -gt 0 ]; do
  case "$1" in
    --demo)         DEMO="$2"; shift 2 ;;
    --res)          RES="$2";  shift 2 ;;
    --sample-secs)  SAMPLE_SECS="$2"; shift 2 ;;
    --no-yosemite)    SKIP_YOSEMITE=1; shift ;;
    --no-sawtooth)    SKIP_SAWTOOTH=1; shift ;;
    --no-quicksilver) SKIP_QUICKSILVER=1; shift ;;
    --no-mini-g4)     SKIP_MINI_G4=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

W="${RES%x*}"
H="${RES#*x}"
COMMIT=$(git -C "$REPO_ROOT" rev-parse --short HEAD)
OUT_DIR="$REPO_ROOT/benchmarks/profile/$COMMIT"
mkdir -p "$OUT_DIR"

echo "[profile-pass] commit $COMMIT, demo=$DEMO, res=${W}x${H}"
echo "[profile-pass] output → $OUT_DIR/"

# ---------------------------------------------------------------------------
# G3 yosemite: gprof via -pg instrumented binary
# ---------------------------------------------------------------------------
if [ "$SKIP_YOSEMITE" = "0" ]; then
  echo ""
  echo "[profile-pass] === G3 yosemite gprof capture ==="

  # Sanity check: the binary on yosemite must be -pg instrumented. The
  # `nm` symbol __mcount appears in any -pg binary (libgmon hook).
  if ! ssh yosemite "nm Desktop/quake/Quakespasm.app/Contents/MacOS/quakespasm 2>/dev/null | grep -q __mcount\\\$"; then
    echo "[profile-pass] WARN: yosemite binary not -pg instrumented."
    echo "[profile-pass]       Build with: BUILD_PG=1 scripts/build.sh g3"
    echo "[profile-pass]       Deploy:     scripts/deploy.sh yosemite"
    echo "[profile-pass]       Skipping G3 gprof capture."
  else
    echo "[profile-pass] yosemite binary is -pg instrumented (good)"

    # Run with +quit so libgmon writes gmon.out on clean exit.
    # Don't kill the process; let timedemo+quit drive it. Use a
    # timeout in case timedemo hangs (paranoia).
    ssh yosemite "
      cd ~/Desktop/quake
      rm -f gmon.out qconsole.log
      ./Quakespasm.app/Contents/MacOS/quakespasm -nolauncher -basedir . -nosound -condebug \
        -fullscreen -width $W -height $H \
        -noarchautoexec \
        +vid_wait 0 \
        +timedemo $DEMO +quit > /dev/null 2>&1 &
      PID=\$!
      # Poll for clean exit. If quakespasm is still running after 6 minutes,
      # the timedemo hung; kill (which sacrifices gmon.out but the demo
      # didn't run anyway).
      i=0
      while [ \$i -lt 360 ] && kill -0 \$PID 2>/dev/null; do
        sleep 1; i=\$((i+1))
      done
      if kill -0 \$PID 2>/dev/null; then
        echo '[profile-pass] yosemite timedemo did not exit cleanly; killing'
        kill -KILL \$PID 2>/dev/null || true
      fi
      ls -la gmon.out qconsole.log 2>/dev/null | head -3
    "

    # Fetch gmon.out + the timedemo line for cross-check.
    scp -q "yosemite:Desktop/quake/gmon.out" "$OUT_DIR/yosemite_${DEMO}_${RES}.gmon" || {
      echo "[profile-pass] FAIL: gmon.out missing on yosemite (timedemo may have hung)"
    }
    scp -q "yosemite:Desktop/quake/qconsole.log" "$OUT_DIR/yosemite_${DEMO}_${RES}.qconsole" || true

    # Run gprof on Ubuntu against the local binary copy.
    if [ -f "$OUT_DIR/yosemite_${DEMO}_${RES}.gmon" ]; then
      if ! command -v gprof >/dev/null 2>&1; then
        echo "[profile-pass] WARN: gprof not installed on Ubuntu workstation"
        echo "[profile-pass]       sudo apt install binutils"
      else
        # We need the SAME binary that wrote gmon.out for symbol resolution.
        # build/quakespasm-g3 is the local copy.
        gprof -b -p -l "$REPO_ROOT/build/quakespasm-g3" \
          "$OUT_DIR/yosemite_${DEMO}_${RES}.gmon" \
          > "$OUT_DIR/yosemite_${DEMO}_${RES}.gprof" 2>&1 || {
          echo "[profile-pass] WARN: gprof failed (likely PPC vs x86 mismatch — gprof"
          echo "[profile-pass]       on Ubuntu can't always parse Mach-O PPC symbols)."
          echo "[profile-pass]       Falling back: gmon.out captured, parse on a PPC host."
        }
        if [ -s "$OUT_DIR/yosemite_${DEMO}_${RES}.gprof" ]; then
          echo "[profile-pass] yosemite gprof report → $OUT_DIR/yosemite_${DEMO}_${RES}.gprof"
          head -50 "$OUT_DIR/yosemite_${DEMO}_${RES}.gprof"
        fi
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# G4 trio: Apple sample(1) statistical profiler
# ---------------------------------------------------------------------------
for HOST in sawtooth quicksilver mini-g4; do
  case "$HOST" in
    sawtooth)    [ "$SKIP_SAWTOOTH" = "1" ] && continue ;;
    quicksilver) [ "$SKIP_QUICKSILVER" = "1" ] && continue ;;
    mini-g4)     [ "$SKIP_MINI_G4" = "1" ] && continue ;;
  esac

  echo ""
  echo "[profile-pass] === G4 $HOST sample($SAMPLE_SECS s) capture ==="

  # Start quakespasm with a long timedemo, then run `sample` against the PID
  # for SAMPLE_SECS seconds. Kill quakespasm cleanly after sample finishes.
  ssh "$HOST" "
    cd ~/Desktop/quake
    rm -f qconsole.log
    ./Quakespasm.app/Contents/MacOS/quakespasm -nolauncher -basedir . -nosound -condebug \
      -fullscreen -width $W -height $H \
      -noarchautoexec \
      +vid_wait 0 \
      +timedemo $DEMO > /dev/null 2>&1 &
    QPID=\$!
    # Give SDL+OpenGL ~3s to come up before sample attaches; otherwise
    # sample's first samples land in window-creation code which isn't
    # the perf-loop we want.
    sleep 3
    if kill -0 \$QPID 2>/dev/null; then
      sample \$QPID $SAMPLE_SECS -file /tmp/sample.out > /dev/null 2>&1 || true
    else
      echo '[profile-pass] $HOST quakespasm exited before sample could attach'
      ls -la /tmp/sample.out 2>/dev/null || true
    fi
    # Clean up Quake — TERM-grace-KILL like bench.sh.
    killall -TERM quakespasm 2>/dev/null || true
    sleep 2
    killall -KILL quakespasm 2>/dev/null || true
    wait \$QPID 2>/dev/null || true
    ls -la /tmp/sample.out qconsole.log 2>/dev/null | head -3
  "

  scp -q "$HOST:/tmp/sample.out" "$OUT_DIR/${HOST}_${DEMO}_${RES}.sample" || {
    echo "[profile-pass] FAIL: sample.out missing on $HOST"
    continue
  }
  scp -q "$HOST:Desktop/quake/qconsole.log" "$OUT_DIR/${HOST}_${DEMO}_${RES}.qconsole" || true

  # Sample's output format: a header, then for each thread a tree of
  # call-stacks with sample counts. The "Total number in stack" line
  # near the start tells us total samples.
  echo "[profile-pass] $HOST sample report → $OUT_DIR/${HOST}_${DEMO}_${RES}.sample"
  awk '/Sort by top of stack|^[[:space:]]*[0-9]+ [A-Za-z_]/ { print }' \
    "$OUT_DIR/${HOST}_${DEMO}_${RES}.sample" | head -40 || true
done

echo ""
echo "[profile-pass] all captures landed in $OUT_DIR/"
echo "[profile-pass] next: hand-curate SUMMARY.md cross-referencing top hot functions"
