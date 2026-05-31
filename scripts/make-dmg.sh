#!/usr/bin/env bash
# Build a distributable .dmg containing Quakespasm.app + quakespasm.pak +
# a user-facing README — the easy way to hand the build to the old Macs.
#
# The .app is staged exactly like deploy.sh (fat 4-arch binary + SDL +
# codec dylibs + per-machine autoexec cfgs + icon). Linux has no hdiutil,
# so a Mac (the cross-build host by default) does the actual hdiutil
# create; we stage on Ubuntu, ship the folder over, build the .dmg there,
# and fetch it back.
#
# usage: scripts/make-dmg.sh [version-label]
#   version-label: e.g. v1.6 (default: short HEAD hash)
#
# env: DMG_HOST  Mac to run hdiutil on. DEFAULT: first REACHABLE Tiger box
#               (mini-g4, then quicksilver, then sawtooth).
#               WHY TIGER, NOT THE G3 OR LION (all empirically tested 2026-05-31,
#               and confirmed by the Quake II sister port's corrupt-DMG incident):
#                 * Lion's hdiutil writes a UDIF container Panther's 2003-vintage
#                   DiskImageMounter can't parse — "no mountable file systems" on
#                   10.3.9. NO hdiutil flag fixes it (UDZO, uncompressed UDRO, and
#                   an Apple-Partition-Map -layout SPUD image all fail to mount on
#                   Panther). So Lion is out for any image that must reach a G3.
#                 * A TIGER-built UDZO mounts on Panther AND everything newer
#                   (old→new compat holds; new→old doesn't). Tiger (10.4) is the
#                   oldest OS we need for the hdiutil step.
#                 * We deliberately do NOT use the 1999 Panther G3 (yosemite):
#                   it's the flakiest hardware in the fleet (non-ECC RAM /
#                   25-year-old disk). On 2026-05-31 a single byte flipped during
#                   the Q2 DMG's hdiutil read→zlib→write on that G3 and shipped a
#                   corrupt ppc7400 slice (a register-save `stw r31` became an
#                   illegal 64-bit opcode → EXC_PPC_PRIVINST → instant crash on
#                   every G4), passing `hdiutil verify` silently. The end-to-end
#                   content verification below now catches such a flip on ANY
#                   host, but there is no reason to build on the worst hardware
#                   when a healthy Tiger box does the job.
#               The BINARY is still built on Lion (mini-intel) by build-fat.sh;
#               DMG_HOST only runs the hdiutil packaging step on the staged tree.
#
# pre:   build/quakespasm-fat present (build with scripts/build-fat.sh;
#        this script builds it for you if missing)
# post:  dist/QuakeSpasm-OldMac-<version>.dmg
#
# The same .dmg installs on every supported Mac — the fat binary's four
# slices (ppc750 / ppc7400 / ppc970 / x86_64) + the CFBundle per-machine
# autoexec layer mean one disk image serves G3 Panther through modern Intel.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERSION="${1:-$(git rev-parse --short HEAD)}"
# Tiger host → image mounts on Panther→modern (see header). If DMG_HOST is not
# set explicitly, auto-pick the first REACHABLE Tiger box so a powered-off
# mini-g4 doesn't break the default — all three write Panther-mountable images.
if [ -z "${DMG_HOST:-}" ]; then
  for cand in mini-g4 quicksilver sawtooth; do
    if ssh -o ConnectTimeout=6 -o BatchMode=yes "$cand" true 2>/dev/null; then DMG_HOST="$cand"; break; fi
  done
  DMG_HOST="${DMG_HOST:-mini-g4}"
  echo "[make-dmg] DMG_HOST not set — using reachable Tiger host: $DMG_HOST"
fi
VOLNAME="QuakeSpasm OldMac $VERSION"
OUT="$REPO_ROOT/dist/QuakeSpasm-OldMac-$VERSION.dmg"

BIN="$REPO_ROOT/build/quakespasm-fat"
if [ ! -f "$BIN" ]; then
  echo "[make-dmg] build/quakespasm-fat missing — building it"
  scripts/build-fat.sh
fi
# Sanity: must be the multi-slice fat, not a stray single-arch binary.
# Note `file` prints the subtypes with underscores (ppc_750 / ppc_7400 /
# ppc_970). Checking the two endpoints (oldest PPC + Intel) is enough to
# distinguish the fat from any single-arch slice.
if ! file "$BIN" | grep -q 'ppc_750' || ! file "$BIN" | grep -q 'x86_64'; then
  echo "[make-dmg] $BIN is not the 4-arch fat binary — run scripts/build-fat.sh" >&2
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
for cfg in ppc750 ppc7400 ppc970 x86_64 yosemite sawtooth quicksilver mini-g4 mini-intel imac-2019 imac-g5 imac-g4; do
  cp "$REPO_ROOT/scripts/bundle/autoexec-$cfg.cfg" "$RESOURCES/"
done

# ---- user-facing README inside the image ---------------------------------
cat > "$IMG/README.txt" <<EOF
QuakeSpasm — Old-Mac fat build ($VERSION)
=========================================

A QuakeSpasm fork tuned to look as good as possible while staying playable
on retro Macs from 1999 to today. ONE universal binary (PowerPC G3 + PowerPC
G4/AltiVec + PowerPC G5/970 + Intel x86_64); the right code slice and the
right per-machine visual/perf config are picked automatically at launch.

Supported: Mac OS X 10.3.9 Panther (G3) and up, through modern Intel macOS.
(PowerPC G3/G4/G5 and 64-bit Intel only — pre-Lion 32-bit Intel Macs are not
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

# ---- build the .dmg on a Mac, with END-TO-END content verification -------
# CRITICAL (learned from the Q2 sister port — see MISTAKES.md 2026-05-31
# "DMG byte-flip"): `hdiutil verify` only checks the UDIF container's *internal*
# checksum — that the compressed blocks decompress to whatever was stored. It
# does NOT verify that what was stored matches our source. A single byte flipped
# anywhere in the rsync→hdiutil chain (e.g. a bad sector / RAM glitch on an old
# build host) passes `hdiutil verify` and ships a corrupt binary. That exact
# failure turned a register-save (stw r31) in Q2's ppc7400 slice into an illegal
# 64-bit opcode → EXC_PPC_PRIVINST → instant crash on every G4, while deploy.sh
# (which ships the fat binary directly, no DMG) was fine. So: after building,
# mount the finished image and md5 the actual binaries inside it against the
# source. Retry on mismatch; fail loud if it can't be made clean.
REMOTE="/tmp/qs-dmg-$VERSION"
# Panther (yosemite) ships rsync 2.5.x — needs --protocol=29, same as deploy.sh.
# (The default DMG_HOST is now Tiger, which ships a modern-enough rsync, so this
# only fires on a manual DMG_HOST=yosemite override.) NOTE: dropped --partial —
# it can reuse a stale chunk from a previous interrupted run, defeating the
# point of a clean re-ship on a verification-mismatch retry.
RSYNC_EXTRA=""
[ "$DMG_HOST" = "yosemite" ] && RSYNC_EXTRA="--protocol=29"

# Every corruptible code artifact we ship inside the bundle, asserted end-to-end:
# the 4-arch engine binary, the audio codec dylibs, and the SDL framework binary.
# The staged $IMG copies are plain local `cp` of the source tree, so the $IMG
# md5s ARE the true-source md5s. (Paths are space-free, so word-splitting them
# into the SRC_SUMS loop is safe; the IN-DMG list is hardcoded in the remote
# heredoc because `ssh host bash -s "$VAR"` word-splits a multi-path arg down to
# its first element — keep the two lists in sync.)
VERIFY_FILES="Quakespasm.app/Contents/MacOS/quakespasm \
Quakespasm.app/Contents/MacOS/libFLAC.dylib \
Quakespasm.app/Contents/MacOS/libmad.dylib \
Quakespasm.app/Contents/MacOS/libmikmod.dylib \
Quakespasm.app/Contents/MacOS/libmpg123.dylib \
Quakespasm.app/Contents/MacOS/libogg.dylib \
Quakespasm.app/Contents/MacOS/libopus.dylib \
Quakespasm.app/Contents/MacOS/libopusfile.dylib \
Quakespasm.app/Contents/MacOS/libvorbis.dylib \
Quakespasm.app/Contents/MacOS/libvorbisfile.dylib \
Quakespasm.app/Contents/MacOS/libxmp.dylib \
Quakespasm.app/Contents/MacOS/SDL.framework/Versions/A/SDL"
SRC_SUMS=$(cd "$IMG" && for f in $VERIFY_FILES; do \
             printf '%s  %s\n' "$(md5sum "$f" | cut -d' ' -f1)" "$f"; done)

mkdir -p "$REPO_ROOT/dist"

attempt=0; verified=no
while [ "$attempt" -lt 3 ]; do
  attempt=$((attempt + 1))
  echo "[make-dmg] attempt $attempt/3: ship staged image to $DMG_HOST and run hdiutil"
  ssh "$DMG_HOST" "rm -rf '$REMOTE' && mkdir -p '$REMOTE'"
  rsync -a $RSYNC_EXTRA -e 'ssh -o ServerAliveInterval=15' "$IMG/" "$DMG_HOST:$REMOTE/img/"
  # UDZO = zlib-compressed read-only image; widest compatibility incl. Panther.
  ssh "$DMG_HOST" "rm -f '$REMOTE/out.dmg' && \
    hdiutil create -volname '$VOLNAME' -srcfolder '$REMOTE/img' \
      -ov -format UDZO '$REMOTE/out.dmg' && \
    hdiutil verify '$REMOTE/out.dmg' >/dev/null"

  # md5 the binaries INSIDE the finished image (mount → hash → detach). Mount at
  # a private mountpoint (not /Volumes) to dodge BSD-grep parsing and any stale
  # same-name mount left by a previous run. Tolerant of detach races. md5 ...
  # | awk '{print $NF}' is portable across Panther/Tiger/Lion (md5 -q isn't).
  DMG_SUMS=$(ssh "$DMG_HOST" bash -s "$REMOTE" <<'REMOTE_EOF' || true
REM="$1"; MP="$REM/mnt"
mkdir -p "$MP"
hdiutil detach "$MP" >/dev/null 2>&1 || true
hdiutil attach -nobrowse -readonly -mountpoint "$MP" "$REM/out.dmg" >/dev/null 2>&1 || exit 7
for f in Quakespasm.app/Contents/MacOS/quakespasm \
         Quakespasm.app/Contents/MacOS/libFLAC.dylib \
         Quakespasm.app/Contents/MacOS/libmad.dylib \
         Quakespasm.app/Contents/MacOS/libmikmod.dylib \
         Quakespasm.app/Contents/MacOS/libmpg123.dylib \
         Quakespasm.app/Contents/MacOS/libogg.dylib \
         Quakespasm.app/Contents/MacOS/libopus.dylib \
         Quakespasm.app/Contents/MacOS/libopusfile.dylib \
         Quakespasm.app/Contents/MacOS/libvorbis.dylib \
         Quakespasm.app/Contents/MacOS/libvorbisfile.dylib \
         Quakespasm.app/Contents/MacOS/libxmp.dylib \
         Quakespasm.app/Contents/MacOS/SDL.framework/Versions/A/SDL; do
  printf '%s  %s\n' "$(md5 "$MP/$f" 2>/dev/null | awk '{print $NF}')" "$f"
done
hdiutil detach "$MP" >/dev/null 2>&1 || hdiutil detach -force "$MP" >/dev/null 2>&1 || true
REMOTE_EOF
)
  if [ "$DMG_SUMS" = "$SRC_SUMS" ]; then verified=yes; break; fi
  echo "[make-dmg] WARNING: DMG contents differ from source (attempt $attempt) — retrying" >&2
  echo "--- source ---"; echo "$SRC_SUMS"
  echo "--- in dmg ---"; echo "$DMG_SUMS"
done

[ "$verified" = yes ] || {
  echo "[make-dmg] FATAL: could not produce an uncorrupted DMG after $attempt attempts on $DMG_HOST." >&2
  echo "           The build host may have a failing disk/RAM. Try a different DMG_HOST." >&2
  exit 1
}
echo "[make-dmg] verified: engine binary + codec dylibs + SDL inside the DMG match source byte-for-byte"

# Fetch the container back and confirm scp didn't corrupt it in transit either.
scp -q "$DMG_HOST:$REMOTE/out.dmg" "$OUT"
RMT_DMG_MD5=$(ssh "$DMG_HOST" "md5 '$REMOTE/out.dmg' | awk '{print \$NF}'")
LCL_DMG_MD5=$(md5sum "$OUT" | cut -d' ' -f1)
[ "$RMT_DMG_MD5" = "$LCL_DMG_MD5" ] || {
  echo "[make-dmg] FATAL: scp corrupted $OUT ($RMT_DMG_MD5 != $LCL_DMG_MD5)" >&2
  exit 1
}
ssh "$DMG_HOST" "rm -rf '$REMOTE'" 2>/dev/null || true

echo "[make-dmg] OK — $OUT (container md5 $LCL_DMG_MD5, contents verified vs source)"
ls -lh "$OUT"
