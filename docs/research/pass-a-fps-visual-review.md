# QuakeSpasm PPC port: Pass A code review (round v3 wrap)

> Research-only sweep, 2026-05-08. Goal: surface unexploited fps + visual
> opportunities not covered by §0/§13 of `PPC_PLAN.md`. No code written;
> findings only. Ranked recommendation list at the end.
>
> Hot-target files inspected: `Quake/gl_texmgr.c`, `Quake/r_brush.c`,
> `Quake/r_world.c`, `Quake/r_part.c`, `Quake/r_alias.c`, `Quake/gl_warp.c`,
> `Quake/gl_sky.c`, `Quake/gl_rmain.c`, `Quake/gl_rmisc.c`, `Quake/gl_screen.c`,
> `Quake/gl_vidsdl.c`, `Quake/gl_model.c`, `Quake/mathlib.c`, plus the captured
> GL extension lists in `benchmarks/gl-info/` and the Lion qconsole log
> for runtime extension confirmation.

---

## 1. Unexploited GL fast paths

### 1a. `GL_BGRA` + `8_8_8_8_REV` for **all** texture uploads (not just lightmaps)

**Item:** Convert `TexMgr_LoadImage32` upload path to BGRA + 8888_REV.
**Targets:** g4, lion (both expose `EXT_bgra`); g3 also exposes `EXT_bgra` so it works there too.
**Mechanism:** `Quake/gl_texmgr.c:1280,1300` upload world textures, alias model skins, particle textures, sky textures via `glTexImage2D(..., GL_RGBA, GL_UNSIGNED_BYTE, data)`, Apple's documented slow swizzle path. Phase 2.1 already proved BGRA + 8888_REV is faster on this stack for lightmaps; the same swap on `TexMgr_LoadImage32` covers every static texture in the engine. Source data layout in memory is the same after Phase 2.1's lightmap fix; we'd need a one-time byte swap during the 8→32 expansion in `TexMgr_LoadImage8` (or simply update the palette table `d_8to24table[]` to BGRA byte order, fixing all callers in one place).
**Impact prediction:** Load-time only (textures upload once per map), but Apple's guidance says the upload itself is faster per-byte; visible payoff is **shorter map-load wall-clock** on G3 and G4, material on big custom maps. **Zero per-frame fps change** (Phase 2.x already covered the only per-frame texture upload). Visual: bit-identical.
**Effort:** small, palette init reorder + format constant swap.
**Risk:** medium, `d_8to24table` is consumed by ~15 sites including the alias renderer's color array (which packs `d_8to24table[p->color]` into `part_col_scratch` per particle quad). Changing byte order there invisibly miswires particle colors. Has to be done top-down, all sites in one commit, with screenshot diff against baseline.
**Toggleability:** `-norgba2bgra` cmdline; defaulted on.

### 1b. `GL_APPLE_client_storage` + `GL_STORAGE_CACHED_APPLE` on **static** textures (not just lightmaps)

**Item:** Extend Phase 2.2 + 2.3 from per-frame lightmaps to all static textures uploaded via `TexMgr_LoadImage32`.
**Targets:** g4, lion (both have `APPLE_client_storage` and `APPLE_texture_range`); g3 has client_storage but not texture_range, so storage-hint half is no-op on G3.
**Mechanism:** Set `GL_UNPACK_CLIENT_STORAGE_APPLE = GL_TRUE` around the `glTexImage2D` calls in `TexMgr_LoadImage32`. For long-lived textures (which all map textures are, they live in the model's hunk allocation until `Mod_ClearAll`), the no-copy path saves the per-texture upload memcpy. Combined with `GL_STORAGE_CACHED_APPLE` per-texture hint after upload, the driver should keep them VRAM-resident.
**Impact prediction:** Load-time wall-clock improvement (skipped memcpys during atlas upload). **Per-frame fps:** uncertain, depends on whether the Radeon 9000 driver pre-caches static textures already. If it does, no win. If we're getting cache misses on world textures (possible on demo3 where ~200 world textures + many model skins exceed VRAM), real win. **G3 most-likely beneficiary**, Rage 128 has 16 MB VRAM and the entire texture working set on a vanilla Quake map is close to that. Pinning client_storage means the engine's RAM copy is the canonical, freeing some VRAM pressure indirectly.
**Effort:** small (mirror the Phase 2.2 pattern).
**Risk:** medium, same lifetime concern as Phase 2.2 (driver follows our pointer after `TexMgr_FreeTexture`). Need to ensure `Mod_ClearAll` runs after we delete the GL texture, not before. Currently it's free-then-tex-delete in some paths. Audit needed.
**Toggleability:** `-noclientstorage-static` cmdline.

### 1c. `APPLE_object_purgeable` for VRAM management on G4 + Lion

**Item:** Mark unused-this-frame textures purgeable so the driver can evict under memory pressure.
**Targets:** g4 (Radeon 9000), lion (GMA 950), but **needs a probe**, not in the captured `g4-radeon9000-tiger.txt` extension list. Untested whether 10.4/10.7 expose it on these GPUs. Likely not on Tiger; Apple introduced the API publicly around 10.5.
**Status:** Untested, would need a probe on the actual machine. If it's only available on Lion/10.7 and not Tiger/10.4, the asymmetry isn't worth the engine-side bookkeeping.
**Recommendation:** **DROP** unless someone wants to spend an hour probing. Almost certainly not present on Tiger; G4 is the only target where VRAM pressure matters most.

### 1d. `EXT_texture_compression_s3tc` on G4 (already cut in §8)

§8 of PPC_PLAN.md cuts S3TC on visual-quality grounds (block artifacts on character textures). With the goal pivot, **revisit selectively**: world brush textures (rocks, walls, metal panels) can absorb DXT1 compression near-invisibly at typical Quake screen sizes; alias model skins (player, enemies) cannot. A per-texture decision (DXT only `texinfo->texture` lump entries, not `aliashdr->gltextures`) would free 50-75% of VRAM with a **~5% visual cost only on close-up walls**. This is on the table again under the goal pivot, but it's structural enough (touching the texmgr policy) that I rank it below 1a/1b. **G3 doesn't have S3TC, so G4-only.**
**Toggleability:** `-s3tc-world` cmdline.

### 1e. `APPLE_fence` for tighter sync: **skip**

Available on both G3 and G4, but used to insert app-controlled fence points so you can know when the GPU is past a draw call. Useful for readback-heavy code (we don't have any) or for `glCopyTexSubImage2D` followed by sampling that texture next frame (we have one, in `R_UpdateWarpTextures` at `gl_warp.c:284`). Replacing implicit GL synchronization with explicit fences typically helps on tile-based GPUs (Radeon 9000 isn't), and the warpimage copy is once-per-warp-texture-per-frame, small absolute time. **Don't pursue.**

### 1f. `ARB_pixel_buffer_object` / `APPLE_pixel_buffer`: needs investigation

G4 has both `ARB_pixel_buffer_object` and `APPLE_pixel_buffer`; G3 has only `APPLE_pixel_buffer`. PBOs let `glTexSubImage2D` source from a GPU buffer object, decoupling the upload from the render thread. **Could replace the lightmap upload Phase 2.x stack** with a fundamentally different path: write into a mapped PBO instead of `lightmaps[i].data`, then unmap + glTexSubImage2D. This is the post-Apple-fast-path canonical pattern.
**Targets:** g4 (real win possible); g3 has the extension but on GL 1.1 with an old driver, behavior is uncertain.
**Impact prediction:** speculative +2-5% on G4 demo3 (dynamic-light heavy). The Phase 2 stack already extracts most of the upload-side win; PBO might or might not stack on top. **Need a profiler trace from Phase 7 first** before committing.
**Effort:** medium, touches the same `R_BuildLightMap` → `glTexSubImage2D` plumbing as Phase 2.x.
**Risk:** medium-high, interaction with `client_storage` is undefined; one of the two has to win. This is a "redo Phase 2 with different transport" not a "stack on top of Phase 2."
**Toggleability:** `-pbo-lightmaps` cmdline.
**Recommendation:** **defer to round v4**, gate on Phase 7 data showing lightmap upload is still a measurable cost.

---

## 2. Per-frame compute hot paths we haven't AltiVec'd

### 2a. `R_AddDynamicLights` (Quake/r_brush.c:975)

**Item:** AltiVec the per-texel attenuation loop.
**Targets:** g4 only.
**Mechanism:** Inner loop at `r_brush.c:1031-1051` does `dist = max(sd, td) + min(sd, td)/2` then `if (dist < minlight) bl[0..2] += brightness * cred/cgreen/cblue`. Outer loop walks `tmax` rows, inner walks `smax` cols (typically 16-256 texels). Per texel: 2 abs, 1 max-with-shift, 1 conditional, 3 float multiply-add against an int accumulator. **Vec-shaped but with a branch:** the `if (dist < minlight)` is the obstacle. AltiVec way: compute the conditional add as `mask * brightness * color`, where `mask` is `vec_cmplt(dist, minlight)` extended to 3-channel. Replaces conditional scalar add with always-add-of-masked-value, ~5 vector ops per texel.
**Impact prediction:** demo3 G4 1024 +1-3% (the 91.75 cell, dlight-affected surfaces dominate that demo). Compounds with Phase 4.4 if 4.4 is ever revived (the two run back-to-back per dirty surface).
**Effort:** medium, the conditional-mask AltiVec idiom is well-known but needs care with `int` accumulators (`bl` is `unsigned int *`, so the brightness×color result has to land via vec_mladd into ints, not floats). Per the build-warning-survey perf hint, gcc-4.0's auto-vectorizer fails here too, confirming manual AltiVec is the only path.
**Risk:** low-medium. Phase 4.4 already learned that lightmap inner-loop AltiVec can regress because the per-iteration overhead exceeds the per-texel saving on small surfaces. Same risk applies here. Mitigation: same `size >= N` threshold gate as 4.4 used.
**Toggleability:** `-altivec-dlights` cmdline; default off until measured net positive (mirror 4.4's opt-in default).

### 2b. `CL_RunParticles` (Quake/r_part.c:720)

**Item:** AltiVec the position/velocity update loop.
**Targets:** g4 only.
**Mechanism:** Per active particle, line 762-764 does `p->org[0..2] += p->vel[0..2] * frametime`. Then per `p->type` switch updates `p->vel` (3-4 multiplies + grav add). Particles are stored in a singly-linked list (`particle_t::next`), so memory access is **non-contiguous**, a fundamental AltiVec hostility. Even though the math is float3-shaped, the gather-by-pointer-chase dominates. Could AltiVec the per-particle work itself (load org+vel as two float3s, vec_madd, store back) but the load+store crosses cache lines per particle.
**Verdict:** **vec-hostile in current data layout.** Would require restructuring `particle_t` from a linked list to a packed array first, multi-week refactor, probably not worth.
**Drop.**

### 2c. `Mod_DecompressVis` (Quake/gl_model.c:139)

**Item:** AltiVec the RLE-zero-run PVS decompression.
**Targets:** g4 only.
**Mechanism:** Walks input bytes, copies non-zero through, expands zero runs (`*in++ = 0; c--` × N) into output. **vec-hostile**: RLE decompression has data-dependent branching at every input byte; the per-byte work is one compare-or-store. AltiVec can't accelerate the dispatch.
**Verdict:** **vec-hostile.** Drop.

### 2d. `R_RecursiveWorldNode` / `R_MarkSurfaces` cull math (Quake/r_world.c:131-160)

**Item:** AltiVec the frustum-cull dot products.
**Targets:** g4 only.
**Mechanism:** Inside `R_MarkSurfaces` (replacement for the old recursive walk), per leaf and per surface we call `R_CullBox` which does 4 frustum planes × 1 dot product each (`gl_rmain.c:416`). Per dot: 3 mul + 2 add + 1 cmp. AltiVec: 4 planes × 4 floats fits a vector, **and** the box vertex (`vec[0..2]`) can splat against it. One `vec_madd` + `vec_madd` + `vec_madd` does 4 plane dot products simultaneously, reducing 4 sequential dot products to ~3 vector ops. Also benefits `R_CullModelForEntity` (each visible entity).
**Impact prediction:** Demo1 has ~400 visible leaves on a typical PVS = ~1600 dot products per frame for `R_CullBox`. At ~10 ns each scalar (G4 7400), that's 16µs/frame. AltiVec'd to 3 ops × 4ns = ~5µs. **Saves ~11µs/frame = +0.1% at 100 fps.** Negligible.
**Verdict:** vec-shaped but **not-worth**, frustum cull isn't the bottleneck on either target. Drop.

### 2e. `R_DrawAliasFrame` post-Phase-4.1: index walk & color packing

**Item:** Re-examine remaining alias work after the lerp.
**Targets:** g4 only.
**Mechanism:** After Phase 4.1 + 4.6 cover the lerp + color compute, what's left in `r_alias.c:629`-on (`GL_DrawAliasFrame`) is `glDrawElements` against `paliashdr->indexes` plus the `glVertexPointer` setup. The **index walk** is driver-side now, nothing for the CPU to do. The **color array submission** is `glColorPointer (4, GL_FLOAT, 16, alias_color_scratch)`; the array is filled by Phase 4.6's fused mul, and consumed by GL. No more per-vert CPU work between 4.6's vec_madd and the driver. **Already tight.**
**Verdict:** Phase 4.x covers everything available here. Drop.

### 2f. **NEW**: `BuildSurfaceDisplayList` per-vertex DotProduct (Quake/r_brush.c:613,616)

**Item:** AltiVec the per-vertex texcoord computation at level load.
**Targets:** g4 only.
**Mechanism:** For every world surface vertex, compute `s = DotProduct(vec, texinfo->vecs[0]) + s0; s /= sdiv;` and same for t. Two scalar dot products + two divides + scalar copy of position. Per typical Quake map: ~5,000 surfaces × ~6 verts each = ~30,000 vert iters. With 4 floats per dot + 1 splat for sdiv/tdiv inverse, this is a clean SoA-friendly target IF we pad `texinfo->vecs[0..1]` to vector alignment.
**Impact prediction:** Load-time only. Bigger absolute saving than 4.5 mipmap (6× fewer iterations but ~10× the per-iter work). **Better load-time payoff than 4.5; same scope.**
**Effort:** small, drop a `#ifdef __ALTIVEC__` block around the loop body in the same shape as Phase 4.1.
**Risk:** low.
**Toggleability:** `-noaltivec-bsl` cmdline.

### 2g. **NEW**: `R_LightPoint` per-frame (Quake/gl_rlight.c)

**Item:** Re-check vector-shaped work in the alias entity lighting calculation.
**Targets:** g4 only.
**Mechanism:** Called once per visible alias entity (~10-30/frame on demo3) in `R_SetupAliasLighting`. Walks BSP to find the lightmap value at the entity origin. Tree walk = vec-hostile; the per-leaf work is small. **Skip.**

### 2h. **NEW**: `R_RotateForEntity` matrix push (per-entity: per-frame)

**Item:** Cache the rotation matrix on entities that don't move pose.
**Targets:** all three.
**Mechanism:** `gl_rmain.c:R_RotateForEntity` calls `glTranslatef + glRotatef × 3 + glScalef`. Driver builds the matrix from these. For **static map entities** (lights, ammo, decorations) the angles don't change between frames; we could compose the matrix once, cache it on `entity_t`, and `glMultMatrixf` instead. Saves driver-side matrix composition, typically a couple of µs per entity. demo1 has ~50 static entities visible at most points.
**Impact:** small (<1%) but free if it works. Lion may benefit most (driver overhead dominant on Intel-on-Apple stack).
**Effort:** small.
**Risk:** low.
**Toggleability:** `-cachetransform` cmdline.

---

## 3. Visual upgrades we haven't shipped

### 3a. Anisotropy 16x on G4 (Radeon 9000)

**Item:** Bump `gl_texture_anisotropy 8` → 16 in `autoexec-g4.cfg`.
**Targets:** g4 (probable), lion (almost certain, GMA 950 supports 16x per the autoexec-lion.cfg comment).
**Mechanism:** Cvar edit. The driver clamps to `gl_max_anisotropy` (GL 1.4 path). Radeon 9000 GL 1.3 driver, **untested whether 16x is supported**, would need to log `GL_MAX_TEXTURE_MAX_ANISOTROPY_EXT`. If it caps at 8x, the cvar set to 16 silently clamps to 8 (engine code at `gl_texmgr.c:188` does this).
**Impact prediction:** g4 -1-3% (additional fillrate cost on glancing-angle samples); lion -2-4%. Visual: tighter texture sharpness at glancing angles, most visible on long corridors. Both targets stay above the 60 fps floor.
**Effort:** trivial (cvar edit).
**Risk:** low.
**Toggleability:** already a cvar.

### 3b. `gl_flashblend 0` is correct default: DON'T flip

`gl_flashblend 1` replaces dynamic lighting with a billboard glow sprite at the explosion source. Faster but **visually worse** (no light splash on walls). With `r_dynamic 1` shipping default and the goal pivot prioritising visuals, `gl_flashblend 0` is the right call. **Document this, current default is already correct.** Don't flip.

### 3c. `r_waterquality` higher (default 8)

**Item:** Bump `r_waterquality` to 16 or 32 on G4 + Lion.
**Targets:** g4 (with `r_oldwater 0`), lion (with `r_oldwater 1`, only affects water surface tessellation, not shader path).
**Mechanism:** `gl_warp.c:255` clamps `r_waterquality` to [3, 64]; the value divides 128 to give the warp tessellation step. Default 8 → tess step 16 → 8x8 = 64 verts per warp surface. At 16 → 128 verts. At 32 → 256 verts.
**Impact prediction:** vert-bound, not fillrate-bound. G4 (vert pipe is fast on Radeon 9000) probably -1% at 16. Lion (no hardware T&L on GMA 950) -3-8% at 16. **Visible improvement only on `r_oldwater 1` (classic warp)**, that's where individual verts make distortion finer. With `r_oldwater 0` (new shader) the warp is per-fragment and doesn't care about tess.
**Effort:** trivial.
**Risk:** low.
**Toggleability:** already a cvar.
**Recommendation:** **G3-targeted**, bump from default 8 (currently inherited) to maybe 16, paired with `gl_subdivide_size 256` already in autoexec-g3.cfg. The classic warp is what G3 ships, so this lifts G3 visuals where it matters.

### 3d. `r_particles 1` on G4 + Lion (currently using engine default)

**Item:** Confirm/explicit-set particle quality on G4 + Lion.
**Targets:** g4, lion.
**Mechanism:** G3 ships `r_particles 2` (square). G4/Lion fall through to the engine default which is **`r_particles 1` (full anti-aliased circle, 64x64 texture)** per `r_part.c:42`. So this is **already shipping**. **Document explicitly in autoexec-g4 and autoexec-lion** so a future config drift doesn't silently regress. No actual visual upgrade available, already at max.

### 3e. GLSL alias path: **unreachable on all three targets**

**Item:** Document this dead-end so it doesn't keep coming up.
**Status:** `gl_glsl_alias_able` requires `gl_glsl_able && gl_vbo_able && gl_max_texture_units >= 3` (`gl_vidsdl.c:1410`). G3 (GL 1.1), G4 (GL 1.3), Lion (GL 1.4), **none reach GL 2.0 + VBO**. The Fitz fallback path is the only path that ever runs on our targets. Phase 4.1 + 4.6's AltiVec is the only optimisation that reaches the alias renderer.
**Recommendation:** add a comment to `r_alias.c` calling this out. The `r_alias_program != 0` test at `r_alias.c:998` is **always false on PPC + Lion**; the GLSL branch is dead code we ship.
**Implication:** the `GL_DrawAliasFrame_GLSL` function (`r_alias.c:232`-on, ~70 lines) is **kill candidate**, not even compiled-out, it's just unreachable. Stripping it would save a couple KB of code; not material to perf, but Pass B/§14.2 should flag it. Removing this block would also remove the dead static globals (`r_alias_program` etc.) from `gl_rmain.c` constructor + `gl_rmisc.c`. Recommend keep-with-comment, since restoring would be a regression.

### 3f. `r_scale 2` for retro pixellated upscale

**Item:** Document the `r_scale` cvar as a Lion-specific lever.
**Targets:** lion (most usefully).
**Mechanism:** `r_scale` (cvar at `gl_rmain.c:114`) renders the 3D viewport at 1/N resolution, then nearest-neighbour upscales for the final blit (`R_ScaleView` at `gl_rmain.c:1119`). At `r_scale 2`, 1024×768 renders 512×384. **Lion at 512×384 would explode past 200 fps and look like an authentic retro Quake.** The cvar already exists, just isn't enabled in any autoexec.
**Impact prediction:** Lion 1024 95.85 → ~150-180 fps (1024 cell becomes CPU-bound like the 640 cell currently). Visual: pixellated, deliberate retro aesthetic. Optional aesthetic.
**Effort:** trivial.
**Risk:** low.
**Toggleability:** already a cvar.
**Recommendation:** **document** in autoexec-lion.cfg as a commented-out option. Don't ship by default, the goal pivot is "best looking", not "most retro."

### 3g. `r_lerpmodels 1` + `r_lerpmove 1` are already default-on

Both default 1 per `gl_rmain.c:96-97`. Good, animation interpolation for monsters and projectiles is on. **No action needed.**

### 3h. `gl_overbright_models 1` already default-on

`gl_rmain.c:91` defaults 1. Good. No action.

### 3i. **Skybox upgrade path**: `r_oldskyleaf 0` already default

**Item:** Verify sky path. `r_oldskyleaf 0` (default) uses cloud-layer compositing with two-tex multitexture. Some texture-pak vintages have clean skybox replacements; if user has `quake/maps/<map>_*` skybox files, `Sky_LoadSkyBox` engages.
**No action, already optimal.**

### 3j. Trilinear is **already shipping** on G4 + Lion

Per autoexec-g4.cfg + autoexec-lion.cfg. Good. **G3 is on `GL_LINEAR_MIPMAP_NEAREST` (bilinear)** by default, flipping to trilinear would be a visual upgrade but the per-pixel cost is meaningful at 23 fps where every percent counts. **G3-trilinear-trial as a future round v4 candidate** if/when we find more G3 fps headroom.

### 3k. **NEW**: `gl_texturemode "GL_LINEAR"` on character/HUD textures only

**Item:** Selective non-mipmap linear filtering on UI elements.
**Targets:** all three.
**Mechanism:** `gl_texturemode` is global; HUD pics are loaded with `TEXPREF_LINEAR` already (`gl_draw.c`) so they get linear filtering. **Already optimal**. No action.

---

## 4. Cvar defaults to revisit

Reviewing `gl_rmain.c:59-114` and `gl_rmisc.c` cvar declarations, ordered by goal-pivot relevance:

| Cvar | Default | Recommendation | Rationale |
|---|---|---|---|
| `gl_finish` | 0 | **leave 0** | 1 hard-syncs CPU↔GPU per frame. Devastating to frame pipelining. |
| `gl_clear` | 1 | **leave 1** | Fillrate-cheap; without it, viewport corners may show stale frame on Lion windowed mode. |
| `gl_polyblend` | 1 | **leave 1** | Damage flash overlay is part of correct visuals. |
| `gl_flashblend` | 0 | **leave 0** | 1 = ugly billboard, no light splash. |
| `gl_overbright` | 1 | **leave 1** | Brightens lit surfaces, correct for QS. |
| `gl_overbright_models` | 1 | **leave 1** | Same for alias. |
| `gl_fullbrights` | 1 | **leave 1** | Full-bright pixels in palette (lava, lights). |
| `r_lerpmodels` | 1 | **leave 1** | Smoothed alias animation. |
| `r_lerpmove` | 1 | **leave 1** | Smoothed entity origin interpolation. |
| `r_dynamic` | 1 | **leave 1** | Removing breaks rocket lights. |
| `r_litwater` | 1 | **leave 1** | Lit water surfaces (modern QS visual). |
| `r_oldskyleaf` | 0 | **leave 0** | New sky-leaf path is faster & visually identical. |
| `r_clearcolor` | 2 | **maybe flip to 0** for fog-mapped levels | 2 is "brown" which shows at sky edges; with fog density >0, the fog covers it. Cosmetic, no perf. **Skip.** |
| `gl_smoothmodels` | 1 | **leave 1** | Gouraud shading on alias models. |
| `gl_affinemodels` | 0 | **leave 0** | 1 = perspective-incorrect texture warping (retro look but wrong on QS). |
| `gl_zfix` | 0 | **leave 0** | Off-by-default fix for z-fighting on coincident surfaces; some maps need it. Per-map decision. |
| `r_lavaalpha`, `r_telealpha`, `r_slimealpha` | 0 | **leave 0** | 0 = opaque; non-zero would show sub-surface water through lava etc., unusual. |
| `gl_subdivide_size` | 128 | G3: 256 already (good); G4/Lion: leave default | Tessellation density. G4/Lion can afford more verts. |

**Net finding:** the engine defaults are already well-tuned for "best-looking and correct." No cvar default flip stands out as a missed visual upgrade.

---

## 5. Per-platform asymmetric wins

### G3-specific (Rage 128: CPU-bound, fillrate-bound at 1024)

1. **G3 texture working set reduction (1b above + S3TC-on-world).** G3 has no S3TC extension, but the Phase 1b client_storage on world textures + the **picmip 1 trial in §13.7** is the only lever left. The user owns the picmip call. **No new lever I can find for G3 1024 specifically.**
2. **`r_lerpmodels 0` on G3 only**, would skip the per-frame alias lerp work (which Phase 4.1 didn't help on G3 because G3 has no AltiVec). Visual cost: jerkier monster animation. Goal pivot says "best looking" so **skip**.
3. **G3 `r_dynamic 0` selective**, visual loss, already cut in §13.11. **Skip.**
4. **NEW: G3 `gl_zfix 0`** is default. Some user maps need it. G3 is sensitive to per-frame draw cost; if `gl_zfix 1` is ever flipped on globally, it doubles brush submission for coincident surfaces. **Make sure config doesn't flip this on by accident**, already correct.

### G4-specific (Radeon 9000: fillrate-bound at 1024, vert-bound at 640)

1. **Anisotropy 16x trial** (3a above).
2. **Selective S3TC on world textures** (1d above).
3. **AltiVec `BuildSurfaceDisplayList`** (2f above), load-time only.
4. **AltiVec `R_AddDynamicLights`** (2a above), fps win on demo3.

### Lion-specific (GMA 950: fillrate-bound at 1024, CPU-bound at 640)

1. **Reduce overdraw at 1024**, biggest lever for Lion's GPU-bound 1024 cell.
   - **`gl_finish 0`** is already default-correct.
   - **`r_scale 2` retro option** (3f above).
   - **Frustum-cull tightening?** `R_CullBox` is per-leaf only; per-surface backface cull happens in `R_BackFaceCull` (`r_world.c:145`). Already tight.
2. **Anisotropy 16x trial** (3a above).
3. **The Lion autoexec parses 4 stray words as commands** ("16x", "expected", "smooths", "vid_wait") per `4bf1f771_lion_demo1_1024x768_run3.log:39-42`. Likely missing `//` on a comment line in the cfg or config.cfg. Cosmetic but should fix. Trace down to the cfg producing it.

---

## 6. Lurking inefficiencies

### 6a. `R_UpdateWarpTextures` glBegin in a tight loop (Quake/gl_warp.c:271)

**Item:** The water-warp procedural-texture re-draw still uses `glBegin/glEnd` per row of the warp tess. With `r_waterquality 8` that's 8 strips × 8 verts = 8 glBegin calls per warp surface per frame. If a level has 4 visible water textures, that's 32 glBegin/frame for what should be one batched call.
**Targets:** g4, lion.
**Mechanism:** Convert to client vertex array following the Phase 1.1 pattern. Texcoords change every frame (`scroll`), positions are static, same shape as `Sky_DrawFaceQuad` already converted (gl_sky.c:919).
**Impact prediction:** Lion most likely beneficiary (driver overhead dominant). +0.5-1% on cells with visible water, demo3 doesn't have water so smoke wouldn't catch it.
**Effort:** small.
**Risk:** low.
**Toggleability:** `-nowarpedarrays` cmdline.

### 6b. `R_SetupAliasLighting` per-entity `R_LightPoint` call

**Item:** Every visible alias entity does a BSP walk to find ambient light. Cached per-frame via `lerpdata`?  Not currently.
**Targets:** g4, g3.
**Mechanism:** Investigate `r_alias.c:772` (`R_SetupAliasLighting`), if the same entity is lit twice in a frame (alpha-pass + non-alpha), we walk the BSP twice. Cache in `entity_t::cachedlight` already exists (Quake `cl.h`); confirm it's used. Likely already cached. **Verify, no action.**

### 6c. `Sky_GetTexCoord` per-vertex `sqrt` (Quake/gl_sky.c:899)

**Item:** Sky cloud-layer scrolling does `sqrt(dot)` per vert.
**Targets:** g4 (and g3 already gets `frsqrte` from Phase 1).
**Mechanism:** **already covered**, Phase 1's `frsqrte` patches both `VectorLength` and `VectorNormalize`, and `Sky_GetTexCoord` calls `sqrt` directly (not via VectorLength). One patched call site missed. Tiny but free.
**Effort:** trivial. One-line `frsqrte` substitution.
**Risk:** low (sky is too coarse for precision drift to matter).
**Toggleability:** none needed (math swap).

### 6d. `Sky_DrawSkyBox` glBegin (Quake/gl_sky.c:819)

**Item:** Skybox emit still uses `glBegin/glEnd`. Six faces × one glBegin each = 6/frame, plus 6 more if `Fog_GetDensity > 0 && skyfog > 0`. **Already in Phase 1.1's "skip" list** (per PPC_PLAN.md §8 won't-do, "skybox is rasterizer-bound"). **Skip, already triaged.**

### 6e. `glColor3f`: `glDepthMask`, etc. churn in `R_DrawTextureChains_*`

**Item:** Inspect for redundant state changes within one chain pass.
**Targets:** all three.
**Mechanism:** `r_world.c` chains do per-iter `glEnable/Disable` of `GL_ALPHA_TEST` (line 459, 491) for fence textures. Hoisting "is any surface in this chain a fence?" to a chain-level decision could remove half the toggle. Phase 3.3's `R_BindBrushChain_*` already hoisted client-state for VAR; this is a similar idea for ALPHA_TEST.
**Impact:** small (<0.5%); driver state switches are cheap on these vintage GPUs.
**Effort:** small.
**Risk:** low.
**Recommendation:** **defer**, small magnitude, doesn't move the floor.

### 6f. `SCR_DrawFPS` `sprintf` per frame (Quake/gl_screen.c:471)

**Item:** When `scr_showfps 1`, sprintf runs every frame.
**Targets:** all three (only when shown).
**Mechanism:** Currently default 0; only fires when user enables. Per-frame string format is microseconds. **Ignore unless user reports HUD-on perf regression.**

### 6g. `S_ExtraUpdate` mid-frame call (Quake/gl_rmain.c:1062)

**Item:** Sound mix midway through `R_RenderScene`. Comment says "don't let sound get messed up if going slow". On AltiVec'd 16-bit mixer (Phase 4.2), this is now cheaper, but it still adds frame-time variance.
**Verdict:** **don't touch**, this is a deliberate audio glitch mitigation, not a perf optimisation site. Keep.

### 6h. **NEW**: Lion's `-O3 → -O2` downgrade (per build-warning-survey item §7.4)

**Item:** The build-warning-survey identifies that **Lion's actual optimisation level is `-O2`, not `-O3`**, because of Makefile flag ordering. Fixing this is **deferred** in the warning survey but **bench may move**. With the goal-pivot acceptance of "fps drops OK above floor", we should revisit: a Lion `-O3` actually-applied could give 2-5% on the 1024 cell (currently 95.85 → maybe 100-105 fps).
**Targets:** lion only.
**Mechanism:** Per `docs/research/build-warning-survey.md` §7 item 4: drop `-O2` from the DEBUG=0 path or have lion's CPUFLAGS not specify a level.
**Impact prediction:** speculative +2-5% Lion 1024.
**Effort:** small (Makefile.darwin tweak).
**Risk:** low.
**Toggleability:** trivial, bisectable via build flag.

---

## Ranked recommendations

### Top 5 to act on **this round** (round v3 wrap)

1. **§6h, Fix Lion `-O3 → -O2` downgrade in Makefile.darwin.**
   Speculative +2-5% Lion 1024 with no source change. Lowest risk in the list. Bench-and-commit pattern: trivial. Carries forward into round v4 anyway.

2. **§3a, Anisotropy 16x trial (G4 + Lion autoexec edit).**
   Cvar-only change. Visual upgrade for free if max anisotropy on Radeon 9000 and GMA 950 actually goes to 16. G3 untouched (driver clamps to 1). Smoke-bench, accept or revert.

3. **§2a, AltiVec `R_AddDynamicLights` (G4 only).**
   The biggest remaining per-frame compute lever on G4. Demo3 1024 is the cell that wants it. Effort medium; behind opt-in `-altivec-dlights` flag (mirroring 4.4's `-altivec-lm` opt-in default after the regression). Even if it regresses, the data feeds round v4.

4. **§6a, `R_UpdateWarpTextures` glBegin → array path.**
   Same shape as Phase 1.1 already-completed work for Sky_DrawFaceQuad. Lion's GMA 950 is driver-overhead-heavy and probably benefits most. Smoke-bench should catch any regression; risk low.

5. **§1a, BGRA palette/upload conversion in `TexMgr_LoadImage32`.**
   Phase 2.1 proved the upload speedup is real on Apple stacks. Map-load wall-clock improvement on big maps + sets foundation for §1b. Single audit-and-flip commit. Risk medium (palette table is consumed widely; needs visual diff).

### Round v4 candidates

- **§1b, `client_storage` + `STORAGE_CACHED_APPLE` for static textures.**
  Pairs with §1a; map-load wall-clock improvement. Possibly per-frame win on G3 if VRAM pressure is real.
- **§2f, AltiVec `BuildSurfaceDisplayList` per-vertex DotProduct.**
  Load-time only on G4. Larger payoff than 4.5 mipmap.
- **§1f, Pixel buffer object upload path for lightmaps.**
  Gate on Phase 7 perfprint data; could replace or augment the Phase 2 stack.
- **§1d, Selective S3TC on world textures only (G4).**
  Visual cost on close-up walls; possible 5% fillrate gain at 1024. Goal-pivot makes it reconsiderable.
- **G3 `gl_picmip 1` decision (§13.7 already drafted).**
  User owns the visual call.
- **§3c, `r_waterquality 16` on G3.**
  Pairs with classic warp; tighter water visual.
- **§3f, `r_scale 2` documented option for Lion.**
  Aesthetic; document but don't ship.
- **§2h, Cached entity transform matrix.**
  Small win, low risk, but only if a profiler trace from Phase 7 says glTranslatef/glRotatef stack is measurable.
- **Pass B kill-list followups:** `GL_DrawAliasFrame_GLSL` and its supporting globals are unreachable on every target, strip or comment-as-dead.

### Explicit drops (researched, not worth)

- §1c `APPLE_object_purgeable`, likely not on Tiger.
- §1e `APPLE_fence`, no readback path needs it.
- §2b particles, vec-hostile data layout.
- §2c PVS decompression, vec-hostile branchy RLE.
- §2d frustum cull, already too cheap to bother.
- §2g `R_LightPoint`, already cached.
- §6b, already cached.
- §6c `Sky_GetTexCoord` sqrt patch, too small (single missed site, distant sky).
- §6e ALPHA_TEST hoist, too small.

---

## Files of interest

- `/home/matt/quakespasm/Quake/gl_texmgr.c:1280,1300`, `TexMgr_LoadImage32` upload site (the GL_RGBA + GL_UNSIGNED_BYTE slow path); §1a target.
- `/home/matt/quakespasm/Quake/gl_texmgr.c:1413-1420`, already-converted lightmap upload (Phase 2.1 reference for §1a).
- `/home/matt/quakespasm/Quake/r_brush.c:975-1052`, `R_AddDynamicLights`; §2a target.
- `/home/matt/quakespasm/Quake/r_brush.c:565-650`, `BuildSurfaceDisplayList` per-vert DotProduct; §2f target.
- `/home/matt/quakespasm/Quake/gl_warp.c:246-300`, `R_UpdateWarpTextures` glBegin loop; §6a target.
- `/home/matt/quakespasm/Quake/gl_vidsdl.c:1273-1311`, anisotropy detection; §3a target's gating.
- `/home/matt/quakespasm/Quake/r_alias.c:232-298`, `GL_DrawAliasFrame_GLSL` dead code.
- `/home/matt/quakespasm/Quake/Makefile.darwin`, Lion -O3/-O2 collision (§6h).
- `/home/matt/quakespasm/scripts/bundle/autoexec-{g4,lion}.cfg`, anisotropy bump target (§3a).
- `/home/matt/quakespasm/benchmarks/raw/4bf1f771_lion_demo1_1024x768_run3.log:39-42`, Lion's 4 "Unknown command" warnings (cosmetic config bug).
