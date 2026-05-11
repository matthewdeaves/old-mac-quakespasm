# QuakeSpasm — six old Macs, one fat binary

[![License: GPL v2](https://img.shields.io/badge/License-GPL_v2-blue.svg)](LICENSE.txt)
[![Platform: PowerPC + Intel macOS](https://img.shields.io/badge/Platform-PowerPC%20%7C%20Intel%20macOS-lightgrey.svg)](#the-bench-fleet)
[![macOS: 10.3.9 → 15.7](https://img.shields.io/badge/macOS-10.3.9%20%E2%86%92%2015.7-success.svg)](#the-bench-fleet)
[![Engine: QuakeSpasm fork](https://img.shields.io/badge/Engine-QuakeSpasm%20fork-red.svg)](https://github.com/sezero/quakespasm)

<p align="center">
  <img src="docs/images/quakespasm-icon-256.png" width="120" alt="QuakeSpasm icon" />
</p>

A QuakeSpasm fork tuned to look as good as possible while staying playable on **six retro Macs spanning 1999–2019**. One source tree, one fat universal binary (PPC G3 + PPC G4 AltiVec + Intel x86_64), per-machine config picked at boot via `sysctl hw.model`.

<p align="center">
  <img src="docs/screenshots/sawtooth_spasm0010.webp" width="24%" alt="Sawtooth G4 / GeForce2 MX" />
  <img src="docs/screenshots/quicksilver_spasm0040.webp" width="24%" alt="Quicksilver G4 / Radeon 9000" />
  <img src="docs/screenshots/mini-intel_spasm0070.webp" width="24%" alt="Mac mini Intel / GMA 950" />
  <img src="docs/screenshots/imac-2019_spasm0010.webp" width="24%" alt="iMac 27&quot; 2019 / Radeon Pro 580X" />
</p>

## fps improvement (Yosemite B&W G3, 449 MHz / Rage 128)

Vanilla v2-baseline (`4c165e6f`, early-port pre-Phase-0) → current Round v11.1 (`d64427db`):

| Cell | Before | After | Improvement |
|---|---:|---:|---:|
| **demo3 1024×768** | 5.10 fps | **20.95 fps** | **+311% (4.1×)** |
| demo1 1024×768 | 7.70 fps | 17.35 fps | +125% (2.3×) |

Baselines from [`PPC_PLAN.md §17.7.1`](PPC_PLAN.md). 640×480 cells weren't formally baselined at the v2-baseline checkpoint, so they're omitted here — current numbers are in the full grid below.

…with translucent water, alias drop-shadows, emissive-fullbright dynamic lights, watervis NoVis (auto-engine), classic warped water (Rage 128 framebuffer-copy refraction bug), reduced particles, coarser warp tessellation, `gl_clear 0`, and a per-frame dynamic-light distance gate. Lava / slime / teleporter alpha was dropped on G3 in [Round v8 followup](MISTAKES.md) — `r_lavaalpha 0.6` alone dropped demo3 1024 by 26% on Rage 128, pushing G3 below the 20-fps floor.

## The bench fleet

| Machine | CPU | GPU | OS | Default res |
|---|---|---|---|---:|
| **Yosemite** (PowerMac1,1 B&W G3, 1999) | 449 MHz PPC 750 | ATI Rage 128 16 MB | 10.3.9 Panther | 800×600 |
| **Sawtooth** (PowerMac3,1 G4 AGP, 1999) | 500 MHz PPC 7400 | NVIDIA GeForce2 MX 32 MB | 10.4.11 Tiger | 1024×768 |
| **Quicksilver** (PowerMac3,5, 2001) | 733 MHz PPC 7450 | ATI Radeon 9000 Pro 64 MB | 10.4.11 Tiger | 1024×768 |
| **Mac mini G4** (PowerMac10,1, 2005) | 1.25 GHz PPC 7447A | ATI Radeon 9200 32 MB | 10.4.11 Tiger | 1024×768 |
| **Mac mini Intel** (Macmini2,1, 2007) | 2.33 GHz Core 2 Duo | Intel GMA 950 64 MB | 10.7.5 Lion | 1024×768 |
| **iMac 27"** (iMac19,1, 2019) | 3.7 GHz Core i5-9600K | AMD Radeon Pro 580X 8 GB | 15.7.5 Sequoia | 2560×1440 |

Four GPU eras: fixed-function (Rage 128, GeForce2 MX), early shader-era ATI (Radeon 9000/9200), Intel integrated GMA, modern AMD discrete.

## Latest fps across all six machines

Round v11.1 (`d64427db`), `timedemo demo1/2/3` × 1024×768 + 640×480, median of runs 2 + 3:

| Machine | demo1 1024 | demo2 1024 | demo3 1024 | demo1 640 | demo2 640 | demo3 640 |
|---|---:|---:|---:|---:|---:|---:|
| Yosemite (G3 / Rage 128) | 17.35 | 15.25 | 20.95 | 34.45 | 33.40 | 36.85 |
| Sawtooth (G4 / GeForce2 MX) | 40.25 | 32.70 | **46.90** | 55.65 | 50.15 | **57.55** |
| Quicksilver (G4 / Radeon 9000) | 62.75 | 60.10 | **84.05** | 70.30 | 68.00 | **95.35** |
| Mac mini G4 (G4 / Radeon 9200) | 48.45 | 37.40 | **65.60** | 86.30 | 73.85 | **113.20** |
| Mac mini Intel (Lion / GMA 950) | 72.85 | 54.50 | **44.60** | 163.95 | 130.70 | **185.90** |
| iMac 27" (Sequoia / Radeon Pro 580X) | 1610.95 | 1490.20 | **1575.15** | 1894.45 | 1876.20 | **1907.25** |

**Round v11.1 highlight:** per-frame GL state cache in `R_DrawAliasModel` (Round v11) landed **+19 % to +46 % on demo3 1024** across every cached machine. Compiled out of the G3 ppc750 slice via `QS_DISABLE_ALIAS_STATE_CACHE` — same-session A/B confirmed neutral on Yosemite. See [`CLAUDE.md` "Per-machine gating is a legitimate pattern"](CLAUDE.md) for the gating mechanism.

## What each machine renders by default

Per-machine `autoexec-<machine>.cfg` is selected at boot by `sysctl hw.model`. Every entry below is a runtime cvar — flip without rebuild — *except* the Watervis NoVis row, which is auto-engine behaviour applied to non-watervised BSPs at load (see `Quake/gl_model.c:2456+`, `Quake/r_world.c:152`).

|  | Yosemite | Sawtooth | Quicksilver | Mini-G4 | Mini-Intel | iMac |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| Anisotropic filtering | — | — | 16× | 16× | 16× | 16× |
| Trilinear (`GL_LINEAR_MIPMAP_LINEAR`) | — | ✓ | ✓ | ✓ | ✓ | ✓ |
| Alias drop-shadows | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `r_shadow_distance` | default | 512 | 512 | 512 | 512 | default |
| Translucent water | ✓ classic warp | ✓ classic warp | ✓ shader water | ✓ shader water | ✓ classic warp | ✓ shader water |
| Translucent lava / slime / tele | — | ✓ | ✓ | ✓ | ✓ | ✓ |
| Watervis NoVis (X-ray fix) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Emissive-fullbright lights | ✓ r 0.5 / cap 4 | ✓ r 0.5 / cap 6 | ✓ r 1.0 / cap 12 | ✓ r 1.0 / cap 12 | ✓ r 0.75 / cap 8 | ✓ r 1.5 / cap 32 |
| `r_dynamic_distance` | 768 | 768 | default | default | default | default |
| `gl_clear 0` (skip backbuffer) | ✓ | — (driver quirk) | ✓ | ✓ | ✓ | ✓ |
| `gl_texture_lodbias -1.5` | ✓ | inert (probe) | ✓ | ✓ | — | — |
| Reduced particles (`r_particles 2`) | ✓ | — | — | — | — | — |
| Coarser warp tess (`gl_subdivide_size 256`) | ✓ | — | — | — | — | — |

<p align="center">
  <img src="docs/screenshots/yosemite_spasm0010.webp" width="32%" alt="Yosemite (G3 / Rage 128)" />
  <img src="docs/screenshots/sawtooth_spasm0010.webp" width="32%" alt="Sawtooth (G4 / GeForce2 MX)" />
  <img src="docs/screenshots/quicksilver_spasm0040.webp" width="32%" alt="Quicksilver (G4 / Radeon 9000)" />
</p>
<p align="center">
  <img src="docs/screenshots/mini-g4_spasm0070.webp" width="32%" alt="Mac mini G4 (Radeon 9200)" />
  <img src="docs/screenshots/mini-intel_spasm0070.webp" width="32%" alt="Mac mini Intel (Lion / GMA 950)" />
  <img src="docs/screenshots/imac-2019_spasm0040.webp" width="32%" alt="iMac 27&quot; 2019 (Radeon Pro 580X)" />
</p>

## How the fat binary picks its config

<p align="center">
  <img src="docs/images/architecture.svg" width="92%" alt="Architecture: arch baseline → per-machine layer → autoexec dispatch" />
</p>

Two extra `.cfg` layers execute on top of the regular `quake.rc` → `default.cfg` → `config.cfg` → `autoexec.cfg` chain: the per-architecture baseline (`autoexec-ppc750.cfg` / `autoexec-ppc7400.cfg` / `autoexec-x86_64.cfg`) picked by C macros at compile time, then the per-machine layer (`autoexec-<machine>.cfg`) picked at runtime by `sysctlbyname("hw.model", ...)` — see [`Quake/host.c:946`](Quake/host.c). The per-machine layer runs last so its cvars win over everything above.

## How it's built

<p align="center">
  <img src="docs/images/build-pipeline.svg" width="92%" alt="Build pipeline: rsync sources from Ubuntu → cross-compile on Lion → lipo three slices → fat .app bundle" />
</p>

Cross-builds run on the Mac mini Intel — the last machine with a working `gcc-4.0` + `MacOSX10.3.9.sdk` + `MacOSX10.4u.sdk` toolchain (Xcode 3.2.6 era). Three sub-builds (G3 with 10.3.9 SDK, G4 with 10.4u SDK + `-maltivec`, Intel with Lion default SDK), glued with `lipo -create` into one fat `quakespasm-fat`. The `.app` bundle ships identically to all six machines.

## How it's benched

<p align="center">
  <img src="docs/images/bench-loop.svg" width="92%" alt="Bench loop: code edit → build fat → deploy 6 machines → parallel timedemo → CSV append → commit" />
</p>

```bash
scripts/build-fat.sh                              # 3-arch universal binary
scripts/deploy.sh fat <machine>                   # ship to one of the 6 hosts
scripts/bench.sh <machine> demo1 1024x768 3       # 3 timedemo runs, append to CSV
scripts/parallel-bench.sh                         # full matrix, all 6 legs concurrent
```

Every phase that lands gets a smoke bench (demo1 × 2 res × 3 runs) committed alongside the code change. Full grid (3 demos × 2 res × 3 runs) at end-of-round. CSV in [`benchmarks/results.csv`](benchmarks/results.csv) is a rolling history — every cell tagged with the commit hash that produced it.

## Running it

Drop the release `.app` next to your own `id1/pak0.pak` (shareware) or `id1/pak0.pak` + `id1/pak1.pak` (registered — buy on [Steam](https://store.steampowered.com/app/2310/QUAKE/) / [GOG](https://www.gog.com/en/game/quake_the_offering)) at `~/Desktop/quake/` and double-click. The binary is x86_64 + PPC G3 + PPC G4; pre-Lion Intel Macs (32-bit kernel) are not supported.

Modern macOS will quarantine the unsigned bundle — either right-click → Open, or `xattr -dr com.apple.quarantine ~/Desktop/quake/Quakespasm.app`.

## Dig deeper

- [**`PPC_PLAN.md`**](PPC_PLAN.md) — every phase, every decision, every reverted experiment.
- [**`MISTAKES.md`**](MISTAKES.md) — append-only log of approaches that broke and why.
- [**`CLAUDE.md`**](CLAUDE.md) — operational tribal knowledge: SSH legacy crypto, bundle layout, toggleable-knobs inventory.

## License

GPL-2.0-or-later, inherited verbatim from upstream QuakeSpasm. See [`LICENSE.txt`](LICENSE.txt). Chain: id Software (1996–2001) → John Fitzgibbons / FitzQuake (2002–2009) → QuakeSpasm developers ([sezero/quakespasm](https://github.com/sezero/quakespasm), 2010–present). Bundled SDL 1.2.15 is zlib-licensed.
