# QuakeSpasm old-Mac port

QuakeSpasm as ONE fat binary across PowerPC, Intel and Apple Silicon Macs,
from a single `Quakespasm.app`, 10.3.9 Panther through modern macOS. Sticky
facts only, loaded every session. Reasoning, evidence and rejected
alternatives live in `docs/adr/`; recorded negative results live in
`MISTAKES.md`.

**There is no current plan doc.** The round v2 → v11.1 plan is archived at
`docs/archive/PPC_PLAN_v2-v11.md`, historical context, not a roadmap. New
optimisation work starts from a fresh evidence pass and a new plan.

## Goal in one line

Best-looking QuakeSpasm on G3 Panther/Tiger, G4 Tiger, G5 Leopard and Lion
Intel, staying playable on each: **≥ 20 fps on the G3, ≥ 60 fps on the G4s, G5
and Lion**, uncapped on modern hardware. Above the floor, effects beat fps.

## Commands: do not reinvent these inline

Per-script contracts are in `scripts/CLAUDE.md`; the host matrix and the full
script table are in `scripts/README.md`.

```sh
scripts/build-fat.sh                        # THE build: 6 slices, lipo'd, on a claimed Intel mini
scripts/build.sh <g3|g4|g5|lion|i386>       # one slice; sub-step, or to diagnose a compile error
scripts/build-arm64.sh                      # the arm64 slice; runs HERE, Lion's Xcode cannot target it
scripts/deploy.sh <machine>                 # stage Quakespasm.app + ship; always the fat binary
scripts/bench.sh <machine> <demo> <WxH>     # one 3-run cell into benchmarks/results.csv
scripts/parallel-bench.sh [--quick]         # the concurrent matrix
scripts/bench-and-commit.sh "<phase>"       # canonical post-phase bench commit
scripts/make-dmg.sh [version]               # release image, on a Tiger box, content-verified
scripts/deploy-dmg.sh HOST [ver]            # install from the DMG as a human does
scripts/smoke-dmg.sh HOST [demo]            # launch the installed copy, production config
scripts/screenshot.sh <machine>             # visual A/B captures
scripts/build-server-linux.sh               # Linux dedicated server, in a container
ssh <host> '~/bin/qsreboot.sh'              # reboot a Mac whose display is wedged
```

There is a `ppc-ops` skill and `/bench` + `/deploy` slash commands wrapping
these.

Build TARGET names (`g3`/`g4`/`g5`/`lion`) are **chip family plus SDK, not
machines**. `yosemite` and `yosemite-tiger` are ONE Mac (PowerMac1,1) on ONE IP
with two OS installs, one booted at a time, so they are mutually exclusive bench
legs. Both run `ppc750` and both read `hw.model = PowerMac1,1`, so both get the
`autoexec-yosemite` overlay.

## Hard rules

- **Never trust "done" or exit 0.** After every build: fresh mtimes on each
  `build/quakespasm-{g3,g4,g5,lion,i386,arm64}` from THIS run; `lipo
  -detailed_info build/quakespasm-fat` showing six slices at their exact
  subtypes — `build-fat.sh` deliberately fuses WITHOUT arm64 when that slice
  is missing and only warns, so a five-slice fat is a passing build; and
  after `deploy.sh`, read its md5 comparison, it WARNS rather than fails, and
  a WARN means the target is not running what you built. ADR 0002.
- **A slice is fused only if it was built from this source.** Every build
  writes a hash of the source set to `build/stamps/<arch>/SOURCE-STAMP`, and
  `build-fat.sh` refuses to fuse any slice whose hash differs from the tree.
  This exists because arm64 is the one slice `build-fat.sh` never rebuilds, so
  it was the one that could be silently stale. Not an mtime check: a stale
  object can carry a fresh timestamp. One exclude list, in
  `scripts/source-stamp-excludes.sh`, drives both the hash and `build.sh`'s
  rsync, so adding an exclude also stops rsync replacing that path on the build
  host. ADR 0014.
- **`scripts/source-stamp.sh` is not ours to edit.** It is old-mac-build-host's
  canonical file, adopted byte-identical (currently build-host `dca0776`,
  sha256 `36aad4266534`) and replaced wholesale by its sync. An edit here is
  silently reverted on the next sync and breaks the drift check meanwhile. Put
  anything port-specific in `scripts/source-stamp-excludes.sh` instead, which
  the sync does not touch. Both shared functions take the list as an argument:
  `source_stamp_compute <dir> <excludes>` and `source_stamp_rsync_excludes
  <excludes>`. Four call sites pass it — `build.sh:251`, `build.sh:321`,
  `build-fat.sh:107`, `build-arm64.sh:94` — and a missing argument is refused
  with rc=2, rsync additionally getting a deliberately unopenable
  `--exclude-from` so the build stops instead of copying `.git` to the mini.
- **Every PowerPC slice carries its exact cpusubtype**, never generic `ppc
  (ALL)`, which is a launch blocker on Tiger and Leopard. `build.sh` asserts and
  re-stamps. Trust `lipo`, not `file` (modern `file` renders subtype 9 as
  `ppc_650`). ADR 0002.
- **Bench every change on all targets**, 3 runs, median of 2 and 3, two commits
  per phase (code, then bench). A regression verdict needs a same-session A/B on
  the suspected target. ADR 0009.
- **Every per-target knob must be flippable** at runtime or launch without a
  rebuild, and a change that helps some machines and hurts others gets gated,
  not dropped. ADR 0008, inventory in `docs/KNOBS.md`.
- **Releases:** content-verify the DMG (md5 every binary inside it against
  source, `make-dmg.sh` does it, read the output), build it on a Tiger host and
  never the G3 or Lion, install it the end-user way on at least the oldest and
  newest targets, fact-check the README's per-CPU OS floors in the same commit,
  and give the GitHub release a real description. ADR 0005.
- **Bump the version for every build that gets deployed or released.**
  `QS_PORT_VERSION` is the only way to tell from a running copy which build is
  on a machine. Tag before building. ADR 0004.
- **Never hard-KILL the engine in fullscreen on the G3 or the G5.** TERM, grace,
  then `killall -KILL quakespasm`. ADR 0007.
- **We ship code, not content.** ADR 0012.

## Operational gotchas: every session

- **Do not run `build.sh g3` and `g4` in parallel.** Both rsync to the same tree
  on the build host and `make -j2` in it; the `.o` race produces a wrongly
  stamped binary that crashes Panther during AppKit NIB init. `build.sh` flocks;
  if you bypass it, serialise. `parallel-bench.sh` is fine, it parallelises
  bench legs, not builds.
- **Do not run `bench.sh` legs in parallel from one shell.** Local ssh-stack
  contention gave a wrong G3 reading, 14.7 vs 23.1 fps for the same binary.
- **No `pkill` on Tiger or Panther.** `killall` by name, out of `ps` if needed.
- **Panther's `/bin/sleep` is integer-only**, `sleep 0.2` returns immediately
  on 10.3 (Tiger fixes it). Poll loops on the G3 use `sleep 1`.
- **Leopard's `sudo` has no `-n`**, so `qsreboot.sh`'s Tier-1 silently fails on
  10.5; plain `sudo /sbin/reboot` works with the NOPASSWD entry.
- **The orchestration host needs a REAL rsync, not Apple's openrsync.** macOS
  15+ replaced `/usr/bin/rsync` with openrsync, which always sends `--dirs`, an
  option that did not exist before rsync 2.6.4. Panther's rsync 2.5.x and the G3
  Tiger partition's 2.6.3 both reject it, so `deploy.sh` fails on exactly the two
  oldest boxes. Fix on this end: `brew install rsync` and put
  `/opt/homebrew/bin` ahead of `/usr/bin`. `--protocol=28/29` does NOT help; the
  option is sent regardless.
- **Old-Mac SSH (Lion and PowerPC) needs legacy crypto**: `~/.ssh/config`
  carries `HostKeyAlgorithms +ssh-rsa`, `PubkeyAcceptedKeyTypes +ssh-rsa`,
  pre-2014 `KexAlgorithms` and the RSA key `id_rsa_tiger`. Ad-hoc `ssh user@ip`
  without these fails.
- **The Intel minis sleep aggressively.** `No route to host` from `build.sh`
  means that mini is asleep; `pick-build-host.sh` treats it as unusable and
  picks the other one.
- **The shared SDKs on the minis are read-only.** Never modify
  `/Developer/SDKs/*`, the Q2 port depends on the same install and reinstalling
  is multi-hour recovery. ADR 0005.

## Codebase facts you cannot grep for

- **No software renderer.** QuakeSpasm dropped FitzQuake's software path; this
  is GL-only. "Palette blit hot path" and "software inner loops" do not apply.
- **No upstream PowerPC code.** No `__VEC__`, `<altivec.h>`, `frsqrte` or asm
  anywhere upstream; every PowerPC path here is ours.
- **The two `SSE` mentions are defensive.** `gl_model.c:1414` and
  `gl_rlight.c:326` cast lightmap-extent calculations to `double` to dodge
  x87/SSE2 precision drift. Nothing to patch.

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

## Read on demand

- `docs/adr/`, the decisions and their evidence. Index in `docs/adr/README.md`.
- `MISTAKES.md`, recorded negative results. **Read before lighting up an idea
  that smells "easy" or "load-time only, zero risk".**
- `docs/KNOBS.md`, every toggleable cvar and `-flag`, with what each measured.
- `docs/DEVELOPMENT.md`, build path, build-host tenancy, optimisation hot files.
- `scripts/CLAUDE.md`, `scripts/README.md`, per-script contracts, host matrix.
- `MacOSX/CLAUDE.md`, toolchain paths and per-target flags on the build host;
  `MacOSX/SDL-rebuild.md` for the fat-SDL recipes.
- `docs/README.md`, index of the rest (features, research, archive).
