# 1. Four slices: chosen by CPU capability and not by OS version

Date: 2026-08-20
Status: accepted

## Context

The app ships as one Mach-O fat binary. `dyld` picks a slice by **CPU subtype
alone** and cannot see the OS. A slice cannot encode "requires 10.5": if the CPU
matches, the machine gets that slice, and if the code inside needs a newer OS,
the process does not start. There is no fallback to a lower slice.

The fleet spans a 1999 Power Mac G3 on 10.3.9 to a 2019 iMac on Sequoia.

## Decision

**Ship four slices: `ppc750`, `ppc7400`, `ppc970`, `x86_64`**, composed by
`scripts/build-fat.sh` into `build/quakespasm-fat` (ADR 0004). Each is built by
`scripts/build.sh <g3|g4|g5|lion>`; the target names are chip family plus SDK,
never machine identity.

| Slice | Target | Compiler | SDK | min-OS | `CPUFLAGS` |
|---|---|---|---|---|---|
| `ppc750` | G3, no AltiVec | `gcc-4.0` | 10.3.9 | 10.3 | `-mcpu=750 -O3` |
| `ppc7400` | G4 (7400 / 7450 / 7447A) | `gcc-4.0` | 10.3.9 | 10.3 | `-mcpu=7400 -faltivec -maltivec -mabi=altivec -O3 -mtune=7450` |
| `ppc970` | iMac G5 on Leopard | `gcc-4.0` | 10.5 | 10.5 | `-mcpu=970 -maltivec -mabi=altivec -O3 -DQS_ARCH_PPC970` |
| `x86_64` | Intel | `clang` | Lion default | 10.6 | `-arch x86_64 -O3 -Qunused-arguments` |

**OS floors follow from that, and two of them were deliberately lowered:**

| CPU | Slice | OS needed | Tested on |
|---|---|---|---|
| G3 (750) | `ppc750` | 10.3.9 or later | 10.3.9 and 10.4.11 |
| G4 (7400/7450/7447A) | `ppc7400` | 10.3.9 or later | 10.4.11 |
| G5 (970) | `ppc970` | **10.5 Leopard only** | 10.5.8 |
| Intel 64-bit | `x86_64` | 10.6 or later | 10.7.5 and 15.7 |

- **The G4 slice moved to the 10.3.9 SDK at min-10.3** (issue #1). A G4 booted
  on Panther is handed `ppc7400` regardless of its OS and cannot fall back to
  the min-10.3 `ppc750`. AltiVec codegen is orthogonal to the SDK (it comes from
  `-mcpu=7400 -maltivec`, and the 750 never sees this slice), so the Tiger G4s
  give nothing up; verified by bench. Two costs came with the SDK move, both in
  `scripts/build.sh`: `<altivec.h>` is a compiler header, not an SDK one, and
  `-isysroot` confines the search to the sysroot, so the G4 build adds
  `-isystem /usr/lib/gcc/powerpc-apple-darwin10/4.0.1/include`; and `-faltivec`
  is required, which has its own hazard (ADR 0002).
- **The Intel slice moved to min-10.6** (issue #4). Same argument: a 64-bit
  Intel Mac left on Snow Leopard gets `x86_64` or nothing. Lion's SDK weak-links
  correctly for a 10.6 target and the bundled codec dylibs are already built at
  min 10.6. The engine is plain C, so the libc++-on-10.6 problem that pins the
  sister Half-Life port at 10.7 does not apply. **10.6 itself is untested**,
  there is no Snow Leopard machine in the fleet.
- **`ppc970` exists for scheduling, not compatibility.** The 970 has AltiVec, so
  it could run `ppc7400`, but its deep out-of-order pipeline has different
  AltiVec latencies than the 7450. It is a 32-bit ABI build (`-arch ppc`, not
  `ppc64`); Leopard runs the 32-bit slice fine and there is no need for 64-bit
  GPRs. Apple's gcc defines only `__VEC__` / `__ALTIVEC__` / `__ppc__` for
  `-mcpu=970` and no `__ppc970__`, so the slice is indistinguishable from
  `ppc7400` at compile time; `-DQS_ARCH_PPC970` is the hook `host.c` uses to
  pick the right config baseline (ADR 0006).
- **Anything that depends on the OS rather than the CPU is decided at runtime**,
  in config (ADR 0006) or on a renderer-string check (ADR 0007), never by adding
  a slice.

## Alternatives rejected

**A slice per machine.** Three G4 machines (sawtooth 7400, quicksilver 7450,
mini-g4 7447A) share `ppc7400`; the 7450 and 7447A run 7400-baseline code
happily. Two Intel machines share `x86_64`. Machine differences are config, not
code.

**An `i386` slice.** 32-bit-only Intel Macs (Core Solo / Core Duo, 2006) get no
slice at all. There is no such machine in the fleet to build or test one on.

**An `arm64` slice.** Not shipped. Apple Silicon runs `x86_64` under Rosetta 2.
Commit `fd507839` removed the two reasons one could not be built, but did not
add it: `net_main.c` was missing its `net_dgrm.h` include (gcc 4.0 accepts the
implicit declaration with a warning; clang 21 rejects it), and the vendored
`MacOSX/SDL2.framework` had an invalid ad-hoc signature on its arm64 slice, so
macOS SIGKILLed any process loading it with a CODESIGNING / Invalid Page crash
and no output at all. Re-signed ad-hoc, the client builds and runs on Apple
Silicon. The fuse is still not done, and the blocker is now SDL: a shipped arm64
slice would be the only one on SDL2 (ADR 0003).

**One PowerPC slice with runtime AltiVec dispatch.** `-maltivec` changes the ABI
globally: vector-register save and restore in prologues, and alignment. So the
engine cannot be compiled with `-maltivec` throughout and gated at runtime, the
G3 would crash on the first vector-aware function epilogue. Static initialisers
and file-scope vector constants are the obvious footgun: a
`const vector float foo = …` in a `-maltivec` translation unit runs
unconditionally at module load on a G3 and explodes. Runtime dispatch is more
work than shipping two PowerPC slices in one fat
(`docs/research/fat-binary-feasibility.md` §3).

**A `ppc970` slice for compatibility rather than scheduling.** The Half-Life
sister port dropped its `ppc970` because leopard-SDL2 made the G5 unable to boot
on 10.3/10.4. Here the G5 slice is 10.5-only by design and the README says so:
that row is a real floor, not a gap in testing.

## Consequences

- One disk image installs on every supported Mac and the same `.app` bundle is
  shipped byte-for-byte to all of them.
- The `ppc970` slice makes the G5 a 10.5-only machine. A G5 on Tiger or Panther
  is handed a slice it cannot run.
- Two rows in the README are honest about the gap between what is built and what
  is tested: **a G4 on Panther and an Intel Mac on Snow Leopard should both work
  and neither has been run on hardware.**
- `MacOSX/SDL.framework` must cover the same ground (ADR 0003), and it does, with
  a different slice split: `x86_64 i386 ppc ppc970`.
