#!/bin/bash
# lay-out-dmg.sh - package a staged .app into a DMG with the standard macOS
# installer layout (icon left, /Applications alias right, drag arrow), instead
# of a bare hdiutil DMG that just invites a double-click.
#
# ============================================================================
# CANONICAL COPY. This file lives in old-mac-build-host and is distributed to
# the port repos by scripts/sync-shared-scripts.sh. Edit it HERE and re-run
# that script; do not edit the copies. See docs/adr/0001 -- this is a
# PRIMITIVE (a path in, nothing product-specific), not a driver: it does not
# know what game it is packaging.
# ============================================================================
#
# WHY THIS EXISTS (issue #37, follow-on to #34/#36): measured 2026-08-28, a
# plain Finder drag-install into /Applications runs clean (no AMFI kill);
# double-clicking an app straight off the mounted DMG is the actual failure
# path (#36). No port's make-dmg.sh laid its DMG out to nudge the safe method
# -- every one just ran plain hdiutil, which invites the failure path instead
# of visually steering away from it. #36 already decided against paid signing
# for now; this is the UX mitigation that decision implied, not a substitute
# for it.
#
# WHY create-dmg AND NOT HAND-ROLLED APPLESCRIPT
# -----------------------------------------------
# create-dmg (https://github.com/create-dmg/create-dmg, Homebrew: `brew
# install create-dmg`) already handles the Finder .DS_Store/AppleScript
# window-layout trick, including the parts that are easy to get subtly wrong
# (waiting for Finder to actually apply the layout before detaching, handling
# a busy Finder, cleaning up its own temp mount). Wrapping a proven tool beats
# re-solving a problem this repo does not need to own the internals of.
#
# MEASURED 2026-08-28: the AppleScript/Finder-scripting trick DOES work over
# a plain ssh session with no console user logged in and no attached display
# -- checked directly on mini-intel (one of the three Lion minis with no
# monitor, build-host#20), a trivial `osascript -e 'tell application "Finder"
# to get name of startup disk'` returned cleanly (exit 0). This was the
# ticket's own open question ("verify ... before committing to the design")
# and it does not block this design. A LaunchServices/Adobe-scripting-addition
# warning printed alongside it is unrelated noise (an old Adobe .osax with no
# universal binary slice) and not a failure.
#
# NO BACKGROUND IMAGE SHIPPED HERE ON PURPOSE. The ticket left "who designs a
# shared drag-me graphic" undecided. Rather than block the primitive on that,
# --background is optional: omit it and create-dmg still lays out the icon
# and the /Applications arrow on a plain background, which is already the
# fix that matters (nudging a drag, not a double-click). A background can be
# added later without changing this script's interface.
#
# usage:
#   scripts/lay-out-dmg.sh STAGED_DIR APP_NAME OUTPUT.dmg [BACKGROUND.png]
#     STAGED_DIR    a directory containing ONLY what should be on the DMG
#                   (the .app, and nothing else this script needs to know
#                   about -- a port's own make-dmg.sh stages this however it
#                   already does, e.g. a README).
#     APP_NAME      the .app's name as it appears in STAGED_DIR, e.g.
#                   "Quake3.app" -- used to size/position its icon and to
#                   derive the volume name if not overridden.
#     OUTPUT.dmg    where to write the finished DMG. Any existing file at
#                   this path is removed first (create-dmg refuses to
#                   overwrite).
#     BACKGROUND.png  optional folder background (png/gif/jpg).
#
# env:
#   VOLNAME       Finder volume name (default: APP_NAME without ".app")
#   WINDOW_W/H    Finder window size (default: 660x400)
#   ICON_SIZE     icon size in the window (default: 128)
#
# exit: 0 on success. 2 on a bad argument or missing create-dmg. Whatever
#       create-dmg itself returns otherwise.
#
# Deliberately NOT a "host:" self-contained-over-ssh script (see README.md's
# convention for those): this runs on whichever machine packages the DMG --
# the same place make-dmg.sh already runs -- as a local step, not piped over
# ssh to a vintage Mac. create-dmg needs Homebrew and a Finder to talk to;
# neither exists on this fleet's PowerPC/Lion targets, nor should it.
set -euo pipefail

STAGED_DIR="${1:?usage: lay-out-dmg.sh STAGED_DIR APP_NAME OUTPUT.dmg [BACKGROUND.png]}"
APP_NAME="${2:?usage: lay-out-dmg.sh STAGED_DIR APP_NAME OUTPUT.dmg [BACKGROUND.png]}"
OUTPUT="${3:?usage: lay-out-dmg.sh STAGED_DIR APP_NAME OUTPUT.dmg [BACKGROUND.png]}"
BACKGROUND="${4:-}"

command -v create-dmg >/dev/null 2>&1 || {
	echo "lay-out-dmg: create-dmg not found. Install it: brew install create-dmg" >&2
	exit 2
}
[ -d "$STAGED_DIR" ] || { echo "lay-out-dmg: no such directory: $STAGED_DIR" >&2; exit 2; }
[ -e "$STAGED_DIR/$APP_NAME" ] || {
	echo "lay-out-dmg: $APP_NAME not found in $STAGED_DIR" >&2; exit 2; }

VOLNAME="${VOLNAME:-${APP_NAME%.app}}"
WINDOW_W="${WINDOW_W:-660}"
WINDOW_H="${WINDOW_H:-400}"
ICON_SIZE="${ICON_SIZE:-128}"

rm -f "$OUTPUT"

args=(
	--volname "$VOLNAME"
	--window-pos 200 120
	--window-size "$WINDOW_W" "$WINDOW_H"
	--icon-size "$ICON_SIZE"
	--icon "$APP_NAME" 160 190
	--hide-extension "$APP_NAME"
	--app-drop-link 500 190
	--no-internet-enable
)
[ -n "$BACKGROUND" ] && args+=(--background "$BACKGROUND")

echo "lay-out-dmg: packaging $APP_NAME from $STAGED_DIR -> $OUTPUT"
create-dmg "${args[@]}" "$OUTPUT" "$STAGED_DIR"
echo "lay-out-dmg: done"
