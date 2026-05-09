#!/usr/bin/env bash
# Assemble a Quakespasm.app bundle and deploy it to the target machine.
# Idempotent — safe to re-run.
#
# usage: scripts/deploy.sh <yosemite|sawtooth|quicksilver|mini-g4|mini-intel>          # per-target
#        scripts/deploy.sh fat <yosemite|sawtooth|quicksilver|mini-g4|mini-intel>      # fat binary
#
# Machine identity → binary mapping (machine names use Apple codenames /
# form-factor; binary names use chip family):
#   yosemite    → quakespasm-g3      (PPC 750, 10.3.9 SDK)
#   sawtooth    → quakespasm-g4      (PPC 7400 baseline, 10.4u SDK)
#   quicksilver → quakespasm-g4      (PPC 7450, 10.4u SDK; same binary)
#   mini-g4     → quakespasm-g4      (PPC 7447A, 10.4u SDK; same binary)
#   mini-intel  → quakespasm-lion    (x86_64, native Lion toolchain)
#
# pre:   per-target form: build/quakespasm-<chip> must exist
#        fat form:        build/quakespasm-fat must exist (scripts/build-fat.sh)
#
# The fat form ships ONE Mach-O (3 slices: ppc750 + ppc7400 + x86_64) plus
# all three per-arch autoexec files in id1/. The engine hook in host.c
# selects the per-arch autoexec at boot via compile-time __VEC__ /
# __ppc__ / __x86_64__ macros, so the fat slice running on each host
# auto-picks its tuning.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Mode: "per-target" (legacy) or "fat" (universal). First arg switches.
MODE="per-target"
if [ "${1:-}" = "fat" ]; then
  MODE="fat"
  shift
fi
TARGET="${1:?usage: $0 [fat] <yosemite|sawtooth|quicksilver|mini-g4|mini-intel|imac-2019>}"

# MacOSX/SDL.framework is a 3-arch fat (x86_64 + i386 + ppc) where the
# ppc slice is the Panther-compatible build. One framework serves all
# five targets — no per-host SDL swap. See "How the fat SDL was built"
# in CLAUDE.md if it ever needs regenerating from MacOSX/SDL-panther.dylib.
case "$TARGET" in
  yosemite)
    # PowerMac1,1 — only G3 / Panther target. Needs --protocol=29 because
    # Panther ships rsync 2.5.x, older than Ubuntu's.
    HOST="yosemite"
    RSYNC_EXTRA="--protocol=29"
    BIN_TARGET="g3"
    ;;
  sawtooth)
    # PowerMac3,1 — G4 AGP "Sawtooth" tower, 500 MHz 7400 + GeForce2 MX.
    # Only fixed-function G4 in the matrix. Reuses the g4 binary (-mcpu=7400
    # is the native ISA — actually a closer match than Quicksilver's 7450).
    HOST="sawtooth"
    RSYNC_EXTRA=""
    BIN_TARGET="g4"
    ;;
  quicksilver)
    # PowerMac3,5 — Quicksilver G4 tower, 733 MHz 7450 + Radeon 9000 Pro.
    HOST="quicksilver"
    RSYNC_EXTRA=""
    BIN_TARGET="g4"
    ;;
  mini-g4)
    # PowerMac10,1 — Mac mini G4 first-gen, 1.25 GHz 7447A + Radeon 9200 32MB.
    # Different GPU class (Radeon 9200 / 32 MB) from the Quicksilver
    # — separate data point for CPU-bound vs fillrate-bound diagnosis.
    HOST="mini-g4"
    RSYNC_EXTRA=""
    BIN_TARGET="g4"
    ;;
  mini-intel)
    # Macmini2,1 — Mac mini Intel C2D 2.33 GHz + GMA 950, Lion 10.7.5.
    # Dual-role: this is also the cross-build host for all PPC binaries.
    HOST="mini-intel"
    RSYNC_EXTRA=""
    BIN_TARGET="lion"
    ;;
  imac-2019)
    # iMac19,1 — iMac 27" 2019, Core i5-9600K @ 3.70 GHz + Radeon Pro
    # 580X 8GB, macOS Sequoia 15.7.5. Same x86_64 arch as mini-intel,
    # so reuses build/quakespasm-lion. Vastly more capable GPU/CPU
    # than mini-intel — expect chart-topping fps and full visual stack.
    HOST="imac-2019"
    RSYNC_EXTRA=""
    BIN_TARGET="lion"
    ;;
  *)
    echo "unknown target: $TARGET" >&2
    exit 2
    ;;
esac

# Fat-mode: ship build/quakespasm-fat regardless of host.
if [ "$MODE" = "fat" ]; then
  BIN_TARGET="fat"
fi

BIN="$REPO_ROOT/build/quakespasm-${BIN_TARGET:-$TARGET}"
if [ ! -f "$BIN" ]; then
  echo "binary not found: $BIN" >&2
  if [ "$MODE" = "fat" ]; then
    echo "run: scripts/build-fat.sh" >&2
  else
    echo "run: scripts/build.sh ${BIN_TARGET:-$TARGET}" >&2
  fi
  exit 1
fi

STAGE=$(mktemp -d -t qs-deploy.XXXXXX)
trap "rm -rf '$STAGE'" EXIT

echo "[deploy] stage Quakespasm.app bundle"
mkdir -p "$STAGE/Quakespasm.app/Contents/MacOS"
mkdir -p "$STAGE/Quakespasm.app/Contents/Resources"

cp "$REPO_ROOT/scripts/bundle/Info.plist" "$STAGE/Quakespasm.app/Contents/Info.plist"
cp "$REPO_ROOT/MacOSX/QuakeSpasm.icns"    "$STAGE/Quakespasm.app/Contents/Resources/"
cp -r "$REPO_ROOT/MacOSX/English.lproj"   "$STAGE/Quakespasm.app/Contents/Resources/"
cp "$REPO_ROOT/MacOSX/codecs/lib"/*.dylib "$STAGE/Quakespasm.app/Contents/MacOS/"
cp -r "$REPO_ROOT/MacOSX/SDL.framework"   "$STAGE/Quakespasm.app/Contents/MacOS/"

cp "$BIN" "$STAGE/Quakespasm.app/Contents/MacOS/quakespasm"
chmod +x "$STAGE/Quakespasm.app/Contents/MacOS/quakespasm"
cp "$REPO_ROOT/Quake/quakespasm.pak" "$STAGE/"

# Autoexec layout depends on mode.
#
# per-target mode (legacy, single-arch binary):
#   id1/autoexec.cfg = scripts/bundle/autoexec-<target>.cfg verbatim.
#   quake.rc's `exec autoexec.cfg` picks it up directly.
#
# fat mode (universal binary):
#   id1/autoexec-ppc750.cfg, autoexec-ppc7400.cfg, autoexec-x86_64.cfg
#   are all shipped. The engine hook in host.c picks the right one at
#   boot via compile-time __VEC__ / __ppc__ / __x86_64__ macros. We do
#   NOT ship id1/autoexec.cfg in fat mode — keeping it out avoids a
#   confusing "which file wins" question for users who edit them later.
mkdir -p "$STAGE/id1"
if [ "$MODE" = "fat" ]; then
  cp "$REPO_ROOT/scripts/bundle/autoexec-ppc750.cfg"  "$STAGE/id1/"
  cp "$REPO_ROOT/scripts/bundle/autoexec-ppc7400.cfg" "$STAGE/id1/"
  cp "$REPO_ROOT/scripts/bundle/autoexec-x86_64.cfg"  "$STAGE/id1/"
else
  AUTOEXEC="$REPO_ROOT/scripts/bundle/autoexec-$TARGET.cfg"
  if [ -f "$AUTOEXEC" ]; then
    cp "$AUTOEXEC" "$STAGE/id1/autoexec.cfg"
  fi
fi

echo "[deploy] ship to $HOST:~/Desktop/quake/"
rsync -av --partial $RSYNC_EXTRA -e 'ssh -o ServerAliveInterval=15' \
  "$STAGE/" "$HOST:Desktop/quake/" | tail -8

# In fat mode, also delete any prior id1/autoexec.cfg from a previous
# per-target deploy. The per-arch hook in host.c runs LAST so it would
# still override, but a stale autoexec.cfg can confuse validation by
# setting cvars that match the per-arch defaults coincidentally.
if [ "$MODE" = "fat" ]; then
  ssh "$HOST" 'rm -f ~/Desktop/quake/id1/autoexec.cfg' || true
fi

ssh "$HOST" 'chmod +x ~/Desktop/quake/Quakespasm.app/Contents/MacOS/quakespasm 2>/dev/null

# Round v4 §14.7: scrub any custom-icon overlay left from a previous
# Get-Info-paste icon edit. The canonical icon now lives at
# Contents/Resources/QuakeSpasm.icns (sourced from MacOSX/QuakeSpasm.icns
# in the repo). Without this scrub Finder would keep showing the old
# pasted overlay because kHasCustomIcon makes the Icon\r resource fork
# win over CFBundleIconFile. find -name "Icon?" matches the literal
# Icon-followed-by-CR filename without the inline-CR-quoting hell.
APP=~/Desktop/quake/Quakespasm.app
find "$APP" -maxdepth 1 -name "Icon?" -exec rm -f {} \; 2>/dev/null
# SetFile is in /Developer/Tools on Tiger and at /usr/bin on Lion. -a c
# clears the kHasCustomIcon flag (lowercase = clear, capital = set).
if command -v SetFile >/dev/null 2>&1; then
  SetFile -a c "$APP" 2>/dev/null || true
elif [ -x /Developer/Tools/SetFile ]; then
  /Developer/Tools/SetFile -a c "$APP" 2>/dev/null || true
fi

echo "[deploy] OK on $(hostname -s)"'
