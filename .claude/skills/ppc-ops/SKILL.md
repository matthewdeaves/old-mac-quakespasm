---
name: ppc-ops
description: Build, deploy, and benchmark QuakeSpasm on the PowerMac G3/G4 from this Ubuntu workstation via the Lion build host. Use this skill any time the user asks to compile, ship, or measure a build on the PPC machines.
---

# PPC operations skill

The PPC QuakeSpasm project has a stable build/deploy/bench pipeline.
Don't reinvent it inline — invoke the scripts.

## When to use

- "build for g4" / "build for g3" → `scripts/build.sh <target>`
- "deploy" / "ship to g4" → `scripts/deploy.sh <target>` (build first if
  `build/quakespasm-<target>` doesn't exist or isn't from current HEAD)
- "run a bench" / "timedemo" → `scripts/bench.sh <target> <demo> <WxH>`
- "full benchmark sweep" → `scripts/full-bench.sh both`
- "set up a fresh Lion box" → `scripts/setup-lion.sh`

All scripts live in `scripts/` at the repo root. Read `scripts/README.md`
once to know the contract.

## Inputs and outputs

- Sources: working tree of this repo (rsynced to Lion automatically)
- Build artifacts: `build/quakespasm-{g3,g4}` (gitignored)
- Deploy targets: `<host>:~/Desktop/quake/Quakespasm.app`
- Bench results: appended to `benchmarks/results.csv`
- Raw bench logs: `benchmarks/raw/<commit>_<target>_<demo>_<res>_run<N>.log`

## SSH aliases used

- `lion` → Intel Mac mini build host (10.7)
- `g4` → PowerMac G4 (10.4 Tiger)
- `PowerMacG3` → PowerMac G3 B&W (10.3 Panther)

All three configured in `~/.ssh/config` with legacy crypto algorithms
(ssh-rsa, dh-group1-sha1, aes128-cbc on Panther) and `id_rsa_tiger` as
the keypair.

## Things to avoid

1. **Don't pipe `scp` through `tee` without `set -o pipefail`** — exit
   codes get masked, silent failures.
2. **Don't use `pkill` on the PPC machines** — they don't have it.
   Use `killall <name>`.
3. **Don't pass `CPUFLAGS` via env** to `make -f Makefile.darwin` — the
   makefile resets it with `CPUFLAGS=`. Pass on the make command line.
   The build.sh script handles this correctly.
4. **Don't ship the bundled `MacOSX/SDL.framework`'s SDL binary unmodified
   to the G3** — that binary was built against 10.6 SDK and crashes on
   Panther. `scripts/deploy.sh g3` swaps in `MacOSX/SDL-panther.dylib`
   automatically.
5. **Don't use `+timedemo demo1 +timedemo demo1 +quit`** in one launch —
   the cmd buffer stomps each timedemo with the next. `bench.sh` does
   one launch per run.
6. **Don't sleep the Lion mini during benchmarks/transfers** — wifi+sleep
   makes it drop off the LAN.

## Reading bench results

`scripts/parse_qconsole.py <path>` extracts fps + GL info from a raw
log. Use `--json` for machine-readable output.

`benchmarks/results.csv` schema:
`timestamp,commit,machine,demo,res,run1_fps,run2_fps,run3_fps,median_fps`

Median is computed across runs 2 and 3 (run 1 includes texture upload
warmup). For comparing optimization wins, the relevant cell is
`(commit, machine, demo, res) → median_fps`.

## Required source patches (already applied)

Three patches that any PPC build needs (committed):

- `Quake/pl_osx.m` — Obj-C 2.0 dot-notation → setter calls (gcc-4.0)
- `Quake/gl_vidsdl.c` — `kCGLCEMPEngine` 10.4-gate
- `MacOSX/QuakeArguments.m` + `AppController.m` — NSString encoding
  APIs version-gated for Panther

These are in the working tree. `CLAUDE.md` documents them in detail.

## Optimization roadmap

See `PPC_PLAN.md` for the prioritized list. Short version:
1. `frsqrte` in mathlib (universal PPC, helps both)
2. AltiVec sound mixer (G4 only)
3. Multitexture lightmaps (universal)
4. AltiVec mathlib batch ops (G4 only)

Always benchmark each change on **both** G3 and G4. AltiVec wins can
be no-ops or regressions on G3 if the dispatch is wrong.
