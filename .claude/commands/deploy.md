---
description: Build binary on the cross-build host and deploy Quakespasm.app to a bench machine
argument-hint: [yosemite|sawtooth|quicksilver|mini-g4|mini-intel|all]
---

Build and deploy QuakeSpasm to a bench machine. Arguments: $ARGUMENTS

Machine identity → binary mapping (machine names use Apple codenames /
form-factor; binary names use chip family — one G4 binary serves three
machines):

| machine     | binary              | builder |
|-------------|---------------------|---------|
| yosemite    | `quakespasm-g3`     | `scripts/build.sh g3`   (PPC 750, 10.3.9 SDK) |
| sawtooth    | `quakespasm-g4`     | `scripts/build.sh g4`   (PPC 7400, 10.4u SDK) |
| quicksilver | `quakespasm-g4`     | `scripts/build.sh g4`   (same binary) |
| mini-g4     | `quakespasm-g4`     | `scripts/build.sh g4`   (same binary) |
| mini-intel  | `quakespasm-lion`   | `scripts/build.sh lion` (native x86_64 on Lion) |

Behavior:
- `/deploy yosemite`    → `scripts/build.sh g3 && scripts/deploy.sh yosemite`
- `/deploy sawtooth`    → build g4 (if not present) and `scripts/deploy.sh sawtooth`
- `/deploy quicksilver` → build g4 (if not present) and `scripts/deploy.sh quicksilver`
- `/deploy mini-g4`     → build g4 (if not present) and `scripts/deploy.sh mini-g4`
- `/deploy mini-intel`  → `scripts/build.sh lion && scripts/deploy.sh mini-intel`
- `/deploy all` (or no arg) → build g3 + g4 + lion sequentially, then deploy
  all 5 machines.

`build.sh` syncs sources to the cross-build host (mini-intel / Lion box),
cross-compiles with the right SDK + `-mcpu` for the target (or native x86_64
via clang for `lion`), applies `install_name_tool` SDL fixup, and fetches
`build/quakespasm-<chip>` to Ubuntu.

`deploy.sh` assembles the `Quakespasm.app` bundle on Ubuntu and rsyncs
to `<machine>:~/Desktop/quake/`. The bundled `MacOSX/SDL.framework` ships
a Panther-compatible PPC slice in-place (no per-host SDL swap).

After deploy, the bundle is ready to launch: each machine has
`~/Desktop/quake/Quakespasm.app` plus `id1/`, `quakespasm.pak`, etc.
`scripts/bench.sh` can drive it from there.

Don't manually scp binaries or hand-roll the bundle layout — the
scripts encode the right structure (Cocoa nib placement, install_name
substitutions, codec dylibs, Info.plist, icon).
