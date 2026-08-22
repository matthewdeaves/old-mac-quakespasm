# 14. A slice is fused only if it was built from this source

Date: 2026-08-22
Status: accepted (implemented; six-slice end-to-end passed on the fleet)

## Context

`build-fat.sh` decided whether to include the arm64 slice by testing that the
file existed:

    if [ -x "build/quakespasm-arm64" ]; then

Five of the six slices cannot go stale. `build-fat.sh` rebuilds g3, g4, g5,
lion and i386 itself on every run, so they are always built during the run that
fuses them.

arm64 is different, and it is different for a reason that will not change.
Lion's Xcode 4.6 predates arm64 by seven years and cannot target it at all, so
the slice is built separately by `build-arm64.sh` on the Apple Silicon
orchestration Mac (ADR 0013). `build-fat.sh` picks up whatever file is on disk,
at whatever age.

Nothing downstream caught it. The post-fuse check reads `lipo -archs` and
confirms each architecture is named. A stale slice is present and correctly
named, so it passed. The script printed `arm64 slice present, it WILL be
included` on the way through, which is the line at which someone stops looking.

The same defect was found in all four ports on 2026-08-22. Quake II reproduced
it for real: a fat binary fused an arm64 slice three hours older than the
source the other five came from, and exited 0.

## Decision

Fingerprint the source a slice was built from, and refuse to fuse any slice
whose fingerprint does not match the tree being fused.

`scripts/source-stamp.sh` hashes the content of the source set and writes the
result to `build/stamps/<arch>/SOURCE-STAMP`. `build.sh` and `build-arm64.sh`
each write their slice's stamp after all their own assertions pass.
`build-fat.sh` recomputes the hash and compares all six.

The five mini-built slices are checked as well as arm64. A check that runs only
on the slice already under suspicion is worth little.

An absent arm64 slice is still allowed. That is a Rosetta 2 downgrade, not a
fault, and it was a deliberate choice in ADR 0013. Present but stale is a hard
failure.

## Why not the cheaper checks

**File exists.** The bug above.

**mtime, or any freshness comparison.** A stale object can carry a fresh
timestamp. That is how the sister Half-Life port shipped stale PowerPC slices
on 31 July 2026 with every check passing. This is the trap worth naming,
because "check the timestamps" is the obvious fix and it is the wrong one. The
original write-up on issue #16 proposed exactly that.

**Commit id.** Builds here rsync the working tree, not a commit, and an
uncommitted tree is the normal state during development.

**Commit id plus a dirty flag.** Records *that* the tree was dirty, not *which*
dirty tree.

## Consequences

**The stamp is defined over the source tree, not over the rsync transfer.**
`build-arm64.sh` compiles in place and rsyncs nothing, so there is no
transferred file set to fingerprint. A transfer-based stamp would have had no
definition for the one slice this whole decision exists for.

**One exclude list drives both the hash and the rsync.**
`source_stamp_rsync_excludes` emits the flags `build.sh` passes to rsync, from
the same list `source_stamp_compute` prunes. A file outside the set cannot
affect a build; a file inside it must move the hash. They cannot drift apart
because there is only one of them.

**`dist/` is excluded, and that is the one entry rsync did not already have.**
It is a build output directory living inside the source tree: release DMGs and
server tarballs, gitignored, 64 MB. Left in, an unchanged tree fingerprinted
differently depending on whether a release had been cut, so cutting a DMG would
have invalidated all six stamps and demanded an arm64 rebuild that could not
change a byte of the binary. A gate that fires on noise gets switched off,
which would hand back the original bug.

**A remote `quakespasm/dist/` no longer self-cleans.** `rsync --delete`
protects excluded paths on the receiver. The build mini stops receiving 64 MB
of DMGs it never reads, and any copy already there stays until someone removes
it. It is inert: the build host only ever runs `make` in `quakespasm/Quake`.

**Doc edits invalidate the arm64 stamp.** `docs/` and `analysis/` are in the
hashed set, so editing a doc between an arm64 build and a fuse forces an arm64
rebuild. Conservative, never a false pass, and deliberately left at parity with
Quake II's list rather than narrowed here. Narrowing it is a real option if the
cost is felt; it is not free, because every exclusion is a promise that the
excluded files cannot affect a binary.

**Stamps live inside `build/`, which the hash excludes**, so writing a stamp
cannot change the hash it records. They get a directory per architecture
because the slices are bare files and `source_stamp_write` takes a directory:
the primitive deliberately knows nothing about this port's layout, so
`old-mac-build-host#5` can replace it with a shared version without a merge.
Everything in `source-stamp.sh` below the exclude list is byte-identical to
Quake II's.

## Verification

A gate tested only on the direction it is meant to catch can refuse every real
build and still look proved. Quake II's first two cuts did exactly that. Both
directions were tested here, under the same `set -euo pipefail` `build-fat.sh`
runs:

| case | exit |
|---|---|
| good six-slice build | 0 |
| arm64 absent, five-slice build | 0 |
| arm64 present but stale | 1 |
| arm64 present, no stamp | 1 |
| a mini-built slice stale | 1 |

Then end-to-end on the fleet, which is the only result that counts: all six
slices stamped `4a40fb3948cb`, the tree hashing `4a40fb3948cb`, six slices in
the fat at their exact subtypes, and fresh mtimes on all seven binaries.

The hash is identical under `sh`, `bash` and `zsh`. That is not incidental: the
exclude list is read with `while IFS= read -r` because zsh does not word-split,
and `for e in $VAR` would collapse the list to one word, prune nothing, and
silently hash `build/`. `shasum -a 256` because `md5sum` is absent on the
10.7.5 minis and `md5 -q` is BSD-only. `LC_ALL=C` on the sort because the
workstation and the minis disagree on collation, which would make identical
trees hash differently for ever.
