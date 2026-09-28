#!/usr/bin/env bash
# Self-host download test for the DP-style in-protocol downloader.
#
# Runs our own fat binary as a HEADLESS dedicated server on mini-intel,
# hosting a custom map (dltest.bsp = a renamed id1 start.bsp) that the PPC
# clients do NOT have, with allow_download on. Connecting from the G5 / mini-g4
# (with `allow_download 1`) then exercises the full "missing map -> in-protocol
# UDP download -> spawn -> play" loop with OUR code on both ends -- the
# deterministic test the public servers can't give us (they're all on id1 maps).
#
# usage:
#   scripts/selfhost-download-test.sh start   # (re)launch the dedicated server
#   scripts/selfhost-download-test.sh stop    # kill it
#   scripts/selfhost-download-test.sh status  # show server console tail
#
# Then on the G5 / mini-g4 in-game console:
#   allow_download 1
#   connect <mini-intel-LAN-IP>:26000
# It should print "Downloaded: maps/dltest.bsp" and drop you into the map.
# A second client can connect the same way to test coop download + play.

set -euo pipefail

HOST="${SELFHOST_HOST:-mini-intel}"

# Claim the machine for the whole run. Same re-exec as bench.sh; see
# scripts/pick-bench-host.sh.
#
# This one matters more than most: it starts and stops a game on $HOST.
# Unclaimed, that races whatever the lock holder is running -- another repo's
# timedemo mid-flight, with no error on either side. The lock is the only
# thing arbitrating this hardware. The game itself goes through launch-game.sh
# (build-host#147), which refuses while any game is already running.
#
# `start` must run INSIDE a claim the caller holds for the server's whole life:
# releasing a claim TERMs any game still running on the host (pick-bench-host
# #38), so a `start` under its own `--run` has its server killed the moment it
# returns, and every client gets "CL_Connect: connect failed" (found on #58).
# So `start` refuses unless the caller already holds $HOST:
#   scripts/shared.sh pick-bench-host.sh --run mini-intel -- bash -c \
#     'scripts/selfhost-download-test.sh start; <client test>; scripts/selfhost-download-test.sh stop'
_PICK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/shared.sh"
if [ "${1:-start}" = start ] && [ "${RETRO_BENCH_LOCK:-}" != "$HOST" ] && [ "${BENCH_NO_LOCK:-0}" != 1 ]; then
	echo "selfhost: run 'start' inside your own claim on $HOST (see the comment above); refusing" >&2
	exit 2
fi
if [ "${RETRO_BENCH_LOCK:-}" != "$HOST" ] && [ "${BENCH_NO_LOCK:-0}" != 1 ] && [ -x "$_PICK" ]; then
	export RETRO_BENCH_LOCK="$HOST"
	exec "$_PICK" pick-bench-host.sh --run "$HOST" "selfhost" -- "$0" "$@"
fi

MAP="dltest"
# The server host's one game folder (#55): the same install deploy.sh and
# deploy-dmg.sh write. `stop` removes the staged test map again, so
# /Applications keeps only the build and the game data.
QDIR='/Applications/QuakeSpasm'
BIN='./Quakespasm.app/Contents/MacOS/quakespasm'

stage_map () {
  # Extract id1 start.bsp out of PAK0 as a LOOSE maps/dltest.bsp (the server
  # serves loose files only; Host_Download_f fopen()s under com_gamedir).
  ssh "$HOST" "test -f $QDIR/id1/maps/dltest.bsp" && return 0
  echo "[selfhost] staging dltest.bsp on $HOST ..."
  ssh "$HOST" "python2.7 - <<'PY'
from __future__ import print_function
import struct, os
pak = '/Applications/QuakeSpasm/id1/PAK0.PAK'
outdir = '/Applications/QuakeSpasm/id1/maps'
out = os.path.join(outdir, 'dltest.bsp')
f = open(pak, 'rb')
magic, dirofs, dirlen = struct.unpack('<4sii', f.read(12))
f.seek(dirofs)
for i in range(dirlen // 64):
    e = f.read(64)
    name = e[:56].split('\x00')[0]
    pos, length = struct.unpack('<ii', e[56:64])
    if name == 'maps/start.bsp':
        f.seek(pos); data = f.read(length)
        if not os.path.isdir(outdir): os.makedirs(outdir)
        open(out, 'wb').write(data)
        print('staged %s (%d bytes)' % (out, length))
        break
f.close()
PY"
}

case "${1:-start}" in
start)
  stage_map
  echo "[selfhost] launching dedicated server on $HOST ..."
  # build-host#147: the server starts through the shared launch guard, which
  # refuses if ANY game already runs on $HOST (whoever started it) and arms a
  # guest watchdog, so there is no killall of a stale engine here. The claim
  # is what arbitrates the hardware; a stale quakespasm is reported, not
  # killed. The pid is kept on the host for `stop` (a separate invocation).
  # Never KILL: ADR 0007:120, a hard KILL of a fullscreen engine wedges the
  # Rage 128 and hangs the R300 (recovery is a reboot).
  ssh "$HOST" "cd $QDIR && { [ -f qconsole.log ] && mv -f qconsole.log qconsole.prev.log; true; }"
  GPID="$("$_PICK" launch-game.sh "$HOST" quakespasm --max-secs 3600 -- \
    sh -c "cd $QDIR && exec $BIN -dedicated 4 -nolauncher -basedir . -nosound -condebug +developer 1 +allow_download 1 +sv_public 0 +map $MAP" \
    | awk '/^PID/ {print $2}')" || true
  [ -n "$GPID" ] || { echo "[selfhost] launch refused or failed on $HOST" >&2; exit 1; }
  ssh "$HOST" "echo $GPID > /tmp/qs-selfhost.pid
    sleep 4
    cd $QDIR && tail -8 qconsole.log 2>/dev/null || true"
  IP=$(ssh "$HOST" "ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null")
  echo
  echo "[selfhost] server up: ${IP}:26000  map '${MAP}'  allow_download 1"
  echo "  On G5 / mini-g4 console:   allow_download 1 ; connect ${IP}:26000"
  ;;
stop)
  GPID="$(ssh "$HOST" 'cat /tmp/qs-selfhost.pid 2>/dev/null' || true)"
  if [ -n "$GPID" ]; then
    "$_PICK" launch-game.sh --stop "$HOST" "$GPID" >&2 || echo "[selfhost] server pid $GPID survived TERM; quit it by hand" >&2
    ssh "$HOST" 'rm -f /tmp/qs-selfhost.pid'
  fi
  ssh "$HOST" "rm -f $QDIR/id1/maps/$MAP.bsp; rmdir $QDIR/id1/maps 2>/dev/null || true"
  echo "[selfhost] stopped, test map removed"
  ;;
status)
  ssh "$HOST" "cd $QDIR && tail -20 qconsole.log 2>/dev/null || echo '(no qconsole.log)'"
  ;;
*)
  echo "usage: $0 {start|stop|status}" >&2; exit 2 ;;
esac
