# Fat (Universal) Binary Feasibility for QuakeSpasm PPC + Intel

> Research-only report drafted by an investigation agent on 2026-05-08
> at the user's request. Goal: determine what it takes to ship a single
> universal binary covering G3 (PPC 750), G4 (PPC 7400 + AltiVec), and
> Intel x86_64 (Mac mini, Lion 10.7) so one `Quakespasm.app` bundle can
> deploy to all three. **Implementation deferred** to round-v4 release
> packaging (per user direction: end-of-round code review and FPS-squeeze
> work first, then fat-binary tooling).

## 1. `lipo` merge feasibility

**Verified working.** On Lion (`/usr/bin/lipo`), `lipo -create` merges
all three of `build/quakespasm-{g3,g4,lion}` into a single 3-slice
universal binary with zero warnings:

```
$ lipo -create quakespasm-g3 quakespasm-g4 quakespasm-lion -output fat-all
$ file fat-all
fat-all: Mach-O universal binary with 3 architectures
fat-all (for architecture ppc750):  Mach-O executable ppc
fat-all (for architecture ppc7400): Mach-O executable ppc
fat-all (for architecture x86_64):  Mach-O 64-bit executable x86_64
```

Fat header is the standard `0xcafebabe` magic with `nfat_arch=3`,
slices page-aligned at 4 KB. Sum of three slices: 749352 + 753188 +
890704 = 2,393,244 bytes ≈ 2.28 MB; fat is 2,398,032 bytes — only
~5 KB padding overhead from page alignment.

**Min-SDK / version-min compatibility:** A non-issue in practice for
this build. None of the three slices currently embed an
`LC_VERSION_MIN_MACOSX` load command — gcc-4.0 predates it (added in
Xcode 4.2), and Lion's `clang 1.7` doesn't emit it either despite
`-mmacosx-version-min=10.7`. Each slice carries `LC_LOAD_DYLINKER` +
`LC_UNIXTHREAD` (old-style) and that's it.

**PPC-32 + x86_64 coexistence:** No restriction. Historical
"PPC + i386" was just the common Apple-era shape; the fat format keys
on `(cputype, cpusubtype, offset, size, align)` records.
`ppc + x86_64` works the same way.

## 2. Two PPC slices in one binary

**Yes — explicitly supported, and verified.** Mach-O's fat header keys
on `(cputype, cpusubtype)` together, not just `cputype`. So
`(PPC, 750)` and `(PPC, 7400)` are distinct entries and `lipo -create
g3 g4` succeeds. lipo *does* refuse to add a duplicate `(PPC, 750)`
slice ("have the same architectures and can't be in the same fat
output file"), but distinct subtypes are fine.

Apple's documentation backs this: cctools' `NXFindBestFatArch` source
defines the PPC grading order as
`7450 > 7400 > 750 > 604e > 604 > 603ev > 603e > 603 > ALL`. TenFourFox
documented LAMEVMX as a real-world 3-PPC-subtype shipping example
(G3/G4/G5 from one fat).

**Implications for "ship one PPC slice":**

- **Ship `ppc7400` only:** Will *not* be cleanly selected on a G3 host.
  Per the grading table, a host with cpusubtype 750 will skip a 7400
  slice. The CLAUDE.md "biggest landmine" section describes the
  observed failure mode when a G3 ends up running a `ppc7400`-stamped
  binary: Panther's dyld is permissive enough to load it anyway, but
  the runtime crashes inside AppKit NIB init when it hits a G4-only
  instruction. That's not academic — it's already happened on this
  project from build races.
- **Ship generic `ppc` (no `-mcpu` / `-mtune`):** Loads on both. Works
  correctly on both. But leaves AltiVec on the floor unless we add
  runtime dispatch (option 3 below).
- **Ship both `ppc750` *and* `ppc7400` slices in the same fat:** Each
  PPC host picks its preferred slice automatically. **This is the right
  answer for QuakeSpasm.**

## 3. Runtime AltiVec dispatch alternative

If we instead wanted a single generic-PPC slice with runtime AltiVec
dispatch via `sysctlbyname("hw.optional.altivec")`, it's *technically*
possible but ugly:

- `-maltivec` changes ABI globally (vector-register save/restore in
  prologues, alignment), so **you can't compile the whole engine with
  `-maltivec`** and rely on runtime gating. The G3 runtime would crash
  on the first vector-aware function epilogue.
- The clean approach is to compile AltiVec hot-paths (currently in
  `Quake/snd_mix.c`, `Quake/r_brush.c`, `Quake/r_alias.c`,
  `Quake/gl_rmisc.c`, `Quake/snd_dma.c`) into separate `.o` files with
  `-maltivec` and the rest of the engine without; link both into one
  PPC binary; gate calls on `hw.optional.altivec`.
- Per-TU `-maltivec` works in gcc-4.0 (per-file CFLAGS in the
  Makefile). But you also need to make sure no inlinable function
  header in those TUs reaches a non-AltiVec TU as a header — vector
  types in struct definitions would poison.
- Static initializers and global vector constants are the obvious
  footgun: a `const vector float foo = ...` at file scope in an
  `-maltivec` TU runs unconditionally at module load on a G3 and
  explodes.

**Verdict:** runtime dispatch is more work than just shipping two PPC
slices in one fat. The two-slice approach also wins because it lets
each slice keep its `-mtune` and SDK independent.

## 4. SDL.framework story for fat

**Verified: `lipo -replace ppc` works.** The bundled
`MacOSX/SDL.framework/Versions/A/SDL` is already fat (`x86_64 + i386 +
ppc`, all built against 10.6 SDK). The Panther-incompatible PPC slice
can be permanently swapped:

```
$ lipo SDL -replace ppc MacOSX/SDL-panther.dylib -output SDL-fat-panther
$ file SDL-fat-panther
SDL-fat-panther: Mach-O universal binary with 3 architectures
  (for architecture x86_64): Mach-O 64-bit dynamically linked shared library x86_64
  (for architecture i386):   Mach-O dynamically linked shared library i386
  (for architecture ppc):    Mach-O dynamically linked shared library ppc
```

The panther dylib's install_name already matches the framework's
expected path (`@executable_path/SDL.framework/Versions/A/SDL`).

**Caveat for G4:** The framework's PPC slice was historically used on
G4/Tiger without issue (per CLAUDE.md: "G4 runs the bundled SDL fine"
— meaning the 10.6-SDK-built PPC slice works on Tiger). But
`SDL-panther.dylib` was specifically built `--disable-altivec` and
against the 10.3.9 SDK. **Open question for the user:** does
Panther-built SDL run cleanly on Tiger? If yes, swapping the PPC slice
with the panther dylib once gives a single PPC SDL slice that works on
both G3 and G4 — and `deploy.sh` no longer needs the per-target swap.
If no (e.g. Tiger expects newer Quartz hooks), we'd need a separate
Tiger-G4 SDL build *and* lipo two PPC subtypes into the framework SDL
too — at which point the framework needs to mirror the engine's
dual-PPC layout.

## 5. min-os-version compatibility

In this codebase, **moot**: none of the three slices embed
`LC_VERSION_MIN_MACOSX` (verified via `otool -l` on each slice — only
LC_UNIXTHREAD/LC_LOAD_DYLINKER appears, because both gcc-4.0 and
Lion's clang 1.7 predate that load command). Each slice gets selected
purely on `(cputype, cpusubtype)` match plus dyld being able to
resolve the LC_LOAD_DYLIB references on the running OS.

For completeness: when `LC_VERSION_MIN_MACOSX` is present, dyld checks
it at load time and refuses to map a slice whose minimum is higher
than the running OS, falling back to the next-best slice. Behaviour is
graceful (load failure with diagnostic, never a fault) on 10.6+. On
10.3/10.4 the load command didn't exist so the question doesn't arise.

## 6. Apple's official answer

- **4-way fat (`ppc + ppc64 + i386 + x86_64`) was an explicit
  Apple-supported configuration**, introduced with Xcode 2.4 (per
  Wikipedia's "Universal binary" article and Apple's "Compiling Your
  Code in OS X" porting docs).
- **Apple did not, to my knowledge, ship dual-PPC-subtype Apple
  binaries** in their own products — they shipped generic `ppc` for
  the OS-vended PPC code and let `-mtune` decide micro-arch tuning. So
  the *pattern* is well-trodden by 3rd parties (LAMEVMX is the
  canonical example) but not blessed by Apple shipping it themselves.
- The fat format itself has no known hard slice-count limit; TenFourFox
  argues 5-way is realistic. Practical limit is binary size.

## 7. Practical Makefile.darwin / build.sh shape

Apple's preferred single-pass approach (`-arch ppc -arch ppc64 -arch
i386 -arch x86_64` on the same `gcc` invocation) **does not work for
our case** because:

1. We need *different SDKs* (10.3.9 for ppc750, 10.4u for ppc7400, Lion
   default for x86_64). gcc only supports one `-isysroot` per
   invocation.
2. We need *different compilers*: `gcc-4.0` for both PPC slices, `clang`
   for x86_64.
3. The `__ALTIVEC__` macro must be set for the ppc7400 slice and unset
   for ppc750.
4. Apple's docs explicitly call out the "configuration-time data
   structure" caveat: "the tool must be configured and compiled for
   each architecture as separate executables, then glued together
   manually using lipo."

**Multi-pass pattern (recommended):**

1. `scripts/build.sh g3`, `g4`, `lion` keep their current contract —
   each produces `build/quakespasm-<target>` exactly as today
   (per-target `Makefile.darwin clean` between, plus the existing
   flock).
2. New `scripts/build.sh fat` (or a separate `scripts/build-fat.sh`):
   drives all three sub-builds sequentially under the same flock, then
   runs a final `lipo -create build/quakespasm-{g3,g4,lion} -output
   build/quakespasm-fat` step. No Makefile changes.
3. Same shape for SDL: a one-time `lipo -replace ppc` of
   `MacOSX/SDL.framework/Versions/A/SDL` with
   `MacOSX/SDL-panther.dylib`, committed into the repo as the new
   bundled framework. `deploy.sh` no longer special-cases G3.
4. `scripts/deploy.sh` then becomes target-agnostic: same
   `Quakespasm.app` bundle (containing `quakespasm-fat` renamed to
   `quakespasm`, plus the now-uniform fat SDL) gets shipped to G3 / G4
   / Lion. Each host's dyld picks its slice automatically.

**Pitfalls:**

- Each PPC sub-build still needs the existing flock — not because they
  race against each other (they're now serialized), but to prevent the
  `make clean` in step 1 from racing if someone runs a non-fat
  `build.sh g3` concurrently.
- The `install_name_tool` step in `build.sh` operates on the per-arch
  standalone before lipo merge — keep it where it is.
- Sanity check after lipo: `lipo -info build/quakespasm-fat` must show
  `ppc750 ppc7400 x86_64` exactly. Also `file build/quakespasm-fat |
  grep -c ppc` must be 2.

## 8. Tradeoff summary

**Verdict: not worth it for the development phase. Probably worth it
as a release-time packaging step.**

Mechanically it works — every experiment lipo'd cleanly, dyld will
pick the right PPC slice, SDL's PPC slice can be permanently swapped
to the Panther-compatible build. The pure-engineering cost is small:
one extra `scripts/build-fat.sh` plus a `lipo -replace` on the bundled
SDL, both well under a day's work.

What it buys: one `Quakespasm.app` bundle that ships to G3, G4, and
Lion verbatim. Nice-to-have for a public "QuakeSpasm-PPC v1.0" release
artifact.

What it costs *during* the optimization round: the ability to bisect
cheaply. The current 3-binary deploy is the bisectable A/B comparison
shape CLAUDE.md prescribes. Per-target `quakespasm-{g3,g4,lion}`
artifacts remain readable in `file` output, profileable in isolation,
and individually checkpointable in `benchmarks/results.csv`. A fat
binary mid-round gives up nothing measurable but obscures which slice
is actually loaded on each host and complicates the `parse_qconsole.py`
story slightly.

**Recommendation:** defer fat-packaging to end-of-round release prep.
Add `scripts/build-fat.sh` then; until then, the existing 3-binary
path is strictly better for the iteration loop.

## Open questions flagged for user

1. **G4-vs-G3 SDL coverage:** does `MacOSX/SDL-panther.dylib` (built
   against 10.3.9 SDK, `--disable-altivec`) run correctly on G4/Tiger?
   If yes, `lipo -replace ppc` solves the SDL story permanently. If
   no, a fat SDL might need *two* PPC slices, which Apple's framework
   loader probably tolerates but isn't verified empirically. Quick
   test on the G4 would settle it.
2. **Lion `clang 1.7`'s missing `LC_VERSION_MIN_MACOSX`:** absence
   noted but not deeply investigated. On Lion itself it doesn't matter
   (the binary already runs there). Whether dyld on a hypothetical
   10.8+ machine would refuse it is untested — irrelevant to the
   project's targets but worth flagging if the artifact ever escapes
   into the wild.

## Sources

- [TenFourFox: The Super Duper Universal Binary](http://tenfourfox.blogspot.com/2020/06/the-super-duper-universal-binary.html)
- [Wikipedia: Universal binary](https://en.wikipedia.org/wiki/Universal_binary)
- [Apple cctools `arch.3` man page (NXFindBestFatArch grading)](https://opensource.apple.com/source/cctools/cctools-358/man/arch.3.auto.html)
- [Mach-O ABI File Format Reference (mirror)](https://github.com/aidansteele/osx-abi-macho-file-format-reference)
