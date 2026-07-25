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
# Output is silenced; if both tiers fail the script exits non-zero.
#
# Deployed to ~/bin/qsreboot.sh on every bench Mac (including a second OS
# partition such as yosemite-tiger) via scripts/install-host-tools.sh. Used by
# the orchestration host to recover machines remotely without a keyboard.

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
