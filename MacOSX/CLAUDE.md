# MacOSX/: toolchain and flags on the build host

Upstream's `Build_Instructions.md` covers the Xcode-project workflow, which is
not how this port builds. This file is the per-target flag reference. The
decisions behind it are ADR 0001 (slices and floors), ADR 0003 (SDL), ADR 0004
(the fat build model) and ADR 0010 (bundle and source patches).

## Toolchain on the Lion build minis

```
/usr/bin/gcc-4.0                Apple gcc 4.0.1 (build 5494), PowerPC cross
/usr/bin/clang                  Apple clang 1.7, LLVM 2.9-based, Intel native
/usr/bin/gcc-4.2                llvm-gcc-4.2.1, Intel fallback, unused
/Developer/SDKs/MacOSX10.3.9.sdk    G3 and G4 targets
/Developer/SDKs/MacOSX10.4u.sdk     present, no longer used by a shipped slice
/Developer/SDKs/MacOSX10.5.sdk      G5 target only (2026-08-29: the SDL
                                     framework's own dedicated ppc970 slice
                                     was removed, #39; see SDL-rebuild.md)
```

Read-only and shared with the Q2 port. **Never modify.**

## Per-target flags (as `scripts/build.sh` sets them)

- **g3** `-isysroot /Developer/SDKs/MacOSX10.3.9.sdk -mmacosx-version-min=10.3
  -arch ppc -mcpu=750 -O3`
- **g4** `-isysroot /Developer/SDKs/MacOSX10.3.9.sdk -mmacosx-version-min=10.3
  -arch ppc -mcpu=7400 -faltivec -maltivec -mabi=altivec -O3 -mtune=7450
  -isystem /usr/lib/gcc/powerpc-apple-darwin10/4.0.1/include`
- **g5** `-isysroot /Developer/SDKs/MacOSX10.5.sdk -mmacosx-version-min=10.5
  -arch ppc -mcpu=970 -maltivec -mabi=altivec -O3 -DQS_ARCH_PPC970`
- **lion** `-arch x86_64 -mmacosx-version-min=10.6 -O3 -Qunused-arguments`, no
  `-isysroot` (Lion's default toolchain SDK). Lion's kernel is `RELEASE_I386` on
  a Macmini2,1, but Core 2 Duo plus 10.7 user-space runs x86_64 binaries fine.
  `LTO=1` opts into `-flto`, which measures nothing (ADR 0005).
- **i386** `-arch i386 -mmacosx-version-min=10.4 -O3 -Qunused-arguments`, no
  `-isysroot`. For the 2006 Core Solo / Core Duo Macs, which have no 64-bit
  mode and so are never handed the x86_64 slice.
- **arm64** `-arch arm64 -mmacosx-version-min=11.0 -O2`. NOT built here: Lion's
  Xcode 4.6 predates arm64 by seven years, so `build.sh` refuses this target
  and `scripts/build-arm64.sh` builds it on the Apple Silicon orchestration Mac
  instead. It is also the only slice that links SDL2 rather than SDL 1.2
  (ADR 0003), and the only one at `-O2` rather than `-O3`.

Three flags on that list are load-bearing and easy to misread as noise: the G4's
`-faltivec` is required by the 10.3.9 SDK's Carbon headers and **un-stamps the
cpusubtype** unless `build.sh` re-stamps it (ADR 0002); the G4's `-isystem`
supplies `<altivec.h>`, a compiler header `-isysroot` would otherwise hide; and
`-DQS_ARCH_PPC970` exists because Apple gcc defines no `__ppc970__`, so the 970
slice is otherwise indistinguishable from the 7400 one at compile time
(ADR 0006).

`-Wl,-w` silences cosmetic `-mlong-branch which is no longer needed` warnings
from Apple's own `crt1.o` / `crt2.o` on PowerPC builds, so a real link warning
stands out.

`BUILD_PG=1` adds `-pg` to the g3 compile and link, so the binary writes
`gmon.out` on a clean exit. `-O3` is kept so the profile matches what ships;
`-pg` costs ~3-5% per call through mcount instrumentation. Use
`+timedemo demoN +quit` for a clean exit, SIGKILL writes no `gmon.out`.

## Bundle

`Info.plist` keys, the nib requirement, the four required source patches, the
`install_name_tool` fixup, the layout and the icon pipeline are all ADR 0010.
The fat-SDL rebuild recipes are [`SDL-rebuild.md`](SDL-rebuild.md); they are a
once-per-version-bump procedure and are not needed for normal work.
