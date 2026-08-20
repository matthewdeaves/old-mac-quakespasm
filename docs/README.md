# docs/: index

Sticky facts live in the repo-root [`CLAUDE.md`](../CLAUDE.md). Decisions and
their evidence live in [`adr/`](adr/README.md). Recorded negative results live in
[`../MISTAKES.md`](../MISTAKES.md). This tree holds the rest.

## Live references

- [`adr/`](adr/README.md), the twelve architecture decision records: slices and
  OS floors, cpusubtype stamping, SDL 1.2, the fat build model, build and
  packaging hosts, config layering, fragile-GPU gating, toggleability,
  benchmarking, the bundle, the Linux server, code-not-content.
- [`KNOBS.md`](KNOBS.md), inventory of every toggleable cvar and cmdline
  `-flag`, with what each one measured. Keep current; end-of-round A/B depends
  on it.
- [`DEVELOPMENT.md`](DEVELOPMENT.md), build path, build-host tenancy,
  optimisation hot files.
- [`WATCHLINK.md`](WATCHLINK.md), the optional Apple Watch companion feed.

## Implemented features: design and post-mortem notes

- [`NETPLAY_DOWNLOAD_PLAN.md`](NETPLAY_DOWNLOAD_PLAN.md), online network play,
  DPMaster server browser, auto-download of missing maps. Copies QSS's
  in-protocol UDP download (no TLS, no curl, no new libs); gated behind
  `allow_download`, default 0. **DONE and hardware-verified**, full
  browse → join → download → play loop tested against `denver.quakeone.com` and a
  self-host rig (`scripts/selfhost-download-test.sh`).
- [`LIGHTNING_BOLT_DEBUG.md`](LIGHTNING_BOLT_DEBUG.md), root-cause post-mortem
  for the dark lightning bolt on Radeon 9200 and GMA 950. Decoded the
  `bolt2.mdl` skin (the bright core is fullbright-palette texels split into the
  `fb` mask) and fixed the beam to draw fullbright-unlit on a single GL 1.1
  path. **SOLVED.**

## ideas/: forward-looking design, not yet built

**Nothing here is on a roadmap or has code.**

- [`ideas/AI_DIRECTOR.md`](ideas/AI_DIRECTOR.md), LLM-as-Dungeon-Master:
  dynamic monster waves, directed spawns, item economy, narration via a network
  sidecar. Grounded against the real spawn/placement source; flags the
  precache-lock trap.

## archive/: historical, not a roadmap

Superseded plans and reviews, kept for phase decisions and reverted-experiment
context.

- [`archive/PPC_PLAN_v2-v11.md`](archive/PPC_PLAN_v2-v11.md), the working plan
  for rounds v2 → v11.1: every phase, decision and reverted experiment.
- [`archive/PPC_PERF_R7.md`](archive/PPC_PERF_R7.md) /
  [`PPC_PERF_R7_REVIEW.md`](archive/PPC_PERF_R7_REVIEW.md), the
  static-analysis-driven round 7.
- [`archive/PPC_PLAN_v1.md`](archive/PPC_PLAN_v1.md),
  [`PPC_PLAN_1_1.md`](archive/PPC_PLAN_1_1.md),
  [`PPC_PLAN_1_3.md`](archive/PPC_PLAN_1_3.md), earlier plan revisions.
- [`archive/IRONWAIL_REVIEW.md`](archive/IRONWAIL_REVIEW.md), survey of
  Ironwail at commit `5a98362` (2026-05-09): what could be back-ported and what
  is disqualified by GL version, with upstream file:line anchors. The record
  that stops a future round re-surveying it from scratch.

## research/: one-off investigations and captured logs

- [`research/fat-binary-feasibility.md`](research/fat-binary-feasibility.md),
  the lipo'd-fat feasibility study; cited by `scripts/build-fat.sh` (§1, §7).
  Its live conclusions are ADR 0001 and ADR 0004.
- [`research/build-warning-survey.md`](research/build-warning-survey.md),
  [`pass-b-static-analysis-triage.md`](research/pass-b-static-analysis-triage.md),
  [`pass-a-fps-visual-review.md`](research/pass-a-fps-visual-review.md),
  [`perfprint-pass-c-analysis.md`](research/perfprint-pass-c-analysis.md),
  end-of-round survey passes (`perfprint-*.log` are their raw captures).

## Asset folders

- `images/`, README SVG diagrams (architecture, build pipeline, bench loop) and
  app icons.
- `screenshots/`, per-machine visual A/B captures (`<machine>_spasmNNNN.webp`).

## See also

- [`../analysis/INDEX.md`](../analysis/INDEX.md), static-analysis output and
  perf candidates.
- [`../scripts/README.md`](../scripts/README.md), tooling and host matrix.
- [`../benchmarks/profiles/README.md`](../benchmarks/profiles/README.md), the
  `sample`-based profile captures.
