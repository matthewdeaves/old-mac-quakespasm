#!/usr/bin/env bash
# Install the host-side tooling (currently qsreboot.sh + qsreboot-setup.sh)
# to ~/bin on all four bench Macs. Idempotent -- re-run after adding a
# new machine, or after editing the source scripts in scripts/host-bin/.
#
# After install, run the setup step ONCE per machine to enable
# password-less /sbin/reboot via sudoers:
#
#     ssh <host> 'sudo ~/bin/qsreboot-setup.sh'
#
# Then `ssh <host> '~/bin/qsreboot.sh'` reboots cleanly through the
# kernel even if Finder/display state is borked.
#
# usage: scripts/install-host-tools.sh [host [host...]]
#   default hosts: PowerMacG3 g4 g4mini lion
# env:
#   HOSTS=...   override host list

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/scripts/host-bin"

HOSTS=("$@")
[ ${#HOSTS[@]} -eq 0 ] && HOSTS=(${HOSTS_ENV:-PowerMacG3 g4 g4mini lion})

for host in "${HOSTS[@]}"; do
    echo "=== $host ==="
    # Ensure ~/bin exists.
    ssh -o ConnectTimeout=10 "$host" 'mkdir -p ~/bin' || { echo "[$host] ssh failed"; continue; }
    # Push each script via scp; chmod +x on the remote side.
    for script in qsreboot.sh qsreboot-setup.sh; do
        scp -q "$SRC/$script" "$host:bin/$script"
        ssh "$host" "chmod +x ~/bin/$script"
    done
    echo "[$host] installed: ~/bin/qsreboot.sh ~/bin/qsreboot-setup.sh"
    echo "[$host] next:     ssh $host 'sudo ~/bin/qsreboot-setup.sh'"
done

echo
echo "Once setup is done on each host:"
echo "  ssh <host> '~/bin/qsreboot.sh'  -- reboots that machine cleanly"
