# 2. Every PowerPC slice carries its exact cpusubtype, and the build asserts it

Date: 2026-08-20
Status: accepted

## Context

Apple's `gcc-4.0` normally propagates `-mcpu=750/7400/970` into the Mach-O
header's cpusubtype field. It does not do so reliably, and nothing in the build
complains when it fails.

A generic `ppc (ALL)` slice is not merely imprecise, it is a launch blocker.
Panther's lax 2003 `dyld` accepts it, but the **Tiger and Leopard kernel
mis-grade a fat of `[ppc ALL, ppc7400, ppc970]` on a 750 host and refuse to exec
it at all**. Proven on hardware by the sister Half-Life port, whose v1.0.0 could
not launch on the G3 under Tiger for exactly this reason and was fixed by
re-stamping to `ppc750`.

`NXFindBestFatArch` grades PowerPC subtypes in the order
`7450 > 7400 > 750 > 604e > 604 > 603ev > 603e > 603 > ALL`, so an exactly
stamped slice always wins over a generic one where both are present
(`docs/research/fat-binary-feasibility.md` §1; LAMEVMX and TenFourFox are the
precedent for a three-PowerPC-subtype fat).

## Decision

**Assert the exact cpusubtype after every PowerPC build and re-stamp the header
if the compiler drifted** (`scripts/build.sh`, "exact cpusubtype enforcement").

- Expected: `ppc750` = 9, `ppc7400` = 10, `ppc970` = 100.
- The cpusubtype is the 4-byte big-endian field at offset 8 of the Mach-O
  header. The re-stamp writes it directly. Idempotent, and it fails loudly if
  the stamp does not take.
- Verify by hand with `lipo -detailed_info build/quakespasm-fat`: it must list
  `CPU_SUBTYPE_POWERPC_750 / _7400 / _970`, never `_ALL`.

**Do not trust `file(1)` for this.** Modern `file` prints subtype 9 as
`ppc_650`, and on an Apple Silicon workstation that made an old
`file | grep ppc_750` check in `make-dmg.sh` fail on a perfectly good four-arch
fat. `lipo -archs` reads the Mach header directly and is authoritative.

## The trap that made this necessary

**`-faltivec` silently un-stamps the `ppc7400` subtype.** The G4 slice needs it:
the 10.3.9 SDK's Carbon `MachineExceptions.h` (pulled in via `AppController.m` /
`pl_osx.m`) declares an AltiVec `vector` field and will not parse without
Apple's context-sensitive `vector` keyword, which `-maltivec` alone does not
enable. Adding `-faltivec` alongside `-mcpu=7400 -maltivec -mabi=altivec`
produced a slice stamped generic `ppc (ALL)`. `lipo -info` was the only signal;
the build exited 0 and the binary looked runnable. Recorded 2026-07-25.

The same class of failure comes from a build race: running `scripts/build.sh g3`
and `g4` in parallel has both rsync to the same `quakespasm/Quake/` tree on the
build host and `make -j2` in it, so the `.o` files alias, and the resulting
binary carries the wrong CPU subtype and crashes Panther during AppKit NIB init.
`build.sh` takes a flock now; if that is bypassed, serialise by hand.

SDL has its own version of the trap: SDL's configure injects
`-force_cpusubtype_ALL`, which stamps generic `ppc` and would collide with the
existing Panther `ppc` slice, so the `ppc970` SDL cross-build strips it from the
generated Makefile before compiling (`MacOSX/SDL-rebuild.md`).

## Consequences

- The build is the check. A drifted stamp is corrected rather than shipped.
- Verification after every build is mandatory and is part of a wider rule: never
  trust "done" or exit 0. Confirm each `build/quakespasm-{g3,g4,g5,lion}` has a
  fresh mtime from this run and not a mix of old and new; run
  `lipo -detailed_info` on the fat; and after `deploy.sh`, read its md5
  comparison, which **warns rather than fails**, a WARN line means the target
  is not running what you built.
- A build that exits 0 and produces a runnable-looking binary can still be
  unlaunchable on a machine you did not test.
