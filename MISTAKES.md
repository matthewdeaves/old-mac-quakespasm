# Mistakes log — things we tried that were bad

Append-only record of changes that landed (or were attempted) and turned out
wrong, harmful or misjudged. Each entry exists so a future round does not
re-litigate settled ground on incomplete information. Newest first.

Where a mistake produced a standing decision, the mechanism and the evidence
live in the ADR named at the end of the entry and are not repeated here.

> **Naming note (2026-05-09).** Older entries and older CSV rows use `g3`, `g4`,
> `g4mini`, `lion`. Those are the same hardware as `yosemite`, `quicksilver`,
> `mini-g4`, `mini-intel`. `sawtooth` (G4 AGP tower) joined after the rename.

---

## 2026-08-20 — "this port uses SDL2" was wrong; every shipped slice is SDL 1.2

Commit `fd507839` asserted that QuakeSpasm "is on SDL2 and its bundled framework
was already fat with arm64 in it", and used that to argue this port was
structurally ahead of the Quake II and Quake III ports. `Makefile.darwin:13`
sets `USE_SDL2=0` and `otool -L build/quakespasm-fat` shows every slice linking
SDL at current version 12.4.0, i.e. SDL 1.2.15. The wrong idea came from
`MacOSX/SDL2.framework` genuinely being vendored and fat, plus upstream having a
live `USE_SDL2` path, plus the arm64 probe only linking with `USE_SDL2=1`.

**Lesson: check what the artifact links, not what the source tree contains.**
Same failure as the `-faltivec` entry below, in a different costume. ADR 0003.

## 2026-07-25 — `-faltivec` silently un-stamps the ppc7400 cpusubtype

Adding `-faltivec` (required by the 10.3.9 SDK's Carbon headers) produced a
slice stamped generic `ppc (ALL)` instead of `ppc7400`. Nothing in the build
complained; `lipo -info` was the only signal. A generic `ppc` slice is a launch
blocker on Tiger and Leopard, not a cosmetic flaw.

**Lesson: do not trust the compiler to stamp the subtype. Assert it. A build
that exits 0 and produces a runnable-looking binary can still be unlaunchable on
a machine you did not test.** ADR 0002.

## 2026-05-31 — the DMG pipeline could ship a silently-corrupt binary

Caught on the Quake II sister port, whose `make-dmg.sh` was adapted from ours: a
single flipped byte in the ppc7400 slice turned `stw r31` into an illegal
64-bit-only opcode and crashed every G4 at init. Only the DMG copy was corrupt;
`hdiutil verify` passed it.

**Lessons: `hdiutil verify` is a container checksum, not a content check — verify
the bytes inside the image against source, end to end, every build. Do not build
release artifacts on the flakiest hardware in the fleet. Test the artifact the
user actually runs, not the convenience path.** ADR 0005.

## 2026-05-31 — G3 Rage 128: a live in-game resolution SWITCH crashes the engine

A two-layer config where the overlay changed `vid_width` without a `vid_restart`
left the engine running at the baseline's resolution; the user corrected it via
the video menu, and that live fullscreen mode switch hard-crashed the driver.

**Lessons: an overlay that sets a resolution cvar without a `vid_restart` is a
silent no-op for the live mode and only shows up as a phantom in `config.cfg` —
put the authoritative boot resolution and its one restart in ONE place. On a GPU
that cannot survive a live mode switch, booting at the right resolution is not
enough: the video menu and alt-enter are loaded guns.** ADR 0006, ADR 0007.

## 2026-05-31 — iMac G5: GLSL/VBO on the ATI Radeon 9600 hard-hangs the whole OS

Two red herrings before the real cause: fullscreen was blamed, then SDL was
rebuilt for Leopard and it wedged anyway. The cause is the R300's Leopard GL 2.0
driver on the GLSL/VBO path.

**Lessons: a GPU that advertises GL2 on an old Mac driver is a trap — the first
GL-2.0-class GPU in a fleet exercises code paths nothing else did. Gate on the
renderer string, not the CPU or the slice. GL 1.x here is not a compromise.**
ADR 0007.

## 2026-05-29 — `vid_bpp 32` hard-wedged mini-g4 (Radeon 9200)

A code-review "cheap win" (32bpp for a real stencil buffer, so `r_shadows` gets
its self-intersection mask) wedged the whole OS during boot video-mode init on
the 9200 and did not on the 9000. Intermittent on retest, which is worse to ship
than a deterministic failure.

**Lessons: an autoexec-driven boot `vid_restart` is not free on old GPU drivers.
`deploy.sh` does not seed `config.cfg`, so a cvar the engine saved during a test
run persists on the target and silently changes the next launch. A modern bench
machine being offline means the headline visual win ships unverified — flag it
loudly in the cfg and the commit message.** ADR 0006, ADR 0007.

## 2026-05-10 — rounds v9 and v10: a "code regression" that was a config change

A whole-fleet demo3 regression was blamed on the Ironwail flat-array efrags
pattern, which was reverted; a v10 follow-up was then built to fix a regression
that did not exist. The real cause was `r_lavaalpha 0.6` in the autoexec.

**Lessons: check a bench delta against the autoexec diff before blaming code —
verify by re-running with `id1/autoexec.cfg` removed. "Same code, same machine,
same bench script" is not enough; the cvar set in effect is part of the bench.
Yosemite needs frequent reboots during long bench cycles.** ADR 0009.

*If revisited:* the flat-array efrags pattern measured **neutral** on the G3
under the confound (15.10 legacy vs 15.00 flat) and its true impact is unknown.
An `r_lavaalpha_distance` cvar mirroring `r_dynamic_distance` would let close-up
lava blend while far-field stays opaque, recovering the effect on the G3 without
the full-scene fillrate cost — about one round of work.

## 2026-05-09 — round v6: stale-binary CSV pollution read as a 30% regression

Wrap rows were benched against a binary that had been superseded mid-day. Bisect
showed the "72.20 baseline" was really 53.40, so the following round's "−30%"
was −5.8%. Twelve rows were deleted from `results.csv` and the baseline re-run.

**Lesson: after any mid-bench binary refresh, re-bench every affected machine
before the wrap commit — not just the most suspect ones. "Stale binary" is
invisible to the bench scripts.** ADR 0009.

*If revisited:* the mini-g4 demo3 1024 **+42%** / 640 **+46%** wins from round v7
phase 1 (sky hoist) on the Radeon 9200's ATI driver are that round's headline.
Confirm them in any future bisect.

## 2026-05-09 — round v5 B5: the scalar dlight cast hoist. REVERT WAS WRONG

Reverted on a reading that sat inside a 6%-wide historical noise cluster. A
proper same-session A/B showed **+2.9%** on mini-g4 demo3 1024, and B5 was
re-applied.

**Lesson, now load-bearing: never declare a regression without an
apples-to-apples same-session A/B on the suspected target.** ADR 0009. B5's
genuine G4-vs-G4 split, and why it was not simply dropped, is ADR 0008.

## 2026-05-09 — round v5 B3: Lion PGO and LTO, expected +5–12%, delivered nothing

Lion's clang is Apple clang 1.7 (LLVM 2.9): `-fprofile-instr-generate` is
silently accepted and emits no instrumentation; `-flto` works and measures +0.2
fps inside a 0.8 fps spread.

**Lesson: do not redo this on Lion's clang. Intel gains have to come from
source-level changes, not compiler flags.** ADR 0005.

## 2026-05-08 — Pass A item 5: BGRA static-texture upload (reverted)

**Tried.** Extend Phase 2.1's `GL_BGRA` + `GL_UNSIGNED_INT_8_8_8_8_REV` upload
format from per-frame lightmaps to all static textures (world brushes, alias
skins, particle/sky/HUD pics) in `TexMgr_LoadImage32`, as an **in-place**
RGBA→BGRA byte swap on the source buffer plus a format-constant change at the
`glTexImage2D` call. Predicted as a load-time-only win with zero per-frame fps
effect; risk tagged medium; toggleable behind `-nobgra-static`.

**What went wrong.** Reproducibly crashed **all four bench targets** during map
load — G3 Panther / Rage 128, G4 Quicksilver / Radeon 9000 / Tiger, G4 mini /
Radeon 9200 / Tiger, Lion x86_64 / GMA 950 — with an identical signature:

```
EXC_BAD_ACCESS / SIGSEGV  in COM_FindFile + ~256
  ← Image_LoadImage (recursing through extensions)
  ← Mod_LoadTextures (replacement-image lookup)
  ← Mod_LoadBrushModel ← Mod_LoadModel ← CL_ParseServerInfo
```

The faulting register held an address in the high stack region (e.g.
`0x3f9f08b4`, `0xff3808b4`, from r30/rsi pointing into trashed strings): the
in-place swap corrupted hunk-allocated filename memory adjacent to the texture
buffer, and the engine dereferenced garbage looking for the next replacement
texture's filename.

**Misdiagnosis on the way.** The first fix (`cea45842`) gated the path on
`host_bigendian`, assuming only PowerPC was affected because the engine disables
`EXT_packed_pixels` on big-endian (`gl_vidsdl.c:1424`, upstream
sezero/quakespasm#114). Lion crashed too. The endianness gate was a partial mask
of a deeper bug.

**Why the lightmap path works and this did not.** `R_BuildLightMap` writes bytes
directly in `[B][G][R][A]` order — the data is *born* in BGRA layout and the
upload format consumes it correctly. The static path took an existing RGBA
buffer, swapped in place, then handed it to the same upload format; somewhere
between the swap, the optional resample / mipmap-down / alpha-edge-fix steps and
the upload, it wrote past its allocation. **The exact mechanism was never
found** — the byte-count math and buffer-size invariants all looked correct on
inspection.

**Fix.** Reverted to `GL_RGBA` + `GL_UNSIGNED_BYTE` unconditionally. There is no
per-frame hot loop attached, so the revert costs nothing measurable. The
`bgra_static_disabled` flag and `-nobgra-static` cmdline stay in tree as inert
plumbing.

**Lessons.**
1. **Smoke-bench every target before committing, even for a change tagged
   "load-time only, zero fps move".** This shipped through a smoke that passed
   on all three machines then in the matrix (`b186ae44`, Lion 95.7 fps demo1
   1024 with BGRA enabled). **demo1 alone is not enough exposure** — include a
   map transition.
2. **In-place buffer mutation is a footgun on shared hunk allocations.** The
   replacement-image lookups happen before `TexMgr_LoadImage32` returns, so
   corrupted state persists in any buffer still reachable. If revisited,
   allocate a fresh BGRA buffer and copy into it.
3. **"Apple's documented fast path" is not a green light.** The combo is
   genuinely faster when the data layout matches, but "matches" needs to be
   proven, not inherited from a different data origin.
4. **Endian-only gating is suspicious as a fix.** The same crash on Lion should
   have been a stronger signal that endianness was not the issue.
5. **Lion is a load-bearing third bench leg.** Without Intel in the matrix the
   bug would have looked PowerPC-specific and the wrong fix could have shipped.

**Cost.** Three engine crashes on the G3 (one needing a hard reboot), one each
on Quicksilver, mini-g4 and Lion; about 90 minutes before reverting. Commits:
`b186ae44` (original), `cea45842` (partial endian gate), then the full revert.

## Phase 1.1c — multitexture client-array conversion (reverted, `c00a07a7` era)

Converting `R_DrawTextureChains_Multitexture` to client vertex arrays cost the
G4 **−3 to −4%** on brush-heavy demos and was neutral on the G3, whose Rage 128
driver has no fast path for client arrays. Apple's Radeon 9000 driver has a
`glBegin` fast path that beats `glDrawArrays` **against client memory**. It was
restored later, gated on `gl_apple_var_able` so it only runs when the verts are
already in driver-cached VAR memory (Phase 3.3, `fdd1b09a`): G4 640 141.75 →
151.00 (+6.5% vs 3.2), G4 1024 121.20 → 119.85 (−1.1%, still under the 2.3 peak
of 123.35) — 1024 is fillrate-bound, 640 is vert-submission-bound. CVA `Lock`
stayed gated off on the R128 for in-game colour corruption (`-r128-cva` is the
retest hatch).

**Lesson: on these drivers, moving world geometry off immediate mode is
neutral-to-negative unless the verts land in driver-owned memory.** The same
wall was hit again by `gl_surfbatch` (2026-05-31: **−4.8%** on G3 demo2 640,
**−4.2%** on Lion demo1 640, neutral on G4 and G5, no machine winning) and by
the Q2 sister port's `gl_groupdraw` (−3% on R128). Both are kept default-off and
correct; full tables in `docs/KNOBS.md`. **Do not re-chase this without a new
mechanism.**
