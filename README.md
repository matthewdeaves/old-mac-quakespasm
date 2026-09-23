# QuakeSpasm: old-Mac port

[![License: GPL v2](https://img.shields.io/badge/License-GPL_v2-blue.svg)](LICENSE.txt)
[![Platform: PowerPC | Intel | Apple Silicon](https://img.shields.io/badge/Platform-PowerPC%20%7C%20Intel%20%7C%20Apple%20Silicon-lightgrey.svg)](#tested-machines)
[![macOS: 10.3.9 → 15.7](https://img.shields.io/badge/macOS-10.3.9%20%E2%86%92%2015.7-success.svg)](#tested-machines)
[![Download: latest .dmg](https://img.shields.io/badge/Download-latest%20.dmg-brightgreen.svg)](https://github.com/matthewdeaves/old-mac-quakespasm/releases/latest)

<p align="center">
  <img src="docs/images/quakespasm-icon-256.png" width="180" alt="QuakeSpasm icon" />
</p>

QuakeSpasm as one fat binary for PowerPC, Intel and Apple Silicon Macs. At boot it
reads the machine model (`sysctl hw.model`) and loads per-machine settings.

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
| **Power Mac G5** (dual, three partitions) | 2.7 GHz PPC 970 ×2 | ATI Radeon 9600 | 10.3.9, 10.4.11, 10.5.8 | native |
| **MacBook Air** (Mac17,4, 2026) | Apple M5 | Apple M5 GPU | 26.6 Tahoe | native |

On the GeForce 9400 Mac mini, the GLSL alias-model renderer made the driver log GPU
channel faults and could panic the Mac, so it is off by default on that GPU
(`-glslalias` turns it back on). Details in #57.

### Which OS each CPU needs

The binary carries one slice per CPU family, each stamped with its exact CPU subtype:

| CPU | Slice | OS needed | Tested on |
|---|---|---|---|
| G3 (750) | `ppc750` | 10.3.9 Panther or later | 10.3.9 and 10.4.11 |
| G4 (7400 / 7450 / 7447A) | `ppc7400` | 10.3.9 Panther or later | 10.4.11 |
| G5 (970) | `ppc970` | 10.3.9 Panther or later | 10.3.9, 10.4.11 and 10.5.8 |
| Intel, 32-bit (Core Solo / Duo) | `i386` | 10.4.11 Tiger or later | not yet run on hardware |
| Intel, 64-bit | `x86_64` | 10.6 Snow Leopard or later | 10.6.8, 10.7.5 and 15.7 |
| Apple Silicon | `arm64` | macOS 11.0 Big Sur or later | macOS 26 |

`dyld` picks a slice by CPU alone; the OS plays no part in it. A Mac running an OS
older than its slice needs gets that slice anyway rather than falling back to a lower
one, and won't launch, which is why the G3 and G4 slices are both built at min 10.3
even though no G4 here runs Panther. **A G4 on Panther should work but has not been
run on hardware** (no such machine in the fleet).

## Framerate

`timedemo demo1`, with each Mac's shipped per-machine settings
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
switch) at ~102 fps; the 2019 iMac runs over 1500 fps. The G3 defaults to
800×600, where demo1 runs 25.5 fps on Panther and 25.1 on Tiger. Targets: ≥ 60 fps
on the G4/G5/Lion machines, ≥ 20 on the G3. Full history and all three demos in
[`benchmarks/results.csv`](benchmarks/results.csv).

## How it's built and benchmarked

One modern Mac drives the fleet over SSH. A Lion Mac mini cross-builds the five
PowerPC/Intel slices; arm64 is built on an Apple Silicon Mac.

![Build and bench rack: one orchestration box drives the fleet via the Lion mini cross-build host](docs/images/architecture.svg)

![Build pipeline: six slices (ppc750, ppc7400, ppc970, i386, x86_64, arm64) lipo'd into one fat binary](docs/images/build-pipeline.svg)

![Bench loop: The orchestration Mac launches a timedemo over SSH, reads qconsole.log back, and the median lands in results.csv](docs/images/bench-loop.svg)

## Features

- **One fat binary** (six slices: ppc750, ppc7400 with AltiVec, ppc970, i386, x86_64, arm64); runs on Mac OS X
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
(`QuakeSpasm-OldMac-<version>.dmg`). The image is built on Tiger so it mounts on
10.3.9 through current macOS.

Open the `.dmg` and drag the whole **`Quakespasm`** folder (not just the
`.app`) to `/Applications` or anywhere else. It holds the app, `quakespasm.pak`,
an empty `id1/` and a fix script. Add your own
`pak0.pak` (shareware) or `pak0.pak` + `pak1.pak` (registered, from your own
copy of the game) into that folder's `id1/`, then double-click
`Quakespasm.app`.

If it shows a `couldn't load gfx.wad` error, or does nothing at all: open
the `Quakespasm` folder, right-click **`Fix Launch Problems.command`** and
choose Open (once -- this app isn't Developer ID signed, so any unsigned
script needs one right-click-Open bypass instead of a plain double-click),
then try `Quakespasm.app` again. See "Where to put it" below for why this
happens. Not needed before 10.12 Sierra (no App Translocation there); the script
checks the OS version. Apple Silicon runs the native `arm64` slice, and Core Duo /
Core Solo Macs run the `i386` slice.

## Sister projects

Same machines, same tooling, other id engines:
[**old-mac-quake2**](https://github.com/matthewdeaves/old-mac-quake2) (Quake II)
and [**old-mac-quake3**](https://github.com/matthewdeaves/old-mac-quake3)
(Quake III Arena).

## License

GPL-2.0-or-later, inherited verbatim from upstream QuakeSpasm. See
[`LICENSE.txt`](LICENSE.txt). Chain: id Software (1996–2001) → John Fitzgibbons /
FitzQuake → QuakeSpasm developers ([sezero/quakespasm](https://github.com/sezero/quakespasm)).
Bundled SDL 1.2.15 is LGPL-2.1; SDL2.framework (arm64 only) is zlib.

### Where to put it on Apple Silicon and modern macOS

Two separate issues; only the second depends on where the folder is:

- **App Translocation** (macOS 10.12 Sierra and later only), wherever the
  folder lives: a quarantined app can run from a random, sandboxed copy of
  itself instead of its real folder, so it can't see `id1/` next to it --
  `couldn't load gfx.wad, Basedir is .../AppTranslocation/...`. `Fix Launch
  Problems.command`, inside the `Quakespasm` folder, clears this; doing it by
  hand from inside that folder is `xattr -dr com.apple.quarantine .`
- **The Desktop-permission prompt**, only if you put the folder on the
  Desktop: macOS asks an app for permission before it may read files in
  Desktop, Documents or Downloads, and asks again on every launch for an app
  it can't identify consistently. Putting the `Quakespasm` folder in
  `/Applications` instead avoids this prompt entirely; there's nothing to
  clear by hand for it.

PowerPC and Intel Macs running 10.3 through 10.7 have neither of these and can
keep the folder wherever you like.
