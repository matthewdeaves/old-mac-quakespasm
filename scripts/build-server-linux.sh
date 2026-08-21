#!/usr/bin/env bash
# Build the Linux dedicated-server release from the same source tree the Mac
# fat binary is built from.
#
# This is a SEPARATE release from the fat Mac app. It ships one ELF binary for
# one Linux architecture, and it is built in a container so the result does not
# depend on whatever happens to be installed on the machine that ran it.
#
# usage: scripts/build-server-linux.sh [--arch x86_64|aarch64] [--version V]
# output: dist/server/quakespasm-server-<version>-linux-<arch>.tar.gz
#
# Requires Docker (or Colima). Nothing else: no local compiler is used, and the
# host architecture does not matter.
#
# WHY A DEDICATED BINARY AT ALL
#
# QuakeSpasm has no separate server executable; the one binary takes
# `-dedicated N`. What it does have is a hard split at runtime: Host_Init wraps
# VID_Init, R_Init, TexMgr_Init and the rest of the client in
# `if (cls.state != ca_dedicated)` (Quake/host.c). So in dedicated mode not one
# OpenGL entry point is reached, but every one of them is still LINKED, because
# the renderer objects are in the link line either way.
#
# Linking real libGL to satisfy them would put Mesa, and behind it the whole
# X11 chain, on a headless server for symbols that are never called. Instead
# this script harvests the undefined GL symbols from a first link pass and
# generates a stub for exactly that set, each one aborting with its own name.
# If the guard above ever stops holding, the server says which entry point it
# reached rather than failing quietly.
#
# SDL2 gets the same treatment. QuakeSpasm needs SDL for SDL_Init(0), SDL_Delay
# and SDL_GetVersion, which is nearly nothing, but Debian's shared libSDL2
# drags in X11, Wayland, PulseAudio, krb5 and the audio codecs: 61 shared
# libraries for a program that opens no window. So SDL is built here from
# pinned source with every backend disabled and linked statically, which leaves
# the API complete and the dependencies at zero.
#
# The result depends on libc, libm, libdl and libpthread. Nothing else. It runs
# on a plain Ubuntu server with no packages installed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ARCH="x86_64"
VERSION=""

while [ $# -gt 0 ]; do
	case "$1" in
		--arch)    ARCH="${2:?--arch needs a value}"; shift 2 ;;
		--version) VERSION="${2:?--version needs a value}"; shift 2 ;;
		-h|--help) sed -n '2,20p' "$0"; exit 0 ;;
		*) echo "$0: unknown argument: $1" >&2; exit 2 ;;
	esac
done

case "$ARCH" in
	x86_64)  DOCKER_PLATFORM="linux/amd64" ;;
	aarch64) DOCKER_PLATFORM="linux/arm64" ;;
	*) echo "$0: unsupported arch: $ARCH (expected x86_64 or aarch64)" >&2; exit 2 ;;
esac

# Version: an explicit --version wins, otherwise describe against the tags so a
# build off a non-tagged commit is visibly not a release.
if [ -z "$VERSION" ]; then
	VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo unknown)"
fi

GIT_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
GIT_DIRTY=""
git diff --quiet 2>/dev/null || GIT_DIRTY=" (working tree modified)"
BUILD_DATE="$(date -u '+%Y-%m-%d %H:%M UTC')"

IMAGE="oldmac-quakespasm-server-build:deb11"
OUT_DIR="$REPO_ROOT/dist/server"
WORK="$REPO_ROOT/build/server-linux-$ARCH"

# SDL2, pinned. Verified by sha256 below: this is fetched over the network and
# compiled, so an unverified download would be an unpinned dependency in a
# release artifact.
SDL2_VER="2.28.5"
SDL2_SHA256="332cb37d0be20cb9541739c61f79bae5a477427d79ae85e352089afdaf6666e4"
SDL2_URL="https://github.com/libsdl-org/SDL/releases/download/release-${SDL2_VER}/SDL2-${SDL2_VER}.tar.gz"

echo "[server] quakespasm dedicated server"
echo "[server]   arch     : $ARCH ($DOCKER_PLATFORM)"
echo "[server]   version  : $VERSION"
echo "[server]   commit   : $GIT_COMMIT$GIT_DIRTY"

command -v docker >/dev/null 2>&1 || {
	echo "$0: docker not found. Start Colima or Docker Desktop first." >&2
	exit 1
}
docker info >/dev/null 2>&1 || {
	echo "$0: the Docker daemon is not responding. Try: colima start" >&2
	exit 1
}

mkdir -p "$WORK" "$OUT_DIR"

echo "[server] building container image"
docker build --platform "$DOCKER_PLATFORM" \
	-t "$IMAGE" -f scripts/docker/server-build.Dockerfile scripts/docker >/dev/null

# Stage the source. Building in a copy keeps object files out of the working
# tree, which matters here because the Mac builds compile the same directory.
echo "[server] staging source"
rm -rf "$WORK/src"
mkdir -p "$WORK/src"
# --exclude the object and dependency files. A local macOS build leaves 174 of
# them in Quake/, and the .d files carry absolute-ish dependency lines pointing
# at the Mac SDL framework. Staged into the container, make reads them and stops
# with
#   No rule to make target '../MacOSX/SDL2.framework/Headers/SDL.h',
#   needed by 'gl_refrag.o'
# which looks like a missing dependency in the container rather than what it is:
# a Mac build leaking into a Linux one. Same class of bug as the Quake II driver
# staging yquake2/release/. These are build output, never inputs.
tar cf - --exclude='*.o' --exclude='*.d' Quake | tar xf - -C "$WORK/src"

cat > "$WORK/build-in-container.sh" <<CONTAINER_SCRIPT
#!/bin/sh
# Runs INSIDE the build container. Fails the whole build on any error.
set -e

WORK=/work
SDL_PREFIX=\$WORK/sdl2-static

# ---------------------------------------------------------------- SDL2 (static)
if [ ! -f "\$SDL_PREFIX/lib/libSDL2.a" ]; then
	cd \$WORK
	if [ ! -f "SDL2-${SDL2_VER}.tar.gz" ]; then
		echo "[container] fetching SDL2 ${SDL2_VER}"
		curl -fsSL -o "SDL2-${SDL2_VER}.tar.gz" "${SDL2_URL}"
	fi
	echo "${SDL2_SHA256}  SDL2-${SDL2_VER}.tar.gz" | sha256sum -c - || {
		echo "[container] SDL2 tarball failed its checksum" >&2
		exit 1
	}
	rm -rf "SDL2-${SDL2_VER}"
	tar xzf "SDL2-${SDL2_VER}.tar.gz"
	cd "SDL2-${SDL2_VER}"
	# Every API stays present so the QuakeSpasm objects link; every BACKEND is
	# turned off so nothing outside libc is pulled in. The dummy video driver
	# is what keeps the SDL_video symbols defined without X11 or Wayland.
	./configure --prefix="\$SDL_PREFIX" \\
		--disable-shared --enable-static \\
		--enable-video --enable-video-dummy \\
		--disable-video-x11 --disable-video-wayland --disable-video-kmsdrm \\
		--disable-video-vulkan --disable-video-opengles \\
		--disable-alsa --disable-pulseaudio --disable-sndio \\
		--disable-jack --disable-pipewire --disable-oss \\
		--disable-libudev --disable-dbus --disable-ime --disable-ibus \\
		--disable-fcitx --disable-libsamplerate \\
		> \$WORK/sdl2-configure.log 2>&1
	make -j"\$(nproc)" > \$WORK/sdl2-make.log 2>&1
	make install > \$WORK/sdl2-install.log 2>&1
	echo "[container] static SDL2 built"
fi

cd \$WORK/src/Quake

# Hardening.
#
# This binary parses UDP datagrams from strangers, in C written in 1996, and
# is meant to sit on the internet permanently. Debian's gcc gives PIE and NX by
# default and nothing else, so a plain build ships with no stack canaries, no
# FORTIFY_SOURCE and only partial RELRO. These flags are the difference between
# a memory-safety bug being a crash and being a shell.
#
# Routed through EXTRA_CFLAGS/EXTRA_LDFLAGS rather than CFLAGS=, because a
# command-line CFLAGS assignment defeats every conditional `CFLAGS +=` in the
# Makefile above it. The Makefile says so itself.
#
# Exported rather than put on the make command line: MAKE_ARGS is expanded
# unquoted, so a multi-word value there word-splits and make reads the tail of
# it as its own options. make imports the environment for variables it does not
# set itself, so this reaches \$(EXTRA_CFLAGS) intact.
HARDEN_CFLAGS="-fstack-protector-strong -D_FORTIFY_SOURCE=2 -fPIE"
HARDEN_LDFLAGS="-Wl,-z,relro,-z,now -Wl,-z,noexecstack -pie"
export EXTRA_CFLAGS="\$HARDEN_CFLAGS"
export EXTRA_LDFLAGS="\$HARDEN_LDFLAGS"

# The codecs are for background music, which a dedicated server does not play.
# Turning them off removes libvorbis, libmad and their chains from the build.
MAKE_ARGS="USE_SDL2=1 USE_CODEC_VORBIS=0 USE_CODEC_MP3=0 USE_CODEC_WAVE=0 \\
           USE_CODEC_FLAC=0 USE_CODEC_OPUS=0 \\
           SDL_CONFIG=\$SDL_PREFIX/bin/sdl2-config"

# ------------------------------------------------------- pass 1: harvest GL syms
# Deliberately expected to fail at the link step. Everything before the link is
# the real compile, and those objects are reused by pass 2, so this costs one
# link, not one build.
echo "[container] pass 1: collecting undefined GL symbols"
set +e
make \$MAKE_ARGS COMMON_LIBS="-lm" -j"\$(nproc)" > \$WORK/pass1.log 2>&1
set -e

grep -oE "undefined reference to \\\`[a-zA-Z0-9_]+" \$WORK/pass1.log \\
	| sed "s/.*\\\`//" | sort -u > \$WORK/gl-undef.txt || true

# Anything undefined that is NOT a GL entry point is a real build error wearing
# the same shape, so refuse rather than stub it out.
if grep -vE '^(gl|GL)' \$WORK/gl-undef.txt > \$WORK/gl-unexpected.txt 2>/dev/null; then
	if [ -s \$WORK/gl-unexpected.txt ]; then
		echo "[container] undefined non-GL symbols, refusing to stub them:" >&2
		cat \$WORK/gl-unexpected.txt >&2
		exit 1
	fi
fi

SYM_COUNT=\$(wc -l < \$WORK/gl-undef.txt)
if [ "\$SYM_COUNT" -eq 0 ]; then
	# Either the build already succeeded (a real libGL got linked, which would
	# reintroduce the Mesa dependency) or it failed for some other reason.
	if [ -x quakespasm ]; then
		echo "[container] pass 1 linked against a real libGL; that defeats the point" >&2
		exit 1
	fi
	echo "[container] pass 1 failed before the link stage:" >&2
	tail -30 \$WORK/pass1.log >&2
	exit 1
fi
echo "[container] \$SYM_COUNT GL entry points to stub"

# ------------------------------------------------------------ generate the stub
{
	cat <<'STUB_HEADER'
/*
 * gl_stub.c - GENERATED by scripts/build-server-linux.sh. Do not edit.
 *
 * The dedicated server links the renderer objects but never reaches them:
 * Host_Init guards VID_Init, R_Init and TexMgr_Init behind a
 * cls.state != ca_dedicated test (host.c). These stubs satisfy the linker
 * without putting Mesa and X11 on a headless box.
 *
 * Each one aborts naming itself, so if that guard ever stops holding the
 * server reports which entry point it reached instead of misbehaving quietly.
 */
#include <stdio.h>
#include <stdlib.h>

static void gl_stub_die (const char *name)
{
	fprintf (stderr,
	         "\nfatal: %s was called in a dedicated-server build.\n"
	         "This binary carries no OpenGL. Use the Mac client build instead.\n",
	         name);
	abort ();
}

#define GL_STUB(n) void n (void) { gl_stub_die (#n); }

STUB_HEADER
	while read -r sym; do
		[ -n "\$sym" ] && echo "GL_STUB(\$sym)"
	done < \$WORK/gl-undef.txt
} > gl_stub.c

gcc -O2 \$HARDEN_CFLAGS -c gl_stub.c -o gl_stub.o

# ------------------------------------------------------------ pass 2: real link
echo "[container] pass 2: linking"
make \$MAKE_ARGS COMMON_LIBS="-lm \$PWD/gl_stub.o" -j"\$(nproc)" > \$WORK/pass2.log 2>&1
MAKE_RC=\$?
if [ "\$MAKE_RC" -ne 0 ] || [ ! -x quakespasm ]; then
	echo "[container] link failed:" >&2
	tail -40 \$WORK/pass2.log >&2
	exit 1
fi

strip quakespasm
cp quakespasm \$WORK/quakespasm-server

# ------------------------------------------------------------------ verify it
echo "[container] verifying"
file \$WORK/quakespasm-server

# Assert the hardening actually landed. Flags can be silently dropped by a
# Makefile that stomps the variable carrying them, and the result looks exactly
# like a normal build, so this is checked rather than assumed.
readelf -sW \$WORK/quakespasm-server | grep -q "__stack_chk_fail" || {
	echo "[container] no stack canaries in the binary" >&2; exit 1; }
readelf -dW \$WORK/quakespasm-server | grep -q "BIND_NOW" || {
	echo "[container] RELRO is not full (no BIND_NOW)" >&2; exit 1; }
readelf -lW \$WORK/quakespasm-server | grep -q "GNU_STACK.*RWE" && {
	echo "[container] stack is executable" >&2; exit 1; }
echo "[container] hardening: canaries yes, full RELRO, NX, PIE"

# Every shared library this binary needs must be part of glibc. Anything else
# is a package the operator would have to install, which is exactly what this
# build exists to avoid.
ldd \$WORK/quakespasm-server > \$WORK/ldd.txt 2>&1 || true
if grep -qE '=> */' \$WORK/ldd.txt; then
	BAD=\$(awk '{print \$1}' \$WORK/ldd.txt \\
		| sed 's|.*/||' \\
		| grep -E '\\.so' \\
		| grep -vE '^(linux-vdso|libc|libm|libdl|libpthread|librt|ld-linux.*)\\.so' || true)
	if [ -n "\$BAD" ]; then
		echo "[container] binary depends on libraries outside glibc:" >&2
		echo "\$BAD" >&2
		cat \$WORK/ldd.txt >&2
		exit 1
	fi
fi

# It must actually start. With no game data it stops at the missing-wad error,
# and reaching THAT proves Host_Init ran without touching a GL stub.
cd \$WORK
mkdir -p probe && cd probe
set +e
OUT=\$(\$WORK/quakespasm-server -dedicated 2 -basedir \$WORK/probe 2>&1)
set -e
echo "\$OUT" | grep -q "Host_Init" || {
	echo "[container] the binary did not reach Host_Init:" >&2
	echo "\$OUT" >&2
	exit 1
}
echo "\$OUT" | grep -q "dedicated-server build" && {
	echo "[container] a GL stub was reached during startup" >&2
	exit 1
}
echo "[container] startup probe reached Host_Init cleanly"
CONTAINER_SCRIPT
chmod +x "$WORK/build-in-container.sh"

echo "[server] compiling in container"
docker run --rm --platform "$DOCKER_PLATFORM" \
	-v "$WORK:/work" -w /work \
	"$IMAGE" /work/build-in-container.sh

BIN="$WORK/quakespasm-server"
[ -x "$BIN" ] || { echo "$0: no binary was produced" >&2; exit 1; }

# ---------------------------------------------------------------------- package
STAGE="$WORK/pkg/quakespasm-server-$VERSION-linux-$ARCH"
rm -rf "$WORK/pkg"
mkdir -p "$STAGE/systemd"

cp "$BIN" "$STAGE/quakespasm-server"
cp "$REPO_ROOT/server/server.cfg"                    "$STAGE/server.cfg"
cp "$REPO_ROOT/server/README.md"                     "$STAGE/README.md"
cp "$REPO_ROOT/server/quakespasm-server.service"     "$STAGE/systemd/"
cp "$REPO_ROOT/LICENSE.txt"                          "$STAGE/LICENSE.txt" 2>/dev/null || true

SDL_LINE="SDL2 $SDL2_VER, static, all backends disabled"
cat > "$STAGE/BUILD-INFO.txt" <<EOF
QuakeSpasm dedicated server (old-mac-quakespasm)
================================================
Version      : $VERSION
Built from   : git $GIT_COMMIT$GIT_DIRTY
Built on     : $BUILD_DATE
Target       : linux-$ARCH
Built against: Debian 11, glibc 2.31
Bundled      : $SDL_LINE

Runs on any Linux with glibc 2.31 or newer (Ubuntu 20.04 and up). It needs no
packages installed: the only shared libraries it loads are part of glibc.

This is the same source tree as the Mac fat binary release. The server carries
no OpenGL, so it cannot be used as a client.

Project: https://github.com/matthewdeaves/old-mac-quakespasm
EOF

TARBALL="$OUT_DIR/quakespasm-server-$VERSION-linux-$ARCH.tar.gz"
rm -f "$TARBALL"
tar czf "$TARBALL" -C "$WORK/pkg" "$(basename "$STAGE")"

echo "[server] verifying the tarball"
tar tzf "$TARBALL" >/dev/null || { echo "$0: tarball is unreadable" >&2; exit 1; }

echo
echo "[server] done"
echo "[server]   $TARBALL"
echo "[server]   $(du -h "$TARBALL" | cut -f1)  sha256 $(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
echo
echo "[server] contents:"
tar tzf "$TARBALL" | sed 's/^/[server]   /'
