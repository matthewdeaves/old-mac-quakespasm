#!/bin/sh
# Fix Launch Problems.command - clears the macOS "downloaded from the
# internet" flag that can make Quakespasm.app launch cut off from its own
# data files (App Translocation -- see the README's TROUBLESHOOTING
# section). Safe to run more than once; does nothing if there is nothing to
# fix. Matches alephone's "Fix Launch Problems.command" pattern (user,
# 2026-09-02: "it should just run from same location as the fat binary...
# make it like how the others work") -- no copy to ~/Applications, no
# install step, just fixes the folder you already put it in, wherever that
# is.
#
# Self-contained on purpose, NOT a wrapper around a sidecar copy of
# clear-launch-quarantine.sh: a hidden ".fix-support/" helper does not
# survive a real user's drag of only the visible "Quakespasm" folder items
# (Finder hides dotfiles by default) -- same failure alephone hit live on
# imac-2019, 2026-09-02: "No such file or directory" because the hidden
# helper never came along. Inlining the logic removes that failure mode.
#
# Lives INSIDE the "Quakespasm" folder, next to Quakespasm.app, not beside
# it at the DMG root: a single-folder drag always brings it along, where a
# DMG-root sibling only travels if the user drags it separately -- and most
# people just drag the one game folder they came for.
set -eu
cd "$(dirname "$0")"
echo "Fixing Quakespasm's launch flags..."
echo

if [ ! -e "Quakespasm.app" ]; then
	echo "Couldn't find Quakespasm.app next to this script."
	echo "Keep this file inside the 'Quakespasm' folder and try again."
	echo
	printf 'Press Return to close this window...'
	read -r _
	exit 1
fi

TARGET="."

# Presence check trusted only via -l's printed output (see
# clear-launch-quarantine.sh): xattr's own exit codes lie about presence on
# more than one xattr build encountered on this fleet.
has_quarantine() { xattr -l "$1" 2>/dev/null | grep -q '^com\.apple\.quarantine:'; }

had_flag=0
find "$TARGET" 2>/dev/null | while IFS= read -r f; do
	has_quarantine "$f" && echo found
done | grep -q found && had_flag=1

# Fast recursive form first (modern xattr); fall back to a manual walk with
# non-recursive -d per file for older xattr builds (no -r flag at all on
# some OS versions still in the fleet) that would otherwise just print
# usage and do nothing.
xattr -dr com.apple.quarantine "$TARGET" >/dev/null 2>&1 || true
find "$TARGET" 2>/dev/null | while IFS= read -r f; do
	xattr -d com.apple.quarantine "$f" >/dev/null 2>&1 || true
done

if [ "$had_flag" = 1 ]; then
	echo "Cleared the download flag."
else
	echo "Nothing to fix -- no download flag was set."
fi

# Force LaunchServices to re-register: a stale registration can make Finder
# open the wrong copy, independent of the quarantine flag.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ -x "$LSREGISTER" ]; then
	find "$TARGET" -maxdepth 4 -iname "*.app" -print 2>/dev/null | while IFS= read -r a; do
		[ -n "$a" ] || continue
		"$LSREGISTER" -f "$a" >/dev/null 2>&1 || true
	done
fi

# Case-insensitive-safe (Quake data is traditionally shipped as uppercase
# PAK0.PAK). Two real users hit "couldn't load gfx.wad" the same night with
# no idea which folder the engine actually wanted (2026-09-02) -- say it
# plainly, right here, the last thing before they try again.
HAVE_PAK0=0
for f in id1/pak0.pak id1/PAK0.PAK id1/Pak0.pak; do
	[ -f "$f" ] && HAVE_PAK0=1 && break
done
if [ "$HAVE_PAK0" = 0 ]; then
	echo
	echo "*** No pak0.pak yet -- Quakespasm.app will say \"couldn't load gfx.wad\" until you add it. ***"
	echo "Put your Quake data here:"
	echo "  $(pwd)/id1/pak0.pak              (shareware)"
	echo "  $(pwd)/id1/pak0.pak + pak1.pak   (registered, from your own copy of the game)"
fi

echo
echo "Done. Close this window, then double-click Quakespasm.app again."
echo
printf 'Press Return to close this window...'
read -r _
