# Development reference — build path, build host, codebase facts

Deeper detail behind the root [`CLAUDE.md`](../CLAUDE.md) summaries. Per-target
compiler flags, the required source patches, and bundle assembly are in
[`MacOSX/CLAUDE.md`](../MacOSX/CLAUDE.md); tooling contracts in
[`scripts/README.md`](../scripts/README.md) and [`scripts/CLAUDE.md`](../scripts/CLAUDE.md).

## Build path

`Quake/Makefile.darwin` with `MACH_TYPE=ppc` and SDK + `-mcpu` injected via
`CPUFLAGS`/`LDFLAGS`. **NOT** `MacOSX/QuakeSpasmPPC.xcodeproj` (needs Xcode 3.2+,
doesn't differentiate G3 from G4, more annoying than the makefile). Per-target
flags + bundle assembly: [`MacOSX/CLAUDE.md`](../MacOSX/CLAUDE.md).

Build TARGET names (`g3`/`g4`/`g5`/`lion`) = chip family + SDK, NOT machines. The
single `g4` binary serves three machines (sawtooth/quicksilver/mini-g4); `g5`
serves the iMac G5 (PowerMac8,x, Leopard 10.5.8); the `lion` binary serves two
(mini-intel/imac-2019). All four slices live in the one fat binary; dyld picks
per CPU subtype (ppc970 prefers the g5 slice, G4s fall back to ppc7400, the
universal ppc750 floor runs on any PPC).

**Release version stamping.** `build.sh` / `build-fat.sh` compute `QS_PORT_VERSION`
via `git describe --tags --always --dirty` on the orchestration host (the rsync excludes
`.git`, so the build host can't) and pass it as a quote-free make token;
`Makefile.darwin` turns a non-empty token into `-DQUAKESPASM_VER_SUFFIX`, so the
binary self-identifies as e.g. `QuakeSpasm 0.97.0-oldmac-v1.9` (overriding the
`#ifndef`'d suffix in `quakedef.h`). Bare `make` (empty token) keeps upstream
parity. Tag the release commit *before* building so the stamp is clean (`v1.9`,
not `v1.9-2-g…-dirty`).

`prereqs/` vendors the installers (Xcode 3.2.6 DMG, Xcode 2.5 DMG for 10.3.9 SDK,
SDL 1.2.15 source); ~5 GB total. Don't push to a free GitHub remote without
git-lfs.

## Multi-tenancy on mini-intel (shared with the Q2 sister project)

`mini-intel` is the cross-build host for both this port and the Q2 sister project
at `~/quake2/`. Isolation:

| Resource | QuakeSpasm uses | Q2 uses |
|---|---|---|
| Source rsync target | `mini-intel:quakespasm/` | `mini-intel:quake2/` |
| `make` cwd | `mini-intel:quakespasm/Quake/` | `mini-intel:quake2/` |
| Local flock | `~/quakespasm/build/.build.lock` | `~/quake2/build/.build.lock` |
| Local build outputs | `~/quakespasm/build/quakespasm-*` | `~/quake2/build/q2-*` |

Shared (read-only): `/Developer/SDKs/{MacOSX10.3.9.sdk,MacOSX10.4u.sdk}`,
`/usr/bin/{gcc-4.0,clang}`. **Never modify** — Q2 depends on the install and
reinstalling Xcode 3.2.6 + 2.5 from `prereqs/` is multi-hour recovery.

Concurrent builds are safe (separate dirs, separate locks). If Q2 is mid-compile,
prefer to wait — serial is faster than 2× concurrent on a 2-core Core 2 Duo, but
it's not a correctness issue.

Tell-tale of accidental conflation: `build.sh` ever rsyncing to `mini-intel:~/`
or `mini-intel:quake2/` overwrites Q2. `build.sh` hard-codes
`mini-intel:quakespasm/` — never rely on relative or env-derived paths.

## Codebase facts you can't grep for

**No software renderer.** QuakeSpasm dropped FitzQuake's software path; GL-only.
"Palette blit hot path" / "software inner loops" don't apply.

**No existing PPC-specific code (upstream).** No `__VEC__`, `<altivec.h>`,
`frsqrte`, asm anywhere upstream. Greenfield (the port adds PPC code; this notes
the *starting* point).

**Two `SSE` mentions are defensive, not SSE code.** `gl_model.c:1414` and
`gl_rlight.c:326` cast lightmap-extent calcs to `double` to dodge x87/SSE2
precision drift. Universally safe; nothing to patch.

## Hot files (optimisation phase)

Targets for a future optimisation round (there is no current plan — fresh
evidence pass first):

- `Quake/mathlib.c:276,281` — `VectorLength`, `VectorNormalize` use scalar
  `sqrt`. Target for `frsqrte` (~6 cyc vs ~30, base PPC).
- `Quake/snd_mix.c:472,498` — sound mixer hot loops. AltiVec (G4 only).
- `Quake/gl_texmgr.c` — `TexMgr_LoadImage8` 8→32 bit expansion at level load.
  Load-time, not per-frame.
