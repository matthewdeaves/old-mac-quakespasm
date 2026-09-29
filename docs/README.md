# docs/: index

Sticky facts live in the repo-root [`CLAUDE.md`](../CLAUDE.md). Decisions and
their evidence live in [`adr/`](adr/README.md). Recorded negative results live in
[`../MISTAKES.md`](../MISTAKES.md). This tree holds the rest.

## Live references

- [`PERFORMANCE_PLAN.md`](PERFORMANCE_PLAN.md), a past optimisation plan and its
  results. History, not a current roadmap.
- [`adr/`](adr/README.md), the fourteen architecture decision records: slices and
  OS floors, cpusubtype stamping, SDL 1.2, the fat build model, build and
  packaging hosts, config layering, fragile-GPU gating, toggleability,
  benchmarking, the bundle, the Linux server, code-not-content.
- [`KNOBS.md`](KNOBS.md), inventory of every toggleable cvar and cmdline
  `-flag`, with what each one measured. Keep current; end-of-round A/B depends
  on it.
- [`DEVELOPMENT.md`](DEVELOPMENT.md), build path, build-host tenancy,
  optimisation hot files.
- [`WATCHLINK.md`](WATCHLINK.md), the optional Apple Watch companion feed.
- [`legacy-mac-hardware.md`](legacy-mac-hardware.md), full build/release rules, operational gotchas and codebase facts behind `.claude/rules/legacy-mac-hardware.md`.
- [`ticketing.md`](ticketing.md), labels, lock exports, public/private boundary.
- [`qemu-loop.md`](qemu-loop.md), the PPC test loop on qemu-tiger3d.

## Implemented features: design and post-mortem notes

- [`NETPLAY_DOWNLOAD_PLAN.md`](NETPLAY_DOWNLOAD_PLAN.md), online network play,
  DPMaster server browser, auto-download of missing maps. Copies QSS's
  in-protocol UDP download (no TLS, no curl, no new libs); gated behind
  `allow_download`, default 0. The full loop is hardware-verified end-to-end
  (#59), one 1400-byte (MTU-safe) chunk per server tick, ~1.3x the original
  1024-byte chunk (#64; batching more than one chunk per tick was tried and
  reverted, MISTAKES.md).
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

## Task guides and topic references

- [LAUNCH.md](LAUNCH.md): Fleet engine launch
- [RELEASE.md](RELEASE.md): Release inputs
- [SCRIPT-CONTRACTS.md](SCRIPT-CONTRACTS.md): scripts/: per-script gotchas
- [TESTS.md](TESTS.md): Test entry points
- [TOOLCHAIN.md](TOOLCHAIN.md): MacOSX/: toolchain and flags on the build host
- [adr/0001-four-slices-chosen-by-cpu-capability.md](adr/0001-four-slices-chosen-by-cpu-capability.md): 1. Four slices: chosen by CPU capability and not by OS version
- [adr/0002-every-powerpc-slice-carries-its-exact-cpusubtype.md](adr/0002-every-powerpc-slice-carries-its-exact-cpusubtype.md): 2. Every PowerPC slice carries its exact cpusubtype, and the build asserts it
- [adr/0003-every-shipped-slice-links-sdl-1-2.md](adr/0003-every-shipped-slice-links-sdl-1-2.md): 3. Every shipped slice links SDL 1.2, and the PowerPC slices are hand-built
- [adr/0004-the-fat-is-composed-by-lipo-from-four-separate-builds.md](adr/0004-the-fat-is-composed-by-lipo-from-four-separate-builds.md): 4. The fat binary is composed by lipo from four separate builds, not one pass
- [adr/0005-build-on-an-intel-lion-mini-package-the-dmg-on-tiger.md](adr/0005-build-on-an-intel-lion-mini-package-the-dmg-on-tiger.md): 5. Build on an Intel Lion mini: package the disk image on a Tiger box
- [adr/0006-settings-are-layered-per-arch-then-per-machine.md](adr/0006-settings-are-layered-per-arch-then-per-machine.md): 6. Settings are layered per-arch then per-machine: from inside the bundle
- [adr/0007-fragile-gpus-are-gated-on-the-renderer-string-and-mode-locked.md](adr/0007-fragile-gpus-are-gated-on-the-renderer-string-and-mode-locked.md): 7. Fragile GPUs are gated on the renderer string, and their video mode is locked
- [adr/0008-every-knob-is-toggleable-gate-a-change-do-not-drop-it.md](adr/0008-every-knob-is-toggleable-gate-a-change-do-not-drop-it.md): 8. Every per-target knob is toggleable, and a split result is gated, not dropped
- [adr/0009-benchmarks-are-three-runs-on-hardware-with-a-same-session-ab.md](adr/0009-benchmarks-are-three-runs-on-hardware-with-a-same-session-ab.md): 9. Benchmarks are three runs on real hardware, and a verdict needs a same-session A/B
- [adr/0010-the-bundle-is-a-real-app-that-carries-everything-it-needs.md](adr/0010-the-bundle-is-a-real-app-that-carries-everything-it-needs.md): 10. The bundle is a real .app: location-agnostic, carrying everything it needs
- [adr/0011-the-dedicated-server-is-a-linux-elf-built-in-a-container.md](adr/0011-the-dedicated-server-is-a-linux-elf-built-in-a-container.md): 11. The dedicated server is a Linux ELF built in a container
- [adr/0012-we-ship-code-not-content.md](adr/0012-we-ship-code-not-content.md): 12. We ship code, not content
- [adr/0013-two-more-slices-i386-for-2006-intel-and-arm64-for-apple-silicon.md](adr/0013-two-more-slices-i386-for-2006-intel-and-arm64-for-apple-silicon.md): 13. Two more slices: i386 for 2006 Intel, arm64 for Apple Silicon
- [adr/0014-a-slice-is-fused-only-if-it-was-built-from-this-source.md](adr/0014-a-slice-is-fused-only-if-it-was-built-from-this-source.md): 14. A slice is fused only if it was built from this source

## History archive

Older and superseded accounts: [archive/](archive/). Search by ticket or date.
