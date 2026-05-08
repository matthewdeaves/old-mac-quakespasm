# End-of-round v3 final code review — resume prompt

> Paste the prompt block at the bottom of this file into a fresh
> (cleared-context) Claude Code session at `/home/matt/quakespasm`.
> The prompt is self-contained: it points at the durable artifacts
> (CLAUDE.md, PPC_PLAN.md, the four `docs/research/` reports) and
> lists the deferred work the new session should pick up.

---

```
Final code review for QuakeSpasm PPC port at /home/matt/quakespasm.
This is the §14.3 implementation tail of round v3 — pick up after
the dev-work commits already landed and execute the deferred
findings using compiler/static-analysis tooling, with the goal of
"best-looking + best-fps Quake on G3, G4, and Lion-Intel".

## Read these first (durable picture)

1. CLAUDE.md — codebase tribal knowledge, hosts, build/deploy/bench
   tooling, "Toggleable knobs" inventory of every per-target
   shipping cvar/-flag. The "Goal in one line" + "Toggleable knobs"
   sections set the project's direction; everything else in this
   prompt is gated by them.
2. PPC_PLAN.md §0 (what's done across rounds 1-3), §13 (round v3
   plan including outcomes for Phase 4.4/4.5/4.6/7 and §13.6),
   and especially §14 (this end-of-round structure: passes A/B/C
   already executed, this session is §14.3 implementation tail
   followed by §14.4 round wrap and §14.5 fat-binary tooling).
3. docs/research/pass-a-fps-visual-review.md — code review for
   unexploited fps + visual wins. Top 5 ranked. Items 1-4 already
   shipped (commits 4798eb16, 316bb957, c2de82fa, f1a0cb11). Item
   5 (BGRA TexMgr_LoadImage32) is deferred to this session.
4. docs/research/pass-b-static-analysis-triage.md — kill / revive /
   latent-bug / style classification. The "revive" and "kill"
   buckets are the actionable work for this session. Note B3 (cvar
   default audit) calls out gl_flashblend 1 on G3 as the highest-
   ROI single experiment we haven't tried.
5. docs/research/perfprint-pass-c-analysis.md — live gl_perfprint
   per-region timing on G4 demo3 1024 + G3 demo1 1024. Two
   load-bearing findings: (a) G3 is GPU-bound (swap=70% of frame),
   so CPU optimisations don't help G3 unless they reduce GPU
   command volume; (b) on G4 demo3, alias dominates (47% of frame
   peak) — distance-gated shadows would be the biggest demo3 lever.
6. docs/research/build-warning-survey.md — initial warning audit
   (predecessor to Pass B). Most actionable findings already
   applied; deferred items there are folded into Pass B.
7. docs/research/fat-binary-feasibility.md — verified `lipo` merge
   of all three slices works; fat SDL via `lipo -replace ppc` works
   too. **DO NOT BUILD THE FAT-BINARY TOOLING UNTIL §14.5 (after
   §14.3 + §14.4).** This is explicit user direction.

## Current shipping state

HEAD will be on the bench-and-commit chain ending around `f1a0cb11`
(item 4 AltiVec R_AddDynamicLights — opt-in only) plus its bench
commit on top. `git log --oneline -20` will show the full session.

Per-target shipping config (in `scripts/bundle/autoexec-{g3,g4,lion}.cfg`):

  G3:   r_oldwater 1, r_particles 2, gl_subdivide_size 256,
        r_shadows 1
  G4:   gl_texture_anisotropy 16, r_oldwater 0, r_shadows 1,
        gl_texturemode "GL_LINEAR_MIPMAP_LINEAR" (trilinear)
  Lion: gl_texture_anisotropy 16, r_oldwater 1, r_shadows 1,
        gl_texturemode "GL_LINEAR_MIPMAP_LINEAR"

Latest official bench numbers (last bench-and-commit on top of f1a0cb11):

  G3   demo1 1024  ~23 fps    (above 20 fps floor ✓; user-accepted)
  G3   demo1 640   ~46 fps    ✓
  G3   demo3 1024  ~19.5 fps  (smoke; just below 20 fps — user accepted)
  G4   demo1 1024  ~106 fps   (well above 60 ✓; trilinear+shadows on)
  G4   demo1 640   ~127 fps   ✓
  G4   demo3 1024  ~81 fps    ✓
  Lion demo1 1024  ~96 fps    ✓
  Lion demo1 640   ~220 fps   ✓
  Lion demo3 1024  ~44 fps    (below 60 fps — known GMA 950 fillrate
                                 limit; CPU-bound regime works fine)

## Work to do (in order)

### 1. Pass A item 5: BGRA conversion in TexMgr_LoadImage32

**The deferred item from §14.3.** Pass A §1a — extend Phase 2.1's
BGRA + 8888_REV from per-frame lightmaps to all static textures via
`Quake/gl_texmgr.c:1280,1300`. Cleanest approach is to update
`d_8to24table[]` to BGRA byte order at startup, then change the
upload format constants from GL_RGBA + GL_UNSIGNED_BYTE to GL_BGRA +
GL_UNSIGNED_INT_8_8_8_8_REV.

**Risk:** `d_8to24table` is consumed by ~15 sites including the
alias renderer's color array and the palette expand path. Some sites
might do byte-by-byte access expecting RGBA byte order. Audit each
callsite of `d_8to24table` before flipping the table. Run with both
default-on and `-nobgra-static` (a new toggle) so we can A/B if
visuals regress on any platform.

**Impact:** load-time only (textures upload once per map). Win is
shorter map-load wall-clock, especially big custom maps. Zero
per-frame fps. Visuals must be bit-identical.

**Toggle:** `-nobgra-static` cmdline parsed in `R_Init` or
`TexMgr_Init`.

**Validation:** screenshot diff first frame of e1m1 / start.bsp
against baseline; eyeball menu/HUD glyphs; compare a brushwork
section in detail. If any pixel diff appears, revert the
d_8to24table reorder and try a per-image swap during 8→32 expansion
instead.

Estimated effort: small to medium. Estimated time: 1-3 hours
including the callsite audit.

### 2. Pass B "kill" bucket cleanup

`docs/research/pass-b-static-analysis-triage.md` §A. Mostly
mechanical deletes:

- A1+A2: ~150 LOC of vestigial software-renderer helpers in
  `Quake/mathlib.c` (Invert24To16, FloorDivMod, GreatestCommonDivisor,
  Q_log2, R_ConcatRotations, R_ConcatTransforms, VectorInverse).
  Verify all are tree-callable-only (`grep -rn`), then delete bodies
  + header declarations.
- A3: 12 `#if 0` blocks scattered across the codebase. The Pass B
  report enumerates each with a verdict; trust those.
- A4: `sbar.c:1116` always-true ternary.
- A5: `cd_sdl.c:569-574` dead `hw_vol_works` branch.

Single cleanup commit, ~250 LOC removed. Zero behaviour change.
Build all three targets after to confirm.

### 3. Pass B "latent bug" sweep

§C in the Pass B report. Most useful items:

- C2: mark `Sys_Error`/`Host_Error`/`Host_EndGame`
  `__attribute__((noreturn))`. Eliminates 7 cppcheck warnings + 10
  gcc "will never be executed" notes; lets the optimiser drop
  trailing `return 0;` shutup-compiler lines.
- C1: swap order of bound check + array index in `cl_main.c:234`.
- C3, C4, C5: realloc/malloc NULL-deref handling sweep across
  `r_brush.c:491`, `snd_mix.c:265-274`, `gl_mesh.c:508-546`,
  `common.c:181-183`. One-line fix at each callsite (NULL check +
  Sys_Error or graceful return).
- C8: `1U << 31` instead of `1 << 31` in `cl_parse.c:754,
  sbar.c:725`. Trivial.

These are real bugs that haven't bitten yet. Single cleanup commit
~45 minutes total.

### 4. Pass B "revive" bucket — the BIG ONE

§B in the Pass B report. **This is where the user's "don't just
silence, look for revivable code" policy creates leverage.** Per-item
notes:

**B3 highest priority — gl_flashblend 1 on G3.** Predicted +2-5% on
G3 demo3 (replaces per-light dynamic-light lightmap re-touch with a
single billboard sprite). Visual change is "small glowing ball"
instead of light spilling onto walls — arguably acceptable for the
framerate gain. **Bench-test on G3 demo3 1024 first;** if it
recovers >2 fps it's the highest-ROI item left in the round.
**G3-specific autoexec.** Also revisit: r_lavaalpha/r_telealpha/
r_slimealpha 0.6 on G4 (translucent liquids), gl_zfix 1 on both.

**B6 — re-test EXT_compiled_vertex_array CVA Lock on R128.** Phase
1.1 disabled CVA Lock on R128 due to color corruption; the original
corruption may have been a state interaction with the RGBA upload
path that Phase 2.x changed. Toggle the exclusion at
`gl_vidsdl.c:1049-1050`, deploy G3, smoke, eye-check. Predicted
+1-3% G3 demo1 if clean.

**B1 — `sbar.c:653` HUD item-pickup flash.** Hard-coded `flashon = 0`
kills the original Quake item-pickup flash. Replace with the same
expression form used at lines 547-557 for the weapon flash. Visual
upgrade. Cost ~zero fps.

**B4 — Lion `-noglslalias` A/B.** GMA 950 on Lion is the only target
that can hit the GLSL alias-skinning path (G3=GL1.1, G4=GL1.3,
both below the GL2.0 + GLSL requirement). Bench Lion demo1 1024
with and without `-noglslalias` to see whether the GLSL path is
actually faster than the immediate-mode-equivalent fallback on
GMA 950. Could be ±10% either direction.

### 5. Distance-gated R_DrawShadows (Pass C HIGH priority)

Pass C analysis flagged this as the single biggest leverable item
for G4 demo3. Currently `r_shadows 1` triggers a per-entity shadow
pass for every visible alias entity (8 ms peak / 17 ms frame on
combat). Adding distance gating — only shadow the closest N
entities — recovers worst-case demo3 fps. Implementation:
threshold check in `R_DrawAliasModel` shadow path, distance from
viewer to entity origin. New cvar `r_shadow_distance` (default
something like 256 game units, tunable).

This is genuinely new code, ~50 LOC. Medium effort. Toggleable via
the cvar. Smoke-bench G4 demo3 with shadows on, distance limited;
if the worst-case frame recovers measurably, ship as the new G4
default.

### 6. §14.4 round-wrap full-grid bench

Per `scripts/bench-and-commit.sh "v3 round wrap"` (no `--quick`).
3 demos × 2 res × 3 runs × 3 machines = 54 cells. Captures the
cumulative trajectory across rounds 1-3 + §14.3 implementations.

Use this as the official "v3 final" bench data. Compare to v2 and
earlier baselines in `benchmarks/results.csv`.

### 7. §14.5 fat-binary tooling

After §14.4 lands. Per `docs/research/fat-binary-feasibility.md`
recommendation:

  a. New `scripts/build-fat.sh` that drives g3+g4+lion sub-builds
     under the existing flock, then `lipo -create` into
     `build/quakespasm-fat`.
  b. One-time `lipo -replace ppc` of
     `MacOSX/SDL.framework/Versions/A/SDL` with
     `MacOSX/SDL-panther.dylib`, committed as the new bundled
     framework.
  c. `scripts/deploy.sh` becomes target-agnostic — same bundle ships
     to G3/G4/Lion verbatim, dyld picks each host's slice.
  d. Verify each target runs the same fat bundle with bench numbers
     within noise of per-target baselines.

Open prerequisite question: does `SDL-panther.dylib` (10.3.9-built,
--disable-altivec) run cleanly on G4/Tiger? If yes, single PPC SDL
slice serves both. Test before committing the framework swap.

## Tooling for the static analysis sweep

Already exercised in Pass B; available again:

- **cppcheck** on Ubuntu — Pass B used `cppcheck --enable=all
  --suppress=missingIncludeSystem --inline-suppr Quake/`. Re-run after
  any cleanup commit to confirm the count drops.
- **gcc-4.0 strict mode on Lion** — `-Wstrict-aliasing=2 -Wcast-align
  -Wpointer-arith -Wundef -Wunreachable-code -Wunused-function
  -Wunused-value`. Use to verify the latent-bug sweep didn't introduce
  new warnings.
- **clang static analyser** on Lion — `scan-build --use-cc=/usr/bin/clang`
  is documented as not-installed in Pass B's table; if you can wire
  it in via Xcode 4.6's bundled scan-build it's another sanity check.
- **gcc-4.0 vectorizer notes** — `-ftree-vectorizer-verbose=2` on G4
  build to see which loops the compiler auto-vectorized vs rejected.
  Useful to confirm new AltiVec hand-written loops are necessary
  (and to find new ones).

The build-warning-survey report has command lines you can copy-paste.

## Hard rules

- Stay buildable on gcc-4.0 + 10.3.9 SDK for G3 (no toolchain bumps).
- Keep PPC + AltiVec-conditional compilation working (`#ifdef
  __ALTIVEC__` gates).
- Don't introduce undefined behaviour to silence warnings — fix the
  underlying issue.
- Maintain runtime toggleability of every shipped per-target
  contribution (cvar or `-flag`). Any new perf/visual phase landed
  this session needs the same opt-in/opt-out treatment as §13's
  AltiVec phases.
- Use the bench-and-commit cadence (CLAUDE.md): code commit + smoke
  + bench-and-commit. Two commits per phase. Never wipe results.csv
  mid-round.
- G3 has crashed 3 times this session — the freshly-reinstalled
  Panther install is unstable. If G3 crashes again, capture
  panic.log if any (Panther's PanicReporter is at
  `/Library/Logs/PanicReporter/`), reboot, and continue. Don't
  spend cycles debugging hardware/OS instability.

## Reporting back

End-of-session, leave the working tree clean (no uncommitted edits)
and update PPC_PLAN.md §14.4 + §14.5 with status. Final summary
should include: what shipped, what stayed deferred to round v4, and
the v3-final fps numbers from the round-wrap bench.
```
