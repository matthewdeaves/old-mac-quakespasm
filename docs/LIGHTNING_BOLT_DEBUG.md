# Lightning bolt brightness: SOLVED (2026-06-06)

**Symptom (original):** the thunderbolt beam (player lightning gun) rendered the
main bolt too dark / black instead of bright light blue. Worse outdoors. Split
across GPUs: G5 (R300) looked OK, mini-g4 (R200) and mini-intel (GMA 950) dark.

## Root cause (proven from the asset, not theory)

`progs/bolt2.mdl`'s skin (308×36) was decoded straight out of `id1/pak0.pak`
(`/tmp/decode_bolt.py`). Findings:

- **67% of the skin is pure black** (palette index 0). The zigzag bolt occupies
  only ~1/3 of the texture.
- The **bright cyan/white core uses palette indices 244, 245, 246, 253, 254**,
  all in Quake's **fullbright range (224-255)**. 24% of the skin is fullbright.

Therefore `Mod_CheckFullbrights` (gl_model.c:595, returns true for any pixel
>223) is TRUE for this skin, so `Mod_LoadAllSkins` (gl_model.c:3282) **splits
it**: the base texture (`gltextures`) is loaded `TEXPREF_NOBRIGHT`, **the bright
core is blacked OUT of the base**, and the core is moved into the `fb` mask
(`fbtextures`).

So the bolt's bright appearance comes almost entirely from the **additive
fullbright pass**, NOT the lit base. The bolt is only correct when the unlit
base AND the additive fb core are both drawn. Anything that draws the base alone
shows a bolt with its bright core removed = dark.

This invalidated the old hand-off's central assumption ("fb == NULL, no
fullbright mask"). Every prior fix failed for the same reason:

- **Approach 3** (flat fullbright, base only, no fb pass) → dark, because it drew
  the NOBRIGHT base with the core missing.
- **Approach 5** (flat `GL_REPLACE`, base only) → the deployed build; drew the
  NOBRIGHT base = dark core on R200/GMA950. (R300 happened to apply a leftover
  RGB_SCALE that lifted the dim base, so G5 looked passable, the GPU split was
  a red herring, not a driver-correctness story.)
- The lit paths went black **outdoors** because the bolt is a temp entity that
  gets **no min-light floor** (only viewent/players do), so `R_LightPoint`
  returns ~0 and the lit base * light = 0.

Also note: the G5 no longer runs `gl_fullbrights 0` (it moved to
`gl_fullbright_zbias 1`, commit cdda2a5b's successor). **All three machines now
run `gl_fullbrights 1`**, so the fb core pass is available on every target.

## The fix (r_alias.c: R_DrawAliasModel)

Detect beam models (`strstr name "bolt"/"beam"`) and route them through a
dedicated **fullbright-unlit** branch, inserted after the cheat-safe modes and
before the GLSL/overbright dispatch:

1. Draw the base unlit at full skin brightness, `shading=false`,
   `glColor4f(1,1,1,entalpha)`, `GL_MODULATE`, so it never darkens with world
   light (bright indoors AND outdoors).
2. Add the fb core back in an additive (`GL_ONE,GL_ONE`) unlit pass, with `fb`
   taken straight from `paliashdr->fbtextures[...]` so the core survives even on
   a target running `gl_fullbrights 0`.

This is the engine's own `r_fullbright_cheatsafe` pass shape, plain GL 1.1,
which every driver in the fleet (R300 / R200 / GMA 950 + the GLSL targets) draws
identically. No overbright-combine GPU-path variance, no dependence on
`R_LightPoint`. The `lightcolor` override hack in R_SetupAliasLighting was
removed.

## Verification

Build: full 4-arch fat via `scripts/build-fat.sh`. Deployed to mini-intel,
mini-g4, imac-g5; hardware-tested with the lightning gun in e1m1, indoors and
outdoors, on all three.

## Decode tool

`/tmp/decode_bolt.py` (pulls `gfx/palette.lmp` + `progs/bolt2.mdl` from a copy of
pak0.pak, prints luminance stats + an ASCII brightness map + fullbright-range
coverage). Re-run if any future beam-skin question comes up.
