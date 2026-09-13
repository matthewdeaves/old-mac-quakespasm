#!/usr/bin/env bash
# Install the release DMG onto a target Mac *exactly the way an end user would*:
# stage the .dmg under ~/oldmac/quakespasm/incoming (port-owned transfer
# staging, never the Desktop — user rule, retro-agents 5cbbb3d), mount it,
# then atomically publish its contents at /Applications/QuakeSpasm/. This is
# deliberately the DMG path (not deploy.sh's direct rsync) so the test loop
# exercises the same artifact and the same install steps a human performs —
# that is where the Q2 sister port's 2026-05-31 corrupt-DMG / illegal-
# instruction bug hid (deploy.sh was clean, the DMG wasn't). See MISTAKES.md.
#
# usage: scripts/deploy-dmg.sh <machine> [version]
#   machine: yosemite | yosemite-tiger | sawtooth | quicksilver | mini-g4 |
#            imac-g5 | mini-intel | imac-2019  (ssh alias)
#   version: e.g. v1.8  (default: newest dist/QuakeSpasm-OldMac-*.dmg)
#
# Preserves the user's game data: the id1/ folder (pak0.pak / pak1.pak / saves /
# configs) is left untouched; only the app + the engine's own quakespasm.pak are
# (re)installed.
#
# An existing /Applications/QuakeSpasm is upgraded, not refused: it is
# renamed aside to ~/oldmac/quakespasm/backups/QuakeSpasm.bak-<timestamp>
# (never deleted -- that is the rollback copy, restore it with
# scripts/rollback-dmg.sh; NOT left in /Applications itself, which holds
# only the current build) and its id1/ is what seeds the new install's game
# data, since that is the machine's actual current state. Only a genuinely
# first-ever install with no prior /Applications/QuakeSpasm falls back to
# seeding id1/ from the legacy ~/Desktop/quake/id1 this script used to read
# exclusively. old-mac-quakespasm#47, #49.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

HOST="${1:?usage: $0 <machine> [version]}"

# Claim this machine for the whole run. See scripts/pick-bench-host.sh.
#
# Re-exec under the picker rather than acquire-here-and-trap: bash traps REPLACE
# rather than compose, so a release trap installed at the top of a script that
# later sets its own trap is silently discarded, and the machine stays claimed
# until the stale reclaim. `--run` makes the lock a property of the INVOCATION,
# so it is released however this exits, and no caller has to remember to do it.
#
# The lock lives on the target, so it serialises across repos, agents and
# workstations, not just this checkout. It also refuses a host booted into an OS
# its alias does not name, which the multi-boot machines otherwise allow.
#
# RETRO_BENCH_LOCK guards against the re-exec recursing.
# BENCH_NO_LOCK=1 skips the lock, for when the picker itself is what you are
# debugging. It is not a way to get past a machine someone else is using.
_PICK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pick-bench-host.sh"
if [ "${RETRO_BENCH_LOCK:-}" != "$HOST" ] && [ "${BENCH_NO_LOCK:-0}" != 1 ] && [ -x "$_PICK" ]; then
	export RETRO_BENCH_LOCK="$HOST"
	exec "$_PICK" --run "$HOST" "deploy-dmg" -- "$0" "$@"
fi
VERSION="${2:-}"
if [ -z "$VERSION" ]; then
  DMG=$(ls -t "$REPO_ROOT"/dist/QuakeSpasm-OldMac-*.dmg 2>/dev/null | head -1)
  [ -n "$DMG" ] || { echo "no dist/QuakeSpasm-OldMac-*.dmg found — run scripts/make-dmg.sh" >&2; exit 1; }
else
  DMG="$REPO_ROOT/dist/QuakeSpasm-OldMac-$VERSION.dmg"
  [ -f "$DMG" ] || { echo "missing $DMG" >&2; exit 1; }
fi
DMG_BASE=$(basename "$DMG")

INCOMING="oldmac/quakespasm/incoming"
echo "[deploy-dmg $HOST] copy $DMG_BASE to ~/$INCOMING/"
ssh "$HOST" "mkdir -p ~/$INCOMING"

# Clean up any previously-shipped release DMGs first so bench machines don't
# accumulate stale versions across releases (and so a leftover same-name DMG
# can't be silently reused if a later scp ever fails). Scoped to our own
# QuakeSpasm-OldMac-*.dmg release artifacts in this staging dir — the user's
# own files and game data are never touched. Removing the current name too is
# fine: it's re-copied fresh on the next line. Also detach any stale mount of
# an old image so its /Volumes entry doesn't linger.
# find, not `ls -1 <glob>`: the incoming dir starts empty on every host (it's
# new, per-port staging under ~/oldmac, not the Desktop everyone already had
# stale DMGs sitting in), and zsh's default nomatch behavior prints "no
# matches found" straight to stderr on a failed glob BEFORE the command's own
# 2>/dev/null redirection ever applies. find is silent either way.
OLD_DMGS=$(ssh "$HOST" "find ~/$INCOMING -maxdepth 1 -name 'QuakeSpasm-OldMac-*.dmg' 2>/dev/null")
if [ -n "$OLD_DMGS" ]; then
  echo "[deploy-dmg $HOST] removing old release DMG(s) on target:"
  echo "$OLD_DMGS" | sed 's/^/    /'
  ssh "$HOST" "rm -f ~/$INCOMING/QuakeSpasm-OldMac-*.dmg"
fi

scp -q "$DMG" "$HOST:$INCOMING/$DMG_BASE"

# Verify the .dmg arrived intact (md5 the local vs remote copy) — defence in
# depth on top of make-dmg.sh's own end-to-end content check.
LCL_MD5=$(md5sum "$DMG" | cut -d' ' -f1)
RMT_MD5=$(ssh "$HOST" "md5 '$INCOMING/$DMG_BASE' | awk '{print \$NF}'")
[ "$LCL_MD5" = "$RMT_MD5" ] || { echo "[deploy-dmg $HOST] FATAL: scp corrupted the DMG ($LCL_MD5 != $RMT_MD5)" >&2; exit 1; }
echo "[deploy-dmg $HOST] DMG in $INCOMING verified intact ($RMT_MD5)"

# Shared primitive (issue #35), scp'd over for the remote block below to run
# and then delete. Best-effort — an old checkout without it just skips the
# quarantine-clear/lsregister step.
if [ -f "$REPO_ROOT/scripts/clear-launch-quarantine.sh" ]; then
  scp -pq "$REPO_ROOT/scripts/clear-launch-quarantine.sh" "$HOST:.qs-clear-launch-quarantine.sh"
fi

echo "[deploy-dmg $HOST] mount + stage /Applications/QuakeSpasm/ (upgrade with backup if occupied)"
ssh "$HOST" bash -s "$DMG_BASE" <<'REMOTE_EOF'
set -e
DMG_BASE="$1"
MNT="$HOME/qsinstall-mnt"
DEST="/Applications/QuakeSpasm"
DEST_STAGE="/Applications/.QuakeSpasm.stage.$$"
BACKUP_DIR="$HOME/oldmac/quakespasm/backups"

# fresh mountpoint — detach any stale attach, then rmdir (NEVER rm -rf a path
# that might still be a mounted read-only volume).
hdiutil detach "$MNT" >/dev/null 2>&1 || hdiutil detach -force "$MNT" >/dev/null 2>&1 || true
rmdir "$MNT" 2>/dev/null || true
mkdir -p "$MNT"
hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$HOME/oldmac/quakespasm/incoming/$DMG_BASE" >/dev/null

# Upgrade, never clobber: an existing install is renamed aside as the
# rollback copy (scripts/rollback-dmg.sh restores it), it is NEVER deleted
# or written into in place. Backups live under ~/oldmac, not /Applications
# (user rule, 2026-09-13: /Applications holds only the current build, so a
# human testing it is never looking at an ambiguous directory listing —
# caught live on mini-g4 by old-mac-build-host, old-mac-quakespasm#49).
# old-mac-quakespasm#47.
BACKUP=""
if [ -e "$DEST" ] || [ -L "$DEST" ]; then
  OLD_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$DEST/Quakespasm.app/Contents/Info.plist" 2>/dev/null || echo unknown)"
  mkdir -p "$BACKUP_DIR"
  BACKUP="$BACKUP_DIR/QuakeSpasm.bak-$(date +%Y%m%d-%H%M%S)"
  [ -e "$BACKUP" ] && { echo "REFUSE: $BACKUP already exists (two installs same second?)" >&2; exit 11; }
  mv "$DEST" "$BACKUP"
  echo "upgrading: backed up existing install (version $OLD_VER) to $BACKUP"
fi
[ ! -e "$DEST_STAGE" ] && [ ! -L "$DEST_STAGE" ] || { echo "REFUSE: staging path exists" >&2; exit 11; }
trap 'rm -rf "$DEST_STAGE"' EXIT HUP INT TERM
mkdir "$DEST_STAGE"
# Seed id1/ (the actual game data: paks, saves, configs). An upgrade's own
# backup is the machine's real current state and wins; only a genuine
# first-ever install (no prior $DEST) falls back to the legacy Desktop copy.
if [ -n "$BACKUP" ] && [ -d "$BACKUP/id1" ]; then
  ditto "$BACKUP/id1" "$DEST_STAGE/id1"
elif [ -d "$HOME/Desktop/quake/id1" ]; then
  ditto "$HOME/Desktop/quake/id1" "$DEST_STAGE/id1"
else
  mkdir "$DEST_STAGE/id1"
fi
ditto "$MNT/Quakespasm/Quakespasm.app" "$DEST_STAGE/Quakespasm.app"
cp -p "$MNT/Quakespasm/quakespasm.pak" "$DEST_STAGE/quakespasm.pak"
cmp -s "$MNT/Quakespasm/Quakespasm.app/Contents/MacOS/quakespasm" \
       "$DEST_STAGE/Quakespasm.app/Contents/MacOS/quakespasm"
cmp -s "$MNT/Quakespasm/quakespasm.pak" "$DEST_STAGE/quakespasm.pak"

# Defensive quarantine clear + LaunchServices re-register (issue #35, shared
# primitive from old-mac-build-host#34). The DMG reaches this machine by scp,
# which never sets com.apple.quarantine, and ditto doesn't add it either, so
# the clear is normally a no-op here too — this script's install path was
# never the one that reproduced the launch bug. Stays as belt and suspenders,
# matching deploy.sh's install guarantee exactly. lsregister -f is the part
# that matters regardless of quarantine: a stale LaunchServices registration
# for a rebuilt app at this same path can make Finder open the wrong old copy.
if [ -x "$HOME/.qs-clear-launch-quarantine.sh" ]; then
  "$HOME/.qs-clear-launch-quarantine.sh" "$DEST_STAGE/Quakespasm.app"
  rm -f "$HOME/.qs-clear-launch-quarantine.sh"
fi

# Same-volume rename makes the verified staging directory visible in one step.
mv "$DEST_STAGE" "$DEST"
trap - EXIT HUP INT TERM

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
# `|| true`: this is the LAST statement before REMOTE_EOF under `set -e` --
# a fresh install (no prior $DEST) leaves $BACKUP empty, the `[ -n ]` test
# itself fails, and with nothing following to protect it that failure exits
# the whole remote script with status 1 despite a fully successful install.
# Reproduced live on g5-panther's first-ever install before this fix.
[ -n "$BACKUP" ] && echo "rollback copy kept at: $BACKUP (scripts/rollback-dmg.sh restores it)" || true
REMOTE_EOF

echo "[deploy-dmg $HOST] done — installed from $DMG_BASE"
