#!/usr/bin/env bash
# Build a distributable .dmg containing Quakespasm.app + quakespasm.pak +
# a user-facing README — the easy way to hand the build to the old Macs.
#
# The .app is staged exactly like deploy.sh (fat 3-arch binary + SDL +
# codec dylibs + per-machine autoexec cfgs + icon). Linux has no hdiutil,
# so a Mac (the cross-build host by default) does the actual hdiutil
# create; we stage on Ubuntu, ship the folder over, build the .dmg there,
# and fetch it back.
#
# usage: scripts/make-dmg.sh [version-label]
#   version-label: e.g. v1.6 (default: short HEAD hash)
#
# env: DMG_HOST  Mac to run hdiutil on. DEFAULT: yosemite (the Panther G3).
#               This matters: a UDZO image built by Lion's hdiutil reports
#               "no mountable file systems" on Mac OS X 10.3.9 — the UDIF
#               container version is too new for Panther's DiskImageMounter
#               (the inner partition is plain Apple_HFS, so it's not a
#               filesystem problem — it's the image-format version). An
#               image built on the OLDEST target OS mounts everywhere from
#               10.3.9 → modern (old→new compat holds; new→old doesn't).
#               If you only ship to Tiger+ and want a faster build, override
#               with e.g. DMG_HOST=quicksilver (Tiger) or =mini-intel (Lion).
#
# pre:   build/quakespasm-fat present (build with scripts/build-fat.sh;
#        this script builds it for you if missing)
# post:  dist/QuakeSpasm-OldMac-<version>.dmg
#
# The same .dmg installs on every supported Mac — the fat binary's three
# slices (ppc750 / ppc7400 / x86_64) + the CFBundle per-machine autoexec
# layer mean one disk image serves G3 Panther through modern Intel.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERSION="${1:-$(git rev-parse --short HEAD)}"
DMG_HOST="${DMG_HOST:-yosemite}"   # Panther host → image mounts on every target (see header)
VOLNAME="QuakeSpasm OldMac $VERSION"
OUT="$REPO_ROOT/dist/QuakeSpasm-OldMac-$VERSION.dmg"

BIN="$REPO_ROOT/build/quakespasm-fat"
if [ ! -f "$BIN" ]; then
  echo "[make-dmg] build/quakespasm-fat missing — building it"
  scripts/build-fat.sh
fi
# Sanity: must be the 3-slice fat, not a stray single-arch binary. Note
# `file` prints the subtypes with underscores (ppc_750 / ppc_7400).
if ! file "$BIN" | grep -q 'ppc_750' || ! file "$BIN" | grep -q 'x86_64'; then
  echo "[make-dmg] $BIN is not the 3-arch fat binary — run scripts/build-fat.sh" >&2
  exit 1
fi

# ---- stage the disk-image contents (Quakespasm.app + pak + README) -------
STAGE=$(mktemp -d -t qs-dmg.XXXXXX)
trap "rm -rf '$STAGE'" EXIT
IMG="$STAGE/img"                       # becomes the .dmg root
APP="$IMG/Quakespasm.app"
RESOURCES="$APP/Contents/Resources"
mkdir -p "$APP/Contents/MacOS" "$RESOURCES"

echo "[make-dmg] stage Quakespasm.app (same layout as deploy.sh)"
cp    "$REPO_ROOT/scripts/bundle/Info.plist" "$APP/Contents/Info.plist"
cp    "$REPO_ROOT/MacOSX/QuakeSpasm.icns"    "$RESOURCES/"
cp -r "$REPO_ROOT/MacOSX/English.lproj"      "$RESOURCES/"
cp    "$REPO_ROOT/MacOSX/codecs/lib"/*.dylib "$APP/Contents/MacOS/"
cp -r "$REPO_ROOT/MacOSX/SDL.framework"      "$APP/Contents/MacOS/"
cp    "$BIN" "$APP/Contents/MacOS/quakespasm"
chmod +x "$APP/Contents/MacOS/quakespasm"
# Engine's own pak (menu/UI assets) ships in the gamedir root, beside id1/.
cp    "$REPO_ROOT/Quake/quakespasm.pak" "$IMG/"
# Per-arch baselines + per-machine overlays, picked at boot by host.c.
for cfg in ppc750 ppc7400 x86_64 yosemite sawtooth quicksilver mini-g4 mini-intel imac-2019; do
  cp "$REPO_ROOT/scripts/bundle/autoexec-$cfg.cfg" "$RESOURCES/"
done

# ---- user-facing README inside the image ---------------------------------
cat > "$IMG/README.txt" <<EOF
QuakeSpasm — Old-Mac fat build ($VERSION)
=========================================

A QuakeSpasm fork tuned to look as good as possible while staying playable
on retro Macs from 1999 to today. ONE universal binary (PowerPC G3 + PowerPC
G4/AltiVec + Intel x86_64); the right code slice and the right per-machine
visual/perf config are picked automatically at launch.

Supported: Mac OS X 10.3.9 Panther (G3) and up, through modern Intel macOS.
(PowerPC G3/G4 and 64-bit Intel only — pre-Lion 32-bit Intel Macs are not
supported.)

INSTALL
-------
1. Make a folder for the game, e.g.  ~/Desktop/quake/
2. Copy BOTH of these from this disk image into that folder:
       Quakespasm.app
       quakespasm.pak
3. Add your Quake data — put your own pak files in an "id1" subfolder:
       ~/Desktop/quake/id1/pak0.pak              (shareware)
       ~/Desktop/quake/id1/pak0.pak + pak1.pak   (registered)
   Registered Quake is on Steam and GOG.
4. Double-click Quakespasm.app.

The final layout:
   ~/Desktop/quake/Quakespasm.app
   ~/Desktop/quake/quakespasm.pak
   ~/Desktop/quake/id1/pak0.pak

MODERN macOS (Gatekeeper)
-------------------------
The bundle is unsigned, so recent macOS will quarantine it. Either
right-click Quakespasm.app and choose Open the first time, or run:
   xattr -dr com.apple.quarantine ~/Desktop/quake/Quakespasm.app
(Not needed on Panther / Tiger / Lion.)

PER-MACHINE CONFIG
------------------
The app detects the Mac it's on (sysctl hw.model) and applies a hand-tuned
visual + performance config — anisotropic filtering, trilinear, alias
drop-shadows, translucent liquids, smooth lightstyles, and more on the
machines that can afford them; leaner settings where they can't. Every knob
is a runtime cvar or launch -flag, so nothing is locked in.

Project: https://github.com/matthewdeaves/old-mac-quakespasm
License: GPL-2.0-or-later (see the project repo).
EOF

# ---- build the .dmg on a Mac (hdiutil is macOS-only) ---------------------
REMOTE="/tmp/qs-dmg-$VERSION"
# Panther (yosemite) ships rsync 2.5.x — needs --protocol=29, same as deploy.sh.
RSYNC_EXTRA=""
[ "$DMG_HOST" = "yosemite" ] && RSYNC_EXTRA="--protocol=29"
echo "[make-dmg] ship staged image to $DMG_HOST and run hdiutil"
ssh "$DMG_HOST" "rm -rf '$REMOTE' && mkdir -p '$REMOTE'"
rsync -a --partial $RSYNC_EXTRA -e 'ssh -o ServerAliveInterval=15' "$IMG/" "$DMG_HOST:$REMOTE/img/"
# UDZO = zlib-compressed read-only image; widest compatibility incl. Panther.
ssh "$DMG_HOST" "rm -f '$REMOTE/out.dmg' && \
  hdiutil create -volname '$VOLNAME' -srcfolder '$REMOTE/img' \
    -ov -format UDZO '$REMOTE/out.dmg' && \
  hdiutil verify '$REMOTE/out.dmg' >/dev/null"

mkdir -p "$REPO_ROOT/dist"
scp -q "$DMG_HOST:$REMOTE/out.dmg" "$OUT"
ssh "$DMG_HOST" "rm -rf '$REMOTE'" 2>/dev/null || true

echo "[make-dmg] OK — $OUT"
ls -lh "$OUT"
