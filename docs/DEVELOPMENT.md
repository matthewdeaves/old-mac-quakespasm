# Development reference: build path, build host, hot files

Detail behind the root [`CLAUDE.md`](../CLAUDE.md). Decisions and their evidence
are in [`adr/`](adr/README.md); per-target compiler flags and toolchain paths are
in [`MacOSX/CLAUDE.md`](../MacOSX/CLAUDE.md); per-script contracts are in
[`scripts/CLAUDE.md`](../scripts/CLAUDE.md) and
[`scripts/README.md`](../scripts/README.md).

## Build path

`Quake/Makefile.darwin`, with `MACH_TYPE` set and SDK plus `-mcpu` injected via
`CPUFLAGS` / `LDFLAGS`. Not the Xcode project (ADR 0004). Six slices: five
`scripts/build.sh` targets plus `build-arm64.sh`, lipo'd by `build-fat.sh` (ADR 0001, ADR 0004).

`prereqs/` vendors the installers (Xcode 3.2.6 DMG, Xcode 2.5 DMG for the 10.3.9
SDK, SDL 1.2.15 source), about 5 GB, gitignored. Its README carries the download
URLs, the MD5s, and the extraction dance both Xcode installers need on Lion.
Don't push these to a free GitHub remote without git-lfs.

## Multi-tenancy on the Intel minis

Each mini hosts this port and the Quake II sister port at once. Isolation:

| Resource | QuakeSpasm | Q2 |
|---|---|---|
| Source rsync target | `mini-intel:oldmac/quakespasm/src/` | `mini-intel:oldmac/quake2/` |
| `make` cwd | `mini-intel:oldmac/quakespasm/src/Quake/` | `mini-intel:oldmac/quake2/` |
| Local flock | `<repo>/build/.build.lock` | `<repo>/build/.build.lock` |
| Local build outputs | `<repo>/build/quakespasm-*` | `<repo>/build/q2-*` |

Shared read-only: `/Developer/SDKs/{MacOSX10.3.9,MacOSX10.4u,MacOSX10.5}.sdk`,
`/usr/bin/{gcc-4.0,clang}`. **Never modify.**

Concurrent builds are safe (separate dirs, separate locks), though serial is
faster than 2× concurrent on a 2-core Core 2 Duo. Host arbitration across repos
is `pick-build-host.sh` (ADR 0005), run via `scripts/shared.sh pick-build-host.sh`
(#68).

Tell-tale of accidental conflation: `build.sh` ever rsyncing to `mini-intel:~/`
or `mini-intel:quake2/` overwrites Q2. It hard-codes `mini-intel:quakespasm/`;
never rely on a relative or env-derived path.

## Shared fleet scripts (build-host#105 pin, #68)

This repo no longer carries copies of `pick-build-host.sh`, `pick-bench-host.sh`,
`deploy-dmg.sh`, `smoke-dmg.sh`, `bench-evidence.sh`, `bench-compare.sh`,
`lay-out-dmg.sh` or `clear-launch-quarantine.sh`. `shared-scripts.pin` (repo
root) names the `old-mac-build-host` revision they're fetched from; run any of
them as `scripts/shared.sh <name>.sh [args...]` (needs a sibling
`../old-mac-build-host` checkout, or `OLDMAC_BUILDHOST_REPO` set).
`source-stamp.sh`/`source-stamp-excludes.sh` stay real copies — the first is
sourced, not exec'd, so it can't go through the wrapper (`.claude/rules/
legacy-mac-hardware.md`); the excludes list is this port's own data, never
synced.

Two scripts need an explicit override every time, because they locate
port-specific files relative to their OWN path, which is the pin's read-only
cache once fetched (`~/.cache/retro-shared/<sha>/`), not this repo:

- **`bench-evidence.sh`** needs `BENCH_ADAPTER="$REPO_ROOT/scripts/bench-adapter.sh"`.
- **`deploy-dmg.sh`** / **`smoke-dmg.sh`** need `DMG_PORT_CONF="$REPO_ROOT/scripts/dmg-port.conf"`.
- **`deploy-dmg.sh`** additionally derives its `dist/*.dmg` lookup from its own
  path when given a bare version string (e.g. `v1.2.0`) — resolves to the
  wrong directory once pinned. Always pass a full path instead:
  `scripts/shared.sh deploy-dmg.sh <host> "$REPO_ROOT/dist/QuakeSpasm-OldMac-v1.2.0.dmg"`.
- **`deploy-dmg.sh`** also claims its own host lock via a co-located
  `pick-bench-host.sh` next to itself (`$SELF_DIR/pick-bench-host.sh`) rather
  than through `shared.sh`. On a stone-cold cache (deploy-dmg.sh is the very
  first pinned script run) that used to silently skip claiming the host — no
  error, no lock (build-host#118). Fixed at shared-v5: `shared.sh --resolve
  <script>` fetches a script into the cache and prints its path without
  exec'ing it, and `deploy-dmg.sh` now pre-warms its own `pick-bench-host.sh`
  dependency through `$RETRO_SHARED_WRAPPER --resolve` before re-execing
  under it. No manual cache-warming call needed as of shared-v5.

`deploy.sh`'s own remote-scp use of `clear-launch-quarantine.sh` (staging it
onto a target Mac that has no `old-mac-build-host` checkout to resolve the
pin itself) pre-warms the cache with a harmless no-arg call and scp's the
resolved cache file directly — see the comment at the call site.

## Hot files (optimisation phase)

Targets for a future optimisation round. There is no current plan; do a fresh
evidence pass first.

- `Quake/mathlib.c:276,281`, `VectorLength`, `VectorNormalize` use scalar
  `sqrt`. Target for `frsqrte` (~6 cycles vs ~30, base PowerPC).
- `Quake/snd_mix.c:472,498`, sound mixer hot loops. AltiVec, G4 and G5 only.
- `Quake/gl_texmgr.c`, `TexMgr_LoadImage8` 8→32-bit expansion at level load.
  Load-time, not per-frame.

Profiling tooling: `/usr/bin/sample` on Panther through Lion (no Xcode needed),
captured by `scripts/profile-pass.sh`; see
[`../benchmarks/profiles/README.md`](../benchmarks/profiles/README.md) for the
capture pattern, how to read the format, and why OpenGL Profiler is unusable on
Tiger (Xcode 2.5 ships Profiler v3.4(78) against Tiger 10.4.11's v3.1(33) system
nub, and the mismatch crashes it at attach).
