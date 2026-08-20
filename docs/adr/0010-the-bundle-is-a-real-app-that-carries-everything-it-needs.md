# 10. The bundle is a real .app, location-agnostic, carrying everything it needs

Date: 2026-08-20
Status: accepted

## Context

Tiger and Panther Cocoa will not launch a bare binary. Doing so over SSH fails
with `"No Info.plist file in application bundle or no NSPrincipalClass in the
Info.plist file"`, and after fixing that it still needs `NSMainNibFile`
referencing a compiled nib.

Upstream QuakeSpasm's source also does not compile with `gcc-4.0`, and parts of
it call APIs that do not exist on 10.3.

## Decision

**`scripts/deploy.sh` assembles a complete `Quakespasm.app` and rsyncs it to
`<machine>:~/Desktop/quake/`. The same bundle goes to every machine,
byte-for-byte.**

```
Quakespasm.app/
  Contents/
    Info.plist
    MacOS/
      quakespasm            the fat binary; @executable_path resolves here
      lib*.dylib            10 codec dylibs (fat ppc + i386 + x86_64)
      SDL.framework/        fat; ADR 0003
    Resources/
      QuakeSpasm.icns
      autoexec-*.cfg        per-arch baselines + per-machine overlays; ADR 0006
      English.lproj/        Launcher.nib, InfoPlist.strings
```

Required `Info.plist` keys: `CFBundleExecutable=quakespasm`,
`NSPrincipalClass=SDLApplication`, `NSMainNibFile=Launcher`,
`CFBundleIconFile=QuakeSpasm`, `CFBundlePackageType=APPL`. `-nolauncher`
(handled in `AppController.m:135`) skips the launcher GUI and goes straight to
the game; `bench.sh` passes it automatically.

**The bundle is location-agnostic.** Whatever directory contains
`Quakespasm.app/` alongside `id1/` is the basedir. Three runtime paths arrive
there: Finder double-click, via `SDLMain.m setupWorkingDirectory:` →
`CFBundleCopyBundleURL` → parent dir → `chdir`; the launcher GUI's Play button,
via `AppController.m:206-210` taking `gArgv[0]` and stripping four components
(`quakespasm` / `MacOS` / `Contents` / `Quakespasm.app`); and headless
`-nolauncher`, where the shell `cd`s into the parent before exec. Only the bench
scripts pin `~/Desktop/quake/`, and that is a convention for predictable rsync
paths, not a binary requirement.

**Four source patches are required and are committed in tree.** None is
upstream-able without sniff macros.

1. `Quake/pl_osx.m:92-95` — Objective-C 2.0 dot-notation replaced with
   traditional setter calls (`setAlertStyle:`, `setMessageText:`,
   `setInformativeText:`). `gcc-4.0` cannot parse dot-notation.
2. `MacOSX/QuakeArguments.m` — `[NSString stringWithCString:encoding:]` and
   `[NSString cStringUsingEncoding:]` are 10.4+ APIs; wrapped in
   `QSpasmStringFromCString` / `QSpasmCStringFromString` macros that route to
   the deprecated `cString` / `stringWithCString:` variants on Panther. Without
   this the binary crashes inside `[QuakeArguments init]` with "unrecognized
   selector" when targeting 10.3.
3. `MacOSX/AppController.m:173` — the same NSString encoding fix.
4. `Quake/gl_vidsdl.c:1381-1390` — the multi-threaded OpenGL block wrapped in
   `#if MAC_OS_X_VERSION_MAX_ALLOWED >= 1040`. `kCGLCEMPEngine` is 10.4.8+ and
   does not exist in the 10.3.9 SDK headers. The B&W G3 is single-core, so the
   `host_parms->numcpus > 1` runtime check would skip the call anyway.

**Icons use legacy-only ICNS chunks** so Panther and Tiger can read them;
`iconutil` is wrong here. `scripts/make-icon.py` regenerates
`MacOSX/QuakeSpasm.icns` and defaults to conservative edge-flood-fill background
removal that preserves all interior detail. `--scrub-interior` exists for
AI-generated artwork with background leaking through glyph gaps, but its
heuristics (size, score-purity, annulus darkness) cannot reliably tell
background bleed from saturated specular highlights on metal. **Use Photoshop
touch-up rather than chasing algorithmic perfection**: run with defaults for a
conservative transparent-background master plus a magenta-composited
`--preview`, paint the visible pockets to alpha 0 by hand, then hand the RGBA
PNG back with `--keep-bg` to regenerate the ICNS without re-running removal.

## Alternatives rejected

**Relying on the system `SDL.framework`.** A typical Tiger install has 1.2.7,
too old for a binary linked against current_version 12.5.0. ADR 0003.

**Cfgs beside the game data instead of in `Resources/`.** ADR 0006.

**Cosmetic linker warnings as a reason to change flags.** Apple's own
`crt1.o` / `crt2.o` emit `-mlong-branch which is no longer needed` on PowerPC
builds. Harmless; silenced with `-Wl,-w` so a real link warning stands out.

## Consequences

- The end-user install is two drag-and-drops plus your own `id1/`. Nothing to
  configure and nothing to place correctly.
- The bundle is self-contained, so a deployed copy can be moved anywhere.
- Four patches have to survive every rebase onto upstream.
