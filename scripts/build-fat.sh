#!/usr/bin/env bash
# Build a 6-arch universal Quakespasm binary by composing the existing
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
. "$REPO_ROOT/scripts/source-stamp.sh"
. "$REPO_ROOT/scripts/source-stamp-excludes.sh"
cd "$REPO_ROOT"

# Resolve the port release label ONCE here and export it so all five sub-builds
# stamp the identical version into their slice (build.sh would otherwise call
# git describe per-slice — same value in practice, but pinning it is correct and
# documents intent). git describe gives "v1.9" on a tagged build, else a
# descriptive off-tag string. Overridable via the environment.
export QS_PORT_VERSION="${QS_PORT_VERSION:-$(git -C "$REPO_ROOT" describe --tags --always --dirty 2>/dev/null || echo unknown)}"
echo "[build-fat] stamping port version: $QS_PORT_VERSION"

# Pin ONE Intel build host for the whole fat build and claim it up front.
# This MUST be a single host for the entire run: the five mini-built slices accumulate in
# that host's quakespasm/Quake/ tree and the final lipo happens there, so letting
# individual sub-builds drift onto different minis would lipo an incomplete set.
# Claiming once also stops another repo/agent taking the box between sub-builds.
# An explicit BUILD_HOST (or LION) from the caller always wins.
if [ -z "${BUILD_HOST:-}" ] && [ -z "${LION:-}" ]; then
	# Strict release. Without a nonce the picker can only match user@host:repo,
	# which every session in this repo shares, so a sibling session's --release
	# would silently drop this build's lock -- the case build-host#7 was filed
	# for. Exported, not local, because the EXIT trap below runs --release in a
	# separate process and has to present the same claim this acquire made.
	export BENCH_LOCK_CLAIM="${BENCH_LOCK_CLAIM:-$$.$(date +%s).${RANDOM:-0}}"
	BUILD_HOST="$(BUILD_LOCK_WAIT="${BUILD_LOCK_WAIT:-900}" \
		"$REPO_ROOT/scripts/pick-build-host.sh" --acquire "quakespasm build-fat")" || {
		echo "[build-fat] no free Intel build host; see scripts/pick-build-host.sh --status" >&2
		exit 1
	}
	export BUILD_HOST
	# Absolute path: the trap must still resolve if anything ever cd's away.
	trap '"$REPO_ROOT/scripts/pick-build-host.sh" --release "$BUILD_HOST" >/dev/null 2>&1; true' EXIT
	echo "[build-fat] claimed build host: $BUILD_HOST (held for all five mini-built slices)"
else
	export BUILD_HOST="${BUILD_HOST:-$LION}"
	echo "[build-fat] using caller-supplied build host: $BUILD_HOST"
fi

echo "[build-fat] sub-build 1/5: g3"
scripts/build.sh g3

echo "[build-fat] sub-build 2/5: g4"
scripts/build.sh g4

echo "[build-fat] sub-build 3/5: g5"
scripts/build.sh g5

echo "[build-fat] sub-build 4/5: lion"
scripts/build.sh lion

echo "[build-fat] sub-build 5/5: i386"
scripts/build.sh i386

# All five mini-buildable slices present?
for arch in g3 g4 g5 lion i386; do
  if [ ! -x "build/quakespasm-$arch" ]; then
    echo "[build-fat] missing build/quakespasm-$arch — sub-build did not produce a binary" >&2
    exit 1
  fi
done

# arm64 is the ONE slice a Lion mini cannot build: its Xcode 4.6 toolchain
# predates arm64 by seven years. It is produced separately by
# scripts/build-arm64.sh on the Apple Silicon orchestration Mac, so here it is
# OPTIONAL and picked up if present. Its absence is a Rosetta 2 downgrade on
# Apple Silicon, not a fault, and the fuse says which way it went either way
# rather than leaving it to be discovered from a lipo -archs later.
SLICES="g3 g4 g5 lion i386"

# What the source looks like RIGHT NOW. Every slice we fuse must have been built
# from exactly this. Computed once; the five slices above were just rebuilt from
# it, so this is also what their own stamps must say.
WANT_STAMP="$(source_stamp_compute "$REPO_ROOT" "$SOURCE_STAMP_EXCLUDES")"
echo "[build-fat] source stamp $(printf %s "$WANT_STAMP" | cut -c1-12)"

# The five mini-built slices are rebuilt by this script every run, so a mismatch
# here means something is wrong with the build itself, not with staleness.
# Check them anyway: the check is worthless if it only runs on the slice we
# already suspect.
for arch in g3 g4 g5 lion i386; do
  got="$(source_stamp_read "$REPO_ROOT/build/stamps/$arch")"
  if [ "$got" != "$WANT_STAMP" ]; then
    echo "[build-fat] $arch was built from different source than this tree" >&2
    echo "[build-fat]   want $WANT_STAMP" >&2
    echo "[build-fat]   got  ${got:-<no stamp>}" >&2
    exit 1
  fi
done
echo "[build-fat] five mini-built slices match the source"

# arm64 is the slice this check exists for. It is built separately by
# scripts/build-arm64.sh on an Apple Silicon Mac and is the ONE slice this
# script never rebuilds, so it is the only one that can be older than the
# source. Absence is still allowed -- that is a Rosetta 2 downgrade, not a
# fault. Being present but STALE is a hard failure, because it silently ships
# Apple Silicon a different game from every other machine (issue #16).
if [ -x "build/quakespasm-arm64" ]; then
  got="$(source_stamp_read "$REPO_ROOT/build/stamps/arm64")"
  if [ "$got" != "$WANT_STAMP" ]; then
    echo "[build-fat] arm64 slice is STALE: built from different source than the other five." >&2
    echo "[build-fat]   want $WANT_STAMP" >&2
    echo "[build-fat]   got  ${got:-<no stamp>}" >&2
    echo "[build-fat]   Rebuild it: scripts/build-arm64.sh   (run on an Apple Silicon Mac)" >&2
    echo "[build-fat]   Refusing to fuse. A stale slice passes lipo -archs and the" >&2
    echo "[build-fat]   slice count, which is exactly why this check is a hash." >&2
    exit 1
  fi
  SLICES="$SLICES arm64"
  echo "[build-fat] arm64 slice present and built from this source, it WILL be included"
else
  echo "[build-fat] arm64 slice absent, fusing without it."
  echo "[build-fat]   Apple Silicon will run the x86_64 slice under Rosetta 2."
  echo "[build-fat]   To include it: run scripts/build-arm64.sh on an Apple Silicon Mac first."
fi

# lipo lives on Lion's build host, not necessarily on the orchestration
# host. Send the slices over, lipo there, scp the fat back. (lipo
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
SLICE_PATHS=""
SLICE_NAMES=""
for a in $SLICES; do
  SLICE_PATHS="$SLICE_PATHS build/quakespasm-$a"
  SLICE_NAMES="$SLICE_NAMES quakespasm-$a"
done

scp -q $SLICE_PATHS "$LION:/tmp/" >/dev/null
# Lion's lipo can WRITE a correct fat containing arm64 even though its otool
# and install_name_tool refuse the file and it cannot name the slice (it
# prints a numeric `cputype (16777228)` instead). Writing is all that is
# needed here; the naming check below runs on this box, whose lipo is current.
ssh "$LION" "cd /tmp && \
  lipo -create$SLICE_NAMES -output quakespasm-fat && \
  lipo -info quakespasm-fat"
scp -q "$LION:/tmp/quakespasm-fat" build/quakespasm-fat
ssh "$LION" "rm -f /tmp/quakespasm-fat$(for a in $SLICES; do printf ' /tmp/quakespasm-%s' "$a"; done)" 2>/dev/null || true

# Verify the fuse HERE, not on Lion: Lion's lipo cannot name an arm64 slice,
# so its own report would look like a corrupt fat.
echo "[build-fat] slices in the fused binary (verified on this box):"
lipo -archs build/quakespasm-fat
for a in $SLICES; do
  case $a in
    g3) want=ppc750 ;; g4) want=ppc7400 ;; g5) want=ppc970 ;;
    lion) want=x86_64 ;; i386) want=i386 ;; arm64) want=arm64 ;;
  esac
  case " $(lipo -archs build/quakespasm-fat) " in
    *" $want "*) ;;
    *) echo "[build-fat] fuse lost the $a slice ($want)" >&2; exit 1 ;;
  esac
done

echo "[build-fat] sanity:"
file build/quakespasm-fat
echo "[build-fat] OK — build/quakespasm-fat ready"
