# QuakeSpasm PPC port: static-analysis Pass B (cleanup triage)

> Research-only report. 2026-05-08. Successor to
> `docs/research/build-warning-survey.md`. Goal per the user's
> 2026-05-08 policy: **don't just silence warnings, find code that's
> dead, code that's inefficient, latent bugs, *and* code that's dead
> only because of an `#if 0` / unset cvar / undetected extension and
> would arguably contribute to the project's "best looking + playable
> fps" goal if revived.**
>
> This pass goes deeper than the prior survey: cppcheck `--enable=all`
> on Ubuntu (553 raw findings, post-noise filter), gcc-4.0
> `-Wstrict-aliasing=2 -Wpointer-arith -Wundef -Wconversion
> -Wunreachable-code -Wunused-function -Wunused-value` on the G4
> build, and a manual `#if 0` / cvar-default audit. Findings are
> classified into four buckets: **A. Kill** (truly unreachable),
> **B. Revive** (gated-off but worth turning on for the project goal
> pivot), **C. Latent bug** (works today, undefined or near-miss),
> **D. Style/noise** (only items the prior pass missed).

## Tooling outcome

| Tool | Host | Outcome | Total raw / interesting |
|---|---|---|---|
| **scan-build** (clang) | Lion | **Not installed.** `which scan-build` returns nothing on Lion (Apple clang 1.7 / Xcode 4.6.x ships scan-build but the QS Lion toolchain box was bootstrapped with the older Xcode 3.2.6 install where scan-build never made it onto `$PATH`). Skipped. | n/a |
| **gcc-4.0 strict pass (G3)** | Lion | Default `-Wall -O3` already clean. Adding `-Wstrict-aliasing=2 -Wpointer-arith -Wundef -Wconversion -Wunreachable-code -Wunused-function -Wunused-value`: clean too. | 0 warnings |
| **gcc-4.0 strict pass (G4)** | Lion | Same flag set surfaces 1,613 warnings: 73 × `will never be executed` (most are `Sys_Error` / `Host_Error` not marked `noreturn`, false-positive idiom), and ~1,540 × `passing argument N of FOO with different width / as floating rather than integer / as signed due to prototype` (pure `-Wconversion` noise from gcc-4.0's K&R-era sense of "promotion mismatch"). | 73 unreachable + ~1,540 conversion noise |
| **cppcheck 2.17.1** (Ubuntu) | local | Full repo: 553 findings (468 style, 56 warning, 22 error, 8 portability) after suppressing `missingInclude`, `toomanyconfigs`, `normalCheckLevelMaxBranches`. Vendored code (lodepng, miniz, snd_umx, opus headers) generates ~30% of those, filtered out below. | 22 error / 13 warning / 7 portability after filter |
| **`#if 0` audit** | local | 25 hits in `Quake/`. 6 in vendored `miniz.c`/`miniz.h`/`stb_image_write.h` (skip). 19 in our code; categorised below. | 19 |
| **Cvar default audit** | local | ~165 cvars ship `"0"`. Of those, 12 are user-tuneable graphics levers; the rest are debug/diagnostic flags (correct default). 4 candidates flagged for revisit under the project goal. | 4 candidates |

`cppcheck` and the gcc-4.0 unreachable list are the load-bearing inputs.
The "due to prototype" warnings from `-Wconversion` were dropped wholesale
, they're K&R-era promotion warnings, not actual conversion bugs, and the
prior survey already correctly identified `-Wconversion` as not adoptable.

---

## A. Kill (truly unreachable / vestigial)

Items in this bucket can be deleted with no behaviour change on any
target. None affects fps directly; they reduce surface area for the
"every codepath we ship must be either reachable or document why it's
not" review pass.

### A1. `mathlib.c:505-512`  `Invert24To16`

**What:** Software-renderer fixed-point reciprocal helper, converts
8.24 fixed to 16.16 fixed via double precision and a magic
`0x10000 * 0x1000000 / val` constant.

**Why kill:** Defined in `mathlib.c`, declared in `mathlib.h:98`, called
**zero** times in the entire tree (`grep -rn Invert24To16 Quake/` returns
only the declaration and definition). It existed for the WinQuake
software rasteriser's perspective-correct affine span loop, which
QuakeSpasm dropped before this fork. Also triggers cppcheck
`floatConversionOverflow` warning at line 510 (the constant
`0x10000 * 0x1000000 = 4.29e9` overflows `int32_t`, only safe because
the result is stored in a `fixed16_t` typedef'd to unsigned).

**Action:** Delete function body + header declaration. No callers, no
re-introduction risk. **Trivial.**

### A2. `mathlib.c:96-115` `FloorDivMod`: `:120-128` `GreatestCommonDivisor`, `:194-220` `Q_log2`, `:230-260` `R_ConcatRotations`, `:265-310` `R_ConcatTransforms`, `:90-95` `VectorInverse`

**What:** Six more software-renderer-era helpers in the same file. Tree-grep
confirms all six are defined/declared but called nowhere outside `mathlib.c`
itself.

**Why kill:** Same lineage as A1. WinQuake's `R_AliasTransformVector` and
`R_AliasTransformFinalVert` used these; QuakeSpasm's `r_alias.c` does the
work inline. `Q_log2` is shadowed by the libc `log2()` modern code uses.
`R_ConcatRotations`/`R_ConcatTransforms` would have been useful for the
software model rasteriser's matrix-stack path; the GL path uses
`glLoadMatrix` instead.

**Action:** Delete bodies + header declarations. **Trivial.**
**Combined with A1, this trims ~150 LOC from mathlib.c** without
touching anything callers reach.

### A3. Most `#if 0` blocks: historical-only

| Location | Kept-disabled context | Verdict |
|---|---|---|
| `cl_main.c:768-786` `CL_Viewpos_f` `#if 0` camera-vs-player | author left both impls in; chose the `#else` | KILL the `#if 0` half, keep the active half |
| `cl_demo.c:267-270` `#if 0 Con_Printf("...already connected...")` | early-disconnect message replaced by a different one a few lines below | KILL |
| `menu.c:1160-1165` `M_DrawCheckbox` `#if 0` glyph version | the active `M_Print "on"/"off"` text version replaced it | KILL the disabled glyph version |
| `mathlib.c:108-113` `anglemod` original `#if 0` reduction | replaced by single-line bitmask form below; kept for reference | KILL the `#if 0` |
| `mathlib.c:132-143` `BoxOnPlaneSide` early-exit comment-noted as macro-handled upstream | comment `// this is done by the BOX_ON_PLANE_SIDE macro before calling this function` is correct; the inner block is genuinely unreachable | KILL the `#if 0` |
| `mathlib.c:159-183` `BoxOnPlaneSide` alternative formulation | original draft, replaced by the active block at 185-201 | KILL |
| `cl_parse.c:964-1000` `#if 0 CL_DumpPacket` | "for debugging. from fteqw.", a debug helper that was never wired to a console command | KILL (or: see B1 below) |
| `pr_cmds.c:747-751` `static void PF_checkpos (void) {}` `#if 0` | `FIXME: make work...`, empty stub, never called even with `#if 0` removed | KILL |
| `pr_edict.c:1369-1389` two `#if 0` blocks in `PR_SetEngineString` | author's notes-to-self about an engine-string bounds check that's ABI-unsafe (`sv.model_precache` points into `pr_strings`); cannot be turned on | KILL the comments + dead blocks; keep the comment explaining why |
| `gl_model.c:2355-2395` `Mod_BoundsFromClipNode` | comment says "disabled for now becuase it fucks up on rotating models", known wrong with submodels | KILL the function definition; KILL the commented-out call at line 2628 |
| `world.c:870-873` `SV_MoveBounds` `#if 0` debug-against-everything | author's debug fallback, never enabled | KILL |
| `snd_mem.c:233-249` `DumpChunks` + `:281-283` `#if 0 DumpChunks();` | wav-loader debug helper, never bound to anything | KILL |
| `pr_edict.c:1383-1389` `for (i = 0; ...) if (!pr_knownstrings[i]) break` | author chose linear append at the end instead of slot-reuse | KILL the disabled slot-reuse loop (linear append is correct for pr_knownstrings semantics) |

**Aggregate effort:** mechanical delete pass. Zero risk. **Trivial.**
~200 LOC removed.

### A4. `sbar.c:1116` `x += pic ? pic->width : 24`

**What:** Width-or-fallback ternary. Cppcheck flags the condition as
always-true.

**Why kill:** Three lines above (`if (!pic) continue;`) makes `pic`
guaranteed non-null at line 1116. The `: 24` branch is dead.

**Action:** Replace with `x += pic->width;`. **Trivial.**

### A5. `cd_sdl.c:569-574` `hw_vol_works` always false

**What:** `hw_vol_works = CD_GetVolume (NULL); /* no SDL support at present. */`
followed by `if (hw_vol_works) ...`.

**Why kill:** `CD_GetVolume` at line 373 is a stub that always returns 0.
The if-branch at 570-574 is unreachable. The guard exists in case SDL
ever grows CD-volume APIs, but SDL 1.2 hasn't and SDL 2 dropped CD
support entirely.

**Action:** Delete the `hw_vol_works` variable and the if-branch.
The stub `CD_GetVolume` / `CD_SetVolume` callbacks should also drop
their `void *unused` params (cppcheck's `constParameterPointer`
flags them). **Trivial.**

---

## B. Revive (dead-by-toggle: turn on for the goal)

These are the most interesting findings per the user's policy. Each is
code that was deliberately written, tested, and gated off, not deleted.
The project goal pivot from "ship a stable port" to "best looking +
playable fps" makes some of them attractive again.

### B1. `sbar.c:653` `flashon = 0;` kills item-pickup HUD flash

**What:** `Sbar_DrawInventory` originally flashed the item icons (keys,
runes, sigil, etc.) when newly picked up, same UI feel as the weapon
flash above (lines 543-563). The author hard-coded `flashon = 0` at
line 653, making the conditional at line 660 (`if (time && time >
cl.time - 2 && flashon)`) always take the no-flash branch. The else
branch with the actual `Sbar_DrawPic` call is fine, so items still
draw, they just don't flash.

**Why revive:** Project goal is **best looking + playable fps**. The
flash is a visual quality feature original to Quake. Removing the
hard-zero (or replacing it with the same `(int)((cl.time - time)*10)`
expression as the weapon block) restores the original behaviour. The
weapon flash already works; this is just symmetry. Cost is ~zero fps
(one extra `Sbar_DrawPic` per flashing slot, only on pickup, lasts
2 seconds).

**Action:** Replace `flashon = 0;` at line 653 with the same
`flashon = (int)((cl.time - time)*10); if (flashon >= 10) flashon = 0;
else flashon = (flashon%5) + 2;` shape used at lines 547-557. The else
branch at 664 needs to honour `flashon` (probably a separate
`hsb_items` lookup keyed by `flashon`). Smoke-test by picking up a key
in e1m4 and watching the inventory bar. **Small** (1 hour).

**Predicted impact:** Visual upgrade (HUD flash on item pickup).
Zero fps, happens once per pickup over 2 seconds.

### B2. `cl_parse.c:964-1000` `CL_DumpPacket` debug helper

**What:** Static debug function that hex-dumps the current network
packet. Header comment "for debugging. from fteqw.", it's a debug
helper from a sibling engine, ported and gated off.

**Why revive:** Not an fps win, but a *project* tooling win, we've
spent debug cycles on G3 demo3 dynamic-light analysis where
`Con_Printf` per-byte tracing would have helped. A bound `dumppacket`
console command (`Cmd_AddCommand("dumppacket", CL_DumpPacket_f)`)
would be useful for future protocol-level debugging on PPC where
`tcpdump`-style tools aren't easy to run.

**Action:** Wrap in a `Cmd_AddCommand` registration in
`CL_InitInput`/`CL_Init`. Drop the `#if 0`. Compile-time cost zero
(unused unless invoked). **Trivial** (5 min).

**Predicted impact:** Tooling convenience. Zero perf, zero visual.

### B3. Cvar defaults to revisit under the goal pivot

The prior survey did not look at cvar defaults. The goal pivot makes
this worth a short audit.

| Cvar | Default | Verdict |
|---|---|---|
| `r_shadows` (gl_rmain.c:66, CVAR_ARCHIVE) | `"0"` | **Revive candidate.** Drop-shadows under alias models are visually significant on G4 (free-ish on Radeon 9000). G3/R128 may not afford it. Suggest per-target default in `scripts/bundle/autoexec-{g3,g4}.cfg`: G4 `"1"`, G3 leave `"0"`. **Bench at end-of-round.** |
| `r_lerpmodels` / `r_lerpmove` (gl_rmain.c:96-97) | both `"1"` | already on. Keep. |
| `r_drawentities` `r_drawviewmodel` (gl_rmain.c:60-61) | both `"1"` | correct. |
| `gl_overbright` `gl_overbright_models` (gl_rmain.c:90-91) | both `"1"` | correct. Both on. |
| `r_skyfog` (gl_sky.c:50) | `"0.5"` | already a sensible default. |
| `r_telealpha` `r_lavaalpha` `r_slimealpha` (gl_rmain.c:106-108) | `"0"` | translucent liquids visual upgrade. **Revive candidate** for G4 (`"0.6"` or so), visual unblocking, low fps cost since these are small surface areas. G3 leave at 0 (its alpha-water path is the killer that 1024 had to ban via `r_oldwater`). |
| `gl_zfix` (gl_rmain.c:104) | `"0"` | z-fighting fix. Visual neutral if scene has no z-fight; if any map does, this is a free win. **Revive candidate** at `"1"` on both targets after a quick smoke check. |
| `r_flatlightstyles` (gl_rmain.c:87) | `"0"` | turning to `"1"` *eliminates* light-flicker animation. Bench-only knob; do NOT enable for shipping. |
| `gl_flashblend` (gl_rmain.c:78) | `"0"` | `"1"` replaces real dynamic lights with a cheap glow billboard. **Revive candidate for G3 only**, dynamic lights are the biggest CPU cost on demo3 G3. Gives back what `r_dynamic 0` would, but visually nicer. Bench at end-of-round; if it recovers G3 demo3 some fps it's a worthwhile per-target default. |

**Recommended per-target autoexec changes (smoke-bench gated):**

- `scripts/bundle/autoexec-g4.cfg`: add `r_shadows 1`, `r_lavaalpha 0.6`,
  `r_telealpha 0.6`, `r_slimealpha 0.6`, `gl_zfix 1`.
- `scripts/bundle/autoexec-g3.cfg`: add `gl_flashblend 1`, `gl_zfix 1`.

**Effort:** Small (config + smoke bench, ~30 min).
**Predicted impact:**
- G4: visual upgrade (alpha liquids, drop shadows). Expect ±0 to −2 fps.
- G3: `gl_flashblend 1` predicted **+2-5 fps on demo3** (replaces per-light
  `R_AddDynamicLights` lightmap re-touch with a single billboard sprite).
  Visual change is "small glowing ball where rocket explodes" instead of
  light spilling onto walls, arguably acceptable for the framerate.

### B4. `gl_glsl_alias_able` / GLSL alias model rendering on Lion

**What:** `gl_vidsdl.c:120,1408+` detects GL2.0+GLSL and binds an alias-
model GPU-skinned vertex shader path. CLAUDE.md notes the runtime GL
on G3 is 1.1 and on G4 is 1.3, neither hits this path. Lion has
GL 2.1+ (Intel GMA 950) and *does* hit it.

**Why this matters:** Lion was added 2026-05-08 as a third bench data
point. The prior round's perf work focused exclusively on PPC fast
paths. The **GLSL alias path on Lion is currently un-benched**, and
it's `if (gl_glsl_alias_able && !COM_CheckParm("-noglslalias"))`.
Worth a one-shot smoke bench with and without `-noglslalias` on Lion
to see whether GMA 950 actually wins on the GLSL path or is happier
with the immediate-mode-equivalent fallback.

**Action:** Bench Lion `quakespasm-lion -nolauncher +timedemo demo1` at
1024×768 with and without `-noglslalias`. If the GLSL path is
faster: keep default (already on). If the fallback is faster: flip
default for Intel low-end integrated. **Small** (10 min, just running
a bench cell).

**Predicted impact:** Lion-only. Could be ±10% either direction.

### B5. `gl_apple_var_able` static brush VAR pool default

**Status:** Phase 3.2 of the v2 round implemented the VAR pool, smoke-
benched a small G4 1024 regression and a 640 +6.5% recovery in 3.3,
ultimately shipped with the VAR-pool path **opt-in via `-var`** because
the cumulative effect across the workload mix wasn't a clear win.

**Why mention it:** The pool code is fully working on G4; just the
default is conservative. If end-of-round full grid measures show a
demo-mix net positive, flip default-on. Already documented in `PPC_PLAN.md`
§13; not a new finding, just acknowledging it belongs in this bucket.

**Action:** revisit after end-of-round full grid. **Already planned.**

### B6. `EXT_compiled_vertex_array` / `gl_cva_able` on R128

**Status:** Phase 1.1 disabled CVA-Lock on Rage 128 due to in-game color
corruption (`gl_vidsdl.c:1049-1050`). Arrays still flow on R128; only
the lock is skipped.

**Why mention it:** A targeted re-test of CVA-Lock on R128 with the
post-Phase-2 state (BGRA lightmaps + APPLE_client_storage now in play)
might behave differently, the original color corruption could have
been a driver state interaction with the RGBA-format upload, not with
CVA itself. Worth a quick experiment now that Phase 2's lightmap path
is different.

**Action:** Toggle the R128 exclusion at `gl_vidsdl.c:1049-1050`,
deploy to G3, run a smoke bench, eye-check for color corruption on
e1m1 walls and items. If clean: leave on. If corruption returns:
revert. **Small** (15 min).

**Predicted impact:** G3 demo1 could see +1-3% from getting the CVA
lock fast path back on R128. Visual check required.

---

## C. Latent bug (works today: undefined or near-miss)

These are real bugs that haven't bitten yet. Worth fixing but lower
priority than the round's perf phases.

### C1. `cl_main.c:234` short-circuit order in MAX_DEMOS guard

`if (!cls.demos[cls.demonum][0] || cls.demonum == MAX_DEMOS)` reads
`cls.demos[MAX_DEMOS][0]` *before* the bound check. The `[0]` deref
walks one element past the `cls.demos[MAX_DEMOS]` array.

**Action:** Swap the order: `if (cls.demonum == MAX_DEMOS ||
!cls.demos[cls.demonum][0])`. Currently doesn't crash because the next
4 bytes are some other `cls` field that happens to be safe to read, but
that's accidental. **Trivial.**

### C2. `cl_parse.c:212,364,386,1125-1128,1238` same OOB-then-check pattern

Same shape as C1. `Host_Error` / `Sys_Error` is properly `noreturn` so
the OOB never lands at runtime, but the OOB *expression* is evaluated
under aggressive optimization speculation. cppcheck flags 7 sites.

**Action:** Mark `Sys_Error` / `Host_Error` / `Host_EndGame` with
`__attribute__((noreturn))` in their declarations. gcc-4.0 supports
this attribute. This both silences the warnings and lets the optimizer
schedule the OOB-side code more aggressively. Already partially noted
in CLAUDE.md as why a few `return 0;` lines exist, this cleans up
that whole pattern. **Small** (5 min, single-file change to
`sys.h`/`common.h`).

**Predicted impact:** zero fps (compiler already infers noreturn from
flow), but eliminates the false-positive cluster from future linting.

### C3. `r_brush.c:491` `realloc` leak on failure

`lightmaps = realloc(lightmaps, ...)`. If realloc returns NULL, the
old `lightmaps` pointer is still valid memory, but is now overwritten
with NULL. `memset(&lightmaps[texnum], 0, ...)` immediately after
NULL-derefs and crashes. Real bug, only triggers under memory
pressure (extreme map load on low-RAM systems, possibly hitting
the G3 with its 256MB ceiling).

**Action:** Standard pattern: `void *new = realloc(lightmaps, ...);
if (!new) Sys_Error("..."); lightmaps = new;`. **Trivial.**

### C4. `snd_mix.c:265-274` malloc result not checked

`input = (float *) malloc(...)` then `memcpy(input, ...)` and
`input[...] = ...`. NULL-deref on OOM. Same pattern as C3 but in the
audio downsampler.

**Action:** `if (!input) return;` (the function returns void) before
the first deref. **Trivial.**

### C5. `gl_mesh.c:508-546` and `common.c:181-183` similar malloc/realloc OOM holes

Three more sites with the same shape. cppcheck flags them as
`nullPointerArithmeticOutOfMemory` / `memleak`.

**Action:** sweep with the same pattern as C3/C4. **Small** (~15 min).

### C6. `gl_mesh.c:330-331` reinterpret-cast `int *` ↔ `float *`

```c
((int *)mdl->scale)[0] = LittleLong (((int *)mdl->scale)[0]);
((int *)mdl->scale)[1] = LittleLong (((int *)mdl->scale)[1]);
```

cppcheck flags as `portability:invalidPointerCast`. Strict-aliasing
violation. Works on PPC because `vec_t == float == 32-bit`, but the
formal aliasing rule is broken (compiler is free to assume the
`scale` array hasn't been touched after this through the float view).

**Action:** Use the engine's existing `LittleFloat`/`BigFloat` swap
helpers, OR a `union { int i; float f; }` punning helper. The same
pattern repeats in `pr_edict.c:854,1261` and `pr_exec.c:299,308,336`
for QuakeC float→int saves. **Medium** (sweep + verify each callsite),
but **the prior survey called this clean** (`-Wstrict-aliasing=2`
returned 0 on gcc-4.0). gcc-4.0 doesn't see the violation because of
its weaker analysis; clang on Lion does, but doesn't warn either
because the casts are wrapped in macros. Worth fixing for correctness.

### C7. `gl_refrag.c:209` reads `*ppefrag` before init?

False positive on cppcheck, the `while` loop assigns and tests in one
expression. Skip.

### C8. `cl_parse.c:754` and `sbar.c:725` `1 << 31` undefined behaviour

`(1 << 31)` shifts a signed `1` into the sign bit. C11 says undefined.
PPC and x86 both produce `INT_MIN` deterministically, but the spec is
clear.

**Action:** Replace with `1U << 31` or `(int)0x80000000U`. **Trivial.**

### C9. `host.c:691` `rand()` call result discarded

Intentional ("keep the random time dependent" comment), but ignored-
return triggers cppcheck warning every run. **Action:** cast to
`(void)`: `(void)rand();`. **Trivial.**

### C10. `gl_draw.c:228` `x: y` "may be uninitialized" (gcc strict)

`Scrap_AllocBlock(p->width, p->height, &x, &y)`, gcc-4.0 doesn't
know the function writes through the pointers. False positive but
fixable by initializing `x = y = 0;` at declaration. **Trivial,
style only.**

### C11. `r_brush.c:1029-1030: 1034-1035` `td = -td;` "will never be executed"

False positive (gcc thinks `td` is non-negative under `tmax >= 0`
domain). Hot path though, and cppcheck and gcc agree. Can simplify
to `td = abs(local[1] - t*16);` for clarity. **Trivial style.**

---

## D. Style/noise (only items the prior pass missed)

Mostly suppressing per the prior survey's plan. Items here are ones
**not** covered by the prior survey:

### D1. `r_part.c:870: 1022` redundant `extern cvar_t r_particles;` inside function bodies

The cvar is already file-scope at line 42. The two `extern` re-declarations
inside `R_DrawParticles` and `R_RunParticleEffect_BulletPuff` (or
neighbour) are vestigial. Cppcheck flags as `shadowVariable`.
**Action:** delete both `extern` lines.

### D2. `gl_rmain.c:868` `sv_player` local shadows global

cppcheck flags. The local probably should pick a different name; the
global `sv_player` in `server.h` is unrelated. **Action:** rename local.
**Trivial.**

### D3. unused fields in `pcxheader_t`: `_genhist`, `upkg_hdr`, `cmd_function_s::function`, `cmdalias_s::value`

Either the field is parsed-and-discarded (PCX hdpi/vdpi) or the struct
member is preserved for binary-format fidelity (UMX upkg header). Most
should stay. `cmd_function_s::function` and `cmdalias_s::value` warning
sources are in `console.c:733,741`, those are local stub structs used
in the `Tab` autocomplete code and look like leftover scaffolding;
worth one look. **Small** (10 min audit, likely keep all but the
cmd_function_s fields).

### D4. `keys.c:1061` `down` always true

cppcheck flags. Quick read suggests dead `if (!down) ...` branch
where the caller always passes `true`. Could simplify but very low
ROI. **Skip.**

### D5. `bgmusic.c:418: cmd.c:649, console.c:1143, in_sdl.c:156, menu.c:1896, r_part.c:216, pr_edict.c:828,837` unread variable assignments

Mostly self-explanatory: `x = foo(); /* never read */ ...`. Several are
debug-leftovers (`status = ...` then the function returns without
checking it). **Action:** sweep with the cvar-designated-init sweep
proposed by the prior survey. **Trivial each.**

### D6. `gl_sky.c:521,522,559,560,628` `alloca`

cppcheck warns "obsolete." `alloca` works fine on PPC + Mach-O; the
flag is a C99-style nag. Keep, these are sky-vert temporary scratch
buffers in a hot path; converting to VLA buys nothing on gcc-4.0
which lowers VLA to alloca anyway. **Skip.**

---

## Recommended actions (ROI-ordered)

1. **(B3, config-only, ~30 min) Per-target autoexec defaults.** Add
   `r_shadows 1`, `r_lavaalpha/r_telealpha/r_slimealpha 0.6`, `gl_zfix 1`
   to `autoexec-g4.cfg`; add `gl_flashblend 1`, `gl_zfix 1` to
   `autoexec-g3.cfg`. Smoke-bench. If `gl_flashblend 1` recovers G3
   demo3 fps as predicted, this is the **highest ROI item in the
   report** by far. **Land at end-of-round, before the v3 grid.**

2. **(B6, 15 min) Re-test `EXT_compiled_vertex_array` lock on R128.**
   Toggle the exclusion at `gl_vidsdl.c:1049-1050`, deploy G3, smoke,
   eye-check colors. If clean, +1-3% G3 demo1 likely.

3. **(B1, 1 hr) HUD item-pickup flash.** Replace `flashon = 0` at
   `sbar.c:653` with the same expression form as the weapon flash
   block. Visual upgrade, zero fps cost.

4. **(C2, 5 min) Mark `Sys_Error`/`Host_Error`/`Host_EndGame`
   `__attribute__((noreturn))`.** Eliminates 7 false-positive cppcheck
   warnings AND ~10 of the 73 "will never be executed" gcc warnings.
   Compiler can also drop the trailing `return 0; //johnfitz -- shut
   up compiler` lines once it knows the prior call doesn't return.

5. **(A1 + A2, 10 min) Delete vestigial mathlib functions.**
   `Invert24To16`, `FloorDivMod`, `GreatestCommonDivisor`, `Q_log2`,
   `R_ConcatRotations`, `R_ConcatTransforms`, `VectorInverse`. ~150 LOC
   gone, no callers. Pure cleanup.

6. **(A3, 30 min) Sweep `#if 0` blocks.** Delete the historical-only
   ones (12 sites). Keep flagged "kept-disabled" comments where the
   author left a *why*-it's-off note.

7. **(C1, C3, C4, C5, C8, C9, together ~45 min) Latent-bug sweep.**
   OOB-before-bounds-check fix in `cl_main.c:234`, realloc-NULL
   patterns, malloc-NULL-deref in `snd_mix.c`, `1U << 31` shift fix.
   None has bitten yet; all are 1-line each.

8. **(B4, 10 min) Bench Lion with/without `-noglslalias`.**
   GMA 950 datapoint, currently un-measured.

9. **(B2, 5 min) Wire `CL_DumpPacket` to a console command.**
   Tooling.

10. **(D1 + D2, 10 min) Cosmetic shadow cleanups in r_part.c and
    gl_rmain.c.**

Items 4, 5, 6, 7 form a single "cleanup" commit shape that lands
nicely as **Phase v3.0, pre-round cleanup**: ~3 hours of work,
zero risk, deletes ~250 LOC, marks 3 functions noreturn (faster code
generation downstream), and clears the warning-survey to-do list.

Items 1, 2, 3, 8 are **gain-curious**, measure first, ship if the
numbers move.

The whole report's revive bucket (B1-B6) represents the user's
2026-05-08 policy in action: ~5 candidate paths where the prior
warning audit would have just said "nothing actionable here", but
the goal pivot makes them worth lighting back up.

---

## Files of interest

- `/home/matt/quakespasm/Quake/mathlib.c`, A1, A2 (vestigial helpers)
- `/home/matt/quakespasm/Quake/sbar.c` (line 653), B1 (HUD flash revive)
- `/home/matt/quakespasm/Quake/cl_parse.c` (line 964-1000), B2
- `/home/matt/quakespasm/scripts/bundle/autoexec-g3.cfg` and
  `autoexec-g4.cfg`, B3 (cvar defaults to flip)
- `/home/matt/quakespasm/Quake/gl_vidsdl.c` (line 1049-1050), B6
  (R128 CVA exclusion)
- `/home/matt/quakespasm/Quake/cl_main.c` (line 234), C1 (OOB order)
- `/home/matt/quakespasm/Quake/sys.h` / `common.h`, C2 (noreturn attrs)
- `/home/matt/quakespasm/Quake/r_brush.c` (line 491), C3 (realloc)
- `/home/matt/quakespasm/Quake/snd_mix.c` (line 265-277), C4 (malloc)
- `/home/matt/quakespasm/Quake/gl_mesh.c` (line 330-331, 508-546),
  C5, C6 (alias model OOM + alias casts)
- `/home/matt/quakespasm/docs/research/build-warning-survey.md`,
  predecessor report

## Raw data

- `/tmp/qs-cppcheck-clean.txt` (Ubuntu cppcheck 2.17.1 full run, 553
  rows after suppressing missingInclude/toomanyconfigs)
- Lion-side strict pass logs at `/tmp/qs-strict-g3.log` and
  `/tmp/qs-g4-strict.{stdout,stderr}` (regenerable; not preserved
  across reboots)
