#!/usr/bin/env bash
# Build a 4-arch universal Quakespasm binary by composing the existing
# per-target builds with `lipo`.
#
# Output: build/quakespasm-fat — a Mach-O universal binary with four
# slices: ppc750 (G3), ppc7400 (G4 + AltiVec), ppc970 (iMac G5, Leopard),
# x86_64 (Lion). dyld picks the right slice automatically per host CPU
# subtype, so the same Quakespasm.app bundle runs on G3 Panther, G4 Tiger,
# G5 Leopard, and Lion Intel.
#
# usage: scripts/build-fat.sh
# pre:   build host reachable; SDKs installed (10.3.9 + 10.4u + 10.5 + Lion default)
# post:  build/quakespasm-{g3,g4,g5,lion,fat} all present; fat is the deliverable
#
# Strategy (per docs/research/fat-binary-feasibility.md §7):
#   1. Run scripts/build.sh g3, g4, g5, lion sequentially. Each takes the
#      build flock individually; we serialise the sub-builds.
#      Parallel sub-builds would race on the build host's quakespasm/Quake/
#      tree (`make clean` + `-j2` aliases the .o files), so SERIAL is required.
#   2. lipo -create the four per-target binaries into a single fat.
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

# Resolve the port release label ONCE here and export it so all four sub-builds
# stamp the identical version into their slice (build.sh would otherwise call
# git describe per-slice — same value in practice, but pinning it is correct and
# documents intent). git describe gives "v1.9" on a tagged build, else a
# descriptive off-tag string. Overridable via the environment.
export QS_PORT_VERSION="${QS_PORT_VERSION:-$(git -C "$REPO_ROOT" describe --tags --always --dirty 2>/dev/null || echo unknown)}"
echo "[build-fat] stamping port version: $QS_PORT_VERSION"

# Pin ONE Intel build host for the whole fat build and claim it up front.
# This MUST be a single host for the entire run: the four slices accumulate in
# that host's quakespasm/Quake/ tree and the final lipo happens there, so letting
# individual sub-builds drift onto different minis would lipo an incomplete set.
# Claiming once also stops another repo/agent taking the box between sub-builds.
# An explicit BUILD_HOST (or LION) from the caller always wins.
if [ -z "${BUILD_HOST:-}" ] && [ -z "${LION:-}" ]; then
	BUILD_HOST="$(BUILD_LOCK_WAIT="${BUILD_LOCK_WAIT:-900}" \
		"$REPO_ROOT/scripts/pick-build-host.sh" --acquire "quakespasm build-fat")" || {
		echo "[build-fat] no free Intel build host; see scripts/pick-build-host.sh --status" >&2
		exit 1
	}
	export BUILD_HOST
	# Absolute path: the trap must still resolve if anything ever cd's away.
	trap '"$REPO_ROOT/scripts/pick-build-host.sh" --release "$BUILD_HOST" >/dev/null 2>&1; true' EXIT
	echo "[build-fat] claimed build host: $BUILD_HOST (held for all four slices)"
else
	export BUILD_HOST="${BUILD_HOST:-$LION}"
	echo "[build-fat] using caller-supplied build host: $BUILD_HOST"
fi

echo "[build-fat] sub-build 1/4: g3"
scripts/build.sh g3

echo "[build-fat] sub-build 2/4: g4"
scripts/build.sh g4

echo "[build-fat] sub-build 3/4: g5"
scripts/build.sh g5

echo "[build-fat] sub-build 4/4: lion"
scripts/build.sh lion

# All four slices present?
for arch in g3 g4 g5 lion; do
  if [ ! -x "build/quakespasm-$arch" ]; then
    echo "[build-fat] missing build/quakespasm-$arch — sub-build did not produce a binary" >&2
    exit 1
  fi
done

# lipo lives on Lion's build host, not necessarily on the orchestration
# host. Send the four slices over, lipo there, scp the fat back. (lipo
# is also in /usr/bin/ on macOS only — a Linux orchestrator would not ship it by
# default. Doing the merge on Lion keeps the toolchain assumption
# uniform with build.sh.)
# BUILD_HOST was pinned (and claimed) at the top of this script, so the lipo runs
# on the SAME mini that built the slices. Assert rather than re-defaulting: a second
# "${BUILD_HOST:-mini-intel}" here could silently fuse on a different box than the
# one the slices were built on.
: "${BUILD_HOST:?internal error: build host should have been pinned above}"
LION="$BUILD_HOST"
echo "[build-fat] lipo -create on $LION (cross-build host)"
scp -q build/quakespasm-g3 build/quakespasm-g4 build/quakespasm-g5 build/quakespasm-lion \
  "$LION:/tmp/" >/dev/null
ssh "$LION" "cd /tmp && \
  lipo -create quakespasm-g3 quakespasm-g4 quakespasm-g5 quakespasm-lion \
    -output quakespasm-fat && \
  lipo -info quakespasm-fat"
scp -q "$LION:/tmp/quakespasm-fat" build/quakespasm-fat
ssh "$LION" "rm -f /tmp/quakespasm-{g3,g4,g5,lion,fat}" 2>/dev/null || true

echo "[build-fat] sanity:"
file build/quakespasm-fat
echo "[build-fat] OK — build/quakespasm-fat ready"
