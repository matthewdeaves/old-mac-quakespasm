# 4. The fat binary is composed by lipo from four separate builds, not one pass

Date: 2026-08-20
Status: accepted

## Context

Apple's toolchain can build a universal binary in one invocation,
`gcc -arch ppc -arch x86_64 ...`. That is the obvious way to do it and it does
not work here.

## Decision

**`scripts/build-fat.sh` runs `scripts/build.sh g3`, `g4`, `g5` and `lion`
sequentially, then `lipo -create`s the four results into
`build/quakespasm-fat`.** That fat is the only binary `deploy.sh` ships;
`build.sh` exists as its sub-step and for diagnosing a one-slice compile error.

**Sub-builds are serial, never parallel.** They share the build host's
`quakespasm/Quake/` tree, and `make clean` plus `-j2` aliases the `.o` files
between them. The result is a binary stamped with the wrong CPU subtype
(ADR 0002). `build.sh` takes a flock per invocation; `build-fat.sh` claims one
build host up front and holds it for all four slices, because the slices
accumulate in that host's tree and drifting onto a second mini would lipo an
incomplete set.

**`QS_PORT_VERSION` is resolved once** in `build-fat.sh` and exported so all four
slices carry the identical stamp. Default is `git describe --tags --always
--dirty`, computed on the orchestration host because the rsync excludes `.git`.
`Makefile.darwin` turns a non-empty token into `-DQUAKESPASM_VER_SUFFIX`, so the
binary self-identifies as e.g. `QuakeSpasm 0.97.0-oldmac-v1.9`, overriding the
`#ifndef`'d suffix in `quakedef.h`. Bare `make` with an empty token keeps
upstream parity. **Tag the release commit before building**, or the stamp reads
`v1.9-2-g…-dirty`. `make-dmg.sh` stamps the same value into the bundle's
`Info.plist`, because the static plist carries upstream's engine version
(0.97.0), which never changes between releases and so identifies nothing.

**Bump the version for every build that gets deployed or released.** The stamp
is the only way to confirm from a running copy which build is on a machine.

## Alternatives rejected

**One `gcc -arch … -arch …` pass.** Enumerated in
`docs/research/fat-binary-feasibility.md` §7:

- Three different SDKs are in play (10.3.9, 10.5, Lion default) and gcc supports
  one `-isysroot` per invocation.
- Two different compilers are in play, `gcc-4.0` for PowerPC and `clang` for
  x86_64.
- `__ALTIVEC__` must be set for `ppc7400` and `ppc970` and not for `ppc750`.
- Each slice has its own `-mmacosx-version-min` (ADR 0001).

**The Xcode project** (`MacOSX/QuakeSpasmPPC.xcodeproj`). Needs Xcode 3.2+, does
not differentiate G3 from G4, and is more annoying than the makefile. The build
path is `Quake/Makefile.darwin` with `MACH_TYPE` set and SDK plus `-mcpu`
injected through `CPUFLAGS` / `LDFLAGS`.

## Consequences

- Per-slice flags are free. Any slice can move SDK, compiler or floor without
  disturbing the others, which is what made the min-10.3 G4 and min-10.6 Intel
  changes cheap (ADR 0001).
- `lipo -create` on the four is clean: zero warnings, about 5 KB of padding
  overhead on top of the sum of the slices (`fat-binary-feasibility.md` §1).
- A full fat build is four sequential compiles on one 2-core Core 2 Duo.
- A slice that failed to build is a slice missing from the fat, so the
  `lipo -detailed_info` check after every build is load-bearing (ADR 0002).
