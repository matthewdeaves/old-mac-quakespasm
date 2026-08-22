#!/usr/bin/env bash
# build-arm64.sh: build the arm64 (Apple Silicon) slice.
#
# This one runs HERE, on the orchestration Mac, not on an Intel Lion mini.
# Lion's Xcode 4.6 toolchain predates arm64 by seven years and cannot target
# it at all, so unlike the other five slices this cannot be a `build.sh`
# target: build.sh rsyncs to the mini and compiles there. Same split the
# sister Half-Life port uses (its docs/adr/0001 amendment).
#
# usage: scripts/build-arm64.sh
# post:  build/quakespasm-arm64 present, ad-hoc signed, arm64-only
#
# The arm64 slice is the ONLY one that links SDL2 rather than SDL 1.2.
# SDL 1.2 upstream never produced an arm64 build, so there is no SDL 1.2 to
# link (docs/adr/0003). Each slice of a fat Mach-O carries its own
# LC_LOAD_DYLIB, so this changes nothing for the other four.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/scripts/source-stamp.sh"
cd "$REPO_ROOT"

if [ "$(uname -m)" != "arm64" ]; then
  echo "[build-arm64] this box is $(uname -m), not arm64." >&2
  echo "[build-arm64] the arm64 slice must be built on an Apple Silicon Mac." >&2
  exit 1
fi

export QS_PORT_VERSION="${QS_PORT_VERSION:-$(git -C "$REPO_ROOT" describe --tags --always --dirty 2>/dev/null || echo unknown)}"

VMIN=11.0
# 11.0 rather than 10.x: there is no arm64 Mac that shipped earlier, so a
# lower deployment target would only be a fiction. It also keeps the SDL2
# framework's own minimum satisfied.

echo "[build-arm64] compile (vmin=$VMIN, SDL2, port version $QS_PORT_VERSION)"

cd Quake
make -f Makefile.darwin clean >/dev/null 2>&1 || true

# Arch flags go through CPUFLAGS, never CFLAGS. Makefile.darwin declares
# `CFLAGS ?= -Wall -MMD` and then appends to it (-DUSE_SDL2, the codec
# defines, the framework paths); a CFLAGS set on the make command line wins
# over those `+=` lines and silently drops every one of them. The first
# attempt at this build did exactly that and linked against the SDL 1.2 API.
make -f Makefile.darwin MACH_TYPE=arm64 -j"$(sysctl -n hw.ncpu)" \
  USE_SDL2=1 \
  CC=clang \
  QS_PORT_VERSION="$QS_PORT_VERSION" \
  CPUFLAGS="-arch arm64 -mmacosx-version-min=$VMIN -O2" \
  LDFLAGS="-arch arm64 -mmacosx-version-min=$VMIN" \
  SDL_FRAMEWORK_PATH=../MacOSX

install_name_tool -change \
  @executable_path/../Frameworks/SDL2.framework/Versions/A/SDL2 \
  @executable_path/SDL2.framework/Versions/A/SDL2 \
  quakespasm 2>/dev/null || true

cd "$REPO_ROOT"
mkdir -p build
mv Quake/quakespasm build/quakespasm-arm64

# Makefile.darwin runs `strip -S` as its last step, which invalidates any
# signature. arm64 is the one architecture where that is fatal rather than
# cosmetic: the kernel refuses to exec an unsigned or badly-signed arm64
# binary and the process dies on SIGKILL with no diagnostic. Re-sign ad-hoc
# AFTER the strip, and verify rather than trusting the exit code.
codesign --force --sign - build/quakespasm-arm64
codesign --verify --verbose=1 build/quakespasm-arm64

GOT=$(lipo -archs build/quakespasm-arm64)
[ "$GOT" = "arm64" ] || { echo "[build-arm64] expected arm64, got '$GOT'" >&2; exit 1; }

echo "[build-arm64] OK: build/quakespasm-arm64 ($GOT, signed)"
file build/quakespasm-arm64

# --- source stamp ------------------------------------------------------------
# This is the stamp that actually matters. arm64 is the only slice build-fat.sh
# never rebuilds, so it is the only one that can be older than the source the
# other five came from. That is issue #16.
#
# This driver compiles IN PLACE and rsyncs nothing, so there is no transferred
# file set to fingerprint. The stamp is therefore defined over the source tree,
# which is the same tree build.sh sends to the mini for the other five slices.
# A transfer-based stamp would have had no definition for the one slice the
# whole check exists for.
#
# Written last, after the codesign and lipo assertions, so a slice that failed
# either leaves no stamp.
STAMP_DIR="$REPO_ROOT/build/stamps/arm64"
mkdir -p "$STAMP_DIR"
source_stamp_write "$STAMP_DIR" "$(source_stamp_compute "$REPO_ROOT")"
echo "[build-arm64] source stamp $(source_stamp_read "$STAMP_DIR" | cut -c1-12) → build/stamps/arm64"
