#!/usr/bin/env bash
# Capture a series of in-game screenshots from a deployed Quakespasm fat
# bundle running on a remote host. Saves into a per-host folder on that
# machine's Desktop and (optionally) fetches copies back to the
# orchestrator for blog/post-mortem use.
#
# usage: scripts/screenshot.sh <g3|g4|g4mini|lion> [--width WxH] [--no-fetch]
#
# pre:   Deploy a fat bundle first via `scripts/deploy.sh fat <host>`.
#        Host must reach login (ssh works).
# post:  Per-host folder ~/Desktop/quakespasm-screens-<hostname>/ on the
#        target machine contains spasm0000.png, spasm0001.png, … plus a
#        manifest.txt naming each shot's vantage.
#        Local copies land in benchmarks/screenshots/<hostname>/ unless
#        --no-fetch is passed.
#
# Map: e1m1 (Slipgate Complex). Picked because it hits all four blog
# categories the user asked for in one map:
#   - water (the central pool, lava channels)
#   - shadows (alias drop-shadows — r_shadows 1 on g4/lion)
#   - dynamic lights (torches in the corridors)
#   - action (early grunts + dog spawning into the level)
#
# Each shot uses `setpos x y z pitch yaw roll` to fix camera at known
# vantages. setpos auto-enables noclip in singleplayer (host_cmd.c:693).
# Coords were sampled by manually walking e1m1 with `setpos` printing
# current values via the no-arg form (host_cmd.c:679-689). Roll is 0
# everywhere — pitch is the up/down look angle (negative = looking down),
# yaw is the heading (0 = east in Quake's coordinate system).
#
# Why many shots: user wants to pick best-looking ones for the blog post,
# so we cast a wide net. Each host gets the same vantage list so the
# resulting PNGs are directly comparable (R128 classic warp vs
# Radeon 9000 new shader vs GMA 950 trilinear — same pixels, different
# rendering stack).

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <g3|g4|g4mini|lion> [--width WIDTHxHEIGHT] [--no-fetch]" >&2
  exit 2
fi

TARGET="$1"; shift
WIDTH=1024
HEIGHT=768
DO_FETCH=1

while [ $# -gt 0 ]; do
  case "$1" in
    --width)  IFS='x' read -r WIDTH HEIGHT <<< "$2"; shift 2;;
    --no-fetch) DO_FETCH=0; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

case "$TARGET" in
  g3)     HOST="PowerMacG3" ;;
  g4)     HOST="g4"          ;;
  g4mini) HOST="g4mini"      ;;
  lion)   HOST="lion"        ;;
  *) echo "unknown target: $TARGET" >&2; exit 2 ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Demo playback schedule. We use Quake's stock demos (id1/pak0.pak ships
# demo1.dem, demo2.dem, demo3.dem) instead of teleporting via setpos to
# hardcoded coordinates. Earlier setpos approach put us outside the BSP
# in some cells (grey skybox / void clipping artifacts). Demos play back
# the recorded camera path through real gameplay — no out-of-map shots,
# real action (combat, grunts, dogs, lava jumps), and the same camera
# motion across all 4 hosts so visual side-by-side is a fair comparison.
#
# Demos:
#   demo1 = Slipgate Complex (e1m1)   gameplay opening, grunts + dogs
#   demo2 = Necropolis        (e1m3)   water/lava, mid-episode pacing
#   demo3 = Ziggurat Vertigo  (e1m8 secret) low-grav sky-map, vertical motion
#
# 4 shots per demo × 3 demos = 12 shots total per host. Spread evenly
# in time across each demo's runtime by inserting N `wait` commands
# between captures (each `wait` pauses the cmd buffer for one render
# frame; demo playback continues in the background).
DEMOS="demo1 demo2 demo3"
SHOTS_PER_DEMO=30           # user wants a big bank to pick from
WAITS_BETWEEN_SHOTS=30      # ~0.5s on G4/Lion (60 fps), ~1.3s on G3 (24 fps)
WAITS_INITIAL=60            # let map load + first frames render before shot 1
WAITS_AFTER_SHOT=8          # tight — TGA write is fast (no zlib)

REMOTE_DESKTOP_DIR="\$HOME/Desktop/quakespasm-screens-\$(hostname -s)"
REMOTE_QUAKE="\$HOME/Desktop/quake"
LOCAL_FETCH_DIR="$REPO_ROOT/benchmarks/screenshots/$TARGET"

# Build the +cmd1 +cmd2 ... cmdline. wait-pumps a cmd-buffer pause for
# one frame; SETTLE_WAITS lets the engine render N frames at the new
# vantage before the screenshot fires. SHOT_WAITS lets the file write
# complete before we move to the next vantage. Generous on G3 (slower
# frame rate → fewer wall-time ms per wait) but harmless on faster hosts.
SETTLE_WAITS=30     # ~1.2s on G3, ~0.15s on Lion — frames-of-render budget
SHOT_WAITS=30       # let TGA writer flush — TGA is fast (no zlib)

# Quake's cmdline +cmd parser truncates at CMDLINE_LENGTH (256 chars,
# common.c:58). 10 vantages with N waits each balloons past 6 KB of
# cmdline text — way over the cap, which is why an earlier version of
# this script silently dropped every command past the first dozen waits.
# Workaround: write our command sequence into a cfg file in id1/ and
# launch the engine with just `+exec screenshot.cfg`. cfg files are
# loaded from disk via COM_LoadHunkFile (cmd.c:273) which has no length
# cap. The cfg goes through the same Cbuf_Execute pump as cmdline cmds,
# so semantics (\n / ; line breaks, // comments) are identical.

build_cfg() {
  echo "// Auto-generated by scripts/screenshot.sh -- do not edit by hand."
  echo "// 4 shots per demo across $(echo $DEMOS | wc -w) demos. TGA dump."
  echo ""

  for demo in $DEMOS; do
    echo ""
    echo "// === $demo ==="
    echo "playdemo $demo"
    # Initial settle: let map load + first frames render before shot 1.
    for _ in $(seq 1 $WAITS_INITIAL); do echo "wait"; done
    echo "screenshot tga"
    for _ in $(seq 1 $WAITS_AFTER_SHOT); do echo "wait"; done

    # Shots 2..N evenly spread through the demo runtime.
    i=2
    while [ $i -le $SHOTS_PER_DEMO ]; do
      for _ in $(seq 1 $WAITS_BETWEEN_SHOTS); do echo "wait"; done
      echo "screenshot tga"
      for _ in $(seq 1 $WAITS_AFTER_SHOT); do echo "wait"; done
      i=$((i+1))
    done

    # Stop the current demo before the next playdemo starts.
    echo "disconnect"
    for _ in $(seq 1 30); do echo "wait"; done
  done

  echo ""
  echo "quit"
}

CFG_TEXT="$(build_cfg)"
TOTAL_SHOTS=$(($(echo $DEMOS | wc -w) * SHOTS_PER_DEMO))

echo "[screenshot] target=$HOST  res=${WIDTH}x${HEIGHT}  shots=$TOTAL_SHOTS  demos=$DEMOS"

# Build the manifest content.
manifest() {
  echo "# Quakespasm fat-binary screenshot run"
  echo "# host:        $TARGET -> $HOST"
  echo "# captured:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# resolution:  ${WIDTH}x${HEIGHT}"
  echo "# demos:       $DEMOS  ($SHOTS_PER_DEMO shots each)"
  echo "#"
  echo "# Each row: spasmNNNN.tga  demo  shot-index"
  i=0
  for demo in $DEMOS; do
    s=1
    while [ $s -le $SHOTS_PER_DEMO ]; do
      printf "spasm%04d.tga  %-8s  shot-%d-of-%d\n" "$i" "$demo" "$s" "$SHOTS_PER_DEMO"
      i=$((i+1))
      s=$((s+1))
    done
  done
}

MANIFEST_TEXT="$(manifest)"

# Run on the remote host:
#   1. wipe any previous spasm*.png in id1/ so we start clean
#   2. launch the fat bundle with our cmd sequence
#   3. wait for it to exit (or kill after timeout)
#   4. mkdir Desktop folder, move PNGs there, write manifest
ssh "$HOST" bash <<EOF
set -e
cd "\$HOME/Desktop/quake"

# Pre-clean any prior screenshot output in id1/ so this run's PNGs
# are unambiguous (engine names them spasm0000.<ext> upward, finding
# the first unused index — leftover files would shift the numbering
# and break manifest.txt's vantage→file mapping).
rm -f id1/spasm*.png id1/spasm*.tga id1/spasm*.jpg

# Drop the auto-generated screenshot.cfg into id1/. exec screenshot.cfg
# loads it via COM_LoadHunkFile (cmd.c:273-284) and Cbuf_InsertText's
# its contents — same parsing path as autoexec.cfg, no length cap.
cat > id1/screenshot.cfg <<'CFG_END'
$CFG_TEXT
CFG_END

# Make sure the destination Desktop folder exists fresh. Move (not delete)
# any prior session's shots into a timestamped sibling so we never lose
# a previous capture by accident.
DEST="$REMOTE_DESKTOP_DIR"
if [ -d "\$DEST" ]; then
  STAMP=\$(date -u +%Y%m%dT%H%M%SZ)
  mv "\$DEST" "\$DEST.\$STAMP"
fi
mkdir -p "\$DEST"

# Launch: a single +exec is well within the 256-char cmdline cap. The
# cfg file does the heavy lifting (map, settles, setpos, screenshot,
# quit). Output to /tmp so we can debug if it dies.
LOGFILE="/tmp/screenshot-${TARGET}.log"
rm -f "\$LOGFILE"
./Quakespasm.app/Contents/MacOS/quakespasm \\
  -nolauncher -basedir "\$HOME/Desktop/quake" \\
  -fullscreen -width $WIDTH -height $HEIGHT \\
  -noarchautoexec \\
  +exec screenshot.cfg \\
  > "\$LOGFILE" 2>&1 &
PID=\$!

# Wait for engine exit, but cap wall time. Tiger's /usr/bin/seq doesn't
# exist (it's a GNU coreutils thing), so we use a counter loop — works
# in any sh-compatible shell. Budget: 3 demos × (init waits + N shots ×
# inter-shot waits) frames at host fps. G3 worst case at ~24 fps:
# (60 + 30*(30+8)) = 1200 waits/demo × 3 = ~150s wall. Plus 3 map loads
# ≈ 180s. 600s ceiling gives plenty of headroom for the bigger shot
# bank the user asked for (30 per demo × 3 demos = 90 shots per host),
# without wedging forever if something genuinely went wrong.
TIMEOUT=600
ELAPSED=0
while [ \$ELAPSED -lt \$TIMEOUT ]; do
  if ! kill -0 \$PID 2>/dev/null; then break; fi
  sleep 1
  ELAPSED=\$((ELAPSED + 1))
done

if kill -0 \$PID 2>/dev/null; then
  echo "[screenshot-remote] engine still running after \$TIMEOUT s, sending SIGTERM"
  kill -TERM \$PID 2>/dev/null || true
  sleep 2
  kill -KILL \$PID 2>/dev/null || true
fi

# Move the screenshots into the Desktop folder. id1/ is the gamedir so
# they land directly there (gl_screen.c:797). Disable -e here so the
# loop survives when a glob has no match (sh expands the literal pattern,
# [ -f ] returns false, we move on to the next).
set +e
for f in id1/spasm*.tga id1/spasm*.png id1/spasm*.jpg; do
  if [ -f "\$f" ]; then mv "\$f" "\$DEST/"; fi
done
set -e

# Write manifest.txt with vantage labels.
cat > "\$DEST/manifest.txt" <<MANIFEST
$MANIFEST_TEXT
MANIFEST

# Echo what we produced.
ls -1 "\$DEST" | head -30
SHOT_COUNT=\$(ls -1 "\$DEST"/spasm*.tga "\$DEST"/spasm*.png 2>/dev/null | wc -l | tr -d ' ')
echo "[screenshot-remote] wrote \$SHOT_COUNT shots into \$DEST"
EOF

if [ "$DO_FETCH" -eq 1 ]; then
  mkdir -p "$LOCAL_FETCH_DIR"
  echo "[screenshot] fetch copies → $LOCAL_FETCH_DIR/"
  rsync -av --partial -e ssh \
    "$HOST:Desktop/quakespasm-screens-$(ssh "$HOST" 'hostname -s')/" \
    "$LOCAL_FETCH_DIR/" 2>/dev/null | tail -8 || true
fi

echo "[screenshot] done — host folder: ~/Desktop/quakespasm-screens-<hostname>/"
