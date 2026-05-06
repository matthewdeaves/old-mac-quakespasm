#!/usr/bin/env bash
# Cross-build a QuakeSpasm PPC binary on the Lion build host.
#
# usage: scripts/build.sh <g3|g4>
# output: build/quakespasm-<target>
# env:    LION (ssh alias for the build host, default 'lion')

set -euo pipefail

TARGET="${1:?usage: $0 <g3|g4>}"
LION="${LION:-lion}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "$TARGET" in
  g3)
    SDK=/Developer/SDKs/MacOSX10.3.9.sdk
    VMIN=10.3
    CPUFLAGS='-mcpu=750 -O3'
    ;;
  g4)
    SDK=/Developer/SDKs/MacOSX10.4u.sdk
    VMIN=10.4
    CPUFLAGS='-mcpu=7400 -maltivec -mabi=altivec -O3 -mtune=7450'
    ;;
  *)
    echo "unknown target: $TARGET (expected: g3|g4)" >&2
    exit 2
    ;;
esac

SYSROOT="-isysroot $SDK -mmacosx-version-min=$VMIN -arch ppc"

echo "[build] sync sources Ubuntu → $LION"
# exclude prereqs/ (5 GB of installer DMGs; only used locally for setup)
# and benchmarks/raw/ + build/ (output dirs that shouldn't bounce through Lion)
rsync -av --partial --inplace --delete \
  --exclude='.git' --exclude='*.o' --exclude='*.d' \
  --exclude='build/' --exclude='benchmarks/' --exclude='prereqs/' \
  --exclude='quakespasm' --exclude='quakespasm-g3' --exclude='quakespasm-g4' \
  -e 'ssh -o ServerAliveInterval=15' \
  "$REPO_ROOT/" "$LION:quakespasm/" | tail -3

echo "[build] compile $TARGET on $LION (SDK=$SDK, vmin=$VMIN)"
ssh "$LION" "cd quakespasm/Quake && \
  make -f Makefile.darwin clean >/dev/null 2>&1
  make -f Makefile.darwin MACH_TYPE=ppc -j2 \
    CC=/usr/bin/gcc-4.0 \
    CPUFLAGS=\"$SYSROOT $CPUFLAGS\" \
    LDFLAGS=\"$SYSROOT\" \
    > /tmp/qs-build-$TARGET.log 2>&1
  RC=\$?
  if [ \$RC -ne 0 ]; then tail -30 /tmp/qs-build-$TARGET.log; exit \$RC; fi
  install_name_tool -change \
    @executable_path/../Frameworks/SDL.framework/Versions/A/SDL \
    @executable_path/SDL.framework/Versions/A/SDL \
    quakespasm
  mv quakespasm quakespasm-$TARGET"

mkdir -p "$REPO_ROOT/build"
echo "[build] fetch → build/quakespasm-$TARGET"
scp -q "$LION:quakespasm/Quake/quakespasm-$TARGET" "$REPO_ROOT/build/quakespasm-$TARGET"
file "$REPO_ROOT/build/quakespasm-$TARGET"
