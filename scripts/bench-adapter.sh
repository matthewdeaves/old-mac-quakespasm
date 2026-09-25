#!/usr/bin/env bash
# scripts/bench-adapter.sh -- quakespasm's port adapter for the shared
# bench-evidence contract (build-host#104). Port-owned, like
# dmg-port.conf/dmg-hooks.sh: never synced from old-mac-build-host, never
# edited there. Contract: old-mac-build-host/docs/bench-evidence.md. Sourced
# by scripts/bench-evidence.sh.
#
# Launches the SAME production path smoke-dmg.sh already proves safe on every
# class (dmg-port.conf's PROC/PASS_RE/FAIL_RE/SMOKE_TIMEOUT_*, sourced
# below), not scripts/bench.sh's per-machine autoexec staging +
# -noarchautoexec + vid_width/vid_height stuffcmds. ADR 0007: a live
# fullscreen resolution switch mid-run can hard-crash the G3's Rage 128
# (display LUT wedge) or hard-hang the G5's R300 (full OS death, power-cycle
# only) -- bench.sh's overrides are made safe there only because it stages a
# per-machine overlay ending in vid_lock BEFORE they run. This adapter never
# stages that overlay and never passes -noarchautoexec, so the engine loads
# the CFBundle .app's own per-arch autoexec (Quake/host.c:1019 -- the same
# hook a real player's launch gets) with no stuffcmd video-mode override at
# all: there is nothing for vid_lock to need to catch. +cvarlist is spliced
# in so bench_effective_config has real read-back data.
#
# #68 (build-host#105 pin migration): bench-evidence.sh now runs from
# old-mac-build-host's pinned-revision cache (~/.cache/retro-shared/<sha>/),
# not from this repo's scripts/ next to this file, so its own
# `$SELF_DIR/bench-adapter.sh` default can no longer find this file. Always
# invoke it as:
#   BENCH_ADAPTER="$REPO_ROOT/scripts/bench-adapter.sh" scripts/shared.sh bench-evidence.sh <host> <round> ...
#
# This buys evidence-of-validity, not scripts/bench.sh's finer per-machine
# fps tuning -- different job, see docs/bench-evidence.md.

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/dmg-port.conf
. "$SELF_DIR/dmg-port.conf"

# bench-evidence.sh always resolves "$HOME/$INSTALL_BIN" (old-mac-build-host#107:
# the contract doc allows an absolute path, but the script does not special-case
# a leading '/'). QuakeSpasm installs at $INSTALL_DIR (/Applications/QuakeSpasm,
# root-level, dmg-port.conf), not under any user's $HOME, so this is a
# path-traversal value that resolves correctly rather than a real absolute
# path -- same workaround quake3's pilot adapter already carries (its own
# comment cites the same #107). Verified $HOME is /Users/<name> (2 components)
# on every host this adapter targets, workstation included (deploy-dmg.sh
# installs there too, no ssh). Switch to the plain absolute path once #107 is
# fixed.
INSTALL_BIN='../../Applications/QuakeSpasm/Quakespasm.app/Contents/MacOS/quakespasm'

BENCH_DEMO="${BENCH_DEMO:-$SMOKE_DEMO}"

_sh_host() {
	if [ "$1" = workstation ]; then shift; bash -c "$1"
	else local h="$1"; shift; ssh -o BatchMode=yes -o ConnectTimeout=15 "$h" "$1"; fi
}

bench_launch() {
	local host="$1" round="$2" workdir="$3"
	local class v tmo out rc

	# Same CLASS/timeout lookup as smoke-dmg.sh, run ON the host so a class
	# not in the table above falls back to $SMOKE_TIMEOUT rather than being
	# guessed from the alias.
	class="$(_sh_host "$host" 'case "$(machine 2>/dev/null || uname -m)" in
		ppc750) echo ppc750 ;; ppc7400) echo ppc7400 ;; ppc7450) echo ppc7450 ;;
		ppc970) echo ppc970 ;; arm64*) echo arm64 ;; *) echo x86 ;;
	esac' 2>/dev/null)"
	v="SMOKE_TIMEOUT_$class"
	tmo="${!v:-$SMOKE_TIMEOUT}"

	local remote="set -u
cd '$INSTALL_DIR' || exit 2
if killall -TERM $PROC 2>/dev/null; then sleep 2; fi
killall -KILL $PROC 2>/dev/null || true
sleep 1
[ -f $SMOKE_LOG ] && mv -f $SMOKE_LOG ${SMOKE_LOG}.prev
./Quakespasm.app/Contents/MacOS/quakespasm -nolauncher -basedir . -nosound -condebug +cvarlist +timedemo $BENCH_DEMO > /dev/null 2>&1 &
PID=\$!
j=0
while [ \$j -lt $tmo ]; do
	if [ -f $SMOKE_LOG ] && grep -qE '$PASS_RE|$FAIL_RE' $SMOKE_LOG 2>/dev/null; then break; fi
	sleep 1; j=\$((j+1))
done
killall -TERM $PROC 2>/dev/null
sleep 2
killall -KILL $PROC 2>/dev/null
wait \$PID 2>/dev/null
cat $SMOKE_LOG 2>/dev/null"

	out="$(_sh_host "$host" "$remote" 2>&1)"; rc=$?
	printf '%s\n' "$out" > "$workdir/log.txt"

	local fps
	fps="$(printf '%s\n' "$out" | grep -E 'frames.*seconds.*fps' | tail -1 | awk '{print $5}')"
	[ -n "$fps" ] && printf '%s\n' "$fps" > "$workdir/stats.txt"
	echo fps > "$workdir/stats.unit"

	echo "EXIT=$rc"
	echo "PID="
}

# The launch above blocks until the fps line lands or the timeout elapses,
# then TERM-grace-KILLs the engine itself (ADR 0007: never a bare KILL in
# fullscreen), so nothing is left running for bench-evidence.sh to sample by
# the time bench_launch returns -- same reasoning as quake3's pilot adapter.
bench_liveness() {
	:
}

# Read back from the SAME qconsole.log bench_launch just captured (+cvarlist
# dumps every cvar before +timedemo runs, so this is real state, not the
# requested flags).
bench_effective_config() {
	local host="$1" raw
	raw="$(_sh_host "$host" "cat '$INSTALL_DIR/$SMOKE_LOG' 2>/dev/null" 2>/dev/null)"
	printf '%s\n' "$raw" | grep -F \
		-e 'GL_RENDERER' -e 'GL_VENDOR' \
		-e ' vid_vsync "' -e ' vid_width "' -e ' vid_height "' -e ' vid_bpp "' \
		-e ' vid_fsaa "' -e ' r_shadows "' -e ' r_decals "' \
	| sed -n \
		-e 's/.*GL_RENDERER: */renderer=/p' \
		-e 's/.*GL_VENDOR: */vendor=/p' \
		-e 's/.* vid_vsync "\([^"]*\)".*/vid_vsync=\1/p' \
		-e 's/.* vid_width "\([^"]*\)".*/vid_width=\1/p' \
		-e 's/.* vid_height "\([^"]*\)".*/vid_height=\1/p' \
		-e 's/.* vid_bpp "\([^"]*\)".*/vid_bpp=\1/p' \
		-e 's/.* vid_fsaa "\([^"]*\)".*/vid_fsaa=\1/p' \
		-e 's/.* r_shadows "\([^"]*\)".*/r_shadows=\1/p' \
		-e 's/.* r_decals "\([^"]*\)".*/r_decals=\1/p'
}
