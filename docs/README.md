# docs/ — index

Documentation for the QuakeSpasm PPC port. The authoritative sticky facts live
in the repo-root [`CLAUDE.md`](../CLAUDE.md); this tree holds the longer-form
material.

## Live references

- [`KNOBS.md`](KNOBS.md) — inventory of every toggleable cvar / cmdline `-flag`
  (per-target visual + perf knobs). Keep current; end-of-round A/B depends on it.
- [`GATING.md`](GATING.md) — toggleability requirement + the three per-machine
  gating mechanisms (compile-time / per-machine autoexec / runtime cvar).
- [`BENCHMARKING.md`](BENCHMARKING.md) — bench discipline, bench-and-commit
  cadence, the timedemo invocation pattern, DMG smoke vs timedemo bench.
- [`DEVELOPMENT.md`](DEVELOPMENT.md) — build path, the shared mini-intel
  build-host isolation table, optimisation hot-files, codebase facts you can't
  grep for. (Per-target compiler flags + bundle assembly: [`../MacOSX/CLAUDE.md`](../MacOSX/CLAUDE.md).)

## ideas/ — forward-looking design, not yet built

Blue-sky design captures. **Nothing here is on a roadmap or has code** — each
doc carries its own status banner.

- [`ideas/AI_DIRECTOR.md`](ideas/AI_DIRECTOR.md) — LLM-as-Dungeon-Master:
  dynamic monster waves, directed spawns, item economy, and narration via a
  network sidecar. Grounded against the real spawn/placement source; flags the
  precache-lock trap.

## archive/ — historical, not a roadmap

Superseded plans and reviews, kept for phase decisions and reverted-experiment
context.

- [`archive/PPC_PLAN_v2-v11.md`](archive/PPC_PLAN_v2-v11.md) — the working plan
  for rounds v2 → v11.1 (every phase, decision, and reverted experiment).
- [`archive/PPC_PERF_R7.md`](archive/PPC_PERF_R7.md) /
  [`PPC_PERF_R7_REVIEW.md`](archive/PPC_PERF_R7_REVIEW.md) — the
  static-analysis-driven Round 7.
- [`archive/PPC_PLAN_v1.md`](archive/PPC_PLAN_v1.md),
  [`PPC_PLAN_1_1.md`](archive/PPC_PLAN_1_1.md),
  [`PPC_PLAN_1_3.md`](archive/PPC_PLAN_1_3.md) — earlier plan revisions.
- [`archive/IRONWAIL_REVIEW.md`](archive/IRONWAIL_REVIEW.md),
  [`MORNING.md`](archive/MORNING.md),
  [`README.v1.md`](archive/README.v1.md) — assorted historical notes.

## research/ — one-off investigations + captured logs

- [`research/fat-binary-feasibility.md`](research/fat-binary-feasibility.md) —
  3-arch lipo'd binary feasibility.
- [`research/build-warning-survey.md`](research/build-warning-survey.md),
  [`pass-b-static-analysis-triage.md`](research/pass-b-static-analysis-triage.md),
  [`pass-a-fps-visual-review.md`](research/pass-a-fps-visual-review.md),
  [`perfprint-pass-c-analysis.md`](research/perfprint-pass-c-analysis.md) —
  end-of-round survey passes (`perfprint-*.log` are their raw captures).
- [`research/end-of-round-resume-prompt*.md`](research/) — resume-prompt drafts.

## Asset folders

- `images/` — README SVG diagrams (architecture / build-pipeline / bench-loop)
  and app icons.
- `screenshots/` — per-machine visual A/B captures (`<machine>_spasmNNNN.webp`).

## See also

- [`../analysis/INDEX.md`](../analysis/INDEX.md) — static-analysis output
  (clang-tidy, cppcheck, scan-build, flawfinder) and perf candidates.
- [`../scripts/README.md`](../scripts/README.md) — tooling + host matrix.
