#!/usr/bin/env bash
# Build a distributable .dmg containing Quakespasm.app + quakespasm.pak +
# a user-facing README - the easy way to hand the build to the old Macs.
#
# The .app is staged exactly like deploy.sh (fat 6-arch binary + SDL +
# codec dylibs + per-machine autoexec cfgs + icon). Linux has no hdiutil,
# so a Mac (the cross-build host by default) does the actual hdiutil
# create; we stage locally, ship the folder over, build the .dmg there,
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
#                   DiskImageMounter can't parse - "no mountable file systems" on
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
# The same .dmg installs on every supported Mac: the fat binary's six
# slices (ppc750 / ppc7400 / ppc970 / i386 / x86_64 / arm64) + the CFBundle per-machine
# autoexec layer mean one disk image serves G3 Panther through Apple Silicon.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERSION="${1:-$(git rev-parse --short HEAD)}"
# Tiger host → image mounts on Panther→modern (see header). If DMG_HOST is not
# set explicitly, auto-pick the first REACHABLE Tiger box so a powered-off
# mini-g4 doesn't break the default - all three write Panther-mountable images.
if [ -z "${DMG_HOST:-}" ]; then
  for cand in mini-g4 quicksilver sawtooth; do
    if ssh -o ConnectTimeout=6 -o BatchMode=yes "$cand" true 2>/dev/null; then DMG_HOST="$cand"; break; fi
  done
  DMG_HOST="${DMG_HOST:-mini-g4}"
  echo "[make-dmg] DMG_HOST not set - using reachable Tiger host: $DMG_HOST"
fi

# Claim the Tiger box for the whole run. This script builds and mounts a disk
# image on it and reads files back off it, so sharing the machine corrupts the
# artifact we are about to ship. Same re-exec as bench.sh; see
# scripts/pick-bench-host.sh.
#
# Note what is NOT being fixed here: the candidate loop above picks the first
# REACHABLE box, and reachable is not free. If that box turns out to be held,
# the claim below fails and this script stops. It does not silently move to the
# next candidate, because "never work around a busy host by picking a different
# one" is the rule, and a release image built on a different machine than the
# one reported is exactly the kind of thing nobody notices. Set DMG_HOST
# explicitly to choose another.
#
# The inner scripts/build-fat.sh claims a LION mini, a different host from this
# Tiger one, so the two locks do not interact. The RETRO_BENCH_LOCK guard is
# still checked, because acquiring is not reentrant: pick-bench-host.sh:246 is a
# bare mkdir that fails even for the current owner, and cmd_run at :306 releases
# unconditionally, so a nested claim would free the box mid-run.
_PICK="$REPO_ROOT/scripts/pick-bench-host.sh"
if [ "${RETRO_BENCH_LOCK:-}" != "$DMG_HOST" ] && [ "${BENCH_NO_LOCK:-0}" != 1 ] && [ -x "$_PICK" ]; then
	export RETRO_BENCH_LOCK="$DMG_HOST" DMG_HOST
	exec "$_PICK" --run "$DMG_HOST" "make-dmg" -- "$0" "$@"
fi
VOLNAME="QuakeSpasm OldMac $VERSION"
OUT="$REPO_ROOT/dist/QuakeSpasm-OldMac-$VERSION.dmg"

BIN="$REPO_ROOT/build/quakespasm-fat"
if [ ! -f "$BIN" ]; then
  echo "[make-dmg] build/quakespasm-fat missing - building it"
  scripts/build-fat.sh
fi
# Sanity: must be the multi-slice fat, not a stray single-arch binary.
# Use lipo (reads the Mach header directly) rather than file(1): file's ppc
# subtype names vary by host/toolchain - on an Apple-silicon workstation it
# renders the ppc750 slice as "ppc_650", so the old `file | grep ppc_750`
# check spuriously failed on a perfectly good 6-arch fat. lipo -archs is
# authoritative and stable.
ARCHS=$(lipo -archs "$BIN" 2>/dev/null || echo)
# arm64 is deliberately NOT in this list. It is the one slice a Lion mini
# cannot build, so it is optional at fuse time and its absence is a Rosetta 2
# downgrade rather than a broken release. Say which way it went, though, so a
# release that quietly lost it is not mistaken for one that never had it.
for a in ppc750 ppc7400 ppc970 i386 x86_64; do
  case " $ARCHS " in
    *" $a "*) ;;
    *) echo "[make-dmg] $BIN is missing the $a slice (got: ${ARCHS:-none}), run scripts/build-fat.sh" >&2; exit 1;;
  esac
done
case " $ARCHS " in
  *" arm64 "*) echo "[make-dmg] arm64 slice present, native on Apple Silicon" ;;
  *) echo "[make-dmg] NOTE: no arm64 slice; Apple Silicon will use Rosetta 2" ;;
esac

# ---- stage the disk-image contents (Quakespasm.app + pak + README) -------
# Everything a player needs lives inside one "Quakespasm" folder at the DMG
# root (matches alephone's "Aleph One" folder; user, 2026-09-02: "make it
# like how the others work" -- no copy-to-~/Applications, the fix script
# just operates on wherever the player drags this one folder). A single
# folder-drag always brings the .app, the pak, id1/ and the fix script
# along together; loose DMG-root siblings only travel if dragged separately.
STAGE=$(mktemp -d -t qs-dmg.XXXXXX)
trap "rm -rf '$STAGE'" EXIT
IMG="$STAGE/img"                       # becomes the .dmg root
GAMEDIR="$IMG/Quakespasm"              # the one folder a player drags out
APP="$GAMEDIR/Quakespasm.app"
RESOURCES="$APP/Contents/Resources"
mkdir -p "$APP/Contents/MacOS" "$RESOURCES" "$GAMEDIR/id1"

echo "[make-dmg] stage Quakespasm.app (same layout as deploy.sh)"
cp    "$REPO_ROOT/scripts/bundle/Info.plist" "$APP/Contents/Info.plist"

# Stamp the PORT release version into the bundle so a human can tell which build
# is installed from Finder's Get Info, not just from the engine console. The
# static plist carries upstream's engine version (0.97.0), which never changes
# between our releases and so identifies nothing.
#
# Defaults to $VERSION, the label this image is NAMED after, not to `git
# describe`. Those two disagree the moment a release is cut from anything but an
# exact clean tag, and then the DMG says one thing and the .app on the machine
# says another, so a bench test proves nothing about WHICH build just ran. That
# is not hypothetical: v1.15-rc1 shipped a bundle stamped
# "v1.14-14-g24cab54e-dirty" and it was only caught by reading the plist back off
# five machines. An explicit QS_PORT_VERSION in the environment still wins.
QS_PORT_VERSION="${QS_PORT_VERSION:-$VERSION}"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString 0.97.0-oldmac-$QS_PORT_VERSION" \
  -c "Add :CFBundleVersion string $QS_PORT_VERSION" \
  "$APP/Contents/Info.plist" >/dev/null 2>&1 || \
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString 0.97.0-oldmac-$QS_PORT_VERSION" \
  -c "Set :CFBundleVersion $QS_PORT_VERSION" \
  "$APP/Contents/Info.plist" >/dev/null
echo "[make-dmg] bundle version: 0.97.0-oldmac-$QS_PORT_VERSION"

# Read it straight back. PlistBuddy's Add-then-Set fallback above fails silently
# if both branches error, and an unstamped bundle is exactly the defect this
# block exists to prevent.
STAMPED=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo '')
[ "$STAMPED" = "$QS_PORT_VERSION" ] || {
  echo "[make-dmg] .app CFBundleVersion is '$STAMPED', expected '$QS_PORT_VERSION'" >&2; exit 1; }
echo "[make-dmg] bundle version verified: $STAMPED"

cp    "$REPO_ROOT/MacOSX/QuakeSpasm.icns"    "$RESOURCES/"
cp -r "$REPO_ROOT/MacOSX/English.lproj"      "$RESOURCES/"
cp    "$REPO_ROOT/MacOSX/codecs/lib"/*.dylib "$APP/Contents/MacOS/"
# cp -a, NOT -r or -R. Both of those FOLLOW the symlinks that make a versioned
# framework a framework, so SDL.framework/Versions/Current stops being a link to
# A and becomes a second real copy of it. Measured: 2.0M as a proper framework,
# 4.5M flattened. Two consequences, and the second is fatal:
#   1. the image carries every framework twice over;
#   2. codesign refuses a flattened framework with "bundle format is ambiguous
#      (could be app or framework)", so the .app cannot be signed at all, and an
#      unsigned/invalid bundle is killed on Apple Silicon before it runs.
cp -a "$REPO_ROOT/MacOSX/SDL.framework"      "$APP/Contents/MacOS/"
# SDL2 as well, and it is NOT optional. The arm64 slice is the only one that
# links SDL2 rather than SDL 1.2 (build-arm64.sh), and it links it as
# @executable_path/SDL2.framework/Versions/A/SDL2. Shipping only SDL.framework
# meant every Apple Silicon Mac got a bundle whose arm64 slice could not
# resolve its own SDL, and the app died at launch, before main(), with
#   Termination Reason: Namespace DYLD, Code 1, Library missing
#   Library not loaded: @executable_path/SDL2.framework/Versions/A/SDL2
# macOS shows that as "Quakespasm quit unexpectedly", which reads like an
# engine crash rather than a missing file. Shipped broken in v1.15.
# SDL.framework has no arm64 slice and SDL2.framework has no ppc slice, so
# both have to be here: neither is a substitute for the other.
cp -a "$REPO_ROOT/MacOSX/SDL2.framework"     "$APP/Contents/MacOS/"
cp    "$BIN" "$APP/Contents/MacOS/quakespasm"
chmod +x "$APP/Contents/MacOS/quakespasm"
# Engine's own pak (menu/UI assets) ships in the gamedir root, beside id1/.
cp    "$REPO_ROOT/Quake/quakespasm.pak" "$GAMEDIR/"

# Launch-fix script (issue: imac-2019 DMG launch, 2026-09-02; folder-drag
# rework same day). Self-contained -- see the script's own header for why it
# does not depend on a sidecar copy of clear-launch-quarantine.sh. Lives
# INSIDE $GAMEDIR, next to Quakespasm.app, so it travels with a single
# folder-drag.
cp "$REPO_ROOT/scripts/bundle/Fix-Launch-Problems.command" "$GAMEDIR/Fix Launch Problems.command"
chmod +x "$GAMEDIR/Fix Launch Problems.command"
# Per-arch baselines + per-machine overlays, picked at boot by host.c.
#
# Shipped COMMENT-STRIPPED, and that is not cosmetic. Quake's Cbuf_Execute
# splits a line on ';' as well as on newline (cmd.c:162), and it does that
# BEFORE it decides whether the line is a '//' comment. So a semicolon inside a
# comment ends the comment as far as the command buffer is concerned, and
# everything after it is executed. Every config in this port had between 2 and
# 11 of them, including, with some irony, the comment in autoexec-ppc970.cfg
# that warns not to put semicolons in comments.
#
# Seen on hardware: a G5 quad logged two "Unknown command `" lines at startup,
# one for each semicolon in that warning. Harmless there, but only by luck. The
# text after a semicolon is whatever the prose happened to say, and if its first
# word matches a real command or cvar it will be run with the rest of the
# sentence as arguments.
#
# Stripping also keeps the combined baseline + overlay well inside Cbuf's fixed
# 8 KB, which is the same reason the Quake II port strips its own.
for cfg in ppc750 ppc7400 ppc970 i386 x86_64 arm64 yosemite sawtooth quicksilver mini-g4 mini-intel imac-2019 imac-g5 imac-g4; do
  sed -e 's,//.*,,' -e 's/[[:space:]]*$//' \
      "$REPO_ROOT/scripts/bundle/autoexec-$cfg.cfg" \
    | grep -v '^[[:space:]]*$' \
    > "$RESOURCES/autoexec-$cfg.cfg"
done

# ---- user-facing README inside the image ---------------------------------
cat > "$IMG/README.txt" <<EOF
QuakeSpasm - Old-Mac fat build ($VERSION)
=========================================

A QuakeSpasm fork tuned to look as good as possible while staying playable
on retro Macs from 1999 to today. ONE universal binary (PowerPC G3 + PowerPC
G4/AltiVec + PowerPC G5/970 + Intel x86_64); the right code slice and the
right per-machine visual/perf config are picked automatically at launch.

WHICH MAC OS X YOU NEED
-----------------------
The slice is chosen by CPU, and the OS plays no part in that choice, so each
CPU family has a real floor:

   G3  (750)               10.3.9 Panther or later     tested on 10.3.9 + 10.4.11
   G4  (7400/7450/7447A)   10.3.9 Panther or later     tested on 10.4.11
   G5  (970)               10.5 Leopard ONLY           tested on 10.5.8
   Intel, 64-bit           10.6 Snow Leopard or later  tested on 10.7.5 + 15.7

A G4 on Panther and an Intel Mac on Snow Leopard should both work, but neither
has been run on real hardware - there is no such machine here to try it on. The
G5 line is a genuine floor, not an untested gap: its slice needs 10.5.

32-bit-only Intel Macs (Core Duo / Core Solo) have no slice and cannot run this.
On Apple Silicon the Intel slice runs under Rosetta 2; there is no native arm64
slice.

WHAT'S NEW in $VERSION
----------------------
* The G3 slice is now tested on Tiger as well as Panther. Every PowerPC slice
  carries its exact CPU subtype (ppc750 / ppc7400 / ppc970), which is what lets
  Tiger and Leopard grade the fat binary correctly on a G3.
* The G4 slice is built for 10.3.9 instead of 10.4, so a G4 left on Panther can
  load it. AltiVec is unchanged and the Tiger G4s bench identically.
* The Intel slice is built for 10.6 instead of 10.7, covering 64-bit Macs left
  on Snow Leopard.

INSTALL
-------
1. Drag the "Quakespasm" folder (not just the .app) to your Desktop or
   Applications folder, or anywhere else you like -- it's self-contained.
2. Add your Quake data - put your own pak files inside that folder's id1/:
       Quakespasm/id1/pak0.pak              (shareware)
       Quakespasm/id1/pak0.pak + pak1.pak   (registered)
   Registered Quake is on Steam and GOG.
3. Double-click Quakespasm.app inside that folder.

If it shows an error about gfx.wad, or does nothing at all when
double-clicked, see TROUBLESHOOTING below.

GATEKEEPER (modern macOS)
--------------------------
The bundle is unsigned (no paid Apple Developer ID), so macOS quarantines
whatever you download. The first time you run anything unsigned from a new
location -- the app, or the fix script below -- right-click it and choose
Open instead of double-clicking; that one click can't be removed without
notarization we don't have. Not needed on Panther / Tiger / Lion, which
predate Gatekeeper.

TROUBLESHOOTING: "couldn't load gfx.wad" / Basedir is .../AppTranslocation/...
-------------------------------------------------------------------------------
Only possible on macOS 10.12 Sierra or later. This means Quakespasm.app still
carries the quarantine flag from being downloaded, and macOS ran it from a
temporary sandboxed copy instead of its real folder, so it can't see its own
data files next to it. Fix: open the "Quakespasm" folder and right-click "Fix
Launch Problems.command", choose Open once (see GATEKEEPER above), then try
Quakespasm.app again. Or from Terminal, inside that same folder:
    xattr -dr com.apple.quarantine .
This only needs doing once per copy of the game.

On Panther, Tiger, Leopard or Lion this cannot happen -- those all predate
App Translocation -- so "Fix Launch Problems.command" isn't needed there.
Running it anyway is safe: it checks the OS version itself and tells you so
instead of working through steps that would only ever be a no-op.

PER-MACHINE CONFIG
------------------
The app detects the Mac it's on (sysctl hw.model) and applies a hand-tuned
visual + performance config - anisotropic filtering, trilinear, alias
drop-shadows, translucent liquids, smooth lightstyles, and more on the
machines that can afford them; leaner settings where they can't. Every knob
is a runtime cvar or launch -flag, so nothing is locked in.

Project: https://github.com/matthewdeaves/old-mac-quakespasm
License: GPL-2.0-or-later (see the project repo).
EOF

# ---- build the .dmg on a Mac, with END-TO-END content verification -------
# CRITICAL (learned from the Q2 sister port - see MISTAKES.md 2026-05-31
# "DMG byte-flip"): `hdiutil verify` only checks the UDIF container's *internal*
# checksum - that the compressed blocks decompress to whatever was stored. It
# does NOT verify that what was stored matches our source. A single byte flipped
# anywhere in the rsync→hdiutil chain (e.g. a bad sector / RAM glitch on an old
# build host) passes `hdiutil verify` and ships a corrupt binary. That exact
# failure turned a register-save (stw r31) in Q2's ppc7400 slice into an illegal
# 64-bit opcode → EXC_PPC_PRIVINST → instant crash on every G4, while deploy.sh
# (which ships the fat binary directly, no DMG) was fine. So: after building,
# mount the finished image and md5 the actual binaries inside it against the
# source. Retry on mismatch; fail loud if it can't be made clean.
REMOTE="/tmp/qs-dmg-$VERSION"
# Panther (yosemite) ships rsync 2.5.x - needs --protocol=29, same as deploy.sh.
# (The default DMG_HOST is now Tiger, which ships a modern-enough rsync, so this
# only fires on a manual DMG_HOST=yosemite override.) NOTE: dropped --partial -
# it can reuse a stale chunk from a previous interrupted run, defeating the
# point of a clean re-ship on a verification-mismatch retry.
RSYNC_EXTRA=""
[ "$DMG_HOST" = "yosemite" ] && RSYNC_EXTRA="--protocol=29"

# Every corruptible code artifact we ship inside the bundle, asserted end-to-end:
# the 6-arch engine binary, the audio codec dylibs, and the SDL framework binary.
# The staged $IMG copies are plain local `cp` of the source tree, so the $IMG
# md5s ARE the true-source md5s. (Paths are space-free, so word-splitting them
# into the SRC_SUMS loop is safe; the IN-DMG list is hardcoded in the remote
# heredoc because `ssh host bash -s "$VAR"` word-splits a multi-path arg down to
# its first element - keep the two lists in sync.)
VERIFY_FILES="Quakespasm/Quakespasm.app/Contents/MacOS/quakespasm \
Quakespasm/Quakespasm.app/Contents/MacOS/libFLAC.dylib \
Quakespasm/Quakespasm.app/Contents/MacOS/libmad.dylib \
Quakespasm/Quakespasm.app/Contents/MacOS/libmikmod.dylib \
Quakespasm/Quakespasm.app/Contents/MacOS/libmpg123.dylib \
Quakespasm/Quakespasm.app/Contents/MacOS/libogg.dylib \
Quakespasm/Quakespasm.app/Contents/MacOS/libopus.dylib \
Quakespasm/Quakespasm.app/Contents/MacOS/libopusfile.dylib \
Quakespasm/Quakespasm.app/Contents/MacOS/libvorbis.dylib \
Quakespasm/Quakespasm.app/Contents/MacOS/libvorbisfile.dylib \
Quakespasm/Quakespasm.app/Contents/MacOS/libxmp.dylib \
Quakespasm/Quakespasm.app/Contents/MacOS/SDL.framework/Versions/A/SDL"

# ---- ad-hoc code-sign the staged bundle ----------------------------------
# REQUIRED for Apple Silicon. macOS on arm64 refuses to map a page whose code
# signature does not validate, and kills the process:
#
#   Termination Reason: CODESIGNING, Invalid Page
#   EXC_BAD_ACCESS ... SIGKILL (Code Signature Invalid)
#
# The prebuilt codec dylibs in MacOSX/codecs/lib are in exactly that state:
# `codesign -v` reports "invalid signature (code or signature have been
# modified)" on nine of them, because they were signed once and then had extra
# architecture slices lipo'd in. An INVALID signature is worse than none: an
# unsigned binary gets an implicit ad-hoc identity, a broken one is rejected.
#
# It also fixes a second, less obvious symptom. macOS keys its privacy grants
# (the "wants to access files in your Desktop folder" prompt) on the app's code
# identity, so a bundle whose identity is unstable re-prompts on every launch.
#
# Signed here rather than on DMG_HOST because DMG_HOST is a Tiger G4, which has
# no codesign and no notion of arm64. Signed BEFORE SRC_SUMS is computed so the
# end-to-end byte verification below hashes the files as they will ship.
#
# Nested-first order matters: signing the bundle before its contents would be
# invalidated by signing the contents afterwards.
if command -v codesign >/dev/null 2>&1; then
	echo "[make-dmg] ad-hoc code-signing the staged bundle"
	SAPP="$APP"  # $GAMEDIR/Quakespasm.app
	# Order is not optional. codesign validates a bundle's nested code when it
	# signs the bundle, so anything inside must already be signed:
	#   1. plain dylibs beside the executable  (skip anything inside a framework)
	#   2. each framework, signed as a DIRECTORY, never by its inner binary path
	#   3. the .app last, which signs the main executable as part of it
	# Signing the executable directly instead fails with
	#   "code object is not signed at all / In subcomponent: libopus.dylib"
	find "$SAPP" -type f -name '*.dylib' -not -path '*.framework/*' -print0 \
	  | while IFS= read -r -d '' f; do
			codesign --force --sign - "$f" >/dev/null 2>&1 \
			  || echo "[make-dmg] WARN: could not sign ${f#$SAPP/}" >&2
		done
	for fw in "$SAPP"/Contents/MacOS/*.framework "$SAPP"/Contents/Frameworks/*.framework; do
		[ -d "$fw" ] || continue
		# A versioned framework may only have symlinks and Versions/ at its root.
		# SDL.framework ships License.rtf, ReadMe.txt and UniversalBinaryNotes.rtf
		# there, and codesign refuses the lot with
		#   "unsealed contents present in the root directory of an embedded
		#    framework"
		# Move them under Versions/A/Resources rather than delete them: they are
		# the upstream licence and notes and should still ship.
		for stray in "$fw"/*; do
			[ -L "$stray" ] && continue
			[ "$(basename "$stray")" = "Versions" ] && continue
			mkdir -p "$fw/Versions/A/Resources"
			mv "$stray" "$fw/Versions/A/Resources/" 2>/dev/null || true
		done
		codesign --force --sign - "$fw" >/dev/null 2>&1 \
		  || echo "[make-dmg] WARN: could not sign $(basename "$fw")" >&2
	done
	codesign --force --sign - "$SAPP" >/dev/null 2>&1 \
	  || echo "[make-dmg] WARN: could not sign the .app bundle" >&2

	# Assert it took, on the bundle AND on every Mach-O in it. A silently
	# unsigned bundle is exactly the defect this block exists to prevent, so it
	# fails the build rather than shipping.
	codesign -v "$SAPP" >/dev/null 2>&1 || {
		echo "[make-dmg] FATAL: the .app bundle signature does not validate" >&2; exit 1; }
	BADSIG=$(find "$SAPP" -type f \( -name '*.dylib' -o -perm -u+x \) 2>/dev/null \
	  | while IFS= read -r f; do
			file "$f" 2>/dev/null | grep -q 'Mach-O' || continue
			codesign -v "$f" >/dev/null 2>&1 || echo "  ${f#$SAPP/}"
		done)
	[ -z "$BADSIG" ] || {
		echo "[make-dmg] FATAL: still not validly signed:" >&2
		echo "$BADSIG" >&2; exit 1; }
	echo "[make-dmg] signatures verified: bundle + every Mach-O inside it"
else
	echo "[make-dmg] WARN: no codesign here; the bundle will NOT run on Apple Silicon" >&2
fi

# Quarantine clear + LaunchServices re-register on the STAGED bundle, before
# hdiutil packages it (issue #35, shared primitive from
# old-mac-build-host#34). This is the fix for the actual reported symptom: a
# real published DMG downloaded via a browser measured
# `com.apple.quarantine` on 2026-08-28, and an ad-hoc-signed (not
# Developer-ID) app under quarantine gets killed by macOS's AppleSystemPolicy
# a few seconds into an apparently-normal launch — confirmed on imac-2019
# (Sequoia) by log: "ASP: Security policy would not allow process", ~18s
# after launch, no crash report. Clearing it here does not stop the
# quarantine flag being set again on THIS Mac's own download of the DMG we
# ship (that's the browser/Finder's doing, out of our control, and needs the
# one-time right-click-Open a real Developer ID + notarization would remove
# entirely) -- it stops it being set on files nested one level down that
# would otherwise inherit it independently, and it means an install that
# reaches a machine any other way than a fresh browser download (rsync,
# scp+ditto, a file share) is never quarantined via this DMG's own contents.
if [ -f "$REPO_ROOT/scripts/clear-launch-quarantine.sh" ]; then
  "$REPO_ROOT/scripts/clear-launch-quarantine.sh" "$APP"
fi

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
for f in Quakespasm/Quakespasm.app/Contents/MacOS/quakespasm \
         Quakespasm/Quakespasm.app/Contents/MacOS/libFLAC.dylib \
         Quakespasm/Quakespasm.app/Contents/MacOS/libmad.dylib \
         Quakespasm/Quakespasm.app/Contents/MacOS/libmikmod.dylib \
         Quakespasm/Quakespasm.app/Contents/MacOS/libmpg123.dylib \
         Quakespasm/Quakespasm.app/Contents/MacOS/libogg.dylib \
         Quakespasm/Quakespasm.app/Contents/MacOS/libopus.dylib \
         Quakespasm/Quakespasm.app/Contents/MacOS/libopusfile.dylib \
         Quakespasm/Quakespasm.app/Contents/MacOS/libvorbis.dylib \
         Quakespasm/Quakespasm.app/Contents/MacOS/libvorbisfile.dylib \
         Quakespasm/Quakespasm.app/Contents/MacOS/libxmp.dylib \
         Quakespasm/Quakespasm.app/Contents/MacOS/SDL.framework/Versions/A/SDL; do
  printf '%s  %s\n' "$(md5 "$MP/$f" 2>/dev/null | awk '{print $NF}')" "$f"
done
hdiutil detach "$MP" >/dev/null 2>&1 || hdiutil detach -force "$MP" >/dev/null 2>&1 || true
REMOTE_EOF
)
  if [ "$DMG_SUMS" = "$SRC_SUMS" ]; then verified=yes; break; fi
  echo "[make-dmg] WARNING: DMG contents differ from source (attempt $attempt) - retrying" >&2
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

echo "[make-dmg] OK - $OUT (container md5 $LCL_DMG_MD5, contents verified vs source)"
ls -lh "$OUT"
