# QuakeSpasm PPC port — guidance for Claude

This file is loaded into every session. It captures durable tribal knowledge
that's expensive to re-derive. **The full plan lives in `PPC_PLAN.md`** — read
that for hardware inventory, decisions, the bench script, optimization list,
etc. This file is just the sticky facts.

**Read `MISTAKES.md` before lighting up an idea that smells "easy" or
"load-time only / zero risk".** It's an append-only log of approaches we
tried, why they broke, and what we learned. Newest at the top. Append to
it whenever a change is reverted, a phase regresses unexpectedly, or a
fix turns out to be wrong. Don't re-litigate items unless the entry's
"if we revisit" guidance changes.

## Tooling — DON'T reinvent these inline

The full build/deploy/bench loop is scripted. Don't write inline ssh+make
heredocs; invoke the scripts:

```
# Naming: build TARGET names (g3/g4/lion) refer to chip family + SDK,
# NOT a machine. Machine names (yosemite/sawtooth/quicksilver/mini-g4/
# mini-intel) refer to specific bench Macs. The single g4 binary serves
# three machines (sawtooth, quicksilver, mini-g4); see deploy.sh for
# the machine→binary map.

scripts/build.sh <g3|g4|lion>          cross-compile (g3/g4) or native x86_64 (lion)
                                       on the cross-build host (mini-intel)
scripts/deploy.sh <yosemite|sawtooth|quicksilver|mini-g4|mini-intel>
                                       assemble Quakespasm.app, ship to <machine>
scripts/bench.sh <machine> <demo> <WxH> [runs]
                                       run timedemo, append to results.csv
                                       machine ∈ {yosemite,sawtooth,quicksilver,mini-g4,mini-intel}
scripts/full-bench.sh [<machine>|ppc|all] [--quick]   matrix sweep
                                                      ppc = 4 PPC machines
                                                      all = all 5 machines
scripts/parallel-bench.sh [--quick] [--no-yosemite] [--no-sawtooth]
                                    [--no-quicksilver] [--no-mini-g4] [--no-mini-intel]
                                       all 5 legs concurrently by default
                                       env: DEMOS, RESES, RUNS for custom
scripts/setup-lion.sh             bootstrap fresh cross-build host from prereqs/
                                  (env BUILD_HOST=mini-intel by default)
scripts/parse_qconsole.py <log>   extract fps + GL info from a raw log
scripts/build-fat.sh              build a 3-arch (ppc750+ppc7400+x86_64) universal
                                  binary by composing g3/g4/lion sub-builds with
                                  lipo. Output: build/quakespasm-fat.
scripts/deploy.sh fat <machine>   ship build/quakespasm-fat to <machine> with all
                                  three per-arch autoexec files in id1/. Engine
                                  hook in host.c:891 picks the right slice's
                                  autoexec at boot via __VEC__ / __ppc__ /
                                  __x86_64__ macros. (Per-machine form
                                  scripts/deploy.sh <machine> still works for
                                  pure single-arch builds.)
scripts/screenshot.sh <machine>   drive the deployed Quakespasm fat (or per-target)
                                  through demo1/demo2/demo3 with `screenshot tga`
                                  inserted at intervals. Saves into
                                  ~/Desktop/quakespasm-screens-<hostname>/ on the
                                  target and fetches a copy to
                                  benchmarks/screenshots/<host>/. Tunable shot
                                  density via SHOTS_PER_DEMO + WAITS_BETWEEN_SHOTS
                                  in the script.
scripts/install-host-tools.sh     push scripts/host-bin/* to ~/bin on every
                                  bench Mac. Idempotent, re-run after editing
                                  qsreboot.sh or adding a machine.
scripts/host-bin/qsreboot.sh      runs ON the Mac. Reboots through `sudo -n
                                  /sbin/reboot` (Tier 1, definite, works
                                  through wedged Finder / corrupt LUT) with
                                  Finder Apple Event as Tier 2 fallback.
                                  Use as: ssh <host> '~/bin/qsreboot.sh'
scripts/host-bin/qsreboot-setup.sh runs ON the Mac. ONE-TIME `sudo
                                  ~/bin/qsreboot-setup.sh` per machine to
                                  install the NOPASSWD sudoers entry. Backs
                                  up /etc/sudoers, validates with `visudo
                                  -c`, restores backup on syntax failure.
                                  Idempotent.
```

**Host-side reboot recovery.** When Quake hard-kills in fullscreen on G3,
Panther's Rage 128 driver leaves the display LUT corrupt — black screen,
mouse moves, OS alive over SSH. Apple-menu Restart fails because Finder
itself can be wedged. After running `qsreboot-setup.sh` once per
machine, `ssh <host> '~/bin/qsreboot.sh'` from the orchestration host
issues a kernel-level reboot regardless of display/Finder state. This
is the canonical recovery path; do not power-cycle unless qsreboot.sh
itself has been verified failed (very rare — would mean sudoers got
mangled, in which case the in-script visudo -c restore should have
caught it).

There's also a `ppc-ops` skill (`.claude/skills/ppc-ops/SKILL.md`) and
`/bench` + `/deploy` slash commands that wrap these. See
`scripts/README.md` for the full contract.

`prereqs/` contains vendored installers (Xcode 3.2.6 DMG, Xcode 2.5 DMG
for the 10.3.9 SDK only, SDL 1.2.15 source) so the project remains
self-buildable if Apple's archive ever goes dark. Total ~5 GB; do not
push to a free GitHub remote without git-lfs.

## Goal in one line

Ship the **best-looking** QuakeSpasm port for G3 Panther + G4 Tiger +
Lion Intel — keeping framerate "comfortably playable" on each (≥ 60 fps
on G4, ≥ 60 fps on Lion, ≥ 20 fps on G3) but **not** treating raw fps
as the only optimisation target. Visual upgrades that cost 10-15% fps
are in scope when they leave the cell above its playability threshold.
Lion itself is also a runnable bench reference (added 2026-05-08) —
third data point that helps separate GPU-bound from CPU-bound effects,
since GMA 950 + Core 2 Duo has a markedly different fillrate-vs-CPU
balance than either PPC.

**Toggleability is a hard requirement.** Every per-target visual /
perf knob must be flippable at runtime (cvar) or at launch
(command-line flag) so end-of-round code review can A/B individual
contributions without a rebuild. See "Toggleable knobs" below for the
current inventory.

## Toggleable knobs (current inventory, 2026-05-08)

Every per-target visual / perf decision shipped to date can be flipped
without rebuild — most via cvars, some via launch-time `-flag` parsed
in the relevant `*_Init`. Listed by class so end-of-round tuning has
a complete map.

**AltiVec phase opt-outs (cmdline, G4 only — `-flag` to disable):**

| Flag             | Phase  | Default     | What it gates                                  | File parsed |
|------------------|--------|-------------|------------------------------------------------|-------------|
| `-noaltivec-snd` | 4.2    | enabled     | 16-bit sound mixer (`SND_PaintChannelFrom16`)  | `snd_dma.c` `S_Init` |
| `-altivec-lm`    | 4.4    | **disabled** (opt-in) | Lightmap compose loop (`R_BuildLightMap`) — regressed -0.5..-2.3% in smoke; round v3 retest 2026-05-08 (Task #9) confirmed net-zero on demo3 1024 (quicksilver -0.4% noise, mini-g4 fillrate-bound). Preserved in tree. See PPC_PLAN.md §13.2 status. | `gl_rmisc.c` `R_Init` |
| `-noaltivec-mip` | 4.5    | enabled     | Mipmap chain build (`TexMgr_MipMap{W,H}`) — load-time only | `gl_texmgr.c` `TexMgr_Init` |
| `-altivec-dlights` | §14.3 item 4 | **disabled** (opt-in) | Per-texel attenuation in `R_AddDynamicLights` — neutral in smoke (gate restricts AltiVec to ~30% of pixels; stack-spill erodes FP-mul win). Round v3 retest 2026-05-08 confirmed neutral alongside `-altivec-lm`. Preserved in tree. | `gl_rmisc.c` `R_Init` |

**Diagnostics (cmdline + cvar, both targets):**

| Flag/cvar      | Phase | Default | What it does |
|----------------|-------|---------|--------------|
| `-perfprint` (cmdline) / `gl_perfprint` (cvar) | 7 | 0 (silent) | Per-region renderer timing every 60 frames — see Quake/gl_perfprint.h for region list |

**Visual cvars (runtime, set in `scripts/bundle/autoexec-<machine>.cfg`):**
Per-machine configs live at `scripts/bundle/autoexec-{yosemite,sawtooth,quicksilver,mini-g4,mini-intel}.cfg`.

| Cvar                    | G3 default | G4 default | Lion default | Notes |
|-------------------------|------------|------------|--------------|-------|
| `r_oldwater`            | 1 (classic warp) | 0 (new shader) | (engine default) | G3 set 1 because Rage 128 R128 has a refraction bug at 640 with new shader; G4 has the headroom. Phase 0 + Round v2 epilogue. |
| `r_particles`           | 2          | (default 1) | (default)    | G3 reduced particle quality. Phase 0. |
| `gl_texture_anisotropy` | (default 1) | 8           | (default)    | G4 anisotropic filtering. Phase 0. |
| `r_shadows`             | (default 0) | 1           | (default)    | G4 alias drop-shadow. §13.6, costs -11% but stays > 60 fps. Defensively re-cleared in autoexec because CVAR_ARCHIVE makes a stale `1` from any past session sticky. |
| `gl_texturemode`        | (default GL_LINEAR_MIPMAP_NEAREST) | `GL_LINEAR_MIPMAP_LINEAR` (trilinear) | (default) | G4 trilinear pairs with anisotropy 8. §13.6. |
| `r_shadow_distance`     | (default 0 = unlimited) | 512 | (default 0) | Pass C HIGH (Round v3 Task #10): elide shadow draws past N units from viewer. Engine default 0 preserves upstream; G4 sets 512 for ~4-7% on dlight-heavy demos. Squared compare in `R_DrawShadows`. |
| `gl_texture_lodbias`    | (default 0)            | -1.5         | 0            | Round v4 Task #20: bias the diffuse-texture mipmap LOD selection. User reported soft mips on G4 / Radeon 9000 distant brick walls; Lion / GMA 950 unaffected on the same engine. Negative pulls sharper mip chains. Wired via `glTexEnvf(GL_TEXTURE_FILTER_CONTROL_EXT, GL_TEXTURE_LOD_BIAS_EXT, …)` in `gl_texmgr.c`. Inert if neither GL 1.4 nor `EXT_texture_lod_bias` is present (R128 falls back silently). |
| `r_dynamic_distance`    | 768                    | (default 0)  | (default 0)  | Round v5 B1: elide dlight BSP-mark + surface-reblend pass past N units from viewer. R128 has no fragment-shader dlight path, so each dlight = full extra GPU pass per touched surface. G3 GPU-bound regime ⇒ removing GPU work is the only fps lever. G4/Lion left at 0 = unlimited (they have headroom). Squared compare in `R_PushDlights`. Headline G3 lever — expect +5–15% on demo3 (dlight-heavy). |
| `r_wateralpha`          | 0.6                    | 0.6 (all 3)  | 0.6          | Round v5 wrap pass 2 (2026-05-09): plain water translucency. Same path as the existing `r_lavaalpha`/`r_telealpha`/`r_slimealpha` 0.6 family — see-through liquid surfaces. On classic-warp targets (yosemite/sawtooth/mini-intel) goes through the `R_DrawTextureChains_Water` `R_OldWaterEffective()` branch; on shader-water targets (quicksilver/mini-g4) goes through the GLSL alpha uniform. Negligible cost across all targets. |
| `r_shadow_distance` (Lion) | (n/a)                | 512 (G4 trio)| 512          | Round v5 wrap pass 2 (2026-05-09): added to `mini-intel` autoexec to free GMA 950 fillrate on demo3 1024 (was fillrate-bound at 44.90 fps with shadows + trilinear + aniso). Mirrors the G4 trio's value. |
| `gl_clear`              | 0 | 0 (quicksilver + mini-g4 only — sawtooth stays at 1) | 0           | Round v5 wrap pass 3 (2026-05-09): skip per-frame backbuffer clear. Quake's world+sky covers 100% of the screen so the clear is a redundant fillrate-bound write. Wins: yosemite +4.7%, mini-intel +3.5%, quicksilver +7.1%, mini-g4 +9.3% on demo3 1024. **Sawtooth regresses -2.1%** (GeForce2 MX driver quirk — no-clear path is slower than the explicit clear), so sawtooth stays at engine default 1. Visually verified clean on yosemite e1m1 (sky + water — no ghosting at sky edges, no garbage artifacts). |

**Hard-coded (no runtime toggle yet) — flag if a future round wants
to A/B these:** Phase 1 `frsqrte` mathlib, Phase 1.1 client vertex
arrays + CVA, Phase 2.1 BGRA `8_8_8_8_REV` lightmap upload, Phase 2.2
APPLE_client_storage, Phase 2.3 STORAGE_CACHED_APPLE per-texture hint,
Phase 3.1/3.2/3.3 APPLE_vertex_array_range pool + multitex array
conversion, Phase 4.1 + 4.6 alias lerp + color fuse AltiVec. Most of
these are foundational and bisected at landing time; not worth a
runtime toggle unless a regression is suspected. Add a
`-noaltivec-lerp` (Phase 4.1 + 4.6) follow-up if end-of-round review
wants to A/B alias-side AltiVec specifically.

**§14.3 hygiene flag added:** `-nowarpedarrays` falls the
`R_UpdateWarpTextures` water-warp procedural-update loop back to its
pre-§14.3 glBegin/glEnd path. Default is the new client-array path
(submission-overhead reduction; smoke neutral on standard demos
because they barely exercise warp updates).

**Pass B B6 retest hatch:** `-r128-cva` (G3 only — Rage 128 detection)
overrides the default skip of `glLockArraysEXT` on R128 so we can
revisit whether the Phase 2.x lightmap pipeline incidentally fixed
the in-game colour-band corruption. Default unchanged: R128 still
skips Lock automatically. Parsed in `gl_vidsdl.c` `GL_CheckExtensions`.
G4/Lion are unaffected — they get CVA Lock as before.

**Why this matters:** project goal is best-looking Quake at
playable fps; the only way to navigate that trade-space honestly is
to be able to flip individual contributions at runtime and watch
fps + visuals together. Gate any new perf or visual phase behind a
named knob unless you have a strong reason not to (e.g. a code-size
win that's only realised by removing the scalar fallback).

## Hosts (5 bench machines, named by Apple codename / form-factor)

SSH aliases live in `~/.ssh/config`. Renamed 2026-05-09 to nicer names —
the rename round added the new G4 (sawtooth) at the same time. Historical
CSV rows tagged with the OLD names (`g3`, `g4`, `g4mini`, `lion`) refer
to the same hardware as `yosemite`, `quicksilver`, `mini-g4`, `mini-intel`
respectively.

- `yosemite` — PowerMac1,1 Blue & White G3, 449 MHz PPC 750, Rage 128
  16 MB AGP, 10.3.9 Panther. Apple codename "Yosemite".
- `sawtooth` — PowerMac3,1 G4 AGP tower (1999), 500 MHz PPC 7400, NVIDIA
  GeForce2 MX 32 MB AGP, 10.4.11 Tiger. AltiVec. **Only fixed-function G4
  in the matrix** (GeForce2 MX has no fragment shaders). Added 2026-05-09
  as the third G4 data point. Apple codename "Sawtooth".
- `quicksilver` — PowerMac3,5 Quicksilver G4 tower (2001-2002), 733 MHz
  PPC 7450, ATI Radeon 9000 Pro 64 MB AGP, 10.4.11 Tiger. AltiVec.
  Apple codename "Quicksilver".
- `mini-g4` — PowerMac10,1 Mac mini G4 first-gen (2005), 1.25 GHz PPC
  7447A, ATI Radeon 9200 32 MB AGP, 10.4.11 Tiger. AltiVec. Different
  GPU class from Quicksilver (Radeon 9200 32MB vs 9000 Pro 64MB) — useful
  for separating CPU-bound from fillrate-bound effects within the G4 family.
- `mini-intel` — Macmini2,1 Mac mini Intel (mid-2007), 2.33 GHz Core 2 Duo
  T7600, Intel GMA 950 64 MB shared, 10.7.5 Lion. **Dual role:** the
  cross-build host for G3 + G4 PPC binaries (gcc-4.0 + 10.3.9/10.4u SDKs),
  and a bench target in its own right via native x86_64 build (`/usr/bin/clang`,
  no `-isysroot`). **Sleeps aggressively** (system sleep timer is short);
  if `build.sh` fails with `ssh: connect to host ... No route to host`,
  the box is asleep — wake it (Wake-on-LAN, key press, or `caffeinate`
  if you've configured one) and retry.

The three G4 machines (`sawtooth`, `quicksilver`, `mini-g4`) all share
the same `build/quakespasm-g4` binary — `-mcpu=7400 -maltivec` is
correct for all three. The 7450 and 7447A run 7400 baseline code happily;
`-mtune=7450` is just scheduling hints.

Hardware lineup spans the GPU axis:
- yosemite (Rage 128) and sawtooth (GeForce2 MX): fixed-function GPUs,
  no fragment shaders. Each dlight = full extra blending pass.
- quicksilver (Radeon 9000 Pro 64MB) and mini-g4 (Radeon 9200 32MB):
  programmable-pipeline GPUs but pre-shader-model-2.0; shaders work
  but engine doesn't use them on PPC.
- mini-intel (GMA 950): GL 1.4 only, no GLSL.

So GLSL paths are inert across the entire matrix.

Old-Mac SSH (Lion + PPC) needs legacy crypto. The config entries already
include `HostKeyAlgorithms +ssh-rsa`, `PubkeyAcceptedKeyTypes +ssh-rsa`,
`KexAlgorithms +diffie-hellman-group-exchange-sha1[,group14-sha1[,group1-sha1]]`,
and use `id_rsa_tiger` (RSA, not ed25519 — pre-2014 OpenSSH can't validate
ed25519). Ad-hoc `ssh user@ip` without these flags will fail.

## Don't run `scripts/bench.sh` legs in parallel from one shell

A `bench.sh yosemite ... &` plus `bench.sh quicksilver ... &` from the
same workstation shell stresses the local network/ssh stack and can
produce a wrong G3 fps reading — observed 14.7 fps when run concurrent
with a G4 cell, vs 23.1 fps the same binary delivers run alone. Both runs completed
successfully (no crash, no timeout); the G3 just churned through
demo1 in ~3× the wall time. Use `parallel-bench.sh` for the proper
concurrent matrix — it has its own log redirection and process
management — or run cells serially with `bench.sh`.

## Don't run `scripts/build.sh g3` and `g4` in parallel

Both invocations rsync to the same `mini-intel:quakespasm/` path and `make -j2`
in `mini-intel:quakespasm/Quake/`. Concurrent builds race on the `.o` files and
the resulting binary gets stamped with the *other* target's CPU subtype.
Specific failure mode: G3 binary ends up `ppc7400`, Panther loads it
anyway, then crashes during AppKit NIB init (`-[NSCustomObject
nibInstantiate]` → `class_initialize` → `0xfffeff00`) when the runtime
hits G4-compiled library code on a 750. `scripts/build.sh` now takes a
flock to serialize, but if you bypass the script you must serialize
yourself. **`scripts/parallel-bench.sh` is fine** — it parallelizes the
*bench* legs (separate target machines), not the build.

After any build, sanity-check: `file build/quakespasm-g3` must report
`ppc_750` (or generic `ppc`); `file build/quakespasm-g4` must report
`ppc_7400`. Anything else is the race.

## Build path: `Quake/Makefile.darwin`, NOT the Xcode project

`MacOSX/QuakeSpasmPPC.xcodeproj` exists but `objectVersion=42` requires Xcode
3.2+, doesn't differentiate G3 from G4, and is more annoying than the
makefile. We use `Quake/Makefile.darwin` with `MACH_TYPE=ppc` and inject SDK +
`-mcpu` via `CPUFLAGS`/`LDFLAGS`.

## Toolchain on Lion (installed)

```
/usr/bin/gcc-4.0                              Apple gcc 4.0.1 (build 5494) — PPC cross
/usr/bin/clang                                Apple clang (Lion default) — Intel native
/usr/bin/gcc-4.2                              llvm-gcc-4.2.1 — Intel fallback
/Developer/SDKs/MacOSX10.3.9.sdk              G3 (Panther) target
/Developer/SDKs/MacOSX10.4u.sdk               G4 (Tiger) target
/Developer/SDKs/MacOSX10.5.sdk                bonus, unused
```

Per-target flags (full set, including the `-isysroot` and version-min):

- G3:   `-isysroot /Developer/SDKs/MacOSX10.3.9.sdk -mmacosx-version-min=10.3.9 -arch ppc -mcpu=750 -O3`
- G4:   `-isysroot /Developer/SDKs/MacOSX10.4u.sdk  -mmacosx-version-min=10.4   -arch ppc -mcpu=7400 -maltivec -mabi=altivec -O3 -mtune=7450`
- Lion: `-arch x86_64 -mmacosx-version-min=10.7 -O3` (no `-isysroot`; uses
  Lion's default toolchain SDK). Lion's kernel is `RELEASE_I386` on
  Macmini2,1, but Core 2 Duo + 10.7's user-space happily run x86_64 binaries.

Cosmetic linker warnings about `-mlong-branch` from Apple's `crt1.o`/`crt2.o`
are harmless on PPC builds. Suppress with `-Wl,-w` if noisy.

## Bundle is fully universal — same layout serves all four targets

`MacOSX/SDL.framework` is fat (x86_64 + i386 + ppc) where the **ppc slice
is the Panther-compatible 10.3.9-SDK build**, not the 10.6-SDK build that
ships upstream. `MacOSX/codecs/lib/*.dylib` are all fat too. Combined
with the fat engine binary (`build/quakespasm-fat` — ppc750 + ppc7400 +
x86_64), `deploy.sh fat <target>` ships the same bundle byte-for-byte
to G3, G4, G4mini, and Lion. The only per-host action `deploy.sh` takes
is rsync.

## How the fat SDL was built (round v4 §14.5)

Until round v4 we shipped the upstream fat SDL (10.6 SDK) and ran a
per-host swap in `deploy.sh g3` that overlaid `MacOSX/SDL-panther.dylib`
on top of `Versions/A/SDL`. The swap is gone — the bundled framework
itself now carries the Panther slice. To regenerate it from a fresh
upstream fat (e.g. on an SDL version bump):

```sh
# On Lion (lipo + install_name_tool live there)
cp upstream-SDL.framework/Versions/A/SDL /tmp/SDL-fat-orig
install_name_tool -id "@executable_path/SDL.framework/Versions/A/SDL" /tmp/SDL-fat-orig
lipo -replace ppc /path/to/MacOSX/SDL-panther.dylib /tmp/SDL-fat-orig \
     -output /path/to/MacOSX/SDL.framework/Versions/A/SDL
```

`SDL-panther.dylib` is a ppc-only SDL 1.2.15 built against 10.3.9 SDK
with `--disable-video-x11 --disable-altivec --disable-cdrom`. Why it's
needed: upstream's PPC slice was linked against the 10.6 SDK and crashes
inside `SDL_VideoInit + 608` on Panther (jumps to a Quartz address that
doesn't exist on 10.3). The Panther slice still loads and works on
Tiger and Lion, so one slice covers both PPC OS versions.

Why `install_name_tool -id` first: dyld matches LC_LOAD_DYLIB against
the loaded slice's LC_ID_DYLIB. The upstream framework's three slices
were id'd `@executable_path/../Frameworks/SDL.framework/...`, which
doesn't match where we actually drop it. Re-iding all three to
`@executable_path/SDL.framework/Versions/A/SDL` aligns with the engine
binary's install_name fixup in `scripts/build.sh:109`.

The bundled SDL also presents a version mismatch on G4 even when it
loads: the system `/Library/Frameworks/SDL.framework` (if present from
Fruitz of Dojo) is 1.2.7, too old for our binary (linked against
current_version=12.5.0). We always ship our own SDL alongside the
binary, never rely on the system one.

## Tiger/Panther Cocoa requires a real .app bundle

Bare-binary launch via SSH fails with `"No Info.plist file in application
bundle or no NSPrincipalClass in the Info.plist file"`. After fixing
that, you also need `NSMainNibFile=Launcher` referencing the compiled
`MacOSX/English.lproj/Launcher.nib/`. Required Info.plist keys:

```
CFBundleExecutable=quakespasm
NSPrincipalClass=SDLApplication
NSMainNibFile=Launcher
CFBundleIconFile=QuakeSpasm
CFBundlePackageType=APPL
```

Pass `-nolauncher` in args (handled in `MacOSX/AppController.m:135`) to
skip the launcher GUI window and go straight to the game. `bench.sh`
passes this automatically.

## Panther's `/bin/sleep` is integer-only

`sleep 0.2` on Panther (10.3) returns immediately — old BSD sleep doesn't
parse fractional seconds. Tiger's `sleep` does. **Any poll loop running on
G3 must use integer sleeps**, otherwise it busy-spins through `POLLS` in
~20 seconds and SIGKILLs Quake before the timedemo line lands in
qconsole.log. `bench.sh` uses `sleep 1` for this reason — the 1-second
detection latency is fine.

## ssh remote `cd && X &` puts cd in the subshell

`ssh host "cd /foo && rm -f bar && ./prog &"` parses as `(cd && rm && ./prog) &`
because `&&` binds tighter than `&`. The whole chain runs in a background
subshell, the parent shell's cwd never changes, and `[ -f bar ]` in the
parent shell checks `$HOME/bar`, not `/foo/bar`. Put `cd` and `rm` on
their own foreground lines and `&` only the long-running command.

## Killing the engine reliably

QuakeSpasm spawns SDL/CoreAudio threads that don't always respond to
SIGTERM. Use `killall -KILL quakespasm` after a brief SIGTERM grace
period. **Don't use `pkill`** — Tiger and Panther don't have it.
`bench.sh` does this dance automatically.

## Required patches for our target build (already applied in working tree)

Four patches needed for clean compile + runtime on G3 Panther + G4 Tiger.
All committed; not upstream-able without sniff macros.

**1. `Quake/pl_osx.m:92-95`** — replace Obj-C 2.0 dot-notation (gcc-4.0 can't
parse it) with traditional setter calls:

```objc
[alert setAlertStyle: NSAlertStyleCritical];
[alert setMessageText: @"Quake Error"];
[alert setInformativeText: msg];
```

**2. `MacOSX/QuakeArguments.m`** — wrap `[NSString stringWithCString:encoding:]`
and `[NSString cStringUsingEncoding:]` (10.4+ APIs) in
`QSpasmStringFromCString` / `QSpasmCStringFromString` macros that route
to the deprecated `cString` / `stringWithCString:` variants on Panther.
Without this the binary crashes inside `[QuakeArguments init]` with
"unrecognized selector" when targeting 10.3.

**3. `MacOSX/AppController.m`** — same NSString-encoding fix at line 173.

**4. `Quake/gl_vidsdl.c:1381–1390`** — wrap the multi-threaded OpenGL block
in `#if MAC_OS_X_VERSION_MAX_ALLOWED >= 1040`. `kCGLCEMPEngine` is 10.4.8+
and doesn't exist in the 10.3.9 SDK headers. B&W G3 is single-core so the
runtime check would skip the call anyway:

```c
#ifdef __APPLE__
#if MAC_OS_X_VERSION_MAX_ALLOWED >= 1040
    if (host_parms->numcpus > 1 &&
        kCGLNoError != CGLEnable(CGLGetCurrentContext(), kCGLCEMPEngine))
    {
        Con_Warning ("Couldn't enable multi-threaded OpenGL");
    }
#endif
#endif
```

## Codebase facts you can't grep for

**No software renderer.** QuakeSpasm dropped FitzQuake's software path; it's
GL-only. Anything about "palette blit hot path" or "software inner loops"
doesn't apply.

**No existing PPC-specific code anywhere.** No `__VEC__`, `<altivec.h>`,
`frsqrte`, or asm. Greenfield.

**Two `SSE` mentions are defensive, not SSE code.** `gl_model.c:1414` and
`gl_rlight.c:326` cast lightmap-extent calcs to `double` to dodge x87/SSE2
precision drift. Universally safe; nothing to patch out.

## Hot files for the optimization phase

- `Quake/mathlib.c:276,281` — `VectorLength`, `VectorNormalize` use scalar
  `sqrt`. Target for `frsqrte` (~6 cyc vs ~30, base PowerPC, helps both G3
  and G4).
- `Quake/snd_mix.c:472,498` — `SND_PaintChannelFrom8/16`, sound mixer hot
  loops. AltiVec target (G4 only).
- `Quake/gl_texmgr.c` — `TexMgr_LoadImage8` 8→32 bit expansion at level
  load. Load-time, not per-frame.

## Build strategy: phase 1 = two binaries, no runtime dispatch yet

We ship `quakespasm-g3` and `quakespasm-g4` as separate binaries through
phase 1. Runtime dispatch (function pointers via `sysctlbyname("hw.optional.altivec")`)
is phase 2, after a few AltiVec wins are validated. Bisectable A/B comparison
is the priority — don't pile dispatch on top of in-progress AltiVec code.

## Benchmark discipline

Canonical: Quake's `timedemo demo1` / `demo2` / `demo3`. **3× runs, median
of 2 & 3.** Both G3 and G4 every change. Capture `qconsole.log` via
`-condebug`. Tag results with `(commit, machine, demo)`. **No source
changes beyond the `pl_osx.m` patch until clean baseline numbers exist
for both targets on unmodified upstream.**

## Bench-and-commit cadence (don't skip)

`benchmarks/results.csv` is a **rolling history** that grows across
every phase — that's how we see the optimization trajectory and decide
whether to reorder upcoming phases. **Never wipe it mid-round.** The
default of `parallel-bench.sh` is now append (was wipe; flipped 2026-05-07
after this exact mistake almost cost us the v2 baseline).

Every phase landing on master gets a smoke bench (`--quick`: demo1 ×
1024×768 + 640×480 × 3 runs, both targets, ~3-4 min) and the resulting
CSV rows + raw logs **must be committed** before the next phase starts.
Full grid (3 demos × 2 res × 3 runs) is reserved for end-of-round, after
all phases land — that's where we measure the cumulative trajectory.

Rationale (2026-05-07): full-grid per-phase was costing ~20 min of wall
time per landing, which throttles plan progress. Smoke catches
regressions and proves the change builds + runs; the demo3 dynamic-light
wins (Phase 2.x) and brush-heavy wins (Phase 3.x) only show clearly in
full grid anyway, and we measure those once at the end.

Per-phase shape:

1. **Edit + build + deploy** the phase.
2. **Smoke** (dirty tree, throwaway): `scripts/parallel-bench.sh --quick`.
   Used only to catch broken builds + gross regressions; rows tag with
   parent commit hash because tree is dirty. Strip these rows from CSV
   before continuing (`git checkout benchmarks/results.csv && rm -f
   benchmarks/raw/<parent>_*.log`).
3. If smoke is sane (no crash, no unexplained >5% regression on either
   target), **commit the code change** with the smoke numbers in the
   message body.
4. **Bench-commit in one shot** (post-commit, clean tree, official rows):
   ```
   scripts/bench-and-commit.sh "Phase 2.1 BGRA lightmaps" --quick
   ```
   This: refuses dirty trees, pins HEAD, runs the smoke grid (CSV rows
   tag with the phase commit hash), stages `results.csv` + the new
   `raw/<commit>_*.log` files, and lands a `bench: <phase>` commit with
   median fps summary in the message.

Two commits per phase (code + bench) is the price of clean attribution.

**End of round (after all phases land):** run the full grid once
(`scripts/bench-and-commit.sh "v2 round wrap" `, no `--quick`) to
capture the cumulative trajectory across all 3 demos.

**Hash stability:** `parallel-bench.sh` resolves HEAD once at start and
exports `$COMMIT`; `bench.sh` honors it. Side commits during a long
bench can't drift the row tags. (Before 2026-05-07, `bench.sh`
re-resolved per cell, and the v2-baseline last cell got mis-tagged
because a docs commit landed mid-bench.)

**Negative results still get committed** — they're signal for redirecting
upcoming phases. If smoke surfaces an unexpected regression, name it in
the bench commit (`bench: Phase 2.1 [REGRESSED] (HEAD ...)`) and decide
whether to revert before continuing. Don't discard the data.

**`--reset` is a fresh-epoch action only.** `parallel-bench.sh --reset`
wipes `results.csv` (after backing it up to `results.csv.bak.<ts>`).
Reserved for starting a brand-new optimization round.

**Manual-commit override when bench-and-commit refuses on a transient
flake.** `parallel-bench.sh` is strict: if any single run returns NA fps
(SIGTERM-before-qconsole-write, ssh hiccup, etc.) the leg returns
non-zero and `bench-and-commit.sh` refuses to commit anything. That's
the right default for "real" failures (binary crash, regression on
every run) but too harsh when you've got 23/24 cells clean and one
transient. **Recovery pattern (used 2026-05-08 for v3 round wrap):**
verify the failure is transient (other runs of the same cell hit
sane fps, or re-running the cell standalone via `scripts/bench.sh
<host> <demo> <res> 3` succeeds), then `git add benchmarks/results.csv
benchmarks/raw/<commit>_*.log` and craft a manual `bench: <phase>
(HEAD <commit>) — N.5/N cells` commit naming the partial cell in the
body. Don't hide the NA; do commit the rest. The data is signal even
when one row has fewer-than-three valid runs.

## Runtime packaging on Tiger (G4) — required structure

Tiger's Cocoa requires a real `.app` bundle to launch a binary that uses
NSApplication. Bare-binary launch fails with `"No Info.plist file in
application bundle or no NSPrincipalClass in the Info.plist file"`. After
that's fixed, you also need `NSMainNibFile=Launcher` referencing the
compiled `Launcher.nib` from `MacOSX/English.lproj/`.

Bundle layout that works:

```
~/Desktop/quake/                       ← basedir; cwd at launch
  Quakespasm.app/
    Contents/
      Info.plist                       ← CFBundleExecutable=quakespasm,
                                          NSPrincipalClass=SDLApplication,
                                          NSMainNibFile=Launcher,
                                          CFBundleIconFile=QuakeSpasm
      MacOS/
        quakespasm                     ← @executable_path resolves here
        lib*.dylib (10 codec dylibs)   ← per binary's install_names
        SDL.framework/                 ← after install_name_tool fix
                                          (was @executable_path/../Frameworks)
      Resources/
        QuakeSpasm.icns
        English.lproj/
          Launcher.nib/
          InfoPlist.strings
  id1/, hipnotic/, rogue/              ← game data (basedir level)
  quakespasm.pak                       ← engine pak (basedir level)
```

Pass `-nolauncher` in args so `AppController.applicationDidFinishLaunching:`
skips the launcher GUI and goes straight to `launchQuake:` (line 135 of
`MacOSX/AppController.m`).

`install_name_tool` fixup (run on Lion before shipping):

```
install_name_tool -change \
  @executable_path/../Frameworks/SDL.framework/Versions/A/SDL \
  @executable_path/SDL.framework/Versions/A/SDL \
  quakespasm
```

System SDL.framework on a typical Tiger install is too old (1.2.7) for our
binary (linked against current_version=12.5.0 i.e. 1.2.16). Always ship
our framework alongside.

## Timedemo invocation pattern that actually works

`+timedemo demo1 +timedemo demo1 +timedemo demo1 +quit` in a single launch
**does not work** — they stomp each other in the cmd buffer; first frame
runs all four commands, demo runs zero frames, `+quit` kills the process.
You get `-1 frames 0.0 seconds` per "run."

Correct pattern: **3 separate launches, one `+timedemo demo1` each, no
`+quit`. Poll `qconsole.log` for the result line, kill the process via
SIGTERM when found.** See `bench.sh` (when written) — for now it's the
inline shell loop in PPC_PLAN.md.

## Workflow shape

```
Ubuntu (edit, git, orchestrate)
   │
   ├── rsync sources ──▶ Lion (cross-build PPC + native x86_64)
   │                          │
   │◀────── scp binary ───────┘     (per-target binary fetched back)
   │
   ├── deploy bundle ──▶ G4 / G3 / Lion (run timedemo, write qconsole.log)
   │                                       │
   │◀────────── scp qconsole.log ─────────┘
   │
   └── append CSV row to benchmarks/results.csv
```

Lion has dual role: it's the build host for G3+G4 cross-compiles, AND its
own bench target via native x86_64 builds. Ubuntu still orchestrates all
three legs (Lion never ssh's anywhere outbound).

Game data layout on Lion mirrors the PPC machines: `~/Desktop/quake/{id1,
legacy,quakespasm.pak,Quakespasm.app}`. Game data was rsync'd from G4 → Ubuntu →
Lion when the Lion target was added (Lion's own build tree is at
`~/quakespasm/`, kept separate from the runtime layout).
