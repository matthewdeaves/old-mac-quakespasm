#!/bin/bash
# One-time setup. Adds a NOPASSWD sudoers entry so qsreboot.sh tier 1
# (direct /sbin/reboot) works without password. Run once per machine.
#
# Usage:
#     sudo ~/bin/qsreboot-setup.sh
#   OR
#     ~/bin/qsreboot-setup.sh   (will prompt for password 2-3 times)

set -e

# When invoked via sudo, $(whoami) is root -- use $SUDO_USER instead.
TARGET_USER="${SUDO_USER:-$(whoami)}"
SUDOERS_LINE="$TARGET_USER ALL=(ALL) NOPASSWD: /sbin/reboot, /sbin/shutdown, /sbin/halt"
BACKUP=/etc/sudoers.bak.$(date +%s)

# Already installed? (look for existing NOPASSWD reboot entry for this user)
if sudo grep -qE "^$TARGET_USER\s+.*NOPASSWD:.*\b(reboot|shutdown|halt)\b" /etc/sudoers 2>/dev/null; then
    echo "[qsreboot-setup] entry for $TARGET_USER already present in /etc/sudoers"
    echo "[qsreboot-setup] testing tier 1..."
    if sudo -n -u root -i true 2>/dev/null || sudo -n /sbin/reboot --help >/dev/null 2>&1; then
        echo "[qsreboot-setup] OK -- tier 1 works"
    else
        echo "[qsreboot-setup] entry present but `sudo -n` still prompts; may need re-login"
    fi
    exit 0
fi

echo "[qsreboot-setup] target user: $TARGET_USER"
echo "[qsreboot-setup] adding to /etc/sudoers (backup: $BACKUP):"
echo "    $SUDOERS_LINE"
sudo cp /etc/sudoers "$BACKUP"
echo "$SUDOERS_LINE" | sudo tee -a /etc/sudoers >/dev/null

# Verify with visudo -c (Panther sudo 1.6 supports -c).
if ! sudo visudo -c -f /etc/sudoers >/dev/null 2>&1; then
    echo "[qsreboot-setup] FAILED -- /etc/sudoers syntax broken; restoring backup"
    sudo cp "$BACKUP" /etc/sudoers
    exit 1
fi

echo "[qsreboot-setup] OK -- written and validated."
echo "[qsreboot-setup] test from your orchestration host:"
# $(hostname -s) is this Mac's OWN OS-reported name, not the ssh alias the
# orchestration host uses to reach it (that mapping only exists in the
# orchestration host's own ~/.ssh/config) -- printing it produced a garbled,
# wrong suggestion on at least one machine. Generic placeholder instead of a
# guess that can be wrong.
echo "    ssh <this-host's-alias> '~/bin/qsreboot.sh'"
