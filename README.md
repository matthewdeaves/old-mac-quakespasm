# QuakeSpasm: old-Mac port

[![License: GPL v2](https://img.shields.io/badge/License-GPL_v2-blue.svg)](LICENSE.txt)
[![Platform: PowerPC + Intel macOS](https://img.shields.io/badge/Platform-PowerPC%20%7C%20Intel%20macOS-lightgrey.svg)](#tested-machines)
[![macOS: 10.3.9 → 15.7](https://img.shields.io/badge/macOS-10.3.9%20%E2%86%92%2015.7-success.svg)](#tested-machines)
[![Download: latest .dmg](https://img.shields.io/badge/Download-latest%20.dmg-brightgreen.svg)](https://github.com/matthewdeaves/old-mac-quakespasm/releases/latest)

<p align="center">
  <img src="docs/images/quakespasm-icon-256.png" width="180" alt="QuakeSpasm icon" />
</p>

A QuakeSpasm build as one fat PowerPC + Intel binary, tested on a range of old
Macs, G3, G4, G5 and Intel, from a 1999 Power Mac to a 2019 iMac. It reads the
machine model at boot (`sysctl hw.model`) and loads settings tuned to run well on
that hardware.

> **About this project.** A personal project, I love Quake and I collect and
> tinker with old Macs. My part is the setup and testing: the build, deploy and
> benchmark scripts, and the per-machine settings. The engine and config changes
> were made mostly **with AI (Claude), which I directed and checked against real
> benchmarks on the machines**, not hand-written from scratch.

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
| **Yosemite on Tiger** (same Mac, 2nd partition) | 449 MHz PPC 750 | ATI Rage 128 16 MB | 10.4.11 Tiger | 800×600 |
| **Sawtooth** (PowerMac3,1 G4 AGP, 1999) | 500 MHz PPC 7400 | NVIDIA GeForce2 MX 32 MB | 10.4.11 Tiger | 1024×768 |
| **Quicksilver** (PowerMac3,5, 2001) | 733 MHz PPC 7450 | ATI Radeon 9000 Pro 64 MB | 10.4.11 Tiger | 1024×768 |
| **Mac mini G4** (PowerMac10,1, 2005) | 1.25 GHz PPC 7447A | ATI Radeon 9200 32 MB | 10.4.11 Tiger | 1024×768 |
| **iMac G5** (PowerMac8,2, 2005) | 2.0 GHz PPC 970 | ATI Radeon 9600 128 MB | 10.5.8 Leopard | 1440×900 (native) |
| **Mac mini** (Macmini3,1, 2009) | 2.26 GHz Core 2 Duo | NVIDIA GeForce 9400 256 MB | 10.6.8 Snow Leopard | 1024×768 |
| **Mac mini Intel** (Macmini2,1, 2007) | 2.33 GHz Core 2 Duo | Intel GMA 950 64 MB | 10.7.5 Lion | 1024×768 |
| **iMac 27"** (iMac19,1, 2019) | 3.7 GHz Core i5-9600K | AMD Radeon Pro 580X 8 GB | 15.7 Sequoia | 2560×1440 |

The GeForce 9400 Mac mini plays fine and passes normal launch and play testing,
but its own driver (not this engine) occasionally logs a low-level GPU fault
under back-to-back relaunches; a real play session (launch, play, quit) is not
known to trigger it. See `MISTAKES.md` for the full evidence.

### Which OS each CPU needs

The binary carries one slice per CPU family, each stamped with its exact CPU subtype:

| CPU | Slice | OS needed | Tested on |
|---|---|---|---|
| G3 (750) | `ppc750` | 10.3.9 Panther or later | 10.3.9 and 10.4.11 |
| G4 (7400 / 7450 / 7447A) | `ppc7400` | 10.3.9 Panther or later | 10.4.11 |
| G5 (970) | `ppc970` | **10.5 Leopard, a G5 on 10.3 or 10.4 is not supported** | 10.5.8 |
| Intel, 32-bit (Core Solo / Duo) | `i386` | 10.4.11 Tiger or later | 10.7.5 |
| Intel, 64-bit | `x86_64` | 10.6 Snow Leopard or later | 10.7.5 and 15.7 |
| Apple Silicon | `arm64` | macOS 11.0 Big Sur or later | macOS 15.7 |

`dyld` picks a slice by CPU alone; the OS plays no part in it. A Mac running an OS
older than its slice needs gets that slice anyway rather than falling back to a lower
one, and won't launch, which is why the G3 and G4 slices are both built at min 10.3
even though no G4 here runs Panther. Two rows are honest about the gap between what
is built and what is tested: **a G4 on Panther and an Intel Mac on Snow Leopard should
both work but neither has been run on hardware** (no such machine in the fleet). The G5
is the exception, its slice genuinely needs 10.5, so that row is a real floor, not a
gap in testing.

## Framerate

`timedemo demo1`, with the per-machine settings each Mac actually ships with
(translucent water, shadows, dynamic lights, trilinear), median of runs 2 & 3:

| Machine | 1024×768 | 640×480 |
|---|---:|---:|
| Yosemite (G3 / Panther / Rage 128) | 17.2 | 33.6 |
| Yosemite (G3 / Tiger / Rage 128) | 15.9 | 32.5 |
| Quicksilver (G4 / Radeon 9000) | 63.6 | 71.2 |
| Mac mini G4 (Radeon 9200) | 48.7 | 86.0 |
| Mac mini Intel (Lion / GMA 950) | 71.3 | 161.4 |
| Sawtooth (G4 / GeForce2 MX) † | 40.5 | 55.8 |

† Sawtooth was offline for this round; its figures are from the previous
release. Everything else is measured on the v1.14 build.

The iMac G5 runs native 1440×900 only (its Leopard driver hangs on a mode
switch) at ~102 fps; the 2019 iMac sits well over 1500 fps. The G3 ships at
800×600, its default, where demo1 runs 25.5 on Panther and 25.1 on Tiger,
comfortably above 20 fps with everything turned on. That pair is the same Mac
booted from two partitions, running the byte-identical binary out of the same
disk image: the OS costs the G3 a couple of percent and nothing else. Every
machine stays above its target (≥ 60 fps on the G4/G5/Lion machines, ≥ 20 on the
G3); full history and all three demos in
[`benchmarks/results.csv`](benchmarks/results.csv).

## How it's built and benchmarked

One modern Mac drives the whole fleet over SSH. The Lion mini does double duty:
it cross-builds the four PowerPC/Intel slices and benches itself. These diagrams
cover the setup, the build pipeline and the timedemo bench loop.

![Build and bench rack: one orchestration box drives the fleet via the Lion mini cross-build host](docs/images/architecture.svg)

![Build pipeline: six slices (ppc750, ppc7400, ppc970, i386, x86_64, arm64) lipo'd into one fat binary](docs/images/build-pipeline.svg)

![Bench loop: The orchestration Mac launches a timedemo over SSH, reads qconsole.log back, and the median lands in results.csv](docs/images/bench-loop.svg)

## Features

- **One fat binary** (PPC G3 + G4 AltiVec + G5 + Intel x86_64); runs on Mac OS X
  10.3.9 Panther through modern macOS. Every PowerPC slice carries its exact CPU
  subtype (`ppc750` / `ppc7400` / `ppc970`) so Tiger and Leopard grade it
  correctly on a G3.
- **Per-machine settings** picked at boot via `sysctl hw.model`, each Mac gets
  a config tuned to stay playable on it. Every setting is a runtime cvar.
- **Visual features**, trilinear + up to 16× anisotropic filtering, alias
  drop-shadows, translucent water / lava / slime / teleporters, watervis on
  un-vis'd maps, emissive-fullbright dynamic lights, `gl_zfix`, and 8× MSAA on
  the modern iMac.
- **Weapon damage decals**, bullet holes, nail pocks, axe slashes, scorch
  stars, burn scars and lightning scars on walls, floors and ceilings (a BSP
  fragment clipper ported from the sister Quake II port; gated via `r_decals`).
- **Online multiplayer**, a server browser (DPMaster query) plus in-protocol
  auto-download, so a 449 MHz G3 and a 2019 iMac can share the same public
  server. Downloads off by default (`allow_download 0`).
- Optional **Apple Watch "tactical computer" companion** (`watchlink`), streams
  the ranger's live state to an iPhone + Watch; off by default. Shared with the
  Quake II port ([quake2-tactical-watch](https://github.com/matthewdeaves/quake2-tactical-watch)).

## The Linux dedicated server

There is also a headless Linux server, so a game does not have to be hosted on
one of the old Macs. It builds from the same tree and ships as its own release
(`server-v*`), for x86_64 and aarch64. It needs glibc 2.31 or newer, so Ubuntu
20.04 or Debian 11 upward, and it ships no content.

Read [`server/README.md`](server/README.md) before putting one on the internet.
NetQuake has no password and no rcon, so who can reach the port is the only
access control there is.

The always-on public servers this game's server browser talks to are deployed
and kept running from a separate repo,
[**retro-server-infra**](https://github.com/matthewdeaves/retro-server-infra),
not this one.

## Get the latest release

Download the latest disk image from
[**Releases**](https://github.com/matthewdeaves/old-mac-quakespasm/releases/latest)
(`QuakeSpasm-OldMac-<version>.dmg`). One image installs on every supported Mac,
built on Tiger so it mounts on everything from 10.3.9 through modern macOS, and
the `.app` inside is a fat binary that runs natively on each.

Open the `.dmg`, then drag `Quakespasm.app` and `quakespasm.pak` into a folder
(e.g. `~/Desktop/quake/`) next to your own `id1/` containing `pak0.pak`
(shareware) or `pak0.pak` + `pak1.pak` (registered, from your own copy of the
game). On modern macOS, a
plain double-click on a freshly-downloaded copy can be killed by Gatekeeper a
few seconds in with no error dialog (this app isn't Developer ID signed) --
**right-click `Quakespasm.app` and choose Open** instead, once, the same
one-click bypass Apple provides for any unsigned app; every launch after that
is a normal double-click. Not needed on Panther/Tiger/Leopard/Lion, which
predate Gatekeeper entirely. An Apple Silicon Mac now runs a **native `arm64`
slice** rather than the `x86_64` one under Rosetta 2, and the 2006 Core Duo /
Core Solo machines have their own `i386` slice, so there is no longer any Mac
this binary cannot run on natively.

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

### Where to put it on Apple Silicon and modern macOS

Put the game folder in **`/Applications`**, not on the Desktop.

macOS asks an app for permission before it may read files in Desktop, Documents
or Downloads, and it asks **every launch** for an app it cannot identify
consistently. A game that lives in `/Applications` is outside those protected
locations, so it never triggers the prompt and can read its own `id1/` folder
without being interrupted.

So: drag the whole folder (the `.app` **and** the game data beside it) into
`/Applications`, keeping them together. On first run, clear Gatekeeper with:

```sh
xattr -dr com.apple.quarantine /Applications/<folder>
```

PowerPC and Intel Macs running 10.3 through 10.7 have none of this and can keep
the folder wherever you like.
