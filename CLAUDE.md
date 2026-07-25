# QuakeSpasm PPC port — guidance for Claude

Sticky facts loaded every session. **There is no current plan doc.** The Round
v2 → v11.1 plan is archived at `docs/archive/PPC_PLAN_v2-v11.md` — read it for
historical phase decisions and reverted-experiment context, but don't treat it as
a roadmap. Any new optimisation work starts with a fresh evidence pass
(end-of-round bench grid, code review, static-analysis sweep) and a new plan
written from that evidence.

## Where things live (read on demand)

- `MISTAKES.md` — append-only log of approaches that broke. **Read before
  lighting up an idea that smells "easy" or "load-time only / zero risk".**
- `docs/GATING.md` — toggleability requirement + per-machine gating mechanisms
- `docs/BENCHMARKING.md` — bench discipline, cadence, timedemo invocation
- `docs/DEVELOPMENT.md` — build path, mini-intel build-host isolation, hot files,
  codebase facts you can't grep for
- `docs/KNOBS.md` — toggleable cvar / cmdline knob inventory
- `scripts/CLAUDE.md` + `scripts/README.md` — tooling contracts + host matrix
- `MacOSX/CLAUDE.md` — bundle layout, Tiger/Panther Cocoa, required patches
  (`MacOSX/SDL-rebuild.md` for the fat-SDL recipe)
- `docs/README.md` — full documentation index (archive, research, ideas)

## Goal in one line

Best-looking QuakeSpasm port for G3 Panther/Tiger + G4 Tiger + G5 Leopard + Lion Intel,
keeping framerate comfortably playable on each (≥ 60 fps on G4, ≥ 60 fps on G5,
≥ 60 fps on Lion, ≥ 20 fps on G3). Visual upgrades that cost 10–15% fps are in
scope when they leave the cell above its playability threshold. Lion + iMac-2019
are also bench references — useful data points that separate GPU-bound from
CPU-bound effects across the GPU axis (R128 / GeForce2 MX / Radeon 9000/9200 /
Radeon 9600 / GMA 950 / Radeon Pro 580X).

**iMac G5 (PowerMac8,2, Radeon 9600 / R300, Leopard 10.5.8)** is the one
GL-2.0-class GPU in the fleet, and is forced onto the GL 1.x fixed-function path
because its Leopard GLSL/VBO driver hard-hangs the GPU (engine ATI R300 gate in
`gl_vidsdl.c`; `-atigl` overrides). It runs native-panel-res fullscreen via a
same-mode CAPTURE (`vid_desktopfullscreen` in the ppc970 baseline — a mode SWITCH
wedges the R300). ~100/74/86 fps (demo1/2/3) at native 1440×900. Integrated-panel
iMacs (G5, and the untested-but-baked-in iMac G4) default to native panel res;
external-display Macs keep their tuned fixed res. See MISTAKES.md 2026-05-31.

## Hard requirements

- **Toggleability.** Every per-target visual/perf knob must be flippable at
  runtime (cvar) or launch (`-flag`) so end-of-round review can A/B it without a
  rebuild. An fps win must not regress visuals on any target. When a change helps
  some machines and hurts others, **gate it, don't drop it** (compile-time /
  per-machine autoexec / runtime cvar). Mechanisms + inventory: `docs/GATING.md`,
  `docs/KNOBS.md`.
- **Bench every change on all targets**, 3× runs median of 2 & 3, commit the
  numbers (code commit + bench commit). Full cadence: `docs/BENCHMARKING.md`.

## Hard rule — slice stamping (exact cpusubtype, never generic ppc ALL)

Every PPC slice must carry its EXACT cpusubtype — **ppc750** (9), **ppc7400**
(10), **ppc970** (100) — which `build.sh` gets for free because Apple's gcc-4.0
propagates `-mcpu=750/7400/970` into the Mach-O header. Verify it every time:
`lipo -detailed_info build/quakespasm-fat` must list `CPU_SUBTYPE_POWERPC_750 /
_7400 / _970`, never `_ALL`. (`file` prints subtype 9 as `ppc_650`; that's a
naming quirk in modern `file`, not a wrong stamp — trust `lipo`.)

A generic `ppc (ALL)` slice is not merely imprecise, it is a launch blocker: it
loads under Panther's lax 2003 dyld, but the Tiger/Leopard **kernel** mis-grades a
fat of `[ppc ALL, ppc7400, ppc970]` on a 750 host and refuses to exec at all.
Proven on hardware in the sister Half-Life port (its v1.0.0 could not launch on
the G3 under Tiger for exactly this reason; fixed by re-stamping to ppc750).

## Hard rule — build verification and version stamping

**Never trust "done" or exit 0.** After every build:

1. Confirm each `build/quakespasm-{g3,g4,g5,lion}` has a fresh mtime from THIS
   run, not a mix of old and new (the `.o` race in "Operational gotchas" can
   silently ship a stale or wrongly-stamped slice).
2. `lipo -detailed_info build/quakespasm-fat` — four slices, exact subtypes.
3. After `deploy.sh`, check its md5 comparison passed. It warns rather than
   fails; a WARN line means the target is NOT running what you built.

**Bump the version for every build that gets deployed or released.**
`QS_PORT_VERSION` (default `git describe --tags --always --dirty`) is stamped
into the binary, so a tagged build self-identifies and an untagged one is
visibly `-N-g…-dirty`. That stamp is the only way to confirm from a running copy
which build is on a machine — don't ship an ambiguous one.

## Hard rule — releases

- The DMG must be **content-verified**, not just `hdiutil verify`: md5 every
  shipped binary inside the image against source (`make-dmg.sh` does this — read
  its output, don't assume). MISTAKES.md 2026-05-31 "DMG byte-flip" is why.
- Build it on a Tiger host, never the G3 (flaky hdiutil) or Lion (writes a UDIF
  Panther can't mount).
- Install it the end-user way (`deploy-dmg.sh` + `smoke-dmg.sh`) on at least the
  oldest and newest targets before publishing.
- **Fact-check the docs in the same commit.** README, `scripts/README.md`, the
  per-CPU OS table and the tested-machines table must state what this build
  actually supports — the per-CPU/per-OS floors, not an aspirational range.
- The GitHub release gets a **real description** (what changed, what was verified
  on which machine, what is known-unverified), not a bare tag.

## Tooling — DON'T reinvent inline

Contracts in `scripts/CLAUDE.md`; host matrix in `scripts/README.md`. Target
names (`g3`/`g4`/`g5`/`lion`) = chip family + SDK, NOT machines. `yosemite` and
`yosemite-tiger` are ONE Mac (PowerMac1,1) on ONE IP with two OS installs —
Panther and Tiger, one booted at a time — so they are mutually exclusive bench
legs, never concurrent. Both run the `ppc750` slice and both read
`hw.model = PowerMac1,1`, so both get the `autoexec-yosemite` overlay. Top of mind:

- `scripts/build-fat.sh` — 4-arch (ppc750+ppc7400+ppc970+x86_64) lipo'd binary,
  the only binary we deploy (`build.sh <g3|g4|g5|lion>` builds one slice)
- `scripts/deploy.sh <machine>` — stage Quakespasm.app + ship; per-machine
  settings travel inside Contents/Resources/
- `scripts/bench.sh <machine> <demo> <WxH>` / `scripts/parallel-bench.sh
  [--quick]` / `scripts/bench-and-commit.sh "<msg>" [--quick]`
- `scripts/make-dmg.sh` + `scripts/{deploy,smoke}-dmg.sh` — release image
  build / install / smoke (content-verified; Tiger host)
- `scripts/screenshot.sh <machine>` — visual A/B captures
- `ssh <host> '~/bin/qsreboot.sh'` — reboot a Mac when a fullscreen kill wedged
  the display (one-time `qsreboot-setup.sh` per machine first)

There's a `ppc-ops` skill (`.claude/skills/ppc-ops/SKILL.md`) and `/bench` +
`/deploy` slash commands that wrap these.

## Operational gotchas — every session

**Don't run `scripts/bench.sh` legs in parallel from one shell.** Local ssh-stack
contention can produce a wrong G3 fps reading (14.7 vs 23.1 fps for the same
binary). Use `parallel-bench.sh` for the proper concurrent matrix, or serial
`bench.sh`.

**Don't run `scripts/build.sh g3` and `g4` in parallel.** Both rsync to
`mini-intel:quakespasm/` and `make -j2` in the same dir → `.o` races → binary
stamped with wrong CPU subtype → Panther crashes during AppKit NIB init.
`build.sh` flocks now; if you bypass, serialize. After any build sanity-check
`file build/quakespasm-g3` reports `ppc_750` and `quakespasm-g4` reports
`ppc_7400`. `parallel-bench.sh` is fine — it parallelizes bench legs, not builds.

**Panther's `/bin/sleep` is integer-only.** `sleep 0.2` returns immediately on
10.3 (Tiger fixes this). Poll loops on G3 must use integer sleeps; `bench.sh`
uses `sleep 1` for this reason.

**Killing the engine.** SDL/CoreAudio threads don't always answer SIGTERM. Use
`killall -KILL quakespasm` after a brief SIGTERM grace. **Don't use `pkill`** —
not on Tiger or Panther. A hard KILL in fullscreen wedges the Rage 128 (G3) and
hangs the R300 (G5), so TERM-before-KILL on those.

**The orchestration host needs a REAL rsync, not Apple's openrsync.** macOS 15+
replaced `/usr/bin/rsync` with openrsync, which always sends `--dirs` — an option
that did not exist before rsync 2.6.4. Panther's rsync 2.5.x and the G3 Tiger
partition's 2.6.3 both reject it (`--dirs: unknown option`), so `deploy.sh` fails
on exactly the two oldest boxes. Fix is on this end: `brew install rsync` (3.x
negotiates down correctly) and make sure `/opt/homebrew/bin` precedes `/usr/bin`
on PATH. `--protocol=28/29` does NOT help — the option is sent regardless.

**Old-Mac SSH (Lion + PPC) needs legacy crypto.** `~/.ssh/config` carries the
required `HostKeyAlgorithms +ssh-rsa`, `PubkeyAcceptedKeyTypes +ssh-rsa`,
pre-2014 `KexAlgorithms`, and RSA key `id_rsa_tiger`. Ad-hoc `ssh user@ip`
without these fails.

**`mini-intel` sleeps aggressively.** If `build.sh` fails with `ssh: connect to
host ... No route to host`, it's asleep — wake it and retry.

## Build + codebase essentials

Build via `Quake/Makefile.darwin` (`MACH_TYPE=ppc`, SDK + `-mcpu` via
`CPUFLAGS`/`LDFLAGS`) — **NOT** the Xcode project. `mini-intel` is the shared
cross-build host for this port AND the Q2 sister project (`~/quake2/`); they're
isolated by separate rsync dirs + flocks, and the 10.3.9 / 10.4u SDKs are
**read-only shared — never modify** (multi-hour Q2 recovery). Per-target flags +
the isolation table: `docs/DEVELOPMENT.md`, `MacOSX/CLAUDE.md`.

Codebase facts that bite: **no software renderer** (GL-only — no "palette blit
hot path"); the two `SSE` mentions are defensive `double` casts, not SSE code.
More + the optimisation hot-file list: `docs/DEVELOPMENT.md`.
