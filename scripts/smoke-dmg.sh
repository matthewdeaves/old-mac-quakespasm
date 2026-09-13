#!/usr/bin/env bash
# Smoke-test the DMG-installed copy of the game on a target Mac EXACTLY as a
# human would launch it: the production bundle config (per-arch baseline +
# per-machine overlay, loaded from the .app via CFBundle) drives the renderer —
# fullscreen, the machine's own tuned resolution, full visual tune, vid_lock
# where it applies. We do NOT pass -noarchautoexec and do NOT override vid/res
# (that is what bench.sh does for deterministic measurement). The only things we
# add are -condebug (so the engine writes qconsole.log) and a +timedemo so the
# run AUTO-EXITS instead of sitting fullscreen forever — proof the world
# actually rendered (an fps line) on the real production path, at the resolution
# the production config selected.
#
# This is the gate the Q2 corrupt-DMG bug slipped past: deploy+bench was clean,
# but the human DMG-launch path crashed instantly. So we test the as-installed,
# as-launched artifact. See MISTAKES.md.
#
# usage: scripts/smoke-dmg.sh <machine> [demo]
#   machine: yosemite | yosemite-tiger | sawtooth | quicksilver | mini-g4 | imac-g5 |
#            mini-intel | imac-2019 | workstation (this Mac, local — no ssh
#            alias for it by design; old-mac-quakespasm#51)
#   demo:    demo1 (default) | demo2 | demo3
#
# After this passes, the human starts a NEW GAME by hand — the timedemo proves
# world render + correct res but NOT the live in-game path (an in-game vid
# change on the G3/G5, or an entity-spawn class of crash, only shows there).

set -euo pipefail
HOST="${1:?usage: $0 <machine> [demo]}"

# The playable install belongs here (buildhost#73).  Keep this an exact,
# space-free contract: ssh joins remote-command arguments before the remote
# shell parses them, so accepting arbitrary paths would permit argument
# injection. Validate before the picker can claim or contact a host.
INSTALL_DIR="${SMOKE_INSTALL_DIR:-/Applications/QuakeSpasm}"
case "$INSTALL_DIR" in
  /Applications/QuakeSpasm) ;;
  *)
    echo "smoke-dmg: SMOKE_INSTALL_DIR must be /Applications/QuakeSpasm" >&2
    exit 2
    ;;
esac

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
	exec "$_PICK" --run "$HOST" "smoke-dmg" -- "$0" "$@"
fi
DEMO="${2:-demo1}"

# workstation is this Mac -- no ssh alias for it exists (nor should one;
# pick-bench-host.sh already treats it as local-only via LOCAL_ALIASES).
# old-mac-quakespasm#51.
IS_LOCAL=false
[ "$HOST" = workstation ] && IS_LOCAL=true

# LAUNCH_MODE picks how this host gets tested. "open" uses
# `open -W -a APP --args ...`, the real LaunchServices path (LSOpenApplication)
# -- same call a Finder double-click makes, so it exercises code-signature
# validation, Gatekeeper quarantine and App Translocation, none of which a
# direct exec ever touched (issue #35). "exec" falls back to the old direct
# binary exec. Not a downgrade for every PowerPC/pre-Gatekeeper target: `open`
# itself didn't grow -W until Leopard and didn't grow --args until Snow
# Leopard -- measured directly on this fleet, Panther's and Tiger's `open`
# treat `-W` as a FILENAME ("No such file: .../-W"), Leopard's has -W but no
# --args. None of Panther/Tiger/Leopard have Gatekeeper at all (it postdates
# all three), so a direct exec already exercises everything that OS can do to
# a launch; "open" mode here would just be a syntax error, not a stronger
# test.
case "$HOST" in
  yosemite)    TIMEOUT=240; COOLDOWN=5; LAUNCH_MODE=exec ;;
  # Same PowerMac1,1 as yosemite, booted from its Tiger partition.
  yosemite-tiger) TIMEOUT=240; COOLDOWN=5; LAUNCH_MODE=exec ;;
  sawtooth)    TIMEOUT=180; COOLDOWN=3; LAUNCH_MODE=exec ;;
  quicksilver) TIMEOUT=120; COOLDOWN=2; LAUNCH_MODE=exec ;;
  mini-g4)     TIMEOUT=120; COOLDOWN=2; LAUNCH_MODE=exec ;;
  imac-g5)     TIMEOUT=110; COOLDOWN=2; LAUNCH_MODE=exec ;;
  mini-intel)  TIMEOUT=60;  COOLDOWN=1; LAUNCH_MODE=open ;;
  imac-2019)   TIMEOUT=45;  COOLDOWN=1; LAUNCH_MODE=open ;;
  g5-desktop|g5-tiger|g5-panther|quad-leopard|quad-tiger)
               TIMEOUT=120; COOLDOWN=2; LAUNCH_MODE=exec ;;
  mini-intel2) TIMEOUT=60;  COOLDOWN=1; LAUNCH_MODE=open ;;
  mini-sl)     TIMEOUT=60;  COOLDOWN=1; LAUNCH_MODE=open ;;
  # Apple Silicon, modern macOS -- same LAUNCH_MODE as the other Gatekeeper-
  # era hosts (mini-intel/imac-2019/mini-sl), timeout in line with imac-2019.
  workstation) TIMEOUT=45;  COOLDOWN=1; LAUNCH_MODE=open ;;
  *) echo "unknown machine: $HOST" >&2; exit 2 ;;
esac

# Both are overridable. The per-machine defaults are tuned for this port's
# demo at that machine's production settings, and a heavier config or a busy
# box can exceed them. When that happens the run is reported as a crash or
# hang, which is far more alarming than the truth, and it leaves the engine
# running for the NEXT run to trip over.
TIMEOUT="${SMOKE_TIMEOUT:-$TIMEOUT}"
COOLDOWN="${SMOKE_COOLDOWN:-$COOLDOWN}"

# Report whether a real console user is logged in during this run --
# old-mac-quakespasm#45's original failure (2026-09-04) was specifically a
# TCC SystemPolicyAllFiles denial with NOBODY logged in to answer the
# one-time consent prompt. Moving the install off ~/Desktop and onto
# /Applications (this ticket) sidesteps that particular TCC gate, and every
# smoke run since has PASSED -- but every one of those runs also happened
# to have a console user logged in, which is a materially easier case than
# the original bug. This line makes that distinction visible in the run's
# own output instead of a silent, easily-misread PASS: a PASS here with
# CONSOLE_USER=none is real evidence #45 is fixed; a PASS with a user
# logged in is evidence the /Applications move helps, not proof of the
# no-login case.
if $IS_LOCAL; then
  CONSOLE_USER=$(stat -f '%Su' /dev/console 2>/dev/null || echo none)
else
  CONSOLE_USER=$(ssh "$HOST" "stat -f '%Su' /dev/console 2>/dev/null || echo none")
fi
echo "[smoke $HOST] console user: ${CONSOLE_USER:-none} (see old-mac-quakespasm#45 — a PASS with no console user is the strong form of this test)"

echo "[smoke $HOST] launching DMG-installed Quakespasm.app via LaunchServices (as a human's double-click would), demo=$DEMO"
# Production launch, via `open`, not a direct binary exec — issue #35. A
# direct exec (the old form of this script) never goes through LaunchServices,
# so it never exercised code-signature validation, Gatekeeper quarantine, or
# App Translocation, and none of those passed a real double-click reliably
# even when this script did. `open -W -a APP --args ...` is the CLI
# equivalent of a Finder double-click: same LaunchServices call
# (LSOpenApplication), same code-signature check, same translocation if the
# bundle is quarantined. -W waits for it to quit, matching the old script's
# own wait loop below (belt and suspenders — the loop still bounds it).
#
# -basedir . (so id1/ + quakespasm.pak resolve) + -condebug (qconsole.log) +
# a single +timedemo so it self-terminates, forwarded through --args exactly
# as they'd reach argv from a direct exec. NO -noarchautoexec and NO vid/res
# override — the CFBundle per-arch + per-machine autoexec drives the
# renderer. -nosound matches bench.sh: it keeps SIGTERM clean (CoreAudio
# threads can ignore TERM) and is orthogonal to the config/render path the
# corrupt-binary crash lived on. TERM-before-KILL always: a hard KILL leaves the
# Rage 128 (G3) display LUT wedged and hard-hangs the R300 (Leopard G5).
# Built as a heredoc with a QUOTED delimiter ('REMOTE_EOF'), not the
# double-quoted-string-with-backslash-escapes form this script used to use --
# that form needs every remote-side $var and every literal backslash escaped
# an extra time for each layer, and got it wrong twice already today (a
# stray backtick, then this same LAUNCH_MODE branch). A quoted heredoc sends
# its body byte-for-byte with NO local expansion at all, so remote-side `$`
# and `\` are written exactly as they should run; only DEMO/TIMEOUT/
# LAUNCH_MODE cross the local/remote boundary, as explicit positional args.
if $IS_LOCAL; then
  RUNNER=(bash -s)
else
  RUNNER=(ssh "$HOST" bash -s)
fi
"${RUNNER[@]}" "$DEMO" "$TIMEOUT" "$COOLDOWN" "$LAUNCH_MODE" "$INSTALL_DIR" <<'REMOTE_EOF'
set -u
DEMO="$1"; TIMEOUT="$2"; COOLDOWN="$3"; LAUNCH_MODE="$4"; INSTALL_DIR="$5"

if killall -TERM quakespasm 2>/dev/null; then sleep 2; fi
killall -KILL quakespasm 2>/dev/null || true
sleep 1
cd "$INSTALL_DIR" || { echo 'NO_INSTALL'; exit 9; }
[ -f qconsole.log ] && mv -f qconsole.log qconsole.prev.log

if [ "$LAUNCH_MODE" = open ]; then
  open -W -a "$PWD/Quakespasm.app" --args -nolauncher -basedir . -nosound -condebug \
    +timedemo "$DEMO" > /dev/null 2>&1 &
else
  # Pre-Snow-Leopard `open` has neither -W nor --args (measured on this fleet:
  # Panther and Tiger take -W as a literal filename, Leopard has -W but not
  # --args) and none of the three have Gatekeeper to exercise anyway, so a
  # direct exec is not a weaker test here, just the only one `open` supports.
  ./Quakespasm.app/Contents/MacOS/quakespasm -nolauncher -basedir . -nosound -condebug \
    +timedemo "$DEMO" > /dev/null 2>&1 &
fi
PID=$!
j=0
while [ "$j" -lt "$TIMEOUT" ]; do
  if [ -f qconsole.log ] && \
     grep -q 'frames.*seconds.*fps\|Quake Error' qconsole.log 2>/dev/null; then break; fi
  # bail early if open/the binary itself returned (app quit or refused)
  if ! kill -0 "$PID" 2>/dev/null; then break; fi
  sleep 1; j=$((j+1))
done
killall -TERM quakespasm 2>/dev/null
sleep 2
killall -KILL quakespasm 2>/dev/null || true
wait "$PID" 2>/dev/null
sleep "$COOLDOWN"
true
REMOTE_EOF

# Pull the log and report.
TMP=$(mktemp)
if $IS_LOCAL; then
  cp "$INSTALL_DIR/qconsole.log" "$TMP" 2>/dev/null || { echo "[smoke $HOST] FAIL: no qconsole.log (engine never wrote one — no install or instant crash)"; rm -f "$TMP"; exit 1; }
else
  scp -q "$HOST:$INSTALL_DIR/qconsole.log" "$TMP" 2>/dev/null || { echo "[smoke $HOST] FAIL: no qconsole.log (engine never wrote one — no install or instant crash)"; rm -f "$TMP"; exit 1; }
fi

FPS_LINE=$(grep -E 'frames.*seconds.*fps' "$TMP" 2>/dev/null | tail -1 || true)
MODE_LINE=$(grep -E 'Video mode' "$TMP" 2>/dev/null | tail -1 || true)
REND_LINE=$(grep -E 'GL_RENDERER' "$TMP" 2>/dev/null | tail -1 || true)
ERR_LINE=$(grep -E 'Quake Error|EXC_|illegal' "$TMP" 2>/dev/null | tail -1 || true)
rm -f "$TMP"

echo "[smoke $HOST] renderer : ${REND_LINE:-<none>}"
echo "[smoke $HOST] mode     : ${MODE_LINE:-<none>}"
echo "[smoke $HOST] result   : ${FPS_LINE:-<NO FPS LINE>}"
[ -n "$ERR_LINE" ] && echo "[smoke $HOST] error    : $ERR_LINE"

if [ -n "$FPS_LINE" ]; then
  echo "[smoke $HOST] PASS — world rendered to completion on the production path"
  exit 0
else
  echo "[smoke $HOST] FAIL — no fps line; the production launch did not render a demo (crash or hang)" >&2
  exit 1
fi
