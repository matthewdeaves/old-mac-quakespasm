---
description: Run a QuakeSpasm timedemo benchmark on one or more bench machines
argument-hint: [yosemite|sawtooth|quicksilver|mini-g4|mini-intel|imac-2019|ppc|intel|all] [demo1|demo2|demo3] [1024x768|640x480]
---

Run a QuakeSpasm timedemo benchmark via the project's bench scripts.

Arguments: $ARGUMENTS

Machines (Apple-codename / form-factor naming):
- `yosemite`, PowerMac G3 B&W 449 MHz, Rage 128, 10.3.9 Panther
- `sawtooth`, PowerMac G4 AGP 500 MHz, GeForce2 MX, 10.4.11 Tiger
- `quicksilver`, PowerMac G4 733 MHz, Radeon 9000, 10.4.11 Tiger
- `mini-g4`, Mac mini G4 1.25 GHz, Radeon 9200, 10.4.11 Tiger
- `mini-intel`, Mac mini Intel C2D 2.33 GHz, GMA 950, 10.7.5 Lion
- `imac-2019`, iMac 27" i5-9600K, Radeon Pro 580X 8 GB, 15.7.5 Sequoia

Behavior:
- If 1 arg (a machine name, `ppc`, `intel`, or `all`) → run the matrix
  via `scripts/full-bench.sh $ARGUMENTS`. Sweeps demo1/2/3 ×
  1024x768/640x480 × 3 runs. `ppc` = the four PPC machines; `intel` =
  the two Intel machines; `all` = all 6. Wall time ~30 s on imac-2019,
  ~1 min on mini-intel, ~3 min each on the G4s, ~25 min on yosemite.
- If 3 args (`<machine> <demo> <res>`) → single bench via
  `scripts/bench.sh $ARGUMENTS`. Single 3-run cell, ~30 s on
  Intel/G4, ~3 min on yosemite.
- If no args → default to `scripts/parallel-bench.sh` (all 6 machines
  concurrently, wall time ≈ slowest leg = yosemite).

Run the appropriate script with `Bash`. Don't try to rebuild manually with
inline ssh+make, the scripts already handle build, deploy, and bench.

Append rows go to `benchmarks/results.csv`. Raw `qconsole.log`s land in
`benchmarks/raw/` keyed by `<commit>_<machine>_<demo>_<res>_run<N>.log`.

After completion, summarize what was added to the CSV and flag any rows
where median fps changed >3% from the previous baseline at the same
(machine, demo, res) cell, that's our "is this a real win?" threshold.
