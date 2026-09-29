# MacOSX/: toolchain and flags on the build host

Per-target flag reference; upstream's Xcode `Build_Instructions.md` is not how this port builds. Decisions: ADR 0001 (slices, floors), 0003 (SDL), 0004 (fat build), 0010 (bundle, source patches).

## Toolchain on the Lion build minis

`/usr/bin/gcc-4.0` (Apple gcc 4.0.1) cross-builds PowerPC; `/usr/bin/clang` (1.7) builds Intel; `/Developer/SDKs/MacOSX10.3.9.sdk` serves g3/g4/g5. The 10.4u and 10.5 SDKs are present but unused. All read-only and shared with the Q2 port: **never modify**.

## Per-target flags (as `scripts/build.sh` sets them)

Common to g3/g4/g5: `-isysroot /Developer/SDKs/MacOSX10.3.9.sdk -mmacosx-version-min=10.3 -arch ppc -O3`.
- **g3** `-mcpu=750`
- **g4** `-mcpu=7400 -faltivec -maltivec -mabi=altivec -mtune=7450 -isystem /usr/lib/gcc/powerpc-apple-darwin10/4.0.1/include`
- **g5** `-mcpu=970 -faltivec -maltivec -mabi=altivec -DQS_ARCH_PPC970` plus the g4 `-isystem`
- **lion** `-arch x86_64 -mmacosx-version-min=10.6 -O3 -Qunused-arguments`, no `-isysroot`. `LTO=1` opts into `-flto`, which measures nothing.
- **i386** `-arch i386 -mmacosx-version-min=10.4 -O3 -Qunused-arguments`, for Core Solo/Duo Macs with no 64-bit mode.
- **arm64** `-arch arm64 -mmacosx-version-min=11.0 -O2`. `build.sh` refuses it; `scripts/build-arm64.sh` builds it on the Apple Silicon Mac. Only slice on SDL2 (ADR 0003).

Load-bearing flags, not noise:
- G4 `-faltivec` (needed by the 10.3.9 Carbon headers) un-stamps the cpusubtype unless `build.sh` re-stamps it (ADR 0002).
- G4 `-isystem` supplies `<altivec.h>`, which `-isysroot` hides.
- `-DQS_ARCH_PPC970`: Apple gcc defines no `__ppc970__`, so 970 and 7400 are otherwise indistinguishable (ADR 0006).
- `-Wl,-w` hides cosmetic `-mlong-branch` warnings from Apple's `crt1.o`/`crt2.o`.

`BUILD_PG=1` adds `-pg` to the g3 build (~3-5% cost); exit with `+timedemo demoN +quit`, SIGKILL writes no `gmon.out`.

## Bundle

`Info.plist`, nib, source patches, `install_name_tool` fixup, layout and icon: ADR 0010. SDL rebuild recipes: [`SDL-rebuild.md`](../MacOSX/SDL-rebuild.md), once per version bump.
