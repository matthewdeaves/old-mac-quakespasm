# Perf candidates from compiler optimisation reports

Round v5 A5: capture `-fopt-info-vec-missed` from Ubuntu gcc 15 against
the Linux build to surface loops that the modern vectoriser couldn't
handle. Each missed loop is a candidate for hand-AltiVec on G4 or
manual scalar tightening on G3.

**Verdict:** mostly null result. Hot paths the project cares about are
either already covered by existing AltiVec hand-paths (alias lerp,
sound mixer, lightmap compose, mipmap chain) or rejected by the
vectoriser for legitimate reasons that human rewrites can't easily
overcome.

## Raw output

`analysis/raw/vec-missed.log` — full 13,616-line dump (gitignored).

## Top "couldn't vectorize loop" entries

After filtering vendored libraries (`lodepng.c`, `stb_image_write.h`,
`miniz.c`):

| Site | Count | What it is | Disposition |
|------|-------|------------|-------------|
| `menu.c:112,122` | 113 | Menu draw text-position loop | Not perf-relevant (menu only) |
| `gl_texmgr.c:861` | 39 | `TexMgr_Pad` — power-of-two finder | Inherently sequential (`i<<=1` LCD); not vectorisable |
| `cvar.c:252` | 27 | Cvar list iteration | Not perf-relevant (console only) |
| `common.c:233,1337` | 24 | strcmp / hash iteration | Not perf-relevant (boot path) |
| `gl_model.c:1685` | 10 | Model loading | Load-time only |
| `host_cmd.c:70,91` | 10 | Console command iteration | Not perf-relevant |
| `gl_sky.c:562` | 6 | Sky drawing inner loop | Worth a closer look — see below |
| `sv_main.c:1271` | 6 | Server frame iteration | Not perf-relevant for client-side fps |
| `zone.c:769` | 5 | Zone allocator scan | Not hot (pre-game allocations) |

## The bulk of "missed" entries are noise

The 13,616-line log breaks down roughly as:

- **~70%** "statement clobbers memory: <function call>" — the loop has a
  function call (most often a `glXxx` GL submission or `Sys_Error`)
  inside it, so the vectoriser can't reorder iterations. Unavoidable.
- **~20%** "couldn't vectorize loop" + "no vectype for stmt" on
  3-element vec3 loops in `mathlib.c`. The vectoriser's minimum width
  on x86 is 4; vec3 is below the threshold. PPC AltiVec is also 4-wide
  (vector float = 4 floats), so the same fundamental shape applies.
- **~5%** vendored library code (lodepng, stb, miniz) — not ours.
- **~5%** menu / console / loading / serialisation paths — not in the
  per-frame hot loop.

## Hot paths the project actually cares about

These are the per-frame perf-relevant loops, with their A5 status:

| File | Loop | Status |
|------|------|--------|
| `r_alias.c:443,516` | Alias lerp / pose1+pose2 blend | Already covered by Phase 4.1 AltiVec hand-path on G4. Vectoriser misses are because of the AltiVec fallback's structure; redundant with the hand-path. |
| `r_brush.c` various | Lightmap compose, brush surface draw | Phase 4.4 AltiVec hand-path on G4 (`-altivec-lm`). DrawGLPoly et al all "clobber memory" via GL — irreducible. |
| `gl_rlight.c` | `R_AddDynamicLights` per-texel | §14.3 item 4 AltiVec hand-path on G4 (`-altivec-dlights`). Scalar fallback is candidate B5 (cast hoist). |
| `snd_mix.c` | 16-bit sound mixer | Phase 4.2 AltiVec hand-path on G4 (`-noaltivec-snd`). |
| `mathlib.c` | `VectorLength`, `VectorNormalize`, `VectorMA` | Phase 1 `frsqrte` covers the sqrt path. Vec3 loops are below auto-vectoriser threshold. Hand-AltiVec for vec4-equivalent is conceivable but the data layout is vec3 so requires SOA shuffle which is its own perf problem. |

## One worth investigating: `gl_sky.c:562`

6 missed iterations on a sky-pass inner loop. Sky is a fullscreen
fillrate hog on G3 (R128) and contributes to the GPU-bound regime.
**Action:** read the loop, see if it's a candidate for AltiVec
on G4 or for arithmetic simplification on G3. Not done in Round v5;
filed as a Round v6 starter.

## Conclusion

Compiler-driven perf candidate generation is a wash for this codebase
on this revision. The genuinely vectorisable hot loops are all already
hand-AltiVec'd; the remaining "missed" entries are either irreducible
(GL submission walls) or below the vectoriser's minimum width (vec3).

**The unblocked win pile for Round v5 onwards is algorithmic, not
compiler-driven**: distance gates (B1), call hoisting (B5),
per-frame caching (B6), tail-recursion elimination (B7).
