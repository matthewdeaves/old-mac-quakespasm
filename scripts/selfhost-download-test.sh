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
MAP="dltest"
QDIR='~/Desktop/quake'
BIN='./Quakespasm.app/Contents/MacOS/quakespasm'

stage_map () {
  # Extract id1 start.bsp out of PAK0 as a LOOSE maps/dltest.bsp (the server
  # serves loose files only; Host_Download_f fopen()s under com_gamedir).
  ssh "$HOST" "test -f $QDIR/id1/maps/dltest.bsp" && return 0
  echo "[selfhost] staging dltest.bsp on $HOST ..."
  ssh "$HOST" "python2.7 - <<'PY'
from __future__ import print_function
import struct, os
pak = os.path.expanduser('~/Desktop/quake/id1/PAK0.PAK')
outdir = os.path.expanduser('~/Desktop/quake/id1/maps')
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
  ssh "$HOST" "killall -KILL quakespasm 2>/dev/null || true
    sleep 1
    cd $QDIR
    rm -f qconsole.log
    nohup $BIN -dedicated 4 -nolauncher -basedir . -nosound -condebug \
      +allow_download 1 +sv_public 0 +map $MAP >/dev/null 2>&1 &
    sleep 4
    tail -8 qconsole.log 2>/dev/null || true"
  IP=$(ssh "$HOST" "ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null")
  echo
  echo "[selfhost] server up: ${IP}:26000  map '${MAP}'  allow_download 1"
  echo "  On G5 / mini-g4 console:   allow_download 1 ; connect ${IP}:26000"
  ;;
stop)
  ssh "$HOST" "killall -TERM quakespasm 2>/dev/null; sleep 1; killall -KILL quakespasm 2>/dev/null || true"
  echo "[selfhost] stopped"
  ;;
status)
  ssh "$HOST" "cd $QDIR && tail -20 qconsole.log 2>/dev/null || echo '(no qconsole.log)'"
  ;;
*)
  echo "usage: $0 {start|stop|status}" >&2; exit 2 ;;
esac
