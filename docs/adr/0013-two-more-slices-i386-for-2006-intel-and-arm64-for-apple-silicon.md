# 13. Two more slices: i386 for 2006 Intel, arm64 for Apple Silicon

Date: 2026-08-20
Status: accepted (built; arm64 and i386 not yet run on hardware)

Amends ADR 0001, which described four slices. There are now six.

## Context

ADR 0001 establishes the rule that matters here: **dyld grades a fat binary by
CPU subtype alone**, and there is no fallback to a lower slice. Two
consequences of that rule were being carried as if they were choices.

**32-bit-only Intel Macs got nothing.** The 2006 Core Solo and Core Duo
machines (Mac mini 1,1, iMac 4,1, MacBook 1,1, MacBook Pro 1,1) are the only
Intel Macs with no 64-bit mode. They are never handed the `x86_64` slice, and
there was no slice beneath it, so the app did not launch on them at all. The
release notes called this "have no slice and cannot run this", which is
accurate but was being read as a hardware limit rather than a missing build.

**Apple Silicon ran under Rosetta 2** because SDL 1.2 upstream never produced
an arm64 build, so there was no SDL 1.2 to link (ADR 0003).

## Decision

**Ship both, taking six slices in total: `ppc750`, `ppc7400`, `ppc970`,
`i386`, `x86_64`, `arm64`.**

### i386

Nothing exotic. Lion's clang targets it, and the two dependency sets were
already in place before this ADR was written: the bundled `SDL.framework`
carries `x86_64 i386 ppc ppc970`, and all ten codec dylibs carry
`ppc i386 x86_64 arm64`. Built by `scripts/build.sh i386`.

Floored at **10.4**, lower than the `x86_64` slice's 10.6. An i386-only Mac
may still be on Tiger or Leopard and there is no slice beneath this one to
catch it.

### arm64

The blocker was never the engine, it was that SDL 1.2 has no arm64 build. The
answer is that **a fat binary can carry a different SDL per slice**: each
slice has its own `LC_LOAD_DYLIB`. So the arm64 slice links the bundled
`SDL2.framework`, which already has an arm64 slice, while the other five keep
real SDL 1.2 untouched. `USE_SDL2=1` is a supported switch in
`Makefile.darwin`, not a patch.

Floored at **11.0**. No arm64 Mac shipped earlier, so a lower target would be
fiction.

## Two things that bite

**arm64 must be built on the orchestration Mac, never on a build mini.**
Lion's Xcode 4.6 predates arm64 by seven years. This is the one slice
`build.sh` cannot produce, so it gets its own driver, `scripts/build-arm64.sh`,
and `build.sh arm64` fails with a pointer to it rather than a confusing
toolchain error. Same split as the sister Half-Life port.

**Arch flags go through `CPUFLAGS`, never `CFLAGS`.** `Makefile.darwin`
declares `CFLAGS ?= -Wall -MMD` and then appends to it: `-DUSE_SDL2`, the
codec defines, the framework paths. A `CFLAGS` set on the make command line
wins over every one of those `+=` lines and silently drops them. The first
arm64 attempt did exactly that, and the result was an arm64 object set
compiled against the **SDL 1.2** API, which failed at link on
`SDL_WM_GrabInput` and `SDL_WM_SetCaption`. The error names an SDL 1.2 symbol,
so it reads like an SDL problem rather than a make-variable problem.

## arm64 is optional at fuse time

`build-fat.sh` requires the five mini-buildable slices and includes arm64 only
if `build/quakespasm-arm64` is present, saying which way it went either way. A
release built without ever running `build-arm64.sh` is a Rosetta 2 downgrade,
not a fault. `make-dmg.sh` asserts the five and reports arm64's presence
rather than requiring it.

The fuse itself still happens on the mini. Lion's `lipo` can **write** a
correct fat containing arm64 even though it cannot **name** the slice, printing
a numeric `cputype (16777228)`, and its `otool` and `install_name_tool` refuse
the file outright. So the verification runs on the orchestration Mac, whose
`lipo` is current. Lion's own report on a good arm64 fat looks like corruption.

## Ad-hoc signing, and why it is not cosmetic

`Makefile.darwin` runs `strip -S` as its last step, which invalidates any code
signature. On arm64 that is fatal rather than cosmetic: the kernel refuses to
exec an unsigned or badly-signed arm64 binary and the process dies on SIGKILL
with no diagnostic. `build-arm64.sh` re-signs ad-hoc **after** the strip and
runs `codesign --verify` rather than trusting the exit code. No other slice
needs this.

## Consequences

**Gained**

- Every Mac the project claims to support now actually has a slice, from a
  449 MHz G3 on 10.3.9 to Apple Silicon on current macOS.
- Apple Silicon runs native.

**Lost**

- Two more slices to build and keep honest, and the arm64 one cannot be built
  by the same host as the rest.
- The arm64 slice is the only one on SDL2, so SDL bugs can now differ by slice
  within one binary.

**Open**

- **Neither new slice has been run on hardware.** There is no 32-bit-only
  Intel Mac in the fleet at all, so `i386` is build-correct only and every
  value in `autoexec-i386.cfg` is set from documented capability rather than
  measurement. The arm64 slice builds, signs and verifies, but has not been
  played.
- `autoexec-arm64.cfg` picks 1920x1080 rather than a Retina native mode on
  purpose, and that choice is unmeasured.
