# QuakeSpasm — old-Mac port

[![License: GPL v2](https://img.shields.io/badge/License-GPL_v2-blue.svg)](LICENSE.txt)
[![Platform: PowerPC + Intel macOS](https://img.shields.io/badge/Platform-PowerPC%20%7C%20Intel%20macOS-lightgrey.svg)](#tested-machines)
[![macOS: 10.3.9 → 15.7](https://img.shields.io/badge/macOS-10.3.9%20%E2%86%92%2015.7-success.svg)](#tested-machines)
[![Download: latest .dmg](https://img.shields.io/badge/Download-latest%20.dmg-brightgreen.svg)](https://github.com/matthewdeaves/old-mac-quakespasm/releases/latest)

<p align="center">
  <img src="docs/images/quakespasm-icon-256.png" width="180" alt="QuakeSpasm icon" />
</p>

A QuakeSpasm build as one fat PowerPC + Intel binary, tested on a range of old
Macs — G3, G4, G5 and Intel, from a 1999 Power Mac to a 2019 iMac. It reads the
machine model at boot (`sysctl hw.model`) and loads settings tuned to run well on
that hardware.

> **About this project.** A personal project — I love Quake and I collect and
> tinker with old Macs. My part is the setup and testing: the build, deploy and
> benchmark scripts, and the per-machine settings. The engine and config changes
> were made mostly **with AI (Claude), which I directed and checked against real
> benchmarks on the machines** — not hand-written from scratch.

<p align="center">
  <img src="docs/screenshots/sawtooth_spasm0010.webp" width="24%" alt="Sawtooth G4 / GeForce2 MX" />
  <img src="docs/screenshots/quicksilver_spasm0040.webp" width="24%" alt="Quicksilver G4 / Radeon 9000" />
  <img src="docs/screenshots/mini-intel_spasm0070.webp" width="24%" alt="Mac mini Intel / GMA 950" />
  <img src="docs/screenshots/imac-2019_spasm0010.webp" width="24%" alt="iMac 27&quot; 2019 / Radeon Pro 580X" />
</p>

## Tested machines

| Machine | CPU | GPU | OS | Default res |
|---|---|---|---|---:|
| **Yosemite** (PowerMac1,1 B&W G3, 1999) | 449 MHz PPC 750 | ATI Rage 128 16 MB | 10.3.9 Panther | 800×600 |
| **Sawtooth** (PowerMac3,1 G4 AGP, 1999) | 500 MHz PPC 7400 | NVIDIA GeForce2 MX 32 MB | 10.4.11 Tiger | 1024×768 |
| **Quicksilver** (PowerMac3,5, 2001) | 733 MHz PPC 7450 | ATI Radeon 9000 Pro 64 MB | 10.4.11 Tiger | 1024×768 |
| **Mac mini G4** (PowerMac10,1, 2005) | 1.25 GHz PPC 7447A | ATI Radeon 9200 32 MB | 10.4.11 Tiger | 1024×768 |
| **iMac G5** (PowerMac8,2, 2005) | 2.0 GHz PPC 970 | ATI Radeon 9600 128 MB | 10.5.8 Leopard | 1440×900 (native) |
| **Mac mini Intel** (Macmini2,1, 2007) | 2.33 GHz Core 2 Duo | Intel GMA 950 64 MB | 10.7.5 Lion | 1024×768 |
| **iMac 27"** (iMac19,1, 2019) | 3.7 GHz Core i5-9600K | AMD Radeon Pro 580X 8 GB | 15.7 Sequoia | 2560×1440 |

## Framerate

`timedemo demo1`, with the per-machine settings each Mac actually ships with
(translucent water, shadows, dynamic lights, trilinear), median of runs 2 & 3:

| Machine | 1024×768 | 640×480 |
|---|---:|---:|
| Yosemite (G3 / Rage 128) | 17.6 | 36.5 |
| Sawtooth (G4 / GeForce2 MX) | 40.5 | 55.8 |
| Quicksilver (G4 / Radeon 9000) | 65.8 | 71.4 |
| Mac mini G4 (Radeon 9200) | 51.4 | 89.7 |
| Mac mini Intel (Lion / GMA 950) | 76.3 | 172.5 |

The iMac G5 runs native 1440×900 only (its Leopard driver hangs on a mode
switch) at ~100 fps; the 2019 iMac sits well over 1500 fps. Yosemite ships at
800×600 — its default — where demo1/2/3 run ~27/25/30, comfortably above 20 fps
with everything turned on. Every machine stays above its target (≥ 60 fps on the
G4/G5/Lion machines, ≥ 20 on the G3); full history and all three demos in
[`benchmarks/results.csv`](benchmarks/results.csv).

## Features

- **One fat binary** (PPC G3 + G4 AltiVec + G5 + Intel x86_64); runs on Mac OS X
  10.3.9 Panther through modern macOS.
- **Per-machine settings** picked at boot via `sysctl hw.model` — each Mac gets
  a config tuned to stay playable on it. Every setting is a runtime cvar.
- **Visual features** — trilinear + up to 16× anisotropic filtering, alias
  drop-shadows, translucent water / lava / slime / teleporters, watervis on
  un-vis'd maps, emissive-fullbright dynamic lights, `gl_zfix`, and 8× MSAA on
  the modern iMac.
- **Weapon damage decals** — bullet holes, nail pocks, axe slashes, scorch
  stars, burn scars and lightning scars on walls, floors and ceilings (a BSP
  fragment clipper ported from the sister Quake II port; gated via `r_decals`).
- **Online multiplayer** — a server browser (DPMaster query) plus in-protocol
  auto-download, so a 449 MHz G3 and a 2019 iMac can share the same public
  server. Downloads off by default (`allow_download 0`).
- Optional **Apple Watch "tactical computer" companion** (`watchlink`) — streams
  the ranger's live state to an iPhone + Watch; off by default. Shared with the
  Quake II port ([quake2-tactical-watch](https://github.com/matthewdeaves/quake2-tactical-watch)).

## Get the latest release

Download the latest disk image from
[**Releases**](https://github.com/matthewdeaves/old-mac-quakespasm/releases/latest)
(`QuakeSpasm-OldMac-<version>.dmg`). One image installs on every supported Mac —
built on Panther so it mounts on everything from 10.3.9 through modern macOS, and
the `.app` inside is a fat binary that runs natively on each.

Open the `.dmg`, then drag `Quakespasm.app` and `quakespasm.pak` into a folder
(e.g. `~/Desktop/quake/`) next to your own `id1/` containing `pak0.pak`
(shareware) or `pak0.pak` + `pak1.pak` (registered — buy on
[Steam](https://store.steampowered.com/app/2310/QUAKE/) /
[GOG](https://www.gog.com/en/game/quake_the_offering)). Double-click
`Quakespasm.app`. On modern macOS, clear Gatekeeper with
`xattr -dr com.apple.quarantine ~/Desktop/quake/Quakespasm.app` (not needed on
Panther/Tiger/Lion; pre-Lion 32-bit-kernel Intel Macs are not supported).

## Sister projects

Same machines, same tooling, other id engines:
[**old-mac-quake2**](https://github.com/matthewdeaves/old-mac-quake2) (Quake II)
and [**old-mac-quake3**](https://github.com/matthewdeaves/old-mac-quake3)
(Quake III Arena).

## License

GPL-2.0-or-later, inherited verbatim from upstream QuakeSpasm. See
[`LICENSE.txt`](LICENSE.txt). Chain: id Software (1996–2001) → John Fitzgibbons /
FitzQuake → QuakeSpasm developers ([sezero/quakespasm](https://github.com/sezero/quakespasm)).
Bundled SDL 1.2.15 is zlib-licensed.
