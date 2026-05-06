#!/usr/bin/env bash
# Bootstrap a fresh Lion build host using the vendored installers in prereqs/.
# Designed to be re-runnable; skips steps that are already done.
#
# This script runs on Ubuntu and orchestrates everything via SSH to `lion`.
# Prerequisites:
#   - Lion mini reachable as `lion` SSH alias
#   - prereqs/ contains the Xcode DMGs and SDL-1.2.15.tar.gz
#   - Lion mini's user can sudo with the password that the user supplies
#     interactively (we don't store sudo passwords in scripts).
#
# usage: scripts/setup-lion.sh [skip-xcode|skip-sdl]

set -euo pipefail

LION="${LION:-lion}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKIP_XCODE=0
SKIP_SDL=0

for arg in "$@"; do
  case "$arg" in
    skip-xcode) SKIP_XCODE=1;;
    skip-sdl)   SKIP_SDL=1;;
  esac
done

echo "[setup-lion] target host: $LION"
ssh "$LION" 'echo "[setup-lion] connected: $(hostname -s) $(sw_vers -productVersion)"'

# 1. Verify or install Xcode 3.2.6 + SDKs ------------------------------------
if [ "$SKIP_XCODE" = "0" ]; then
  if ssh "$LION" '[ -x /usr/bin/gcc-4.0 ] && [ -d /Developer/SDKs/MacOSX10.4u.sdk ]'; then
    echo "[setup-lion] Xcode 3.2.6 + 10.4u SDK already in place"
  else
    echo "[setup-lion] uploading Xcode 3.2.6 DMG"
    rsync -av --partial --append-verify --inplace --timeout=120 \
      -e 'ssh -o ServerAliveInterval=15' \
      "$REPO_ROOT/prereqs/xcode_3.2.6_and_ios_sdk_4.3.dmg" \
      "$LION:Downloads/" | tail -3

    cat <<MSG
[setup-lion] Xcode installer is on Lion. The next steps need GUI access
            because the installer is interactive. From a Terminal on Lion
            (or via VNC), run:

    export COMMAND_LINE_INSTALL=1
    open "/Volumes/Xcode and iOS SDK/Xcode and iOS SDK.mpkg"

            Click through; install System Tools + UNIX Development;
            don't worry about the "Mac OS X 10.4 SDK" checkbox (it's
            misleading and we install it manually below).

            When done, re-run: scripts/setup-lion.sh skip-xcode
MSG
    exit 0
  fi

  # SDK packages from Xcode 3.2.6 (skip if already in place)
  if ! ssh "$LION" '[ -d /Developer/SDKs/MacOSX10.4u.sdk ]'; then
    echo "[setup-lion] installing 10.4u SDK package..."
    ssh "$LION" 'cd /Volumes/"Xcode and iOS SDK"/Packages 2>/dev/null || hdiutil attach ~/Downloads/xcode_3.2.6_and_ios_sdk_4.3.dmg
    sudo installer -pkg "/Volumes/Xcode and iOS SDK/Packages/MacOSX10.4.Universal.pkg" -target /
    sudo installer -pkg "/Volumes/Xcode and iOS SDK/Packages/MacOSX10.5.pkg" -target /
    [ -d /SDKs/MacOSX10.4u.sdk ] && sudo mv /SDKs/MacOSX10.4u.sdk /Developer/SDKs/
    [ -d /SDKs/MacOSX10.5.sdk  ] && sudo mv /SDKs/MacOSX10.5.sdk  /Developer/SDKs/
    sudo rmdir /SDKs 2>/dev/null || true
    hdiutil detach "/Volumes/Xcode and iOS SDK" 2>/dev/null || true'
  fi
fi

# 2. Extract 10.3.9 SDK from Xcode 2.5 DMG ----------------------------------
if ! ssh "$LION" '[ -d /Developer/SDKs/MacOSX10.3.9.sdk ]'; then
  echo "[setup-lion] uploading Xcode 2.5 DMG (for 10.3.9 SDK only)"
  rsync -av --partial --append-verify --inplace --timeout=120 \
    -e 'ssh -o ServerAliveInterval=15' \
    "$REPO_ROOT/prereqs/xcode25_8m2558_developerdvd.dmg" \
    "$LION:Downloads/" | tail -3
  echo "[setup-lion] extracting 10.3.9 SDK payload (no full Xcode 2.5 install)"
  ssh "$LION" 'hdiutil attach -nobrowse ~/Downloads/xcode25_8m2558_developerdvd.dmg | tail -1
  rm -rf /tmp/sdk103 && mkdir -p /tmp/sdk103 && cd /tmp/sdk103
  gunzip -c "/Volumes/Xcode Tools/Packages/Packages/MacOSX10.3.9.pkg/Contents/Archive.pax.gz" | pax -r
  SRC=$(find /tmp/sdk103 -maxdepth 6 -type d -name "MacOSX10.3.9.sdk" | head -1)
  sudo mv "$SRC" /Developer/SDKs/
  rm -rf /tmp/sdk103
  hdiutil detach "/Volumes/Xcode Tools" 2>/dev/null || true
  echo "[setup-lion] 10.3.9 SDK installed"'
else
  echo "[setup-lion] 10.3.9 SDK already in place"
fi

# 3. Build Panther SDL (only needed if SDL-panther.dylib isn't in repo) ------
if [ "$SKIP_SDL" = "0" ] && [ ! -f "$REPO_ROOT/MacOSX/SDL-panther.dylib" ]; then
  echo "[setup-lion] uploading SDL 1.2.15 source"
  rsync -av --partial --inplace -e 'ssh -o ServerAliveInterval=15' \
    "$REPO_ROOT/prereqs/SDL-1.2.15.tar.gz" "$LION:/tmp/" | tail -2

  echo "[setup-lion] building Panther SDL"
  ssh "$LION" 'cd /tmp && rm -rf SDL-1.2.15 && tar xzf SDL-1.2.15.tar.gz && cd SDL-1.2.15
  CC=/usr/bin/gcc-4.0 \
  CFLAGS="-arch ppc -isysroot /Developer/SDKs/MacOSX10.3.9.sdk -mmacosx-version-min=10.3 -O2" \
  LDFLAGS="-arch ppc -isysroot /Developer/SDKs/MacOSX10.3.9.sdk -mmacosx-version-min=10.3" \
  ./configure --host=powerpc-apple-darwin --build=i686-apple-darwin11 \
              --enable-shared --disable-static \
              --disable-video-x11 --disable-nasm --disable-altivec --disable-cdrom \
              > /tmp/sdl-config.log 2>&1
  make -j2 > /tmp/sdl-build.log 2>&1 || (tail -20 /tmp/sdl-build.log; exit 1)
  install_name_tool -id @executable_path/SDL.framework/Versions/A/SDL \
    build/.libs/libSDL-1.2.0.dylib'

  scp -q "$LION:/tmp/SDL-1.2.15/build/.libs/libSDL-1.2.0.dylib" \
    "$REPO_ROOT/MacOSX/SDL-panther.dylib"
  echo "[setup-lion] MacOSX/SDL-panther.dylib refreshed"
fi

echo
echo "[setup-lion] DONE. Lion is ready."
echo "[setup-lion] verify:"
ssh "$LION" '/usr/bin/gcc-4.0 --version | head -1
echo "/Developer/SDKs:"; ls /Developer/SDKs/'
