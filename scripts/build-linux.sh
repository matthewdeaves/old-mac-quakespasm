#!/usr/bin/env bash
# Build a QuakeSpasm Linux x86_64 binary on the Ubuntu orchestration host.
#
# This is *not* a bench target — none of the four bench machines run Linux.
# It exists so static analyzers (scan-build, clang-tidy, cppcheck,
# -fanalyzer, infer, etc.) and runtime sanitizers (ASan, UBSan) have a
# buildable target on the orchestration host. Same source the PPC and Lion
# builds compile.
#
# usage: scripts/build-linux.sh [variant]
#   variant ∈ {default, asan, ubsan, analyze}
#     default — plain optimised build with full modern warnings
#     asan    — -fsanitize=address build for runtime heap/UAF checks
#     ubsan   — -fsanitize=undefined build for UB hunting
#     analyze — -fanalyzer interprocedural pass; warnings only, may be slow
#
# output: build/quakespasm-linux[-<variant>]
# deps:   libsdl2-dev libvorbis-dev libgl1-mesa-dev (already on this host)

set -euo pipefail

VARIANT="${1:-default}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Modern-warning floor — applies to every Linux variant. These are findings
# the PPC gcc-4.0 and Lion clang both miss, so the Linux build is our
# "second compiler" pass that surfaces issues the ship toolchains silently
# accept. -Wcast-align is especially load-bearing because misaligned access
# is a real perf bug on PPC (alignment-trap fixup on G3, AltiVec penalty on
# G4) but compiles cleanly on x86.
WARNS=(
  -Wall -Wextra -Wshadow
  -Wstrict-prototypes -Wmissing-prototypes
  -Wpointer-arith -Wcast-align
  -Wwrite-strings -Wundef -Wfloat-equal
  -Wnull-dereference -Wdouble-promotion
  -Wlogical-op -Wduplicated-cond -Wduplicated-branches
  -Wstrict-aliasing=2
  -Wformat=2
  -Wmissing-include-dirs -Wmissing-field-initializers
)

# Codecs disabled to avoid soft-deps on libmad/libFLAC/libopusfile during
# analysis runs. Vorbis kept because it's installed and exercises a typical
# codec path.
MAKE_VARS=(
  USE_SDL2=1
  USE_CODEC_WAVE=1
  USE_CODEC_VORBIS=1
  USE_CODEC_MP3=0
  USE_CODEC_FLAC=0
  USE_CODEC_OPUS=0
  USE_CODEC_MIKMOD=0
  USE_CODEC_UMX=0
)

case "$VARIANT" in
  default)
    EXTRA_CFLAGS="${WARNS[*]} -O2"
    EXTRA_LDFLAGS=""
    OUT_NAME="quakespasm-linux"
    ;;
  asan)
    # ASan: heap/stack OOB, use-after-free, double-free. Slows runtime
    # ~2x, fine for timedemo. -fno-omit-frame-pointer makes traces useful.
    EXTRA_CFLAGS="${WARNS[*]} -O1 -g -fsanitize=address -fno-omit-frame-pointer"
    EXTRA_LDFLAGS="-fsanitize=address"
    OUT_NAME="quakespasm-linux-asan"
    ;;
  ubsan)
    # UBSan: signed shift, integer overflow, alignment, null deref. The
    # signed-shift UB landed in 463ec405 is exactly what this catches.
    # -fno-sanitize-recover keeps the process running so we collect every
    # diagnostic, not just the first.
    EXTRA_CFLAGS="${WARNS[*]} -O1 -g -fsanitize=undefined -fno-sanitize-recover=undefined"
    EXTRA_LDFLAGS="-fsanitize=undefined"
    OUT_NAME="quakespasm-linux-ubsan"
    ;;
  analyze)
    # gcc -fanalyzer: interprocedural, finds use-after-free, double-free,
    # fd leaks, taint. Output is warnings-only; binary is usable. Pair
    # with scan-build for two complementary path-sensitive views.
    EXTRA_CFLAGS="${WARNS[*]} -O2 -fanalyzer -fdiagnostics-path-format=inline-events"
    EXTRA_LDFLAGS=""
    OUT_NAME="quakespasm-linux-analyze"
    ;;
  *)
    echo "build-linux.sh: unknown variant '$VARIANT' (expected default|asan|ubsan|analyze)" >&2
    exit 2
    ;;
esac

cd "$REPO_ROOT/Quake"
echo "[build-linux] variant=$VARIANT → build/$OUT_NAME"

# Clean stale artifacts so the warning report is fresh. The Linux build
# shares the Quake/ tree with all PPC/Mac builds (per-target trees live
# on Lion); keep this dir clean between runs to avoid stale .o linkage.
make -f Makefile clean >/dev/null 2>&1 || true

# CFLAGS append, not override — preserves the Makefile's own flags
# (-DNDEBUG, -fweb, -frename-registers, -DUSE_SDL2, etc.).
make -f Makefile -j"$(nproc)" "${MAKE_VARS[@]}" \
  EXTRA_CFLAGS="$EXTRA_CFLAGS" \
  EXTRA_LDFLAGS="$EXTRA_LDFLAGS" 2>&1 | tee "/tmp/qs-build-linux-$VARIANT.log"

mkdir -p "$REPO_ROOT/build"
mv quakespasm "$REPO_ROOT/build/$OUT_NAME"
file "$REPO_ROOT/build/$OUT_NAME"
echo "[build-linux] done → build/$OUT_NAME"
