# Round v7 pre-smoke review: Candidate 1 (sky-state hoist) + Candidate 9 (Tier A emissive lights)

**Reviewer:** static + read-through pass against IRONWAIL_REVIEW.md, MISTAKES.md,
PPC_PERF_R7.md, and the working tree off HEAD `5cbcf785`.

## Executive verdict

**Ship-with-changes.** Candidate 1 is clean, narrowly scoped, fallback-equivalent,
no GL state-machine surprises; ship as-is. Candidate 9 has **one correctness bug
that will reproducibly chew up `cl_dlights[0]` once 64 emissive lights are alive
simultaneously** (which happens within ~6 frames at 60 fps with the current `die`
window) and a couple of design-smell issues that should be fixed before smoke.
None of those is a crash on the order of the BGRA-static failure; closer to
"behaves badly when the cvar is on, especially overlapping with player-key=0
muzzle flashes." Fix the `die` window and a few smaller items, then it's
reasonable to smoke. Sub-1% perf risk on Candidate 1; cvar-off-default for
Candidate 9 means the *default* binary smoke is unchanged, which protects the
"no regression on any target" rule even if the cvar-on path has issues.

---

## Candidate 1: DrawGLPoly sky-state client-state hoist

### Correctness
- `Sky_DrawSky` enables `GL_VERTEX_ARRAY` exactly when `!sky_hoist_disabled`
  and disables it on the same condition before `glEnable(GL_TEXTURE_2D)`
  (gl_sky.c:1191–1200). Symmetric. Exit state matches entry state.
- `Sky_DrawFlatPoly` falls back to the upstream `DrawGLPoly` when
  `sky_hoist_disabled`, preserving prior behaviour exactly under the opt-out
  (gl_sky.c:660–666).
- The next renderer call after `Sky_DrawSky` is `R_DrawWorld`, which
  unconditionally re-enables `GL_VERTEX_ARRAY + GL_TEXTURE_COORD_ARRAY`
  itself at r_world.c:959, does not depend on entry state. Hoist is
  well-bounded.
- `PERF_COUNT` macros in `Sky_DrawFlatPoly` (gl_sky.c:662–663) compile to
  `((void)0)` on non-Apple builds (gl_perfprint.h:95). Linux compile clean.
- The hoist intentionally does NOT enable `GL_TEXTURE_COORD_ARRAY`, sky
  flat-pass runs with `GL_TEXTURE_2D` disabled, texcoords are unread. Correct.

### Ironwail alignment
- Ironwail's "GPU-driven sky" (compute-shader sky bounds) is GL 4.3, not
  on our matrix, no conflict. The CPU-side hoist is independent of any
  Ironwail technique and follows the same theory as our existing Phase
  3.3 brush-chain hoist.

### Mistakes-log alignment
- Closest precedent is Phase 3.2 → 3.3 (the per-surface client-state
  thrash that caused the G4 -3.5% regression). Phase 3.3 fixed it the
  same way Candidate 1 fixes sky. No mistakes-log entry warns against
  this pattern.

### Edge cases
- `r_drawflat_cheatsafe` / `r_lightmap_cheatsafe` early-return at
  gl_sky.c:1170, those exit BEFORE the new `glEnableClientState` call,
  so client state is untouched and matches entry. Safe.
- `r_drawworld_cheatsafe == 0` short-circuits inside
  `Sky_ProcessTextureChains` (gl_sky.c:708), but client state is still
  enabled by then. The disable on the way out runs correctly. Safe.
- Empty world (no sky surfaces visible): both Process calls iterate
  zero surfaces, then we still disable. One redundant enable/disable
  pair per frame in worst case. Sub-noise.

### Smoke risk grade: **Low**.
Worst plausible outcome: smoke-neutral on every target (driver
already no-ops redundant `glEnableClientState`). Best plausible
outcome: +0.5–2% on G3 and Lion. Either result lets it ship.

---

## Candidate 9: Tier A emissive-fullbright dynamic lights

### Correctness: there is a real bug

**Blocker B1.** `gl_emissive.c:266` sets `dl->die = cl.time + 0.1f`.
The comment claims this means the slot dies "before next frame," but
that is wrong: 0.1 s = 100 ms, longer than a single frame at any of
our targets. At 60 fps each emissive seed leaves ~6 living slots in
`cl_dlights[]` before the first one expires. With
`r_emissive_lights_max 16` × 6 frames = up to 96 alive slots, but
`MAX_DLIGHTS = 64`. Once `cl_dlights[]` saturates,
`CL_AllocDlight(0)` (cl_main.c:307–323) falls through both passes and
**stomps slot 0**, which is the player muzzle-flash slot at
`ent_index 0`. Effect: every emissive frame after saturation clobbers
the muzzle flash, and 15 of every 16 emissive injects collapse onto a
single slot. No crash, but visually broken and a CPU-cost bug
(`R_MarkLights` re-runs on the same overwritten slot).

  Fix: change to `dl->die = cl.time + 0.001f` to match the BRIGHTLIGHT
  / DIMLIGHT idiom (cl_main.c:544/551/558/568). That's the canonical
  "expires before next frame" pattern in the engine. The 0.1 s window
  is correct for muzzle flashes specifically because they refresh by
  matching `key=ent_index` next frame; emissive lights use `key=0` and
  do not refresh-by-key, so they need the short die.

**Blocker B2.** Selection at the cap is FIFO, not luminance-ranked,
despite the design comment claiming "brightest seeds win at the cap"
(gl_emissive.c:36 and PPC_PLAN_R7.md). `R_BuildEmissiveLights` simply
`break`s when `r_num_emissive_seeds >= MAX_EMISSIVE_SEEDS`
(gl_emissive.c:161–162). Combined with `Mod_CheckFullbrights` flagging
ANY texture with even one pixel > 223 (gl_model.c:595–604), most id1
wall textures (`wbrick*`, `wmet*`, etc., all carry trim pixels in the
fullbright range) qualify. Expected outcome on a typical id1 map: the
first 128 brush surfaces, all walls, mostly meaningless trim, fill
the seed array, and real "emissive" surfaces (buttons, screens) past
that point are silently dropped.

  Fix options, in order of effort: (a) raise the bar to "≥ N
  fullbright pixels" by counting in `Mod_CheckFullbrights` and storing
  a count, then filter `count > threshold` here; (b) sort seeds by
  surface area or fullbright fraction before truncating; (c)
  pre-filter to texture names matching the `R_PickEmissiveColor`
  heuristic table (light/lite/button/btn/comp/tech/panel/screen/+) so
  only "intentionally emissive" surfaces seed. Option (c) is the
  smallest patch and matches the design intent expressed in the docs.

### Other correctness concerns (non-blocking)
- `r_dynamic_distance` default is `0` → unlimited (gl_rmain.c:89). On
  G4/Lion (autoexec doesn't set it), the distance gate is a no-op
  and ALL active seeds inject every frame. That's the documented
  behaviour but worth noting, combined with B1, the saturation
  point arrives faster on those targets than on G3 (which sets
  `r_dynamic_distance 768`).
- `R_BuildEmissiveLights` reads `surf->extents` (gl_emissive.c:193).
  `extents` is `short[2]`. Implicit promotion to int via `+16` is
  fine; cast to float OK. No overflow on legal extents (clamped to
  2000 in gl_model.c:1459).
- `R_PushEmissiveLights` clamps `max_active` to `MAX_EMISSIVE_SEEDS`
  (128) but the dlights pool is 64. A user `r_emissive_lights_max
  100` will inject up to 100 at once, saturating the pool and
  triggering blocker B1 immediately. Recommend clamping
  `max_active` to `MAX_DLIGHTS - 8` (leave headroom for muzzle/
  rocket/gib lights), or stop on first saturation by checking
  whether `CL_AllocDlight(0)` returned `&cl_dlights[0]` and the slot
  was already alive (signal of fallback-stomp).
- `r_emissive_lights_radius` default is `1.0`; per-machine radii in
  the autoexec table (PPC_PLAN_R7.md) range 0.5–1.5. The clamp at
  gl_emissive.c:243–244 is `[0.05, 4.0]`, so user typos can't crash,
  but radius `0.05 * 192 = 9.6` is below playable visual threshold
 , fine, just confirms range is sane.

### Ironwail alignment
- Ironwail's runtime dlight pipeline is identical at the
  `cl_dlights[]` interface, same struct, same `CL_AllocDlight`. Tier
  A's strategy of seeding `cl_dlights[]` from a parallel array is
  compatible with Ironwail's CPU-side path; if a future round
  imports Ironwail's flat-array static-entity efrags (IRONWAIL_REVIEW
  candidate 1), Tier A's seed array is structurally similar (load-
  time-fixed flat array of small structs, walked linearly per
  frame), same pattern, no conflict.
- No conflict with Ironwail's GPU dlight cluster pass, that's GL
  4.3+ and disqualified for our matrix.

### Mistakes-log alignment
- The closest mistakes-log analogue is **BGRA static texture upload**
  (2026-05-08). That entry's lesson, "load-time-only / zero risk"
  claims need smoke-bench validation across the full demo set, not
  just demo1, applies here. Tier A IS load-time + per-frame, so
  it's strictly riskier than BGRA-static was on paper. The default
  `r_emissive_lights 0` opt-in does protect us: a smoke run with
  the cvar OFF tests only the inert plumbing path, which is where
  BGRA-static appeared safe and then crashed. **Recommendation:
  smoke at least one cell with `r_emissive_lights 1` enabled,
  ideally on G3 demo3 (the highest-stress dlight scene), before
  committing.**
- Phase 4.4 lightmap AltiVec ("looked clean on paper, regressed at
  smoke"): not directly analogous, but the principle "code paths
  that touch the GPU dlight pass are precision-of-fps territory"
  applies. Especially on R128 which has no fragment-shader dlight
  path.

### Edge cases
- Empty world (`cl.worldmodel == NULL`): `R_NewMap` already
  dereferences `cl.worldmodel->numleafs` at gl_rmisc.c:441, so
  if cl.worldmodel were null we'd have crashed already. The
  defensive `if (!world) return` at gl_emissive.c:156 is a
  redundant guard, harmless.
- Map with zero fullbright surfaces (e.g. a custom map using only
  non-emissive textures): `r_num_emissive_seeds == 0`, early-out
  in `R_PushEmissiveLights` at gl_emissive.c:236. Safe.
- Surface with `polys->numverts < 3`: filtered at gl_emissive.c:169.
  Safe.
- `surf->plane == NULL` (impossible per Mod_LoadFaces but guarded):
  filtered at gl_emissive.c:170. Safe.
- Animated textures with circular `alternate_anims` (the `+0button`
  cycle): NOT a problem, emissive seeding is per-surface-instance,
  not per-texture-frame. Each button surface in the BSP gets ONE
  seed using its base-frame texture. Animation-frame cycling by
  `R_TextureAnimation()` is a renderer-time concern; the seed is
  static. Comment in gl_emissive.c:75 mentions "reserved for v2
  (animation modulation)", explicit non-feature for Tier A. Fine.
- `gl_flashblend 1`: `R_PushDlights` early-returns at gl_rlight.c:240
  BEFORE calling `R_PushEmissiveLights`. So when flashblend is on,
  emissive lights are disabled entirely. Probably what we want
  (flashblend's billboard sprite path does not naturally render
  emissive-as-dlight) but the design doc says flashblend should
  trigger billboard-render of emissive lights. **Currently does
  nothing in flashblend mode**, the doc's intent is unimplemented.
  Acceptable as a Tier A scope cut, but a recommendation below.

### Smoke risk grade
- **Default-off path (cvar 0):** Low. Inert. The only code that runs
  is `R_BuildEmissiveLights` at map-load (a one-shot scan, < 50 ms
  on G3 in the worst case) and a single early-return cvar check at
  the head of `R_PushDlights` per frame. Sub-noise.
- **Cvar-on path (`r_emissive_lights 1`):** **Medium-High** until
  blocker B1 is fixed. Once B1 is fixed: Medium. Saturation-stomp
  on cl_dlights[0] is the dominant mode of badness, and reliably
  reproducible on any map with > 16 emissive surfaces (i.e. every
  id1 map). On G3 R128 the predicted -5–15% fps cost is on top of
  the broken-allocator behaviour, so the "real" cvar-on smoke
  number could be worse than predicted until B1 lands.

---

## Specific blockers (must fix before smoke)

1. **gl_emissive.c:266**, change `dl->die = cl.time + 0.1f` to
   `cl.time + 0.001f`. Without this the dlight pool saturates
   within ~6 frames of cvar-on, fallback-stomps `cl_dlights[0]`
   (player muzzle-flash slot), and breaks both the emissive
   visual and the muzzle flash.

2. **gl_emissive.c:159–204**, selection at `MAX_EMISSIVE_SEEDS`
   cap is FIFO, not luminance- or area-ranked, contradicting the
   design doc. Either (a) pre-filter to surfaces whose
   `texinfo->texture->name` matches the
   `R_PickEmissiveColor` heuristic table, or (b) sort seeds and
   keep the top `MAX_EMISSIVE_SEEDS`. (a) is the small patch and
   matches design intent. Without this, on a typical id1 map the
   seed array fills with non-emissive trim before any actual
   button/light is seen. **Smoke will produce visually wrong
   "lit walls" rather than "lit buttons."**

## Recommendations (non-blocking: before round v8)

1. **gl_emissive.c:240**, clamp `max_active` to e.g.
   `MAX_DLIGHTS - 8` rather than `MAX_EMISSIVE_SEEDS`. Leaves
   headroom for muzzle/rocket/gib dlights even on the cvar-on
   path. Belt-and-braces over blocker B1.

2. **Sort or score seeds by `area * (count of fullbright pixels
   in source mip0)`** in `R_BuildEmissiveLights`, so the cap
   prioritises actually-bright surfaces. Requires a tiny extension
   to `Mod_CheckFullbrights` (return count, not boolean), small
   but touches model.c. Optional follow-up after blocker B2's
   name-table filter does the immediate triage.

3. **Implement the gl_flashblend path** mentioned in the design
   doc, when `gl_flashblend.value`, `R_PushEmissiveLights`
   currently does nothing because `R_PushDlights` early-returns
   first. Either move the call ahead of the flashblend check, or
   add a billboard-render hook for emissive lights specifically.
   (Tier A scope cut: defer to Tier B.)

4. **Align with Ironwail flat-array efrags pattern.** Tier A
   already uses a flat `r_emissive_seeds[128]` array, keep that
   shape if Ironwail candidate 1 (flat-array static-entity
   efrags) ever lands; both can share the same iteration idiom.
   Worth noting in PPC_PLAN.md so the alignment is intentional,
   not accidental.

5. **Add a smoke cell with `r_emissive_lights 1` to the bench
   discipline for this phase.** The cvar-off default protects the
   "no regression" rule, but the design intent is for the cvar to
   be on per-machine via autoexec. Smoke-validate the cvar-on
   path on at least G3 demo3 1024 (highest-stress) before the
   autoexec edits land, per the BGRA-static lesson.

6. **Candidate 1 + Candidate 9 share no code paths**, they can
   land as two independent commits. Recommend Candidate 1 first
   (as the round prompt already plans) since it's lower-risk and
   the smoke result is informative independent of Candidate 9's
   fixes.
