# 8. Every per-target knob is toggleable, and a split result is gated, not dropped

Date: 2026-08-20
Status: accepted

## Context

The goal is the best-looking Quake that stays playable on each machine: **≥ 20
fps on the G3, ≥ 60 fps on the G4s, G5 and Lion**, uncapped on modern hardware.
Above the floor, effects beat fps. Visual upgrades costing 10–15% are in scope
when they leave the cell above its threshold.

Navigating that trade-space honestly needs individual contributions flipped one
at a time on real hardware, and a change that wins on five machines and loses on
one is the normal case, not the exception.

## Decision

**Every per-target visual or perf knob must be flippable at runtime (a cvar) or
at launch (a `-flag` parsed in the relevant `*_Init`), without a rebuild.** The
inventory is `docs/KNOBS.md`; keep it current, because end-of-round A/B depends
on it. Per-machine shipping defaults live in `scripts/bundle/autoexec-*.cfg`.

**An fps win must not regress visuals on any target.** Gate an fps-for-quality
mode behind a cvar rather than making it unconditional.

**When a change helps some machines and hurts others, gate it to the regressor
and ship the wins.** Three mechanisms, most to least restrictive:

1. **Compile-time gate by build slice** — `#if (__ppc__ && !__VEC__)` for
   G3-only, `#if __VEC__` for AltiVec, `#if __x86_64__` for Intel. Use when the
   runtime check itself would matter on the slice being skipped, or when the
   code cannot compile for it (AltiVec intrinsics on a 750). Example: round v11
   `gl_aliasstate_cache` is compiled out of the G3 slice via
   `QS_DISABLE_ALIAS_STATE_CACHE` in `r_alias.c`.
2. **Per-machine autoexec** — the right tool when the difference is hardware or
   driver. ADR 0006.
3. **Runtime cvar or cmdline opt-out** — the everywhere-available toggle for
   end-of-round A/B review.

**Do not bury a beneficial change behind a runtime cvar when the beneficiaries
are five sixths of the matrix.** Gate the regressor.

## Evidence: the split results this exists for

- **`gl_aliasstate_cache`** (per-frame GL state cache in `R_DrawAliasModel`).
  Same-session A/B: sawtooth **+31.5%**, quicksilver **+38.1%**, mini-g4
  **+44.9%**, mini-intel **+21.2%**, imac-2019 **+16.0%**, yosemite **−4.1%**.
  The G3 regression is what drives the compile-time exclusion.
- **`gl_clear 0`** (skip the per-frame backbuffer clear; Quake's world and sky
  cover 100% of the screen, so it is a redundant fillrate-bound write). demo3
  1024: yosemite **+4.7%**, mini-intel **+3.5%**, quicksilver **+7.1%**, mini-g4
  **+9.3%**, but sawtooth **−2.1%** — a GeForce2 MX driver quirk where the
  no-clear path is slower than the explicit clear. Sawtooth alone stays at the
  engine default 1.
- **Liquid alpha.** `r_lavaalpha` / `r_telealpha` / `r_slimealpha` 0.6 shipped
  across yosemite plus three G4s plus mini-intel, then bisected on yosemite
  demo3 1024 (e1m6, lava-heavy): `r_lavaalpha 0.6` **alone** drops 19.65 → 14.40
  fps, **−26%**, below the 20 fps floor. Tele and slime alpha together also
  regressed. Dropped on the G3 only; `r_wateralpha 0.6` kept there because
  see-through water is the most common transparent-liquid effect in normal play.
  The G4 trio, Lion and the iMac keep all four — a different fillrate envelope.
- **`vid_bpp 32`**, gated to quicksilver and imac-2019. ADR 0007.
- **Round v5 B5, the scalar dlight cast hoist** (integer-only math replacing
  per-texel `(int)(brightness_f * cred_f)`, 3 fmul + 3 fctiw; estimated ~62%
  fewer cycles in the inner loop on a G3). Quicksilver demo3 1024 **+2.3%**, 640
  **+3.8%**; G3 neutral because it is GPU-bound; Lion neutral. mini-g4
  reproducibly **−2.6%**. Both G4s are ppc7400-class running the same scalar
  fallback, so the divergence is microarchitectural — quicksilver is MPC7450,
  mini-g4 is MPC7447A generation, with subtly different cache and
  integer/FP scheduling. Not separable without a hardware profiler.

## Consequences

- Two knobs are default-on now that were opt-in: `-noaltivec-lm` and
  `-noaltivec-dlights` were flipped to default-enabled in v8.1 (2026-05-10)
  after the round v3 retest of 2026-05-08 reclassified both as net-zero rather
  than regressed. The legacy `-altivec-lm` / `-altivec-dlights` remain as
  backward-compatible no-ops.
- Some changes are hard-coded with no runtime toggle: Phase 1 `frsqrte`
  mathlib, Phase 1.1 client vertex arrays plus CVA, Phase 2.1 BGRA
  `8_8_8_8_REV` lightmap upload, Phase 2.2 `APPLE_client_storage`, Phase 2.3
  `STORAGE_CACHED_APPLE`, Phase 3.1/3.2/3.3 `APPLE_vertex_array_range` pool and
  multitex array conversion, Phase 4.1 and 4.6 alias lerp and colour-fuse
  AltiVec. Most are foundational and were bisected at landing time.
- Levers that measured neutral are kept in tree, correct and inert, rather than
  deleted: `-g3clbrush`, `gl_surfbatch`, `-r128-cva`, `-nowarpedarrays`. See
  `docs/KNOBS.md` for what each does and what it measured, and `MISTAKES.md`
  for why the client-array family keeps coming out neutral-to-negative on a
  Rage 128.
- Gate any new perf or visual phase behind a named knob unless there is a strong
  reason not to, such as a code-size win only realised by removing the scalar
  fallback.
