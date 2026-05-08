---
description: Run a QuakeSpasm timedemo benchmark on one or more of g3/g4/g4mini/lion
argument-hint: [g3|g4|g4mini|lion|both|all] [demo1|demo2|demo3] [1024x768|640x480]
---

Run a QuakeSpasm timedemo benchmark via the project's bench scripts.

Arguments: $ARGUMENTS

Behavior:
- If 1 arg (`g3`, `g4`, `g4mini`, `lion`, `both`, or `all`) → run the full
  v2 matrix via `scripts/full-bench.sh $ARGUMENTS`. This sweeps
  demo1/2/3 × 1024x768/640x480 × 3 runs. `both` = g4+g3 (historical PPC pair);
  `all` = lion+g4+g4mini+g3 (full 4-machine sweep). Wall time ~3 min on G4
  / G4mini / Lion, ~25 min on G3.
- If 3 args (`<target> <demo> <res>`) → single bench via
  `scripts/bench.sh $ARGUMENTS`. Single 3-run cell, ~30 s on G4 / G4mini /
  Lion, ~3 min on G3.
- If no args → default to `scripts/parallel-bench.sh` (all 4 machines
  concurrently, wall time ≈ slowest leg = G3).

Run the appropriate script with `Bash`. Don't try to rebuild manually with
inline ssh+make — the scripts already handle build, deploy, and bench.

Append rows go to `benchmarks/results.csv`. Raw `qconsole.log`s land in
`benchmarks/raw/` keyed by `<commit>_<target>_<demo>_<res>_run<N>.log`.

After completion, summarize what was added to the CSV and flag any rows
where median fps changed >3% from the previous baseline at the same
(target, demo, res) cell — that's our "is this a real win?" threshold.
