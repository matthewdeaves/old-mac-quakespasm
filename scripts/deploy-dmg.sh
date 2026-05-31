#!/usr/bin/env bash
# Install the release DMG onto a target Mac *exactly the way an end user would*:
# copy the .dmg to the Desktop, mount it, copy its contents into
# ~/Desktop/quake/, then unmount. This is deliberately the DMG path (not
# deploy.sh's direct rsync) so the test loop exercises the same artifact and the
# same install steps a human performs — that is where the Q2 sister port's
# 2026-05-31 corrupt-DMG / illegal-instruction bug hid (deploy.sh was clean, the
# DMG wasn't). See MISTAKES.md.
#
# usage: scripts/deploy-dmg.sh <machine> [version]
#   machine: yosemite | sawtooth | quicksilver | mini-g4 | imac-g5 |
#            mini-intel | imac-2019  (ssh alias)
#   version: e.g. v1.8  (default: newest dist/QuakeSpasm-OldMac-*.dmg)
#
# Preserves the user's game data: the id1/ folder (pak0.pak / pak1.pak / saves /
# configs) is left untouched; only the app + the engine's own quakespasm.pak are
# (re)installed.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

HOST="${1:?usage: $0 <machine> [version]}"
VERSION="${2:-}"
if [ -z "$VERSION" ]; then
  DMG=$(ls -t "$REPO_ROOT"/dist/QuakeSpasm-OldMac-*.dmg 2>/dev/null | head -1)
  [ -n "$DMG" ] || { echo "no dist/QuakeSpasm-OldMac-*.dmg found — run scripts/make-dmg.sh" >&2; exit 1; }
else
  DMG="$REPO_ROOT/dist/QuakeSpasm-OldMac-$VERSION.dmg"
  [ -f "$DMG" ] || { echo "missing $DMG" >&2; exit 1; }
fi
DMG_BASE=$(basename "$DMG")

echo "[deploy-dmg $HOST] copy $DMG_BASE to ~/Desktop/"
ssh "$HOST" 'mkdir -p ~/Desktop'
scp -q "$DMG" "$HOST:Desktop/$DMG_BASE"

# Verify the .dmg arrived intact (md5 the local vs remote copy) — defence in
# depth on top of make-dmg.sh's own end-to-end content check.
LCL_MD5=$(md5sum "$DMG" | cut -d' ' -f1)
RMT_MD5=$(ssh "$HOST" "md5 'Desktop/$DMG_BASE' | awk '{print \$NF}'")
[ "$LCL_MD5" = "$RMT_MD5" ] || { echo "[deploy-dmg $HOST] FATAL: scp corrupted the DMG ($LCL_MD5 != $RMT_MD5)" >&2; exit 1; }
echo "[deploy-dmg $HOST] DMG on Desktop verified intact ($RMT_MD5)"

echo "[deploy-dmg $HOST] mount + install into ~/Desktop/quake/ (preserving id1/ game data)"
ssh "$HOST" bash -s "$DMG_BASE" <<'REMOTE_EOF'
set -e
DMG_BASE="$1"
MNT="$HOME/qsinstall-mnt"
DEST="$HOME/Desktop/quake"

# fresh mountpoint — detach any stale attach, then rmdir (NEVER rm -rf a path
# that might still be a mounted read-only volume).
hdiutil detach "$MNT" >/dev/null 2>&1 || hdiutil detach -force "$MNT" >/dev/null 2>&1 || true
rmdir "$MNT" 2>/dev/null || true
mkdir -p "$MNT"
hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$HOME/Desktop/$DMG_BASE" >/dev/null

mkdir -p "$DEST"
# Replace the app wholesale so no stale bundle files survive. ditto keeps the
# bundle bit, perms (+x on the binary) and resource forks.
rm -rf "$DEST/Quakespasm.app"
ditto "$MNT/Quakespasm.app" "$DEST/Quakespasm.app"
# The engine's own pak (menu/UI assets) lives in the gamedir root beside id1/.
cp -p "$MNT/quakespasm.pak" "$DEST/quakespasm.pak"

# detach — retry until the slow-disk flush completes; only THEN rmdir the now-
# empty mountpoint (rmdir can't touch mounted contents, so it's safe).
detached=no
for k in 1 2 3 4 5; do
  if hdiutil detach "$MNT" >/dev/null 2>&1; then detached=yes; break; fi
  sleep 2
done
[ "$detached" = yes ] || hdiutil detach -force "$MNT" >/dev/null 2>&1 || true
rmdir "$MNT" 2>/dev/null || true

echo "installed into $DEST:"
ls -la "$DEST" | awk '{print "  "$NF}' | grep -vE '^\s+\.$|^\s+\.\.$' | grep -v '^  $' || true
echo "app binary archs:"
file "$DEST/Quakespasm.app/Contents/MacOS/quakespasm" 2>/dev/null | sed 's/.*: //' || true
[ -d "$DEST/id1" ] && echo "id1/ game data preserved." || echo "NOTE: no id1/ yet — add pak0.pak before launching."
REMOTE_EOF

echo "[deploy-dmg $HOST] done — installed from $DMG_BASE"
