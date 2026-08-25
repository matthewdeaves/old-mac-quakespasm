---
name: ppc-ops
description: Build, deploy, and benchmark QuakeSpasm on the bench fleet (yosemite, yosemite-tiger, sawtooth, quicksilver, mini-g4, imac-g5, mini-intel, imac-2019) from the orchestration Mac via a claimed Intel Lion cross-build mini. Use this skill any time the user asks to compile, ship, or measure a build on any of the bench machines.
---

# PPC operations skill

Seven Macs, eight OS installs, four build targets, one fat binary. All driven
through a stable build/deploy/bench pipeline, invoke the scripts, don't
reinvent them inline.

| machine | hardware | target |
|---|---|---|
| yosemite | PowerMac1,1 / G3 B&W 449 MHz / Rage 128 16 MB / Panther 10.3.9 | g3 |
| yosemite-tiger | the SAME Mac, 2nd partition, Tiger 10.4.11 | g3 |
| sawtooth | PowerMac3,1 / G4 AGP 500 MHz / GeForce2 MX 32 MB / Tiger 10.4.11 | g4 |
| quicksilver | PowerMac3,5 / G4 733 MHz / Radeon 9000 64 MB / Tiger 10.4.11 | g4 |
| mini-g4 | PowerMac10,1 / G4 1.25 GHz / Radeon 9200 32 MB / Tiger 10.4.11 | g4 |
| imac-g5 | PowerMac8,2 / G5 2.0 GHz / Radeon 9600 128 MB / Leopard 10.5.8 | g5 |
| mini-intel | Macmini2,1 / C2D 2.33 GHz / GMA 950 64 MB / Lion 10.7.5 | lion |
| imac-2019 | iMac19,1 / i5-9600K 3.7 GHz / Radeon Pro 580X 8 GB / Sequoia 15.7.5 | lion |

`yosemite` and `yosemite-tiger` are one Mac on one IP, one OS booted at a time,
so they are mutually exclusive bench legs. Cross-building happens on a claimed
Intel Lion mini (`mini-intel` or `mini-intel2`), picked by
`scripts/pick-build-host.sh`; `mini-intel` is also a bench reference.

## When to use

- "build" / "build fat" → `scripts/build-fat.sh` (four slices lipo'd into
  `build/quakespasm-fat`, the only binary we deploy). `scripts/build.sh
  <g3|g4|g5|lion>` builds one slice; useful only for a one-slice compile error.
- "deploy" / "ship to <machine>" → `scripts/deploy.sh <machine>`
- "run a bench" / "timedemo" → `scripts/bench.sh <machine> <demo> <WxH>`
- "full sweep" → `scripts/full-bench.sh all` (or `ppc` / `intel` / one machine)
- "parallel sweep" / "smoke" → `scripts/parallel-bench.sh [--quick]`
- "bench + commit" → `scripts/bench-and-commit.sh "<phase desc>"`
- "set up a fresh build host" → `scripts/setup-lion.sh`

Read `scripts/README.md` once for the full contract, and `scripts/CLAUDE.md` for
the gotchas.

## Inputs and outputs

- Sources: this working tree, rsynced to the build host automatically.
- Build artifacts: `build/quakespasm-{g3,g4,g5,lion,fat}`, gitignored.
- Deploy targets: `<machine>:~/Desktop/quake/Quakespasm.app`
- Bench rows: `benchmarks/results.csv`, schema
  `timestamp,commit,machine,demo,res,run1_fps,run2_fps,run3_fps,median_fps,extra_cvars,rendered_res`.
  Median is over runs 2 and 3; run 1 includes texture-upload warmup.
- Raw logs: `benchmarks/raw/<commit>_<machine>_<demo>_<res>_run<N>.log`.
  `scripts/parse_qconsole.py <path>` extracts fps and GL info (`--json`).

Historical CSV rows use the old names `g3`, `g4`, `g4mini`, `lion` for
`yosemite`, `quicksilver`, `mini-g4`, `mini-intel`.

## Things to avoid

1. **Don't build g3/g4/g5 in parallel**, the `.o` race stamps the wrong CPU
   subtype. `build.sh` flocks; don't bypass it. ADR 0004.
2. **Don't run `bench.sh` legs in parallel from one shell**, ssh-stack
   contention gave a wrong G3 reading. Use `parallel-bench.sh`. ADR 0009.
3. **Don't use `pkill` on the PowerPC or Lion machines**, they don't have it.
   `killall`.
4. **Don't hard-KILL quakespasm in fullscreen on yosemite or imac-g5**, the
   Rage 128 LUT and the R300 both wedge. TERM, grace, then KILL. Recovery:
   `ssh <host> '~/bin/qsreboot.sh'`. ADR 0007.
5. **Don't pipe `scp` through `tee` without `set -o pipefail`.**
6. **Don't pass `CPUFLAGS` via env** to `make -f Makefile.darwin`; the makefile
   resets it. `build.sh` handles it.
7. **Don't sleep the Intel minis during benchmarks or transfers.**

## Discipline

Bench every change on every reachable machine, the three G4s span GeForce2 MX /
Radeon 9000 / Radeon 9200 and disambiguate fillrate-bound from CPU-bound within
one CPU family, and the two Intel machines give the GMA 950 fillrate floor and
modern headroom. 3 runs, median of 2 and 3, two commits per phase, same-session
A/B before any regression verdict. ADR 0009. Never re-chase a recorded negative:
`MISTAKES.md`.

There is no current optimisation plan doc. `docs/archive/PPC_PLAN_v2-v11.md` is
history, not a roadmap.
