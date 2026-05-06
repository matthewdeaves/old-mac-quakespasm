# QuakeSpasm PowerPC Optimization Plan

Working document. Pick up from "Path to Baseline" when you return.

## Goal

Maximize performance and visual quality of QuakeSpasm on PowerPC Macs.
Two target classes, each with its own optimization profile.

## Hardware

| Role | Machine | CPU | OS | Notes |
|---|---|---|---|---|
| Editor | Ubuntu box | x86_64 | Ubuntu | Source-of-truth git tree; Claude Code runs here |
| Build host | Intel Mac | x86 | Mac OS X 10.7 Lion | Cross-builds PPC via Xcode 3.2.6 |
| Runtime A | PowerMac G4 | 867 MHz G4 (AltiVec) | Mac OS X 10.4 Tiger | 1 GB RAM, SSD |
| Runtime B | PowerMac G3 (Blue & White) | 450 MHz G3 (no AltiVec) | **Mac OS X 10.3 Panther** | RAM TBD, SSD, Rage 128 16 MB |

All on same LAN. Quake assets already in place on G3 + G4. Both PPC machines run a Fruitz of Dojo GLQuake build as sanity reference.

## Codebase Findings (sezero/quakespasm @ master)

**Build files relevant to our path:**

- `Quake/Makefile.darwin` — macOS native makefile. Auto-detects arch via `detect.sh`. Accepts `MACH_TYPE=ppc` override. Empty `CPUFLAGS=` exposed for `-mcpu` injection. Doesn't impose `-mmacosx-version-min` for 32-bit ppc. Bundled `MacOSX/SDL.framework` (1.2) used by default.
- `MacOSX/QuakeSpasmPPC.xcodeproj/project.pbxproj` — `objectVersion = 42`, `compatibilityVersion = "Xcode 3.2"`, `MACOSX_DEPLOYMENT_TARGET = 10.4`, `SDKROOT[arch=ppc] = MacOSX10.4u.sdk`, `GCC_VERSION = 4.0`, `ARCHS = ppc` (single slice), `VALID_ARCHS = "i386 x86_64 ppc"`. **No G3/G4 distinction.** **Will not open in Xcode 2.5** — file format requires Xcode 3.2+.
- `MacOSX/Build_Instructions.md` — Kristian Duske's dual-Xcode hack for Lion + Xcode 4. We're skipping it; plain Xcode 3.2.6 is enough.

**No existing PPC-specific code anywhere.** No `__VEC__`, no `<altivec.h>`, no `frsqrte`, no asm. Greenfield.

**Two "SSE" mentions in source are not SSE code** — they're defensive `(double)` casts in `gl_model.c:1414` and `gl_rlight.c:326` to avoid x87/SSE2 precision drift in lightmap-extent calcs. Universally safe; nothing to patch.

**No software renderer.** QuakeSpasm is GL-only. Drops items from the original optimization list (see below).

**Heap defaults already generous**: 256 MB heap, 4 MB zone. Probably want to dial *down* for the G3 once we know its RAM, not up.

## Build Strategy

**Phase 1 (now):** two separate binaries via `Makefile.darwin` on Lion.

- `quakespasm-g3`: `CPUFLAGS='-mcpu=750 -O3'`
- `quakespasm-g4`: `CPUFLAGS='-mcpu=7400 -maltivec -mabi=altivec -O3 -mtune=7450'`
- Why: every AltiVec routine needs scalar A/B comparison. Two binaries make that trivial. No dispatch infrastructure to debug while debugging the AltiVec code itself.

**Phase 2 (after AltiVec wins land):** consolidate. Two options to investigate:

- (a) Runtime dispatch — single binary, `sysctlbyname("hw.optional.altivec")` probe, function pointers in `Host_Init`. Same shape as the existing `BigShort/LittleShort` pattern in `common.c`.
- (b) Mach-O fat binary with `ppc` (generic) + `ppc7400` (G4) subtype slices. dyld picks the right one at exec — no C-side dispatch. **Needs hello-world verification before committing**; loader behavior on Tiger for subtype-matching needs to be checked, not assumed.

**Phase 3 (only if shipping publicly):** full universal. `lipo` together i386 + x86_64 + ppc slices. Packaging concern, layered last.

## Workflow

Ubuntu is the orchestrator — every transfer goes through it. SSH key auth from Ubuntu to each of the three Macs; **no key auth needed Lion ↔ PPC**.

```
Ubuntu                 Lion                  G4 / G3
──────                 ─────                 ───────
edit + git
   │
   │── rsync sources ──▶ build PPC slice
   │                          │
   │◀── scp binary ────────────
   │
   │──── scp binary ───────────────────────▶  run timedemo
   │                                              │
   │◀──── scp qconsole.log ───────────────────────
```

Lion never touches git — receives sources, produces binary, hands binary back. PPC machines never see source — receive binary, run timedemo, hand log back. All four legs are direct Ubuntu↔X transfers; nothing fans out from Lion.

## Benchmarking Discipline

- Canonical: `timedemo demo1`, `demo2`, `demo3`.
- Pin variables: fixed resolution, `vid_wait 0`, `-nosound`, no other apps.
- 3× back-to-back. Median of runs 2 and 3 (run 1 has texture upload; less of a confounder now that targets have SSDs, but keep the discipline).
- Bench BOTH G3 and G4 for every change. AltiVec wins can be no-ops or regressions on G3.
- `host_speeds 1` and `r_speeds 1` for per-frame breakdowns when investigating.
- Capture `qconsole.log` via `-condebug`. Tag every result with `(commit-hash, machine, demo)`.
- **NO source changes until clean baseline numbers exist on both G3 and G4 from unmodified upstream.**

## Optimization List

### G4-only (require AltiVec)

1. ~~AltiVec the 8→32 palette blit (software renderer hot path)~~ — **dropped**, no software renderer.
2. AltiVec sound mixer inner loops:
   - `SND_PaintChannelFrom8` — `Quake/snd_mix.c:472`
   - `SND_PaintChannelFrom16` — `Quake/snd_mix.c:498`
3. AltiVec mathlib batch ops (vertex transforms in bulk).

### G3 + G4 (universal PPC)

4. `frsqrte`-based normalize. Replaces `sqrt` in `VectorLength` (`Quake/mathlib.c:276`) and `VectorNormalize` (`Quake/mathlib.c:281`). `frsqrte` is base PowerPC since 601, ~6 cycles vs ~30 for `sqrt`.
5. Audit any remaining immediate-mode `glBegin/glEnd` paths and convert to vertex arrays.
6. Multitexture lightmaps (single pass instead of double pass). Rage 128 supports exactly 2 texture units, which is enough.
7. ~~Cache-friendly inner loops in software renderer~~ — **dropped**, no software renderer.
8. ~~Unrolled scalar palette blit~~ — **dropped**, no software renderer.
9. **Reversed**: tune hunk/zone sizes *down* for the G3 (leave G4 at defaults). Default heap 256 MB; B&W G3 with limited RAM probably wants less.
10. ~~Verify renderer doesn't assume SSE~~ — **done**, confirmed nothing to patch.

### Candidate not in original list

- `TexMgr_LoadImage8` 8→32 expansion at level load (`Quake/gl_texmgr.c`). CPU-bound now that disks are fast. AltiVec on G4 / unrolled scalar on G3. Affects load times, not framerate.

## Compile Flags Per CPU

- G3: `-mcpu=750 -O3`
- G4: `-mcpu=7400 -maltivec -mabi=altivec -O3 -mtune=7450`

(Plus `Makefile.darwin` defaults: `-Wall -MMD`, auto-detected `-fweb`, `-frename-registers`.)

## Decision: G3 Target = 10.3 Panther (locked)

User decision: G3 stays on Panther because it's the lighter OS for that hardware. G4 stays on 10.4 Tiger. We build two binaries with two SDK targets.

### Audit results

- **`MacOSX/AppController.m`, `SDLMain.m`, `SDLApplication.m`, `QuakeArgument*.m`, `ScreenInfo.m`** — clean. No `NSInteger`/`CGFloat`/`@property`/blocks/GCD. Conservative Cocoa, runs on 10.3 as-is.
- **`Quake/pl_osx.m`** — already has explicit `MAC_OS_X_VERSION_MIN_REQUIRED < 1040` and `< 1030` guards (lines 60, 84, 89) routing to legacy APIs when targeting Panther. The QuakeSpasm authors anticipated this build.
- **One known patch needed** — `pl_osx.m:92-95` uses Obj-C 2.0 dot-notation (`alert.alertStyle = ...`) on the `>= 1030` branch. gcc 4.0 doesn't support that syntax (it's gcc 4.2+). 3-line patch:

  ```objc
  // before:
  alert.alertStyle = NSAlertStyleCritical;
  alert.messageText = @"Quake Error";
  alert.informativeText = msg;
  // after:
  [alert setAlertStyle: NSAlertStyleCritical];
  [alert setMessageText: @"Quake Error"];
  [alert setInformativeText: msg];
  ```

  Apply this as part of bring-up; not an upstream-able fix unless we sniff `__OBJC2__`.

- **SDL.framework bundled is 1.2.16, built against 10.6 SDK.** Whether it runs on 10.3 depends on its link-time `MACOSX_DEPLOYMENT_TARGET`, which we can't tell without running `otool -l` on Lion (or just trying it on the G3). **Contingency:** if it doesn't load on 10.3, rebuild SDL 1.2.15 from libsdl.org sources against the 10.3.9 SDK and replace the bundled framework. Well-trodden, ~15 min of work.

## Toolchain Layout on Lion

User can install multiple Xcode versions. Plan: Xcode 3.2.6 as primary, plus the **10.3.9 SDK extracted from the Xcode 2.5 DMG** (no need to fully install Xcode 2.5 — we only want the SDK).

## Lion Toolchain Setup

### 1. Install Xcode 3.2.6 (primary)

- Source: <https://developer.apple.com/download/all/> (free Apple ID required). Search "Xcode 3.2.6 and iOS SDK 4.3". DMG ~4.1 GB.
- Lion install workaround (installer won't launch normally on 10.7):

  ```sh
  export COMMAND_LINE_INSTALL=1
  open "/Volumes/Xcode and iOS SDK/Xcode and iOS SDK.mpkg"
  ```

- Components: enable **Mac OS X 10.4 SDK** (essential for G4 build), Mac OS X 10.5 SDK (free bonus), System Tools, Unix Development. Skip iOS SDK, iOS Simulator.
- Default `/Developer` install target is fine.
- Sanity check after install:

  ```sh
  /usr/bin/gcc-4.0 -arch ppc -v          # version + ppc target info
  ls /Developer/SDKs                     # MacOSX10.4u.sdk + MacOSX10.5.sdk
  xcodebuild -version                    # Xcode 3.2.6
  ```

### 2. Graft the 10.3.9 SDK from Xcode 2.5

Xcode 3.2.6 doesn't ship the 10.3.9 SDK; it was last in Xcode 2.5. We don't need to install Xcode 2.5 in full (its installer is Tiger-era and won't run cleanly on Lion anyway) — we just extract the SDK package.

- Source: same Apple Developer downloads page, search "Xcode 2.5 Developer Tools" (also free Apple ID).
- After downloading, mount the DMG. Don't run the installer. Find the SDK package at:

  ```
  /Volumes/Xcode Tools/Packages/MacOSX10.3.9.pkg
  ```

- Expand the package and copy the SDK into place:

  ```sh
  cd /tmp
  pkgutil --expand "/Volumes/Xcode Tools/Packages/MacOSX10.3.9.pkg" macosx10.3.9
  # The expanded pkg contains a Payload archive (cpio.gz). Find the SDK root:
  cd macosx10.3.9
  cat Payload | gunzip | cpio -id
  # The SDK appears at ./Developer/SDKs/MacOSX10.3.9.sdk/ (or similar).
  sudo cp -R Developer/SDKs/MacOSX10.3.9.sdk /Developer/SDKs/MacOSX10.3.9.sdk
  ```

  (Exact internal path may vary — `find . -name MacOSX10.3.9.sdk -type d` after expand will pin it.)

- Sanity check:

  ```sh
  ls /Developer/SDKs/MacOSX10.3.9.sdk/usr/include/stdio.h    # exists
  /usr/bin/gcc-4.0 -arch ppc -isysroot /Developer/SDKs/MacOSX10.3.9.sdk \
      -mmacosx-version-min=10.3.9 -E - </dev/null > /dev/null  # no errors
  ```

### 3. (Optional, contingency only) Rebuild SDL 1.2 for 10.3

Only needed if the bundled `MacOSX/SDL.framework` (1.2.16, built against 10.6 SDK) refuses to load on the G3. Decide after first 10.3 binary is shipped to the G3 and tried.

If needed:

```sh
# Get SDL 1.2.15 sources from libsdl.org, then on Lion:
./configure CC=/usr/bin/gcc-4.0 CFLAGS="-arch ppc -isysroot /Developer/SDKs/MacOSX10.3.9.sdk -mmacosx-version-min=10.3.9" \
            LDFLAGS="-arch ppc -isysroot /Developer/SDKs/MacOSX10.3.9.sdk -mmacosx-version-min=10.3.9" \
            --host=powerpc-apple-darwin --disable-shared --enable-static=no
make
# Then build the framework bundle (Xcode/SDL.xcodeproj works) and replace MacOSX/SDL.framework.
```

## Path to Baseline (resume here)

**Status check:**

- ✅ Xcode 3.2.6 + 10.4u SDK + 10.5 SDK + 10.3.9 SDK installed on Lion (`/Developer/SDKs/`). PPC `hi.c` smoke-tests pass for all three SDKs.
- ✅ SSH alias `lion` in `~/.ssh/config`, key auth verified (`id_rsa_tiger`).
- ✅ SSH alias `PowerMacG3` in `~/.ssh/config` (pre-existing). Key auth status pending — need G3 powered on to verify.
- ❌ G4 not in `~/.ssh/config` yet, no key bootstrap.
- ✅ `pl_osx.m:92-95` setter-syntax patch applied.
- ✅ `gl_vidsdl.c:1381-1390` `kCGLCEMPEngine` version-gate applied (discovered during first G3 build).
- ✅ G4 binary builds cleanly (`Mach-O executable ppc`, 726 KB, 10.4u SDK, mcpu=7400 +AltiVec, all codecs).
- ✅ G3 binary builds cleanly (`Mach-O executable ppc`, 726 KB, 10.3.9 SDK, mcpu=750, all codecs).
- ✅ G4 binary verified on real hardware (G4 733 MHz / Radeon 9000 / 10.4.11). Runs cleanly.
- ❌ G3 binary not tested (Panther machine still off).
- ✅ G4 baseline captured: demo1 = 127.1 fps median (`benchmarks/baseline.csv`, commit 6baceeac + 2 build patches).
- ❌ G3 baseline not captured.
- ❓ Bundled SDL.framework 1.2.16 built against 10.6 SDK — G4 needed our shipped copy (system SDL was 1.2.7, too old). Same will apply on G3. Whether our 10.6-SDK-built framework loads on Panther is the contingency to watch for.

Outstanding before first baseline run:

- G3 + G4 powered on.
- Asset paths known on G3 and G4 (e.g. `~/quake/id1/pak0.pak`?).
- Hostnames known. Plan assumes `lion`, `PowerMacG3`, and a future G4 alias — adjust as needed.

Bench script — drop in `~/bin/bench.sh` on Ubuntu, `chmod +x`:

```bash
#!/bin/bash
# usage: ./bench.sh <target> [demo]
# target = g3 or g4; selects SDK + cpuflags automatically.
# demo defaults to demo1.

set -euo pipefail
TARGET=$1
DEMO=${2:-demo1}

LION_HOST=lion.local
SRC=$HOME/quakespasm
COMMIT=$(git -C "$SRC" rev-parse --short HEAD)

case "$TARGET" in
  g3)
    HOST=g3.local
    SDK=/Developer/SDKs/MacOSX10.3.9.sdk
    VMIN=10.3.9
    CPUFLAGS='-mcpu=750 -O3'
    ;;
  g3-baseline)
    HOST=g3.local
    SDK=/Developer/SDKs/MacOSX10.3.9.sdk
    VMIN=10.3.9
    CPUFLAGS=''        # default -O2 from Makefile.darwin
    ;;
  g4)
    HOST=g4.local
    SDK=/Developer/SDKs/MacOSX10.4u.sdk
    VMIN=10.4
    CPUFLAGS='-mcpu=7400 -maltivec -mabi=altivec -O3 -mtune=7450'
    ;;
  g4-baseline)
    HOST=g4.local
    SDK=/Developer/SDKs/MacOSX10.4u.sdk
    VMIN=10.4
    CPUFLAGS=''
    ;;
  *) echo "unknown target: $TARGET (g3|g4|g3-baseline|g4-baseline)"; exit 1;;
esac

TAG="${COMMIT}_${TARGET}_${DEMO}"
SYSROOT_FLAGS="-isysroot $SDK -mmacosx-version-min=$VMIN -arch ppc"

echo "==> rsync Ubuntu → Lion"
rsync -avz --delete \
  --exclude='*.o' --exclude='*.d' --exclude='quakespasm' \
  --exclude='.git' \
  "$SRC/" "$LION_HOST:quakespasm/"

echo "==> build PPC slice on Lion (SDK=$SDK, vmin=$VMIN)"
mkdir -p "$SRC/benchmarks"
ssh "$LION_HOST" "cd quakespasm/Quake && \
  make -f Makefile.darwin clean && \
  make -f Makefile.darwin MACH_TYPE=ppc -j2 \
    CPUFLAGS='$SYSROOT_FLAGS $CPUFLAGS' \
    LDFLAGS='$SYSROOT_FLAGS' \
    USE_CODEC_FLAC=0 USE_CODEC_OPUS=0 USE_CODEC_VORBIS=0 \
    USE_CODEC_MP3=0 USE_CODEC_XMP=0 USE_CODEC_UMX=0 \
    CC=/usr/bin/gcc-4.0 2>&1" | tee "$SRC/benchmarks/build_${TAG}.log"

echo "==> fetch binary back to Ubuntu"
mkdir -p "$SRC/build"
scp "$LION_HOST:quakespasm/Quake/quakespasm" "$SRC/build/quakespasm-${TARGET}"

echo "==> ship binary from Ubuntu to $HOST"
scp "$SRC/build/quakespasm-${TARGET}" "$HOST:quakespasm-bin"

echo "==> timedemo on $HOST"
# Adjust -basedir to where assets actually live on each PPC box.
ssh "$HOST" "rm -f qconsole.log && \
  ./quakespasm-bin -basedir \$HOME/quake -nosound -condebug \
    +vid_wait 0 +timedemo $DEMO +timedemo $DEMO +timedemo $DEMO +quit"

scp "$HOST:qconsole.log" "$SRC/benchmarks/${TAG}.log"
echo "==> result in benchmarks/${TAG}.log"
grep -E "fps|seconds" "$SRC/benchmarks/${TAG}.log" | tail -10
```

**Day 1 run order:**

1. Apply the `pl_osx.m:92-95` setter-syntax patch (see "Audit results" above) — required for the build to succeed at all.
2. `./bench.sh g4-baseline demo1` → G4 baseline
3. `./bench.sh g3-baseline demo1` → G3 baseline (will reveal SDL framework compatibility on Panther)
4. Record both in `benchmarks/baseline.csv` keyed by `(commit, machine, demo, fps_run1, fps_run2, fps_run3, median)`.
5. `git add benchmarks/ && git commit -m "baseline numbers, unmodified upstream + minimal Panther build patches"`.

**Only after baseline numbers exist on both machines do we touch source code beyond the minimum patches needed to build.**

## Open Items

- Asset paths on G3 and G4 (wire into `-basedir`).
- Actual RAM in the B&W G3 (heap-size tuning input).
- SSH key auth Ubuntu → Lion, Ubuntu → G4, Ubuntu → G3 (three direct keys; Lion does not need to ssh anywhere).
- Real hostnames (the script assumes `lion.local`/`g4.local`/`g3.local`).
- Whether bundled SDL.framework 1.2.16 actually loads on 10.3 Panther — only knowable by trying. Plan B (rebuild SDL 1.2.15 from source) documented above.

## File Reference

- `MacOSX/QuakeSpasmPPC.xcodeproj/` — existing PPC Xcode project (we're not using it; Makefile path is cleaner).
- `MacOSX/Build_Instructions.md` — Kristian's dual-Xcode-on-Lion docs (informational only).
- `MacOSX/SDL.framework/` — bundled SDL 1.2, what `Makefile.darwin` links against.
- `Quake/Makefile.darwin` — the build file we're driving.
- `Quake/Makefile` — Linux/generic Unix (not used here).
- `Quake/build_cross_osx.sh` — Linux→Mach-O via osxcross (not used here).
- `Quake/mathlib.c` — `frsqrte` target (item 4): `VectorLength` :276, `VectorNormalize` :281.
- `Quake/snd_mix.c` — AltiVec target (item 2): `SND_PaintChannelFrom8` :472, `SND_PaintChannelFrom16` :498.
- `Quake/gl_texmgr.c` — `TexMgr_LoadImage8` (load-time texture expansion candidate).
- `benchmarks/` — to be created, git-tracked. CSV index + per-run `qconsole.log`s.
