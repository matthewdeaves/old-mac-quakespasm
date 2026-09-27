## What's specific to this repo (board/ticketing basics are in POLICY.md)

**`BENCH_NO_LOCK=1` is a local escape hatch some scripts honour to skip the
claim, for debugging the picker itself — the shared picker does not read it,
so it is not audited centrally.** Never use it to get past a machine someone
else is holding.

**A split acquire/release pair must export `BENCH_LOCK_CLAIM`.** Without it the
picker can only match `user@host:repo`, which every session in this repo shares,
so a sibling session's `--release` silently drops your lock. `--run` handles this
itself. `build-fat.sh` and `build.sh` export it. Measured 2026-08-22.

**Guard a re-exec on WHICH host is held, not whether any is.**
`pick-bench-host.sh --run` exports `RETRO_BENCH_LOCK` naming the claimed host, so
`[ -z "${RETRO_BENCH_LOCK:-}" ]` now means "inside ANY claim" and makes a script
skip claiming a DIFFERENT machine. Compare against the target instead:
`[ "${RETRO_BENCH_LOCK:-}" != "$TARGET" ]`. Ten scripts here were wrong; fixed in
77b78a02.

**Issue labels, the same four in every repo:** `from:infra` raised by the server
side for a port to act on, `from:port` raised by a port for another repo,
`needs-measurement` the claim has no number or hardware repro behind it yet,
`cross-port` it affects more than one port, so expect sibling issues. Anything
one session raises at another starts in `Triage` with `needs-measurement` — an
issue written by another agent carries no more evidence than the reasoning that
produced it, but arrives looking like one backed by a bench run.

**This repo is PUBLIC.** `old-mac-build-host` is PRIVATE; `retro-server-infra`
went public 2026-08-31. Both describe the topology, firewall rules and admin
surface of a live host. Never copy addresses, key material, tunnel tokens or
`.env` content out of them into this repo, in code, docs or a commit message.
Referring to a server release tag is fine; describing where it runs is not.
