# QuakeSpasm old-Mac port

QuakeSpasm as ONE fat binary across PowerPC, Intel and Apple Silicon Macs, from a single `Quakespasm.app`, 10.3.9 Panther through modern macOS.

**Goal:** Best-looking QuakeSpasm on G3 Panther/Tiger, G4 Tiger, G5 Leopard and Lion Intel, staying playable on each: **≥ 20 fps on the G3, ≥ 60 fps on the G4s, G5 and Lion**, uncapped on modern hardware. Above the floor, effects beat fps.

## Commands Reference

- `scripts/build-fat.sh` - THE build: 6 slices, lipo'd, on a claimed Intel mini
- `scripts/build.sh <target>` - One slice; sub-step, or to diagnose a compile error
- `scripts/deploy.sh <machine>` - Stage Quakespasm.app + ship; always the fat binary
- `scripts/bench.sh <machine> <demo> <WxH>` - One 3-run cell into benchmarks/results.csv
- *Full script list in `scripts/README.md`. Per-script contracts in `scripts/CLAUDE.md`.*

## Context Routing

This is a lightweight router. For specific scenarios, consult the following isolated rule files:

- **`.claude/rules/legacy-mac-hardware.md`**: Read when making code changes, dealing with build outputs, hardware specifics, or benching. Contains hard rules, codebase facts, and operational gotchas for old-Mac hardware.
- **`.claude/rules/ticketing-workflow.md`**: Read when handling issues, PRs, or working alongside other repositories in the agentic ecosystem. Contains project management and hardware locking rules.

## Read on Demand

- `docs/adr/` - Architecture Decision Records (ADRs). Use these to store specific types of project information and decisions. Index in `docs/adr/README.md`.
- `MISTAKES.md` - Recorded negative results. **Read before trying "easy" ideas.**
- `docs/KNOBS.md` - Toggleable cvars and `-flag` settings.
- `docs/DEVELOPMENT.md` - Build path, build-host tenancy, hot files.
- `MacOSX/CLAUDE.md` - Toolchain paths and per-target flags on the build host.
- `docs/README.md` - Index of features, research, archive.

## Continuous Integration
- All builds and CI are centrally managed by **`old-mac-build-host`**, which acts as the single source of truth. There are no local GitHub Actions or Jenkins pipelines in this repository.
