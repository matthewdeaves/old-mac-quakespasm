# scripts/ — sticky facts for Claude

End-user-facing reference is `scripts/README.md`. This file is the
durable LLM context for the scripts area — full script contracts,
operational gotchas that matter when editing or invoking them.

Build TARGET names (`g3`/`g4`/`lion`) refer to chip family + SDK,
NOT a machine. Machine names (`yosemite`/`sawtooth`/`quicksilver`/
`mini-g4`/`mini-intel`/`imac-2019`) refer to specific bench Macs.

`build.sh` produces one slice; `build-fat.sh` lipo's all three slices
into `build/quakespasm-fat`. **`deploy.sh` always ships the fat binary**
— `build.sh` exists as the sub-step build-fat.sh calls plus for
diagnosing one-slice compile errors; we don't deploy single-arch.

## Per-script notes

```
build.sh <g3|g4|lion>          cross-compile (g3/g4) or native x86_64 (lion)
                               on the cross-build host (mini-intel).
                               Flocks ~/quakespasm/build/.build.lock to
                               serialize against concurrent g3/g4 invocations
                               (see "Don't parallel g3+g4" in /CLAUDE.md).
                               After any build, `file build/quakespasm-<t>`
                               must report the right CPU subtype (ppc_750 /
                               ppc_7400 / x86_64) — anything else is the race.

deploy.sh <machine>            stage Quakespasm.app + ship to <machine> via rsync.
                               Always ships build/quakespasm-fat (3-arch lipo'd
                               binary). Per-arch + per-machine autoexec cfgs
                               ship inside Quakespasm.app/Contents/Resources/
                               (loaded by host.c's QS_ExecConfigFromBundle via
                               CFBundle): __VEC__/__ppc__/__x86_64__ picks the
                               per-arch baseline, sysctl hw.model picks the
                               per-machine overlay. End-user install is just
                               .app + their id1/pak0.pak — bundled settings
                               travel with .app. Also clears stale
                               id1/autoexec*.cfg from any pre-v1.4 layout on
                               the target.

bench.sh <machine> <demo> <WxH> [runs]
                               run timedemo, append to results.csv. Since the
                               v1.5 real-conditions change it STAGES the per-arch
                               + per-machine cfg as a temp id1/autoexec.cfg on the
                               target (from the source-tree cfgs) so benches reflect
                               real play; -noarchautoexec only suppresses the
                               CFBundle layer (no double-apply). EXTRA_CVARS="+cvar
                               val" runs as a stuffcmd AFTER the autoexec, so it
                               still wins for single-cvar A/B.

full-bench.sh [<machine>|ppc|all] [--quick]
                               matrix sweep; ppc=4 PPC machines, all=all 6.
parallel-bench.sh [--quick] [--no-<machine>]
                               all legs concurrently. Env: DEMOS, RESES, RUNS
                               for custom matrix. Default action is APPEND
                               (flipped 2026-05-07 — was wipe). --reset is the
                               only path that wipes (after backing up to
                               results.csv.bak.<ts>).

bench-and-commit.sh "<msg>" [--quick]
                               refuses dirty trees, pins HEAD, runs the grid,
                               stages CSV + raw logs, lands a bench: commit.
                               Strict: any NA fps row fails the leg and refuses
                               the commit. Manual-commit override pattern when
                               23/24 cells are clean and one transient — see
                               /CLAUDE.md "Benchmark discipline".

setup-lion.sh                  bootstrap fresh cross-build host from prereqs/.
                               env BUILD_HOST=mini-intel by default.
parse_qconsole.py <log>        extract fps + GL info from a raw log.
make-icon.py [source.png]      regenerate MacOSX/QuakeSpasm.icns. Default
                               source MacOSX/newiconfinal.png. Emits
                               legacy-only ICNS chunks (Panther/Tiger compat —
                               see file header for why iconutil is wrong).
                               Also refreshes docs/images/quakespasm-icon{,-256}.png
                               by default; --no-readme-refresh to skip.
                               --keep-bg skips auto bg-removal (use when the
                               source PNG is hand-cleaned in Photoshop — the
                               canonical workflow, see "Icon pipeline" below).
                               Requires ~/quakespasm/.venv with Pillow+numpy+scipy.
build-fat.sh                   3-arch (ppc750+ppc7400+x86_64) lipo of g3+g4+lion.
                               Output: build/quakespasm-fat.
screenshot.sh <machine>        drive deployed Quakespasm through demo1/2/3 with
                               `screenshot tga` inserted at intervals. Saves to
                               ~/Desktop/quakespasm-screens-<host>/ on target and
                               fetches a copy to benchmarks/screenshots/<host>/.
install-host-tools.sh          push host-bin/* to ~/bin on every bench Mac.
                               Idempotent. Re-run after editing qsreboot.sh
                               or adding a machine.

host-bin/qsreboot.sh           runs ON the Mac. Reboots via `sudo -n /sbin/reboot`
                               (Tier 1, works through wedged Finder / corrupt LUT)
                               with Finder Apple Event as Tier 2 fallback.
                               Use as: ssh <host> '~/bin/qsreboot.sh'
host-bin/qsreboot-setup.sh     runs ON the Mac. ONE-TIME `sudo ~/bin/qsreboot-setup.sh`
                               per machine to install the NOPASSWD sudoers entry.
                               Backs up /etc/sudoers, validates with `visudo -c`,
                               restores backup on syntax failure. Idempotent.
```

## Host-side reboot recovery

When Quake hard-kills in fullscreen on G3, Panther's Rage 128 driver
leaves the display LUT corrupt — black screen, mouse moves, OS alive
over SSH. Apple-menu Restart fails because Finder itself can be wedged.
After running `qsreboot-setup.sh` once per machine,
`ssh <host> '~/bin/qsreboot.sh'` from the orchestration host issues a
kernel-level reboot regardless of display/Finder state. This is the
canonical recovery path; do not power-cycle unless qsreboot.sh itself
has been verified failed (very rare — would mean sudoers got mangled,
in which case the in-script `visudo -c` restore should have caught it).

## Timedemo invocation pattern (why bench.sh exists)

`+timedemo demo1 +timedemo demo1 +timedemo demo1 +quit` in a single
launch **does not work** — they stomp each other in the cmd buffer;
first frame runs all four, demo runs zero frames, `+quit` kills the
process. Result: `-1 frames 0.0 seconds` per "run."

Correct pattern: **3 separate launches, one `+timedemo demo1` each, no
`+quit`. Poll `qconsole.log` for the result line, kill the process via
SIGTERM when found.** `bench.sh` does this dance.

## ssh remote `cd && X &` puts cd in the subshell

`ssh host "cd /foo && rm -f bar && ./prog &"` parses as
`(cd && rm && ./prog) &` because `&&` binds tighter than `&`. The
whole chain runs in a background subshell, the parent shell's cwd
never changes, and `[ -f bar ]` in the parent shell checks `$HOME/bar`,
not `/foo/bar`. Put `cd` and `rm` on their own foreground lines and `&`
only the long-running command.

## Icon pipeline philosophy

`make-icon.py` ships **conservative defaults**: edge-flood-fill bg
removal that preserves all interior detail, no auto-scrubbing of
interior bg-coloured pockets. The `--scrub-interior` knob exists for
AI-generated artwork that has bg leaking through logo glyph gaps or
detail-sparse areas, but the heuristics (size + score-purity + annulus
darkness) can't reliably distinguish bg-bleed from saturated specular
highlights on metallic surfaces.

**Use Photoshop touch-up over algorithmic perfection.** Proven workflow
for the Q1 + Q2 icons we shipped:

1. Run `make-icon.py` with defaults to produce a conservative
   transparent-bg master + (if `--preview`) a magenta-composited preview.
2. User opens master in Photoshop, paints visible bg pockets to alpha=0
   using the magenta preview as a guide.
3. User saves back as RGBA PNG, hands it back via `--keep-bg` to
   regenerate the ICNS without re-running bg removal.

Don't burn cycles trying to make `--scrub-interior` work perfectly on
new artwork — if defaults leave visible bg pockets, ship to Photoshop.
