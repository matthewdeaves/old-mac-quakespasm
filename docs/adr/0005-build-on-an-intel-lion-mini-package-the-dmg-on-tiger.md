# 5. Build on an Intel Lion mini: package the disk image on a Tiger box

Date: 2026-08-20
Status: accepted

## Context

No single machine can do the whole job. Old tools cannot read new formats, new
tools cannot write old ones, and that decides where each step runs.

- The 10.3.9, 10.4u and 10.5 SDKs and the `gcc-4.0` that goes with them live on
  the Intel Lion minis under `/Developer/SDKs`. A modern Mac has none of them.
  `prereqs/` records where the installers come from, their MD5s, and the exact
  extraction dance; `scripts/setup-lion.sh` provisions a fresh host.
- Lion's `hdiutil` writes a UDIF container Panther's 2003-vintage
  DiskImageMounter cannot parse, reported on 10.3.9 as "no mountable file
  systems". **No `hdiutil` flag fixes it**, UDZO, uncompressed UDRO, and an
  Apple-Partition-Map `-layout SPUD` image were all tried on 2026-05-31 and all
  fail to mount on Panther. A Tiger-built UDZO mounts on Panther and on
  everything newer.

Two identical Intel minis exist, `mini-intel` (10.188.1.190) and `mini-intel2`
(10.188.1.216): same Macmini2,1, 10.7.5, identical toolchain. Several
repositories and agents may want one at once, this port shares the minis with
the Quake II and Quake III sister projects.

## Decision

**All four slices cross-compile on a claimed Intel Lion mini. The release disk
image is packaged on a Tiger box. The PowerPC machines are bench and test
targets only.**

- `build.sh` / `build-fat.sh` ask `scripts/pick-build-host.sh --acquire` for a
  host that is reachable and idle, and release it on exit. `BUILD_HOST=<alias>`
  pins one.
- **The claim lives on the mini, not in the repo.** A per-checkout `flock`
  cannot see a build the Q2 repo, or another agent, started on the same box.
  `pick-build-host.sh` locks `/tmp/.retro-build-lock` on the host and also
  treats running compiler processes as busy, so it detects builds started
  outside the mechanism entirely. The per-checkout flock is kept as well, for
  same-repo races.
- **Within one host, tenants are isolated by path**: this port rsyncs to
  `mini-intel:quakespasm/` and makes in `quakespasm/Quake/`, with local
  artifacts under `~/quakespasm/build/` behind `~/quakespasm/build/.build.lock`;
  Q2 uses `mini-intel:quake2/` and `~/quake2/build/`. `build.sh` hard-codes the
  destination, never rely on a relative or env-derived path, because
  `build.sh` rsyncing to `mini-intel:~/` or `mini-intel:quake2/` overwrites Q2.
- **`/Developer/SDKs/{MacOSX10.3.9,MacOSX10.4u,MacOSX10.5}.sdk` and
  `/usr/bin/{gcc-4.0,clang}` are shared read-only. Never modify them.**
  Reinstalling Xcode 3.2.6 plus 2.5 from `prereqs/` is multi-hour recovery, and
  Q2 depends on the same install.
- **`scripts/make-dmg.sh` defaults `DMG_HOST` to the first reachable Tiger box**
  (mini-g4, then quicksilver, then sawtooth) and never the G3. The binary is
  still built on Lion; only the `hdiutil` step moved.
- **The image is content-verified, not just `hdiutil verify`.** After building,
  `make-dmg.sh` mounts the finished image and md5s the 12 shipped code artifacts
  inside it (engine binary, 10 codec dylibs, SDL) against the local source,
  retrying up to 3 times and failing loud if it cannot be made byte-identical.
  It md5-checks the scp-back too. rsync `--partial` was dropped from that path
  because it can reuse a stale chunk on a retry.
- **Install and launch the real artifact before publishing.** `deploy-dmg.sh`
  installs from the image exactly as a human does; `smoke-dmg.sh` launches the
  installed copy with the **production** bundle config, no `-noarchautoexec` and
  no vid override, plus a `+timedemo` so it self-exits, and reports renderer,
  actual resolution and fps. Do this on at least the oldest and newest targets.

## Alternatives rejected

**Package on the 1999 Panther G3 (`yosemite`).** Rejected on evidence. On
2026-05-31 a single byte flipped during that G3's `hdiutil` read → zlib → write
and shipped a corrupt `ppc7400` slice in the Quake II sister port's DMG: a
register-save `stw r31,...` (`0x93e1fffc`) became `0xe7e1fffc`, an illegal
64-bit-only opcode that traps as privileged on a G4 → `EXC_PPC_PRIVINST` →
instant crash at init on every G4. The build binary was fine; only the DMG copy
was corrupt. It was not a transfer loss (TCP, SSH and rsync all checksum), the
prime suspect is the non-ECC RAM and 25-year-old disk on that G3. Our
`make-dmg.sh` was the parent that Q2's was adapted from, so this port carried
the same latent risk. The already-published v1.8 DMG was re-verified afterwards:
all 12 artifacts byte-identical to source, so it had dodged the corruption by
luck. It was then rebuilt through the hardened pipeline and smoke-tested on four
machines (G3 800×600, mini-g4 1024×768, iMac G5 1440×900 native, mini-intel
1024×768), all rendering demo1 to completion with no crash.

**Package on Lion, where the build already is.** It produces an image a G3
cannot mount, and the G3 is the machine class the image most has to reach.

**Build natively on the PowerPC machines.** They are the slowest hardware and
the machines under test.

**Hardcoding one mini.** Two identical hosts exist so two repos can build at
once; hardcoding wastes half the capacity. `pick-build-host.sh` also treats an
unreachable host as unusable and picks the other one, so a sleeping mini no
longer blocks a build.

**Lion PGO and LTO** (round v5 B3, expected +5–12% on Intel). Lion's
`/usr/bin/clang` is Apple clang 1.7, LLVM 2.9-based, much older than the
planning estimate of the LLVM 3.0–3.1 era. `-fprofile-instr-generate` is
*silently accepted* but emits no instrumentation and no `*.profraw` ever
appears; IR-PGO landed in LLVM 3.4+. `-flto` does work and produces a valid
binary, and measured nothing: Lion demo1 1024×768, 3 runs, 96.65 fps without vs
96.85 fps with, a +0.2 fps delta inside a 0.8 fps within-run spread. Kept as an
`LTO=1` opt-in on `build.sh lion`, default off. **Do not redo this on Lion's
clang.** Reopen only if the Lion box is ever replaced by one with LLVM 3.4+ (for
IR-PGO) or LLVM 7+ (for worthwhile LTO). Intel gains have to come from
source-level changes.

## Consequences

- One toolchain, one set of SDKs, either mini able to build any slice, and this
  port and the sister ports can build at the same time on different minis.
- Nothing can be tested where it is built, so every PowerPC verification is a
  deploy-and-observe cycle.
- A release needs three machines reachable: an Intel mini, the orchestration
  box, and a Tiger box.
- `hdiutil verify` only checks that the UDIF container's compressed blocks
  decompress to whatever was stored, not that what was stored matches the
  source. A bad byte baked in at creation passes it. **If you ship a DMG, verify
  the bytes inside it against source end-to-end, every build.**
- Test the artifact the user actually runs. Before 2026-05-31 only `deploy.sh`
  plus bench was tested, which is a direct rsync with no DMG hop, the wrong
  artifact.
