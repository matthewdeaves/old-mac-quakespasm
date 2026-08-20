---
description: Build the fat binary on the cross-build host and deploy Quakespasm.app to a bench machine
argument-hint: [yosemite|sawtooth|quicksilver|mini-g4|mini-intel|imac-2019|all]
---

Build and deploy QuakeSpasm to a bench machine. Arguments: $ARGUMENTS

The bench fleet is seven Macs (1999 G3 → 2019 i5 iMac) across eight OS
installs. One fat binary serves them all — `build/quakespasm-fat` holds four slices (`ppc750`
G3, `ppc7400` G4 + AltiVec, `ppc970` G5/Leopard, `x86_64` Lion+). dyld
picks the right slice at launch; host.c picks the right per-machine
autoexec from `Contents/Resources/` via CFBundle.

Behavior:
- `/deploy <machine>` → `scripts/build-fat.sh && scripts/deploy.sh <machine>`
- `/deploy all` (or no arg) → `scripts/build-fat.sh` once, then deploy
  to every machine sequentially.

`build-fat.sh` syncs sources to a claimed Intel Lion mini, calls `build.sh g3` + `build.sh g4` + `build.sh g5` + `build.sh lion`
internally to produce the four slices, then `lipo -create`s them
into `build/quakespasm-fat`.

`deploy.sh` assembles the `Quakespasm.app` bundle (fat binary +
codecs + SDL.framework + nib + icon + all 10 autoexec cfgs in
`Contents/Resources/`) locally and rsyncs to
`<machine>:~/Desktop/quake/`. The bundled `MacOSX/SDL.framework`
ships a Panther-compatible PPC slice in place (no per-host SDL swap).

Don't manually scp binaries or hand-roll the bundle layout — the
scripts encode the right structure (Cocoa nib placement,
install_name substitutions, codec dylibs, Info.plist, icon, the
per-arch and per-machine autoexec dispatch).
