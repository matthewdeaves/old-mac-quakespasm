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
# usage: scripts/build.sh <g3|g4|g5|lion|i386>   (arm64: scripts/build-arm64.sh)
# output: build/quakespasm-<target>
# env:    BUILD_HOST (ssh alias for the cross-build host; default: auto-picked
#         from the free Intel minis by scripts/pick-build-host.sh)
#         BUILD_HOSTS / BUILD_LOCK_WAIT — see scripts/pick-build-host.sh

set -euo pipefail

TARGET="${1:?usage: $0 <g3|g4|g5|lion|i386> (arm64: scripts/build-arm64.sh)}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The one definition of what a build is built FROM. The rsync exclude list below
# and the stamp written at the end both come from here, so they cannot drift.
. "$REPO_ROOT/scripts/source-stamp.sh"
. "$REPO_ROOT/scripts/source-stamp-excludes.sh"

# The cross-build host is an Intel Mac mini — there are now TWO interchangeable
# ones (mini-intel, mini-intel2: same Macmini2,1 / 10.7.5 / same toolchain). When
# the caller has not pinned one, ask pick-build-host.sh for a host that is both
# reachable and not already compiling for some other repo/agent, and CLAIM it for
# the duration so nobody grabs it mid-build. The claim is a lock ON the mini, so
# it is visible to the other quake repos and to other workstations — the flock
# below only serialises builds from THIS checkout.
# build-fat.sh pins BUILD_HOST for all five mini-built slices, so this only fires for a
# standalone build.sh run. LION is still accepted for backward compat.
BUILD_HOST_CLAIMED=0
if [ -z "${BUILD_HOST:-}" ] && [ -z "${LION:-}" ]; then
	# Strict release. Without a nonce the picker can only match user@host:repo,
	# which every session in this repo shares, so a sibling session's --release
	# would silently drop this build's lock -- the case build-host#7 was filed
	# for. Exported, not local, because the EXIT trap below runs --release in a
	# separate process and has to present the same claim this acquire made.
	export BENCH_LOCK_CLAIM="${BENCH_LOCK_CLAIM:-$$.$(date +%s).${RANDOM:-0}}"
	BUILD_HOST="$(BUILD_LOCK_WAIT="${BUILD_LOCK_WAIT:-900}" \
		"$REPO_ROOT/scripts/pick-build-host.sh" --acquire "quakespasm build.sh $TARGET")" || {
		echo "build.sh: no free Intel build host; see scripts/pick-build-host.sh --status" >&2
		exit 1
	}
	BUILD_HOST_CLAIMED=1
	echo "[build] claimed build host: $BUILD_HOST"
elif [ -z "${QS_BUILD_HOST_PRECLAIMED:-}" ]; then
	# Caller pinned BUILD_HOST/LION directly with no upstream claim signal.
	# This is currently the ONLY way to target imac-2019 (pick-build-host.sh's
	# auto-pick pool is still just the two Lion minis), so it is not a rare
	# edge case -- it's the normal way to run the g3/g4 GCC14 path today.
	# Measured 2026-08-29: a standalone `LION=imac-2019 scripts/build.sh g3`
	# compiled on imac-2019 with NO lock held at all -- another repo's session
	# found live cc1/make on the host and had to back off on judgment alone,
	# nothing stopped it from grabbing the box mid-compile.
	# build-fat.sh exports QS_BUILD_HOST_PRECLAIMED before its own per-slice
	# calls because IT already claimed (or is trusting the caller for)
	# BUILD_HOST for the whole run up front; this branch is only for a bare
	# standalone invocation, which has no such outer claim.
	export BENCH_LOCK_CLAIM="${BENCH_LOCK_CLAIM:-$$.$(date +%s).${RANDOM:-0}}"
	BUILD_HOST="${BUILD_HOST:-$LION}"
	BUILD_HOST="$(BUILD_LOCK_WAIT="${BUILD_LOCK_WAIT:-900}" \
		"$REPO_ROOT/scripts/pick-build-host.sh" --acquire-host "$BUILD_HOST" "quakespasm build.sh $TARGET")" || {
		echo "build.sh: could not claim $BUILD_HOST; see scripts/pick-build-host.sh --status" >&2
		exit 1
	}
	BUILD_HOST_CLAIMED=1
	echo "[build] claimed build host: $BUILD_HOST (explicit target)"
fi
BUILD_HOST="${BUILD_HOST:-${LION:-mini-intel}}"
LION="$BUILD_HOST"  # keep the LION name in scope for the `ssh "$LION"` lines below
trap '[ "$BUILD_HOST_CLAIMED" = 1 ] && "$REPO_ROOT/scripts/pick-build-host.sh" --release "$BUILD_HOST" >/dev/null 2>&1; true' EXIT

# Port release label stamped into the binary's version string. Computed HERE on
# the orchestration host (the rsync below excludes .git, so the cross-build host has no
# git metadata). `git describe` yields the release tag exactly on a tagged build
# (e.g. "v1.9"), or a descriptive "v1.9-3-gabc123" / "-dirty" off-tag so dev
# builds self-identify. Makefile.darwin turns QS_PORT_VERSION into
# -DQUAKESPASM_VER_SUFFIX. Overridable via env so build-fat.sh stamps all five
# slices with one identical value.
QS_PORT_VERSION="${QS_PORT_VERSION:-$(git -C "$REPO_ROOT" describe --tags --always --dirty 2>/dev/null || echo unknown)}"

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

# .m-only compile flags (Makefile.darwin's OBJCFLAGS). Empty except on the
# imac-2019 GCC14 g3/g4 path (#37), which needs -fnext-runtime; declared here,
# ahead of the case, so every other target has it defined under set -u.
OBJCFLAGS=""
# Final-link strip command (Makefile.darwin's STRIP, default "strip -S").
# Overridden only on the imac-2019 GCC14 g3/g4 path: modern Sequoia's
# Xcode strip doesn't know PowerPC at all ("reloc_has_pair() called with
# unknown cputype (18)", measured 2026-08-29 -- same "modern tool assumes a
# modern Mac" pattern as MISTAKES.md's other entries), and there's no
# PowerPC-aware strip bundled with the GCC14 cross-toolchain or available as
# llvm-strip on this host. `true` (no-op) leaves the binary unstripped --
# correct and launchable, just bigger and with symbols; the Lion-mini path
# (real strip -S, real gcc-4.0) is unaffected and still strips normally.
STRIP="strip -S"

case "$TARGET" in
  g3)
    MACH_TYPE=ppc
    VMIN=10.3
    CPUFLAGS='-mcpu=750 -O3'
    if [ "$LION" = "imac-2019" ]; then
      # GCC14 cross-compiler path (#37/#39, build-host). Apple's own
      # gcc-4.0 doesn't exist on Sequoia at all; this is a genuinely
      # different toolchain, not just a different SDK path. -nostdinc +
      # explicit -isystem order is REQUIRED here -- without it GCC14's own
      # fixincludes pulls a mismatched machine/ansi.h regardless of the
      # target SDK (measured 2026-08-28/29, build-host root-caused it).
      # Hardcoded /Users/mini, NOT $HOME: this string is expanded HERE on
      # the orchestration host (this workstation's $HOME, not imac-2019's)
      # before being embedded in the remote ssh/make command below -- hit
      # this exact bug once already today on the i386 path, repeating it
      # here would be the same mistake twice.
      #
      # gcc14-ppc-objc, NOT gcc14-ppc: the plain toolchain was built C-only
      # (no cc1obj), so pl_osx.m / SDLMain.m can't compile on it at all,
      # flags or no flags -- this is a separate build-host toolchain install
      # with Objective-C language support enabled. Verified 2026-08-29 it
      # also compiles plain .c identically to the C-only install, so one
      # toolchain now covers the whole g3/g4 imac-2019 build.
      CC14BASE="/Users/mini/gcc14-ppc-objc"
      GCCINCBASE="$CC14BASE/lib/gcc/powerpc-apple-darwin8/14.2.0"
      SDK="/Users/mini/SDKs/MacOSX10.3.9.sdk"
      CC="$CC14BASE/bin/powerpc-apple-darwin8-gcc"
      # -include the ptrdiff_t compat shim (build-host, root-caused): Panther's
      # own ppc/ansi.h sets the _BSD_PTRDIFF_T_ guard macro GCC14's stddef.h
      # also checks, without emitting a typedef, so stddef.h thinks
      # ptrdiff_t is already provided and skips its own definition. A
      # re-include of <stddef.h> from our own source can't fix it (standard
      # include guard, no-op on the second pass) -- this shim forces the
      # typedef directly via -include, ahead of any source file's own
      # includes. See scripts/gcc14-ptrdiff-compat.h. (Our own repo-tracked
      # shim, not build-host's host-local /Users/mini/ptrdiff-compat-full.h --
      # verified 2026-08-29 ours is sufficient for every file in this build,
      # including the .m files, and keeping it repo-tracked means it survives
      # a toolchain reinstall on the host instead of depending on untracked
      # host state.)
      CPUFLAGS="$CPUFLAGS -nostdinc -isystem $GCCINCBASE/include -isystem $GCCINCBASE/../../../../powerpc-apple-darwin8/include -isystem $SDK/usr/include -iframework $SDK/System/Library/Frameworks -include ../scripts/gcc14-ptrdiff-compat.h"
      # .m-only (Makefile.darwin's OBJCFLAGS, kept out of CFLAGS): this GCC
      # defaults to the GNU Objective-C runtime, which cannot talk to real
      # Cocoa/Foundation at all. -fnext-runtime switches it to the runtime
      # Apple's own frameworks expect. Verified 2026-08-29: compiled+linked a
      # real NSAutoreleasePool/NSString/UTF8String test against genuine
      # Foundation.framework, and separately pl_osx.m / SDLMain.m themselves,
      # clean. (build-host, #37.)
      OBJCFLAGS="-fnext-runtime"
      STRIP="true"  # see STRIP comment above the case
    else
      CC=/usr/bin/gcc-4.0
      SDK=/Developer/SDKs/MacOSX10.3.9.sdk
    fi
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
    # Built against the 10.3.9 SDK at min-10.3, NOT 10.4u/min-10.4 (issue #1).
    # dyld grades slices by CPU subtype alone, so a G4 booted on Panther is
    # handed this ppc7400 slice regardless of its OS floor — there is no
    # fallback to the min-10.3 ppc750 slice. Building at min-10.3 makes the one
    # slice cover G4s on 10.3, 10.4 and 10.5. AltiVec codegen is orthogonal to
    # the SDK (it comes from -mcpu=7400/-maltivec, and the 750 never sees this
    # slice), so nothing is given up on the Tiger G4s — verified by bench.
    # Same fix as the sister Half-Life port's v1.1.0.
    MACH_TYPE=ppc
    VMIN=10.3
    # -faltivec: enables Apple's context-sensitive `vector` keyword. REQUIRED
    # here and not under 10.4u, because the 10.3.9 SDK's Carbon
    # MachineExceptions.h declares an AltiVec `vector` field (pulled in via
    # AppController.m / pl_osx.m) and won't parse without it. -maltivec alone is
    # codegen only. Same requirement the Half-Life port hit on its min-10.3 G4
    # slice.
    CPUFLAGS='-mcpu=7400 -faltivec -maltivec -mabi=altivec -O3 -mtune=7450'
    if [ "$LION" = "imac-2019" ]; then
      # GCC14 cross-compiler path (#37/#39, build-host) -- see the g3 case
      # above for the ansi.h/ptrdiff_t rationale, identical here since this
      # is the same 10.3.9 SDK. GCC14 bundles its own altivec.h in
      # $GCCINCBASE/include (already on the -isystem list below), so the
      # gcc-4.0-specific "-isystem .../powerpc-apple-darwin10/4.0.1/include"
      # workaround for that header doesn't apply to this toolchain.
      #
      # gcc14-ppc-objc, NOT gcc14-ppc, and OBJCFLAGS -- see the g3 case
      # above for the rationale (same toolchain, same shim, same
      # -fnext-runtime need; g4's AppController.m/pl_osx.m hit it too).
      CC14BASE="/Users/mini/gcc14-ppc-objc"
      GCCINCBASE="$CC14BASE/lib/gcc/powerpc-apple-darwin8/14.2.0"
      SDK="/Users/mini/SDKs/MacOSX10.3.9.sdk"
      CC="$CC14BASE/bin/powerpc-apple-darwin8-gcc"
      CPUFLAGS="$CPUFLAGS -nostdinc -isystem $GCCINCBASE/include -isystem $GCCINCBASE/../../../../powerpc-apple-darwin8/include -isystem $SDK/usr/include -iframework $SDK/System/Library/Frameworks -include ../scripts/gcc14-ptrdiff-compat.h"
      OBJCFLAGS="-fnext-runtime"
      STRIP="true"  # see STRIP comment above the case
    else
      # -isystem <gcc-4.0 include>: gl_texmgr.c's AltiVec mip path includes
      # <altivec.h>, which is a COMPILER header, not an SDK one. The 10.4u SDK
      # happened to satisfy it; the 10.3.9 SDK does not, and -isysroot confines
      # the search to the sysroot, so point at gcc-4.0's own include dir
      # explicitly. Same workaround the Half-Life port needed for its min-10.3
      # G4 slice. (The path is on the cross-build host, mini-intel.)
      CC=/usr/bin/gcc-4.0
      SDK=/Developer/SDKs/MacOSX10.3.9.sdk
      CPUFLAGS="$CPUFLAGS -isystem /usr/lib/gcc/powerpc-apple-darwin10/4.0.1/include"
    fi
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
    #
    # min-10.6, not 10.7 (issue #4): dyld grades by CPU alone, so a 64-bit Intel
    # Mac left on Snow Leopard is handed this slice regardless of its OS — there
    # is no lower Intel slice to fall back to. Lion's SDK weak-links correctly
    # for a 10.6 deployment target, and the bundled codec dylibs are already
    # built at min 10.6, so nothing else has to move. The engine is plain C, so
    # the libc++-on-10.6 problem that keeps the sister Half-Life port at 10.7
    # does not apply here. NOTE: there is no Snow Leopard machine in the fleet —
    # this is build-correct and verified to still run on 10.7, but 10.6 itself
    # is untested. The README says so.
    MACH_TYPE=x86_64
    CC=/usr/bin/clang
    SDK=""
    VMIN=10.6
    CPUFLAGS='-arch x86_64 -mmacosx-version-min=10.6 -O3 -Qunused-arguments'
    if [ "${LTO:-0}" = "1" ]; then
      CPUFLAGS="$CPUFLAGS -flto"
      EXTRA_LDFLAGS='-flto'
    else
      EXTRA_LDFLAGS=''
    fi
    SYSROOT=""
    if [ "$LION" = "imac-2019" ]; then
      # build-host's candidate recipe for x86_64 on imac-2019 (#40). Measured
      # 2026-08-30: WITHOUT this flag, a plain -mmacosx-version-min=10.6 clang
      # build on imac-2019's Sequoia Xcode compiles clean (sane load commands,
      # correct LC_VERSION_MIN_MACOSX, no chained-fixups load command) but
      # SEGFAULTS INSTANTLY on real Lion hardware (mini-intel2) before dyld
      # even reaches DYLD_PRINT_LIBRARIES output -- 3/3 bench runs, no crash
      # log, no qconsole.log written at all. A same-source build via the
      # normal mini-intel2/Lion-native clang path launches and runs fine on
      # the same machine, isolating the crash to the imac-2019 toolchain
      # specifically, not the source or the bundle.
      EXTRA_LDFLAGS="$EXTRA_LDFLAGS -Wl,-ld_classic"
    fi
    ;;
  i386)
    # 32-bit-only Intel: the 2006 Core Solo / Core Duo machines (Mac mini 1,1,
    # iMac 4,1, MacBook 1,1, MacBook Pro 1,1). These are the sole Intel Macs
    # with no 64-bit mode, and they top out at 10.6.8.
    #
    # This slice is not a nicety. dyld grades a fat by CPU subtype alone, so a
    # Core Duo is never handed the x86_64 slice; without an i386 slice those
    # machines get nothing and the app does not launch at all.
    #
    # min-10.4, lower than the x86_64 slice's 10.6: an i386-only Mac may still
    # be on Tiger or Leopard, and there is no lower Intel slice beneath this
    # one to catch it. The bundled SDL.framework already carries an i386 slice
    # and so do all ten codec dylibs, so nothing else has to move.
    #
    # NOT TESTED ON HARDWARE: there is no 32-bit-only Intel Mac in the fleet.
    # This is build-correct only. The README says so.
    #
    # Host-dependent SDK (2026-08-28, user directive to move this slice to
    # imac-2019 for speed): on a Lion mini, "no isysroot" naturally resolves
    # to a compatible OS (the compiler's default SDK IS Lion's own, weak-
    # linking down to 10.4 from a close relative). imac-2019 is Sequoia --
    # its own default SDK is a dozen OS releases newer, not something to
    # weak-link an ancient target against untested (same shape as the G5/
    # VMIN mismatch, issue #35's launch matrix). It DOES have a genuine
    # 10.4u SDK already staged (for the PPC cross-compiler, #37) -- pin an
    # explicit isysroot there instead of trusting a default. Verified
    # 2026-08-28: clean compile+link, correct i386 architecture, correct
    # LC_VERSION_MIN_MACOSX 10.4 (two deprecation warnings only, cosmetic --
    # modern ld complaining about an old target, same category already
    # silenced elsewhere in this file with -Wl,-w). The Lion minis are
    # UNCHANGED: still SDK="", still their own proven default.
    MACH_TYPE=x86
    CC=/usr/bin/clang
    VMIN=10.4
    if [ "$LION" = "imac-2019" ]; then
      # Hardcoded, not $HOME: this string is expanded HERE, on the
      # orchestration host, before being embedded in the remote ssh/make
      # command below -- $HOME at this point is this workstation's home,
      # not imac-2019's ("mini"). Every ssh target in this fleet's config
      # is the "mini" user (see ~/.ssh/config), so this path is stable.
      SDK="/Users/mini/SDKs/MacOSX10.4u.sdk"
      SYSROOT="-isysroot $SDK"
    else
      SDK=""
      SYSROOT=""
    fi
    CPUFLAGS='-arch i386 -mmacosx-version-min=10.4 -O3 -Qunused-arguments'
    EXTRA_LDFLAGS=''
    ;;
  arm64)
    echo "build.sh: arm64 cannot be built here. Lion's Xcode 4.6 toolchain" >&2
    echo "build.sh: predates arm64 by seven years. Run scripts/build-arm64.sh" >&2
    echo "build.sh: on the Apple Silicon orchestration Mac instead." >&2
    exit 2
    ;;
  *)
    echo "unknown target: $TARGET (expected: g3|g4|g5|lion|i386)" >&2
    echo "  arm64 is built by scripts/build-arm64.sh, not here." >&2
    exit 2
    ;;
esac

echo "[build] sync sources orchestrator → $LION"
# exclude prereqs/ (5 GB of installer DMGs; only used locally for setup)
# and benchmarks/raw/ + build/ (output dirs that shouldn't bounce through Lion)
rsync -av --partial --inplace --delete \
  $(source_stamp_rsync_excludes "$SOURCE_STAMP_EXCLUDES") \
  -e 'ssh -o ServerAliveInterval=15' \
  "$REPO_ROOT/" "$LION:quakespasm/" | tail -3

echo "[build] compile $TARGET on $LION (SDK=${SDK:-default}, vmin=$VMIN, arch=$MACH_TYPE)"
ssh "$LION" "cd quakespasm/Quake && \
  make -f Makefile.darwin clean >/dev/null 2>&1
  make -f Makefile.darwin MACH_TYPE=$MACH_TYPE -j2 \
    CC=$CC \
    QS_PORT_VERSION=$QS_PORT_VERSION \
    CPUFLAGS=\"$SYSROOT $CPUFLAGS\" \
    OBJCFLAGS=\"$OBJCFLAGS\" \
    STRIP=\"$STRIP\" \
    LDFLAGS=\"$SYSROOT $CPUFLAGS $EXTRA_LDFLAGS\" \
    > /tmp/qs-build-$TARGET.log 2>&1
  RC=\$?
  if [ \$RC -ne 0 ]; then tail -30 /tmp/qs-build-$TARGET.log; exit \$RC; fi
  install_name_tool -change \
    @executable_path/../Frameworks/SDL.framework/Versions/A/SDL \
    @executable_path/SDL.framework/Versions/A/SDL \
    quakespasm
  # Don't trust exit 0 -- or exit nonzero, here. Sequoia's Xcode
  # install_name_tool cannot write PowerPC Mach-O at all (measured 2026-08-29
  # on imac-2019: 'internal error: swap_object_headers() failed' on ppc750,
  # #37) and exits nonzero even when the binary is already correct, because
  # this toolchain's own linker already emits the right install name and
  # there was nothing to change. So verify the RESULT instead of the exit
  # code: fail only if the desired path is genuinely still missing.
  if ! otool -L quakespasm | grep -q '@executable_path/SDL.framework/Versions/A/SDL'; then
    echo 'install_name_tool fixup failed AND the SDL path is not already correct -- real problem' >&2
    otool -L quakespasm >&2
    exit 1
  fi
  mv quakespasm quakespasm-$TARGET"

mkdir -p "$REPO_ROOT/build"
echo "[build] fetch → build/quakespasm-$TARGET"
scp -q "$LION:quakespasm/Quake/quakespasm-$TARGET" "$REPO_ROOT/build/quakespasm-$TARGET"
file "$REPO_ROOT/build/quakespasm-$TARGET"

# --- exact cpusubtype enforcement -------------------------------------------
# Every PPC slice MUST carry its exact cpusubtype (ppc750=9, ppc7400=10,
# ppc970=100). A generic `ppc (ALL)` slice is a launch BLOCKER, not a cosmetic
# imprecision: Panther's lax 2003 dyld accepts it, but the Tiger/Leopard KERNEL
# mis-grades a fat of [ppc ALL, ppc7400, ppc970] on a 750 host and refuses to
# exec — proven on hardware in the sister Half-Life port, whose v1.0.0 could not
# launch on the G3 under Tiger for exactly this reason.
#
# Apple's gcc-4.0 normally derives the stamp from -mcpu=, but NOT reliably:
# `-faltivec` (required by the g4 slice's 10.3.9 SDK, see its case above) makes
# the linker emit ALL instead of 7400. So don't trust the compiler — assert the
# subtype here and re-stamp if it drifted. Thin 32-bit big-endian Mach-O:
# cpusubtype is the 4-byte big-endian field at offset 8. Idempotent.
case "$TARGET" in
  g3)   WANT_SUBTYPE=9;   WANT_NAME=ppc750  ;;
  g4)   WANT_SUBTYPE=10;  WANT_NAME=ppc7400 ;;
  g5)   WANT_SUBTYPE=100; WANT_NAME=ppc970  ;;
  *)    WANT_SUBTYPE=""                     ;;  # lion: x86_64, nothing to fix
esac
if [ -n "$WANT_SUBTYPE" ]; then
  BIN="$REPO_ROOT/build/quakespasm-$TARGET"
  GOT=$(lipo -info "$BIN" | sed 's/.*: //')
  if [ "$GOT" != "$WANT_NAME" ]; then
    echo "[build] cpusubtype is '$GOT', re-stamping → $WANT_NAME ($WANT_SUBTYPE)"
    printf "$(printf '\\%03o\\%03o\\%03o\\%03o' 0 0 0 "$WANT_SUBTYPE")" \
      | dd of="$BIN" bs=1 seek=8 count=4 conv=notrunc 2>/dev/null
    GOT=$(lipo -info "$BIN" | sed 's/.*: //')
    [ "$GOT" = "$WANT_NAME" ] || { echo "[build] FAILED to stamp $WANT_NAME (got '$GOT')" >&2; exit 1; }
  fi
  echo "[build] cpusubtype OK: $GOT"
fi

# --- source stamp ------------------------------------------------------------
# Record WHAT THIS SLICE WAS BUILT FROM, so build-fat.sh can refuse to fuse a
# slice built from different source than the others. Written only now, after
# the cpusubtype assertion above, so a slice that failed any check leaves no
# stamp and reads as un-built rather than as current.
#
# The stamp goes in build/, which the hash excludes, so writing it cannot change
# the hash it records. Its own directory per target because the slices are bare
# files, not directories: source_stamp_write takes a directory and knows nothing
# about our layout, which is what lets old-mac-build-host replace it later.
STAMP_DIR="$REPO_ROOT/build/stamps/$TARGET"
mkdir -p "$STAMP_DIR"
source_stamp_write "$STAMP_DIR" "$(source_stamp_compute "$REPO_ROOT" "$SOURCE_STAMP_EXCLUDES")"
echo "[build] source stamp $(source_stamp_read "$STAMP_DIR" | cut -c1-12) → build/stamps/$TARGET"
