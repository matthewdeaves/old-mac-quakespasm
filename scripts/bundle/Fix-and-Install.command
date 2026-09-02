#!/bin/sh
# Fix-and-Install.command - one-click install for the QuakeSpasm disk image.
#
# WHY THIS EXISTS: the bundle is unsigned (no paid Apple Developer ID yet --
# CLAUDE.md), so modern macOS quarantines it the moment a browser downloads
# this DMG. A quarantined app copied by hand (not dragged in Finder) gets
# "App Translocation": macOS runs it from a random, sandboxed copy instead of
# the real folder, so it can't find id1/gfx.wad next to it --
#   "W_LoadWadFile: couldn't load gfx.wad, Basedir is: /private/var/.../
#    AppTranslocation/.../d"
# -- or on some OS versions ASP just kills the process a few seconds in with
# no crash report. A README telling a person to run `xattr -dr` by hand is
# not a fix (CLAUDE.md: "Quarantine fix must be tooling, not a human step").
# This script IS that tooling: it installs the game AND clears the flag, so
# every launch after this one is a plain double-click.
#
# You still have to get THIS script running once via right-click > Open (or
# macOS says it "cannot be opened because it is from an unidentified
# developer") -- that one click is unavoidable without notarization. Nothing
# after it needs Terminal or a manual command.
set -eu

DIR=$(cd "$(dirname "$0")" && pwd)
DEST="$HOME/Applications/Quakespasm"

echo "QuakeSpasm - Fix and Install"
echo "============================"
echo

if [ ! -d "$DIR/Quakespasm.app" ]; then
	echo "ERROR: Quakespasm.app not found next to this script (looked in $DIR)." >&2
	echo "Run this from the mounted disk image, not a copy of just this file." >&2
	printf 'Press Return to close this window...'; read -r _
	exit 1
fi

mkdir -p "$DEST"
echo "Installing to: $DEST"

# cp -a, NOT cp -R: -R follows the symlinks that make SDL.framework a real
# framework and flattens it into a second real copy (same reason
# scripts/make-dmg.sh uses -a when it first stages the bundle).
cp -a "$DIR/Quakespasm.app" "$DEST/"
[ -f "$DIR/quakespasm.pak" ] && cp "$DIR/quakespasm.pak" "$DEST/"

# id1/ holds your Quake data (pak0.pak, pak1.pak). Never touched if it
# already exists, so re-running this after an update keeps your install.
if [ ! -d "$DEST/id1" ]; then
	mkdir -p "$DEST/id1"
	echo "Created $DEST/id1 -- put your pak0.pak (and pak1.pak if you have it) there."
fi

echo
echo "Clearing quarantine..."
if [ -x "$DIR/.fix-support/clear-launch-quarantine.sh" ]; then
	"$DIR/.fix-support/clear-launch-quarantine.sh" "$DEST"
else
	echo "WARN: clear-launch-quarantine.sh missing from this image, falling back to plain xattr" >&2
	xattr -dr com.apple.quarantine "$DEST" >/dev/null 2>&1 || true
fi

echo
echo "Done. Quakespasm.app is installed at:"
echo "  $DEST/Quakespasm.app"

# Case-insensitive-safe check (Quake data is traditionally shipped as
# uppercase PAK0.PAK). This is deliberately the LAST thing printed before the
# "double-click" line -- it's the last chance to tell a person where their
# data goes before they hit W_LoadWadFile with no idea which of several
# plausible folders was meant (real user hit this, 2026-09-02).
HAVE_PAK0=0
for f in "$DEST/id1/pak0.pak" "$DEST/id1/PAK0.PAK" "$DEST/id1/Pak0.pak"; do
	[ -f "$f" ] && HAVE_PAK0=1 && break
done
if [ "$HAVE_PAK0" = 0 ]; then
	echo
	echo "*** No pak0.pak yet -- Quakespasm.app will say \"couldn't load gfx.wad\" until you add it. ***"
	echo "Put your Quake data here:"
	echo "  $DEST/id1/pak0.pak              (shareware)"
	echo "  $DEST/id1/pak0.pak + pak1.pak   (registered, from your own copy of the game)"
fi

echo
echo "Double-click it from there from now on -- no more prompts."
echo
open -R "$DEST/Quakespasm.app" 2>/dev/null || true
printf 'Press Return to close this window...'
read -r _ignored
