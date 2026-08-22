#!/bin/sh
# Source fingerprint: what a build was actually built FROM.
#
# Why this exists: build-fat.sh decided whether to include the arm64 slice by
# checking the file EXISTED (`[ -x build/quakespasm-arm64 ]`). arm64 is the one
# slice no build mini can produce -- Lion's Xcode 4.6 predates it by seven years
# -- so it is built separately by scripts/build-arm64.sh and carried over, and
# it is therefore the only slice a fat build never rebuilds. The other five are
# rebuilt by build-fat.sh on every run and cannot go stale. See issue #16.
#
# The same bug was found in all four ports on 2026-08-22. Quake II reproduced it
# for real (old-mac-quake2#17): a fat binary fused an arm64 slice three hours
# older than the source the other five came from, printed a success line, and
# exited 0. This file is a port of the implementation they landed in ea922696,
# deliberately kept close to theirs so a shared primitive can replace it.
#
# Four cheaper checks were ruled out before this one:
#   - file exists          the original bug
#   - mtime / freshness    a stale object can carry a FRESH timestamp; that is
#                          how the sister Half-Life port shipped stale PowerPC
#                          slices on 31 July 2026 with every check passing
#   - commit id            builds here rsync the WORKING TREE (build.sh), not a
#                          commit, and uncommitted trees are the normal state
#   - commit id + dirty    records THAT the tree was dirty, not WHICH dirty tree
#
# So: hash the content of the source that goes IN to the build.
#
# This file deliberately knows nothing about products, slices or paths. It takes
# a directory and returns or records a hash. old-mac-build-host is expected to
# factor this out as the shared primitive across the four ports, so keep it that
# way: no product names, no build/ layout, no per-port logic.

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

# Emit the --exclude= flags for rsync, from the same list the hash uses.
source_stamp_rsync_excludes () {
	printf '%s\n' "$SOURCE_STAMP_EXCLUDES" | while IFS= read -r e; do
		[ -n "$e" ] && printf -- '--exclude=%s ' "$e"
	done
}

# source_stamp_compute <dir>  ->  64 hex chars on stdout
#
# shasum -a 256, not md5: `md5 -q` is BSD-only and `md5sum` is Linux-only and
# ABSENT on the 10.7.5 build minis (measured on mini-intel2), so no md5 spelling
# works fleet-wide. shasum is on Lion, on the workstation and on Linux, and
# build-host's sync-build-lock.sh already uses it.
#
# LC_ALL=C on the sort: collation is locale-dependent and the workstation and
# the minis disagree, which would make identical trees hash differently and
# report drift for ever. A gate that fires on noise gets switched off.
#
# Hashes names AND contents, so a rename changes the result.
#
# set -f around the exclude loop: the list holds globs like *.o, and an
# unquoted expansion would let the shell match them against the cwd instead of
# passing them to find. The prune arguments are built with set -- so each
# pattern reaches find as one quoted word.
source_stamp_compute () {
	( cd "$1" 2>/dev/null || exit 1
	  # set -f: the list holds globs like *.o and nothing here should let the
	  # shell match them against the cwd. Prune args are built with set -- so
	  # each pattern reaches find as one word.
	  set -f
	  set --
	  _first=1
	  while IFS= read -r _e; do
	  	[ -n "$_e" ] || continue
	  	case "$_e" in
	  		*/) _p="./${_e%/}" ; _t="-path" ;;
	  		*)  _p="$_e"       ; _t="-name" ;;
	  	esac
	  	if [ "$_first" = 1 ]; then set -- "$_t" "$_p"; _first=0
	  	else set -- "$@" -o "$_t" "$_p"; fi
	  done <<EOF
$SOURCE_STAMP_EXCLUDES
EOF
	  set +f
	  # One shasum per file spawns a process per file (785 here) and made this
	  # take minutes. Batch through xargs instead: sort FIRST so the order is
	  # deterministic, then let xargs preserve it. tr to NUL rather than
	  # `sort -z`, which Lion's sort does not have. Filenames containing a
	  # newline would break this; none exist in the hashed set and the build
	  # would not survive them either.
	  find . \( "$@" \) -prune -o -type f -print \
	  | LC_ALL=C sort \
	  | tr '\n' '\0' \
	  | xargs -0 shasum -a 256 \
	  | shasum -a 256 | cut -d' ' -f1 )
}

# source_stamp_write <dir> <hash>
# Writes <dir>/SOURCE-STAMP. cut -d' ' is applied at every shasum call site
# because shasum prints "<hash>  <name>", and prints a bare "-" for stdin; a
# stamp file with a dash in it is the easy mistake here.
source_stamp_write () {
	printf '%s\n' "$2" > "$1/SOURCE-STAMP"
}

# source_stamp_read <dir>  ->  hash, or empty if absent
source_stamp_read () {
	[ -f "$1/SOURCE-STAMP" ] || return 0
	head -n1 "$1/SOURCE-STAMP" | tr -d '[:space:]'
}
