# Pass C: Live `gl_perfprint` capture analysis (2026-05-08)

Per PPC_PLAN.md §14.2 Pass C: exercise the Phase 7 instrumentation
(commit 88bd6fb6) on real timedemo runs and capture per-region timing
to ground the §14.3 prioritisation. Crosses Pass A's *predicted*
hot-region list with measured reality.

Raw data files in this directory:
- `perfprint-g4-demo3-1024.log`, G4 demo3 1024×768 (alias-heavy demo)
- `perfprint-g3-demo1-1024.log`, G3 demo1 1024×768

Both ran at HEAD `4bf1f771` shipping config: G4 with `r_shadows 1 +
trilinear + anisotropy 8`, G3 with `r_shadows 1 + gl_subdivide_size
256 + r_oldwater 1 + r_particles 2`. So the numbers reflect the
post-pivot visual-upgrade configuration the project ships.

## Headline findings

### G3: SWAP is 70-75% of every frame

  Average across the 10 last-prints of demo1 1024 (24 fps cell):
    frame: 39 ms
    swap:  29 ms   (74% of frame)
    world:  3.5 ms (9%)
    alias:  2.0 ms (5%)
    everything else combined: ≤ 1 ms

  Sample frames:
    frame=44.24ms swap=31.48ms world=5.61ms alias=2.89ms part=0.43ms
    frame=49.97ms swap=37.38ms world=5.68ms alias=3.28ms part=0.17ms
    frame=41.57ms swap=33.99ms world=1.97ms alias=1.99ms part=0.00ms

**This contradicts the Phase 1.1 conclusion** in PPC_PLAN.md §0 ("G3
/ R128 is not per-call-overhead bound. Switching glBegin →
glDrawArrays didn't move it. Future G3 wins must come from reducing
data motion or CPU work the driver does, not from changing how draws
are dispatched.") The Phase 1.1 result was correct **for the regions
Phase 7 wraps as `world` and `alias`**, those are 14% of the frame
combined, and yes, changing draw-dispatch within them won't move the
needle. But the frame is dominated by the driver / GPU finishing the
frame inside `SDL_GL_SwapBuffers`, which is wrapped as `swap` here.

What's happening in `swap`: with `vid_wait 0` (vsync disabled, set in
bench.sh), `SDL_GL_SwapBuffers` shouldn't be blocking on the refresh
cycle. So the 30 ms is the driver's command queue being full, Rage
128's Panther driver appears to flush synchronously per frame, with
roughly 30 ms of queued GPU work to drain. **G3 is GPU-bound, not
CPU-bound**, on every cell at 1024×768.

**Implications for §14.3 ranking on G3:**

- Anything that reduces GPU-side work pays off proportionally.
  Reducing fillrate (lower resolution, smaller draw distance, simpler
  shaders) directly cuts the swap region. Reducing GPU command volume
  also helps.
- Anything that reduces *CPU* work without reducing GPU work pays
  approximately nothing, we're already idle waiting for the GPU.
- The user accepted G3 demo1 1024 = 23 fps and demo3 1024 = 19.5 fps
  as the shipping floor. Beating that on G3 1024 likely requires
  either accepting visual loss (gl_picmip, reduced texture quality,
  lower sky/water tessellation) which contradicts the project goal,
  OR finding a way to reduce GPU draw count without visual change
  (e.g. better culling, though Phase 1.1 already used the standard
  PVS culling).

### G4: alias dominates demo3: very variable

  Across the 18 last-prints of demo3 1024 (78 fps cell):
    frame range: 6.8 to 17.4 ms
    alias range: 0.5 to 8.4 ms     <-- biggest contributor
    world range: 0.6 to 2.9 ms
    part  range: 0.16 to 1.6 ms
    everything else: ≤ 1 ms typically

  Worst-case combat frame (the 57.5 fps one):
    frame=17.38ms alias=8.04ms world=2.88ms part=0.93ms vmodel=0.52ms
    swap=0.14ms warp=0.22ms sky=0.37ms

  Median-ish frame:
    frame=12.41ms alias=4.92ms world=2.51ms part=0.57ms swap=0.10ms

**Alias is 30-50% of the frame on most demo3 cells, peaking at 47% on
combat-heavy frames.** Demo3 has zombies, ogres, fiends, every alias
entity contributes. The shadow pass we just enabled in §13.6 is part
of `alias` (R_DrawShadows runs inside R_DrawEntitiesOnList's iteration
according to gl_rmain.c:935). Gating shadows on the closest N
entities, already flagged as a round-v4 candidate in §13.6, would
trim the worst-case `alias` cell directly, recovering some of the
demo3-1024 19.50 fps G3 number too if applied symmetrically.

`world` is the second-biggest contributor at 10-20% on G4 demo3.
Phase 4.4 targeted the lightmap-compose hot loop inside `world` and
regressed; if Pass A surfaces a different `world` lever (e.g. a
better R_RecursiveWorldNode, R_DrawTextureChains_World algorithmic
change) it would land here. With Pass C data we know the budget head:
`world` averages ~2 ms, peaks at ~3 ms, so even a 50% improvement is
~1 ms = ~10% of an average 12 ms frame.

`swap` on G4 is consistently sub-millisecond at 1024, Radeon 9000's
Tiger driver pipelines properly. Not a target.

## Specific Pass A predictions Pass C can score

For each lever Pass A is asked to evaluate, the Pass C data either
supports or counter-indicates:

- **AltiVec `R_AddDynamicLights`**, runs inside `world` build path
  (called from R_BuildLightMap which is inside R_DrawWorld). Worth
  ≤ 10% of frame at peak, so an aggressive AltiVec rewrite that
  doubled the function's speed would gain at most ~5% fps. Modest
  return for medium effort. Pass C says: **moderate priority**.
- **Distance-gated `R_DrawShadows`**, sits inside `alias`. If half
  the per-entity shadow cost can be skipped, peak alias cell drops
  from 8 ms to ~5 ms, frame drops from 17 ms to 14 ms (+20% in the
  worst frames). Demo3 worst-case fps could go from 57.5 to ~71.
  Pass C says: **high priority**.
- **R_RecursiveWorldNode AltiVec**, sits inside `world`. Frustum
  cull math per node. If 50% faster, gain ~0.5 ms = 4% of frame.
  Pass C says: **low priority** unless it's also an alignment audit
  win (the warning agent flagged BSP cast-align in this neighbourhood).
- **AltiVec `R_DrawParticles` / `CL_RunParticles`**, runs in `part`.
  Up to 1.6 ms peak; AltiVec'ing could halve it. Gain ≤ 1% fps. Pass
  C says: **low priority** unless trivial.
- **APPLE_object_purgeable / APPLE_pixel_buffer / APPLE_fence**, none
  of these would show up directly in the existing region wrapping
  (they'd reduce the work *inside* `swap` or `world`). Speculative.

## Pass C limitations

- Only one demo / resolution per machine captured. Demo1 G3 isn't in
  the same regime as demo3, the G3 demo1 data above shows swap=70%
  of frame, but demo3 G3 might have a different alias share.
- 60-frame averaging window means the stretched/spike frames blur
  with the calm ones. The "0.16 ms particles" entry next to a
  "1.6 ms particles" entry is two-sigma variance, not one path being
  10× faster than another.
- The captured run included the demo's loading / first-frame compile
  overhead. Last 5-10 prints are the steady-state numbers.
- `swap` on G4 1024 is sub-millisecond, but on G3 1024 we don't have
  good resolution into it, `swap` could decompose into "driver
  wait", "GPU fence", "framebuffer flip". The Phase 7 instrumentation
  doesn't split SDL_GL_SwapBuffers further. Round-v4 candidate.

## Action items feeding §14.3

1. **G3: stop trying to AltiVec / hot-loop optimise the CPU side.**
   We're spending 30 ms in `swap` per frame; nothing CPU-side will
   move the headline. G3 wins require reducing GPU work, either by
   accepting visual loss (out of scope) or by cutting things the GPU
   draws that the player can't see. Better PVS culling, more
   aggressive frustum culling, distance-based LOD on alias models,
   these stay viable for round v4.
2. **G4: distance-gated `R_DrawShadows` is the single biggest lever.**
   Reduces the largest region (`alias`) on the highest-variance demo
   (demo3) without removing the visual that motivated §13.6.
3. **G4: AltiVec'ing R_AddDynamicLights** can take a modest slice of
   `world`. Defensible if the implementation is clean.
4. **Anything else Pass A surfaces** should be cross-checked against
   the per-region budget sizes here before it's prioritised. A win
   on a region that's 1% of the frame is a 1% fps gain at best.

## How to reproduce

```
ssh g4 'cd ~/Desktop/quake && rm -f qconsole.log && \
  ./Quakespasm.app/Contents/MacOS/quakespasm -nolauncher -basedir . \
    -nosound -condebug -perfprint -fullscreen \
    -width 1024 -height 768 +vid_wait 0 +timedemo demo3 \
    > /dev/null 2>&1 &
  ...wait for "frames seconds fps" line in qconsole.log,
  killall -KILL quakespasm,
  grep gl_perfprint qconsole.log'
```

`scripts/bench.sh` doesn't currently pass `-perfprint` through; that
could be wired as a `PERFPRINT=1` env-var pass-through for future
runs. Round-v4 tooling candidate.
