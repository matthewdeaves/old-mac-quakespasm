# QuakeSpasm PPC port — guidance for Claude

This file is loaded into every session. It captures durable tribal knowledge
that's expensive to re-derive. **The full plan lives in `PPC_PLAN.md`** — read
that for hardware inventory, decisions, the bench script, optimization list,
etc. This file is just the sticky facts.

## Goal in one line

Optimize QuakeSpasm framerate + visual quality on PowerPC Macs (G3 Panther +
G4 Tiger), via cross-builds from an Intel Mac mini on Lion.

## Hosts

SSH aliases live in `~/.ssh/config`:

- `lion` — Intel Mac mini, OS X 10.7.5. Cross-build host. PPC toolchain
  installed (see below).
- `PowerMacG3` — Blue & White, 450 MHz, 10.3 Panther, Rage 128 16 MB.
- G4 — not yet wired in `~/.ssh/config`; Quicksilver-class 867 MHz, 10.4 Tiger,
  AltiVec.

Old-Mac SSH (Lion + PPC) needs legacy crypto. The config entries already
include `HostKeyAlgorithms +ssh-rsa`, `PubkeyAcceptedKeyTypes +ssh-rsa`,
`KexAlgorithms +diffie-hellman-group-exchange-sha1[,group14-sha1[,group1-sha1]]`,
and use `id_rsa_tiger` (RSA, not ed25519 — pre-2014 OpenSSH can't validate
ed25519). Ad-hoc `ssh user@ip` without these flags will fail.

## Build path: `Quake/Makefile.darwin`, NOT the Xcode project

`MacOSX/QuakeSpasmPPC.xcodeproj` exists but `objectVersion=42` requires Xcode
3.2+, doesn't differentiate G3 from G4, and is more annoying than the
makefile. We use `Quake/Makefile.darwin` with `MACH_TYPE=ppc` and inject SDK +
`-mcpu` via `CPUFLAGS`/`LDFLAGS`.

## Toolchain on Lion (installed)

```
/usr/bin/gcc-4.0                              Apple gcc 4.0.1 (build 5494)
/Developer/SDKs/MacOSX10.3.9.sdk              G3 (Panther) target
/Developer/SDKs/MacOSX10.4u.sdk               G4 (Tiger) target
/Developer/SDKs/MacOSX10.5.sdk                bonus, unused
```

Per-target flags (full set, including the `-isysroot` and version-min):

- G3: `-isysroot /Developer/SDKs/MacOSX10.3.9.sdk -mmacosx-version-min=10.3.9 -arch ppc -mcpu=750 -O3`
- G4: `-isysroot /Developer/SDKs/MacOSX10.4u.sdk  -mmacosx-version-min=10.4   -arch ppc -mcpu=7400 -maltivec -mabi=altivec -O3 -mtune=7450`

Cosmetic linker warnings about `-mlong-branch` from Apple's `crt1.o`/`crt2.o`
are harmless. Suppress with `-Wl,-w` if noisy.

## Required patches for our target build (already applied in working tree)

These are minimum patches needed to compile cleanly with gcc-4.0 + 10.3.9
SDK. Both kept local; not upstream-able without sniff macros.

**1. `Quake/pl_osx.m:92-95`** — replace Obj-C 2.0 dot-notation (gcc-4.0 can't
parse it) with traditional setter calls:

```objc
[alert setAlertStyle: NSAlertStyleCritical];
[alert setMessageText: @"Quake Error"];
[alert setInformativeText: msg];
```

**2. `Quake/gl_vidsdl.c:1381–1390`** — wrap the multi-threaded OpenGL block
in `#if MAC_OS_X_VERSION_MAX_ALLOWED >= 1040`. `kCGLCEMPEngine` is 10.4.8+
and doesn't exist in the 10.3.9 SDK headers. B&W G3 is single-core so the
runtime check would skip the call anyway:

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

## Codebase facts you can't grep for

**No software renderer.** QuakeSpasm dropped FitzQuake's software path; it's
GL-only. Anything about "palette blit hot path" or "software inner loops"
doesn't apply.

**No existing PPC-specific code anywhere.** No `__VEC__`, `<altivec.h>`,
`frsqrte`, or asm. Greenfield.

**Two `SSE` mentions are defensive, not SSE code.** `gl_model.c:1414` and
`gl_rlight.c:326` cast lightmap-extent calcs to `double` to dodge x87/SSE2
precision drift. Universally safe; nothing to patch out.

## Hot files for the optimization phase

- `Quake/mathlib.c:276,281` — `VectorLength`, `VectorNormalize` use scalar
  `sqrt`. Target for `frsqrte` (~6 cyc vs ~30, base PowerPC, helps both G3
  and G4).
- `Quake/snd_mix.c:472,498` — `SND_PaintChannelFrom8/16`, sound mixer hot
  loops. AltiVec target (G4 only).
- `Quake/gl_texmgr.c` — `TexMgr_LoadImage8` 8→32 bit expansion at level
  load. Load-time, not per-frame.

## Build strategy: phase 1 = two binaries, no runtime dispatch yet

We ship `quakespasm-g3` and `quakespasm-g4` as separate binaries through
phase 1. Runtime dispatch (function pointers via `sysctlbyname("hw.optional.altivec")`)
is phase 2, after a few AltiVec wins are validated. Bisectable A/B comparison
is the priority — don't pile dispatch on top of in-progress AltiVec code.

## Benchmark discipline

Canonical: Quake's `timedemo demo1` / `demo2` / `demo3`. **3× runs, median
of 2 & 3.** Both G3 and G4 every change. Capture `qconsole.log` via
`-condebug`. Tag results with `(commit, machine, demo)`. **No source
changes beyond the `pl_osx.m` patch until clean baseline numbers exist
for both targets on unmodified upstream.**

## Runtime packaging on Tiger (G4) — required structure

Tiger's Cocoa requires a real `.app` bundle to launch a binary that uses
NSApplication. Bare-binary launch fails with `"No Info.plist file in
application bundle or no NSPrincipalClass in the Info.plist file"`. After
that's fixed, you also need `NSMainNibFile=Launcher` referencing the
compiled `Launcher.nib` from `MacOSX/English.lproj/`.

Bundle layout that works:

```
~/Desktop/quake/                       ← basedir; cwd at launch
  Quakespasm.app/
    Contents/
      Info.plist                       ← CFBundleExecutable=quakespasm,
                                          NSPrincipalClass=SDLApplication,
                                          NSMainNibFile=Launcher,
                                          CFBundleIconFile=QuakeSpasm
      MacOS/
        quakespasm                     ← @executable_path resolves here
        lib*.dylib (10 codec dylibs)   ← per binary's install_names
        SDL.framework/                 ← after install_name_tool fix
                                          (was @executable_path/../Frameworks)
      Resources/
        QuakeSpasm.icns
        English.lproj/
          Launcher.nib/
          InfoPlist.strings
  id1/, hipnotic/, rogue/              ← game data (basedir level)
  quakespasm.pak                       ← engine pak (basedir level)
```

Pass `-nolauncher` in args so `AppController.applicationDidFinishLaunching:`
skips the launcher GUI and goes straight to `launchQuake:` (line 135 of
`MacOSX/AppController.m`).

`install_name_tool` fixup (run on Lion before shipping):

```
install_name_tool -change \
  @executable_path/../Frameworks/SDL.framework/Versions/A/SDL \
  @executable_path/SDL.framework/Versions/A/SDL \
  quakespasm
```

System SDL.framework on a typical Tiger install is too old (1.2.7) for our
binary (linked against current_version=12.5.0 i.e. 1.2.16). Always ship
our framework alongside.

## Timedemo invocation pattern that actually works

`+timedemo demo1 +timedemo demo1 +timedemo demo1 +quit` in a single launch
**does not work** — they stomp each other in the cmd buffer; first frame
runs all four commands, demo runs zero frames, `+quit` kills the process.
You get `-1 frames 0.0 seconds` per "run."

Correct pattern: **3 separate launches, one `+timedemo demo1` each, no
`+quit`. Poll `qconsole.log` for the result line, kill the process via
SIGTERM when found.** See `bench.sh` (when written) — for now it's the
inline shell loop in PPC_PLAN.md.

## Workflow shape

```
Ubuntu (edit, git, orchestrate)
   │
   ├── rsync sources ──▶ Lion (cross-build PPC slice)
   │                          │
   │◀────── scp binary ───────┘
   │
   └── scp binary ──▶ G4/G3 (run timedemo, write qconsole.log)
                         │
   ◀────── scp log ────┘
```

Lion never ssh's anywhere outbound. Ubuntu does both legs.
