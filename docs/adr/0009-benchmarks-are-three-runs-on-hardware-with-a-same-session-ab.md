# 9. Benchmarks are three runs on real hardware, and a verdict needs a same-session A/B

Date: 2026-08-20
Status: accepted

## Context

Every performance claim in this port is about a specific driver on specific
1999–2007 hardware. There is no way to model it; it has to be measured where it
runs. And the machines drift: yosemite reads about 5 fps slower on some days
than others in the same configuration, and several mid-session benches have read
anywhere between 14.4 and 20.6 fps for the same effective config until the
machine was rebooted. That drift is wide enough to swallow a real signal.

## Decision

**Canonical measurement is Quake's `timedemo demo1` / `demo2` / `demo3`, three
runs, median of runs 2 and 3** (run 1 includes texture-upload warmup), on all
targets for every change, captured via `-condebug` into `qconsole.log` and
tagged `(commit, machine, demo, res)` in `benchmarks/results.csv`.

**A regression or improvement verdict requires an apples-to-apples same-session
A/B on the suspected target.** Comparing a fresh reading against a historical
CSV row taken under unknown machine state is unreliable.

**`+timedemo demo1 +timedemo demo1 +timedemo demo1 +quit` in one launch does not
work** — they stomp each other in the command buffer, the first frame runs all
four, the demo runs zero frames, and `+quit` kills the process, giving
`-1 frames 0.0 seconds` per "run". The correct pattern, which `bench.sh`
implements, is **three separate launches, one `+timedemo` each, no `+quit`**;
poll `qconsole.log` for the result line and SIGTERM the process when it appears.

**Two commits per phase**, which is the price of clean attribution:

1. Edit, build, deploy, then **smoke** on a dirty tree with
   `parallel-bench.sh --quick`. Rows tag with the parent commit; strip them
   before continuing (`git checkout benchmarks/results.csv && rm -f
   benchmarks/raw/<parent>_*.log`).
2. If the smoke is sane — no crash, no unexplained >5% regression — commit the
   code change with the smoke numbers in the message.
3. **Bench-commit** on the clean tree with
   `bench-and-commit.sh "<phase>" --quick`, which refuses dirty trees, pins
   HEAD, stages the CSV and raw logs, and lands a `bench: <phase>` commit.
4. End of round: the full grid once, no `--quick` — 3 demos × 2 resolutions × 3
   runs.

**`benchmarks/results.csv` is a rolling history; never wipe it mid-round.**
`parallel-bench.sh` defaults to append (it was wipe until 2026-05-07, when the
v2 baseline nearly got lost). `--reset` is a fresh-epoch action only and backs
up to `results.csv.bak.<ts>`.

**Negative results still get committed.** Name the regression in the message
(`bench: <phase> [REGRESSED]`) and then decide whether to revert.

## Evidence: three verdicts that were wrong

**A "code regression" that was a config change (rounds v9 and v10).** The v9
wrap grid showed catastrophic demo3 regressions on every machine — yosemite
−24.5%, sawtooth −23.3%, quicksilver −28.6%, mini-g4 −32.9%, mini-intel −18.0%,
plus demo1 −15% on the iMac. v9's only landed item was the Ironwail flat-array
efrags pattern (`6f3976f8`), which was reverted at `13b6876a` on the strength of
"bench shows demo3 regression on every machine". v10 take 2 (flat efrags plus
per-leaf cull) was then implemented to fix that regression, and bisected to
15.00 fps flat vs 15.10 fps `-noflatefrags` on yosemite demo3 1024 — the same
number. There was nothing in v9 to fix. **The real cause was an autoexec
change**: today's rebuild of the same code at `f2df151d` benched 14.45 fps with
the current autoexec and 19.45 fps with `id1/autoexec.cfg` renamed away.
`r_lavaalpha 0.6` alone accounted for −26% (ADR 0008). The Ironwail flat-array
pattern's actual impact on this codebase was **neutral** on the G3, and we do
not know whether it would have been a small win without the confound.
*Check the bench delta against the autoexec diff before blaming code, and verify
by running with `id1/autoexec.cfg` removed.*

**A "−30% regression" that was a stale binary (round v6).** The v6 wrap grid
appended mini-g4 rows tagged with the wrap commit `5cbcf785` while a stale
pre-watervis binary was still deployed on the machine. Round v7 then showed
mini-g4 demo1 1024 falling from "72.20 baseline" to 50.30. Bisect: checking out
`5cbcf785`, rebuilding and re-deploying gave **53.40 fps**, not 72.20, so v7's
50.30 was really **−5.8%**. The 12 stale rows were deleted from
`results.csv` and a correct v6 baseline re-run. Cross-validation should have
caught it at wrap time: v5 pre-watervis was 76.00, the v6 stale row 72.20, v6
actual 53.40 — the stale row sat much closer to v5 than to v6.
*After any mid-bench binary refresh, re-bench every affected machine before the
wrap commit. "Stale binary" is invisible to the bench scripts.*

**A revert that was wrong (round v5 B5).** The scalar dlight cast hoist was
reverted after a G4-mini reading of 65.00 fps landed inside a historical
65.20–69.30 cluster and was read as neutral. That cluster spans about 6% of
noise, wide enough to hide a +3% real signal. A proper same-session A/B, both
binaries deployed back-to-back on a warm mini-g4, 5 runs per cell, md5-verified
on the target, spread under 0.2 fps within each phase: demo3 1024
**65.10 → 67.00, +2.9%**; demo3 640 **115.50 → 116.50, +0.9%**. The revert was
wrong and B5 was re-applied. (Its *other* target, quicksilver vs mini-g4, is the
split result in ADR 0008.)

## Consequences

- Bench hygiene has hard edges that the tooling encodes:
  `parallel-bench.sh` resolves HEAD once and exports `$COMMIT`, which `bench.sh`
  honours, so side commits during a long bench cannot drift the row tags.
- `bench-and-commit.sh` refuses any NA fps cell. When 23 of 24 cells are clean
  and one is a genuine transient (ssh hiccup, SIGTERM before the qconsole
  write), verify the failure is not real, then stage the CSV and raw logs and
  craft a manual `bench: <phase> (HEAD <commit>) — N.5/N cells` commit naming
  the partial cell. Do not hide the NA; do commit the rest.
- **Do not run `bench.sh` legs in parallel from one shell.** Local ssh-stack
  contention produced a wrong G3 reading, 14.7 vs 23.1 fps for the same binary.
  Use `parallel-bench.sh` for the concurrent matrix, or serial `bench.sh`.
  Parallel *bench* legs are fine; parallel *builds* are not (ADR 0004).
- **Yosemite needs frequent reboots during long bench cycles.**
- **The bench grid measures the `deploy.sh`-installed binary and never the
  DMG.** Test that separately (ADR 0005).
- **Smoke-bench every target before committing, even for a change tagged
  "load-time only, zero fps move", and include at least one map transition.**
  demo1 alone is not enough exposure: the BGRA static-texture crash passed a
  demo1 smoke on three machines and only surfaced on certain map-load sequences
  (see `MISTAKES.md`).
- A CSV row does not record which binary or which autoexec produced it. Adding
  the deployed `.app` md5 and an `id1/autoexec.cfg` fingerprint alongside the
  commit hash is an open schema improvement, and is what both misattributions
  above would have needed.
