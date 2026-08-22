#!/bin/sh
# The exclude list: what this repo does NOT count as source.
#
# Separate from source-stamp.sh on purpose. old-mac-build-host ships a canonical
# source-stamp.sh into every port (build-host#5) and that sync OVERWRITES the
# file wholesale. The canonical carries the shared machinery and no exclude list
# of its own -- the list is per-port, so it has to live somewhere the sync does
# not touch. That is this file.
#
# Sourced by build.sh, build-fat.sh and build-arm64.sh, which pass
# "$SOURCE_STAMP_EXCLUDES" to source_stamp_compute and
# source_stamp_rsync_excludes explicitly. Nothing reads it as a global.

# dist/ is a BUILD OUTPUT directory that lives inside the source tree: it holds
# the release DMGs make-dmg.sh writes and the tarballs build-server-linux.sh
# writes. Gitignored, tracked by nothing, and 64 MB of it. Left in the hashed
# set it means an unchanged source tree hashes differently depending on whether
# a release has been cut, so cutting a DMG would invalidate every slice stamp
# and demand an arm64 rebuild that cannot change a single byte of the binary. A
# gate that fires on noise gets switched off. Measured: touching one file in
# dist/ moved the hash from 1e5aea07554c to 5e892fcb0db0.
#
# It is the ONE entry here that rsync did not already exclude, so it is also the
# one place the shared list changes build.sh's transfer. Two consequences, both
# checked: the mini stops receiving 64 MB of DMGs it never reads, and because
# `rsync --delete` PROTECTS excluded paths on the receiver, an existing remote
# quakespasm/dist/ is now left in place rather than deleted. Nothing on the
# build host reads it -- the remote only ever runs make in quakespasm/Quake --
# so it is inert, but it does not self-clean.
#
# The one definition of "what a build is built from". build.sh's rsync reads
# this too (source_stamp_rsync_excludes), so the two cannot drift apart. A file
# outside this set cannot affect a build; a file inside it must change the hash.
# Newline-separated, NOT space-separated. Reading it with `for e in $VAR`
# would depend on word-splitting, which sh and bash do and zsh does NOT: sourced
# from a zsh shell the whole list collapses to one word, nothing is pruned, and
# the hash silently covers build/ and fires on every bench run. Read it with
# `while IFS= read -r` instead, which behaves identically in all three.
SOURCE_STAMP_EXCLUDES='.git
*.o
*.d
build/
benchmarks/
prereqs/
dist/
quakespasm
quakespasm-g3
quakespasm-g4
quakespasm-g5
quakespasm-lion
quakespasm-i386
quakespasm-arm64'
