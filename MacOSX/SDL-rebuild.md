# Rebuilding the fat SDL.framework

Once-per-version-bump procedure (not needed for normal work — see
[`CLAUDE.md`](CLAUDE.md) for the day-to-day MacOSX facts). The shipped
`SDL.framework/Versions/A/SDL` is fat: **x86_64 + i386 + ppc + ppc970**.

## Why two PPC slices

The generic **`ppc` slice is the Panther-compatible 10.3.9-SDK build**
(`SDL-panther.dylib`) and serves G3/G4 on Panther/Tiger. A second **`ppc970`
slice is a 10.5-SDK Leopard build** for the iMac G5 — dyld auto-selects it on the
970; G3/G4 keep the generic `ppc` slice (zero regression). The Panther build's
fullscreen path is suspect on Leopard, so the G5 gets a slice built natively for
it. (The GLSL/VBO GPU-hang on the iMac G5's Radeon 9600 was NOT an SDL bug — it's
fixed by the engine-side ATI R300 GL 1.x gate — but shipping a Leopard-built SDL
for the G5 is correct regardless.)

`SDL-panther.dylib` is a ppc-only SDL 1.2.15 built against the 10.3.9 SDK with
`--disable-video-x11 --disable-altivec --disable-cdrom`. Why it's needed:
upstream's PPC slice was linked against the 10.6 SDK and crashes inside
`SDL_VideoInit + 608` on Panther (jumps to a Quartz address that doesn't exist on
10.3). The Panther slice still loads and works on Tiger and Lion, so one slice
covers both PPC OS versions.

Why `install_name_tool -id` first: dyld matches `LC_LOAD_DYLIB` against the loaded
slice's `LC_ID_DYLIB`. Upstream's three slices were id'd
`@executable_path/../Frameworks/SDL.framework/...`, which doesn't match where we
actually drop it. Re-iding all three to
`@executable_path/SDL.framework/Versions/A/SDL` aligns with the engine binary's
install_name fixup in `scripts/build.sh:109`.

## Regenerate the x86_64 + i386 + ppc fat (round v4 §14.5)

Until round v4 we shipped upstream fat SDL (10.6 SDK) and ran a per-host swap in
`deploy.sh g3` that overlaid `SDL-panther.dylib` on top of `Versions/A/SDL`. The
swap is gone — the bundled framework now carries the Panther slice. To regenerate
from a fresh upstream fat (e.g. on an SDL version bump):

```sh
# On Lion (lipo + install_name_tool live there)
cp upstream-SDL.framework/Versions/A/SDL /tmp/SDL-fat-orig
install_name_tool -id "@executable_path/SDL.framework/Versions/A/SDL" /tmp/SDL-fat-orig
lipo -replace ppc /path/to/MacOSX/SDL-panther.dylib /tmp/SDL-fat-orig \
     -output /path/to/MacOSX/SDL.framework/Versions/A/SDL
```

## Add the ppc970 Leopard slice (2026-05-31)

The 4th slice is a fresh SDL 1.2.15 built for Leopard and lipo'd in. To
regenerate (on the cross-build host mini-intel, which has gcc-4.0 + the 10.5 SDK):

```sh
# 1. cross-build SDL 1.2.15 ppc970 against the 10.5 SDK
cd /tmp && tar xzf SDL-1.2.15.tar.gz && cd SDL-1.2.15
SDK=/Developer/SDKs/MacOSX10.5.sdk
CC=gcc-4.0 \
CFLAGS="-arch ppc -mcpu=970 -isysroot $SDK -mmacosx-version-min=10.5 -O2" \
CPPFLAGS="-arch ppc -isysroot $SDK -mmacosx-version-min=10.5" \
LDFLAGS="-arch ppc -isysroot $SDK -mmacosx-version-min=10.5 -Wl,-syslibroot,$SDK" \
  ./configure --host=powerpc-apple-darwin9 --build=i686-apple-darwin10 \
  --disable-video-x11 --disable-altivec --disable-cdrom --enable-shared --disable-static
# SDL injects -force_cpusubtype_ALL which stamps generic `ppc` and would
# COLLIDE with the Panther slice -- strip it so -mcpu=970 stamps ppc970:
sed -i.bak 's/-force_cpusubtype_ALL//g' Makefile
make clean && make
# 2. id + lipo the ppc970 slice into the existing fat framework
install_name_tool -id "@executable_path/SDL.framework/Versions/A/SDL" build/.libs/libSDL-1.2.0.dylib
lipo -create /existing/SDL.framework/Versions/A/SDL build/.libs/libSDL-1.2.0.dylib \
     -output /path/to/MacOSX/SDL.framework/Versions/A/SDL
# verify: `lipo -info` -> x86_64 i386 ppc ppc970
```
