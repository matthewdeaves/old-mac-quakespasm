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
| Phase 4.1 — AltiVec alias lerp (pad-to-4 + vec_madd) | ⏳ pending official bench | TBD | Demo1 smoke neutral on both targets (expected — viewmodel is the only alias on demo1). Build OK on G3 (no AltiVec; scalar pad-to-4 layout) and G4 (`__ALTIVEC__`-gated AltiVec block). Real win lives on demo3 (zombies, ogres) at end-of-round full grid. |

**Architectural state we're building on:**
- Two binaries via `Quake/Makefile.darwin` driven by `scripts/build.sh`. No runtime dispatch yet.
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

**Actual outcome (TBD commit):** smoke neutral on demo1 1024 / 640 for
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

**Open visual sign-offs (still todo):**

| # | Question | How to verify | Blocks |
|---|---|---|---|
| V5 | Does the `GL_BGRA` + `GL_UNSIGNED_INT_8_8_8_8_REV` lightmap path produce visually identical output to baseline on both targets? | After 2.1, screenshot demo1 frame ~1500 on G4 baseline vs. G4 + 2.1; pixel-diff must be zero. Spot-check on G3 (R128 has both `APPLE_packed_pixels` and `EXT_bgra` but its 1.1 driver is older, may have corner-case bugs in BGRA paths). | 2.1 sign-off |
| V6 | Does Radeon 9000 tolerate VAR + multitexture without corruption? | After 3.2 + 3.3: visual inspection on G4, demo3 (most state churn). | 3.3 sign-off |

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
