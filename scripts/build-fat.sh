#!/usr/bin/env bash
# Build a 3-arch universal Quakespasm binary by composing the existing
# per-target builds with `lipo`.
#
# Output: build/quakespasm-fat — a Mach-O universal binary with three
# slices: ppc750 (G3), ppc7400 (G4 + AltiVec), x86_64 (Lion). dyld picks
# the right slice automatically per host CPU subtype, so the same
# Quakespasm.app bundle runs on G3 Panther, G4 Tiger, and Lion Intel.
#
# usage: scripts/build-fat.sh
# pre:   Lion build host reachable; SDKs installed (10.3.9 + 10.4u + Lion default)
# post:  build/quakespasm-{g3,g4,lion,fat} all present; fat is the deliverable
#
# Strategy (per docs/research/fat-binary-feasibility.md §7):
#   1. Run scripts/build.sh g3, g4, lion sequentially. Each takes the
#      build flock individually; we serialise the three sub-builds.
#      Parallel sub-builds would race on Lion's quakespasm/Quake/ tree
#      (`make clean` + `-j2` aliases the .o files), so SERIAL is required.
#   2. lipo -create the three per-target binaries into a single fat.
#      Verified working in fat-binary-feasibility.md §1: zero warnings,
#      ~5 KB padding overhead on top of sum-of-slices.
#
# Why not Apple's single-pass `gcc -arch ppc -arch x86_64 ...`:
#   - Three different SDKs (10.3.9, 10.4u, Lion default); gcc only
#     supports one -isysroot per invocation.
#   - Two different compilers (gcc-4.0 for PPC, clang for x86_64).
#   - __ALTIVEC__ macro must be set for ppc7400 only, not ppc750.
#   See feasibility doc §7 for the full enumeration.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "[build-fat] sub-build 1/3: g3"
scripts/build.sh g3

echo "[build-fat] sub-build 2/3: g4"
scripts/build.sh g4

echo "[build-fat] sub-build 3/3: lion"
scripts/build.sh lion

# All three slices present?
for arch in g3 g4 lion; do
  if [ ! -x "build/quakespasm-$arch" ]; then
    echo "[build-fat] missing build/quakespasm-$arch — sub-build did not produce a binary" >&2
    exit 1
  fi
done

# lipo lives on Lion's build host, not necessarily on the orchestration
# host. Send the three slices over, lipo there, scp the fat back. (lipo
# is also in /usr/bin/ on macOS only — Linux Ubuntu doesn't ship it by
# default. Doing the merge on Lion keeps the toolchain assumption
# uniform with build.sh.)
LION="${BUILD_HOST:-${LION:-mini-intel}}"
echo "[build-fat] lipo -create on $LION (cross-build host)"
scp -q build/quakespasm-g3 build/quakespasm-g4 build/quakespasm-lion \
  "$LION:/tmp/" >/dev/null
ssh "$LION" "cd /tmp && \
  lipo -create quakespasm-g3 quakespasm-g4 quakespasm-lion \
    -output quakespasm-fat && \
  lipo -info quakespasm-fat"
scp -q "$LION:/tmp/quakespasm-fat" build/quakespasm-fat
ssh "$LION" "rm -f /tmp/quakespasm-{g3,g4,lion,fat}" 2>/dev/null || true

echo "[build-fat] sanity:"
file build/quakespasm-fat
echo "[build-fat] OK — build/quakespasm-fat ready"
