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
- **`qsreboot.sh`'s Tier 2 (`osascript ... Finder ... restart`) silently
  no-ops with no console user logged in.** Measured on quad-tiger 2026-08-28:
  returned rc=0, machine's uptime kept climbing through the "reboot". Tier 1
  (direct `/sbin/reboot` via the NOPASSWD sudoers entry, `qsreboot-setup.sh`
  installs it) is the one that actually works headless; don't trust a clean
  Tier-2 exit as proof a machine restarted on an unattended bench box.
- **G5 CPU + an OS below Leopard = a guaranteed dyld crash, not a bug.**
  `build.sh`'s g5 case is deliberately `-mmacosx-version-min=10.5`; dyld picks
  that slice on any G5 regardless of the booted OS. g5-panther, g5-tiger and
  quad-tiger (all G5, all pre-10.5) confirmed 3-for-3, 2026-08-28: `dyld:
  Symbol not found: ___stderrp` or `_kTISPropertyUnicodeKeyLayoutData`,
  Trace/BPT trap. Don't re-diagnose this as a regression; it's this repo's
  own stated floor ("G5 Leopard", never G5 Panther/Tiger) working as built.
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

