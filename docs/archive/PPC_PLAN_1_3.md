# PPC Plan 1.3 — Throttled SGIS mipmap for liquids (G4 only)

> **STATUS: ARCHIVED — not worth the effort right now.**
>
> This plan is technically sound and could be executed in a few hours, but
> the expected return is too thin to justify the spend. **Best case** on G4
> is roughly fps-neutral with marginally better-looking distant water.
> **Worst case** is -3 to -5 fps with water animation visibly stuttering.
> G3 gets literally nothing (its code path is untouched). The honest
> verdict: not a Quake-running-on-PPC priority.
>
> **What would change the calculus and make this worth revisiting:**
> - If a benchmarked level shows distant-water shimmering severely on G4
>   and the user calls it out as a quality blocker.
> - If a future phase makes the rest of the engine fast enough that 3-5
>   fps of headroom is acceptable to spend on liquid quality.
> - If we discover the SGIS extension *isn't* exposed on Radeon 9000 at
>   all (in which case the plan becomes "manual CPU mipchain", a
>   different and larger effort — see Cuts).
>
> Archived 2026-05-06.

## Deliverable: copy this plan to repo root

(Already done — this file is the archive copy. If revived, update the
1.3 row in `PPC_PLAN.md` to point here.)

## Context

QuakeSpasm liquid (water/lava/slime/teleport) rendering on the G4 path
(`r_oldwater 0`, framebuffer-copy refraction) currently produces
**shimmering aliased water at distance** because warp textures bind with
`GL_LINEAR` — no mipmaps. Root cause: `gl_vidsdl.c:1305-1322` only
probes `glGenerateMipmap` (ARB / GL 3.0) and `glGenerateMipmapEXT`
(EXT_framebuffer_object). Apple's Tiger GL stack on Radeon 9000 exposes
neither, so `GL_GenerateMipmap` is left `NULL`, the warpimage's
`TEXPREF_MIPMAP` flag is dropped at creation (`gl_model.c:864-868`), and
the warpimage texture renders mipmap-less.

A previous attempt (Phase 1.3) added `SGIS_generate_mipmap` as a third
fallback. **It produced a 109→37 fps regression at 1024×768 on G4.** The
extension is a *texture parameter* (`GL_GENERATE_MIPMAP_SGIS = GL_TRUE`)
that triggers a full mipchain regen on every level-0 update. Since
`R_UpdateWarpTextures()` calls `glCopyTexSubImage2D` once per frame per
visible liquid texture (`gl_warp.c:275`), the Radeon 9000 driver fell
through to a software mipchain generator on every frame. Reverted.

**This plan would restore SGIS with a frame-cadence throttle** that
gates the entire warp update (copy + regen) to once every N frames.
Water *animation* runs at framerate/N; mipmap quality is preserved. At
sensible N values the visual cost is invisible and the perf is
*acceptable* — but only barely, which is why this is archived.

**G3 is out of scope.** Per `autoexec.cfg`, G3 is pinned to
`r_oldwater 1`. `R_UpdateWarpTextures()` short-circuits via
`R_OldWaterEffective()` at `gl_warp.c:243-244` — no `glCopyTexSubImage2D`,
no per-frame mipgen. The classic warp uses base liquid textures with
`WARPCALC` UV displacement (`gl_warp.c:194-221`); those base textures
already carry `TEXPREF_MIPMAP` at load. **G3 distant water already has
mipmaps.** This plan only touches G4-relevant code paths.

## Verified facts (don't re-investigate)

- `R_UpdateWarpTextures()` (`gl_warp.c:237-291`) is the **only** caller of
  `glCopyTexSubImage2D` for warp textures (line 275). It runs once per
  frame from `gl_rmain.c:602`, gated only by `R_OldWaterEffective()`.
- Mipmap detection lives at `gl_vidsdl.c:1305-1322`. Stores function
  pointer in global `GL_GenerateMipmap`, no boolean `_able` flag.
- Warpimage texture creation at `gl_model.c:864-868`:
  `TEXPREF_NOPICMIP | TEXPREF_WARPIMAGE | (GL_GenerateMipmap ? TEXPREF_MIPMAP : 0)`.
  When SGIS replaces the missing GL_GenerateMipmap, `TEXPREF_MIPMAP` must
  be set differently (the existing condition gates on the function
  pointer).
- Filter for mipmapped textures: `GL_LINEAR_MIPMAP_LINEAR` (default
  `glmodes[NUM_GLMODES-1]`, `gl_texmgr.c:62-71`).
- Per-target autoexec mechanism already exists; G4 has its own
  `autoexec.cfg` per Phase 0 (committed in `3e502882`).
- `host_framecount` is available globally (used for cadence in many
  engine subsystems).

## Strategy: 3 phases, each independently buildable + benchable + revertable

| #     | Phase                                                | Files                            | Risk    | G4 1024 expected   | G4 640 |
|-------|------------------------------------------------------|----------------------------------|---------|--------------------|--------|
| 1.3a  | SGIS detection + capability flag (no behavior change) | gl_vidsdl.c, glquake.h           | trivial | 0                  | 0      |
| 1.3b  | r_waterupdaterate cvar + frame-cadence throttle      | gl_warp.c                        | low     | 0 (cvar default 1) | 0      |
| 1.3c  | SGIS warpimage path + per-target tuning              | gl_texmgr.c, gl_model.c, autoexec | medium  | -3 to +2 fps       | -2 to +1 fps |

Phases ordered by risk and reversibility. Each lands as a single commit;
full bench matrix between commits per existing methodology
(`scripts/full-bench.sh both`, 3× runs, median of 2&3, both targets — even
though G3 won't move, run it to verify zero regression).

---

## Phase 1.3a — SGIS detection + capability flag

**Files:** `Quake/glquake.h`, `Quake/gl_vidsdl.c`

Add a third detection branch after the EXT block at `gl_vidsdl.c:1314-1317`,
matching the existing pattern. `GL_SGIS_generate_mipmap` is the extension
string. There's no function pointer to load (it's a `glTexParameteri`
target), so we just need a boolean.

**glquake.h:** add `extern qboolean gl_sgis_mipmap_able;` near the other
capability externs.

**gl_vidsdl.c:** add `qboolean gl_sgis_mipmap_able = false;` next to
existing flags. In `GL_CheckExtensions` after the EXT framebuffer_object
block, add:

```
else if (COM_CheckParm("-nosgis"))
    Con_Warning("SGIS_generate_mipmap disabled at command line\n");
else if (GL_ParseExtensionList(gl_extensions, "GL_SGIS_generate_mipmap"))
{
    Con_Printf("FOUND: GL_SGIS_generate_mipmap\n");
    gl_sgis_mipmap_able = true;
}
```

The existing "liquids won't have mipmaps" warning at `gl_vidsdl.c:1321`
must move into a final `else` so it only fires when neither ARB, EXT, nor
SGIS is available.

**No behavior change.** Smoke test: boot, exit, confirm the right line
prints in `qconsole.log` on G3 and G4. `-nosgis` provides A/B for 1.3c
without rebuilding.

---

## Phase 1.3b — r_waterupdaterate cvar + frame-cadence throttle

**File:** `Quake/gl_warp.c`

Register a new archived cvar near the existing `r_oldwater` registration
(`gl_warp.c:33`):

```
cvar_t r_waterupdaterate = {"r_waterupdaterate", "1", CVAR_ARCHIVE};
```

Register in the same place `r_oldwater` is registered (search
`Cvar_RegisterVariable (&r_oldwater)`).

Modify `R_UpdateWarpTextures()` near `gl_warp.c:243`, after the
`R_OldWaterEffective` short-circuit:

```
{
    int rate = (int)r_waterupdaterate.value;
    if (rate < 1) rate = 1;
    if (rate > 1 && (host_framecount % rate) != 0)
        return;
}
```

Range-clamp at use, not at registration — keeps cvar idempotent and
allows runtime experimentation. No `Cvar_SetCallback` needed.

At `r_waterupdaterate = 1` (default) the throttle is a single
modulo-against-1 = always-zero check, fully benign. **Phase 1.3b is
zero-impact in default configuration** — provides only the lever for
1.3c.

**Smoke test:** boot, set `r_waterupdaterate 30` in console, look at
water — animation should visibly stutter (one update every half-second
at 60fps). Set back to 1, animation smooth.

---

## Phase 1.3c — SGIS warpimage path + per-target tuning

**Files:** `Quake/gl_model.c`, `Quake/gl_texmgr.c`, `Quake/gl_warp.c`,
`MacOSX/g4-autoexec.cfg`

This phase has three pieces:

### 1.3c.1 — Drop `TEXPREF_MIPMAP` gate to admit SGIS

`gl_model.c:864-868`: change the warpimage flag to also set
`TEXPREF_MIPMAP` when SGIS is available (not just when
`GL_GenerateMipmap` is non-NULL):

```
TEXPREF_NOPICMIP | TEXPREF_WARPIMAGE |
((GL_GenerateMipmap || gl_sgis_mipmap_able) ? TEXPREF_MIPMAP : 0)
```

### 1.3c.2 — Set the SGIS texture parameter at warpimage creation

In `gl_texmgr.c`, at the point where `TEXPREF_MIPMAP` textures get their
filter applied (find via `GL_LINEAR_MIPMAP_LINEAR`, around line 107-108
per the research report), add a `glTexParameteri` for the SGIS hint when
SGIS is the active mipgen path:

```
if (gl_sgis_mipmap_able && !GL_GenerateMipmap)
    glTexParameteri(GL_TEXTURE_2D, GL_GENERATE_MIPMAP_SGIS, GL_TRUE);
```

Place this inside the upload routine that handles `TEXPREF_MIPMAP`. The
parameter is sticky on the texture — set once at creation. SGIS then
triggers automatically on every subsequent `glCopyTexSubImage2D` to that
texture.

If neither SGIS nor `GL_GenerateMipmap` is active, the existing path
falls back to `GL_LINEAR` (no mipmaps). Status quo preserved on hardware
without either extension.

### 1.3c.3 — Drop the explicit `GL_GenerateMipmap` call when SGIS is the path

In `R_UpdateWarpTextures()` at `gl_warp.c:276-277`:

```
if (GL_GenerateMipmap)
    GL_GenerateMipmap(GL_TEXTURE_2D);
/* SGIS path: regeneration is automatic via the texture parameter set
   in TexMgr_Upload, triggered by glCopyTexSubImage2D above. No explicit
   call needed (and would crash — GL_GenerateMipmap is NULL when SGIS is
   the active path). */
```

No code change required — the existing `if (GL_GenerateMipmap)` guard
already handles the NULL case. SGIS path runs the auto-regen via the
preceding `glCopyTexSubImage2D` automatically.

### 1.3c.4 — Per-target tuning

Update `MacOSX/g4-autoexec.cfg` with a recommended starting value:

```
// Throttle warp texture regen to every 4 frames; mipmaps cost ~17ms/frame
// unthrottled on Radeon 9000. N=4 amortizes to ~4.5ms/frame; water
// animation is 60/4 = 15fps which is visually fine.
r_waterupdaterate 4
```

Leave `MacOSX/g3-autoexec.cfg` alone — G3 path is untouched by
`R_OldWaterEffective` short-circuit.

---

## Cuts (deliberately not done)

- **Per-distance LOD-style throttle.** Tempting (close water gets full
  rate, distant water gets throttled) but warpimage is per-texture not
  per-surface, so the throttle decision can't see distance. Skip.
- **Throttle just the regen, not the copy.** Impossible with SGIS — the
  parameter triggers regen *on* the copy. We'd have to switch off SGIS
  per-frame, which is a `glTexParameteri` call per skip — adds work
  rather than saves it. Skip.
- **Manual mipchain generation** (compute mips in CPU and `glTexImage2D`
  level-by-level). Bypasses SGIS entirely. Big code surface, possibly
  faster than software-fallback SGIS. Park as a "1.3 follow-up if SGIS
  N=4 isn't fast enough." Don't write it now.
- **SGIS for non-warp textures.** All other mipmapped textures are
  load-time uploads, not per-frame. They don't benefit from SGIS over
  ARB/EXT. The change is warpimage-specific.

---

## Architecture decisions

1. **Capability flag pattern:** `gl_sgis_mipmap_able` global, mirrors
   `gl_vbo_able`. No function pointer to load. `-nosgis` command-line
   parm mirrors `-novbo`/`-nomtex`/`-nocva` precedent.

2. **Throttle gate placement:** inside `R_UpdateWarpTextures()` itself
   (`gl_warp.c:243`), not at the call site in `gl_rmain.c:602`. Keeps
   the policy local; future caller additions get the gate for free.

3. **Cvar default = 1:** zero behavior change without per-target
   autoexec. G4 opts in via `g4-autoexec.cfg`. Vanilla / unconfigured
   targets get current behavior.

4. **Cvar archived:** persists across runs. Range-clamp at use site, not
   registration, for runtime tweakability.

5. **N=4 starting point:** under modern engine assumptions (60+ fps
   target) gives 15fps water animation. `WARP_CYCLE = 128`
   (`gl_warp.c:WARPCALC` macro family) means a single warp cycle takes
   ~32 seconds at scene `cl.time` rate; per-frame phase delta at 60fps
   is ~0.02 radian. At N=4 the phase jump per update is ~0.08 radian —
   imperceptible. N=8 would jump ~0.16 radian, faintly visible on still
   water. Don't go above N=8 by default.

---

## Critical files

- `Quake/glquake.h` — `extern qboolean gl_sgis_mipmap_able;`
- `Quake/gl_vidsdl.c:147,1305-1322` — flag init, SGIS detection branch
- `Quake/gl_warp.c:33` — `r_waterupdaterate` cvar registration
- `Quake/gl_warp.c:243` — frame-cadence gate
- `Quake/gl_warp.c:276-277` — comment update; no logic change (existing
  NULL guard handles SGIS path)
- `Quake/gl_model.c:864-868` — warpimage flag includes SGIS
- `Quake/gl_texmgr.c:~107` — SGIS texture parameter set on
  `TEXPREF_MIPMAP` uploads
- `MacOSX/g4-autoexec.cfg` — per-target `r_waterupdaterate 4`

---

## Verification

**Per-phase smoke test:**

1. `scripts/build.sh g3 && scripts/build.sh g4` — both must compile
   clean.
2. Phase 1.3a: confirm log line `FOUND: GL_SGIS_generate_mipmap` (or
   the ARB/EXT line if those exist) on each target. G4 expected to hit
   SGIS branch; G3 may hit it or hit the warning depending on Rage
   driver.
3. Phase 1.3b: with default `r_waterupdaterate 1`, no visual change.
   Set to 30 and confirm water visibly stutters (sanity check the
   gate). Reset to 1.
4. Phase 1.3c: warp textures bind with `GL_LINEAR_MIPMAP_LINEAR`;
   distant water visibly less aliased. Bench at G4 default
   `r_waterupdaterate 4`. Compare to baseline.

**Per-phase bench protocol:**

- `scripts/full-bench.sh both` — 3 runs × demo1/demo2/demo3 × G3/G4 ×
  640/1024
- Median of runs 2 and 3 per cell
- Phase 1.3a: confirm both targets at baseline ±1 fps (zero behavior).
- Phase 1.3b: confirm both targets at baseline ±1 fps (default cvar = 1
  is no-op).
- Phase 1.3c at G4 with `r_waterupdaterate 4`: target ±3 fps vs 1.3b
  with mipmapped distance water visible. **If we see >5 fps loss at
  N=4, bump default to N=8 and re-bench. If still >5 fps loss at N=8,
  shelve SGIS path entirely** — manual mipchain becomes the
  alternative.
- G3 at all phases: must remain at baseline (unchanged code path).

**Visual verification:**

- G4 demo1 frame ~1500: screenshot the water surface in E1M2 (visible
  pool) before and after. Look for mipmap LOD transitions on distant
  water (smoother gradient, no shimmer).
- Compare against G3 baseline (which already has mipmaps in classic
  warp path) — G4 should now look closer to G3 quality on liquid
  surfaces.
- A/B with `-nosgis` command-line flag to flip back to no-mipmap
  baseline at runtime.

**Cumulative bench at end of 1.3c:** full grid into
`benchmarks/results.csv`, tag the row `1.3-complete`. Expect G4 1024
within 3 fps of pre-1.3 baseline; mipmap visual quality recovered.

**Revert safety:** every phase is one commit on top of HEAD. 1.3a–1.3c
each fully revertable via `git revert <hash>` without touching others —
they share only the additive `gl_sgis_mipmap_able` global, which is
harmless to leave in even if 1.3b/1.3c revert.
