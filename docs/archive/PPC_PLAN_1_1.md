# PPC Plan 1.1: Immediate-Mode → Client Vertex Arrays + CVA

> **STATUS: IMPLEMENTED, historical record.** Shipped via commit
> `c00a07a7`. Net result: G4 +4.7% avg / +6.2% peak; G3 ±0 (driver has
> no fast path for client arrays on R128). Phase 1.1c (multitexture
> array conversion) reverted because it cost G4 −3 to −4% on
> brush-heavy demos; CVA Lock gated off on R128 for in-game color
> corruption. See `../../PPC_PLAN.md` for the next round.
>
> Archived 2026-05-07.

## Context

`PPC_PLAN.md` item 1.1 ("EXT_compiled_vertex_array, projected +20-40% on G3
640") was written assuming QuakeSpasm's legacy GL 1.x path used client vertex
arrays that CVA could lock. **It doesn't.** Every legacy draw call in the
engine is pure immediate mode (`glBegin`/`glVertex3fv`/`glTexCoord2f`/`glEnd`).
CVA wraps `glDrawArrays`/`glDrawElements`; with no array setup to lock, item
1.1 is a no-op as written.

Verified: zero matches in the codebase for `glVertexPointer`, `glDrawArrays`,
`glClientActiveTexture`, `GL_EXT_compiled_vertex_array`. The two
`glDrawElements` calls live in the GLSL/VBO path at `r_world.c:372` and
`r_alias.c`, both gated by `gl_vbo_able` / `gl_glsl_alias_able` and
unreachable on Rage 128 (GL 1.1) and Radeon 9000 (GL 1.3).

So the actual scope of "the CVA win" is two orthogonal optimizations stacked:

1. **Array conversion win**, replace per-vertex `glVertex3fv`+`glTexCoord2f`
   function calls with one `glDrawArrays` per surface. Pure CPU win, removes
   driver per-call overhead. Helps every driver. Largest beneficiary: G3 at
   640 (CPU-bound).
2. **CVA-on-top win**, wrap converted draws in `glLockArraysEXT` /
   `glUnlockArraysEXT` so the driver caches transformed verts across
   multipass (alias overbright + fullbright; multitexture passes). On G3's
   older driver, expected to recover transform cost on subsequent passes.
   May NOP on G4's modern driver.

Original 1.1 estimate was +20-40% G3 / +5-15% G4. Refined estimate (all
phases through 1.1h combined): **+27-55% G3 640 best case, +18-30%
conservative; +10-22% G4 640; minimal at 1024 (fillrate-bound)**. G3 1024 is
GPU-bound and won't move much regardless.

**Visual quality:** zero regressions. No blend modes change, no Z behavior
changes, no feature is removed. Every conversion replaces immediate-mode
dispatch with `glDrawArrays`/`glDrawElements` of the **same primitives with
the same state**. "Fast" and "beautiful" don't fight here, visual upgrades
(mipmap fallback, lit water, anisotropic on G4) are a separate plan thread
in `PPC_PLAN.md`.

## Verified facts (don't re-investigate)

- `glpoly_t` (gl_model.h:135-141) is already a flat interleaved float array,
  stride `VERTEXSIZE = 7` floats: xyz (0..2) + tex0 s,t (3..4) + lightmap s,t
  (5..6). Built once via `BuildSurfaceDisplayList` (r_brush.c:431-522);
  immutable thereafter. Static world geometry can be pointed at directly,
  no copies, no scratch.
- `gl_mesh.c:GL_MakeAliasModelDisplayLists` already builds a triangle index
  list (`hdr->numindexes` unsigned shorts at `vboindexofs`) and a deduped
  vertex map (`numverts_vbo` × `aliasmesh_t`) for the GLSL path. We can
  consume those indices from the legacy path, no loader changes needed.
- `MAXALIASVERTS = 2000` (gl_model.h:378). Caps alias scratch sizing.
- `GL_ClientActiveTextureFunc` is already loaded at gl_vidsdl.c:1033,
  declared glquake.h:169.
- Apple's GL on 10.3.9 + 10.4 is expected to expose
  `GL_EXT_compiled_vertex_array` on both Rage 128 and Radeon 9000 (predates
  ARB_VBO; universally present on GL 1.1+ install base). If absent, the
  array path still runs and we just skip the lock, graceful fallback.
- All immediate-mode call sites enumerated in this plan; no surprises in the
  hot path.

## Strategy: 7 phases: each independently buildable + benchable + revertable

| #     | Phase                                               | Files                            | Risk    | G3 640 (target)  | G4 640 |
|-------|-----------------------------------------------------|----------------------------------|---------|------------------|--------|
| 1.1a  | CVA capability detection (no draws change)          | gl_vidsdl.c, glquake.h           | trivial | 0                | 0      |
| 1.1b  | DrawGLPoly + DrawGLTriangleFan → arrays             | r_brush.c                        | low     | +3-6%            | +1-3%  |
| 1.1c  | R_DrawTextureChains_Multitexture → arrays           | r_world.c                        | low     | **+10-18%**      | +4-7%  |
| 1.1d  | R_DrawLightmapChains → arrays (cheat path)          | r_world.c                        | trivial | n/a              | n/a    |
| 1.1e  | GL_DrawAliasFrame → glDrawElements + scratch lerp   | r_alias.c                        | medium  | **+8-15%**       | +3-6%  |
| 1.1f  | CVA wrap on phases above (lock/unlock)              | r_alias.c, r_world.c             | low     | **+5-12%** extra | +0-3%  |
| 1.1g  | DrawWaterPoly → arrays + warp scratch (G3 1024 only)| gl_warp.c                        | low     | ~0 (GPU-bound)   | 0      |
| 1.1h  | Particles + sky cloud layers → batched arrays       | r_part.c, gl_sky.c               | medium  | **+2-5%** (demo3)| +0-2%  |

Phases ordered by ROI ÷ risk. Each lands as a single commit; full bench
matrix between commits per existing methodology
(`scripts/full-bench.sh both`, 3× runs, median of 2&3, both targets).

---

## Phase 1.1a: CVA capability detection

**Files:** `Quake/glquake.h`, `Quake/gl_vidsdl.c`

**Add to glquake.h** (after the VBO function-pointer block at lines 178-184):

- `QS_PFNGLLOCKARRAYSEXTPROC` and `QS_PFNGLUNLOCKARRAYSEXTPROC` typedefs
  (`QS_` prefix mirroring the GLSL block, 10.3/10.4 SDK headers may not
  provide these typedefs)
- `extern qboolean gl_cva_able;`
- `extern QS_PFNGLLOCKARRAYSEXTPROC GL_LockArraysEXTFunc;`
- `extern QS_PFNGLUNLOCKARRAYSEXTPROC GL_UnlockArraysEXTFunc;`

**Add to gl_vidsdl.c**:

- Definitions next to `gl_vbo_able` and the VBO func pointers (around line 107
  for the flag, line 118 for the pointers, locate via
  `grep -n gl_vbo_able gl_vidsdl.c`).
- Detection block in `GL_CheckExtensions` after the VBO block (around line
  1023), following the `gl_vbo_able` pattern exactly:
  ```
  if (COM_CheckParm("-nocva")) Con_Warning("CVA disabled at command line\n");
  else if (GL_ParseExtensionList(gl_extensions, "GL_EXT_compiled_vertex_array")) {
      GL_LockArraysEXTFunc   = (...) SDL_GL_GetProcAddress("glLockArraysEXT");
      GL_UnlockArraysEXTFunc = (...) SDL_GL_GetProcAddress("glUnlockArraysEXT");
      if (GL_LockArraysEXTFunc && GL_UnlockArraysEXTFunc) {
          Con_Printf("FOUND: EXT_compiled_vertex_array\n");
          gl_cva_able = true;
      }
  }
  ```

**No draws change.** Smoke test: boot, exit, confirm
`FOUND: EXT_compiled_vertex_array` appears in `qconsole.log` on both targets.

`-nocva` provides A/B testing for phase 1.1f without rebuilding.

---

## Phase 1.1b: DrawGLPoly + DrawGLTriangleFan to client arrays

**Files:** `Quake/r_brush.c:82-95` (DrawGLPoly), `:102-114` (DrawGLTriangleFan)

`glpoly_t::verts` is already in the right shape, point GL directly at it,
zero copies:

```
glVertexPointer(3, GL_FLOAT, VERTEXSIZE*sizeof(float), &p->verts[0][0]);
glTexCoordPointer(2, GL_FLOAT, VERTEXSIZE*sizeof(float), &p->verts[0][3]);
glEnableClientState(GL_VERTEX_ARRAY);
glEnableClientState(GL_TEXTURE_COORD_ARRAY);
glDrawArrays(GL_TRIANGLE_FAN, 0, p->numverts);
glDisableClientState(GL_TEXTURE_COORD_ARRAY);
glDisableClientState(GL_VERTEX_ARRAY);
```

`GL_POLYGON ≡ GL_TRIANGLE_FAN`, Quake surfaces are convex, drop-in.

Enable/disable inside the helper for this phase (self-contained,
revertable). Promoting state toggle to callers is a follow-up cleanup if
benches indicate per-poly state churn matters.

`DrawGLPoly` callers covered: `R_DrawTextureChains_Drawflat/Glow/NoTexture/
TextureOnly/Water/White`, `R_DrawLightmapChains` (when chained through),
`Sky_ProcessPoly`. All use the same `glpoly_t` shape, single change covers
all.

`DrawGLTriangleFan` (r_showtris debug path): same pattern, no texcoord
pointer. Correctness only.

**No CVA wrap in this phase**, single poly per call, no multipass, lock
overhead would dominate the 6-vert win. Defer to 1.1f.

---

## Phase 1.1c: R_DrawTextureChains_Multitexture to client arrays

**File:** `Quake/r_world.c:407-452`

Top win target. Per-vertex this path issues 3 GL function calls
(`MTexCoord2f` ×2 + `Vertex3fv`), collapsing them is most of the array win.

**Architectural choice:** per-surface arrays, no cross-surface batching. The
lightmap bind happens per surface and is the batching killer; sorting by
lightmap chain (option C2) would multiply texture binds, which are more
expensive. Stitching to a per-frame scratch buffer (option C3) is what VBOs
are for, out of scope.

**Replacement for glBegin..glEnd at r_world.c:436-444**, after the
texture+lightmap binds:

```
GL_ClientActiveTextureFunc(GL_TEXTURE0_ARB);
glTexCoordPointer(2, GL_FLOAT, VERTEXSIZE*sizeof(float), &v[3]);
GL_ClientActiveTextureFunc(GL_TEXTURE1_ARB);
glTexCoordPointer(2, GL_FLOAT, VERTEXSIZE*sizeof(float), &v[5]);
glVertexPointer(3, GL_FLOAT, VERTEXSIZE*sizeof(float), &v[0]);
glDrawArrays(GL_TRIANGLE_FAN, 0, s->polys->numverts);
```

Enable client states (`GL_VERTEX_ARRAY`, `GL_TEXTURE_COORD_ARRAY` on TMU0
and TMU1) **once at function entry**, disable at function exit. Don't
toggle per surface.

Pointer calls must repeat per surface, `glpoly_t`s are individually
`Hunk_Alloc`'d, not contiguous. 4 pointer calls vs. 18×N immediate-mode
calls is still a huge win.

**No CVA wrap in this phase**, measured separately in 1.1f. Single 6-vert
draw per surface; lock/unlock around one tiny draw is unlikely to win.

---

## Phase 1.1d: R_DrawLightmapChains to client arrays

**File:** `Quake/r_world.c:786-811`

Same shape as 1.1c, single texcoord stream (lightmap at offset +5 floats).
Trivial fold-in. Only reached when `r_lightmap_cheatsafe` set, no demo bench
movement expected. Land it for code-completeness so the immediate-mode
helpers can eventually be fully retired.

Smoke: `r_lightmap 1` in console, verify visual.

---

## Phase 1.1e: GL_DrawAliasFrame to glDrawElements + scratch lerp

**Files:** `Quake/r_alias.c:297-401` (GL_DrawAliasFrame); call sites in
`R_DrawAliasModel` at r_alias.c:633-906.

Highest design-complexity phase. Two routes considered:

- **(e1)** Preserve `aliashdr->commands` strip/fan walk; lerp into scratch
  per substrip; many small `glDrawArrays` per model.
- **(e2)** glDrawElements with the index buffer that
  `GL_MakeAliasModelDisplayLists` already builds for the GLSL path.

**Choose (e2).** Reasons:
- One `glDrawElements` per pass vs. dozens of small `glDrawArrays`,
  dramatically fewer per-call costs across the 3-pass overbright +
  fullbright sequence.
- Vertex range is fixed at `paliashdr->numverts_vbo`, perfect for
  `glLockArraysEXT(0, numverts_vbo)` in 1.1f. **This is the biggest
  single CVA win in the project**, same range hit by 3 passes.
- Index buffer infrastructure already exists in tree
  (`paliashdr->vboindexofs`, `numindexes`, `meshdesc/aliasmesh_t`). No loader
  changes needed.

**Approach:**

1. At top of `R_DrawAliasModel` (r_alias.c:633), after lighting setup:
   - Resolve index buffer: `unsigned short *indices = (unsigned short *)((byte *)paliashdr + paliashdr->vboindexofs);`
   - Resolve mesh-desc: `aliasmesh_t *desc = (aliasmesh_t *)((byte *)paliashdr + paliashdr->meshdesc);`
   - Resolve texcoords: `meshst_t *st = (meshst_t *)((byte *)paliashdr + paliashdr->vbostofs);`, pose-invariant, point GL at it directly.

2. Replace `GL_DrawAliasFrame` body with:
   - **Lerp pass**, walk `i = 0..numverts_vbo-1`, fetch `desc[i].vertindex` → original-vert-index, read `verts1[idx]`/`verts2[idx]` from posedata, lerp xyz into `alias_pos_scratch[i*3]`, compute shaded color via existing `shadedots` LUT into `alias_color_scratch[i*4]`.
   - **Pointer setup** (once per frame, hoist if cheap):
     - `glVertexPointer(3, GL_FLOAT, 0, alias_pos_scratch);`
     - `glTexCoordPointer(2, GL_FLOAT, 0, st);`
     - `glColorPointer(4, GL_FLOAT, 0, alias_color_scratch);` (when shading)
   - **Draw**, `glDrawElements(GL_TRIANGLES, paliashdr->numindexes, GL_UNSIGNED_SHORT, indices);`

3. `mtexenabled` branch (alias multitexture for fullbright pass at
   r_alias.c:349-353): same texcoord stream bound to both TMUs via
   `GL_ClientActiveTextureFunc + glTexCoordPointer`. Mirror 1.1c.

4. When `shading == false`: skip the color array, fall back to
   `glColor3f`/`glColor4f` as the current code does. Don't enable
   `GL_COLOR_ARRAY` for those passes.

**Scratch ownership:** file-static buffers in r_alias.c.
- `static float alias_pos_scratch[MAXALIASVERTS*3];`, 24 KB
- `static float alias_color_scratch[MAXALIASVERTS*4];`, 32 KB
- Total 56 KB, fits L2 on G4 + L1 on G3, no malloc, no thread issues.

**Pitfalls:**
- The `r_drawflat_cheatsafe` per-substrip random color (current code uses
  `srand(count * (size_t)commands)` keyed off the substrip pointer) won't
  exactly replicate. `r_drawflat` is debug; key the randomness off
  `(numindexes, frame)` and write the color array, or accept slight visual
  drift in cheat mode.
- `aliasmesh_t::vertindex` is the back-pointer from deduped index to
  original poseverts index, use it for the lerp source lookup.
- `GL_DrawAliasShadow` (r_alias.c:922-973) and `R_DrawAliasModel_ShowTris`
  (r_alias.c:980-1006) walk the same commands list. Either convert in this
  phase (cheap, same index buffer reuse) or leave immediate-mode (cosmetic /
  shadow has tiny vert count; defer if it complicates 1.1e).

---

## Phase 1.1f: CVA wrap on the converted phases

**Files:** `Quake/r_alias.c`, `Quake/r_world.c`

Wrap each converted draw region in:

```
if (gl_cva_able) GL_LockArraysEXTFunc(0, num_verts);
... draw calls ...
if (gl_cva_able) GL_UnlockArraysEXTFunc();
```

**Per-site:**

- **GL_DrawAliasFrame (1.1e)**, wrap once around the entire 3-pass region
  in `R_DrawAliasModel`. `lock(0, numverts_vbo)` after `R_SetupAliasLighting`,
  `unlock` before `cleanup:`. **Top expected CVA win.**
- **R_DrawTextureChains_Multitexture (1.1c)**, per-surface
  `lock(0, numverts) → DrawArrays → unlock`. Likely small/NOP; A/B with
  `-nocva` to confirm. Skip the wrap if neutral.
- **DrawGLPoly (1.1b)**, DON'T wrap. Single call, no multipass.
- **DrawWaterPoly (1.1g)**, DON'T wrap. Mutating texcoords can't be locked.

**A/B protocol:** run the full bench twice, default, then with `-nocva`,
and diff. Pure CVA contribution attributable independent of the array win.

---

## Phase 1.1g: DrawWaterPoly to client arrays + warp scratch

**File:** `Quake/gl_warp.c:194-221`

Texcoords mutate per draw via `WARPCALC` / `WARPCALC2` macros, so we need
scratch storage. Quake subdivides water surfaces during load
(`SubdividePolygon` in gl_warp.c) into small convex polys, default
`gl_subdivide_size 128` yields ≤~16 verts per poly. The cvar is
user-configurable though, and we **must not drop a draw** to fit a
fixed-size buffer (visible holes in water = visual regression).

Use a C99 VLA so the allocation always tracks `p->numverts`. gcc-4.0
supports VLAs, the stack frame is one cache line for typical polys, and
there's no global state to manage:

```
float st[p->numverts * 2];
```

Walk `p->verts`, write warped (s,t) into `st`:

```
glVertexPointer(3, GL_FLOAT, VERTEXSIZE*sizeof(float), &p->verts[0][0]);
glTexCoordPointer(2, GL_FLOAT, 0, st);
glDrawArrays(GL_TRIANGLE_FAN, 0, p->numverts);
```

**Path activation in our config:** `DrawWaterPoly` only runs when
`r_oldwater 1` is in effect. Phase 0's auto-mode (`r_oldwater 2`,
commit `3e502882`) picks classic warp **above** 640×480 on G3 and
refraction at/below, and uses refraction always on G4. So 1.1g lands
at **G3 1024 only**, where we're GPU-bound and the bench delta will be
small (≤+1%). Land it for code-completeness and to retire the last
immediate-mode call site on the brush/water path; do not budget bench
movement to it.

No CVA wrap (mutating attributes; can't be locked across regenerations).

---

## Phase 1.1h: Particles + sky cloud layers to batched arrays

**Files:** `Quake/r_part.c:826-932`, `Quake/gl_sky.c:914-1000`

Both are vertex-bound submission with many tiny `glBegin`/`glEnd` pairs.
**No visual change**, same primitives, same blend mode, same Z behavior.
Pure CPU win from collapsing per-primitive GL dispatch into one
`glDrawArrays` per group.

Existing particle state already optimal: `glDepthMask(GL_FALSE)` at
r_part.c:848 (depth writes off, johnfitz fix), alpha blend at :846. Don't
touch blend mode; that would change visuals.

### 1.1h.1: Particle batching

**Current:** per particle, one `glBegin(GL_QUADS)` → 4× `glColor4ubv` +
`glTexCoord2f` + `glVertex3fv` → `glEnd`. Roughly **10 GL calls per
particle**. demo3 explosions can push hundreds of particles/frame → 1000s
of GL calls/frame, all on the G3 CPU.

**Approach:** single-pass walk of `active_particles` writes into three
parallel scratch buffers, then **one** `glDrawArrays(GL_QUADS, 0, 4*n)` for
the whole frame.

```
typedef struct {
    float xyz[3];
} part_pos_t;
typedef struct {
    byte rgba[4];
} part_col_t;
typedef struct {
    float st[2];
} part_st_t;

static part_pos_t part_pos_scratch[MAX_PARTICLES * 4];   // 192 KB max
static part_col_t part_col_scratch[MAX_PARTICLES * 4];   // 64 KB max
static part_st_t  part_st_scratch [MAX_PARTICLES * 4];   // 128 KB once at init
```

Texcoords are pose-invariant (every quad uses the same 4 values). Fill
`part_st_scratch` **once at engine init** with the pattern repeated for
`MAX_PARTICLES` quads, never touched again.

Per-frame: walk `active_particles`, write xyz × 4 + rgba × 4 to scratch,
count `n`. Then:
```
glVertexPointer(3, GL_FLOAT, 0, part_pos_scratch);
glColorPointer(4, GL_UNSIGNED_BYTE, 0, part_col_scratch);
glTexCoordPointer(2, GL_FLOAT, 0, part_st_scratch);
glEnableClientState(GL_VERTEX_ARRAY);
glEnableClientState(GL_COLOR_ARRAY);
glEnableClientState(GL_TEXTURE_COORD_ARRAY);
glDrawArrays(GL_QUADS, 0, n*4);
glDisableClientState(GL_TEXTURE_COORD_ARRAY);
glDisableClientState(GL_COLOR_ARRAY);
glDisableClientState(GL_VERTEX_ARRAY);
```

Mirror for the `r_quadparticles 0` triangles branch (r_part.c:897-932),
3 verts per particle, fixed texcoords (0,0)/(1,0)/(0,1).

**Sizing**: `MAX_PARTICLES` is 4096 in QuakeSpasm. Total scratch ~384 KB
static-allocated, RAM is cheap. If concerned about cache footprint on G3
(L2 = 1 MB), can cap per-batch at e.g. 512 particles and dispatch in
chunks, still vastly fewer dispatches than per-particle.

**No CVA wrap**, particle data is rebuilt every frame, locking pre-build
is meaningless.

**Expected gain**: G3 +2-5% in particle-heavy demos (demo3 explosions),
+0-1% in light demos. G4 +0-2% (faster CPU absorbs more of the dispatch
cost).

### 1.1h.2: Sky cloud layer batching (Sky_DrawFaceQuad)

**File:** `Quake/gl_sky.c:914-1000`

Sky_DrawFaceQuad is called per visible sky face per scrolling layer.
Multiple `glBegin(GL_QUADS)` blocks: solid layer (multitexture path,
:927-936), alpha layer pass 1 (:950-957), alpha layer pass 2 (:965-972),
fog overlay (:989-992).

**Approach:** per-face arrays, same shape as 1.1c's multitexture
conversion. Texcoords scroll (mutating), so write to a small per-call
scratch:
```
static float sky_st0_scratch[4*2];  // 4 verts × 2 floats
static float sky_st1_scratch[4*2];  // multitexture second stream
```

Fill scratch from the existing scrolling texcoord math, then:
```
glVertexPointer(3, GL_FLOAT, VERTEXSIZE*sizeof(float), &p->verts[0][0]);
GL_ClientActiveTextureFunc(GL_TEXTURE0_ARB);
glTexCoordPointer(2, GL_FLOAT, 0, sky_st0_scratch);
GL_ClientActiveTextureFunc(GL_TEXTURE1_ARB);
glTexCoordPointer(2, GL_FLOAT, 0, sky_st1_scratch);
glDrawArrays(GL_QUADS, 0, 4);
```

Single-texture branches (:950-972) drop the second texcoord pointer.

**Skybox (Sky_DrawSkyBox at gl_sky.c:802-852), explicitly skip.** Only 6
faces × 4 verts per frame; rasterizer-bound, not vertex-bound. Converting
won't move the bench.

**Expected gain**: small. Sky cloud layers are ≤6 faces × 2-4 passes/frame
= ~30-50 GL calls/frame vertex submission. Below noise on its own; bundled
with particle batching as a single phase commit because the scratch-buffer
plumbing is similar.

---

## Cuts (deferred / skipped)

These collectively move ≤5% of per-frame vertex traffic; bad ROI vs.
1.1c+1.1e+1.1f.

**Skipped entirely** (single quad per call, dispatched ≤50× per frame, ~10
µs/frame total, under measurement noise):

- HUD: `Draw_Pic`, `Draw_Character`, `Draw_String`, `Draw_Fill`,
  `Draw_FadeScreen`, `Draw_TileClear` (gl_draw.c)
- view-blend polyblend (view.c)
- Debug viz: `R_EmitWirePoint`, `R_EmitWireBox`, `GLSLGamma_ApplyShader`,
  `R_ScaleView` (gl_rmain.c)

**Deferred to a future phase:**

- **Skybox** (Sky_DrawSkyBox, gl_sky.c:802-852), only 6 quads/frame,
  rasterizer-limited. Converting won't move the bench.
- **Sprites** (r_sprite.c:95-196), single 4-vert fan per sprite, few per
  frame in demo1/2/3.
- **dlight tris** (gl_rlight.c:102), ≤MAX_DLIGHTS=32 fans per frame.
  Borderline; revisit if 1.1h indicates real wins from small-batch
  conversion.

**Particles and sky cloud layers are now in 1.1h**, they were originally
deferred but moved in because particles are CPU-dispatch-bound (not
fillrate-bound) on G3 in particle-heavy demos. Visual quality unchanged.

---

## Architecture decisions

1. **Capability flag location:** `gl_cva_able` global in gl_vidsdl.c, extern
   in glquake.h. Two function pointers next to it. Pattern mirrors
   `gl_vbo_able` exactly. No cvar, `-nocva` command-line flag mirrors
   `-novbo`/`-nomtex` precedent (gl_vidsdl.c:1003,1027).

2. **Graceful fallback:** every CVA call site is `if (gl_cva_able) ...`. The
   array path runs unconditionally; only CVA is conditional. Single code
   path. Older drivers missing CVA just keep the array win.

3. **Scratch buffer ownership:** per-subsystem buffers, no shared pool.
   Choice of static-vs-VLA driven by whether an engine-enforced hard cap
   exists. Static is preferred when safe, but never at the cost of
   silently dropping a draw, which would be a visual regression.
   - r_alias.c: 24 KB pos + 32 KB color = 56 KB **static**, sized to
     `MAXALIASVERTS` (loader-enforced hard cap).
   - r_part.c: 192 KB pos + 64 KB color + 128 KB st = 384 KB **static**,
     sized to `MAX_PARTICLES` (engine-enforced hard cap). St filled once
     at init.
   - gl_warp.c: per-call **C99 VLA** (`float st[p->numverts*2]`).
     `gl_subdivide_size` is a user-tunable cvar with no hard cap, so
     dynamic sizing is the only correctness-preserving option.
   - gl_sky.c: 32 B per-call static (4-vert quad, fixed shape).

4. **Alias rendering: chosen approach (e2)**, glDrawElements with the
   pre-built triangle index buffer. Lerp xyz/color into scratch; texcoords
   point directly at model-resident `meshst_t`. Maximizes 1.1f CVA win.

5. **Multitexture surfaces:** per-surface arrays, no cross-surface batching.
   Lightmap bind blocks batching; sorting by lightmap multiplies texture
   binds (worse). Per-frame stitching is what VBOs are for (out of scope).

6. **Water warp:** worth doing for codebase consistency + immediate-mode
   removal on G3, despite no CVA wrap.

---

## Critical files (with line ranges)

- `Quake/glquake.h:184`, add CVA typedefs + extern declarations
- `Quake/gl_vidsdl.c:~107,~118,~1023`, CVA flag, function pointers,
  detection block (locate via `grep -n gl_vbo_able gl_vidsdl.c`)
- `Quake/r_brush.c:82-95`, DrawGLPoly to arrays
- `Quake/r_brush.c:102-114`, DrawGLTriangleFan to arrays
- `Quake/r_world.c:407-452`, R_DrawTextureChains_Multitexture to arrays
- `Quake/r_world.c:786-811`, R_DrawLightmapChains to arrays
- `Quake/r_alias.c:297-401`, GL_DrawAliasFrame to glDrawElements + scratch
- `Quake/r_alias.c:633-906`, wrap multipass in lock/unlock (1.1f)
- `Quake/gl_warp.c:194-221`, DrawWaterPoly to arrays + warp scratch
- `Quake/r_part.c:826-932`, particle batching to single glDrawArrays
- `Quake/gl_sky.c:914-1000`, Sky_DrawFaceQuad cloud layers to arrays

**Existing infrastructure to reuse:**

- `Quake/gl_mesh.c:GL_MakeAliasModelDisplayLists`, already builds the
  triangle index buffer + deduped vertex map at level load. Consume from
  legacy path, no loader changes.
- `Quake/gl_model.h:494-496`, `vboindexofs`, `vboxyzofs`, `vbostofs`,
  `meshdesc` already defined on `aliashdr_t`.
- `Quake/glquake.h:169`, `GL_ClientActiveTextureFunc` already loaded
  (gl_vidsdl.c:1033).

---

## Verification

**Per-phase smoke test:**

1. `scripts/build.sh g3 && scripts/build.sh g4`, both must compile clean.
2. Boot demo1 at 640x480 fullscreen on both targets via existing
   `scripts/deploy.sh + scripts/bench.sh`.
3. Phase 1.1a: confirm `FOUND: EXT_compiled_vertex_array` in qconsole.log.
4. Phases 1.1b–1.1g: spot-check screenshot at frame 1500 of demo1. Compare
   to baseline G4 screenshot (Radeon driver is more deterministic). On G3,
   eyeball, minor texturing-precision differences from FAN vs POLYGON are
   acceptable.
5. Debug-build assertions (gate `#ifndef NDEBUG`):
   - `assert(p->numverts >= 3)` in DrawGLPoly/DrawWaterPoly array variants
    , sanity only; release behavior must be safe for any `numverts` (VLA
     in Water, direct pointer at `glpoly_t::verts` in DrawGLPoly, both
     self-sizing, never silently drop a draw to fit a fixed buffer)
   - `assert(num_verts <= MAXALIASVERTS)` in alias path (loader-enforced
     hard cap; safe both in debug and release)
   - `glGetError()` after lock/unlock during dev to confirm CVA isn't
     erroring.

**Per-phase bench protocol** (already standardized):

- `scripts/full-bench.sh both`, 3 runs × demo1/demo2/demo3 × G3/G4 ×
  640/1024
- Median of runs 2 and 3 per cell
- Compare to previous-commit median; threshold for real win: ≥1 fps on G4,
  any positive on G3
- For 1.1f specifically: bench twice, with and without `-nocva`, attribute
  CVA delta independent of array delta

**Cumulative bench at end of 1.1g:** full grid into `benchmarks/results.csv`,
tag the row `1.1-complete`.

**Revert safety:** every phase is one commit on top of HEAD. 1.1b–1.1g each
fully revertable via `git revert <hash>` without touching others, they
share no scaffolding beyond the additive declarations in 1.1a.
