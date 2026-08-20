# 6. Settings are layered per-arch then per-machine, from inside the bundle

Date: 2026-08-20
Status: accepted

## Context

One fat binary serves a G3 with a Rage 128 on Panther, three G4s with three
different GPU classes, a G5 with an R300 on Leopard, a Core 2 Duo with a GMA
950, and a 2019 iMac with a Radeon Pro 580X. `dyld` picks the slice; nothing in
the slice knows which machine it landed on.

The end-user install has to stay "drag two things into a folder", so the tuned
settings cannot be a separate cfg drop.

## Decision

**Two config layers ship inside `Quakespasm.app/Contents/Resources/`, both
loaded through CFBundle by `QS_ExecConfigFromBundle` (`Quake/host.c:53`).**

1. **Per-arch baseline**, picked at compile time in `host.c` (~:1021):
   `autoexec-ppc970.cfg` when `QS_ARCH_PPC970` is defined, else
   `autoexec-ppc7400.cfg` when `__VEC__`, else `autoexec-ppc750.cfg` when
   `__ppc__`, else `autoexec-x86_64.cfg`. **The 970 must be checked first**,
   because `-mcpu=970` also defines `__VEC__` (ADR 0001).
2. **Per-machine overlay**, picked at boot from `sysctl hw.model`
   (`host.c:1064`), layered on top of the baseline:

   | `hw.model` | overlay |
   |---|---|
   | `PowerMac1,1` | `autoexec-yosemite` |
   | `PowerMac3,1` | `autoexec-sawtooth` |
   | `PowerMac3,5` | `autoexec-quicksilver` |
   | `PowerMac10,1` | `autoexec-mini-g4` |
   | `Macmini2,1` | `autoexec-mini-intel` |
   | `iMac19,1` | `autoexec-imac-2019` |
   | `PowerMac8,1` / `8,2` / `12,1` | `autoexec-imac-g5` |
   | `PowerMac4,2` / `6,1` / `6,3` | `autoexec-imac-g4` |

   `PowerMac8,1`, `12,1` and the three iMac G4 models are baked in but have no
   hardware in the fleet: **untested**.

**Integrated-panel machines default to their native panel resolution**;
external-display Macs keep a tuned fixed resolution.

**The authoritative boot resolution, and its one `vid_restart`, live in exactly
one layer.** An overlay that changes `vid_width` / `vid_height` without a
`vid_restart` is a silent no-op for the live mode: the value lands only in the
cvars, and from there in `config.cfg`, as a phantom. That is the shape of the G3
crash in ADR 0007. Do not add a second boot `vid_restart` on a PowerPC machine
without per-machine bench proof, either — it tears down and recreates the GL
context during early init, and the Radeon 9200 can hang the whole OS doing it.

**`bench.sh` reproduces real play conditions rather than bypassing them.** Since
v1.5 it stages the per-arch plus per-machine concatenation as a temp
`id1/autoexec.cfg` on the target, read from the source-tree cfgs, and passes
`-noarchautoexec` only to suppress the CFBundle layer so it is not applied
twice. `EXTRA_CVARS="+cvar val"` is a stuffcmd that runs after the autoexec, so
it wins, and is the way to A/B a single cvar without editing a cfg. A
compile-time gate is in effect regardless.

**Boot order is load-bearing.** The CFBundle autoexec runs *after* `host.c`'s
post-`quake.rc` `vid_unlock`, so a `vid_lock` at the end of a baseline sticks
for a real `.app` launch. The bench-staged `id1/autoexec.cfg` is executed *by*
`quake.rc`, before that `vid_unlock`, so a staged `vid_lock` is cleared and
benching plus `-width` / `-height` overrides are unaffected.

## Alternatives rejected

**Per-machine binaries.** Defeats the one-image install and multiplies the build
matrix. Machine differences are almost all driver and fillrate differences,
which are cvars.

**cfgs dropped in `id1/` next to the game data.** The user would have to install
them, and they would not survive a reinstall. They also collide with the user's
own `config.cfg`.

**Choosing by CPU alone.** Three G4 machines share `ppc7400` and have GeForce2
MX, Radeon 9000 and Radeon 9200 respectively. Their right settings differ by
GPU, not by CPU.

## Consequences

- The end-user install is: drop `Quakespasm.app` and `quakespasm.pak` into any
  folder, add `id1/pak0.pak`, double-click. The per-machine visual stack travels
  inside the `.app`.
- `deploy.sh` ships a byte-for-byte identical bundle to every machine.
- **`deploy.sh` does not seed `config.cfg`.** A cvar the engine saved during a
  test run persists on the target and silently changes the next launch — this
  happened with `vid_bpp 32` on mini-g4 after a wedged session. Reset
  `config.cfg` explicitly when reverting a config change.
- A cvar added to an autoexec is `CVAR_ARCHIVE` state that compounds across
  rounds, so **the cvar set in effect is part of every benchmark** (ADR 0009).
- Adding a machine means adding a `hw.model` row and a cfg, not a build.
