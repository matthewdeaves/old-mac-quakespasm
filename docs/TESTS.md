# Test entry points

## Local checks
`tests/frame-check.py` compares frames; `tests/perf-reuse-check.py` checks rendering/audio reuse. Their command-line interfaces live in those files.

## Commit-level CI
`.github/workflows/build-mac.yml` and `.github/workflows/build-linux.yml` are the only commit-level CI workflows. A commit deleted both on 2026-08-28; retain both when changing the build path.

## Runtime checks
Use `scripts/smoke-dmg.sh` for installed production-launch checks and `scripts/bench.sh` for timedemos. `docs/qemu-loop.md` describes the VM loop.
