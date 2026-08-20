# prereqs/: installers and source tarballs

> **Not in git.** This directory is `.gitignore`d (~5 GB). Download the files
> below into `prereqs/` once on a fresh clone; `scripts/setup-lion.sh` expects
> them here. Verify MD5s after download.

| File | Size | MD5 |
|---|---|---|
| `xcode_3.2.6_and_ios_sdk_4.3.dmg` | 4.2 GB | `2a02f5c2b44d80ff3047cc4d7a281127` |
| `xcode25_8m2558_developerdvd.dmg` | 903 MB | `3bd6c24d8fbbdf9007e15861d173764d` |
| `SDL-1.2.15.tar.gz` | 3.8 MB | `9d96df8417572a2afb781a7c4c811a85` |

## Where to download

**Xcode 3.2.6 and iOS SDK 4.3 for Snow Leopard** (primary toolchain):

- Apple Developer (free Apple ID required): <https://developer.apple.com/download/all/>
  search "Xcode 3.2.6"
- Direct authenticated link (same file): <https://download.developer.apple.com/Developer_Tools/xcode_3.2.6_and_ios_sdk_4.3__final/xcode_3.2.6_and_ios_sdk_4.3.dmg>
- archive.org mirror (no Apple ID): <https://archive.org/details/xcode-3.2.6>

**Xcode 2.5 Developer Tools** (only used to extract the 10.3.9 SDK):

- Apple Developer (free Apple ID required): <https://developer.apple.com/download/all/>
  search "Xcode 2.5"
- Direct authenticated link (same file): <https://download.developer.apple.com/Developer_Tools/xcode_2.5_developer_tools/xcode25_8m2558_developerdvd.dmg>
- archive.org mirror (no Apple ID): <https://archive.org/details/XCode2.5>
  (file `xcode25_8m2558_developerdvd.dmg`)

**SDL 1.2.15 source** (to rebuild SDL.framework for Panther):

- libsdl.org: <https://www.libsdl.org/release/SDL-1.2.15.tar.gz>
- GitHub mirror (in case libsdl.org goes dark):
  <https://github.com/libsdl-org/SDL-1.2/archive/refs/tags/release-1.2.15.tar.gz>

## Verify after download

```sh
cd prereqs/
md5sum *.dmg *.tar.gz
# should match the table above
```

## What each is for

**`xcode_3.2.6_and_ios_sdk_4.3.dmg`**, primary toolchain on the Lion
build host. Provides `gcc-4.0` (Apple's last gcc with full PPC support),
the 10.4u SDK (G4 target), and the 10.5 SDK. Install on Lion via:

```sh
hdiutil attach xcode_3.2.6_and_ios_sdk_4.3.dmg
export COMMAND_LINE_INSTALL=1
open "/Volumes/Xcode and iOS SDK/Xcode and iOS SDK.mpkg"
```

The `COMMAND_LINE_INSTALL=1` is required on Lion, the GUI installer
refuses to launch otherwise. Inside the GUI you'll want **System Tools**,
**UNIX Development**, and to manually run the SDK packages individually
afterwards (the "Mac OS X 10.4 SDK" top-level checkbox is misleading; it
shows "Zero KB" and doesn't actually install anything). After the GUI:

```sh
sudo installer -pkg "/Volumes/Xcode and iOS SDK/Packages/MacOSX10.4.Universal.pkg" -target /
sudo installer -pkg "/Volumes/Xcode and iOS SDK/Packages/MacOSX10.5.pkg"          -target /
# Both packages have a buggy install path, they land at /SDKs/, not /Developer/SDKs/
sudo mv /SDKs/MacOSX10.4u.sdk /Developer/SDKs/
sudo mv /SDKs/MacOSX10.5.sdk  /Developer/SDKs/
sudo rmdir /SDKs
```

**`xcode25_8m2558_developerdvd.dmg`**, only used to extract the 10.3.9
SDK (for G3 target). **Don't install Xcode 2.5 in full** on Lion,
its installer has a host-OS check that refuses on 10.7. Instead extract
the SDK package's payload directly:

```sh
hdiutil attach xcode25_8m2558_developerdvd.dmg
mkdir -p /tmp/sdk103 && cd /tmp/sdk103
gunzip -c "/Volumes/Xcode Tools/Packages/Packages/MacOSX10.3.9.pkg/Contents/Archive.pax.gz" | pax -r
sudo mv ./SDKs/MacOSX10.3.9.sdk /Developer/SDKs/
hdiutil detach "/Volumes/Xcode Tools"
```

**`SDL-1.2.15.tar.gz`**, needed to build a 10.3-compatible SDL.framework
binary for the G3 deployment. The bundled `MacOSX/SDL.framework` (built
against 10.6 SDK) crashes on Panther inside `SDL_VideoInit`. The compiled
result of building from this tarball is committed at `MacOSX/SDL-panther.dylib`
and is what `scripts/deploy.sh g3` swaps into the framework's `Versions/A/SDL`
slot. To rebuild from scratch:

```sh
# On Lion:
cd /tmp && tar xzf /path/to/SDL-1.2.15.tar.gz && cd SDL-1.2.15
CC=/usr/bin/gcc-4.0 \
CFLAGS="-arch ppc -isysroot /Developer/SDKs/MacOSX10.3.9.sdk -mmacosx-version-min=10.3 -O2" \
LDFLAGS="-arch ppc -isysroot /Developer/SDKs/MacOSX10.3.9.sdk -mmacosx-version-min=10.3" \
./configure --host=powerpc-apple-darwin --build=i686-apple-darwin11 \
            --enable-shared --disable-static \
            --disable-video-x11 --disable-nasm --disable-altivec --disable-cdrom
make -j2
# Result: build/.libs/libSDL-1.2.0.dylib (~300 KB)
install_name_tool -id @executable_path/SDL.framework/Versions/A/SDL build/.libs/libSDL-1.2.0.dylib
# Copy back to repo at MacOSX/SDL-panther.dylib
```

`--disable-video-x11` is mandatory: SDL's X11 GL backend pulls in conflicting
OpenGL header decls when built against the 10.3.9 SDK. We use the Cocoa
backend exclusively on this project anyway.

## Why these MD5s matter

If any of these are ever re-downloaded from Apple/libsdl.org, the MD5s
should match. If they don't, treat the new file as suspect, Apple has
been known to silently re-pack DMGs, and a different binary may behave
slightly differently with our patches.
