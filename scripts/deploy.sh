#!/usr/bin/env bash
# Assemble a self-contained Quakespasm.app bundle and deploy it to the
# target machine. Idempotent — safe to re-run.
#
# usage: scripts/deploy.sh <yosemite|sawtooth|quicksilver|mini-g4|mini-intel|imac-2019|imac-g5>
#
# pre:   build/quakespasm-fat must exist (scripts/build-fat.sh)
#
# Ships ONE Mach-O (4 slices: ppc750 + ppc7400 + ppc970 + x86_64). The .app is
# self-contained: per-arch + per-machine autoexec configs live inside
# Quakespasm.app/Contents/Resources/, loaded by host.c via CFBundle
# (QS_ExecConfigFromBundle). Compile-time QS_ARCH_PPC970/__VEC__/__ppc__/__x86_64__
# picks the per-arch baseline; runtime sysctl hw.model picks the
# per-machine overlay. End-user install is just .app + their own
# id1/pak0.pak alongside.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TARGET="${1:?usage: $0 <yosemite|sawtooth|quicksilver|mini-g4|mini-intel|imac-2019|imac-g5>}"

# MacOSX/SDL.framework is a 3-arch fat (x86_64 + i386 + ppc) where the
# ppc slice is the Panther-compatible build. One framework serves all
# six targets — no per-host SDL swap. See "How the fat SDL was built"
# in MacOSX/CLAUDE.md if it ever needs regenerating from
# MacOSX/SDL-panther.dylib.
case "$TARGET" in
  yosemite)
    # PowerMac1,1 — G3 / Panther. Needs --protocol=29 because Panther
    # ships rsync 2.5.x, older than Ubuntu's.
    HOST="yosemite"
    RSYNC_EXTRA="--protocol=29"
    ;;
  sawtooth|quicksilver|mini-g4|mini-intel|imac-2019|imac-g5)
    # imac-g5: PowerMac8,2 iMac G5 on Leopard 10.5.8. Leopard ships
    # rsync 2.6.9 (protocol 29), same as the Tiger boxes — no
    # --protocol downgrade needed (only Panther's 2.5.x needs that).
    HOST="$TARGET"
    RSYNC_EXTRA=""
    ;;
  *)
    echo "unknown target: $TARGET" >&2
    exit 2
    ;;
esac

BIN="$REPO_ROOT/build/quakespasm-fat"
if [ ! -f "$BIN" ]; then
  echo "binary not found: $BIN" >&2
  echo "run: scripts/build-fat.sh" >&2
  exit 1
fi

STAGE=$(mktemp -d -t qs-deploy.XXXXXX)
trap "rm -rf '$STAGE'" EXIT

echo "[deploy] stage Quakespasm.app bundle"
RESOURCES="$STAGE/Quakespasm.app/Contents/Resources"
mkdir -p "$STAGE/Quakespasm.app/Contents/MacOS"
mkdir -p "$RESOURCES"

cp "$REPO_ROOT/scripts/bundle/Info.plist" "$STAGE/Quakespasm.app/Contents/Info.plist"
cp "$REPO_ROOT/MacOSX/QuakeSpasm.icns"    "$RESOURCES/"
cp -r "$REPO_ROOT/MacOSX/English.lproj"   "$RESOURCES/"
cp "$REPO_ROOT/MacOSX/codecs/lib"/*.dylib "$STAGE/Quakespasm.app/Contents/MacOS/"
cp -r "$REPO_ROOT/MacOSX/SDL.framework"   "$STAGE/Quakespasm.app/Contents/MacOS/"

cp "$BIN" "$STAGE/Quakespasm.app/Contents/MacOS/quakespasm"
chmod +x "$STAGE/Quakespasm.app/Contents/MacOS/quakespasm"
cp "$REPO_ROOT/Quake/quakespasm.pak" "$STAGE/"

# Per-arch baselines + per-machine overlays. host.c picks the right
# baseline at compile time and the right overlay at runtime via sysctl
# hw.model. All ship inside the .app so the bundle is self-contained.
for cfg in ppc750 ppc7400 ppc970 x86_64 yosemite sawtooth quicksilver mini-g4 mini-intel imac-2019 imac-g5 imac-g4; do
  cp "$REPO_ROOT/scripts/bundle/autoexec-$cfg.cfg" "$RESOURCES/"
done

echo "[deploy] ship to $HOST:~/Desktop/quake/"
# Migration: pre-v1.4 builds shipped autoexec cfgs to id1/. Remove any
# stragglers on the target so user-visible id1/ stays clean (engine
# now loads from Resources/ via CFBundle). Best effort — failure on a
# fresh target with no id1/ is fine.
ssh "$HOST" 'rm -f ~/Desktop/quake/id1/autoexec.cfg \
                   ~/Desktop/quake/id1/autoexec-ppc750.cfg \
                   ~/Desktop/quake/id1/autoexec-ppc7400.cfg \
                   ~/Desktop/quake/id1/autoexec-ppc970.cfg \
                   ~/Desktop/quake/id1/autoexec-x86_64.cfg \
                   ~/Desktop/quake/id1/autoexec-yosemite.cfg \
                   ~/Desktop/quake/id1/autoexec-sawtooth.cfg \
                   ~/Desktop/quake/id1/autoexec-quicksilver.cfg \
                   ~/Desktop/quake/id1/autoexec-mini-g4.cfg \
                   ~/Desktop/quake/id1/autoexec-mini-intel.cfg \
                   ~/Desktop/quake/id1/autoexec-imac-2019.cfg \
                   ~/Desktop/quake/id1/autoexec-imac-g5.cfg 2>/dev/null' || true

# --checksum: force file-content comparison instead of trusting size+mtime.
# Saw at least one stale-icon case on sawtooth where rsync's size+mtime
# heuristic skipped a real update (298 KB stale icns left in place
# despite the local 2.6 MB version having a different mtime). On a
# 12 MB bundle the checksum cost is negligible (seconds at most) and it
# is the only way to guarantee the deployed bytes match the local repo.
rsync -av --partial --checksum $RSYNC_EXTRA -e 'ssh -o ServerAliveInterval=15' \
  "$STAGE/" "$HOST:Desktop/quake/" | tail -8

# Post-deploy verification: md5 the binary and the icon on the target
# and compare to the local source. Catches silent rsync-skipped files
# (we saw this with --partial leaving a 298 KB stale icns on sawtooth).
LOCAL_BIN_MD5=$(md5sum "$BIN" | awk '{print $1}')
LOCAL_ICN_MD5=$(md5sum "$REPO_ROOT/MacOSX/QuakeSpasm.icns" | awk '{print $1}')
REMOTE_VERIFY=$(ssh "$HOST" '
  if command -v md5 >/dev/null 2>&1; then
    BIN_MD5=$(md5 -q ~/Desktop/quake/Quakespasm.app/Contents/MacOS/quakespasm 2>/dev/null)
    ICN_MD5=$(md5 -q ~/Desktop/quake/Quakespasm.app/Contents/Resources/QuakeSpasm.icns 2>/dev/null)
  else
    BIN_MD5=$(md5sum ~/Desktop/quake/Quakespasm.app/Contents/MacOS/quakespasm 2>/dev/null | awk "{print \$1}")
    ICN_MD5=$(md5sum ~/Desktop/quake/Quakespasm.app/Contents/Resources/QuakeSpasm.icns 2>/dev/null | awk "{print \$1}")
  fi
  echo "$BIN_MD5 $ICN_MD5"
' 2>/dev/null)
REMOTE_BIN_MD5=$(echo "$REMOTE_VERIFY" | awk '{print $1}')
REMOTE_ICN_MD5=$(echo "$REMOTE_VERIFY" | awk '{print $2}')
if [ "$LOCAL_BIN_MD5" != "$REMOTE_BIN_MD5" ]; then
  echo "[deploy] WARN: binary md5 mismatch on $HOST (local $LOCAL_BIN_MD5 vs remote $REMOTE_BIN_MD5)"
fi
if [ "$LOCAL_ICN_MD5" != "$REMOTE_ICN_MD5" ]; then
  echo "[deploy] WARN: icon md5 mismatch on $HOST (local $LOCAL_ICN_MD5 vs remote $REMOTE_ICN_MD5)"
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
