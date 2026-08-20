# QuakeSpasm old-Mac port

QuakeSpasm as ONE fat binary across PowerPC and Intel Macs, from a single
`Quakespasm.app`, 10.3.9 Panther through modern macOS. Sticky facts only, loaded
every session. Reasoning, evidence and rejected alternatives live in
`docs/adr/`; recorded negative results live in `MISTAKES.md`.

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
scripts/build-fat.sh                        # THE build: 4 slices, lipo'd, on a claimed Intel mini
scripts/build.sh <g3|g4|g5|lion>            # one slice; sub-step, or to diagnose a compile error
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
  `build/quakespasm-{g3,g4,g5,lion}` from THIS run; `lipo -detailed_info
  build/quakespasm-fat` showing four slices at their exact subtypes; and after
  `deploy.sh`, read its md5 comparison, it WARNS rather than fails, and a WARN
  means the target is not running what you built. ADR 0002.
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
