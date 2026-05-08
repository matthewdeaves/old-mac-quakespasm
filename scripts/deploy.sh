#!/usr/bin/env bash
# Assemble a Quakespasm.app bundle and deploy it to the target machine.
# Idempotent — safe to re-run.
#
# usage: scripts/deploy.sh <g3|g4|lion>
# pre:   build/quakespasm-<target> must exist (run scripts/build.sh first)

set -euo pipefail

TARGET="${1:?usage: $0 <g3|g4|lion>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

BIN="$REPO_ROOT/build/quakespasm-$TARGET"
if [ ! -f "$BIN" ]; then
  echo "binary not found: $BIN" >&2
  echo "run: scripts/build.sh $TARGET" >&2
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

# Per-target autoexec.cfg with our PPC defaults (Phase 0 cvar tuning).
# Goes in id1/ which is searched by quake.rc's `exec autoexec.cfg`.
# Ships separately from the .app bundle (rsync trailing-slash semantics).
AUTOEXEC="$REPO_ROOT/scripts/bundle/autoexec-$TARGET.cfg"
if [ -f "$AUTOEXEC" ]; then
  mkdir -p "$STAGE/id1"
  cp "$AUTOEXEC" "$STAGE/id1/autoexec.cfg"
fi

echo "[deploy] ship to $HOST:~/Desktop/quake/"
rsync -av --partial $RSYNC_EXTRA -e 'ssh -o ServerAliveInterval=15' \
  "$STAGE/" "$HOST:Desktop/quake/" | tail -8

ssh "$HOST" 'chmod +x ~/Desktop/quake/Quakespasm.app/Contents/MacOS/quakespasm 2>/dev/null
echo "[deploy] OK on $(hostname -s)"'
