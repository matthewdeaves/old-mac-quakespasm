#!/usr/bin/env bash
# Assemble a Quakespasm.app bundle and deploy it to the target machine.
# Idempotent — safe to re-run.
#
# usage: scripts/deploy.sh <g3|g4|g4mini|lion>          # per-target single-arch
#        scripts/deploy.sh fat <g3|g4|g4mini|lion>      # universal fat binary
#
# pre:   per-target form: build/quakespasm-<target> must exist
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
TARGET="${1:?usage: $0 [fat] <g3|g4|g4mini|lion>}"

case "$TARGET" in
  g3)
    HOST="PowerMacG3"
    RSYNC_EXTRA="--protocol=29"  # Panther's rsync 2.5.x is older than Ubuntu's
    SDL_BIN_OVERRIDE="$REPO_ROOT/MacOSX/SDL-panther.dylib"  # 10.3-built PPC SDL
    ;;
  g4)
    HOST="g4"
    RSYNC_EXTRA=""
    SDL_BIN_OVERRIDE=""  # Tiger uses the bundled SDL.framework's SDL binary as-is
    ;;
  g4mini)
    # Mac mini G4 — second G4-class bench target, added 2026-05-08.
    # Same arch as g4 (Quicksilver) so reuses build/quakespasm-g4. Tiger
    # 10.4 like the Quicksilver, so the bundled SDL.framework Just Works.
    # Different GPU class (G4 mini ships ATI Radeon 9200 / 32 MB or
    # Intel GMA 950 on later models) — so it's a separate data point for
    # CPU-bound vs fillrate-bound diagnosis.
    HOST="g4mini"
    RSYNC_EXTRA=""
    SDL_BIN_OVERRIDE=""
    BIN_TARGET="g4"  # reuse the g4 binary
    ;;
  lion)
    HOST="lion"
    RSYNC_EXTRA=""
    SDL_BIN_OVERRIDE=""  # Lion uses the bundled SDL.framework's SDL binary
                         # (fat: x86_64 + i386 + ppc) as-is
    ;;
  *)
    echo "unknown target: $TARGET" >&2
    exit 2
    ;;
esac

# Fat-mode override: ship build/quakespasm-fat regardless of host. The
# SDL_BIN_OVERRIDE rule still applies — G3 still needs the Panther-built
# SDL slice (the bundled fat SDL's PPC slice was built against 10.6 SDK
# and crashes on Panther). So fat-on-G3 still does the SDL swap, while
# fat-on-G4/G4mini/Lion uses the bundled framework as-is. This is asymmetric
# but unavoidable until SDL.framework gets a Panther-compatible PPC slice
# baked in (Round v4 §14.5 task #15).
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

# G3 needs the 10.3-built SDL binary swapped in (system 10.6-SDK build crashes)
if [ -n "$SDL_BIN_OVERRIDE" ]; then
  if [ ! -f "$SDL_BIN_OVERRIDE" ]; then
    echo "missing $SDL_BIN_OVERRIDE — needed for $TARGET deploy" >&2
    exit 1
  fi
  cp "$SDL_BIN_OVERRIDE" "$STAGE/Quakespasm.app/Contents/MacOS/SDL.framework/Versions/A/SDL"
fi

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
echo "[deploy] OK on $(hostname -s)"'
