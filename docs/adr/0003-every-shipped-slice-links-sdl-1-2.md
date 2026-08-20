# 3. Every shipped slice links SDL 1.2, and the PowerPC slices are hand-built

Date: 2026-08-20
Status: accepted

## Context

Upstream QuakeSpasm maintains a live `USE_SDL2` code path, and this tree
vendors both `MacOSX/SDL.framework` (SDL 1.2) and `MacOSX/SDL2.framework`
(SDL 2.0.22). Only one of them is in a shipped Mac build.

## Decision

**Every Mac slice links SDL 1.2.15.** `Quake/Makefile.darwin:13` sets
`USE_SDL2=0`, and `scripts/build.sh` passes only `MACH_TYPE`, `CC`,
`QS_PORT_VERSION`, `CPUFLAGS` and `LDFLAGS` to make, so nothing overrides it.
`USE_SDL2=1` appears only in the Linux, dedicated-server and static-analysis
paths, never in a shipped Mac build.

Verified on the artifact, which is the only check that settles it:
`otool -L build/quakespasm-fat` shows every slice linking
`@executable_path/SDL.framework/Versions/A/SDL` at current version 12.4.0, which
is SDL 1.2.15.

**`MacOSX/SDL.framework/Versions/A/SDL` is fat with four slices,
`x86_64 i386 ppc ppc970`, and the two PowerPC ones are hand-built here.**
`MacOSX/SDL-rebuild.md` holds the exact recipes.

- **The generic `ppc` slice is a 10.3.9-SDK Panther build**
  (`MacOSX/SDL-panther.dylib`), configured
  `--disable-video-x11 --disable-altivec --disable-cdrom`. Upstream's PPC slice
  was linked against the 10.6 SDK and **crashes inside `SDL_VideoInit + 608` on
  Panther**, jumping to a Quartz address that does not exist on 10.3. The
  Panther slice loads and works on Tiger and Lion too, so one slice covers both
  PowerPC OS versions. `--disable-video-x11` is mandatory: SDL's X11 GL backend
  pulls in conflicting OpenGL header declarations against the 10.3.9 SDK, and
  this project uses the Cocoa backend exclusively.
- **The `ppc970` slice is a 10.5-SDK Leopard build** for the iMac G5. `dyld`
  auto-selects it on a 970; G3 and G4 keep the generic `ppc` slice, so there is
  zero regression for them. The Panther build's fullscreen path is suspect on
  Leopard, which is why the G5 gets a slice built natively for it. This is
  **not** the fix for the G5's GPU hang — that is the engine-side R300 gate
  (ADR 0007) — but shipping a Leopard-built SDL for the G5 is correct anyway.
- **All slices are re-id'd** to `@executable_path/SDL.framework/Versions/A/SDL`
  with `install_name_tool -id` before lipo. `dyld` matches `LC_LOAD_DYLIB`
  against the loaded slice's `LC_ID_DYLIB`, and upstream's slices were id'd
  `@executable_path/../Frameworks/...`, which is not where this bundle drops it.
  The engine binary gets the matching `install_name_tool -change` in
  `scripts/build.sh`.
- **Always ship this framework alongside the binary; never rely on the system
  one.** A typical Tiger install has SDL 1.2.7, too old for a binary linked
  against current_version 12.5.0.

## Alternatives rejected

**SDL2 on the Mac slices.** It has no PowerPC support. This port reached the
same conclusion as the Quake II and Quake III sister ports, independently: SDL
1.2 for the PowerPC machines.

**Trusting the vendored `SDL2.framework` as evidence of anything.** It is real
(2.0.22, `x86_64 i386 arm64`, no PowerPC) and it is unused by every shipped Mac
build. Commit `fd507839` asserted that "QuakeSpasm was easy because it is on
SDL2 and its bundled framework was already fat with arm64 in it", and used that
to argue the port was structurally ahead of the two siblings. That was wrong,
and it was wrong because a property of the artifact was inferred from the
contents of the source tree. One `otool -L` would have settled it. Corrected
2026-08-20 (`b9a7fff9`).

## Consequences

- The port is on a 2013 SDL on every machine. Nothing fixed in SDL since 1.2.15
  is fixed here.
- `vid_desktopfullscreen` (ADR 0007) needed a hand-written SDL-1.2 substitution
  in `VID_SetMode`; an SDL2 build would get it free from
  `SDL_WINDOW_FULLSCREEN_DESKTOP`.
- **An arm64 slice is blocked on this, not on the compiler.** It would be the
  only slice in the fat on a different SDL major version. That is legal, since
  each slice carries its own `LC_LOAD_DYLIB`, but the bundle would then have to
  ship both frameworks, and the arm64 slice would exercise the
  `#if defined(USE_SDL2)` half of roughly seventy conditionals that have never
  shipped from this repo on any platform. Notably `MacOSX/SDLApplication.m`
  compiles itself out under SDL2 while `Info.plist` still names
  `NSPrincipalClass = SDLApplication`, which would resolve to SDL2's own class
  rather than ours.
