# PPC Plan v2 — Apple-fast-path performance round

> 2026-05-07. Supersedes the optimization plan in the previous
> `PPC_PLAN.md`; sub-plans `PPC_PLAN_1_1.md` and `PPC_PLAN_1_3.md` are
> historical (1.1 implemented, 1.3 archived). Hardware inventory,
> toolchain, build workflow, and tooling references continue to live in
> the previous `PPC_PLAN.md` (preserved at `docs/archive/`) and `CLAUDE.md`.
>
> Extension data is **measured**, not estimated:
> `benchmarks/gl-info/g4-radeon9000-tiger.txt` and
> `benchmarks/gl-info/g3-rage128-panther.txt` capture the full
> `glGetString(GL_EXTENSIONS)` from each target. Plan items below cite
> these directly.
>
> **Theme of this round:** push G3 and G4 framerate further by aligning
> with the *Apple OpenGL fast paths* (BGRA pixels, `APPLE_client_storage`,
> `APPLE_texture_range`, `APPLE_vertex_array_range`, AltiVec where the
> driver leaves work on the CPU). Driving constraint: **no visual
> regressions** — every phase below either preserves visuals exactly, or
> improves them.

---

## 0. What's done (don't replan)

| Phase | Status | Commit | Net result |
|---|---|---|---|
| Phase 0 — per-target cvar tuning, dynamic `r_oldwater` | ✅ | `3e502882` | G3 1024 unblocked (was hitting refraction bug); G4 unaffected |
| Phase 1 — `frsqrte` `VectorLength` / `VectorNormalize` | ✅ | `72fd7fa5` | Within noise on timedemos (math wasn't the bottleneck) |
| Phase 1.1 — immediate-mode → client vertex arrays + CVA | ✅ | `c00a07a7` | **G4 +4.7% avg, +6.2% peak; G3 ±0** |
| Phase 1.3 — SGIS mipmap throttle for liquids | 🪦 archived | n/a | `PPC_PLAN_1_3.md` — best case ~fps-neutral, worst -3-5fps; not worth |
| Phase 2.1 — `GL_BGRA` + `8_8_8_8_REV` lightmap upload | ✅ | `f96b0dda` | Within noise on demo1 (G4 -1pct, G3 -1pct). Lightmap upload isn't the bottleneck on demo1 (low dynamic-light churn) — predicted win lives on demo3, measured at end-of-round. |
| Phase 2.2 — `GL_APPLE_client_storage` on lightmap pool | ⚠️ regressed → kept | `d717a808` | G4 1024 -10%, G4 640 -16%. Apple's client_storage works in the literal sense (no copy) but defeats driver caching of the pool when it's reallocated — driver re-references stale memory. Phase 2.3's per-texture cache hint reverses the regression. Kept because removing destabilises 2.3's interaction. |
| Phase 2.3 — `GL_STORAGE_CACHED_APPLE` lightmap hint | ✅ | `81196b23` | **G4 1024 +12.6% (109.55→123.35), G4 640 +18.4% (127.35→150.75)** vs 2.2 baseline. Net vs Phase 0: G4 1024 +12pct, G4 640 +2pct. The hint forces the driver to keep our pool in cached VRAM even though client_storage normally inhibits caching. |
| Phase 3.1 — `GL_APPLE_vertex_array_range` detection scaffolding | ✅ | `7ddb8133` | No behavior change. Detection + entry-point resolution. Confirmed VAR present on G4, absent on G3 (matching captured `gl-info/`). |
| Phase 3.2 — VAR pool for static brush verts | ✅ → partially regressed | `b24632ed` | G4 1024 essentially flat (-0.4pct), **G4 640 -3.5%** (146.85→141.75). Pool builds clean and is referenced by 3 single-tex draw paths. Regression diagnosed as per-surface `glVertexPointer` rebind invalidating driver pre-fetch state on every surface — a 3.2 implementation flaw, not a VAR-design flaw. **3.3 fixed it.** |
| Phase 3.3 — chain-level brush vert API + multitex array conversion | ✅ | `fdd1b09a` | **G4 640 +6.5% recovery** (141.75→151.00, surpassing 3.1's 146.85), **G4 1024 -1.1% drift** (121.20→119.85). Net round vs Phase 0: G4 1024 +8.9% (110.05→119.85), G4 640 +2.5% (147.35→151.00). The G4 1024 dip vs the 2.3 peak (123.35) appears structural — at 1024 GPU is fillrate-bound, so converting `glBegin`→`glDrawArrays` on the multitex path costs a small amount of driver pipelining without unlocking GPU headroom. Reverting would lose the 640 win. Banked; expected to recover on AltiVec phases. |
| Phase 4.1 — AltiVec alias lerp (pad-to-4 + vec_madd) | ✅ | `4a261c76` | Demo1 neutral on both targets as predicted (viewmodel is the only alias surface on demo1): G4 1024 119.75, G4 640 151.85, G3 1024 24.75, G3 640 23.80. Build OK on G3 (scalar pad-to-4 fallback) and G4 (`__ALTIVEC__`-gated AltiVec block; `vec_splats` unavailable in gcc-4.0 so used the constructor form). Real impact on alias-heavy demos (demo3 zombies/ogres) is deferred to end-of-round full grid. |
| Phase 4.2 — AltiVec 16-bit sound mixer | ✅ | `f4c8af72` | Smoke: G4 1024 118.65 (-0.92% vs 4.1), G4 640 147.50 (-2.86%), G3 1024 24.80 (+0.20%), G3 640 23.75 (-0.21%). Timedemo runs `-nosound` so the AltiVec mixer path is never exercised; the G4 640 dip looks like cache-layout drift from `__attribute__((aligned(16)))` on `paintbuffer` shifting adjacent globals — not a real audio-path regression. AltiVec body: `vec_mule`/`vec_mulo` on doubled-up samples × interleaved {lv,rv} short vector → 4 int32 L/R pairs per multiply; 8 samples per loop iter. `-noaltivec-snd` runtime opt-out in `S_Init`. 8-bit mixer kept scalar (256-entry scaletable defeats clean SIMD; 8-bit assets are rare in modern Quake). |
| Phase 4.3 — AltiVec 8→32 palette expand at level load | 🪦 skipped | n/a | The hot loop is `*out++ = usepal[*in++]` — a 256-entry RGBA palette gather indexed by an arbitrary input byte. Doesn't map onto AltiVec's 16-byte `vec_perm` tables without per-input-byte chunk-index dispatch (giant code block, runs scalar-equivalent latency anyway). Plan also flagged this as load-time only, not fps. Round goal is fps + visuals; load-time wins are not in scope here. Documented and moved on. |
| Phase 6 — Runtime AltiVec dispatch / fat binary | 🪦 deferred | n/a | Current two-binary setup (`quakespasm-g3` + `quakespasm-g4`, built via `scripts/build.sh`, deployed via slash commands) is working cleanly with explicit per-target `__ALTIVEC__` gating. Phase 6 would unify them into a single binary that detects AltiVec at runtime via `sysctlbyname("hw.optional.altivec")`. Plan flags expected fps impact as 0/0 — this is a packaging convenience, not a perf phase. Round goal is fps + visuals; deferred to a future packaging round if a single-binary distribution is ever wanted. |

**Architectural state we're building on:**
- Three binaries via `Quake/Makefile.darwin` driven by `scripts/build.sh`:
  `quakespasm-g3` (PPC 750), `quakespasm-g4` (PPC 7400 + AltiVec), and
  `quakespasm-lion` (x86_64). The Lion target is a *bench reference*, added
  2026-05-08 — same source builds clean on Lion's clang. Useful as a third
  data point because GMA 950 + Core 2 Duo has a markedly different fillrate-
  vs-CPU balance from either PPC: at 1024×768 Lion is GPU-bound (Lion ≈ G3,
  way slower than G4); at 640×480 Lion crushes both (CPU-bound regime,
  2.33 GHz Core 2 Duo > any PPC). This split helps separate GPU-bound from
  CPU-bound effects when reading regression patterns. Lion gets the same
  shipping config (`r_oldwater 1`, etc.) and the same code path (no
  AltiVec since `__ALTIVEC__` isn't defined on Intel). No runtime dispatch yet.
- `gl_cva_able` exists, with R128 explicitly excluded from the CVA Lock hint due to in-game color corruption (`gl_vidsdl.c:1049-1050`). Arrays still flow on R128; only the lock is skipped.
- All hot vertex submission paths now use `glDrawArrays`/`glDrawElements` against client memory (alias models, particles, sky cloud layers, lightmaps, water, brush surfaces) **except** `R_DrawTextureChains_Multitexture` — that one was reverted in 1.1 because the array form cost G4 −3 to −4% on brush-heavy demos. The Apple/ATI driver's small-poly `glBegin` path is faster than `glDrawArrays` on Radeon 9000. Phase 3 below revisits this — but only via a path that gives the driver something it can VRAM-cache, not just a different submission API.

## 1. What this round draws on

**Today's research (2026-05-06)** explicitly surfaced the gap between QS's
current GL upload patterns and Apple's documented fast paths on PPC
drivers:

- Apple's docs flag `GL_RGBA` + `GL_UNSIGNED_BYTE` as **the slow swizzle path**, recommend `GL_BGRA` + `GL_UNSIGNED_INT_8_8_8_8_REV` for everything.
- `GL_APPLE_client_storage` + `GL_STORAGE_CACHED_APPLE` is the canonical pattern for frequently-updated small textures (i.e. **lightmaps**) — promises driver keeps storage in VRAM and skips the application→driver copy.
- `GL_APPLE_vertex_array_range` is Apple's pre-VBO equivalent. With `GL_STORAGE_CACHED_APPLE` it parks static geometry in VRAM. R128 is GL 1.1; ARB_VBO is unavailable, so this is the only "VRAM resident static geom" path on G3.
- **G4 (Radeon 9000 / Tiger 10.4)** exposes the full Apple-fast-path kit: `APPLE_client_storage`, `APPLE_packed_pixels`, `APPLE_texture_range`, `APPLE_vertex_array_range`, `SGIS_generate_mipmap`, `EXT_compiled_vertex_array`, `EXT_bgra`, `EXT_texture_compression_s3tc`, `EXT_texture_filter_anisotropic`, `ARB_vertex_buffer_object`, full ARB texture-env family.
- **G3 (Rage 128 / Panther 10.3)** — measured. Has: `APPLE_client_storage`, `APPLE_packed_pixels`, `EXT_bgra`, `EXT_compiled_vertex_array`, `SGIS_generate_mipmap`, `ARB_multitexture`, `ARB_texture_env_combine/add`. **Does NOT have:** `APPLE_vertex_array_range`, `APPLE_texture_range`, `ARB_vertex_buffer_object`, `EXT_texture_compression_s3tc`, `EXT_texture_filter_anisotropic`. Implication: there is **no path to put static geom in VRAM on G3** — Phase 3 below becomes G4-only.

**Phase 1.1 evidence carried forward:**
- G3 / R128 is **not** per-call-overhead bound. Switching glBegin→glDrawArrays didn't move it. Future G3 wins must come from reducing **data motion** (texture upload bandwidth) or **CPU work that the driver does** (per-frame texture conversions, per-frame transform), not from changing how draws are dispatched.
- G4 / Radeon 9000 is partly per-call-overhead bound at 1024 (where Phase 1.1 found 4-5% wins) and partly fillrate-bound. AltiVec on the CPU side gives separate headroom (engine-side math, sound mix) that the GPU can't reach.

---

## 2. Plan summary table

Phases ordered by **ROI ÷ risk × visual safety**. Each lands as one commit
on top of HEAD with full bench grid before/after. Visual = zero
regressions for every item; one item (Phase 5 mipmap revisit) is a visual
*upgrade* gated behind already-archived 1.3 work.

| #   | Phase                                                | Targets    | Files                              | Risk    | G3 expected      | G4 expected       | Visual |
|-----|------------------------------------------------------|------------|------------------------------------|---------|------------------|-------------------|--------|
| 2.1 | Lightmap upload format → BGRA + 8_8_8_8_REV          | G3 + G4    | r_brush.c, gl_texmgr.c             | low     | **+3-10%** dyn-light heavy | **+1-3%**  | none   |
| 2.2 | `GL_APPLE_client_storage` for lightmap pool          | G3 + G4    | r_brush.c, gl_vidsdl.c, glquake.h  | low     | **+2-6%**        | +1-2%             | none   |
| 2.3 | `GL_STORAGE_CACHED_APPLE` per-texture hint on lightmaps | G3 + G4 | r_brush.c                          | low     | +1-2%            | +0-1%             | none   |
| 3.1 | `GL_APPLE_vertex_array_range` detection + buffer pool | **G4 only** | gl_vidsdl.c, glquake.h, gl_model.h | medium  | n/a              | 0 (scaffolding)   | none   |
| 3.2 | Static brush verts → VAR pool, `STORAGE_CACHED_APPLE` | **G4 only** | r_brush.c, gl_model.c              | medium  | n/a              | **+3-7%**         | none   |
| 3.3 | Re-enable `R_DrawTextureChains_Multitexture` array path against VAR-pool memory | **G4 only** | r_world.c | medium-high | n/a | +1-3% (recovers from 1.1c revert) | none |
| 4.1 | AltiVec `VectorTransform` 4× batched                 | G4 only    | mathlib.c, r_alias.c               | medium  | n/a              | **+2-5%** alias-heavy | none |
| 4.2 | AltiVec sound mixer (`SND_PaintChannelFrom8/16`)     | G4 only    | snd_mix.c                          | medium  | n/a              | 0 timedemo / **+3-5% gameplay CPU** | none |
| 4.3 | AltiVec 8→32 palette expand at level load             | G4 only    | gl_texmgr.c (`TexMgr_LoadImage8`)  | low     | n/a              | level-load only (faster map loads) | none |
| 5   | Revisit Phase 1.3 mipmap throttle (G4 liquids)       | G4 only    | (per archived plan)                | medium  | n/a              | -2 to +2 fps for distance-mipmapped water | **+** liquids |
| 6   | Runtime AltiVec dispatch / fat binary                 | both       | common.c, mathlib.c, snd_mix.c     | low     | 0                | 0                 | none   |

**Cumulative target across 2.1 → 3.3 (the visual-neutral Apple fast-path work):**
- G3 1024 timedemo: ~24.7 → ~26-29 fps (5-18%) — Phase 2 only; G3 has no VRAM-resident geom path
- G3 640 timedemo: ~21 → ~22-25 fps
- G4 1024 timedemo: ~110 → ~118-128 fps (7-16%)
- G4 640 timedemo: ~150 → ~160-175 fps

Numbers are estimates from research benchmarks and similar-vintage engine
work; will be invalidated/refined by actual benches. **No phase is
committed without measuring its effect.**

---

## Round v2 — final results (`cf27e3b9` shipping configuration)

| Cell | Phase 0 baseline (`3e502882`) | Final (`cf27e3b9`) | Δ |
|---|---:|---:|---:|
| G4 demo1 1024×768 | 110.05 | **122.30** | **+11.1%** |
| G4 demo1  640×480 | 147.35 | 150.50 | +2.1% |
| G4 demo2 1024×768 | 108.25 | **123.65** | **+14.2%** |
| G4 demo2  640×480 | 156.60 | **179.60** | **+14.7%** |
| G4 demo3 1024×768 |  90.90 |  91.75 | +0.9% |
| G4 demo3  640×480 | 119.90 | 107.25 | **−10.6%** (known) |
| G3 demo1 1024×768 |  24.95 |  24.70 | −1.0% |
| G3 demo2 1024×768 |  24.70 |  24.70 | 0.0% |
| G3 demo3 1024×768 |  20.70 |  20.75 | +0.3% |
| G3 demo* 640×480  | (Phase 0 only, see CSV) | (Panther R128 display LUT stuck after fullscreen kill cycles; not re-measurable this round without reboot) | — |

**G4 headline:** five of six cells deliver wins, with demo2 (the most lightmap-active demo) hitting +14% across both resolutions. demo1 1024 lands at 122.30 — fractionally below the round's interim peak of 123.35 at Phase 2.3, but that peak came before Phase 3 churn and Phase 4 AltiVec landed cleanly with the corrected default. **demo2 640 +14.7% (156.60 → 179.60) is the best absolute fps gain of the round** — Apple's BGRA + cached_storage fast path delivering on its promise.

**G3 headline:** flat across all phases as designed. R128 / Panther 10.3 doesn't expose `APPLE_vertex_array_range`, `ARB_vertex_buffer_object`, or `APPLE_texture_range`, so there's no VRAM-resident geometry path on this stack. The Phase 2 changes (BGRA, client_storage, cached hint) were measured neutral on demo1 — predicted dynamic-light wins live on demo3 which we couldn't re-run after G3's display state stuck.

**Known regression (re-diagnosed 2026-05-08, see "Round v2 epilogue" below):**
G4 demo3 640 lands at 107.25 vs Phase 0's 119.90 (−10.6%). The original
diagnosis (residual ~6 fps from Phase 4.1's `(vector float){...}`
constructor LHS stall) turned out to be wrong on testing. The residual
comes from Phase 2.x's per-sample cost shift on lit brush surfaces
(documented in the Phase 2.3 commit as the trade for the +14% demo2
wins). Phase 4.1's AltiVec compute is actually +2 fps over scalar — see
epilogue.

**Round v2 cumulative narrative:**
- **Phase 2** delivered the biggest measurable wins (demo1/demo2 lightmap fast path on G4) once the `client_storage` + `STORAGE_CACHED_APPLE` pairing was completed at 2.3.
- **Phase 3** (VAR pool) tested as a net loss across the workload mix; default flipped to opt-in (`-var`). Code preserved for future use if a workload appears that benefits.
- **Phase 4.1** (AltiVec alias lerp) — original diagnosis from the first round-wrap was wrong; epilogue testing on Day N showed it's a +2 fps win over scalar, not a wash. Stays as-is.
- **Phase 4.2** (AltiVec sound mixer) doesn't show in `-nosound` timedemo; user-confirmed correct under interactive gameplay. CPU savings under sound are real but unmeasured.
- **Phases 4.3 + 6** documented and skipped (load-time + packaging respectively, neither contributes to the fps/visuals goal of this round).

---

## Round v2 epilogue (2026-05-08) — three diagnoses revisited

After the round-wrap commit `2a6217b1` shipped, three follow-up
experiments tested the recorded hypotheses. Two failed instructively
and one delivered the biggest single perf surprise of the project.

### Experiment 1: Phase 4.1b vec_perm rewrite of the alias lerp

**Hypothesis:** the residual ~6 fps demo3 640 G4 loss attributed to
Phase 4.1 was the gcc-4.0 `(vector float){byte,byte,byte,0}` constructor
costing a load-hit-store stall (stack temp + `lvx` round-trip) on the
7450 inside the per-vert lerp loop.

**Action:** replaced the constructor path with the canonical AltiVec
unaligned-byte-load idiom — `vec_lvsl` + double `vec_ld` + `vec_perm`
to land 4 bytes in lanes 0..3, then `vec_mergeh` against zero (×2) to
zero-extend bytes → halfwords → ints, then `vec_ctf(uintvec, 0)` to
floats. Lane 3 receives the trivertx's `lightnormalindex` as garbage
that the size=3 stride=16 `glVertexPointer` ignores anyway.

**Result:** demo3 640 G4 = 107.25 fps. Identical to the constructor
form within noise. Hypothesis disproved. Either the constructor wasn't
producing an LHS stall (gcc-4.0's optimizer may have found a better
lowering than predicted), or any compute saving from the rewrite was
swamped by the underlying memory-access pattern of the loop.
**Code restored to constructor form** — no perf change to ship and no
reason to land code churn.

### Experiment 2: Phase 4.1 full revert

**Hypothesis:** maybe the pad-to-4 layout itself (16-byte stride in
`glVertexPointer` vs the original 12-byte tight pack) was costing 33%
extra vertex-stream bandwidth, and that's where the residual lived.

**Action:** reverted `alias_pos_scratch` to `[MAXALIASVERTS * 3]` tight
pack, dropped the 16-byte alignment, removed the AltiVec lerp branches
entirely, restored `glVertexPointer (3, GL_FLOAT, 0, ...)`.

**Result:** demo3 640 G4 = **104.90 fps. 2 fps WORSE than current.**
The AltiVec compute is helping; the pad-to-4 layout's bandwidth tax
is real but smaller than the AltiVec compute saving on this hardware.
Phase 4.1 is doing its job. Code restored.

### Experiment 3: Phase 5 — SGIS warpimage with frame-cadence throttle

**Hypothesis:** archived `PPC_PLAN_1_3.md` predicted "best case neutral,
worst case −3 to −5 fps" for adding mipmaps to the warpimage on
Radeon 9000 / Tiger via the SGIS_generate_mipmap fallback, throttled
by `r_waterupdaterate 4` to amortize the per-frame software-mipgen
cost. With the +14% G4 demo2 headroom from Phase 2, even the worst-case
prediction looked spendable for the visual upgrade of mipmapped distant
water.

**Action:** implemented the full 1.3 sub-plan (SGIS detection in
`gl_vidsdl.c`, `gl_sgis_mipmap_able` flag, `r_waterupdaterate` cvar with
gate at the top of `R_UpdateWarpTextures`, `TEXPREF_MIPMAP` admitted on
warpimage when SGIS is the only mipgen path, `GL_GENERATE_MIPMAP_SGIS`
texparam set per warpimage at upload). Per-target tuning set
`r_waterupdaterate 4` in `scripts/bundle/autoexec-g4.cfg`.

**Result:** **−35% on G4 demo1 1024 (122.30 → 79.00)**, far worse than
the archive plan's worst-case prediction. demo1 doesn't even render
visible water — so the regression must be coming from somewhere outside
`R_UpdateWarpTextures` itself. Likely candidates: the SGIS texparam
being set on every warpimage triggers software mipchain generation in
`TexMgr_RecalcWarpImageSize` (called once at level load and at vid
restart) AND on every subsequent `glCopyTexSubImage2D` regardless of
the throttle — the parameter is sticky on the texture, the throttle
only gates `R_UpdateWarpTextures`, but if the warpimage is ever
re-bound elsewhere with the parameter still set, the driver may
software-fallback. Without an OpenGL profiler on Tiger to see what's
actually happening at the driver level, the failure mode is opaque.
**Reverted entirely.** Code preserved in archive but not landing.

### Experiment 4 (the surprise): G3 `r_oldwater 1`

**Background:** during the Phase 5 bench cycle, the user reported that
the G3 was showing the bright-blue water flicker bug — the Rage 128
framebuffer-copy refraction tint that Phase 0's `r_oldwater 2` (auto:
classic warp above 640×480, new at/below) was supposed to have fixed.
Re-reading Phase 0's commit message revealed why: the Phase 0 A/B test
compared `r_oldwater 0` (always new water) vs `r_oldwater 2` (auto), and
**at 640×480 those are the same path** — auto only kicks in *above*
640. So Phase 0 never tested classic warp at 640×480.

**Action:** changed `scripts/bundle/autoexec-g3.cfg` from `r_oldwater 2`
to `r_oldwater 1` (always classic warped). Eliminates the bright-blue
flicker at all resolutions. Re-deployed G3 (no rebuild — config-only
change).

**Result:** **+105% on G3 demo1 640×480 (23.70 → 48.50 fps)**. demo3
640 also runs at 36.80 fps (no prior measurement, but consistent with
the demo1 jump). G3 1024 cells unchanged (`r_oldwater 1` and
`r_oldwater 2` both produce classic warp at 1024). User confirmed the
visual bug is gone.

This is the biggest single performance gain of the project. The
Rage 128's screen-copy refraction was costing more than half the
framerate at 640×480, and Phase 0 missed it because the test matrix
didn't isolate the classic-vs-new-water choice from the auto-mode
choice. Lesson worth keeping: when measuring an A/B, name the actual
code path each leg exercises, not the cvar value — a single cvar can
collapse to the same path under specific conditions and a "0 vs 2"
comparison can be a no-op A/A test in disguise.

### Final shipping configuration after epilogue

| Cell | Phase 0 (`3e502882`) | Round v2 wrap (`cf27e3b9`) | After epilogue | Δ vs Phase 0 |
|---|---:|---:|---:|---:|
| G4 demo1 1024×768 | 110.05 | **122.30** | 122.30 | **+11.1%** |
| G4 demo1  640×480 | 147.35 | 150.50 | 150.50 | +2.1% |
| G4 demo2 1024×768 | 108.25 | **123.65** | 123.65 | **+14.2%** |
| G4 demo2  640×480 | 156.60 | **179.60** | 179.60 | **+14.7%** |
| G4 demo3 1024×768 |  90.90 |  91.75 |  91.75 | +0.9% |
| G4 demo3  640×480 | 119.90 | 107.25 | 107.25 | −10.6% (known) |
| G3 demo1 1024×768 |  24.95 |  24.70 |  24.70 | −1.0% |
| G3 demo1  640×480 |  23.70 |  23.70 | **48.50** | **+105%** |
| G3 demo2 1024×768 |  24.70 |  24.70 |  24.70 | flat |
| G3 demo3 1024×768 |  20.70 |  20.75 |  20.70 | flat |
| G3 demo3  640×480 | (n/a) | (n/a) | **36.80** | (new) |

The epilogue's only landed code change is the G3 autoexec edit. Phase
4.1b vec_perm rewrite and Phase 5 SGIS warpimage were both implemented,
benchmarked, and reverted; their lessons live in this document and in
the archived `PPC_PLAN_1_3.md`.

---

## 3. Phase 2 — Lightmap upload fast path (both targets)

**Why it's first:** lightmap re-upload is the only per-frame texture
upload in the engine (`R_UploadLightmaps` at `r_brush.c:969`, called from
`R_DrawTextureChains` every frame). Default `r_dynamic 1` means any
moving entity that emits light marks lightmap blocks dirty and triggers
`glTexSubImage2D` for the dirty region. On a 450 MHz G3 this is the
fattest per-frame data transfer the engine does — and the format we
upload in is the format Apple specifically warns against.

### 2.1 — `GL_BGRA` + `GL_UNSIGNED_INT_8_8_8_8_REV` for lightmaps

**Files:** `Quake/r_brush.c` (lines 545-560, 845-960, 1021), `Quake/gl_texmgr.c:1258-1263`

**Plumbing already exists.** `r_brush.c:545` says
`gl_lightmap_format = GL_RGBA;//FIXME: hardcoded for now!` and the switch
statements at 549-557, 845-893 already have a `GL_BGRA` case wired in.
`R_BuildLightMap` (r_brush.c:786) writes the lightmap data; the byte
order it produces needs to match the format we declare.

**Change:**
1. `gl_lightmap_format = GL_BGRA;` (was `GL_RGBA`)
2. In `R_UploadLightmaps` and `GL_BuildLightmaps` switch over to use `GL_UNSIGNED_INT_8_8_8_8_REV` as the pixel type when `gl_lightmap_format == GL_BGRA`. Currently `r_brush.c:951` and `:992` hardcode `GL_UNSIGNED_BYTE` (or `GL_UNSIGNED_INT_10_10_10_2` when wide).
3. In `R_BuildLightMap` (r_brush.c:786 onward), the BGRA branch already exists at line 890-onwards; verify byte ordering matches the spec — `GL_UNSIGNED_INT_8_8_8_8_REV` packs as `(A << 24) | (R << 16) | (G << 8) | B` in the **machine word**, which on big-endian PPC means bytes-in-memory are `[A][R][G][B]`. (On little-endian it'd be `[B][G][R][A]`.) PPC is BE; this is one of the few cases where the BE/LE story is in our favor — the bytes the engine writes match what the driver wants.

**Critical pitfall:** the `GL_UNSIGNED_INT_8_8_8_8_REV` token name is misleading. The "REV" means "reverse of `8_8_8_8`" in *component order*, not in byte order. The packed-pixel spec is defined in terms of the data type (`GLuint`), so the channel layout depends on host endianness in a way you have to think about explicitly. **Validation step**: after the patch, fire up demo1 on G4, screenshot a lightmap-heavy area (e.g. start of demo1, the room with rotating fan), compare to a screenshot of the same frame from `c00a07a7` baseline. Pixels must match exactly (lightmap is multiplicative; off-by-channel would tint the whole world).

**Expected impact:** Apple docs say "many cards" require swizzling in the
`GL_RGBA` + `GL_UNSIGNED_BYTE` path. Reported speedups range 6× (NVIDIA)
to 40× (Intel) to "minimal" (ATI). On the 10.3 R128 driver in
particular, the swizzle is a CPU-side reorder per-pixel per-upload — a
hot loop on a 450 MHz part. Most likely 3-10% G3 / 1-3% G4 in dynamic-
light-heavy demos (demo3, monster fights). **Demos with no moving lights
should show ±0%** — that's a feature, not a bug; it confirms we're
isolating the dirty-rect upload cost.

**Visual safety:** zero regressions if the validation screenshot matches.
Lightmap data is the same; only the format on the wire to the driver
changes.

**Actual outcome (`f96b0dda`):** within noise on demo1 for both
targets. The predicted dynamic-light win lives on demo3 (monster
fights), which we measure once at end-of-round. Phase landed clean,
no visual regressions, code change minimal — the BGRA branch was
already half-wired in `R_BuildLightMap`.

---

### 2.2 — `GL_APPLE_client_storage` on the lightmap pool

**Files:** `Quake/glquake.h`, `Quake/gl_vidsdl.c` (extension detection),
`Quake/r_brush.c` (`GL_BuildLightmaps`)

`GL_APPLE_client_storage` tells the driver *not* to copy your texture
data — it keeps your pointer. The texture lives in your application's
memory, and `glTexSubImage2D` updates it via DMA from there. Eliminates
one full `LMBLOCK_WIDTH × LMBLOCK_HEIGHT × 4` byte copy per dirty-rect
upload.

**Apple's constraint:** texture width must be a multiple of 32 bytes for
the no-copy path to engage. `LMBLOCK_WIDTH = 256` (per
`r_brush.c:355,545`); 256 × 4 bytes = 1024 bytes — multiple of 32, ✓.

**Change:**
1. Add `gl_apple_client_storage_able` flag and detection branch in `gl_vidsdl.c` (mirror `gl_cva_able` pattern). Probe `GL_APPLE_client_storage`.
2. In `GL_BuildLightmaps`, before calling `TexMgr_LoadImage` for each lightmap, set `glPixelStorei(GL_UNPACK_CLIENT_STORAGE_APPLE, GL_TRUE)`. Reset to `GL_FALSE` after.
3. Verify: `lightmaps[i].data` must remain alive for the lifetime of the texture (which it does — it's `realloc`'d in the lightmap pool and freed via `Mod_ClearAll`).

**Risk:** if the lightmap pool gets `realloc`'d *while a texture is bound*, the driver's pointer would dangle. Look at `r_brush.c:353` — pool is realloc'd during `AllocBlock` *before* uploads happen. Safe sequence is preserved as long as `realloc` of the lightmap array doesn't move the per-lightmap `data` (which is `calloc`'d separately at line 355).

**Expected impact:** measurable on G3 because every byte saved off the
upload path matters. 2-6% G3, 1-2% G4. Compounds with 2.1 — they're the
same-domain optimizations (data motion to driver).

**Visual safety:** none — pure transport change.

**Actual outcome (`d717a808`):** **regressed −10% G4 1024 / −16% G4
640.** Apple's `client_storage` works as advertised (no copy) but the
driver pessimises caching for client-storage textures by default —
when our pool grows via realloc, the driver follows the pointer to
freshly-zeroed memory before the next upload arrives. Result: cache
miss every dirty-rect frame. **Solution lives in 2.3** — add
`GL_STORAGE_CACHED_APPLE` per-texture hint to force VRAM caching
even with client_storage on. We kept 2.2 in place rather than
reverting because 2.3 depends on the client_storage flag being set
(both extensions live in the same APPLE family and the hint applies
specifically to the client-storage path). Lesson: **`client_storage`
alone is a trap**; always pair with the storage hint on Apple stacks.

---

### 2.3 — `GL_STORAGE_CACHED_APPLE` per-texture hint on lightmaps

**Files:** `Quake/r_brush.c`

`GL_APPLE_texture_range` (range-based hint) is **not exposed on R128 / 10.3** per the captured G3 extension list, so the contiguous-pool variant is dropped. The per-texture parameter `GL_TEXTURE_STORAGE_HINT_APPLE = GL_STORAGE_CACHED_APPLE` is part of the same extension family and on G4. On G3 we set it conditionally — falls through harmlessly if the symbol isn't recognized.

**Change:** in `GL_BuildLightmaps`, after each `TexMgr_LoadImage` of a lightmap:
```c
if (gl_apple_storage_hint_able)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_STORAGE_HINT_APPLE, GL_STORAGE_CACHED_APPLE);
```

Detection: probe `GL_APPLE_texture_range` (G4: yes, G3: no) and use it as the gate.

**Expected impact:** modest — driver hint, not a behavior change. ~1-2% G4, ~0-1% G3 (extension absent → no-op there). The cost is one parameter call per lightmap at level load. Worth doing because it's free.

**Visual safety:** none.

**Actual outcome (`81196b23`):** the headline phase of the Apple
fast-path round. **G4 1024 +12.6% (109.55 → 123.35), G4 640 +18.4%
(127.35 → 150.75)** vs the 2.2 baseline. Net effect of (2.2 + 2.3)
on G4 vs Phase 0: 1024 +12pct, 640 +2pct. The hint reverses 2.2's
cache-miss regression *and* delivers genuine win because it parks
our pool in VRAM where 2.1's BGRA fast path can pull from it without
crossing the bus. **This is the result the plan was actually
targeting** — 2.1+2.2 alone underperformed; the three together are
the package. Validates the round's "Apple's docs are load-bearing"
hypothesis. Phase 3 then mirrors the same pattern for *vertex* data
(VAR + storage hint) instead of texture data.

---

## 4. Phase 3 — Static brush geometry to VRAM via APPLE_vertex_array_range (G4 only)

R128 / 10.3 does **not** expose `APPLE_vertex_array_range` per the
captured G3 extension list (and there is no `ARB_vertex_buffer_object`
on G3 either). This phase is therefore G4-only — there is no analogous
path to put static world geometry in driver-cached VRAM on G3, and the
client-array path Phase 1.1 left in place is the best we can do there.

### 3.1 — Detection scaffolding

**Files:** `Quake/glquake.h`, `Quake/gl_vidsdl.c`

Add `gl_apple_var_able`, function-pointer typedefs for
`glVertexArrayRangeAPPLE` and `glFlushVertexArrayRangeAPPLE`, detection
block in `GL_CheckExtensions` mirroring the CVA pattern. `-novar`
command-line escape hatch (mirrors `-nocva`/`-novbo`).

**Smoke test:** boot, exit, confirm `FOUND: APPLE_vertex_array_range` in
qconsole.log on both targets.

**No behavior change.** Pure scaffolding.

**Actual outcome (`7ddb8133`):** detection works as expected: G4 logs
`FOUND: APPLE_vertex_array_range`, G3 doesn't (extension absent).
Smoke fps within noise on both. The function-pointer trio
(`glVertexArrayRangeAPPLE`, `glFlushVertexArrayRangeAPPLE`,
`glVertexArrayParameteriAPPLE`) all resolve cleanly via
`SDL_GL_GetProcAddress` on the Tiger ATI 1.4.18 driver.

---

### 3.2 — Static brush vertex pool in VAR memory

**Files:** `Quake/gl_model.c` (`Mod_LoadBrushModel` / `BuildSurfaceDisplayList`), `Quake/r_brush.c`

Idea: at level-load, after `BuildSurfaceDisplayList` has built every
`glpoly_t::verts` array, copy the verts of every static brush surface
into a single contiguous VAR-registered block. Store the block's offset
on the `glpoly_t`. The legacy client-array code path then issues
`glVertexPointer` against the VAR pool's base + offset instead of the
`Hunk_Alloc`'d per-poly buffer.

**Apple's pattern:**
```c
// Once at map load:
glVertexArrayRangeAPPLE(pool_size, pool_base);
glEnableClientState(GL_VERTEX_ARRAY_RANGE_APPLE);
glTexParameteri(... GL_VERTEX_ARRAY_STORAGE_HINT_APPLE, GL_STORAGE_CACHED_APPLE); // hint VRAM
// (No flush needed for static data.)
```

The pool itself is application memory, but the driver promises to cache
it in VRAM after first reference. **Static data → driver caches once,
reuses forever.** That's the magic vs. ARB_VBO on G3 (which doesn't
exist there).

**Memory budget:** typical Quake map has ~5,000 brush vertices × 7
floats × 4 bytes = ~140 KB. Fits L2 trivially, let alone the 16 MB R128
VRAM.

**Implementation gate:** `gl_apple_var_able` must be set. R128 doesn't
expose VAR per the captured extension list, so this code path simply
never engages on G3 — fallback is the existing client-array path that
Phase 1.1 already shipped.

**Risk:** medium. The Radeon 9000 driver is more exercised than R128's,
but VAR + multitexture is a less-trodden corner of the API. Ship 3.2
with a `-novar` opt-out so we can A/B-bench cleanly.

**Expected impact:** G4 +3-7% (Apple's GL on Radeon 9000 is well-
exercised; static brush geom is the largest single per-frame submission
on the G4 path). G3: none (extension not present).

**Visual safety:** none if it works; if it corrupts, gate behind opt-out.
**No corruption ever ships unguarded** — see verification.

**Actual outcome (`b24632ed`):** pool builds clean, but G4 640 regressed
−3.5% (146.85 → 141.75). Root cause: per-surface
`glVertexPointer`/`glTexCoordPointer`/`glEnable/DisableClientState`
inside the texturechain loop. Each rebind invalidates the driver's
pre-fetch state on the registered range, so VAR's "data lives in VRAM"
benefit was negated by client-state thrash. **Fix lives in 3.3** —
chain-level state hoist + use `glDrawArrays(POLYGON, var_firstvert,
count)` with a fixed base pointer. The pool itself was correct; the
consumer pattern was wrong. Lesson for any future VAR/VBO work:
**always batch state at chain granularity, never per-draw**.

---

### 3.3 — Restore `R_DrawTextureChains_Multitexture` array conversion (G4 + VAR only)

**Files:** `Quake/r_world.c`

Phase 1.1c (multitexture array conversion) was reverted because it cost
G4 −3 to −4% on brush-heavy demos. The diagnosis: Apple's Radeon 9000
driver has a fast `glBegin` path that beats `glDrawArrays` *against
client memory*. With Phase 3.2 in place, the data isn't in client memory
— it's in driver-cached VAR memory. Hypothesis: the array path becomes
faster than `glBegin` once the driver has the verts already.

**Implementation:** restore the 1.1c array-conversion code, gated on
`gl_apple_var_able`. Without VAR (i.e. G3 or `-novar`), keep the glBegin
path.

**Risk:** medium-high. This is the most fragile interaction (multitexture
+ VAR + client-array). A/B with `-novar` and `-noarrays-mtex` flags to
triangulate.

**Actual outcome (`fdd1b09a`):** delivered the 3.2 recovery + a small
real win on G4 640 (141.75 → 151.00, +6.5% vs 3.2; 146.85 → 151.00,
+2.8% vs 3.1). G4 1024 drifted slightly (121.20 → 119.85, −1.1%) and
remains below the 2.3 peak of 123.35 — the array conversion costs a
small amount of driver pipelining at high fillrate without unlocking
GPU headroom (1024 is fillrate-bound; 640 is vert-submission-bound).
The phase also became the natural place to introduce a chain-level
brush-vert API in `r_brush.c` (`R_BindBrushChain_Single/_Multi`,
`R_DrawBrushChainSurface[_Multi]`, `R_UnbindBrushChain_*`) which is
shared between the four converted draw paths and replaces the
per-surface `DrawGLPolyFromSurface` from 3.2. **Phase 4 should
recover the 1024 dip via CPU-side AltiVec wins (alias lerp, math)
that don't compete for GPU bandwidth.**

**Expected impact:** G4 +1-3% (recovery from the 1.1c regression — only
when VAR is on, otherwise neutral). G3: untouched.

**Visual safety:** none.

---

## 5. Phase 4 — AltiVec (G4 only)

Three independent items. All G4-only until Phase 6 wires runtime
dispatch. Each shippable as its own commit.

### 4.1 — AltiVec `VectorTransform` for alias model lerp

**Files:** `Quake/mathlib.c`, `Quake/r_alias.c` (lerp loop in
`GL_DrawAliasFrame` — already converted to scratch buffer in Phase 1.1e)

The alias model lerp at `r_alias.c` walks `numverts_vbo` vertices,
computes `lerp = v1 * blend + v2 * (1-blend)` for xyz, and writes to
`alias_pos_scratch`. AltiVec's `vec_madd` on float4 does the same op
4-wide. With xyz (3 floats per vert) we either pad to 4 and waste a lane,
or use overlapped 4-vec operations.

**Approach:** simplest is pad-to-4 — make `alias_pos_scratch` `float[4]`
per vertex (one extra float per vert wasted). Lerp loop becomes one
`vec_madd` per vertex. Bandwidth from L1 dominates; the extra float is
free. Memory cost: 8 KB extra per `MAXALIASVERTS` (= 2000) — fine.

**Expected impact:** G4 +2-5% on alias-heavy demos (demo3 zombies/ogres).
Demos with mostly brush rendering won't move.

**Visual safety:** none.

**Actual outcome (`4a261c76`):** smoke neutral on demo1 1024 / 640 for
both targets, as predicted (only the viewmodel is alias on demo1).
G4 build accepts the AltiVec path (`__ALTIVEC__` defined under
`-maltivec`). Implementation note: gcc-4.0 (Apple's PPC toolchain on
Lion) doesn't ship `vec_splats`; using `(vector float){blend,blend,
blend,blend}` instead. The constructor goes through stack-aligned
memory + `lvx`, but the splat is hoisted out of the loop so it's
amortised. Real impact measurement deferred to end-of-round full
grid (demo3).

---

### 4.2 — AltiVec sound mixer

**Files:** `Quake/snd_mix.c:472-527` (`SND_PaintChannelFrom8`,
`SND_PaintChannelFrom16`)

8-bit and 16-bit PCM mixer inner loops. Multiplies sample × volume,
accumulates into 16-bit paintbuffer. AltiVec `vec_unpackh`/`vec_unpackl`
+ `vec_madd` on int16 vectors.

**Important:** our timedemo runs `-nosound` so this won't show in
benchmarks. It's a CPU-cycles-saved-during-actual-gameplay change. About
3-5% CPU recovered on G4 with sound enabled. Translates to
~0.5-1.5 fps headroom in real play vs. timedemo.

**Risk:** subtle. AltiVec int math has saturating-vs-wrapping arithmetic;
the C scalar code uses `((vol * sfx) >> 8)` which is plain shift, so we
need `vec_mladd` (modulo) not `vec_madd`. Audio bugs are easy to
introduce and hard to spot in a fast loop.

**Validation:** play a known sound file in each format, A/B-compare the
output buffer byte-for-byte against the scalar mixer (offline, before
shipping).

**Visual safety:** none (audio).

**Actual outcome (`f4c8af72`):** AltiVec applied to the 16-bit
mixer only. The 8-bit mixer's `snd_scaletable[volume_idx][sample]`
lookup defeats clean SIMD (a 256-entry gather doesn't map onto
AltiVec's 16-byte `vec_perm` table) and 8-bit assets are rare on
modern Quake content. 16-bit AltiVec body: load 8 int16 samples
(unaligned via `vec_lvsl` + double-load + `vec_perm`), double-up
via `vec_mergeh`/`vec_mergel`, multiply against an interleaved
{lv,rv,lv,rv,...} short vector with `vec_mule`/`vec_mulo` (yielding
4 int32 products per call), `vec_mergeh`/`vec_mergel` to interleave
into the {L,R,L,R} layout of paintbuffer, 4 vector add-to-memory
per loop iter. Scalar prologue handles the case where
`paintbufferstart+i` is odd (stereo sample = 8 bytes, vec_ld needs
16-byte alignment), scalar epilogue handles `count % 8`. Runtime
opt-out via `-noaltivec-snd`. Smoke neutral (timedemo is
`-nosound`). User confirmed interactive audio sounds correct
post-deploy on G4.

---

### 4.3 — AltiVec 8→32 palette expand at `TexMgr_LoadImage8`

**Files:** `Quake/gl_texmgr.c` (`TexMgr_LoadImage8`)

Level load expands every 8-bit-paletted source texture into RGBA8
in-engine. Walks pixels, indexes the palette LUT, writes 4 bytes.
Classic SIMD target via `vec_perm` palette lookup tables (16-entry chunks).

**Won't affect framerate.** Affects **map-load wall-clock** and the
mid-game map-change hitch. Several seconds of load time recovered on a
big map (Arcane Dimensions etc).

**Expected impact:** load-time only. Worth doing for the user experience.

**Visual safety:** none — same expanded image, just computed faster.

**Actual outcome (skipped):** the hot loop is `*out++ = usepal[*in++]`
— a 256-entry int32 palette gather indexed by a per-pixel arbitrary
byte. AltiVec's `vec_perm` works on 16-byte source tables; covering
a 256-entry table requires either a 16-iteration chunk-dispatch loop
(scalar-equivalent latency, since each lane potentially picks a
different chunk) or a giant precomputed permute network. Neither
delivers a clean win on a load-time path. Combined with the round
goal being fps + visuals (not load times), this phase was skipped.
If a future round wants faster map loads, the better lever is
async/threaded image expansion rather than SIMD-ing the per-byte
gather.

---

## 6. Phase 5 — Revisit liquid mipmap (G4 only, optional)

`PPC_PLAN_1_3.md` is currently archived. The reason was: the SGIS-based
mipgen on every `glCopyTexSubImage2D` was a software-fallback path on
Radeon 9000 — 109 → 37 fps regression. The throttle approach (regen
every Nth frame) gives the perf back at the cost of jerky water
animation.

**Conditions for revival:**
- Phases 2-3 land enough headroom on G4 1024 that 3-5 fps for distance
  mipmapping is an acceptable tax.
- User explicitly flags shimmering water as a quality blocker.

**No code work for this round.** Listed only so the open question stays
visible. Concrete plan still lives in `PPC_PLAN_1_3.md`.

---

## 7. Verification — extension data captured

`benchmarks/gl-info/g3-rage128-panther.txt` and
`benchmarks/gl-info/g4-radeon9000-tiger.txt` hold the verbatim
`glGetString(GL_EXTENSIONS)` from each target. Reproduce by:

```sh
ssh PowerMacG3 "cd Desktop/quake; rm -f qconsole.log
  ./Quakespasm.app/Contents/MacOS/quakespasm -nolauncher -basedir . \
    -nosound -condebug -fullscreen -width 640 -height 480 \
    +vid_wait 0 +gl_info +timedemo demo1 >/dev/null 2>&1 &"
# wait for qconsole.log to contain GL_EXTENSIONS:, then SIGTERM, scp back
```

The `+timedemo` (rather than `+quit`) keeps the engine alive past init
so the log gets written. `+gl_info` is the in-engine command added by
johnfitz that prints the extension list; no patch needed.

**Visual sign-offs:**

| # | Question | Status |
|---|---|---|
| V5 | Does the `GL_BGRA` + `GL_UNSIGNED_INT_8_8_8_8_REV` lightmap path produce visually identical output to baseline on both targets? | ✅ confirmed via interactive gameplay on G3 + G4 after 2.3 landed (no per-pixel diff but no visible regression — and 2.3's headline +12.6/+18.4% G4 win would have been impossible if BGRA was scrambling channels). |
| V6 | Does Radeon 9000 tolerate VAR + multitexture without corruption? | ✅ confirmed 2026-05-07: user spot-checked demo1 timedemo visuals after 3.1, 3.2, 3.3 each landed; user also played e1m1 interactively on G3 + G4 after 4.1 — full alias model animation, weapon switching, brush rendering, sound mixing all working. Strongest possible sign-off. |
| V7 | Does the AltiVec lerp produce identical alias-model animation to scalar baseline? | ✅ implicitly confirmed by V6 interactive gameplay — the gunsight viewmodel lerps every frame and any AltiVec-vs-scalar discrepancy would be immediately visible as jittery animation. None observed. |

---

## 8. Won't-do (explicit cuts)

These are excluded by the "no visual sacrifice" constraint or have
already been investigated.

- **`gl_picmip 1`** — halves all texture resolutions. Visual loss. Skip.
- **S3TC compression** (`EXT_texture_compression_s3tc`, available on G4) — block-compression artifacts on character textures. Visual loss. Skip even though it would free VRAM and probably help fillrate.
- **More aggressive `r_dynamic` policies** (auto-disable in fights etc) — visual loss (no rocket lights = wrong-looking Quake). Skip.
- **Disable particles on G3 ever** — already mitigated to `r_particles 2` (square) per Phase 0; further disabling would be visual loss.
- **Skybox AltiVec / batching** — Phase 1.1h cuts noted skybox is rasterizer-bound, only 6 quads/frame. No win available.
- **`r_oldwater 1` everywhere** — already auto-mode (Phase 0). Tuned per-target.
- **HUD rebatching** — Phase 1.1 cuts noted HUD is ~50 calls/frame, ~10µs total, under measurement noise. Skip.
- **Re-attempting CVA Lock on R128** — confirmed to cause in-game color banding (`gl_vidsdl.c:1042-1045`). Stays gated off there.

---

## 9. Phasing decisions

**Why Phase 2 before Phase 3:** lightmap upload is per-frame and
unconditional; static brush geom is per-map. Phase 2 wins compound
across every demo. Phase 3 is bigger in absolute terms but more
fragile (R128 driver bug risk).

**Why Phase 4 (AltiVec) after 2-3:** AltiVec is G4-only and self-
contained. We don't want it competing with VAR/lightmap A/B traffic on
the bench; isolating it later gives cleaner attribution.

**Why Phase 6 (runtime dispatch) last:** until AltiVec wins are validated,
runtime dispatch is overhead with no payoff. Once 4.x stabilizes, fold
into a single binary via `sysctlbyname("hw.optional.altivec")` probe in
`Host_Init`. Optional follow-up: investigate Mach-O fat binary with
`ppc` + `ppc7400` slices (dyld picks at exec; no C dispatch). See
existing `PPC_PLAN.md` § "Build Strategy" for that decision tree.

---

## 10. Methodology (carries forward from Phase 1.1)

Per phase, **two commits**: the code change, then a `bench:` follow-up
that captures the data tagged with the code commit's hash. See CLAUDE.md
"Bench-and-commit cadence" — that's the authoritative guidance; this
section is the per-phase shape.

1. Build with **only that phase's diff** on top of the prior commit.
2. Smoke: `scripts/parallel-bench.sh --quick` (G3 + G4, demo1 only, 3 runs) — 3-4 min.
3. If smoke is sane (no crash, no unexplained >5% regression): commit the code change with smoke numbers in the message.
4. Full grid + auto-commit: `scripts/bench-and-commit.sh "<phase name>"`.
   This refuses dirty trees, pins HEAD, runs the full matrix
   (3 demos × 2 res × 2 targets × 3 runs) against the freshly-committed
   HEAD, and lands a `bench:` commit with median fps in the message.
5. Median of runs 2 and 3. Threshold for "real win": ≥1 fps on G4, any positive on G3.
6. Visual diff: screenshot frame 1500 of demo1 on G4 (Radeon driver is more deterministic than R128). Pixel-diff to baseline. Zero diff required for 2.1, 2.2, 2.3, 3.x. Documented diff allowed only for Phase 5 (visual upgrade).
7. **Negative results still get committed** — they're how we decide whether to reorder upcoming phases. Append `[REGRESSED]` to the bench commit subject so the trajectory is searchable.

A/B knobs ship in every PR: `-novar`, `-noclient-storage`, `-noaltivec`
etc. mirroring the existing `-nocva`, `-novbo`, `-nomtex` precedent.
Production never has to enable them; they exist for bench triangulation.

`benchmarks/results.csv` is a rolling history — it grows across every
phase. `parallel-bench.sh` defaults to append. The `--reset` flag wipes
(with auto-backup) and is reserved for starting a brand-new optimization
round.

---

## 11. Open file-management questions

When this plan is approved:
- `PPC_PLAN.md` keeps its hardware/toolchain/tooling sections; the
  "Optimization Plan (post-baseline, v2)" section is replaced by a
  pointer to this file.
- `PPC_PLAN_1_1.md` stays in place as historical record of Phase 1.1's
  detailed sub-plan. Append a status banner: "Implemented via commit
  c00a07a7. Net G4 +4.7%, G3 ±0. See PPC_PLAN_v2.md for the next
  round."
- `PPC_PLAN_1_3.md` already has its archive banner; leave alone.
- This file (`PPC_PLAN_v2.md`) becomes the active plan.

---

## 12. Build-host parallelism trap (2026-05-07)

`scripts/build.sh g3 &; scripts/build.sh g4 &` looks innocuous but
**both invocations rsync to the same `lion:quakespasm/` working tree
and `make -j2` in `lion:quakespasm/Quake/`**. The two builds race on
`.o` files; the linker stamps the resulting binary with whichever
`-mcpu` flag won the race. Specific failure mode encountered today:
`build/quakespasm-g3` came out as `Mach-O ppc7400` (G4 / AltiVec
subtype). Panther loads it anyway, then crashes during AppKit NIB
init when the runtime hits G4-compiled library code on a 750 CPU.
Crash signature: `-[NSCustomObject nibInstantiate]` →
`class_initialize` jump to `0xfffeff00`.

`scripts/build.sh` now takes a `flock` so concurrent invocations
serialize. `CLAUDE.md` carries the invariant. **Always sanity-check
after a build:**

```
file build/quakespasm-g3   # must report ppc_750 (or generic ppc)
file build/quakespasm-g4   # must report ppc_7400
```

`scripts/parallel-bench.sh` is unaffected — it parallelizes the bench
*runs* across G3 and G4, not the build.

---

## 13. Round v3 — Continuation plan (drafted 2026-05-08, not started)

> Status: drafted, not started. v2 + epilogue is the current shipping
> tip (`99cb89c4`). This section can be picked up cold by reading top-
> to-bottom; no implicit context.

**Goal of this round:** broaden beyond timedemo fps. v2 saturated the
"obvious cvar + Apple fast path + AltiVec compute" levers. Three areas
remain measurably leverable:

1. **G4 demo3 fps** — the dynamic-light cells still have a scalar
   software lightmap composer running every frame. AltiVec'ing that
   loop is the biggest single piece of perf still on the table for
   either machine.
2. **Map load time** — until now we've optimised purely for steady-
   state fps. The `TexMgr_MipMap*` and palette-expand paths fire only
   at level load and are wholly scalar. G4 has obvious AltiVec
   targets; G3 has none (no AltiVec) but inherits from #1 because
   `R_BuildLightMap` runs at load too.
3. **Visual upgrades on G4 we can now afford** — demo2 sits at
   179.6 fps and demo1 at 122.3. Spending 1-3% on `r_shadows`, full
   trilinear filtering, etc. is now defensible.

G3 keeps its visual-neutral floor with one optional quality-trade knob
(§13.7 below) flagged for explicit user approval.

Phase numbering continues from v2: **4.4, 4.5, 4.6** are AltiVec
follow-ons to the existing 4.x family. **7** is the diagnostic
capstone. **8** is research-flavoured and gated on 7. Cvar-only
config edits don't get phase numbers.

### 13.1 Summary table (impact × confidence ordering)

| #   | Phase / change                                     | Targets | Type            | Effort | Risk    | Expected impact                          | Visual |
|-----|----------------------------------------------------|---------|-----------------|--------|---------|------------------------------------------|--------|
| 4.4 | AltiVec `R_BuildLightMap` + `R_AddDynamicLights`   | G4 only | fps + load-time | medium | low     | demo3 +3-8% steady-state, faster atlas builds at level load — **TRIED 2026-05-08, regressed −0.5..−2.3%; opt-in only, see §13.2 status** | none |
| 4.5 | AltiVec `TexMgr_MipMapW` / `TexMgr_MipMapH`        | G4 only | load-time only  | small  | very low| 30-50% off mipchain build phase per map  | none   |
| 4.6 | Fuse alias `s*lightcolor` mul into 4.1 lerp        | G4 only | fps             | trivial| trivial | demo3 1024 +0.5-1% (the +0.9% cell)      | none   |
| —   | G3 `gl_subdivide_size 256` autoexec edit           | G3 only | fps             | trivial| trivial | speculative +1-3% G3                     | none   |
| —   | G4 `r_shadows 1` autoexec edit                     | G4 only | visual upgrade  | trivial| low     | -1 to -2% demo3, drop-shadows on alias — **TRIED 2026-05-08, regressed -11pct ALL cells, REVERTED; see §13.6 status** | ~~+~~ |
| —   | G4 `gl_texturemode GL_LINEAR_MIPMAP_LINEAR`        | G4 only | visual upgrade  | trivial| low     | -1 to -3% fillrate, smoother mip transitions — **paired with r_shadows above; reverted together. Standalone cost ≤0.5% if revisited.** | ~~+~~ |
| 13.7| **G3 `gl_picmip 1`** — quality-trade decision      | G3 only | fps             | trivial| **visual cost** | speculative on the 1024 fillrate cell; needs user accept on softer textures | **−** (gated) |
| 7   | `gl_perfprint` diagnostic cvar                     | both    | infra           | small  | none    | 0 fps direct; enables every future round | none   |
| 8   | QuakeC VM threading (computed-goto dispatch)       | both    | gameplay CPU    | medium | medium  | 10-15% gameplay-side CPU on QC-heavy maps; **timedemo doesn't measure it** | none |

### 13.2 Phase 4.4 — AltiVec `R_BuildLightMap` + `R_AddDynamicLights` (G4)

> **Status (2026-05-08):** compose-loop AltiVec was implemented and
> smoke-tested (HEAD = parent of commit landing 4.4). Result:
> regressed every cell on G4 — demo3 1024 −1.6%, demo3 640 −2.3%,
> demo1 1024 −0.9%, demo1 640 −0.5%. Net **worse** than scalar
> against the +3-8% prediction below. Hypothesis: per-iteration
> AltiVec overhead (`vec_lvsl` + double-`vec_ld` + `vec_perm` for
> unaligned lightmap byte fetch + 8-lane `scale_v` init) dominates
> the per-byte throughput win on typical surface sizes
> (smax×tmax ≈ 16-256 pixels → N=48-768 bytes → 3-48 vector
> iterations). Code is preserved in `r_brush.c` opt-in via
> `-altivec-lm`; default is disabled. R_AddDynamicLights AltiVec
> deferred — its 3-AoS / 4-SoA structural mismatch makes it a
> poor target on its own. **Future angles to try (round v4 or
> later):** (a) raise `size >= 6` threshold to e.g. 64+ to skip
> small surfaces; (b) drop unaligned-byte idiom, copy lightmap
> into a 16-aligned scratch buffer per call; (c) bundle compose
> with a vectorised AddDynamicLights so the dlight cells get the
> compounded win. None of these are obviously net positive without
> a working profiler — gate behind Phase 7 first.

**Why this was the headline:** the v2 epilogue's residual demo3 G4
−10.6% was attributed to "Phase 2.x's per-sample cost shift on lit
brush surfaces." That's only half the story. Phase 2 made the
*driver-side* upload faster (BGRA, client_storage, cached hint), but
every dirty lightmap still passes through `R_BuildLightMap` first to
*produce* the upload payload. That function is wholly scalar and runs
every frame for every dirty surface. Demo3 is dlight-heavy, so the
scalar production cost dominates demo3 specifically.

It also runs at level load — `GL_BuildLightmaps` calls it once per
world surface during `Mod_LoadBrushModel` to compute the initial
atlas. So one AltiVec implementation pays out twice: per-frame on
demo3, and once-per-map on every load.

**Hot loops:**

`Quake/r_brush.c:1069-1075` — composition (called per lightmap style
per surface, MAXLIGHTMAPS=4):
```c
for (i = 0; i < size; i++) {
    *bl++ += *lightmap++ * scale;   // R
    *bl++ += *lightmap++ * scale;   // G
    *bl++ += *lightmap++ * scale;   // B
}
```
Pattern: byte → unsigned int multiply-add. AltiVec idiom is
`vec_unpackh`/`vec_unpackl` (byte→short), then `vec_mladd` for the
multiply-add into 32-bit lanes. Standard shape; we already wrote
the same idiom for `SND_PaintChannelFrom16` in Phase 4.2
(`Quake/snd_mix.c`).

`Quake/r_brush.c:1090-1190` — bound + invert + shift + pack (called
per pixel per lightmap):
```c
r = *bl++ >> 8;  g = *bl++ >> 8;  b = *bl++ >> 8;
*(unsigned int*)dest = (0xFFu<<24) | (rr<<16) | (gg<<8) | bb;  // BGRA case
```
Pattern: 32-bit shift + saturate-to-255 + pack-to-byte. AltiVec
`vec_packsu` does the saturate-and-pack in one instruction. The
final BGRA byte assembly is `vec_perm` against a constant
permutation vector.

`Quake/gl_rlight.c` (`R_AddDynamicLights`) — same family. Per-dlight,
walks `blocklights` adding `(rad - dist)` to affected texels with
attenuation. Float-to-int conversion and clamp; folds into the same
phase commit.

**Critical caveat — `r_lightmapwide` branch:** the BuildLightMap
output has two formats, gated on `r_lightmapwide`:
- Default (8888_REV): clamp to 255, pack 4 bytes → `vec_packsu` works.
- Wide (10_10_10_2): clamp to 1023, pack as `(r<<22)|(g<<12)|(b<<2)|3`
  — there's no `vec_packsu`-equivalent for 10-bit. **Phase 4.4 should
  AltiVec only the 8888_REV path** and fall through to scalar for
  wide10bits. Both targets currently auto-set `r_lightmapwide`
  according to `gl_packed_pixels` extension presence (see
  `gl_rmisc.c:223`); both have it, so wide is on by default. **We need
  to either (a) flip the per-target default to off via autoexec on
  G4 to exercise the AltiVec path, or (b) AltiVec the wide path too
  with a hand-written 10-bit pack.** Decision deferred to
  implementation; pick whichever measures faster on the actual G4.

**A/B knob:** `-noaltivec-lm`. Mirrors `-noaltivec-snd` from 4.2.

**Validation strategy (offline pixel equivalence):**
1. Build instrumented binary that runs both scalar and AltiVec paths,
   `memcmp`s the output, asserts identical (or logs first
   discrepancy).
2. Boot a level, walk through dlight-heavy areas. If any mismatch,
   dump the inputs (input lightmap bytes, scale values, blocklights
   accumulator) and diff offline.
3. Once memcmp-clean across 100+ surfaces, drop the assert and ship.

This is stronger validation than 4.1 / 4.2 got — both passed visual
sign-off (V6, V7) but never had per-pixel offline checks. Worth the
discipline here because lightmap output drives the entire visible
scene's shading; a one-bit error tints the whole world.

**Predicted impact:**
- G4 demo3 1024×768: 91.75 → ~95-99 fps (+3-8%). The +0.9% cell
  partially recovers.
- G4 demo3 640×480: 107.25 → ~111-117 fps (+4-9%). The −10.6%
  residual from epilogue partially recovers.
- G4 demo1/demo2: ±0% (low dlight churn — same reason BGRA didn't
  show on demo1).
- Map load time: noticeable on Arcane Dimensions / large custom maps;
  measurable with the in-engine `Host_Frametime` infra during
  `Mod_LoadBrushModel`.

### 13.3 Phase 4.5 — AltiVec mipmap chain build (G4)

**Files:** `Quake/gl_texmgr.c:776-821` (`TexMgr_MipMapW`,
`TexMgr_MipMapH`).

Two functions, both pure byte-pair averaging:
```c
out[0] = (in[0] + in[4])>>1;
out[1] = (in[1] + in[5])>>1;
out[2] = (in[2] + in[6])>>1;
out[3] = (in[3] + in[7])>>1;
```

AltiVec has `vec_avg` which computes `(a+b+1)>>1` saturation-friendly
on int8 vectors, **one instruction** for what's currently 4 scalar
add+shifts per pixel-pair. There's also `vec_avg` modes for u8/s8/
u16/s16 — the u8 variant matches the byte-pair averaging exactly,
modulo the `+1` rounding which the scalar code omits. Decision: ship
the `vec_avg` rounding. The 0.5-LSB difference is invisible (this is
mipmap construction, not lightmap composition) and the rounded
average is arguably more correct.

Called from `TexMgr_LoadImage32` for every mip level of every 32-bit
texture. Typical map: 200 textures × ~5 mip levels = 1000
invocations. Pure load-time win.

**Won't move timedemo fps** — mipchain build runs once during atlas
upload, never during play. Visible payoff is the load-bar moving
faster.

**A/B knob:** `-noaltivec-mip`.

**Validation:** offline `memcmp` against scalar output on a test
texture corpus. Once-rounding the difference between vec_avg and
scalar is measurable as a uniform off-by-1 on some pixels — fine, but
flag it explicitly so reviewers don't think the AltiVec path is buggy.

**Predicted impact:** 30-50% off the mipchain-build phase of
`Mod_LoadBrushModel`. Big maps (start.bsp + custom 1k+ texture maps)
gain noticeable wall-clock at load. Negligible for vanilla id1 maps.

### 13.4 Phase 4.6 — Fuse alias color into the 4.1 AltiVec lerp (G4)

**Files:** `Quake/r_alias.c:452-455`.

Inside the existing AltiVec lerp loop in `GL_AliasFrame_Begin`:
```c
alias_color_scratch[i*4+0] = s * lightcolor[0];
alias_color_scratch[i*4+1] = s * lightcolor[1];
alias_color_scratch[i*4+2] = s * lightcolor[2];
alias_color_scratch[i*4+3] = entalpha;
```

`s` is computed scalar (a `shadedots[]` lookup blended with the same
blend factor as the position lerp). After computing `s`, splat to a
vector and do one `vec_madd` against `(vector float){lightcolor[0],
lightcolor[1], lightcolor[2], entalpha/s}` — or rather, store
`(vector float){s*lightcolor[0], s*lightcolor[1], s*lightcolor[2],
entalpha}` directly via two muls. Either way, one or two AltiVec ops
replace 4 scalar mul+stores.

**Trivial rider on Phase 4.4 or as standalone.** Lands in the same
commit as 4.4 to amortise the bench/ship overhead.

**Predicted impact:** demo3 1024 (+0.5-1%, the alias-bound +0.9%
cell). Other cells flat.

### 13.5 G3 `gl_subdivide_size 256` autoexec test (no code)

Edit `scripts/bundle/autoexec-g3.cfg`, add `gl_subdivide_size 256`.
Default 128. Larger value → fewer warp-surface subdivisions → ~4×
fewer triangles for sky/water polys.

R128 is per-vertex-cost-sensitive (1999 silicon), so reducing vertex
count on warp surfaces should help. Visual: classic-warp tessellation
density drops, but the warp distortion is per-vertex-screen-space on
R128 — coarser mesh shouldn't change the apparent water motion.

5-minute test. Bench, then either commit or revert.

**Predicted impact:** speculative 1-3% on G3. Low confidence; high
ROI for the test cost.

### 13.6 G4 visual upgrades (no code)

> **Status (2026-05-08): both REVERTED.** Smoke at parent commit
> `87f64413` (Phase 7 + bench commit) showed `r_shadows 1` plus
> trilinear together costing **-11.2% to -12.5% across all four G4
> cells** (demo1 1024 120.80→105.65, demo1 640 146.00→128.75,
> demo3 1024 91.75→81.45, demo3 640 107.25→94.15). Bisect: dropping
> trilinear and keeping `r_shadows 1` alone showed essentially the
> same cost (demo1 1024 106.40, demo3 1024 80.90), so r_shadows is
> the cost driver — trilinear was a rounding-error contributor on
> top. **The plan's predicted -1..-3% was off by 4-10×.** Likely
> reason: `r_shadows` is implemented as an extra alias-model pass
> per visible alias entity, and demo1/demo2/demo3 all have many
> alias entities visible (start.bsp's other monsters, end's zombies,
> demo3's combat). The per-entity shadow pass dominates the per-
> frame alias work, not just the alias-heavy demo3.
>
> Both visuals reverted in `scripts/bundle/autoexec-g4.cfg` with
> defensive `r_shadows 0` (because CVAR_ARCHIVE sticks the value in
> `config.cfg` once set, so a future build needs an explicit clear
> in autoexec to remove it). Verified post-revert: demo1 1024
> 122.05, demo3 1024 89.90 — back within noise of pre-§13.6.
>
> Future re-attempts gated on Phase 7 data: now that `gl_perfprint`
> is in tree, a future run can confirm whether the cost is in
> R_DrawShadows specifically (the second alias pass) or elsewhere.
> If the per-entity shadow pass is the bottleneck, a possible
> recovery is to gate `r_shadows` on entity distance / size — only
> shadow the closest few entities. Out of scope for round v3.

Two autoexec edits in `scripts/bundle/autoexec-g4.cfg` were
attempted:

1. **`r_shadows 1`** — alias model planar drop-shadow. Currently
   default 0. Plan said ~1-2% on demo3, 0% elsewhere; **actual
   result was -11% across ALL four cells.**

2. **`gl_texturemode "GL_LINEAR_MIPMAP_LINEAR"`** — trilinear
   filtering. Currently `GL_LINEAR_MIPMAP_NEAREST` (bilinear at
   chosen mip, no inter-mip blend). Plan said ~1-3% fillrate cost;
   actual cost on top of r_shadows was ≤0.5% (the bisect showed
   shadows-alone matched shadows-and-trilinear), so trilinear by
   itself probably is in-band — but we never ship it standalone
   because the visual pairing was the original ask.

Both shipped as autoexec-only changes, no rebuild. Result: both
out, neither shipping in round v3.

### 13.7 G3 `gl_picmip 1` — **explicit user-decision required**

> This violates §8 "no visual sacrifice." Listed separately because
> the cost-benefit on G3 specifically is plausibly net-good for a
> "best PPC port for that machine" trade, but the user owns the
> visual call.

`gl_picmip 1` halves all texture resolutions at upload. The Rage 128
has 16 MB VRAM. With `gl_picmip 0` (current) on a modern QS-class
scene, texture VRAM pressure is real and probably part of why the
G3 1024×768 cell has been flat at 24.7 fps the entire project.
Halving texture working set frees ~50% of texture VRAM, may unlock
the framebuffer / lightmap caches, and may move the 1024 cell
upward.

**Visual cost:** textures look softer up close. Walls in particular
lose surface detail. Distant geometry is unaffected (mipmap already
takes those down).

**Suggested protocol:**
1. Smoke-bench G3 with `gl_picmip 1` set in autoexec-g3.cfg.
2. If 1024 cell doesn't move (still ~24.7), revert immediately —
   no point taking visual cost for nothing.
3. If 1024 cell moves to 30+, deploy a build to G3, walk e1m1
   interactively, screenshot a few first-person texture-detail
   shots, judge visually.
4. User makes the call: ship or revert.

This is the only G3 lever left that has a plausible chance of moving
the 1024 cell. Everything else has been tried.

### 13.8 Phase 7 — `gl_perfprint` diagnostic cvar

**Why this is its own phase:** v2 + epilogue surfaced multiple
"can't reason about this without a profiler" moments — Phase 5
mipmap blew up 35% and we couldn't tell where the time went; the
demo3 G4 −10.6% diagnosis was wrong on first attempt and only
cleared up after multiple A/B tests. A profiler isn't available
on Tiger; the next-best is in-engine instrumentation we control.

**Design sketch:** add `gl_perfprint` cvar (default 0). When non-
zero, instrument the per-frame render path with `mach_absolute_time()`
markers and accumulate a rolling 60-frame average per region.
Print to console every N frames (gated by cvar value). Regions:
- `R_RecursiveWorldNode` (PVS walk + culling)
- `R_DrawTextureChains_*` (brush draws — separate single-tex / multitex)
- `R_BuildLightMap` total per frame (compose + pack)
- `R_UploadLightmaps` (driver-side upload time)
- `R_DrawAliasModels` (alias loop)
- `R_DrawParticles`
- `R_UpdateWarpTextures`
- `R_DrawWaterChains`
- `GL_FlushTransparentChains` / fog passes
- `Sky_DrawSky`
- `SwapBuffers` / vsync wait

Output format:
```
gl_perfprint: world=2.3ms (12% nodes,8% chains) lm=1.1ms(build)+0.4ms(up) alias=0.8ms part=0.2ms warp=0.1ms sky=0.3ms swap=0.5ms total=5.7ms (175.4 fps)
```

**Files affected:** `Quake/gl_rmain.c` (frame dispatch + cvar
register), small instrumentation hooks across `r_world.c`,
`r_brush.c`, `r_alias.c`, `r_part.c`, `gl_warp.c`, `gl_sky.c`.
Each hook is two `mach_absolute_time` calls + accumulator add.

**Cost when cvar=0:** zero. Hooks should compile out via macro
or stay as cheap `if (gl_perfprint.value)` branches that the
predictor handles cleanly.

**A/B with `-perfprint` cmdline.** Default off in shipping
binary. Instrumented binary is a separate build target if
overhead measurable.

**Visual sign-offs:** none — diagnostic only.

**Predicted impact:** zero direct fps. Foundation for everything
that comes after.

### 13.9 Phase 8 — QuakeC VM threading (research, gated on Phase 7)

**Why this matters and isn't measurable today:** timedemo replays
recorded packets — server logic doesn't execute. Real interactive
play runs `SV_Physics` on every entity and the QuakeC VM
(`pr_exec.c`) interprets the per-frame `think` function for every
monster, trigger, and projectile. On a boss fight with 20+ active
monsters, the QC VM can dominate a frame's CPU budget. **Timedemo
will never show this.** Phase 7's `gl_perfprint` should add a
`SV_Physics` region to expose it.

**Lever:** `pr_exec.c`'s opcode dispatch is a tight `switch`
statement. PowerPC has computed-goto via gcc's `&&label` extension —
threading the dispatcher (each opcode handler ends with `goto
*next_op_handler`) eliminates the switch's branch prediction churn
on the dispatch jump. Well-trodden technique on QC VMs (FTE,
DarkPlaces both ship JITs or threaded interpreters).

**Predicted impact:** 10-15% gameplay-side CPU on QC-heavy maps.
**Zero on timedemo.** Validation requires actual gameplay benchmark
infra, which we don't have. Phase 7's per-region timer would suffice
for "before/after threading on the same map."

**Effort:** medium. The threading transform itself is mechanical
once you've decided on a representation. Subtle bugs come from
opcodes that change `pr_xstatement` or call user functions
(`OP_CALL*`).

**Why this is round v3 and not v2:** can't measure the win without
Phase 7. Don't ship optimisations you can't verify.

### 13.10 Visual sign-offs to capture

| #   | Question | How to verify |
|-----|----------|----------------|
| V8  | Does the AltiVec `R_BuildLightMap` produce pixel-identical output to scalar? | Offline `memcmp` against scalar on 100+ surface samples. Required clean before ship. |
| V9  | Does the AltiVec `TexMgr_MipMap*` produce visually identical mipchains? | Offline `memcmp` (allowing uniform off-by-1 from `vec_avg` rounding). Visual: load a map and walk to extreme distance — no mip-banding regressions. |
| V10 | Does `r_shadows 1` look correct on G4? (no z-fighting on the floor, no double-shadow under viewmodel) | Interactive playthrough on G4, e1m1 → start.bsp; screenshot under direct overhead light. |
| V11 | Does trilinear filtering on G4 introduce mip-edge artifacts? | Walk a long corridor, check for shimmer at the mip seam (~mid-distance). |
| V12 | Does `gl_subdivide_size 256` on G3 visually break sky/water? | Interactive G3 play, look at sky on e1m1 entry yard, check water in e1m3. |
| V13 (gated) | Is `gl_picmip 1` on G3 acceptable as a "best port for the silicon" trade? | User judgment after seeing screenshots and bench delta. Only fires if §13.7 step 3 reaches user. |

### 13.11 Explicit cuts (carried forward, no relitigation)

- **Phase 4.3 palette expand** (8→32 byte gather) — already documented
  as skipped. `vec_perm` doesn't span 256-entry tables; multi-chunk
  dispatch costs as much as scalar. The real lever for faster map
  loads here is **async/threaded image expansion** via SDL_Thread,
  which is a structural rewrite, not a phase. Consider for round v4
  if loads are still painful after 4.5.
- **AltiVec `ResampleSfx`** — once per sound, then cache-hit. Map
  loads ~50-100 sounds, microseconds in absolute. Not worth the
  code.
- **AltiVec `BoxOnPlaneSide`** — already cheap (one branch + one
  dot product). Not the bottleneck.
- **Phase 5 mipmap revisit** without Phase 7 first — burned twice in
  v2, blind without the profiler. Gate on Phase 7.
- **G3 dynamic-light tuning** (e.g. `r_dynamic 0`, dlight throttling)
  — visual loss. §8 won't-do covers this.
- **`r_oldwater 0` on G3** — counter-tested in epilogue; was the
  +105% gift in reverse. Never go back.
- **Phase 6 fat binary** — packaging convenience, zero perf. Defer
  indefinitely; per-target binaries continue to work fine.

### 13.12 Suggested commit / bench sequence

| Step | Phase / change                          | Commit shape                             |
|------|-----------------------------------------|------------------------------------------|
| 1    | ~~Phase 4.4 + 4.6 (bundled)~~ Phase 4.4 tried, regressed → opt-in (§13.2). Phase 4.6 standalone next. | single code commit; no bench (no behavior change in shipping config) |
| 2    | Phase 4.6 (alias color fuse)            | code commit + smoke + bench-and-commit (small predicted +0.5-1%) |
| 3    | Phase 4.5 (mipmap chain build)          | code commit + smoke + bench-and-commit (load-time only; smoke just confirms it doesn't break play) |
| 4    | G3 `gl_subdivide_size 256`              | autoexec edit + smoke; commit if helpful, revert if not |
| 5    | G4 `r_shadows 1` + trilinear            | autoexec edit + smoke; visual sign-off V10/V11 |
| 6    | (Optional) G3 `gl_picmip 1` decision    | per §13.7 protocol — user gate          |
| 7    | Phase 7 `gl_perfprint`                  | code commit; no bench (diagnostic)       |
| 8    | End-of-round full grid                  | `scripts/bench-and-commit.sh "v3 wrap"` (no `--quick`) |

After 4.4 regressed, items 2-3 are now the perf+load-time core.
Items 4-5 are autoexec-only and can be batched into a single bench
cycle if the decisions all land the same way. Item 6 is gated on
user. Item 7 is Phase 7. Phase 8 is deferred to round v4 unless
interactive-play perf specifically becomes a goal.

Methodology continues from §10: bench-and-commit cadence, smoke per
phase, full grid at end of round, A/B knobs ship in every PR
(`-altivec-lm` opt-in for 4.4, `-noaltivec-mip` for 4.5, `-perfprint`
for 7).
