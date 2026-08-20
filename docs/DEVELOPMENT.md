# Development reference — build path, build host, hot files

Detail behind the root [`CLAUDE.md`](../CLAUDE.md). Decisions and their evidence
are in [`adr/`](adr/README.md); per-target compiler flags and toolchain paths are
in [`MacOSX/CLAUDE.md`](../MacOSX/CLAUDE.md); per-script contracts are in
[`scripts/CLAUDE.md`](../scripts/CLAUDE.md) and
[`scripts/README.md`](../scripts/README.md).

## Build path

`Quake/Makefile.darwin`, with `MACH_TYPE` set and SDK plus `-mcpu` injected via
`CPUFLAGS` / `LDFLAGS`. Not the Xcode project (ADR 0004). Four slices, one per
`scripts/build.sh` target, lipo'd by `build-fat.sh` (ADR 0001, ADR 0004).

`prereqs/` vendors the installers (Xcode 3.2.6 DMG, Xcode 2.5 DMG for the 10.3.9
SDK, SDL 1.2.15 source), about 5 GB, gitignored. Its README carries the download
URLs, the MD5s, and the extraction dance both Xcode installers need on Lion.
Don't push these to a free GitHub remote without git-lfs.

## Multi-tenancy on the Intel minis

Each mini hosts this port and the Quake II sister port at once. Isolation:

| Resource | QuakeSpasm | Q2 |
|---|---|---|
| Source rsync target | `mini-intel:quakespasm/` | `mini-intel:quake2/` |
| `make` cwd | `mini-intel:quakespasm/Quake/` | `mini-intel:quake2/` |
| Local flock | `~/quakespasm/build/.build.lock` | `~/quake2/build/.build.lock` |
| Local build outputs | `~/quakespasm/build/quakespasm-*` | `~/quake2/build/q2-*` |

Shared read-only: `/Developer/SDKs/{MacOSX10.3.9,MacOSX10.4u,MacOSX10.5}.sdk`,
`/usr/bin/{gcc-4.0,clang}`. **Never modify.**

Concurrent builds are safe (separate dirs, separate locks), though serial is
faster than 2× concurrent on a 2-core Core 2 Duo. Host arbitration across repos
is `pick-build-host.sh` (ADR 0005).

Tell-tale of accidental conflation: `build.sh` ever rsyncing to `mini-intel:~/`
or `mini-intel:quake2/` overwrites Q2. It hard-codes `mini-intel:quakespasm/`;
never rely on a relative or env-derived path.

## Hot files (optimisation phase)

Targets for a future optimisation round. There is no current plan; do a fresh
evidence pass first.

- `Quake/mathlib.c:276,281` — `VectorLength`, `VectorNormalize` use scalar
  `sqrt`. Target for `frsqrte` (~6 cycles vs ~30, base PowerPC).
- `Quake/snd_mix.c:472,498` — sound mixer hot loops. AltiVec, G4 and G5 only.
- `Quake/gl_texmgr.c` — `TexMgr_LoadImage8` 8→32-bit expansion at level load.
  Load-time, not per-frame.

Profiling tooling: `/usr/bin/sample` on Panther through Lion (no Xcode needed),
captured by `scripts/profile-pass.sh`; see
[`../benchmarks/profiles/README.md`](../benchmarks/profiles/README.md) for the
capture pattern, how to read the format, and why OpenGL Profiler is unusable on
Tiger (Xcode 2.5 ships Profiler v3.4(78) against Tiger 10.4.11's v3.1(33) system
nub, and the mismatch crashes it at attach).
