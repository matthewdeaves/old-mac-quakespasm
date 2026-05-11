# QuakeSpasm PPC port — guidance for Claude

Sticky facts loaded every session. **There is no current plan doc.**
The Round v2 → v11.1 plan is archived at
`docs/archive/PPC_PLAN_v2-v11.md` — read it for historical phase
decisions and reverted-experiment context, but don't treat it as a
roadmap. Any new optimisation work starts with a fresh evidence pass
(end-of-round bench grid, code review, static-analysis sweep) and a
new plan written from that evidence. Sub-area detail:

- `scripts/CLAUDE.md` — script contracts, reboot recovery, icon pipeline
- `MacOSX/CLAUDE.md` — bundle layout, Tiger/Panther Cocoa, required patches, fat-SDL recipe
- `scripts/README.md` — end-user-facing tooling + host matrix
- `docs/KNOBS.md` — toggleable cvar / cmdline knob inventory
- `docs/archive/PPC_PLAN_v2-v11.md` — archived working plan (rounds v2 → v11.1)
- `MISTAKES.md` — append-only log of approaches that broke. **Read before
  lighting up an idea that smells "easy" or "load-time only / zero risk".**

## Goal in one line

Best-looking QuakeSpasm port for G3 Panther + G4 Tiger + Lion Intel,
keeping framerate comfortably playable on each (≥ 60 fps on G4, ≥ 60 fps
on Lion, ≥ 20 fps on G3). Visual upgrades that cost 10–15% fps are in
scope when they leave the cell above its playability threshold. Lion +
iMac-2019 are also bench references — useful data points that separate
GPU-bound from CPU-bound effects across the GPU axis (R128 / GeForce2 MX
/ Radeon 9000/9200 / GMA 950 / Radeon Pro 580X).

## Toggleability + per-machine gating

**Toggleability is a hard requirement.** Every per-target visual / perf
knob must be flippable at runtime (cvar) or at launch (cmdline `-flag`)
so end-of-round code review can A/B individual contributions without a
rebuild. Inventory: `docs/KNOBS.md`.

**Per-machine gating is a legitimate pattern.** When an optimisation
helps some machines and hurts others, gate it — don't drop it. Three
mechanisms, most to least restrictive:

1. **Compile-time gate by build slice** — `#if (__ppc__ && !__VEC__)`
   for G3-only, `#if __VEC__` for G4, `#if __x86_64__` for Intel.
   Used when the runtime check itself would matter on the slice we
   want to skip, or when the code is incompatible with the slice
   (AltiVec intrinsics on G3). Example: Round v11
   `gl_aliasstate_cache` compiled out of G3 slice via
   `QS_DISABLE_ALIAS_STATE_CACHE` in `r_alias.c`.
2. **Per-machine autoexec** (`scripts/bundle/autoexec-<machine>.cfg` in
   the source tree → shipped inside `Quakespasm.app/Contents/Resources/`
   in the deployed bundle, loaded via CFBundle by `QS_ExecConfigFromBundle`
   at `host.c:53`; per-machine pick uses `sysctl hw.model` at
   `host.c:1024`). Right tool when the difference is hardware/driver.
   `bench.sh` passes `-noarchautoexec` for determinism, so autoexec
   state is NOT in effect during benches — use a compile-time gate or
   `EXTRA_CVARS=` if the gate matters to the bench.
3. **Runtime cvar / cmdline opt-out** — everywhere-available toggle
   for end-of-round A/B review.

Don't bury a beneficial change behind a runtime cvar if the
beneficiaries are 5/6 of the matrix — gate it to the regressor and
ship the wins.

## Tooling — DON'T reinvent inline

Full contracts in `scripts/CLAUDE.md`; host matrix in `scripts/README.md`.
Top of mind:

- `scripts/build.sh <g3|g4|lion>` — cross-compile or native, on mini-intel (per-slice; mostly called by build-fat.sh, also useful for diagnosing one-slice compile errors)
- `scripts/build-fat.sh` — 3-arch (ppc750+ppc7400+x86_64) lipo'd binary; this is the only binary we deploy
- `scripts/deploy.sh <machine>` — stage Quakespasm.app + ship to host. Always ships the fat binary; per-machine settings travel inside Contents/Resources/.
- `scripts/bench.sh <machine> <demo> <WxH> [runs]` — append to results.csv
- `scripts/parallel-bench.sh [--quick]` — full matrix concurrently
- `scripts/bench-and-commit.sh "<msg>" [--quick]` — clean tree + bench + commit
- `scripts/screenshot.sh <machine>` — visual A/B captures
- `ssh <host> '~/bin/qsreboot.sh'` — reboot the Mac when fullscreen kill
  wedged the display (one-time `qsreboot-setup.sh` per machine first)

Build TARGET names (`g3`/`g4`/`lion`) = chip family + SDK, NOT machines.
The single `g4` binary serves three machines (sawtooth/quicksilver/mini-g4);
the `lion` binary serves two (mini-intel/imac-2019).

`prereqs/` vendors the installers (Xcode 3.2.6 DMG, Xcode 2.5 DMG for
10.3.9 SDK, SDL 1.2.15 source); ~5 GB total. Don't push to a free
GitHub remote without git-lfs.

There's a `ppc-ops` skill (`.claude/skills/ppc-ops/SKILL.md`) and
`/bench` + `/deploy` slash commands that wrap these.

## Operational gotchas — every session

**Don't run `scripts/bench.sh` legs in parallel from one shell.**
Local ssh-stack contention can produce a wrong G3 fps reading (14.7
vs 23.1 fps for the same binary). Use `parallel-bench.sh` for the
proper concurrent matrix, or serial `bench.sh`.

**Don't run `scripts/build.sh g3` and `g4` in parallel.** Both rsync
to `mini-intel:quakespasm/` and `make -j2` in the same dir → `.o`
races → binary stamped with wrong CPU subtype → Panther crashes during
AppKit NIB init. `build.sh` flocks now; if you bypass, serialize.
After any build sanity-check `file build/quakespasm-g3` reports
`ppc_750` and `quakespasm-g4` reports `ppc_7400`. `parallel-bench.sh`
is fine — it parallelizes bench legs, not builds.

**Panther's `/bin/sleep` is integer-only.** `sleep 0.2` returns
immediately on 10.3 (Tiger fixes this). Poll loops on G3 must use
integer sleeps; `bench.sh` uses `sleep 1` for this reason.

**Killing the engine.** SDL/CoreAudio threads don't always answer
SIGTERM. Use `killall -KILL quakespasm` after a brief SIGTERM grace.
**Don't use `pkill`** — not on Tiger or Panther.

**Old-Mac SSH (Lion + PPC) needs legacy crypto.** `~/.ssh/config`
has the required `HostKeyAlgorithms +ssh-rsa`,
`PubkeyAcceptedKeyTypes +ssh-rsa`,
`KexAlgorithms +diffie-hellman-group-exchange-sha1[,group14-sha1[,group1-sha1]]`
and RSA key `id_rsa_tiger`. Ad-hoc `ssh user@ip` without these fails.

**`mini-intel` sleeps aggressively.** If `build.sh` fails with `ssh:
connect to host ... No route to host`, it's asleep — wake it and retry.

## Build path

`Quake/Makefile.darwin` with `MACH_TYPE=ppc` and SDK + `-mcpu` injected
via `CPUFLAGS`/`LDFLAGS`. **NOT** `MacOSX/QuakeSpasmPPC.xcodeproj`
(needs Xcode 3.2+, doesn't differentiate G3 from G4, more annoying than
the makefile). Per-target flags + bundle assembly: `MacOSX/CLAUDE.md`.

## Multi-tenancy on mini-intel (shared with Q2 sister project)

`mini-intel` is the cross-build host for both this port and the Q2
sister project at `~/quake2/`. Isolation:

| Resource | QuakeSpasm uses | Q2 uses |
|---|---|---|
| Source rsync target | `mini-intel:quakespasm/` | `mini-intel:quake2/` |
| `make` cwd | `mini-intel:quakespasm/Quake/` | `mini-intel:quake2/` |
| Local flock | `~/quakespasm/build/.build.lock` | `~/quake2/build/.build.lock` |
| Local build outputs | `~/quakespasm/build/quakespasm-*` | `~/quake2/build/q2-*` |

Shared (read-only): `/Developer/SDKs/{MacOSX10.3.9.sdk,MacOSX10.4u.sdk}`,
`/usr/bin/{gcc-4.0,clang}`. **Never modify** — Q2 depends on the install
and reinstalling Xcode 3.2.6 + 2.5 from prereqs/ is multi-hour recovery.

Concurrent builds are safe (separate dirs, separate locks). If Q2 is
mid-compile, prefer to wait — serial is faster than 2× concurrent on a
2-core Core 2 Duo, but it's not a correctness issue.

Tell-tale of accidental conflation: `build.sh` ever rsyncing to
`mini-intel:~/` or `mini-intel:quake2/` overwrites Q2. `build.sh`
hard-codes `mini-intel:quakespasm/` — never rely on relative or
env-derived paths.

## Codebase facts you can't grep for

**No software renderer.** QuakeSpasm dropped FitzQuake's software path;
GL-only. "Palette blit hot path" / "software inner loops" don't apply.

**No existing PPC-specific code.** No `__VEC__`, `<altivec.h>`,
`frsqrte`, asm anywhere upstream. Greenfield.

**Two `SSE` mentions are defensive, not SSE code.** `gl_model.c:1414`
and `gl_rlight.c:326` cast lightmap-extent calcs to `double` to dodge
x87/SSE2 precision drift. Universally safe; nothing to patch.

## Hot files (optimisation phase)

- `Quake/mathlib.c:276,281` — `VectorLength`, `VectorNormalize` use
  scalar `sqrt`. Target for `frsqrte` (~6 cyc vs ~30, base PPC).
- `Quake/snd_mix.c:472,498` — sound mixer hot loops. AltiVec (G4 only).
- `Quake/gl_texmgr.c` — `TexMgr_LoadImage8` 8→32 bit expansion at level
  load. Load-time, not per-frame.

## Benchmark discipline + bench-and-commit cadence

Canonical: Quake's `timedemo demo1`/`demo2`/`demo3`. **3× runs, median
of 2 & 3.** All targets every change. Capture `qconsole.log` via
`-condebug`. Tag results with `(commit, machine, demo)`.

`benchmarks/results.csv` is a **rolling history** — never wipe it
mid-round. `parallel-bench.sh` default is append (was wipe; flipped
2026-05-07 after the v2 baseline nearly got lost). `--reset` is a
fresh-epoch action only (wipes after backing up to
`results.csv.bak.<ts>`).

Per-phase shape:

1. Edit + build + deploy.
2. **Smoke** (dirty tree, throwaway): `scripts/parallel-bench.sh --quick`.
   Catches broken builds + gross regressions. Rows tag with parent commit
   because tree is dirty — strip before continuing
   (`git checkout benchmarks/results.csv && rm -f benchmarks/raw/<parent>_*.log`).
3. If smoke is sane (no crash, no unexplained >5% regression), **commit
   the code change** with smoke numbers in the message.
4. **Bench-commit** (post-commit, clean tree, official rows):
   `scripts/bench-and-commit.sh "<phase>" --quick`. Refuses dirty trees,
   pins HEAD, runs the smoke grid, stages CSV + raw logs, lands a
   `bench: <phase>` commit.

Two commits per phase (code + bench) is the price of clean attribution.

**End of round:** full grid once (`bench-and-commit.sh "v<N> wrap"`, no
`--quick`) — 3 demos × 2 res × 3 runs.

**Hash stability:** `parallel-bench.sh` resolves HEAD once at start and
exports `$COMMIT`; `bench.sh` honors it, so side commits during a long
bench can't drift the row tags.

**Negative results still get committed** — signal for redirecting
upcoming phases. Name the regression in the commit
(`bench: <phase> [REGRESSED]`) and decide whether to revert.

**Manual-commit override on transient flake.** `parallel-bench.sh` is
strict — any NA fps cell fails the leg and `bench-and-commit.sh` refuses
the commit. When 23/24 cells are clean and one is a transient (ssh
hiccup, SIGTERM-before-qconsole-write), verify the failure isn't real,
then `git add benchmarks/results.csv benchmarks/raw/<commit>_*.log` and
craft a manual `bench: <phase> (HEAD <commit>) — N.5/N cells` commit
naming the partial cell. Don't hide the NA; do commit the rest.
