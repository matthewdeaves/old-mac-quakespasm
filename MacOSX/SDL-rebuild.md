# Rebuilding the fat SDL.framework

Once-per-version-bump procedure; not needed for normal work. Why the framework
looks like this (two hand-built PowerPC slices, the `install_name_tool -id`
re-id, and why SDL 1.2 rather than SDL2) is ADR 0003.

The shipped `SDL.framework/Versions/A/SDL` is fat:
**`x86_64 i386 ppc ppc970`**.

## Build the Panther `ppc` slice (`SDL-panther.dylib`)

Run on a Lion build mini. Source tarball comes from `prereqs/`.

```sh
cd /tmp && tar xzf /path/to/SDL-1.2.15.tar.gz && cd SDL-1.2.15
CC=/usr/bin/gcc-4.0 \
CFLAGS="-arch ppc -isysroot /Developer/SDKs/MacOSX10.3.9.sdk -mmacosx-version-min=10.3 -O2" \
LDFLAGS="-arch ppc -isysroot /Developer/SDKs/MacOSX10.3.9.sdk -mmacosx-version-min=10.3" \
./configure --host=powerpc-apple-darwin --build=i686-apple-darwin11 \
            --enable-shared --disable-static \
            --disable-video-x11 --disable-nasm --disable-altivec --disable-cdrom
make -j2
# result: build/.libs/libSDL-1.2.0.dylib (~300 KB)
install_name_tool -id @executable_path/SDL.framework/Versions/A/SDL build/.libs/libSDL-1.2.0.dylib
# copy back to MacOSX/SDL-panther.dylib
```

`--disable-video-x11` is mandatory: SDL's X11 GL backend pulls in conflicting
OpenGL header declarations against the 10.3.9 SDK, and this project uses the
Cocoa backend exclusively.

## Regenerate the x86_64 + i386 + ppc fat from a fresh upstream framework

```sh
# On Lion (lipo + install_name_tool live there)
cp upstream-SDL.framework/Versions/A/SDL /tmp/SDL-fat-orig
install_name_tool -id "@executable_path/SDL.framework/Versions/A/SDL" /tmp/SDL-fat-orig
lipo -replace ppc /path/to/MacOSX/SDL-panther.dylib /tmp/SDL-fat-orig \
     -output /path/to/MacOSX/SDL.framework/Versions/A/SDL
```

Until round v4 the port shipped upstream's fat SDL (10.6 SDK) and `deploy.sh g3`
overlaid `SDL-panther.dylib` on top of `Versions/A/SDL` per host. That swap is
gone; the bundled framework carries the Panther slice.

## Add the ppc970 Leopard slice

On a build mini, which has gcc-4.0 and the 10.5 SDK.

```sh
cd /tmp && tar xzf SDL-1.2.15.tar.gz && cd SDL-1.2.15
SDK=/Developer/SDKs/MacOSX10.5.sdk
CC=gcc-4.0 \
CFLAGS="-arch ppc -mcpu=970 -isysroot $SDK -mmacosx-version-min=10.5 -O2" \
CPPFLAGS="-arch ppc -isysroot $SDK -mmacosx-version-min=10.5" \
LDFLAGS="-arch ppc -isysroot $SDK -mmacosx-version-min=10.5 -Wl,-syslibroot,$SDK" \
  ./configure --host=powerpc-apple-darwin9 --build=i686-apple-darwin10 \
  --disable-video-x11 --disable-altivec --disable-cdrom --enable-shared --disable-static
# SDL injects -force_cpusubtype_ALL, which stamps generic `ppc` and would
# COLLIDE with the Panther slice. Strip it so -mcpu=970 stamps ppc970. (ADR 0002)
sed -i.bak 's/-force_cpusubtype_ALL//g' Makefile
make clean && make
install_name_tool -id "@executable_path/SDL.framework/Versions/A/SDL" build/.libs/libSDL-1.2.0.dylib
lipo -create /existing/SDL.framework/Versions/A/SDL build/.libs/libSDL-1.2.0.dylib \
     -output /path/to/MacOSX/SDL.framework/Versions/A/SDL
# verify: lipo -info -> x86_64 i386 ppc ppc970
```
