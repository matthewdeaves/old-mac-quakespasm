# QuakeSpasm old-Mac port

QuakeSpasm as ONE fat binary across PowerPC, Intel and Apple Silicon Macs, from a single `Quakespasm.app`, 10.3.9 Panther through modern macOS.

**Goal:** Best-looking QuakeSpasm on G3 Panther/Tiger, G4 Tiger, G5 Leopard and Lion Intel, staying playable on each: **≥ 20 fps on the G3, ≥ 25 fps on the G4s, G5 and Lion**, uncapped on modern hardware. Above the floor, effects beat fps; win frame rate by optimising code, not by dropping features.

## Commands Reference

- `scripts/build-fat.sh` - THE build: 6 slices, lipo'd, on a claimed Intel mini
- `scripts/build.sh <target>` - One slice; sub-step, or to diagnose a compile error
- `scripts/deploy.sh <machine>` - Stage Quakespasm.app + ship; always the fat binary
- `scripts/bench.sh <machine> <demo> <WxH>` - One 3-run cell into benchmarks/results.csv
- qemu-tiger3d PPC-in-VM loop (claim first, `scripts/pick-bench-host.sh --run qemu-tiger3d <label> -- <script>`):
  `scripts/deploy.sh qemu-tiger3d` → `scripts/smoke-dmg.sh qemu-tiger3d` →
  `BENCH_ARTEFACT=$PWD/build/quakespasm-fat-deployed BENCH_ADAPTER=$PWD/scripts/bench-adapter.sh scripts/shared.sh bench-evidence.sh qemu-tiger3d <label>` →
  `scripts/screenshot.sh qemu-tiger3d` for the frame check.
- *Full script list in `scripts/README.md`. Per-script contracts in `scripts/CLAUDE.md`.*

## Context Routing

`.claude/rules/legacy-mac-hardware.md` (hard rules, codebase facts, operational
gotchas for old-Mac hardware) auto-loads via its own `paths:` frontmatter
whenever you touch `scripts/`, `Quake/`, `MacOSX/`, `docs/KNOBS.md`,
`docs/adr/` or `MISTAKES.md` — no need to read it separately first.
`.claude/rules/ticketing-workflow.md` holds only what fleet POLICY doesn't
already cover (this repo's lock-export gotchas, issue labels, public/private
repo boundary) and always loads.

## Read on Demand

- `docs/adr/` - Architecture Decision Records (ADRs). Use these to store specific types of project information and decisions. Index in `docs/adr/README.md`.
- `MISTAKES.md` - Recorded negative results. **Read before trying "easy" ideas.**
- `docs/KNOBS.md` - Toggleable cvars and `-flag` settings.
- `docs/DEVELOPMENT.md` - Build path, build-host tenancy, hot files.
- `MacOSX/CLAUDE.md` - Toolchain paths and per-target flags on the build host.
- `docs/README.md` - Index of features, research, archive.

## Continuous Integration
- `.github/workflows/build-mac.yml` (arm64 via `Makefile.darwin`) and
  `build-linux.yml` (clang+gcc via `Makefile`) are this repo's own CI: do the
  current sources still compile on a stock toolchain, on every push and PR.
  Fat-binary fusing, PowerPC, and fleet deploy/smoke are a different concern,
  owned by **`old-mac-build-host`**'s Jenkins jobs (manually/API-triggered,
  not push-triggered) — that is deploy-time verification, not commit-level
  CI, and does not substitute for the workflow files. Public-repo rule: keep
  these green on `master` (2026-08-28, after a Gemini-authored commit
  deleted both files on the unverified claim that build-host covered CI —
  it does not; restored in the commit that added this line).
