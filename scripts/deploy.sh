#!/usr/bin/env bash
# Assemble a self-contained Quakespasm.app bundle and deploy it to the
# target machine. Idempotent — safe to re-run.
#
# usage: scripts/deploy.sh <yosemite|yosemite-tiger|sawtooth|quicksilver|mini-g4|mini-intel|mini-intel2|mini-sl|imac-2019|imac-g5|g5-desktop>
#
# pre:   build/quakespasm-fat must exist (scripts/build-fat.sh)
#
# Ships ONE Mach-O (6 slices: ppc750 + ppc7400 + ppc970 + i386 + x86_64 +
# arm64). The .app is self-contained: per-arch + per-machine autoexec configs
# live inside Quakespasm.app/Contents/Resources/, loaded by host.c via
# CFBundle (QS_ExecConfigFromBundle). Compile-time QS_ARCH_PPC970 / __VEC__ /
# __ppc__ / __x86_64__ / __aarch64__ / __i386__ picks the per-arch baseline
# (host.c:1017, mirrored for the launcher panel at
# MacOSX/AppController.m:433); runtime sysctl hw.model picks the
# per-machine overlay. End-user install is just .app + their own
# id1/pak0.pak alongside.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TARGET="${1:?usage: $0 <yosemite|yosemite-tiger|sawtooth|quicksilver|mini-g4|mini-intel|mini-intel2|mini-sl|imac-2019|imac-g5|g5-desktop>}"

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
if [ "${RETRO_BENCH_LOCK:-}" != "$TARGET" ] && [ "${BENCH_NO_LOCK:-0}" != 1 ] && [ -x "$_PICK" ]; then
	export RETRO_BENCH_LOCK="$TARGET"
	exec "$_PICK" --run "$TARGET" "deploy" -- "$0" "$@"
fi

# MacOSX/SDL.framework is a 3-arch fat (x86_64 + i386 + ppc) where the
# ppc slice is the Panther-compatible build. One framework serves all
# six targets — no per-host SDL swap. See "How the fat SDL was built"
# in MacOSX/CLAUDE.md if it ever needs regenerating from
# MacOSX/SDL-panther.dylib.
case "$TARGET" in
  yosemite)
    # PowerMac1,1 — G3 / Panther. Needs --protocol=29 because Panther
    # ships rsync 2.5.x, older than the orchestrator's.
    HOST="yosemite"
    RSYNC_EXTRA="--protocol=29"
    ;;
  yosemite-tiger|sawtooth|quicksilver|mini-g4|mini-intel|mini-intel2|mini-sl|imac-2019|imac-g5|g5-desktop)
    # mini-intel2: second Macmini2,1, same model as mini-intel. hw.model
    # matching in host.c's qs_machine_map hands it the autoexec-mini-intel
    # overlay automatically -- no per-machine file needed (issue #32).
    #
    # g5-desktop: PowerMac7,3, 2.7 GHz G5, ATY RV351, Leopard 10.5.8.
    # No qs_machine_map entry, so it runs the ppc970 baseline. Whether it
    # should get the imac-g5-style native-res overlay is deliberately open
    # (issue #32) pending its first bench data.
    # imac-g5: PowerMac8,2 iMac G5 on Leopard 10.5.8. Leopard ships
    # rsync 2.6.9 (protocol 29), same as the Tiger boxes — no
    # --protocol downgrade needed (only Panther's 2.5.x needs that).
    #
    # yosemite-tiger: the SAME PowerMac1,1 as `yosemite`, booted from its Tiger
    # partition (same IP; one OS at a time). It belongs here rather than in the
    # yosemite case because Tiger ships rsync 2.6.x — the --protocol=29 downgrade
    # is a Panther-only workaround. The ppc750 slice is min-10.3 so it loads on
    # Tiger unchanged, and hw.model still reads PowerMac1,1, so the same
    # per-machine overlay applies.
    #
    # mini-sl: Macmini3,1, Snow Leopard 10.6.8, GeForce 9400. Never deployed
    # to before 2026-08-23 (no display until then). Confirmed on the machine:
    # rsync 2.6.9 protocol 29, same generation as the rest of this branch —
    # no downgrade needed. hw.model has no per-machine overlay entry in
    # host.c's qs_machine_map yet, so it runs the autoexec-x86_64 baseline
    # only; QS_ExecConfigFromBundle returns false on a missing resource
    # (host.c:64), no crash. That is the correct first-exercise state — a
    # tuned overlay needs real fps data from this machine first.
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

# Stamp the PORT release version into the bundle so a human can tell which build
# is installed from Finder's Get Info, not just from the engine console. The
# static plist carries upstream's engine version (0.97.0), which never changes
# between our releases and so identifies nothing. Same source of truth as the
# binary's own version string: QS_PORT_VERSION, i.e. `git describe`.
QS_PORT_VERSION="${QS_PORT_VERSION:-$(git -C "$REPO_ROOT" describe --tags --always --dirty 2>/dev/null || echo unknown)}"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString 0.97.0-oldmac-$QS_PORT_VERSION" \
  -c "Add :CFBundleVersion string $QS_PORT_VERSION" \
  "$STAGE/Quakespasm.app/Contents/Info.plist" >/dev/null 2>&1 || \
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString 0.97.0-oldmac-$QS_PORT_VERSION" \
  -c "Set :CFBundleVersion $QS_PORT_VERSION" \
  "$STAGE/Quakespasm.app/Contents/Info.plist" >/dev/null
echo "[deploy] bundle version: 0.97.0-oldmac-$QS_PORT_VERSION"

cp "$REPO_ROOT/MacOSX/QuakeSpasm.icns"    "$RESOURCES/"
cp -r "$REPO_ROOT/MacOSX/English.lproj"   "$RESOURCES/"
cp "$REPO_ROOT/MacOSX/codecs/lib"/*.dylib "$STAGE/Quakespasm.app/Contents/MacOS/"
cp -r "$REPO_ROOT/MacOSX/SDL.framework"   "$STAGE/Quakespasm.app/Contents/MacOS/"

cp "$BIN" "$STAGE/Quakespasm.app/Contents/MacOS/quakespasm"
chmod +x "$STAGE/Quakespasm.app/Contents/MacOS/quakespasm"
cp "$REPO_ROOT/Quake/quakespasm.pak" "$STAGE/"

# Ad-hoc code-sign the staged bundle, same recipe and same reasons as
# make-dmg.sh (issue #35): REQUIRED for Apple Silicon, where macOS refuses to
# map a page whose code signature does not validate (EXC_BAD_ACCESS, "Code
# Signature Invalid") — deploy.sh ships the same fat binary make-dmg.sh does,
# arm64 slice included, so it needs the same signature. It also stabilises the
# app's code identity so macOS's per-app privacy grants (Desktop folder
# access) don't re-prompt on every deploy. codesign only exists on the
# workstation running this script (Lion/PPC hosts never run it locally); a
# fresh build host without codesign silently skips, same fallback as
# make-dmg.sh.
if command -v codesign >/dev/null 2>&1; then
  echo "[deploy] ad-hoc code-signing the staged bundle"
  SAPP="$STAGE/Quakespasm.app"
  find "$SAPP" -type f -name '*.dylib' -not -path '*.framework/*' -print0 \
    | while IFS= read -r -d '' f; do
        codesign --force --sign - "$f" >/dev/null 2>&1 \
          || echo "[deploy] WARN: could not sign ${f#$SAPP/}" >&2
      done
  for fw in "$SAPP"/Contents/MacOS/*.framework "$SAPP"/Contents/Frameworks/*.framework; do
    [ -d "$fw" ] || continue
    codesign --force --sign - "$fw" >/dev/null 2>&1 \
      || echo "[deploy] WARN: could not sign $(basename "$fw")" >&2
  done
  codesign --force --sign - "$SAPP" >/dev/null 2>&1 \
    || echo "[deploy] WARN: could not sign the .app bundle" >&2
fi

# Per-arch baselines + per-machine overlays. host.c picks the right
# baseline at compile time and the right overlay at runtime via sysctl
# hw.model. All ship inside the .app so the bundle is self-contained.
# Comment-stripped, for the same reason make-dmg.sh strips them: Cbuf_Execute
# splits on ';' before it decides a line is a '//' comment, so a semicolon
# inside a comment ends the comment and the rest of the sentence is executed.
for cfg in ppc750 ppc7400 ppc970 i386 x86_64 arm64 yosemite sawtooth quicksilver mini-g4 mini-intel imac-2019 imac-g5 imac-g4; do
  sed -e 's,//.*,,' -e 's/[[:space:]]*$//' \
      "$REPO_ROOT/scripts/bundle/autoexec-$cfg.cfg" \
    | grep -v '^[[:space:]]*$' \
    > "$RESOURCES/autoexec-$cfg.cfg"
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

# Defensive quarantine clear (issue #35). rsync never sets
# com.apple.quarantine, so this is normally a no-op — belt and suspenders
# against anything upstream of this step (Time Machine metadata, a future
# transport that does set it) leaving the fleet copy quarantined.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "[deploy] OK on $(hostname -s)"'
