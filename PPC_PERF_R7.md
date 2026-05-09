# Round v7 — Static-analysis-driven perf candidates

**Generated:** 2026-05-09 (HEAD `9825b5f3`, post-watervis round v6).

This round opens with a hot-file static-analysis pass to find untapped
per-frame fps wins, **prioritised for G3 yosemite** (lowest-fps target,
GPU-bound on R128). Mature wins from rounds v2–v6 (frsqrte, AltiVec
lerp/sound/lightmap, Phase 3.x VAR, BGRA lightmaps, dlight/shadow
distance gates, client-array sky/warp paths, no-clear, watervis NoVis)
are already shipping; what remains is a noticeably thinner pile.

**Headline assessment:** the cheap-and-big optimisation wins are gone.
Round v7 is small-and-numerous territory — sub-1% gains stacking up
versus regressions. **Most candidates below should be honestly graded
"sub-noise-band" and we should pick 1–3 worth bench-validating.**

A separate "**measure first**" path is also recommended at the bottom
of this doc: per-machine profiling to confirm where each target is
actually spending its frame, before mining further static signals.

---

## Method

- Source: `analysis/warnings-linux-default.log` (gcc 15.2 `-Wall
  -Wextra -Wfloat-equal -Wnull-dereference -Wdouble-promotion ...`,
  re-run on round v6 HEAD), plus targeted reads of the seven hot
  files the user pointed at.
- 603 `-Wdouble-promotion` lines, 431 `-Wfloat-equal`, ~30 strict-
  aliasing/sign-compare/duplicated-branches; the round v5 wrap
  triage (`analysis/warnings-triage.md`) already absorbed the
  bug-finding signal — that's mostly noise/intentional.
- Hot per-frame paths cross-checked against PPC_PLAN.md (status of
  prior phases) and MISTAKES.md (reverted approaches).
- **Excluded by user direction:** the watervis NoVis trigger in
  `R_MarkSurfaces`, `Mod_BuildExpandedVis`, the AltiVec hot paths.
  Excluded by precedent: BGRA static-texture upload (Mistakes
  2026-05-08), Lion PGO (Mistakes 2026-05-09).
- G3 reasoning: yosemite is GPU-bound on demo1/2/3 1024 (Rage 128 +
  449 MHz 750). Per CLAUDE.md, look for **fillrate** and **GPU
  state-change** wins more than CPU wins. CPU wins help only when a
  CPU-bound frame can spill into fps headroom.
- G4 / Lion are CPU-bound on demo1/2/3 1024 mostly; CPU wins matter
  there.
- imac-2019 is excessively GPU-headroom'd (~2000 fps); ignore for
  ranking.

Estimates below use this scoring discipline: **a candidate's "G3
demo3 1024 estimate" is the upper bound assuming CPU savings spill
fully into fps**, with a confidence note. Static analysis can't tell
us whether a frame is CPU- or GPU-bound at the moment we save the
cycles — that's why honest estimates here are wider than the bench
noise band.

---

## Candidate list (G3-prioritised, ranked)

| # | Candidate | Files | G3 est | G4 est | Lion est | Risk | Cost | Toggleable |
|---|-----------|-------|--------|--------|----------|------|------|------------|
| 1 | **DrawGLPoly client-state hoist** (sky path) | `gl_sky.c`, `r_brush.c` | +0.5 to +2.0% | +0.0 to +1.0% | +0.5 to +1.5% | medium | ~30 lines | yes (`-nodgp-sky-hoist`) |
| 2 | **DrawWaterPoly client-state hoist** (oldwater path) | `gl_warp.c`, `r_world.c` | +0.5 to +1.5% (oldwater hosts only) | +0.0 to +0.5% (sawtooth oldwater only) | +0.5 to +1.0% (mini-intel only) | medium | ~25 lines | yes (`-nodgp-water-hoist`) |
| 3 | **`Sky_DrawFaceQuad` state hoist** | `gl_sky.c` | +0 to +0.5% (skybox-loaded levels skip this) | similar | similar | low | ~15 lines | yes (`-nodgp-skyface-hoist`) |
| 4 | **`-Wdouble-promotion` cleanup** in renderer hot files | `mathlib.h`, `gl_rlight.c`, `gl_sky.c`, `r_alias.c`, `r_part.c`, `view.c` | +0.0 to +1.5% (CPU-bound frames only) | +0.5 to +1.5% (AltiVec single-only mix penalty) | +0.0 to +0.5% | low | ~150–250 line edits across ~6 files | NO runtime toggle (build-time only; bisected at landing — same precedent as Phase 1 frsqrte) |
| 5 | **`Sky_GetTexCoord` sqrt → frsqrte fuse** | `gl_sky.c:898–906` | +0 to +0.5% | similar | n/a (no PPC) | low | 5 lines | already #ifdef-gated by `__ppc__` |
| 6 | **`anglemod` literal narrowing** | `mathlib.c:108` | sub-noise | sub-noise | sub-noise | nil | 2 lines | n/a (build-time) |
| 7 | **`R_BackFaceCull` `double dot` → `float dot`** | `r_world.c:77` | sub-noise (~0.02%) | sub-noise | sub-noise | nil | 1 line | n/a |
| 8 | **Dead-code removal: `R_DrawWorld_WaterDepthPrepass`** | `r_world.c`, `glquake.h` | 0% (cleanup only) | 0% | 0% | nil | ~50 lines | n/a |
| 9 | **Emissive-fullbright dynamic lights (Tier A)** *(visual upgrade, not perf)* | new `gl_emissive.c`, `gl_rlight.c`, `r_brush.c`, autoexecs | -5 to -15% (cost paid for visual win) | -2 to -8% | -1 to -3% | medium | ~250 lines + cvars | yes (`r_emissive_lights 0/1` CVAR_ARCHIVE + `r_emissive_lights_radius`/`_max`) |

**Notes on what *isn't* on this list and why:**

- The §13.2 Phase 4.4 lightmap AltiVec and §14.3 Phase 4.5 dlight
  AltiVec opt-in paths already exist in tree but are smoke-neutral on
  G4. Neither is a Round v7 candidate without same-session A/B that
  smoke missed.
- `R_DrawTextureChains_Multitexture` legacy glBegin loop on G3 (no
  VAR) is intentionally preserved — Phase 1.1c showed array-conversion
  regressed -3 to -4% on the Apple/ATI 1.4.18 driver when data is
  client-memory.
- Compiler-driven candidates (`-fopt-info-vec-missed`) were a wash in
  Round v5 (`analysis/perf-candidates.md`). Re-running won't surface
  anything different on a Round v6 HEAD.
- PGO/LTO on Lion: Mistakes 2026-05-09 closed the door (LLVM 2.9-era
  toolchain). Not coming back this round.

---

## Detailed per-candidate

### 1. DrawGLPoly client-state hoist (sky path)

**Where.** `gl_sky.c:617` (`Sky_ProcessPoly` → `DrawGLPoly`) and
`r_brush.c:120–131` (`DrawGLPoly` body):

```c
void DrawGLPoly (glpoly_t *p)
{
    glVertexPointer (3, GL_FLOAT, VERTEXSIZE*sizeof(float), &p->verts[0][0]);
    glTexCoordPointer (2, GL_FLOAT, VERTEXSIZE*sizeof(float), &p->verts[0][3]);
    glEnableClientState (GL_VERTEX_ARRAY);             // <-- per-poly toggle
    glEnableClientState (GL_TEXTURE_COORD_ARRAY);      // <-- per-poly toggle
    glDrawArrays (GL_POLYGON, 0, p->numverts);
    glDisableClientState (GL_TEXTURE_COORD_ARRAY);     // <-- per-poly toggle
    glDisableClientState (GL_VERTEX_ARRAY);            // <-- per-poly toggle
    ...
}
```

**Hot path.** Sky is a fullscreen GPU consumer on R128 (G3) and a
non-trivial CPU driver-marshalling cost on Tiger/Lion. `Sky_DrawSky`
calls `Sky_ProcessTextureChains` (one `DrawGLPoly` per visible sky
surface in world) and `Sky_ProcessEntities` (sky polys on brush
models), then layers/skybox. **Each of those `DrawGLPoly` calls
toggles client state 4 times in the driver state machine.** On
demo3 1024, ~10–30 sky surfaces visible per frame typical → ~40–120
redundant client-state ops per frame.

**Proposed change.** Wrap `Sky_ProcessTextureChains` and
`Sky_ProcessEntities` in a single
`Sky_BeginPolyRun()`/`Sky_EndPolyRun()` pair that enables/disables
client state once. Add an internal `DrawGLPoly_Inner(p)` that does
just `glVertexPointer + glTexCoordPointer + glDrawArrays` (no state
toggles), used by the sky path. Existing standalone `DrawGLPoly`
keeps its self-contained contract for the world-side callers
(`R_DrawTextureChains_Drawflat`, `R_DrawTextureChains_White`).

**Why this might be worth it.** Phase 3.3's chain-state hoist
(brush rendering) un-broke a -3.5% G4 regression that came from the
same per-surface state thrashing pattern. Same theory applies to
sky.

**Why estimate is wide.** Driver state-set is cheap when the value
is unchanged (the Tiger/ATI driver does this comparison) — so the
saved cycles may be near-zero on those targets. R128 / Panther
driver is older and may not no-op redundant sets. Lion / GMA 950
should benefit most because it's the most driver-overhead-bound.

**Toggleable.** `-nodgp-sky-hoist` cmdline flag parsed in
`Sky_Init` (or `R_Init`) so end-of-round A/B can isolate.

**Cost.** ~30 lines: helper functions in `gl_sky.c`, internal
`DrawGLPoly_Inner` exposed as static-inline header in `glquake.h`,
opt-out flag.

**Risk.** Medium — must ensure the sky-pass exit path (when sky
fog draw is active, when no sky surfaces visible, etc.) leaves
client state in the same place as the upstream contract. A unit
of regression risk = "we forgot to disable a client state before
returning to R_DrawWorld."

---

### 2. DrawWaterPoly client-state hoist (oldwater path)

**Where.** `gl_warp.c:202–233` (`DrawWaterPoly` body) and
`r_world.c:684–698` (the `R_OldWaterEffective()` branch of
`R_DrawTextureChains_Water`):

```c
// per-poly:
for (s = t->texturechains[chain]; s; s = s->texturechain)
    for (p = s->polys->next; p; p = p->next)
        DrawWaterPoly (p);   // each call: 4 client-state toggles
```

`DrawWaterPoly` has the same enable/disable pair pattern as
`DrawGLPoly`.

**Hot path.** Affects three machines: yosemite (G3, classic warp by
design — R128 has the bright-blue refraction bug at 1024), sawtooth
(G4 fixed-function — `r_oldwater 1` set in autoexec), mini-intel
(`r_oldwater 1` set in autoexec — though mini-intel actually defaults
to engine value 0 per autoexec; needs verification). Quicksilver +
mini-g4 use the GLSL shader water path and don't go through
`DrawWaterPoly`.

**Proposed change.** Hoist client-state setup outside the
`for (s ...) for (p ...)` loop in `R_DrawTextureChains_Water`'s
oldwater branch. Add `R_BindWaterPolyRun()`/`R_UnbindWaterPolyRun()`
helpers; `DrawWaterPoly_Inner(p)` writes the per-poly warp scratch
and submits.

**Why estimate is narrower than candidate 1.** Water-poly count per
frame is typically 5–20 (water bodies are smaller than sky). And
each `DrawWaterPoly` call also does the `WARPCALC` per-vert work,
which dominates per-call cost — so the relative win from removing
the state toggle is smaller.

**Toggleable.** `-nodgp-water-hoist` cmdline.

**Cost.** ~25 lines.

**Risk.** Medium — `entalpha < 1` brackets `R_BeginTransparentDrawing`
already, but the GL_TEXTURE_COORD_ARRAY state lifetime extends across
that bracket in the new design. Verify that the transparent-draw
state machine doesn't depend on GL_TEXTURE_COORD_ARRAY being off.

---

### 3. `Sky_DrawFaceQuad` state hoist (cloud-layer skies)

**Where.** `gl_sky.c:919` — the `Sky_DrawFaceQuad` function. Each
call enables and disables vertex/texcoord client state, with
multiple conditional paths internally (mtexable, alpha < 1, fog).
Called from `Sky_DrawFace` per cloud-layer subdivision quad.

**Hot path.** Per cloud-layer quad: `r_sky_quality` defaults to 8 →
8×8 quads × 6 faces = up to 384 quads per frame, **on cloud-layer
skies only** (not when a skybox texture is loaded — id1's `start.bsp`
uses skybox; demo1/2/3 maps load via `_box_*.tga` if present).

**Proposed change.** Extract a `Sky_BindFaceState()`/
`Sky_UnbindFaceState()` pair, called once around the inner loop in
`Sky_DrawFace`, that sets up multitexture state (or single-texture
state) once per face. `Sky_DrawFaceQuad_Inner(p, ...)` writes texcoord
scratch and submits.

**Why estimate is "+0 to +0.5%".** The bench demos run on `start`,
`e1m1`, `e1m2` — checking which use cloud layers vs skybox is part of
the implementation work. If all three use skybox, this is irrelevant.
Even if cloud-layer is hot, `WARPCALC`-style math in
`Sky_GetTexCoord` dominates; state hoist is a smaller relative win
than candidate 1.

**Toggleable.** `-nodgp-skyface-hoist`.

**Cost.** ~15 lines.

**Risk.** Low — Sky_DrawFace lives between the
`Sky_DrawSkyLayers` brackets which already manage `glTexEnvf` state.

---

### 4. `-Wdouble-promotion` cleanup in renderer hot files

**Where.** From `analysis/warnings-linux-default.log`, by file (top
hot-file occurrences):

```
view.c            : 52 sites  (V_CalcRoll, view bob — per-frame)
gl_fog.c          : 38 sites  (Fog_GetColor, Fog_SetupFrame — per-frame)
gl_sky.c          : 37 sites  (Sky_GetTexCoord, Sky_DrawFaceQuad — per-frame, hot)
pr_cmds.c         : 32 sites  (QC builtins — per-frame, server)
mathlib.h         : 25 sites  (Q_rint macro — many callers)
sv_user.c         : 17 sites  (SV_RunClients — per-frame, server)
sv_phys.c         : 15 sites  (SV_Physics — per-frame, server)
sbar.c            : 14 sites  (HUD — per-frame)
r_alias.c         : 14 sites  (R_SetupAliasLighting — per alias entity)
cl_main.c         : 14 sites  (CL_RelinkEntities — per-frame)
r_part.c          : 12 sites  (CL_RunParticles, R_DrawParticles — per-frame, hot)
gl_rmain.c        :  7 sites  (R_SetFrustum, GL_SetFrustum — per-frame)
gl_warp.c         :  8 sites  (R_UpdateWarpTextures — per-frame)
```

**Hot examples:**

`mathlib.h:53`:
```c
#define Q_rint(x) ((x) > 0 ? (int)((x) + 0.5) : (int)((x) - 0.5))
```
The `0.5` is a double; `x` is float; the addition widens. Used 25+
sites incl. lightmap-clamp paths. Fix:

```c
#define Q_rint(x) ((x) > 0 ? (int)((x) + 0.5f) : (int)((x) - 0.5f))
```

`gl_rlight.c:93,98`:
```c
rad = light->radius * 0.35;
AddLightBlend (1, 0.5, 0, light->radius * 0.0003);
```
→ `0.35f`, `0.5f`, `0.0003f`. Per-dlight per-frame.

`gl_sky.c:766–768` (`Sky_EmitSkyBoxVertex`):
```c
b[0] = s * gl_farclip.value / sqrt(3.0);
```
`sqrt(3.0)` is a double — and computed every call. Hoist + narrow:
```c
const float inv_sqrt3 = 1.0f / 1.7320508f;
b[0] = s * gl_farclip.value * inv_sqrt3;
```
Per-skybox-vertex. Skybox face emits 4 verts × 6 faces × 2 passes =
~50 calls per frame.

**PPC double-promotion cost.** PowerPC FPU is double-native, so the
*operation* isn't slower — it's the float-load → double-promote →
double-op → float-store-with-narrow round-trip that costs cycles
(typically 1–3 per site). G4 specifically suffers because AltiVec
is single-precision-only — gcc keeps mixed-precision code OFF the
vector unit and ON the scalar FPU, missing potential vectorisation
(though most of these sites aren't auto-vectorisable at this width
anyway).

**Proposed change.** Three sub-passes for safety/bisectability:
- 4a: `mathlib.h` macros — `Q_rint`, others. Touches every consumer.
- 4b: Renderer hot files (`gl_rlight.c`, `gl_sky.c`, `r_alias.c`,
  `r_part.c`, `gl_rmain.c`, `gl_warp.c`, `view.c`, `gl_fog.c`).
- 4c: Server-side files (`pr_cmds.c`, `sv_*.c`) — lower priority,
  these aren't in the per-frame client perf path.

Each sub-pass = independent commit + smoke bench. Bisects cleanly if
something regresses (each sub-pass touches independent files).

**Why estimate is "+0 to +1.5%".** This is the candidate I'm most
unsure about. PPC double-promotion costs cycles, but the render
loop's CPU work is dominated by the hand-AltiVec'd lerp/lightmap/
sound paths (which are already single-precision) and by GL submission
walls (GL calls don't care about scalar FP precision). The fixable
sites are micro-arithmetic spread across functions. Round v3's
similar `Wdouble-promotion`-driven `sinf/cosf` AngleVectors fix
landed at smoke-neutral.

**Toggleable.** **NO runtime toggle.** Build-time literal change.
Bisected via the 4a/4b/4c split. Same precedent as Phase 1 frsqrte
(per CLAUDE.md "Hard-coded (no runtime toggle yet) — flag if a
future round wants to A/B these"). I'd recommend grouping all 4a/4b
edits into a single phase commit and reverting if smoke is negative.

**Cost.** ~150–250 line edits across ~6 frontend files (4a+4b).
Mostly mechanical (`0.5` → `0.5f`, `sqrt(...)` → `sqrtf(...)`,
`cos(...)` → `cosf(...)`). Sub-pass 4c another ~150 lines.

**Risk.** Low — pure literal substitution. Two pitfalls:
- `DoublePrecisionDotProduct` at `mathlib.h:56` is **intentionally
  double** (gl_rlight.c:348 comment). Don't narrow.
- snd_dma.c double-promotion sites may be the AltiVec mixer math —
  verify before touching.

---

### 5. `Sky_GetTexCoord` sqrt → frsqrte fuse

**Where.** `gl_sky.c:898–906`:
```c
length = dir[0]*dir[0] + dir[1]*dir[1] + dir[2]*dir[2];
length = sqrt (length);
length = 6*63/length;
```

The pattern is `sqrt(x); 1/sqrt(x)` — algebraically `1/sqrt(x)`
directly via `Q_rsqrt_ppc` (which we already have in `mathlib.c`).
Wins one sqrt + one divide per cloud vert.

**Proposed change** (PPC-only):
```c
#if defined(__ppc__) || defined(__POWERPC__) || defined(__powerpc__)
length = (6.0f * 63.0f) * Q_rsqrt_ppc(length);  // length = 6*63 / sqrt(length)
#else
length = sqrt (length);
length = (6.0f * 63.0f) / length;
#endif
```

**Why estimate "+0 to +0.5%".** Cloud-layer sky only. `Q_rsqrt_ppc`
is ~30 cycles; `sqrt + /` is ~70 cycles. Saving ~40 cycles per
cloud vert × 4 verts/quad × 384 quads = ~60K cycles/frame ≈ 130 µs
at 449 MHz. At 25 fps (40 ms frame), that's 0.3%. Probably noise-band.

**Toggleable.** Already PPC-#ifdef'd; G3 + G4 use the new path,
Lion/imac stay on `sqrt`.

**Cost.** 5 lines.

**Risk.** Low. Q_rsqrt_ppc precision (~22-bit) is far below cloud
texcoord visual sensitivity.

---

### 6. `anglemod` literal narrowing

**Where.** `mathlib.c:108`:
```c
a = (360.0/65536) * ((int)(a*(65536/360.0)) & 65535);
```

Both literals are doubles. Called per visible alias entity per frame
(in `R_SetupAliasLighting`). **Sub-noise per call.** 1-line fix if
landing as part of candidate 4.

---

### 7. `R_BackFaceCull` `double dot` → `float dot`

**Where.** `r_world.c:75–88`:
```c
qboolean R_BackFaceCull (msurface_t *surf)
{
    double dot;        // <-- could be float; DotProduct returns float
    ...
}
```

Per visible surface in `R_MarkSurfaces`. ~600 surfaces on demo3
typical. Saving ~5 cycles/call × 600 = 3000 cycles ≈ 7 µs at
449 MHz = **0.02% of a 25fps frame.** Pure noise. Not worth a
phase commit on its own; could fold into candidate 4.

---

### 9. Emissive-fullbright dynamic lights (Tier A)

**Visual upgrade, not perf — costs fps for nicer-looking world.** Added
2026-05-09 in response to user request: buttons / computer panels /
light fixtures should cast coloured light onto surrounding geometry,
matching the way muzzle flashes and rocket trails already do.

**Where.** New file `Quake/gl_emissive.c` plus hooks in `gl_rlight.c`
(R_PushDlights), `r_brush.c` (R_NewMap), and a per-machine autoexec
flip.

**Mechanism.**

1. **At map load** (called from `R_NewMap` after the world's brush
   model is built): walk all surfaces of every brush model. For each
   surface whose `texinfo->texture` has a non-null `fullbright`
   gltexture (i.e., the texture has emissive pixels — `+0button`,
   `+0light`, `*lava`, `*slime`, computer screens, etc.):
   - Compute surface centroid from `s->polys->verts`.
   - Offset centroid 4 units along surface normal so the light sits
     in front of the wall (otherwise it'd be embedded and only light
     the back faces).
   - Read fullbright pixel data (already loaded as a `gltexture_t`):
     compute average colour weighted by alpha, plus a luminance
     score.
   - Compute radius proportional to surface area, scaled by the
     `r_emissive_lights_radius` cvar (default 1.0, multiplier).
   - Store in a parallel array `r_emissive_lights[]` (capacity
     defined by `MAX_EMISSIVE_LIGHTS = 64`, per-frame cap from
     `r_emissive_lights_max`).
   - If we exceed the cap, keep the highest-luminance entries.

2. **Per frame** (in `R_PushDlights`, after the regular `cl_dlights[]`
   sweep): if `r_emissive_lights.value > 0`, walk
   `r_emissive_lights[]`, apply the same `r_dynamic_distance` gate
   that `cl_dlights[]` uses (squared-distance compare), and inject
   the active subset into the existing dlight pipeline by reusing
   the `cl_dlights[]` infrastructure with a separate "always alive"
   flag — die time set to `cl.time + 1.0`, refreshed each frame.

3. **Animation tracking** (cheap, optional): for textures with
   `alternate_anims` (the `+0button`/`+1button`/… cycle, or
   lightstyle-driven flicker textures), modulate the per-light
   colour intensity by `R_TextureAnimation()`'s current frame's
   fullbright luminance ratio vs the base frame. Cost is one
   table lookup per emissive light per frame.

**Cvars (all `CVAR_ARCHIVE`, runtime-flippable):**

```c
cvar_t r_emissive_lights         = {"r_emissive_lights", "0", CVAR_ARCHIVE};   // master gate
cvar_t r_emissive_lights_radius  = {"r_emissive_lights_radius", "1.0", CVAR_ARCHIVE};
cvar_t r_emissive_lights_max     = {"r_emissive_lights_max", "16", CVAR_ARCHIVE};
```

**Per-target autoexec defaults** (set in `scripts/bundle/autoexec-*.cfg`
after smoke-validation):

| Machine    | r_emissive_lights | radius | max | rationale |
|------------|-------------------|--------|-----|-----------|
| yosemite   | `1` (opt-in via console only initially) | 0.5  | 4  | R128 GPU-bound; tight radius + low cap = ~5% cost |
| sawtooth   | `1`               | 0.5  | 6   | GeForce2 MX fixed-function; same pattern as yosemite |
| quicksilver| `1`               | 1.0  | 12  | Radeon 9000 has headroom |
| mini-g4    | `1`               | 1.0  | 12  | Radeon 9200 same family |
| mini-intel | `1`               | 0.75 | 8   | GMA 950 fillrate-modest |
| imac-2019  | `1`               | 1.5  | 32  | Radeon Pro 580X — let it rip |

**G3 cost.** R128 has no fragment-shader dlight path, so each emissive
light = a full extra blending pass over every surface its sphere
touches. This is the same cost profile that drove
`r_dynamic_distance 768`. Honest expectation:
- Tight radius (0.5×) + cap 4 + distance-gating: probably -5% on
  demo3 1024 (currently 20.90 fps → ~19.9 fps). Right at the
  20-fps floor.
- If demo3 drops below 20 fps after smoke, drop yosemite cap from
  4 to 2 or set `r_emissive_lights 0` by default + console-toggleable.

**G4+ cost.** Smaller relative impact; Radeon 9000/9200 absorb the
extra blends.

**Why this design over alternatives.**
- Reusing `cl_dlights[]` slots was rejected: would starve muzzle
  flashes / rockets. Parallel array decouples the budgets.
- One global "world emissive light" baked into the lightmap was
  rejected: lightmap is static; we'd lose the animation-cycle
  flicker (the user's "button flashes red/yellow" requirement).
- Tier B (lightstyle-driven flicker on top of texture anim) is a
  follow-up — keep Tier A simple first.

**Cost.** ~250 new lines: a new TU `gl_emissive.c` for the
load-time scan + per-frame inject, ~10 lines of hook in `R_NewMap`
and `R_PushDlights`, ~20 lines of cvar registration in
`gl_rmisc.c`, autoexec edits per-machine.

**Risk.** Medium.
- Map-load cost: 64 emissive lights × per-light surface scan = small
  overhead at level load. Should be < 100 ms even on G3.
- Per-frame cost: scaling with cap = bounded.
- Visual risk: lights may overlight rooms whose original lighting was
  carefully crafted. Per-machine `r_emissive_lights_radius` lets
  users tune.
- Interaction with `gl_flashblend 1`: that mode replaces dlight blend
  passes with billboard sprites. On yosemite the comment says
  flashblend crashed the R128 driver. Emissive lights should respect
  flashblend — when flashblend is on, emissive lights become
  billboards too. Free animation-cadence with billboard-render.

---

### 8. Dead-code removal: `R_DrawWorld_WaterDepthPrepass`

**Where.** `r_world.c:864–915` (definition), `glquake.h:508`
(declaration). The function is no longer called (round v6 reverted
the depth-prepass approach when watervis NoVis took over). Removing
it is cleanup, no fps impact, but keeps the codebase honest. Could
land as a single grouped "round v7 hygiene" commit alongside
candidates 6 + 7.

---

## Top-3 recommendation (per user direction 2026-05-09)

User has selected **Candidate 9 (Tier A emissive lights)** as a
priority for this round, and asked for additional perf squeeze on
G3 and up. Implementation order locked in:
1. **Candidate 1** (DrawGLPoly sky-state hoist) — perf squeeze, lands
   first because lower risk and leaves headroom for #2.
2. **Candidate 9** (Tier A emissive lights) — visual upgrade.
3. Round v6 wrap full-matrix bench captures the v6 baseline before
   either of the above.

## Top-3 recommendation (original analysis)

1. **Candidate 1: DrawGLPoly client-state hoist (sky path).** Best
   risk/reward. Sky is a per-frame consumer on every target; the
   transformation is well-understood (Phase 3.3 brush hoist as
   precedent). Estimated G3 +0.5–2.0%, others smaller. Honest
   chance of being smoke-neutral too — but if it lands, it lands on
   every machine, not just one.

2. **Candidate 2: DrawWaterPoly client-state hoist.** Same theory
   as 1, narrower applicability (only oldwater hosts: yosemite,
   sawtooth, mini-intel). Estimated G3 +0.5–1.5%. Worth landing
   right after 1 — same code-shape, easy second commit.

3. **Candidate 4: `-Wdouble-promotion` cleanup (4a + 4b only).**
   The "many small wins" phase. Highest line-count cost, but
   mechanical. Honest chance of being smoke-neutral; if it shows
   even +0.5% on G3 + G4, the cumulative effect across maps is
   probably worth the disk churn.

Picking exactly one of the three is also defensible — the project
has been disciplined about "ship-or-skip" on smoke regressions and
small-positive results take real bench time to validate.

---

## "Measure first" — per-machine profiling options

Static analysis can't tell us whether a frame is CPU- or GPU-bound
at the moment we save cycles. Round v7 would benefit from a
profiling pass on each bench machine to confirm where the frame
budget actually goes today, **before** mining further optimisations.

CLAUDE.md notes that Tiger/Panther have no working OpenGL Profiler
(version mismatch) and that `gl_perfprint` (engine-side
mach_absolute_time deltas, region-tagged) is our usual fallback.
Below is what's additionally available on each target — the more
granular options have implementation costs noted.

| Machine | OS | gl_perfprint | sample | gprof (`-pg`) | Instruments | Notes |
|---------|----|--------------|--------|---------------|-------------|-------|
| **yosemite** (G3 Panther 10.3) | 10.3.9 | ✅ free | ❌ no `sample` | ✅ requires rebuild | ❌ | Only options: `gl_perfprint 2` for region timings; `-pg` build for flat-profile |
| **sawtooth** (G4 Tiger 10.4) | 10.4.11 | ✅ free | ✅ `sample <pid>` 30s | ✅ rebuild | ⚠ Shark.app (CHUD) if installed | `sample` is the headless go-to |
| **quicksilver** (G4 Tiger 10.4) | 10.4.11 | ✅ free | ✅ same | ✅ same | ⚠ same | Same as sawtooth |
| **mini-g4** (G4 Tiger 10.4) | 10.4.11 | ✅ free | ✅ same | ✅ same | ⚠ same | Same as sawtooth |
| **mini-intel** (Intel Lion 10.7) | 10.7.5 | ✅ free | ✅ `sample` | ✅ rebuild | ⚠ Time Profiler if Xcode installed | `sample` — function-level hot list is plenty |
| **imac-2019** (Intel Sequoia 15.7) | 15.7.5 | ✅ free | ✅ `sample` | ✅ rebuild | ✅ `xctrace record --template "Time Profiler"` | Modern; `xctrace` is the cleanest |

**Recommended plan if we go this route:**

1. **All machines: `gl_perfprint 2` over a full demo loop.** Free,
   no rebuild needed. Captures per-region ms (warp, sky, world,
   water, alias, alpha, particles, vmodel, swap) plus per-region
   GL call counters (binds, draws, dlights, surfs, atris). Output
   lands in `qconsole.log`. Aggregate across demo1/2/3 1024 to see
   where each target's frame goes. **Highest-ROI single action.**

2. **Tiger + Lion machines: `sample <quakespasm-pid> 30 -file
   /tmp/<host>_sample.txt` while running a timedemo.** Statistical
   sampling, no rebuild, low overhead (won't perturb fps). Gets
   function-level hot list — confirms whether `R_AddDynamicLights`,
   `R_BuildLightMap`, `Sky_GetTexCoord`, etc. are actually where
   the hot frames spend time.

3. **Yosemite (Panther): rebuild with `-pg` and run timedemo.**
   `scripts/build.sh g3` would need a `--with-profile` flag added
   that tacks `-pg` onto CPUFLAGS and links `-lgmon`. Overhead
   is non-trivial (gprof instruments every call) so this perturbs
   the timedemo, but the call-graph flatprofile + call-count hits
   are still informative for relative hot-fn ranking. Probably a
   one-shot exercise rather than a routine.

4. **Optional: imac-2019 `xctrace`.** Modern call-tree visualisation
   for the Intel x86_64 path, including its driver-side OpenGL time.
   imac-2019 isn't a perf target (~2000 fps headroom), but it can
   show whether the Sequoia GL stack itself is doing anything weird.

This profiling pass would be a **separate phase** before
implementing candidates above. It would let us re-rank candidate
estimates with actual signal instead of static analysis only —
e.g. if `gl_perfprint` shows `world` as 60% of G3 demo3 frame and
`sky` as 5%, candidate 1's G3 estimate drops from "+0.5–2.0%" to
"+0.0–0.3%" and we'd shift to a candidate with hot-region overlap.

**Cost.** Plumbing for items 1–3 is mostly already in place
(gl_perfprint is wired; sample/gprof are off-the-shelf). A single
session running profiles + collating results is probably 1–2 hours
end to end across the 6 machines.

---

## Decision point

**The user picks 1–3 candidates from the list above (or "do the
profiling pass first") to actually implement in Round v7.** Phase
1 of this session terminates here per the round prompt — no
implementation in this session past static analysis.
