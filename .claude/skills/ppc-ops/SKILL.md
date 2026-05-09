---
name: ppc-ops
description: Build, deploy, and benchmark QuakeSpasm on the 6 bench machines (yosemite, sawtooth, quicksilver, mini-g4, mini-intel, imac-2019) from this Ubuntu workstation via the mini-intel cross-build host. Use this skill any time the user asks to compile, ship, or measure a build on any of the bench machines.
---

# PPC operations skill

The QuakeSpasm port has 5 bench machines, named by Apple codename (towers)
or form-factor + chip (minis). All driven through a stable build/deploy/
bench pipeline. Don't reinvent it inline — invoke the scripts.

| machine     | hardware                                                              | binary chip family |
|-------------|-----------------------------------------------------------------------|--------------------|
| yosemite    | PowerMac1,1  / G3 B&W 449 MHz / Rage 128 16 MB / Panther 10.3.9       | g3                 |
| sawtooth    | PowerMac3,1  / G4 AGP 500 MHz / GeForce2 MX 32 MB / Tiger 10.4.11     | g4                 |
| quicksilver | PowerMac3,5  / G4    733 MHz / Radeon 9000 64 MB / Tiger 10.4.11     | g4                 |
| mini-g4     | PowerMac10,1 / G4   1.25 GHz / Radeon 9200 32 MB / Tiger 10.4.11     | g4                 |
| mini-intel  | Macmini2,1   / C2D  2.33 GHz / GMA 950 64 MB / Lion 10.7.5            | lion               |
| imac-2019   | iMac19,1     / i5-9600K 3.70 GHz / Radeon Pro 580X 8 GB / Sequoia 15.7.5 | lion               |

`mini-intel` is also the cross-build host for all PPC binaries.

## When to use

- "build for g4" / "build for g3" / "build for lion" → `scripts/build.sh <chip>`
  (the chip name names the BINARY family, not a machine; one g4 binary
  serves sawtooth, quicksilver, and mini-g4)
- "deploy" / "ship to <machine>" → `scripts/deploy.sh <machine>`
  (build first if `build/quakespasm-<chip>` doesn't exist or isn't from current HEAD)
- "run a bench" / "timedemo" → `scripts/bench.sh <machine> <demo> <WxH>`
- "full benchmark sweep" → `scripts/full-bench.sh all`   (all 5 machines)
- "PPC-only sweep" → `scripts/full-bench.sh ppc`         (skip mini-intel)
- "parallel sweep" / "smoke" → `scripts/parallel-bench.sh [--quick]`
  (default runs all 5 legs concurrently; `--no-<machine>` to skip a leg)
- "bench + commit" (post-phase canonical) → `scripts/bench-and-commit.sh "<phase desc>"`
- "set up a fresh build host" → `scripts/setup-lion.sh`

All scripts live in `scripts/` at the repo root. Read `scripts/README.md`
once to know the contract.

## Inputs and outputs

- Sources: working tree of this repo (rsynced to mini-intel automatically)
- Build artifacts: `build/quakespasm-{g3,g4,lion}` (gitignored). The three
  G4 machines (sawtooth, quicksilver, mini-g4) all reuse `quakespasm-g4`.
- Deploy targets: `<machine>:~/Desktop/quake/Quakespasm.app`
- Bench results: appended to `benchmarks/results.csv`
- Raw bench logs: `benchmarks/raw/<commit>_<machine>_<demo>_<res>_run<N>.log`

## SSH aliases used

All five configured in `~/.ssh/config` with legacy crypto algorithms
(ssh-rsa, dh-group1-sha1, aes128-cbc on Panther) and `id_rsa_tiger` as
the keypair. Each Mac also has `~/bin/qsreboot.sh` installed via
`scripts/install-host-tools.sh` for SSH-side reboot recovery (Tier 1
sudo NOPASSWD reboot, Tier 2 Finder Apple Event).

## Things to avoid

1. **Don't pipe `scp` through `tee` without `set -o pipefail`** — exit
   codes get masked, silent failures.
2. **Don't use `pkill` on the PPC machines** — they don't have it.
   Use `killall <name>`.
3. **Don't pass `CPUFLAGS` via env** to `make -f Makefile.darwin` — the
   makefile resets it with `CPUFLAGS=`. Pass on the make command line.
   The build.sh script handles this correctly.
4. **Don't hard-KILL quakespasm in fullscreen on yosemite** — Panther's
   Rage 128 driver leaves the display LUT corrupt. The scripts use
   TERM-grace-then-KILL pre-AND-post-run to give SDL_Quit a chance to
   restore display state. Recovery if you do trip it: `ssh yosemite
   '~/bin/qsreboot.sh'`.
5. **Don't use `+timedemo demo1 +timedemo demo1 +quit`** in one launch —
   the cmd buffer stomps each timedemo with the next. `bench.sh` does
   one launch per run.
6. **Don't sleep mini-intel during benchmarks/transfers** — wifi+sleep
   makes it drop off the LAN.

## Reading bench results

`scripts/parse_qconsole.py <path>` extracts fps + GL info from a raw
log. Use `--json` for machine-readable output.

`benchmarks/results.csv` schema:
`timestamp,commit,machine,demo,res,run1_fps,run2_fps,run3_fps,median_fps`

Median is computed across runs 2 and 3 (run 1 includes texture upload
warmup). For comparing optimization wins, the relevant cell is
`(commit, machine, demo, res) → median_fps`.

NOTE: machine column historical values include `g3`, `g4`, `g4mini`,
`lion` (rows tagged before the rename round); current rows use the
new names. Both refer to the same hardware — `g4` = `quicksilver`,
`g4mini` = `mini-g4`, `lion` = `mini-intel`, `g3` = `yosemite`.

## Required source patches (already applied)

Three patches that any PPC build needs (committed):

- `Quake/pl_osx.m` — Obj-C 2.0 dot-notation → setter calls (gcc-4.0)
- `Quake/gl_vidsdl.c` — `kCGLCEMPEngine` 10.4-gate
- `MacOSX/QuakeArguments.m` + `AppController.m` — NSString encoding
  APIs version-gated for Panther

These are in the working tree. `CLAUDE.md` documents them in detail.

## Optimization roadmap

See `PPC_PLAN.md` for the prioritized list. Always benchmark each change
on **all 5 machines** — AltiVec wins can be no-ops or regressions on
yosemite if dispatch is wrong; the three G4 machines (sawtooth,
quicksilver, mini-g4) have very different GPU classes (GeForce2 MX vs
Radeon 9000 vs Radeon 9200) so they disambiguate fillrate-bound vs
CPU-bound effects within the G4 family; mini-intel is the Intel reference.
`scripts/parallel-bench.sh` runs all five legs concurrently and is the
default canonical sweep.
