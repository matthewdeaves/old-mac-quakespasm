# QuakeSpasm old-Mac port

One fat `Quakespasm.app` (PowerPC, Intel, Apple Silicon), Mac OS X 10.3.9 Panther to current. Floor: 20 fps G3, 25 fps G4/G5/Lion. Above it, effects beat fps; win fps by optimising code.

## Rules
- Read `MISTAKES.md` (grep it; older entries in `docs/archive/MISTAKES-full.md`) before trying an "easy" optimisation: negative results live there.
- A split picker acquire/release must export `BENCH_LOCK_CLAIM`; guard a re-exec on WHICH host is held, not on any claim (`docs/ticketing.md`).
- Start a game on a fleet host only through shared `launch-game.sh` (#80), never an ad-hoc `nohup ... &`.
- Public repo: never copy addresses, keys, tunnel tokens or `.env` content from build-host or retro-server-infra.
- Keep `.github/workflows/build-mac.yml` and `build-linux.yml` green: they are the only commit-level CI (a commit deleted them 2026-08-28).

## Where to look
- Build: `scripts/build-fat.sh` (6 slices, claimed Intel mini); one slice `scripts/build.sh <target>`
- Deploy: `scripts/deploy.sh <machine>`; bench: `scripts/bench.sh <machine> <demo> <WxH>`; smoke: `scripts/smoke-dmg.sh <host>`
- qemu-tiger3d PPC loop: `docs/qemu-loop.md`
- Script contracts: `scripts/CLAUDE.md`; full list `scripts/README.md`
- Hardware rules and gotchas: `.claude/rules/legacy-mac-hardware.md` (loads under scripts/, MacOSX/); full text `docs/legacy-mac-hardware.md`
- Toolchain and per-target flags: `MacOSX/CLAUDE.md`
- Cvars and flags: `docs/KNOBS.md`; decisions: `docs/adr/README.md`
- Build path, host tenancy, hot files: `docs/DEVELOPMENT.md`
- Labels, lock exports, public/private boundary: `docs/ticketing.md`
- Fixes by ticket: `grep -n '#NNN' BUGFIXES.md`; all docs: `docs/README.md`
