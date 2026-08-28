# 12. We ship code, not content

Date: 2026-08-20
Status: accepted

## Context

Quake's game data is id Software's. The engine source is GPL-2.0-or-later, and
this port inherits that verbatim through the chain id Software (1996–2001) →
John Fitzgibbons / FitzQuake → the QuakeSpasm developers
(`sezero/quakespasm`). Bundled SDL 1.2.15 is zlib-licensed.

## Decision

**No Valve-, id- or third-party game assets are ever committed or shipped.**

- The release disk image contains `Quakespasm.app`, `quakespasm.pak` (upstream
  QuakeSpasm's own engine pak, which is part of the GPL source tree) and a
  user-facing `README.txt`. Nothing else.
- The user supplies `id1/pak0.pak` (shareware) or `pak0.pak` plus `pak1.pak`
  (registered, from Steam or GOG) and drops it beside the app.
- The Linux dedicated server ships with no game data at all; the operator
  supplies their own `id1/pak0.pak` and `pak1.pak` (ADR 0011).
- **Assets the port adds are generated at runtime, not shipped.** The weapon
  damage decals generate their textures procedurally at startup, the same way
  the particle textures do; nothing lands in `id1/`.

## Consequences (amended 2026-08-28, issue #36)

This decision governs what is **committed or shipped**, not what a developer
or bench machine may hold locally for testing. A local copy of the user's
own legally-owned game data, kept outside the repo (never `git add`ed), is
already how arm64 bench testing works today: `scripts/bench-arm64-local.sh`
reads `id1/pak0.pak` from `QS_ARM64_BENCH_DIR`, an out-of-repo path the user
chooses (75d0c581). That was always compliant with this ADR as written —
"ever committed or shipped" never applied to a workstation's own local test
copy — and the arm64 orchestration workstation being usable as a full
bench-lock host (`workstation` alias, old-mac-build-host#32) changes nothing
here: it is provisioned the same way, a local path outside the repo, and
this file needed no actual rule change, only this note making that explicit
so the next session doesn't have to re-derive it. `imac-2019` and any other
bench machine follow the identical rule.

## Consequences

- The disk image is small and can be published without a licensing question.
- Every install has a manual step: the user must already own or download their
  own Quake data. The README says so.
- `LICENSE.txt` is upstream's GPL-2.0 text, unmodified. The credit chain belongs
  in the README as a fact, and stays there.
