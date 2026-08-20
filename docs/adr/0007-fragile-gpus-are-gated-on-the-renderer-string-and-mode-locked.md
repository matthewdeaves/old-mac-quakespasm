# 7. Fragile GPUs are gated on the renderer string, and their video mode is locked

Date: 2026-08-20
Status: accepted

## Context

Three GPUs in this fleet can take the machine down, and two of them take the
whole OS with them. All three faults are in the driver, not in the engine, and
none of them correlate with the CPU slice.

- **iMac G5, ATI Radeon 9600 / R300, Leopard 10.5.8.** The only GL-2.0-class GPU
  in the fleet, so the only one that ever ran QuakeSpasm's GLSL and VBO
  renderer. Exercising GLSL locks the GPU and the OS. First deploy plus a
  fullscreen bench **hard-hung the machine**: grey screen, no ping, no SSH, fans
  to maximum (the SMU thermal failsafe when the kernel stops servicing it),
  recoverable only by a physical power-cycle. This matches QuakeSpasm bug #43,
  same card and OS, and its regression window ("0.85.x worked, 0.91.0 broke") is
  exactly when GLSL and VBO landed. Every other GPU here (Rage 128, GeForce2 MX,
  Radeon 9000 / 9200) is GL 1.2–1.3 and silently uses fixed-function, so none
  ever hit it.
- **G3, ATI Rage 128, Panther 10.3.9.** A **live in-game fullscreen resolution
  switch hard-crashes** the engine: black screen, display LUT wedged, OS alive
  over SSH.
- **Mac mini G4, ATI Radeon 9200, Tiger.** `vid_bpp 32` plus a boot
  `vid_restart` **hard-wedged the whole OS during video-mode init**:
  `qconsole.log` stops right after "256 megabyte heap" and before the "Video
  mode" line, SSH goes unreachable, machine auto-reboots.

## Decision

**Gate on the GL renderer string, not on the CPU or the slice**
(`Quake/gl_vidsdl.c` `GL_CheckExtensions`, ~:1072-1090). Renderers matching
`Radeon 9500 / 9600 / 9700 / 9800` (R300, R350, RV350, RV360) are forced onto
the GL 1.x fixed-function path: no VBO, no NPOT, no GLSL, no warp mipmaps.
`-atigl` overrides for A/B, and **expect a wedge** if you use it. Same idiom as
the existing Rage 128 CVA skip. NVIDIA-equipped G5s drive GLSL fine, which is
exactly why the gate cannot key on the slice.

**Capture the display at its current mode; never switch modes on a fragile
GPU.** `vid_desktopfullscreen 1` (cvar, default 0) makes fullscreen use the
captured desktop resolution and depth, a same-mode display *capture*, not a
mode *switch*. The R300 driver survives a capture but not a switch. It also
auto-selects each panel's native maximum with no per-model hard-coding (17"
iMac G5 1440×900, 20" 1680×1050). Set to 1 in `autoexec-ppc970.cfg`, engine
default 0 so external-display machines keep their tuned fixed resolution. Under
SDL 1.2 this is a hand-written substitution of the captured `display_*` values
in `VID_SetMode` (ADR 0003).

**Lock the mode on the machines that cannot survive a switch.** `vid_lock` is
exposed as a console command, upstream only locked internally during gamedir
changes, and is called as the **last** line of `autoexec-ppc750.cfg` (G3) and
`autoexec-ppc970.cfg` (G5), after the boot `vid_restart` has set the safe
resolution. It makes `vid_restart`, `vid_test`, alt-enter (`VID_Toggle`) and the
three video-menu choosers (`VID_Menu_ChooseNextMode` / `Bpp` / `Rate`) inert
until `vid_unlock`. Gating the menu choosers matters as much as gating the
apply: otherwise the menu still mutates `vid_*` cvars, poisoning `config.cfg`
into a hazardous mode switch on the *next* boot. G4 and Intel slices are not
locked; their GPUs switch modes fine. `vid_unlock` stays as the escape hatch for
a known-safe GPU, e.g. a GeForce-equipped Power Mac G5 tower.

**Gate `vid_bpp 32` to the machines that proved it.** `vid_bpp 16` (the engine
default) gives a 16-bit z-buffer and **0 stencil bits**, so `r_shadows`' stencil
self-intersection mask never runs (`gl_rmain.c:1081`, `if (gl_stencilbits)`) and
shadows render the doubled-alpha way; `vid_bpp 32` gives 24-bit depth and 8-bit
stencil. Shipped 32 on **quicksilver** (Radeon 9000, verified stable over ~7
launches, about 3% cost, holds the 60 fps floor) and **imac-2019** (Radeon Pro
580X; a 2004-era driver wedge does not apply, but the machine was offline so it
ships unverified). **Not** on mini-g4, and not on the fillrate-bound G3,
sawtooth or mini-intel.

## Evidence and root causes

**R300.** Two red herrings came first. SDL 1.2.15 was rebuilt against the 10.5
SDK as a dedicated `ppc970` slice on the theory that fullscreen SDL was at
fault; the new SDL loaded and rendered fine windowed and then wedged anyway, so
SDL was not the hang (the Leopard SDL slice is still the right thing to ship,
ADR 0003, just not the cure). The real cause is the GL 2.0 / GLSL / VBO path.
Validated first with the existing `-noglsl -novbo -notexturenpot
-nowarpmipmaps` flags, no rebuild, then confirmed with the baked-in gate
auto-firing with zero flags. Result: stable **119 fps at native 1440×900
fullscreen 32bpp** with the full GL-1.x visual stack, the same stack the G4s
run. **GL 1.x here is not a compromise**, R300 GLSL is partly software-emulated
and likely slower. No meaningful fps or visuals are left on the table.

**G3 resolution switch.** The proximate cause was a config bug, not the user:
`autoexec-ppc750.cfg` set `vid_width 1024` *and* called `vid_restart`, while
`autoexec-yosemite.cfg` set `vid_width 800` with *no* `vid_restart`. The overlay
runs after the baseline, so its 800×600 landed only in the cvars and the engine
actually ran at 1024×768. The user saw the wrong resolution, opened the video
menu and selected 800×600, and that live switch crashed the driver. Fixed in two
parts: move 800×600 into the ppc750 baseline so there is a single boot mode-set
to the documented Rage 128 sweet spot, and lock the mode afterwards. See also
ADR 0006 on one authoritative layer per boot resolution.

**Radeon 9200.** Ambiguous between the 32bpp mode itself and the *extra* boot
`vid_restart` the machine config added on top of the one the ppc7400 baseline
already does. Quicksilver (Radeon 9000) ran the identical path through ~7
launches with a clean +stencil, 24-bit-depth result, so the binary and the
config pattern are fine and this is 9200-driver-specific. On retest mini-g4 ran
demo2 and demo1 fine at 24-bit z, and with `config.cfg` forced back to 16 its
depth negotiation came back **inconsistent between launches** (demo1 run 1 =
16-bit z, run 2 = 24-bit, same config). The wedge is intermittent, which is
worse to ship than a deterministic failure.

Read the **"(N-bit z-buffer)"** field in the Video mode log line, not the `xNN`:
`vid_bpp`'s colour depth is often forced to the desktop's 32-bit by
`VID_ValidMode` fallback regardless of the cvar. 16-bit z means no stencil,
24-bit z means stencil 8.

## Consequences

- Wedge severity splits by trigger. **Fullscreen mode-switch plus GLSL = full OS
  death**, power-cycle only. **Windowed GLSL distress = half-alive**, SSH stays
  up and `sudo /sbin/reboot` recovers. Iterate windowed, or native-same-mode,
  only.
- **Leopard's `sudo` has no `-n` flag** (`sudo: illegal option -n`), so
  `qsreboot.sh`'s Tier-1 `sudo -n /sbin/reboot` silently fails on 10.5. Use
  plain `sudo /sbin/reboot`; the NOPASSWD entry still works.
- **Never hard-KILL the engine in fullscreen** on the G3 or the G5. A hard KILL
  wedges the Rage 128 and hangs the R300. Send SIGTERM, allow a grace period,
  then `killall -KILL quakespasm`. `pkill` does not exist on Tiger or Panther.
  Recovery is `ssh <host> '~/bin/qsreboot.sh'`, which issues a kernel-level
  reboot through a wedged Finder or a corrupt Rage 128 LUT; power-cycle only
  after `qsreboot.sh` has been verified failed.
- The first GL-2.0-class GPU in an old-Mac fleet exercises code paths nothing
  else did. **A GPU that advertises GL2 on an old Mac driver is a trap.**
- Anything that adds a boot `vid_restart` on a PowerPC machine needs
  per-machine bench proof before it ships (ADR 0006).
