# Benchmark discipline + bench-and-commit cadence

How we measure, attribute, and commit performance changes. The root
[`CLAUDE.md`](../CLAUDE.md) carries the one-paragraph summary; this is the full
procedure. Tooling lives in `scripts/` (see [`scripts/README.md`](../scripts/README.md)).

## Timedemo invocation (why `bench.sh` exists)

`+timedemo demo1 +timedemo demo1 +timedemo demo1 +quit` in a single launch
**does not work** — they stomp each other in the cmd buffer; the first frame
runs all four, the demo runs zero frames, `+quit` kills the process. Result:
`-1 frames 0.0 seconds` per "run."

Correct pattern: **3 separate launches, one `+timedemo demo1` each, no `+quit`.
Poll `qconsole.log` for the result line, kill the process via SIGTERM when
found.** `bench.sh` does this dance.

## Discipline

Canonical: Quake's `timedemo demo1`/`demo2`/`demo3`. **3× runs, median of 2 &
3.** All targets every change. Capture `qconsole.log` via `-condebug`. Tag
results with `(commit, machine, demo)`.

`benchmarks/results.csv` is a **rolling history** — never wipe it mid-round.
`parallel-bench.sh` default is append (was wipe; flipped 2026-05-07 after the
v2 baseline nearly got lost). `--reset` is a fresh-epoch action only (wipes
after backing up to `results.csv.bak.<ts>`).

## Per-phase shape

1. Edit + build + deploy.
2. **Smoke** (dirty tree, throwaway): `scripts/parallel-bench.sh --quick`.
   Catches broken builds + gross regressions. Rows tag with parent commit
   because tree is dirty — strip before continuing
   (`git checkout benchmarks/results.csv && rm -f benchmarks/raw/<parent>_*.log`).
3. If smoke is sane (no crash, no unexplained >5% regression), **commit the code
   change** with smoke numbers in the message.
4. **Bench-commit** (post-commit, clean tree, official rows):
   `scripts/bench-and-commit.sh "<phase>" --quick`. Refuses dirty trees, pins
   HEAD, runs the smoke grid, stages CSV + raw logs, lands a `bench: <phase>`
   commit.

Two commits per phase (code + bench) is the price of clean attribution.

**End of round:** full grid once (`bench-and-commit.sh "v<N> wrap"`, no
`--quick`) — 3 demos × 2 res × 3 runs.

## Edge cases

**Hash stability:** `parallel-bench.sh` resolves HEAD once at start and exports
`$COMMIT`; `bench.sh` honors it, so side commits during a long bench can't drift
the row tags.

**Negative results still get committed** — signal for redirecting upcoming
phases. Name the regression in the commit (`bench: <phase> [REGRESSED]`) and
decide whether to revert.

**Manual-commit override on transient flake.** `parallel-bench.sh` is strict —
any NA fps cell fails the leg and `bench-and-commit.sh` refuses the commit. When
23/24 cells are clean and one is a transient (ssh hiccup,
SIGTERM-before-qconsole-write), verify the failure isn't real, then `git add
benchmarks/results.csv benchmarks/raw/<commit>_*.log` and craft a manual `bench:
<phase> (HEAD <commit>) — N.5/N cells` commit naming the partial cell. Don't
hide the NA; do commit the rest.

## DMG smoke vs timedemo bench

The bench grid measures the `deploy.sh`-installed binary. A release **DMG** takes
an extra `hdiutil` packaging hop that the bench never exercises — test that
artifact separately with `scripts/deploy-dmg.sh` + `scripts/smoke-dmg.sh` (the
production install→launch path). See [MISTAKES.md](../MISTAKES.md) 2026-05-31
"DMG byte-flip".
