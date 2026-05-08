#!/usr/bin/env bash
# Build a QuakeSpasm binary on the Lion build host.
# - g3/g4: cross-compile PPC via gcc-4.0 + 10.3.9/10.4u SDKs
# - lion : native x86_64 build for Lion itself (Macmini2,1, Core 2 Duo
#          @ 2.33 GHz, 10.7.5). Third reference point alongside G3 + G4.
#
# usage: scripts/build.sh <g3|g4|lion>
# output: build/quakespasm-<target>
# env:    LION (ssh alias for the build host, default 'lion')

set -euo pipefail

TARGET="${1:?usage: $0 <g3|g4|lion>}"
LION="${LION:-lion}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Serialize concurrent invocations. Both targets rsync to the same
# lion:quakespasm/ path and `make -j2` in lion:quakespasm/Quake/ — running
# them in parallel races on the .o files and produces a binary stamped with
# the *other* target's CPU subtype. Symptom: `lipo -info` reports ppc7400
# for a g3 build, the binary loads on Panther but crashes during AppKit NIB
# init when the runtime hits G4-compiled library code on a 750 CPU.
# flock blocks until the prior build releases. (The lock dir is a sibling
# of build/ so it survives `git clean -dfx`.)
LOCK_DIR="$REPO_ROOT/build"
mkdir -p "$LOCK_DIR"
exec 9>"$LOCK_DIR/.build.lock"
if ! flock -w 600 9; then
  echo "build.sh: another build is in progress on $LION; waited 10 min, giving up" >&2
  exit 1
fi

case "$TARGET" in
  g3)
    MACH_TYPE=ppc
    CC=/usr/bin/gcc-4.0
    SDK=/Developer/SDKs/MacOSX10.3.9.sdk
    VMIN=10.3
    CPUFLAGS='-mcpu=750 -O3'
    SYSROOT="-isysroot $SDK -mmacosx-version-min=$VMIN -arch ppc"
    # `-Wl,-w` silences the cosmetic `-mlong-branch which is no longer
    # needed` linker warnings emitted by Apple's own crt1.o/crt2.o on
    # the 10.3.9 SDK. Already documented in CLAUDE.md as harmless;
    # silencing here so any future real link warning stands out.
    EXTRA_LDFLAGS='-Wl,-w'
    ;;
  g4)
    MACH_TYPE=ppc
    CC=/usr/bin/gcc-4.0
    SDK=/Developer/SDKs/MacOSX10.4u.sdk
    VMIN=10.4
    CPUFLAGS='-mcpu=7400 -maltivec -mabi=altivec -O3 -mtune=7450'
    SYSROOT="-isysroot $SDK -mmacosx-version-min=$VMIN -arch ppc"
    EXTRA_LDFLAGS='-Wl,-w'  # see g3 case
    ;;
  lion)
    # Native x86_64 build on Lion. Lion has llvm-gcc-4.2 + clang; we
    # use clang for clean modern C support. No -isysroot — let the
    # compiler use its default toolchain SDK (Lion's Xcode 4.6.x).
    # Lion's kernel is RELEASE_I386 (Macmini2,1 boots i386) but
    # user-space x86_64 binaries run fine via the kernel's 64-bit
    # compat layer.
    #
    # `-Qunused-arguments` silences ~330 lines of "argument unused
    # during compilation" noise from clang about gcc-only flags
    # (-fweb / -frename-registers) and version-min duplications that
    # the Makefile.darwin pipeline routes to clang anyway. Cosmetic
    # only; lets real lion warnings stand out instead of being lost
    # in the noise.
    MACH_TYPE=x86_64
    CC=/usr/bin/clang
    SDK=""
    VMIN=10.7
    CPUFLAGS='-arch x86_64 -mmacosx-version-min=10.7 -O3 -Qunused-arguments'
    SYSROOT=""
    EXTRA_LDFLAGS=''
    ;;
  *)
    echo "unknown target: $TARGET (expected: g3|g4|lion)" >&2
    exit 2
    ;;
esac

echo "[build] sync sources Ubuntu → $LION"
# exclude prereqs/ (5 GB of installer DMGs; only used locally for setup)
# and benchmarks/raw/ + build/ (output dirs that shouldn't bounce through Lion)
rsync -av --partial --inplace --delete \
  --exclude='.git' --exclude='*.o' --exclude='*.d' \
  --exclude='build/' --exclude='benchmarks/' --exclude='prereqs/' \
  --exclude='quakespasm' --exclude='quakespasm-g3' --exclude='quakespasm-g4' --exclude='quakespasm-lion' \
  -e 'ssh -o ServerAliveInterval=15' \
  "$REPO_ROOT/" "$LION:quakespasm/" | tail -3

echo "[build] compile $TARGET on $LION (SDK=${SDK:-default}, vmin=$VMIN, arch=$MACH_TYPE)"
ssh "$LION" "cd quakespasm/Quake && \
  make -f Makefile.darwin clean >/dev/null 2>&1
  make -f Makefile.darwin MACH_TYPE=$MACH_TYPE -j2 \
    CC=$CC \
    CPUFLAGS=\"$SYSROOT $CPUFLAGS\" \
    LDFLAGS=\"$SYSROOT $CPUFLAGS $EXTRA_LDFLAGS\" \
    > /tmp/qs-build-$TARGET.log 2>&1
  RC=\$?
  if [ \$RC -ne 0 ]; then tail -30 /tmp/qs-build-$TARGET.log; exit \$RC; fi
  install_name_tool -change \
    @executable_path/../Frameworks/SDL.framework/Versions/A/SDL \
    @executable_path/SDL.framework/Versions/A/SDL \
    quakespasm
  mv quakespasm quakespasm-$TARGET"

mkdir -p "$REPO_ROOT/build"
echo "[build] fetch → build/quakespasm-$TARGET"
scp -q "$LION:quakespasm/Quake/quakespasm-$TARGET" "$REPO_ROOT/build/quakespasm-$TARGET"
file "$REPO_ROOT/build/quakespasm-$TARGET"
