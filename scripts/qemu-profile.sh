#!/usr/bin/env bash
# qemu-profile.sh - profile the QemuMac VM (the `qemu-tiger3d` bench target)
# while a game runs in it, to see where the emulator spends its time.
#
# usage: scripts/qemu-profile.sh <game-process> [seconds] [out.txt]
#
#   Waits for <game-process> (quakespasm, quake2, ioquake3-bench) to start in
#   the guest, lets it load for $PROFILE_DELAY seconds (default 8), then runs
#   macOS `sample` on QEMU for [seconds] (default 10) and prints where the
#   guest CPU thread and the main thread spend their samples.
#   Start a bench alongside it, e.g.
#     scripts/qemu-profile.sh quakespasm & scripts/bench.sh qemu-tiger3d demo1 1024x768 1
#
# Read it as shares, not absolute cost:
#   vCPU "self" is emulated guest work plus the device models the guest
#   calls into (the Radeon's ring, vertex and draw work runs here, BQL held);
#   main-thread time in __psynch_mutexwait is the UI and audio waiting for it.
#
# env: QEMUMAC_VM (default power_mac_g4_tiger_3d), VM_HOST (default qemu-tiger3d)
set -euo pipefail

GAME="${1:?usage: $0 <game-process> [seconds] [out.txt]}"
SECS="${2:-10}"
OUT="${3:-${TMPDIR:-/tmp}/qemu-profile-$GAME.txt}"
QEMUMAC_VM="${QEMUMAC_VM:-power_mac_g4_tiger_3d}"
VM_HOST="${VM_HOST:-qemu-tiger3d}"

pid=$(pgrep -f "qemu-system-ppc.*$QEMUMAC_VM" | head -1) \
    || { echo "qemu-profile: the VM is not running" >&2; exit 1; }

started=false
for _ in $(seq 1 300); do
    if ssh -o ConnectTimeout=5 -o BatchMode=yes "$VM_HOST" "killall -0 $GAME" 2>/dev/null; then
        started=true
        break
    fi
    sleep 1
done
$started || { echo "qemu-profile: no $GAME process in the guest after 5 minutes" >&2; exit 1; }
sleep "${PROFILE_DELAY:-8}"
sample "$pid" "$SECS" -file "$OUT" >/dev/null 2>&1

python3 - "$OUT" <<'PY'
import re, sys, collections

text = open(sys.argv[1]).read().split('\n')
line_re = re.compile(r'^(\s*[+!:| ]*)(\d+) (.+?)(?:\s+\(in [^)]*\))?'
                     r'(?:\s+\+ [\d,.]+)?\s*(?:\[0x[0-9a-f,.]+\])?(?:\s+[\w./-]+:\d+)?\s*$')

def thread(marker):
    """Self and inclusive sample counts for the call tree of one thread."""
    try:
        start = next(i for i, l in enumerate(text) if marker in l)
    except StopIteration:
        return None
    nodes = []
    for l in text[start + 1:]:
        if re.match(r'^    \d+ Thread_', l) or not l.strip():
            break
        m = line_re.match(l)
        if m:
            nodes.append((len(m.group(1)), int(m.group(2)),
                          re.sub(r'\s+\+ .*', '', m.group(3).strip())))
    own, incl = collections.Counter(), collections.Counter()
    for i, (d, c, n) in enumerate(nodes):
        kids, cd = 0, None
        for dj, cj, _ in nodes[i + 1:]:
            if dj <= d:
                break
            cd = dj if cd is None else cd
            if dj == cd:
                kids += cj
        own[n] += c - kids
        incl[n] = max(incl[n], c)
    return (nodes[0][1] if nodes else 0), own, incl

for title, marker, n in (("guest CPU (vCPU thread)", "ALL CPUs/TCG", 25),
                         ("main thread", "DispatchQueue_1:", 8)):
    t = thread(marker)
    if not t or not t[0]:
        continue
    total, own, incl = t
    print(f"== {title}: {total} samples, top self")
    for name, c in own.most_common(n):
        print(f"{100 * c / total:5.1f}%  {name}")
    if marker == "ALL CPUs/TCG":
        print(f"== {title}: Radeon and TCG helpers, inclusive")
        dev = [(nm, c) for nm, c in incl.most_common(400)
               if re.search(r'ppc_mac_gpu|r300|metal|r200|pvs|draw|flush', nm)]
        for name, c in dev[:20]:
            print(f"{100 * c / total:5.1f}%  {name}")
PY
echo "(full profile: $OUT)"
