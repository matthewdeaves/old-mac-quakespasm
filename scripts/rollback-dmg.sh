#!/usr/bin/env bash
# rollback-dmg.sh: restore the install deploy-dmg.sh's upgrade-with-backup
# renamed aside, undoing a bad upgrade.
#
# usage: scripts/rollback-dmg.sh <machine> [backup-name]
#   machine:     ssh alias
#   backup-name: e.g. QuakeSpasm.bak-20260913-095619 (default: the newest
#                one in ~/oldmac/quakespasm/backups/ on the target)
#
# Never deletes anything: the install being rolled back FROM is itself kept,
# renamed into the same ~/oldmac/quakespasm/backups/ directory as
# QuakeSpasm.rolledback-<timestamp> -- /Applications holds only the current
# build (user rule, 2026-09-13; old-mac-quakespasm#47, #49).

set -euo pipefail

HOST="${1:?usage: $0 <machine> [backup-name]}"
WANT_BACKUP="${2:-}"

# Claim this machine for the whole run — same convention as deploy-dmg.sh.
# See scripts/pick-bench-host.sh.
_PICK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pick-bench-host.sh"
if [ "${RETRO_BENCH_LOCK:-}" != "$HOST" ] && [ "${BENCH_NO_LOCK:-0}" != 1 ] && [ -x "$_PICK" ]; then
	export RETRO_BENCH_LOCK="$HOST"
	exec "$_PICK" --run "$HOST" "rollback-dmg" -- "$0" "$@"
fi

echo "[rollback-dmg $HOST] looking for a backup"
ssh "$HOST" bash -s "$WANT_BACKUP" <<'REMOTE_EOF'
set -e
WANT="$1"
DEST="/Applications/QuakeSpasm"
BACKUP_DIR="$HOME/oldmac/quakespasm/backups"

if [ -n "$WANT" ]; then
  BACKUP="$BACKUP_DIR/$WANT"
else
  BACKUP="$(ls -1dt "$BACKUP_DIR"/QuakeSpasm.bak-* 2>/dev/null | head -1 || true)"
fi
[ -n "$BACKUP" ] && [ -d "$BACKUP" ] || {
  echo "no backup found (looked for $BACKUP_DIR/QuakeSpasm.bak-*)" >&2
  exit 1
}

ver() { /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$1/Quakespasm.app/Contents/Info.plist" 2>/dev/null || echo unknown; }
CUR_VER="unknown"; [ -e "$DEST/Quakespasm.app/Contents/Info.plist" ] && CUR_VER="$(ver "$DEST")"
BAK_VER="unknown"; [ -e "$BACKUP/Quakespasm.app/Contents/Info.plist" ] && BAK_VER="$(ver "$BACKUP")"

echo "rolling back: current install (version $CUR_VER) -> restoring $BACKUP (version $BAK_VER)"

# Same-volume renames only: the install being replaced is kept, never removed.
if [ -e "$DEST" ] || [ -L "$DEST" ]; then
  mkdir -p "$BACKUP_DIR"
  SIDE="$BACKUP_DIR/QuakeSpasm.rolledback-$(date +%Y%m%d-%H%M%S)"
  mv "$DEST" "$SIDE"
  echo "current install kept at: $SIDE"
fi
mv "$BACKUP" "$DEST"
echo "restored $DEST from $BACKUP"
file "$DEST/Quakespasm.app/Contents/MacOS/quakespasm" 2>/dev/null | sed 's/.*: //' || true
REMOTE_EOF

echo "[rollback-dmg $HOST] done"
