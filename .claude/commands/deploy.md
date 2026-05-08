---
description: Build binary on Lion and deploy Quakespasm.app to g3, g4, g4mini, or lion
argument-hint: [g3|g4|g4mini|lion|all]
---

Build and deploy QuakeSpasm to a target. Arguments: $ARGUMENTS

Behavior:
- `/deploy g4`     → `scripts/build.sh g4 && scripts/deploy.sh g4`
- `/deploy g3`     → `scripts/build.sh g3 && scripts/deploy.sh g3`
- `/deploy g4mini` → `scripts/deploy.sh g4mini` (no build step — reuses
                     `build/quakespasm-g4`; build it first with `/deploy g4`
                     if it doesn't exist yet)
- `/deploy lion`   → `scripts/build.sh lion && scripts/deploy.sh lion`
- `/deploy all` (or no arg) → build g3, g4, lion sequentially, then deploy
  all 4 targets (g3, g4, g4mini, lion). g4mini reuses the g4 binary.

`build.sh` syncs sources to Lion, cross-compiles with the right SDK +
`-mcpu` for the target (or native x86_64 via clang for `lion`), applies
`install_name_tool` SDL fixup, and fetches `build/quakespasm-<target>`
to Ubuntu.

`deploy.sh` assembles the `Quakespasm.app` bundle on Ubuntu and rsyncs
to `<target>:~/Desktop/quake/`. For G3 it swaps in the
`MacOSX/SDL-panther.dylib` (10.3-targeted SDL build) — necessary
because the bundled multi-arch `MacOSX/SDL.framework` was built against
the 10.6 SDK and crashes on Panther in `SDL_VideoInit`. Tiger (g4 +
g4mini) and Lion use the bundled SDL.framework as-is.

After deploy, the bundle is ready to launch: each machine has
`~/Desktop/quake/Quakespasm.app` plus `id1/`, `quakespasm.pak`, etc.
`scripts/bench.sh` can drive it from there.

Don't manually scp binaries or hand-roll the bundle layout — the
scripts encode the right structure (Cocoa nib placement, install_name
substitutions, codec dylibs, Info.plist, icon).
