#!/bin/bash
# Reboot this Mac via the most reliable mechanism available.
#
# Tier 1: `sudo /sbin/reboot` -- direct kernel reboot, works even if
# Finder is wedged or the display LUT is corrupt (e.g. after a Quake
# fullscreen-kill leaves Panther's Rage 128 driver in a bad state).
# Requires a NOPASSWD sudoers entry for /sbin/reboot -- run
# qsreboot-setup.sh once per machine to install.
#
# Tier 2: Finder Apple Event -- standard Apple-menu Restart route. Works
# in normal conditions but can hang if Finder itself is unresponsive.
#
# --force: `sudo /sbin/reboot -q` -- quick reboot, skips the graceful
# process-teardown phase (still syncs disks). Plain /sbin/reboot waits to
# kill every process, and a process wedged UNKILLABLY inside a GPU kernel
# driver blocks that forever: measured on mini-sl 2026-08-23, where a
# GeForce 9400 FIFO wedge (issue #30) left WindowServer stuck in the
# driver and tier 1 hung mid-shutdown for ~2.5 hours until a power reset.
# The filesystem journal makes the skipped teardown survivable; a wedged
# GPU makes it necessary. Escalation pattern from the orchestrator:
#   ssh host '~/bin/qsreboot.sh'            # graceful first
#   sleep 60; ssh host true && ssh host '~/bin/qsreboot.sh --force'
# The existing sudoers entry (bare /sbin/reboot path, no arg list)
# already permits -q; no re-run of qsreboot-setup.sh is needed.
#
# Output is silenced; if all tiers fail the script exits non-zero.
#
# Deployed to ~/bin/qsreboot.sh on every bench Mac (including a second OS
# partition such as yosemite-tiger) via scripts/install-host-tools.sh. Used by
# the orchestration host to recover machines remotely without a keyboard.

if [ "${1:-}" = "--force" ]; then
    if sudo -n /sbin/reboot -q >/dev/null 2>&1; then
        exit 0
    fi
    # Old sudo (1.6.x, Panther/Tiger) rejects -n outright -- retry without.
    if sudo /sbin/reboot -q >/dev/null 2>&1 </dev/null; then
        exit 0
    fi
    echo "qsreboot.sh: --force failed (no NOPASSWD sudoers entry?)" >&2
    exit 1
fi

if sudo -n /sbin/reboot >/dev/null 2>&1; then
    exit 0
fi
# Tiger's and Panther's sudo (1.6.x) have no -n flag -- they reject the option
# outright, so tier 1 above can never fire there even with the NOPASSWD entry
# installed. Retry without -n: with NOPASSWD in /etc/sudoers this still cannot
# prompt, and stdin is closed so a missing entry fails fast instead of hanging
# on a password prompt.
if sudo /sbin/reboot >/dev/null 2>&1 </dev/null; then
    exit 0
fi
if osascript -e 'tell application "Finder" to restart' >/dev/null 2>&1; then
    exit 0
fi
echo "qsreboot.sh: both tiers failed (no NOPASSWD sudoers entry; Finder unresponsive)" >&2
exit 1
