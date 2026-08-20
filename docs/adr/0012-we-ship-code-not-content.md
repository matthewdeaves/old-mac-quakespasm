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

## Consequences

- The disk image is small and can be published without a licensing question.
- Every install has a manual step: the user must already own or download their
  own Quake data. The README says so.
- `LICENSE.txt` is upstream's GPL-2.0 text, unmodified. The credit chain belongs
  in the README as a fact, and stays there.
