# scripts/: per-script gotchas

Host matrix and script list: `scripts/README.md`. Decisions: `docs/adr/`. This file holds only the gotchas neither covers.

Build TARGET names (`g3`/`g4`/`g5`/`lion`) are chip family plus SDK, not
machines. Machine names (`yosemite`, `yosemite-tiger`, `sawtooth`,
`quicksilver`, `mini-g4`, `imac-g5`, `mini-intel`, `imac-2019`) are specific
bench Macs. `deploy.sh` **always ships the fat binary**; `build.sh` exists as
`build-fat.sh`'s sub-step and for diagnosing a one-slice compile error.

## Per-script gotchas

- **build.sh** flocks `<repo>/build/.build.lock` to serialise concurrent
  g3/g4/g5 invocations. After any build, `file build/quakespasm-<t>` must report
  the right CPU subtype, anything else is the `.o` race (ADR 0004). It also
  stamps `QS_PORT_VERSION` (ADR 0004).
- **deploy.sh / bench.sh** load the two autoexec layers from the bundle;
  `bench.sh` stages them as a temp `id1/autoexec.cfg` and passes
  `-noarchautoexec` to avoid double-apply. `EXTRA_CVARS="+cvar val"` runs as a
  stuffcmd after the autoexec, so it wins for a single-cvar A/B. ADR 0006.
- **bench.sh** timeouts differ by machine: mini-intel 60 s, G4s 120 s, sawtooth
  180 s (slower CPU), yosemite 240 s.
- **make-dmg.sh** defaults to a reachable Tiger host and content-verifies the
  binaries inside the image against source. **deploy-dmg.sh / smoke-dmg.sh**
  install and production-launch it. They are buildhost's shared scripts
  (build-host#96), run via `scripts/shared.sh` at this repo's pinned revision
  (build-host#105, #68), never edited here: change `dmg-port.conf`, or send
  buildhost the fix. ADR 0005.
- **bench-and-commit.sh** refuses dirty trees and any NA fps cell; the
  manual-commit override for a lone transient is in ADR 0009.
- **make-icon.py**, conservative defaults, Photoshop over `--scrub-interior`.
  ADR 0010.

## Host-side reboot recovery

A fullscreen hard-kill on the G3 leaves Panther's display LUT corrupt (black screen, mouse moves, ssh alive) and Finder may be wedged. After `qsreboot-setup.sh` once per machine, `ssh <host> '~/bin/qsreboot.sh'` reboots at kernel level. Do not power-cycle before it has failed. Tier details: `docs/legacy-mac-hardware.md`, ADR 0007.

## Shell traps

- `ssh host "cd /foo && ./prog &"` backgrounds the whole `cd && ./prog` chain in a subshell, so the parent's cwd never changes. Put `cd` and `rm` on foreground lines and `&` only the long command.
- `scp | tee` without `set -o pipefail` masks failures.
- Don't pass `CPUFLAGS` via env to `make -f Makefile.darwin`: the makefile resets it. Pass it on the command line (`build.sh` does).
