# Toggleable knobs inventory

Every per-target visual / perf decision shipped to date can be flipped
without rebuild — most via cvars, some via launch-time `-flag` parsed
in the relevant `*_Init`. **Toggleability is a hard project requirement**
so end-of-round code review can A/B individual contributions without
rebuild. Per-machine shipping defaults live in
`scripts/bundle/autoexec-<machine>.cfg`.

Updated 2026-05-11.

## AltiVec phase opt-outs (cmdline, G4 only — `-flag` to disable)

| Flag             | Phase  | Default     | What it gates                                  | File parsed |
|------------------|--------|-------------|------------------------------------------------|-------------|
| `-noaltivec-snd` | 4.2    | enabled     | 16-bit sound mixer (`SND_PaintChannelFrom16`)  | `snd_dma.c` `S_Init` |
| `-noaltivec-lm`  | 4.4    | **enabled** (v8.1 flipped 2026-05-10) | Lightmap compose loop (`R_BuildLightMap`). Was opt-in until v8.1; round v3 retest 2026-05-08 reclassified as net-zero (not regressed) so the conservative default became defeating-the-point. v8.1 made it the G4 default — pass `-noaltivec-lm` to disable. The legacy `-altivec-lm` remains as a backward-compat no-op. | `gl_rmisc.c` `R_Init` |
| `-noaltivec-mip` | 4.5    | enabled     | Mipmap chain build (`TexMgr_MipMap{W,H}`) — load-time only | `gl_texmgr.c` `TexMgr_Init` |
| `-noaltivec-dlights` | §14.3 item 4 | **enabled** (v8.1 flipped 2026-05-10) | Per-texel attenuation in `R_AddDynamicLights`. Was opt-in until v8.1; round v3 retest 2026-05-08 confirmed neutral. Flipped to default-enabled alongside `-noaltivec-lm`. The legacy `-altivec-dlights` remains as a backward-compat no-op. | `gl_rmisc.c` `R_Init` |

## Diagnostics (cmdline + cvar, both targets)

| Flag/cvar      | Phase | Default | What it does |
|----------------|-------|---------|--------------|
| `-perfprint` (cmdline) / `gl_perfprint` (cvar) | 7 | 0 (silent) | Per-region renderer timing every 60 frames — see Quake/gl_perfprint.h for region list |

## Visual cvars (runtime, set in per-machine autoexec)

Per-machine configs live at
`scripts/bundle/autoexec-{yosemite,sawtooth,quicksilver,mini-g4,mini-intel,imac-2019}.cfg`.

| Cvar                    | G3 default | G4 default | Lion default | Notes |
|-------------------------|------------|------------|--------------|-------|
| `r_oldwater`            | 1 (classic warp) | 0 (new shader) | (engine default) | G3 set 1 because Rage 128 R128 has a refraction bug at 640 with new shader; G4 has the headroom. Phase 0 + Round v2 epilogue. |
| `r_particles`           | 2          | (default 1) | (default)    | G3 reduced particle quality. Phase 0. |
| `gl_texture_anisotropy` | 2 (v1.5; silent no-op on R128 driver) | 8 | (default) | G4 anisotropic filtering. Phase 0. G3 set defensively in case a future driver build exposes the ext (qconsole confirms `texture_filter_anisotropic not supported` on current Panther driver). |
| `r_shadows`             | (default 0) | 1           | (default)    | G4 alias drop-shadow. §13.6, costs -11% but stays > 60 fps. Defensively re-cleared in autoexec because CVAR_ARCHIVE makes a stale `1` from any past session sticky. |
| `gl_texturemode`        | (default GL_LINEAR_MIPMAP_NEAREST) | `GL_LINEAR_MIPMAP_LINEAR` (trilinear) | (default) | G4 trilinear pairs with anisotropy 8. §13.6. |
| `r_shadow_distance`     | (default 0 = unlimited) | 512 | 512 | Pass C HIGH (Round v3 Task #10): elide shadow draws past N units from viewer. Engine default 0 preserves upstream; G4 sets 512 for ~4-7% on dlight-heavy demos. Lion mirror added Round v5 wrap pass 2 (2026-05-09) to free GMA 950 fillrate on demo3 1024 (was fillrate-bound at 44.90 fps with shadows + trilinear + aniso). Squared compare in `R_DrawShadows`. |
| `gl_texture_lodbias`    | (default 0)            | -1.5         | 0            | Round v4 Task #20: bias the diffuse-texture mipmap LOD selection. User reported soft mips on G4 / Radeon 9000 distant brick walls; Lion / GMA 950 unaffected on the same engine. Negative pulls sharper mip chains. Wired via `glTexEnvf(GL_TEXTURE_FILTER_CONTROL_EXT, GL_TEXTURE_LOD_BIAS_EXT, …)` in `gl_texmgr.c`. Inert if neither GL 1.4 nor `EXT_texture_lod_bias` is present (R128 falls back silently). |
| `r_dynamic_distance`    | 768                    | (default 0)  | (default 0)  | Round v5 B1: elide dlight BSP-mark + surface-reblend pass past N units from viewer. R128 has no fragment-shader dlight path, so each dlight = full extra GPU pass per touched surface. G3 GPU-bound regime ⇒ removing GPU work is the only fps lever. G4/Lion left at 0 = unlimited (they have headroom). Squared compare in `R_PushDlights`. Headline G3 lever — expect +5–15% on demo3 (dlight-heavy). |
| `r_wateralpha`          | 0.6                    | 0.6 (all 3)  | 0.6          | Round v5 wrap pass 2 (2026-05-09): plain water translucency. Same path as the existing `r_lavaalpha`/`r_telealpha`/`r_slimealpha` 0.6 family — see-through liquid surfaces. On classic-warp targets (yosemite/sawtooth/mini-intel) goes through the `R_DrawTextureChains_Water` `R_OldWaterEffective()` branch; on shader-water targets (quicksilver/mini-g4) goes through the GLSL alpha uniform. Negligible cost across all targets. |
| `r_lavaalpha` / `r_telealpha` / `r_slimealpha` | (default 1.0 = opaque) | 0.6 (all 3) | 0.6 | **Round v5 wrap polish enabled liquid alpha across yosemite + 3 G4s + mini-intel.** Round v8 followup (2026-05-10): bisect on yosemite demo3 1024 (e1m6 lava-heavy) showed `r_lavaalpha 0.6` alone drops fps from 19.65 → 14.40 (-26%), pushing G3 below the 20-fps floor. Tele + slime alpha together also showed regression on the same bisect. Decision: drop `r_lavaalpha`/`r_telealpha`/`r_slimealpha` on G3 (autoexec-yosemite.cfg), keep `r_wateralpha 0.6` (water see-through is the most-common transparent-liquid effect in regular play). G4 trio + Lion + iMac keep all four liquid alphas (different fillrate envelope). Possible follow-up: add `r_lavaalpha_distance` mirroring `r_dynamic_distance` so close-up lava can blend while far-field stays opaque. |
| `gl_clear`              | 0 | 0 (quicksilver + mini-g4 only — sawtooth stays at 1) | 0 | Round v5 wrap pass 3 (2026-05-09): skip per-frame backbuffer clear. Quake's world+sky covers 100% of the screen so the clear is a redundant fillrate-bound write. Wins: yosemite +4.7%, mini-intel +3.5%, quicksilver +7.1%, mini-g4 +9.3% on demo3 1024. **Sawtooth regresses -2.1%** (GeForce2 MX driver quirk — no-clear path is slower than the explicit clear), so sawtooth stays at engine default 1. Visually verified clean on yosemite e1m1 (sky + water — no ghosting at sky edges, no garbage artifacts). |

## Round v8 lightmap + multitex hygiene knobs (2026-05-10)

| Knob                     | Type    | Default | What it gates                                                    | File parsed |
|--------------------------|---------|---------|------------------------------------------------------------------|-------------|
| `gl_lightmap_subrect`    | cvar (CVAR_ARCHIVE) | 1 (on) | **Round v8 item 1 — subrect lightmap upload.** Pre-v8 the per-frame `glTexSubImage2D` in `R_UploadLightmap` ignored the dirty rect's `l`/`w` and uploaded the full LMBLOCK_WIDTH (256-pixel) row regardless of the actual touched extent. Honoring `rectchange.l/w` plus `glPixelStorei(GL_UNPACK_ROW_LENGTH, LMBLOCK_WIDTH)` cuts upload bytes by ~16× for typical 16×16 dlight touches. Visually identical (same pixel data, narrower frame). G3-headline lever — pure AGP bandwidth win exactly where R128 is bottlenecked. | `gl_rmisc.c` `R_Init` |
| `-nomtexhoist`           | cmdline | enabled | **Round v8 item 2 — multitex enable/disable hoist.** Default-on path enables TMU1 once before `R_DrawTextureChains_Multitexture`'s texture loop and disables it once after, instead of toggling per chain (~30-50× per frame in pre-v8). Hygiene cleanup; sub-1% on R128 (driver shrugs at no-op enables). Pass `-nomtexhoist` to revert to per-chain toggles. | `gl_rmisc.c` `R_Init` |
| `-nodirtylmlist`         | cmdline | enabled | **Round v8 item 3 — dirty-lightmap list.** Default-on path tracks dirty lightmap indices in an int[] populated at the modified-edge in `R_RenderDynamicLightmaps` so `R_UploadLightmaps` walks only dirty entries instead of all `lightmap_count`. Sub-1% on G3 (pre-v8 walk is L1-resident). Pass `-nodirtylmlist` to revert to the linear walk. | `gl_rmisc.c` `R_Init` |
| `-nolmunroll`            | cmdline | enabled | **Round v8 item 4 — 2-texel scalar unroll in `R_BuildLightMap`.** G3-only relevant (G4 takes the `__ALTIVEC__` path when not opt-out). Batches 6 byte loads ahead of 6 mul-adds to expose ILP to PPC 750's integer pipeline. Up to ~2% best case on dlight-heavy demos. Pass `-nolmunroll` to revert to the per-texel form. | `gl_rmisc.c` `R_Init` |

## Round v11 alias state-cache knob (2026-05-11)

| Knob | Type | Default | What it gates | File |
|------|------|---------|---------------|------|
| `gl_aliasstate_cache` | cvar (CVAR_ARCHIVE) | 1 (on) on G4/Lion/iMac slices; **compile-time excluded on G3 ppc750 slice** via `QS_DISABLE_ALIAS_STATE_CACHE` in `r_alias.c` | **Round v11 — per-frame GL state cache in `R_DrawAliasModel`.** Intercepts `glTexEnvf(GL_TEXTURE_ENV_MODE, ...)`, `glDepthMask`, and `glEnable/Disable(GL_BLEND)` and no-ops calls that match the cached value. `R_DrawAliasModel` is the hottest state-change site in the engine (~50 calls per alias entity in default config, ~46 of which the cache helpers wrap); each case path's explicit "reset to REPLACE/TRUE/disable" at the end of its block is followed by the function-end cleanup label re-emitting the same defensive resets. The cache catches the cleanup-line redundancy and the rare adjacent same-value calls across case paths. TexEnvMode is tracked per-active-TMU (via `mtexenabled`) so multitex paths cache correctly. Same-session A/B bench data: sawtooth +31.5%, quicksilver +38.1%, mini-g4 +44.9%, mini-intel +21.2%, imac-2019 +16.0%, **yosemite −4.1%** (the regression that drives the compile-time exclusion on G3). Reset once per frame from `R_RenderScene` (`gl_rmain.c:1126`). Cvar registered conditionally in `gl_rmisc.c` `R_Init`. | `r_alias.c`, `gl_rmain.c`, `gl_rmisc.c` |

## v1.5 Q2-borrow round (2026-05-24)

| Knob | Type | Default | What it gates | File |
|------|------|---------|---------------|------|
| `gl_fog` | cvar (CVAR_ARCHIVE) | 0 (off) | **Cvar-driven default fog** for maps that don't ship `_fog` in worldspawn. When enabled and the loaded map has no fog AND nobody has typed `fog <args>` this map, the engine uses `gl_fog_density` / `gl_fog_red` / `gl_fog_green` / `gl_fog_blue` (also CVAR_ARCHIVE, defaults `0.05 / 0.3 / 0.3 / 0.3`). Map-shipped fog and the `fog` console command always win when present; `fog 0` from console truly disables (tracked via `fog_explicit` flag reset on map load). Adapted from yquake2-ppc commit `c3d1de3`. | `gl_fog.c` `Fog_Init` |
| `r_waterwarp` | cvar (was `CVAR_NONE` → `CVAR_ARCHIVE`) | 1 (full magnitude) | Underwater FOV sine-wobble. Now doubles as a magnitude scale (clamped 0..1): `r_waterwarp 0.5` halves the wobble, `0` disables. Formula matches the original FitzQuake effect at the default value. Persistence flip lets per-machine autoexec dial it down without rebuild. | `gl_warp.c`, `gl_rmain.c` |

## Framebuffer depth + MSAA per-machine (2026-05-29, code-review cheap wins)

| Knob | Type | Per-machine default | What it gates | File |
|------|------|---------------------|---------------|------|
| `vid_bpp` | cvar (CVAR_ARCHIVE) | **32** quicksilver + imac-2019; **16** (engine default) everywhere else | Colour depth, but really the depth/stencil allocation: `vid_bpp 16` → 16-bit z-buffer + **0 stencil** (so `r_shadows`' stencil self-intersection mask is inert — gl_rmain.c:1081 `if (gl_stencilbits)`); `vid_bpp 32` → 24-bit z-buffer + 8-bit stencil. Set 32 on quicksilver (Radeon 9000, verified +stencil shadows + 24-bit depth for ~3%, holds 60 floor) and imac-2019 (unverified — machine was offline). **NOT** on mini-g4 (Radeon 9200 hard-wedges intermittently on the 32bpp boot vid_restart — see MISTAKES.md 2026-05-29), nor on the fillrate-bound G3/sawtooth/mini-intel. Needs a boot `vid_restart` in the per-machine autoexec to apply (VID_Init runs before the autoexec). | `scripts/bundle/autoexec-{quicksilver,imac-2019}.cfg` |
| `vid_fsaa` | cvar (CVAR_ARCHIVE) | **8** imac-2019 only; 0 elsewhere | MSAA sample count. Only imac-2019's Radeon Pro 580X gets it (8x — "spend the headroom"); the PPC GPUs lack `ARB_multisample` (sawtooth, G3) or are fillrate-bound near floor (Radeons/GMA950). **Required engine fix:** `VID_Restart` (gl_vidsdl.c) now re-reads the file-scope `fsaa` global from `vid_fsaa` before `VID_SetMode` — upstream only set it in VID_Init / `-fsaa` cmdline, so a `vid_fsaa` in autoexec + `vid_restart` was silently ignored. Inert where `vid_fsaa` is 0. | `gl_vidsdl.c` `VID_Restart`; `scripts/bundle/autoexec-imac-2019.cfg` |

## G3 client-array brush pool (2026-05-29, code-review finding #4)

`-g3clbrush` (cmdline, G3/Rage128 only — inert where `gl_apple_var_able`)
builds the same contiguous brush-vert pool the G4/Lion VAR path uses, but
in plain application memory (no `APPLE_vertex_array_range` registration),
so the world multitexture pass binds vertex/texcoord pointers ONCE at the
pool base and issues one `glDrawArrays(var_firstvert)` per surface instead
of the legacy per-vertex `glBegin` trampoline (`R_DrawTextureChains_Multi`
else branch, `r_world.c`). Shares the `BMODEL_POOL_LIVE` predicate +
build/delete path with the VAR pool; only the APPLE range registration is
gated to VAR mode (`r_brush.c`). **Default OFF.** Same-session yosemite
A/B 2026-05-29: NET-NEUTRAL at 800×600 (demo1 27.90→27.85, demo3
30.05→30.05) — G3 is GPU/fillrate-bound so removing CPU draw-dispatch
frees headroom without moving fps. Notably NOT a regression (the bind-once
design avoided the MISTAKES.md Phase 1.1c −3–4% client-array regression).
Kept as an inert lever for a future less-GPU-bound G-class target (e.g. a
G4/nVidia or faster-GPU machine running the ppc750 slice). Parsed in
`gl_vidsdl.c` `GL_CheckExtensions`.

## §14.3 hygiene flag

`-nowarpedarrays` falls the `R_UpdateWarpTextures` water-warp
procedural-update loop back to its pre-§14.3 glBegin/glEnd path.
Default is the new client-array path (submission-overhead reduction;
smoke neutral on standard demos because they barely exercise warp updates).

## Pass B B6 retest hatch

`-r128-cva` (G3 only — Rage 128 detection) overrides the default skip
of `glLockArraysEXT` on R128 so we can revisit whether the Phase 2.x
lightmap pipeline incidentally fixed the in-game colour-band corruption.
Default unchanged: R128 still skips Lock automatically. Parsed in
`gl_vidsdl.c` `GL_CheckExtensions`. G4/Lion are unaffected — they get
CVA Lock as before.

## Hard-coded (no runtime toggle yet)

Flag if a future round wants to A/B these: Phase 1 `frsqrte` mathlib,
Phase 1.1 client vertex arrays + CVA, Phase 2.1 BGRA `8_8_8_8_REV`
lightmap upload, Phase 2.2 APPLE_client_storage, Phase 2.3
STORAGE_CACHED_APPLE per-texture hint, Phase 3.1/3.2/3.3
APPLE_vertex_array_range pool + multitex array conversion, Phase 4.1 +
4.6 alias lerp + color fuse AltiVec. Most are foundational and
bisected at landing time; not worth a runtime toggle unless a
regression is suspected. Add a `-noaltivec-lerp` (Phase 4.1 + 4.6)
follow-up if end-of-round review wants to A/B alias-side AltiVec
specifically.

## Why this matters

Project goal is best-looking Quake at playable fps; the only way to
navigate that trade-space honestly is to be able to flip individual
contributions at runtime and watch fps + visuals together. Gate any
new perf or visual phase behind a named knob unless you have a strong
reason not to (e.g. a code-size win that's only realised by removing
the scalar fallback).
