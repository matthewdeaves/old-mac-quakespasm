# MacOSX/ — sticky facts for Claude

Upstream's `Build_Instructions.md` covers Xcode-project workflow (not
how we build). This file is the LLM context for what's actually
required to ship working bundles on Panther / Tiger / Lion / Sequoia.

## Toolchain on Lion (installed)

```
/usr/bin/gcc-4.0                Apple gcc 4.0.1 (build 5494) — PPC cross
/usr/bin/clang                  Apple clang (Lion default) — Intel native
/usr/bin/gcc-4.2                llvm-gcc-4.2.1 — Intel fallback
/Developer/SDKs/MacOSX10.3.9.sdk    G3 (Panther) target
/Developer/SDKs/MacOSX10.4u.sdk     G4 (Tiger) target
/Developer/SDKs/MacOSX10.5.sdk      bonus, unused
```

Per-target flags:

- G3:   `-isysroot /Developer/SDKs/MacOSX10.3.9.sdk -mmacosx-version-min=10.3.9 -arch ppc -mcpu=750 -O3`
- G4:   `-isysroot /Developer/SDKs/MacOSX10.4u.sdk  -mmacosx-version-min=10.4   -arch ppc -mcpu=7400 -maltivec -mabi=altivec -O3 -mtune=7450`
- Lion: `-arch x86_64 -mmacosx-version-min=10.7 -O3` (no `-isysroot`;
  uses Lion's default toolchain SDK). Lion's kernel is `RELEASE_I386`
  on Macmini2,1, but Core 2 Duo + 10.7's user-space happily run
  x86_64 binaries.

Cosmetic linker warnings about `-mlong-branch` from Apple's
`crt1.o`/`crt2.o` are harmless on PPC builds. Suppress with `-Wl,-w`
if noisy.

## Required patches (already applied)

Four patches for clean compile + runtime on G3 Panther + G4 Tiger.
All committed; not upstream-able without sniff macros.

**1. `Quake/pl_osx.m:92-95`** — replace Obj-C 2.0 dot-notation
(gcc-4.0 can't parse it) with traditional setter calls:

```objc
[alert setAlertStyle: NSAlertStyleCritical];
[alert setMessageText: @"Quake Error"];
[alert setInformativeText: msg];
```

**2. `MacOSX/QuakeArguments.m`** — wrap
`[NSString stringWithCString:encoding:]` and
`[NSString cStringUsingEncoding:]` (10.4+ APIs) in
`QSpasmStringFromCString` / `QSpasmCStringFromString` macros that
route to the deprecated `cString` / `stringWithCString:` variants on
Panther. Without this the binary crashes inside `[QuakeArguments init]`
with "unrecognized selector" when targeting 10.3.

**3. `MacOSX/AppController.m`** — same NSString-encoding fix at line 173.

**4. `Quake/gl_vidsdl.c:1381–1390`** — wrap the multi-threaded OpenGL
block in `#if MAC_OS_X_VERSION_MAX_ALLOWED >= 1040`. `kCGLCEMPEngine`
is 10.4.8+ and doesn't exist in the 10.3.9 SDK headers. B&W G3 is
single-core so the runtime check would skip the call anyway:

```c
#ifdef __APPLE__
#if MAC_OS_X_VERSION_MAX_ALLOWED >= 1040
    if (host_parms->numcpus > 1 &&
        kCGLNoError != CGLEnable(CGLGetCurrentContext(), kCGLCEMPEngine))
    {
        Con_Warning ("Couldn't enable multi-threaded OpenGL");
    }
#endif
#endif
```

## Tiger/Panther Cocoa requires a real .app bundle

Bare-binary launch via SSH fails with `"No Info.plist file in
application bundle or no NSPrincipalClass in the Info.plist file"`.
After fixing that, you also need `NSMainNibFile=Launcher` referencing
the compiled `MacOSX/English.lproj/Launcher.nib/`.

Required Info.plist keys:

```
CFBundleExecutable=quakespasm
NSPrincipalClass=SDLApplication
NSMainNibFile=Launcher
CFBundleIconFile=QuakeSpasm
CFBundlePackageType=APPL
```

Pass `-nolauncher` in args (handled in `AppController.m:135`) to skip
the launcher GUI window and go straight to the game. `bench.sh` passes
this automatically.

## Bundle layout

```
<basedir>/                              ← cwd at launch (any dir)
  Quakespasm.app/
    Contents/
      Info.plist                        ← keys above
      MacOS/
        quakespasm                      ← @executable_path resolves here
        lib*.dylib (10 codec dylibs)    ← per binary's install_names
        SDL.framework/                  ← after install_name_tool fix
                                           (was @executable_path/../Frameworks)
      Resources/
        QuakeSpasm.icns
        autoexec-ppc750.cfg             ← per-arch baseline (G3); picked at
        autoexec-ppc7400.cfg            ←   compile time via __VEC__/__ppc__/
        autoexec-x86_64.cfg             ←   __x86_64__ in host.c
        autoexec-yosemite.cfg           ← per-machine overlay; picked at
        autoexec-sawtooth.cfg           ←   runtime via sysctl hw.model.
        autoexec-quicksilver.cfg        ←   Both layers loaded via CFBundle
        autoexec-mini-g4.cfg            ←   by QS_ExecConfigFromBundle —
        autoexec-mini-intel.cfg         ←   self-contained .app, no id1/cfgs
        autoexec-imac-2019.cfg          ←   needed for hand-tuned settings.
        English.lproj/
          Launcher.nib/
          InfoPlist.strings
  id1/, hipnotic/, rogue/               ← game data (basedir level)
  quakespasm.pak                        ← engine pak (basedir level)
```

End-user install is **just**: drop `Quakespasm.app` + `quakespasm.pak`
into any folder, add `id1/pak0.pak` (+ `pak1.pak` for registered)
alongside, double-click. The per-machine visual stack travels inside
the .app — no separate cfg drop required.

## Bundle is portable

`Quakespasm.app` is **location-agnostic** by design — does not need to
live in `~/Desktop/quake/`. Whatever directory contains
`Quakespasm.app/` alongside `id1/` etc is treated as the basedir at
launch. Three runtime paths arrive at this:

1. **Finder double-click**: `SDLMain.m setupWorkingDirectory:` uses
   `CFBundleCopyBundleURL` → parent dir → `chdir`. Relative to where
   the bundle actually lives.
2. **Launcher GUI → Play**: `AppController.m:206-210` takes `gArgv[0]`
   (path to `Contents/MacOS/quakespasm`), strips 4 last components
   (`quakespasm`/`MacOS`/`Contents`/`Quakespasm.app`), and
   `changeCurrentDirectoryPath:` to the result.
3. **Headless `-nolauncher`** (bench.sh / screenshot.sh): shell `cd`s
   into the parent dir before exec'ing the binary.

Only the bench scripts pin the location to `~/Desktop/quake/` — that's
a convention for predictable rsync paths, **not** a binary requirement.

## Bundle is fully universal

`SDL.framework` is fat (**x86_64 + i386 + ppc + ppc970**). `codecs/lib/
*.dylib` are fat too. Combined with the fat engine binary
(`build/quakespasm-fat` — ppc750 + ppc7400 + ppc970 + x86_64),
`deploy.sh <target>` ships the same bundle byte-for-byte to G3, G4,
G4mini, G5, Lion, and iMac-2019. The only per-host action `deploy.sh`
takes is rsync (plus the migration cleanup of any pre-v1.4 id1/cfgs).

**Two PPC SDL slices (2026-05-31):** the generic **`ppc` slice is the
Panther-compatible 10.3.9-SDK build** (`SDL-panther.dylib`) and serves
G3/G4 on Panther/Tiger. A second **`ppc970` slice is a 10.5-SDK Leopard
build** for the iMac G5 — dyld auto-selects it on the 970, G3/G4 keep the
generic `ppc` slice (zero regression). The Panther build's fullscreen
path is suspect on Leopard, so the G5 gets a slice built natively for it.
(Note: the GLSL/VBO GPU-hang on the iMac G5's Radeon 9600 was NOT an SDL
bug — it's fixed by the engine-side ATI R300 GL 1.x gate — but shipping a
Leopard-built SDL for the G5 is the correct thing regardless.)

## install_name_tool fixup (run on Lion before shipping)

```sh
install_name_tool -change \
  @executable_path/../Frameworks/SDL.framework/Versions/A/SDL \
  @executable_path/SDL.framework/Versions/A/SDL \
  quakespasm
```

System SDL.framework on a typical Tiger install is too old (1.2.7) for
our binary (linked against current_version=12.5.0 i.e. 1.2.16). Always
ship our framework alongside the binary, never rely on the system one.

## Rebuilding the fat SDL.framework

Once-per-version-bump recipes — the x86_64+i386+ppc fat regen, the ppc970 Leopard
slice cross-build, why `SDL-panther.dylib` exists, and the `install_name_tool -id`
rationale — live in [`SDL-rebuild.md`](SDL-rebuild.md). Not needed for normal work.
