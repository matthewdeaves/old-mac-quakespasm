#!/usr/bin/env bash
# Build a QuakeSpasm binary on the cross-build host (mini-intel, the Lion box).
# - g3/g4: cross-compile PPC via gcc-4.0 + 10.3.9/10.4u SDKs
# - lion : native x86_64 build for the Lion box itself (Macmini2,1, Core 2 Duo
#          @ 2.33 GHz, 10.7.5).
#
# The build TARGET names (g3/g4/lion) refer to chip family + SDK, NOT machine
# identity. The single g4 binary serves three machines (sawtooth, quicksilver,
# mini-g4) — they all run -mcpu=7400 -maltivec code on Tiger 10.4. Machine
# identity → binary mapping lives in scripts/deploy.sh.
#
# - g5  : cross-compile PPC via gcc-4.0 + 10.5 SDK, tuned -mcpu=970 for the
#         iMac G5 (PowerMac8,2, 970FX) on Leopard 10.5.8. AltiVec like the G4,
#         but a very different pipeline, so it gets its own scheduling pass.
#         Stamped cpusubtype ppc970 (via -arch ppc -mcpu=970, same mechanism
#         that gives g4 its ppc7400 stamp) so dyld prefers it on the G5 while
#         G4s still fall back to the ppc7400 slice.
#
# usage: scripts/build.sh <g3|g4|g5|lion>
# output: build/quakespasm-<target>
# env:    BUILD_HOST (ssh alias for the cross-build host, default 'mini-intel')

set -euo pipefail

TARGET="${1:?usage: $0 <g3|g4|g5|lion>}"
# The cross-build host is the Intel Mac mini (mini-intel). Variable name
# kept as BUILD_HOST for clarity; LION still accepted for backward compat.
BUILD_HOST="${BUILD_HOST:-${LION:-mini-intel}}"
LION="$BUILD_HOST"  # keep the LION name in scope for the `ssh "$LION"` lines below
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
    # PPC port -- profiling pass: BUILD_PG=1 adds -pg to compile +
    # link so the binary writes gmon.out on clean exit. -O3 is kept
    # so we profile what we ship; -pg adds ~3-5% overhead per call
    # via mcount instrumentation. Use `+timedemo demoN +quit` to get
    # a clean exit (SIGKILL won't write gmon.out).
    if [ "${BUILD_PG:-0}" = "1" ]; then
      CPUFLAGS="$CPUFLAGS -pg"
      EXTRA_LDFLAGS="$EXTRA_LDFLAGS -pg"
      echo "[build] BUILD_PG=1 → adding -pg (gprof instrumentation)"
    fi
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
  g5)
    # iMac G5 (PowerMac8,2, single 970FX @ 2.0 GHz) on Leopard 10.5.8.
    # The 970 has AltiVec (so __VEC__ paths apply, same as g4) but a deep,
    # heavily out-of-order pipeline with different AltiVec latencies than the
    # 7450 — so it gets -mcpu=970 scheduling rather than reusing the g4 slice.
    # `-arch ppc -mcpu=970` stamps cpusubtype ppc970 (Apple gcc propagates
    # -mcpu into the subtype, the same way g4 → ppc7400), so this slice is a
    # distinct lipo member and dyld prefers it on the G5; G4 hosts (ppc7450)
    # aren't a 970 descendant so they fall back to the ppc7400 slice.
    # 32-bit ABI (-arch ppc, not ppc64): Leopard runs the 32-bit slice fine
    # and we have no need for 64-bit GPRs here.
    MACH_TYPE=ppc
    CC=/usr/bin/gcc-4.0
    SDK=/Developer/SDKs/MacOSX10.5.sdk
    VMIN=10.5
    # Apple gcc defines only __VEC__/__ALTIVEC__/__ppc__ for -mcpu=970 (no
    # __ppc970__), so the 970 slice is indistinguishable from the 7400 slice
    # at compile time. -DQS_ARCH_PPC970 gives host.c a hook to load the
    # generic-G5 autoexec baseline (autoexec-ppc970) instead of the G4 one.
    # Same compile-time-gate pattern as QS_DISABLE_ALIAS_STATE_CACHE.
    CPUFLAGS='-mcpu=970 -maltivec -mabi=altivec -O3 -DQS_ARCH_PPC970'
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
    #
    # LTO (Round v5 B3) -- Lion's clang is Apple LLVM 2.9-based, too old
    # for `-fprofile-instr-generate` PGO (silently accepted, no
    # instrumentation actually emitted). `-flto` does work and produces
    # a valid binary. Opt-in via LTO=1; see CLAUDE.md "Toggleable
    # knobs" for what's runtime-flippable vs. built-in.
    MACH_TYPE=x86_64
    CC=/usr/bin/clang
    SDK=""
    VMIN=10.7
    CPUFLAGS='-arch x86_64 -mmacosx-version-min=10.7 -O3 -Qunused-arguments'
    if [ "${LTO:-0}" = "1" ]; then
      CPUFLAGS="$CPUFLAGS -flto"
      EXTRA_LDFLAGS='-flto'
    else
      EXTRA_LDFLAGS=''
    fi
    SYSROOT=""
    ;;
  *)
    echo "unknown target: $TARGET (expected: g3|g4|g5|lion)" >&2
    exit 2
    ;;
esac

echo "[build] sync sources Ubuntu → $LION"
# exclude prereqs/ (5 GB of installer DMGs; only used locally for setup)
# and benchmarks/raw/ + build/ (output dirs that shouldn't bounce through Lion)
rsync -av --partial --inplace --delete \
  --exclude='.git' --exclude='*.o' --exclude='*.d' \
  --exclude='build/' --exclude='benchmarks/' --exclude='prereqs/' \
  --exclude='quakespasm' --exclude='quakespasm-g3' --exclude='quakespasm-g4' --exclude='quakespasm-g5' --exclude='quakespasm-lion' \
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
