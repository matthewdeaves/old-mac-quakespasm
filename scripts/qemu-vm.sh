#!/usr/bin/env bash
# qemu-vm.sh - start, stop or check the QemuMac Tiger 3D VM, the `qemu-tiger3d`
# bench target: an emulated PowerMac G4 with an emulated ATI Radeon 9700 PRO
# (QemuMac's DISPLAY_GPU="radeon9700"), Mac OS X 10.4.
#
# usage: scripts/qemu-vm.sh up|down|status
#
#   up      boot the VM through QemuMac's run-mac.sh and wait until the Finder
#           is running (a logged-in desktop, which Quake needs for its window)
#   down    shut the guest down over SSH and wait for QEMU to exit
#   status  say whether it is running and whether the desktop answers
#
# env: QEMUMAC_DIR   QemuMac checkout (default ~/Documents/QemuMac)
#      QEMUMAC_VM    VM config name  (default power_mac_g4_tiger_3d)
#      VM_HOST       SSH alias       (default qemu-tiger3d, the bench target name)
#
# One-time setup, all outside this repo:
#   - QemuMac with the Radeon QEMU build (./install-deps.sh, the Radeon choice)
#     and the VM installed; its config sets SSH_PORT=2222.
#   - In the guest: Sharing > Remote Login on, auto-login, a key in
#     ~/.ssh/authorized_keys, and QuakeSpasm at /Applications/QuakeSpasm.
#   - A `Host qemu-tiger3d` block in ~/.ssh/config (127.0.0.1 port 2222; the
#     bench target name is the alias). Tiger's
#     OpenSSH needs `HostKeyAlgorithms +ssh-rsa`, `PubkeyAcceptedAlgorithms
#     +ssh-rsa` and the SHA-1 key exchanges re-enabled.
#
# QEMU is started in its own session (setsid), so it is not a child of this
# shell or of a harness that runs it: ending those does not take the VM down.
set -euo pipefail

QEMUMAC_DIR="${QEMUMAC_DIR:-$HOME/Documents/QemuMac}"
QEMUMAC_VM="${QEMUMAC_VM:-power_mac_g4_tiger_3d}"
VM_HOST="${VM_HOST:-qemu-tiger3d}"
CONF="vms/$QEMUMAC_VM/$QEMUMAC_VM.conf"
LOG="${TMPDIR:-/tmp}/qemu-vm-$QEMUMAC_VM.log"

running() { pgrep -f "qemu-system-ppc.*$QEMUMAC_VM" >/dev/null; }
desktop() { ssh -o ConnectTimeout=5 -o BatchMode=yes "$VM_HOST" 'ps -axc | grep -q Finder' 2>/dev/null; }

case "${1:-}" in
  up)
    [ -f "$QEMUMAC_DIR/$CONF" ] || { echo "qemu-vm: no $CONF in $QEMUMAC_DIR" >&2; exit 2; }
    pid=""
    if ! running; then
      # run-mac.sh execs QEMU, so this pid is QEMU's once it is past preflight
      cd "$QEMUMAC_DIR"
      python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
        ./run-mac.sh --config "$CONF" </dev/null >"$LOG" 2>&1 &
      pid=$!
      cd - >/dev/null
    fi
    for _ in $(seq 1 120); do
      if desktop; then echo "qemu-vm: $VM_HOST up"; exit 0; fi
      if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
        echo "qemu-vm: QEMU exited; see $LOG" >&2; tail -5 "$LOG" >&2; exit 1
      fi
      sleep 5
    done
    echo "qemu-vm: no desktop after 10 minutes; see $LOG" >&2
    exit 1 ;;
  down)
    running || { echo "qemu-vm: not running"; exit 0; }
    for _ in $(seq 1 60); do
      # asked again each pass: a guest still booting has no sshd yet
      ssh -o ConnectTimeout=5 -o BatchMode=yes "$VM_HOST" 'sudo shutdown -h now' >/dev/null 2>&1 || true
      running || { echo "qemu-vm: $VM_HOST down"; exit 0; }
      sleep 3
    done
    echo "qemu-vm: still running after 3 minutes" >&2
    exit 1 ;;
  status)
    if ! running; then echo "stopped"
    elif desktop; then echo "running, desktop up"
    else echo "running, desktop not answering"; fi ;;
  *)
    echo "usage: $0 up|down|status" >&2
    exit 2 ;;
esac
