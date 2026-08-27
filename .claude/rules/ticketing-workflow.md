## Working alongside the other repos

This repo is one of seven worked on together: four game ports, the private
`retro-server-infra` which runs the servers, the private `old-mac-build-host`
which owns the machines, and `retro-agents` which runs the sessions. One board
covers all seven: <https://github.com/users/matthewdeaves/projects/8>.

**Hardware is claimed, never assumed free.** Every script that deploys to,
benches on or otherwise drives a fleet machine re-execs under
`scripts/pick-bench-host.sh --run`, so the machine is claimed for the run and
released however it ends. The lock is a directory on the target, shared with the
build lock and visible to every repo and workstation. Check
`pick-bench-host.sh --status` before assuming a box is idle and NEVER work around
a busy one.

Some repos' own scripts honour `BENCH_NO_LOCK=1` to skip the claim, for debugging
the picker itself. The shared picker does not read it; each script implements it
locally, so it is an escape hatch nothing central audits. Do not use it to get
past a machine someone else is holding.

Nothing arbitrates WORKING TREES. Two sessions in one repo can collide silently,
and a sync can write into your tree mid-task, so stage by name and never
`git add -A`.

**The board columns are gates, not labels:**

    Triage -> Measuring -> Ready -> In progress -> Blocked -> Review -> Done

`Triage` is the user's gate; only a human moves work out of it. `Measuring` means
approved: work it. STOP AT `Review` — `Done` is the user's, not yours. Write
`Refs #12` in commit messages, never `Closes` or `Fixes`, or GitHub closes the
issue behind your back while the column still says Review.

Filing an issue does NOT put it on the board and nothing sets a status on a new
item, so it lands in no column at all and looks like work nobody raised. Run
`retro-agents/bin/board-add.sh <repo>#<n>` after filing, every time.

**The full rules are in `retro-agents/briefs/`, not here.** Every session is
launched with them. This block is the short version for a human reading this repo
cold; where the two differ, the briefs win.
## Working alongside them: what is specific to this repo

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

Labels, the same four in every repo: **`from:infra`** raised by the server side
for a port to act on, **`from:port`** raised by a port for another repo,
**`needs-measurement`** the claim has no number or hardware repro behind it yet,
**`cross-port`** it affects more than one port, so expect sibling issues.

**Anything one session raises at another starts in `Triage` with
`needs-measurement`.** An issue written by another agent carries no more evidence
than the reasoning that produced it, and it arrives looking exactly like one
backed by a bench run. The same finding does recur across ports (the PowerPC SDL2
`--disable-joystick` issue was filed in three repos on one day), so `cross-port`
is worth using, but file the sibling issues rather than assuming the fix
transfers.

**This repo is PUBLIC. `retro-server-infra` and `old-mac-build-host` are
PRIVATE.** They describe the topology, firewall rules and admin surface of a live
host. Never copy addresses, key material, tunnel tokens or `.env` content out of
them into this repo, in code, docs or a commit message. Referring to a server
release tag is fine; describing where it runs is not.

