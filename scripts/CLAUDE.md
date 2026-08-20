# scripts/ — per-script gotchas

The host matrix and what every script does live in `scripts/README.md`. The
decisions behind the tooling are in `docs/adr/`. This file holds only the
gotchas neither of those covers.

Build TARGET names (`g3`/`g4`/`g5`/`lion`) are chip family plus SDK, not
machines. Machine names (`yosemite`, `yosemite-tiger`, `sawtooth`,
`quicksilver`, `mini-g4`, `imac-g5`, `mini-intel`, `imac-2019`) are specific
bench Macs. `deploy.sh` **always ships the fat binary**; `build.sh` exists as
`build-fat.sh`'s sub-step and for diagnosing a one-slice compile error.

## Per-script gotchas

- **build.sh** flocks `~/quakespasm/build/.build.lock` to serialise concurrent
  g3/g4/g5 invocations. After any build, `file build/quakespasm-<t>` must report
  the right CPU subtype — anything else is the `.o` race (ADR 0004). It also
  stamps `QS_PORT_VERSION` (ADR 0004).
- **deploy.sh / bench.sh** load the two autoexec layers from the bundle;
  `bench.sh` stages them as a temp `id1/autoexec.cfg` and passes
  `-noarchautoexec` to avoid double-apply. `EXTRA_CVARS="+cvar val"` runs as a
  stuffcmd after the autoexec, so it wins for a single-cvar A/B. ADR 0006.
- **bench.sh** timeouts differ by machine: mini-intel 60 s, G4s 120 s, sawtooth
  180 s (slower CPU), yosemite 240 s.
- **make-dmg.sh** defaults to a reachable Tiger host and content-verifies the
  binaries inside the image against source. **deploy-dmg.sh / smoke-dmg.sh**
  install and production-launch it; deploy-dmg first removes any older
  `QuakeSpasm-OldMac-*.dmg` from the target Desktop so releases don't pile up.
  ADR 0005.
- **bench-and-commit.sh** refuses dirty trees and any NA fps cell; the
  manual-commit override for a lone transient is in ADR 0009.
- **make-icon.py** — conservative defaults, Photoshop over `--scrub-interior`.
  ADR 0010.

## Host-side reboot recovery

When Quake hard-kills in fullscreen on the G3, Panther's Rage 128 driver leaves
the display LUT corrupt: black screen, mouse moves, OS alive over SSH. The
Apple-menu Restart fails because Finder itself can be wedged. After running
`qsreboot-setup.sh` once per machine, `ssh <host> '~/bin/qsreboot.sh'` issues a
kernel-level reboot regardless of display or Finder state. This is the canonical
recovery path; do not power-cycle unless `qsreboot.sh` has been verified failed,
which would mean sudoers got mangled and the in-script `visudo -c` restore
should have caught it. Leopard's `sudo` has no `-n` (ADR 0007).

## ssh remote `cd && X &` puts the cd in the subshell

`ssh host "cd /foo && rm -f bar && ./prog &"` parses as `(cd && rm && ./prog) &`
because `&&` binds tighter than `&`. The whole chain runs in a background
subshell, the parent shell's cwd never changes, and `[ -f bar ]` in the parent
checks `$HOME/bar`, not `/foo/bar`. Put `cd` and `rm` on their own foreground
lines and `&` only the long-running command.

## Don't pipe `scp` through `tee` without `set -o pipefail`

Exit codes get masked and failures go silent.

## Don't pass `CPUFLAGS` via env to `make -f Makefile.darwin`

The makefile resets it with `CPUFLAGS=`. Pass it on the make command line;
`build.sh` already does.
