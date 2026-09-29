# QuakeSpasm old-Mac port

One fat `Quakespasm.app` for PowerPC, Intel and Apple Silicon, from Mac OS X 10.3.9 Panther to current macOS. Floor: 20 fps G3, 25 fps G4/G5/Lion. Above it, effects beat fps; win fps by optimising code.

## Traps
- Check `MISTAKES.md` before revisiting an optimisation; failed experiments live there and in its archive.
- Export `BENCH_LOCK_CLAIM` for split acquire/release; a re-exec guard must check WHICH host is held (see docs/ticketing.md).
- Start fleet games through shared `launch-game.sh` (see docs/LAUNCH.md, #80).
- Public repo: never copy addresses, keys, tunnel tokens or `.env` content from build-host or retro-server-infra (see docs/ticketing.md).
- Keep both named commit-level CI workflows, `build-mac.yml` and `build-linux.yml`; they were deleted on 2026-08-28 (see docs/TESTS.md).

## Where to look
- Docs → `docs/README.md`
- Build → `docs/DEVELOPMENT.md`, `docs/TOOLCHAIN.md`
- Deploy → `scripts/deploy.sh`
- Script gotchas → `docs/SCRIPT-CONTRACTS.md`, `scripts/README.md`
- Hardware rules → `.claude/rules/legacy-mac-hardware.md`, `docs/legacy-mac-hardware.md`
- Cvars, decisions → `docs/KNOBS.md`, `docs/adr/README.md`
- Smoke → `scripts/smoke-dmg.sh`
- Bench → `scripts/bench.sh`
- Tests → `docs/TESTS.md`
- Release → `docs/RELEASE.md`
- Tickets → `docs/ticketing.md`
- History → `BUGFIXES.md`, `MISTAKES.md`, `docs/archive/`
- VM → `docs/qemu-loop.md`
