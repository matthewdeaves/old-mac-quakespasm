#!/usr/bin/env bash
# Install the host-side tooling (currently qsreboot.sh + qsreboot-setup.sh)
# to ~/bin on all six bench Macs. Idempotent -- re-run after adding a
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
#   default hosts: yosemite yosemite-tiger sawtooth quicksilver mini-g4 mini-intel imac-2019 imac-g5
# env:
#   HOSTS_ENV=...   override host list (line 45 reads HOSTS_ENV, not HOSTS)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/scripts/host-bin"

_PICK="$REPO_ROOT/scripts/pick-bench-host.sh"

# --one-host does the work for a SINGLE machine and is what the loop below runs
# under a claim. It exists because this script drives up to eight machines in one
# invocation, so it cannot re-exec itself under the picker the way the one-target
# scripts do (bench.sh:60). The claim has to be per host, around that host's work
# and nothing else, or installing on eight boxes would hold eight locks for the
# length of the whole run.
if [ "${1:-}" = "--one-host" ]; then
    host="${2:?--one-host needs a host}"
    ssh -o ConnectTimeout=10 "$host" 'mkdir -p ~/bin' || { echo "[$host] ssh failed"; exit 1; }
    for script in qsreboot.sh qsreboot-setup.sh; do
        scp -q "$SRC/$script" "$host:bin/$script"
        ssh "$host" "chmod +x ~/bin/$script"
    done
    echo "[$host] installed: ~/bin/qsreboot.sh ~/bin/qsreboot-setup.sh"
    echo "[$host] next:     ssh $host 'sudo ~/bin/qsreboot-setup.sh'"
    exit 0
fi

HOSTS=("$@")
[ ${#HOSTS[@]} -eq 0 ] && HOSTS=(${HOSTS_ENV:-yosemite yosemite-tiger sawtooth quicksilver mini-g4 mini-intel imac-2019 imac-g5})

# One claim per host, held only while that host is being written to. A machine
# that is busy or unreachable is REPORTED AND SKIPPED, not waited for and not
# worked around: this is idempotent, so re-running it later picks up whatever was
# missed. BENCH_NO_LOCK=1 is for debugging the picker itself, not for getting
# past a machine someone else is using.
for host in "${HOSTS[@]}"; do
    echo "=== $host ==="
    if [ "${BENCH_NO_LOCK:-0}" = 1 ] || [ ! -x "$_PICK" ]; then
        "$0" --one-host "$host" || echo "[$host] failed"
    else
        "$_PICK" --run "$host" "install-host-tools" -- "$0" --one-host "$host" \
            || echo "[$host] skipped: busy, unreachable, or install failed"
    fi
done

echo
echo "Once setup is done on each host:"
echo "  ssh <host> '~/bin/qsreboot.sh'  -- reboots that machine cleanly"
