---
description: Build PPC binary on Lion and deploy Quakespasm.app to G3 or G4
argument-hint: [g3|g4|both]
---

Build and deploy QuakeSpasm to a PPC target. Arguments: $ARGUMENTS

Behavior:
- `/deploy g4` → `scripts/build.sh g4 && scripts/deploy.sh g4`
- `/deploy g3` → `scripts/build.sh g3 && scripts/deploy.sh g3`
- `/deploy both` (or no arg) → both targets, sequentially

`build.sh` syncs sources to Lion, cross-compiles with the right SDK +
`-mcpu` for the target, applies `install_name_tool` SDL fixup, and
fetches `build/quakespasm-<target>` to Ubuntu.

`deploy.sh` assembles the `Quakespasm.app` bundle on Ubuntu and rsyncs
to `<target>:~/Desktop/quake/`. For G3 it swaps in the
`MacOSX/SDL-panther.dylib` (10.3-targeted SDL build) — necessary
because the bundled multi-arch `MacOSX/SDL.framework` was built against
the 10.6 SDK and crashes on Panther in `SDL_VideoInit`.

After deploy, the bundle is ready to launch: each PPC machine has
`~/Desktop/quake/Quakespasm.app` plus `id1/`, `quakespasm.pak`, etc.
`scripts/bench.sh` can drive it from there.

Don't manually scp binaries or hand-roll the bundle layout — the
scripts encode the right structure (Cocoa nib placement, install_name
substitutions, codec dylibs, Info.plist, icon).
