# scripts/ — sticky facts for Claude

Per-script contracts + the host matrix live in `scripts/README.md` (the table
covers what every script does and its arguments). This file holds only the
LLM-critical gotchas the table doesn't — read both when editing scripts.

Build TARGET names (`g3`/`g4`/`g5`/`lion`) refer to chip family + SDK, NOT a
machine. Machine names (`yosemite`/`sawtooth`/`quicksilver`/`mini-g4`/
`mini-intel`/`imac-2019`/`imac-g5`) refer to specific bench Macs. (`g5` = ppc970
/ 10.5 SDK / -mcpu=970 / -DQS_ARCH_PPC970, for the iMac G5 on Leopard 10.5.8.)
`build.sh` produces one slice; `build-fat.sh` lipo's all four into
`build/quakespasm-fat`. **`deploy.sh` always ships the fat binary** — `build.sh`
exists as build-fat.sh's sub-step + for diagnosing one-slice compile errors.

## Per-script gotchas (beyond the README table)

- **build.sh** flocks `~/quakespasm/build/.build.lock` to serialize concurrent
  g3/g4/g5 invocations (the `.o`-race in /CLAUDE.md). After any build, `file
  build/quakespasm-<t>` must report the right CPU subtype (ppc_750 / ppc_7400 /
  ppc_970 / x86_64) — anything else is the race.
- **deploy.sh / bench.sh** load two autoexec layers (per-arch baseline +
  per-machine overlay) from the bundle via CFBundle; bench.sh STAGES them as a
  temp `id1/autoexec.cfg` and passes `-noarchautoexec` to avoid double-apply.
  `EXTRA_CVARS="+cvar val"` runs as a stuffcmd AFTER the autoexec, so it wins for
  a single-cvar A/B. Full detail: `docs/GATING.md`.
- **make-dmg.sh** defaults to a reachable TIGER host (not the flaky G3) and
  content-verifies the binaries inside the image vs source. **deploy-dmg.sh /
  smoke-dmg.sh** install + production-launch the DMG (the path bench skips). Why
  it matters: MISTAKES.md 2026-05-31 "DMG byte-flip".
- **bench-and-commit.sh** refuses dirty trees and any NA fps cell; the
  manual-commit override for a lone transient is in `docs/BENCHMARKING.md`.
- **make-icon.py** — see "Icon pipeline philosophy" below.

The timedemo-invocation pattern (why bench.sh launches 3× separately) moved to
`docs/BENCHMARKING.md`.

## Host-side reboot recovery

When Quake hard-kills in fullscreen on G3, Panther's Rage 128 driver leaves the
display LUT corrupt — black screen, mouse moves, OS alive over SSH. Apple-menu
Restart fails because Finder itself can be wedged. After running
`qsreboot-setup.sh` once per machine, `ssh <host> '~/bin/qsreboot.sh'` from the
orchestration host issues a kernel-level reboot regardless of display/Finder
state. This is the canonical recovery path; do not power-cycle unless qsreboot.sh
has been verified failed (very rare — would mean sudoers got mangled, which the
in-script `visudo -c` restore should have caught).

## ssh remote `cd && X &` puts cd in the subshell

`ssh host "cd /foo && rm -f bar && ./prog &"` parses as `(cd && rm && ./prog) &`
because `&&` binds tighter than `&`. The whole chain runs in a background
subshell, the parent shell's cwd never changes, and `[ -f bar ]` in the parent
checks `$HOME/bar`, not `/foo/bar`. Put `cd` and `rm` on their own foreground
lines and `&` only the long-running command.

## Icon pipeline philosophy

`make-icon.py` ships **conservative defaults**: edge-flood-fill bg removal that
preserves all interior detail, no auto-scrubbing of interior bg-coloured pockets.
The `--scrub-interior` knob exists for AI-generated artwork that has bg leaking
through logo glyph gaps or detail-sparse areas, but the heuristics (size +
score-purity + annulus darkness) can't reliably distinguish bg-bleed from
saturated specular highlights on metallic surfaces.

**Use Photoshop touch-up over algorithmic perfection.** Proven workflow for the
Q1 + Q2 icons we shipped:

1. Run `make-icon.py` with defaults to produce a conservative transparent-bg
   master + (if `--preview`) a magenta-composited preview.
2. User opens master in Photoshop, paints visible bg pockets to alpha=0 using the
   magenta preview as a guide.
3. User saves back as RGBA PNG, hands it back via `--keep-bg` to regenerate the
   ICNS without re-running bg removal.

Don't burn cycles trying to make `--scrub-interior` work perfectly on new
artwork — if defaults leave visible bg pockets, ship to Photoshop.
