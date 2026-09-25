# Performance and graphics implementation plan

Date: 2026-09-08
Status: implementation and validation in progress. Small G4 gain measured; toggles enabled by default at user request.

## G5 OS compatibility

The user confirmed on 2026-09-08 that G5 must support Mac OS X 10.3.9,
including testing alternate G3/G5 boot partitions. The old g5 build case used
SDK/minimum 10.5. It now uses SDK 10.3.9/minimum 10.3, retains `-mcpu=970`,
and adds the Panther Carbon/AltiVec header flags already used by G4.
All six slices built successfully. The PowerMac7,3 on Panther 10.3.9 now
loads and renders demo1, demo2 and demo3 at 800x600 using the Radeon 9600.
Off/on screenshots match outside the top 60 pixels of console notifications.
The first attempt lacked game data; after staging existing packs and restoring
SSH reachability, the retry completed. The demo3 comparison is 65.50 FPS off and 65.70 FPS on at actual 1680x1050. G5 Tiger
and alternate G3 boot testing remain pending.

## Current batch

The user expanded the first experiment to a batch on 2026-09-08. Implemented
behind non-archived toggles, now enabled by default at the user’s request:

- `gl_shadowstate`: defer shared shadow GL cleanup to the end of the pass,
  reopening around a model-cache reload when needed.
- `gl_shadowlight_reuse`: reuse the shadow's original light sample for model
  lighting within the same scene, preserving the elevated-origin fallback.
- `gl_lightmap_reuse`: reuse an already composed world lightmap only when its
  lightstyles, contributing light slots, and those lights' rendering inputs are
  unchanged on consecutive frames. This is the first bounded implementation of
  stage 1, replacing the proposed per-seed contribution cache. It adds no new
  lightmap atlas or per-texel cache and leaves brush models on the original path.
- `r_particle_cull`: reject fully offscreen billboard bounds before vertex filling.
- `r_decal_cull` and `r_decal_uvcache`: conservative bounds rejection and stored
  texture coordinates for immutable clipped decal vertices.
- `snd_filter_reuse`: use per-filter scratch storage for supported mixer blocks,
  retaining allocation fallback for larger blocks and the same filter arithmetic.

`tests/perf-reuse-check.py` compiles actual implementation functions and checks
lightmap invalidation, identical audio samples, conservative particle bounds,
and shadow GL lifecycle with sanitizers. This does not substitute for hardware
image comparison and timedemos. `benchmarks/perf-batch-{off,on}.cfg` define the
same-binary controls without changing the visual settings. The liquid visibility,
modern shader, and simulation/render projects remain outside this batch.

## Objective and scope

Keep one fat Quakespasm.app across PowerPC, Intel, and Apple Silicon. Aim for
at least 20 FPS on G3 and 25 FPS on G4, G5, and Lion Intel at their selected
play resolutions. Above those floors, spend useful headroom on graphics.
Support high-refresh rendering on modern machines without changing game physics.

The user requested this plan after a CPU/GPU code review and authorized subsequent
implementation and hardware benchmarks. They intend to turn on the G3, G4, and G5
Power Macs and report that the Intel iMac is already on. Reachability, exact
models, GPUs, OS versions, and resource ownership must be checked before use.
Do not assume that a Power Mac G5 is the same target as the iMac G5, or that the
Intel iMac represents the Lion/GMA machines. Apple Silicon validation remains
separate from Intel iMac validation.

The mechanisms below were identified by source inspection. Their performance
benefits are hypotheses, not measured gains. Implement experiments independently;
an experiment may finish as a documented negative instead of a shipping change.

## Baselines and evidence

Use `benchmarks/results.csv` and existing raw logs/profiles to select targets,
scenes, and priorities. Do not start with an unnecessary full-fleet baseline sweep.

Historical data is not sufficient to attribute a new improvement or regression.
[ADR 0009](adr/0009-benchmarks-are-three-runs-on-hardware-with-a-same-session-ab.md)
requires same-session A/B: three launches per cell, reporting the median of runs
2 and 3. Take the control measurements as part of each experiment, preferably
with the new path disabled in the same binary. Reuse a same-session control only
while the binary, effective settings, resolution, and machine state remain comparable.

- Record requested and actual resolution. Desktop fullscreen can override the
  requested dimensions; a differently rendered resolution is a different cell.
- Preserve binary identity, source revision, effective cvars, GL renderer and
  capabilities, framebuffer depth, MSAA, and vsync settings with raw evidence.
- Use history for context, not an automatic pass/fail comparison. In particular,
  archived comments claiming spare FPS are not proof that current settings meet
  the floor.
- Keep timing diagnostics out of final throughput measurements where their
  overhead could affect the result. CPU wall-time around GL calls measures
  submission and stalls, not independently measured GPU execution time.
- Inspect run spread. Repeat an ambiguous A/B only when noise or a concrete
  confound prevents a verdict. Do not invent an FPS percentage in advance.
- Capture frame-time spikes for representative combat where supported. Average
  timedemo FPS alone does not establish a minimum frame rate during play.

## Execution order

| Stage | Work | Primary targets | Completion evidence |
|---|---|---|---|
| 0 | Inventory, recover comparable historical cells, focused instrumentation | Available fleet | Known binary/config/mode and useful cost breakdown |
| 1 | Cache stationary emissive contributions | G4, G5, Intel with emissive lights enabled | Lighting equivalence, less rebuild/upload work, A/B |
| 2a | Share same-frame model/shadow light samples | G4, G5; all shadow users | Trace reduction and matching lighting/shadows |
| 2b | Hoist shadow pass GL state | G4, G5; check G3 independently | State-call reduction, correct later passes, A/B |
| 3a | Precompute decal UVs and cull invisible decals | Combat-heavy scenes on available fleet | Identical visible decals, reduced preparation/submission |
| 3b | Cull invisible particle billboards | G3/G4 and heavy combat on modern machines | Identical visible particles, reduced preparation/submission |
| 4 | Reuse audio filter scratch memory | G3/G4 first | Same audio output and fewer hot-path allocations |
| 5 | Conservative liquid visibility research | G3, weak Intel, then fleet | No missing scenery; lower world work than NoVis fallback |
| 6a | Shader lightstyle composition | Apple Silicon and capable Intel | Smooth lighting preserved with fewer CPU rebuilds/uploads |
| 6b | Shader water warp | Apple Silicon and capable Intel | Matching water appearance without intermediate warp copies |
| 6c | Shader dynamic lighting | Modern machines only | Correct lighting and a measured benefit under light-heavy load |
| 7 | Separate simulation ticks from rendering | Modern machines first | Stable physics/input at varied render rates |
| 8 | Spend verified headroom and run final matrix | Each independently validated GPU class | Graphics comparison and floor compliance |

Stages 5–7 are larger projects, not prerequisites for landing the contained
optimizations. Keep each stage toggleable and independently reviewable. Shader
dynamic lighting follows static/lightstyle work rather than being bundled into it.

## 0. Prepare the experiment

- [ ] Read current hardware and ticketing/locking rules, build/deploy contracts,
  `MISTAKES.md`, and applicable ADRs before operating the machines.
- [ ] Discover the available machines and claim shared resources using the
  repository's established process. Check the G5 OS against the shipped slice's
  deployment floor and retain GPU-specific driver gates.
- [ ] Match useful historical cells to current effective resolution and settings.
- [ ] Extend `Quake/gl_perfprint.h` and timing sites as needed for dynamic-light
  marking, lightmap composition, uploads, shadows, and decals. Count rebuilt
  texels, upload bytes/calls, shadow traces, and submitted/rejected effects.
- [ ] Use an instrumentation-only, non-archived toggle. Avoid per-frame console
  output and synchronous GPU waits in ordinary rendering.

## 1. Stationary emissive lighting cache

Source: `Quake/gl_emissive.c` (`R_PushEmissiveLights`), `Quake/gl_rlight.c`
(`R_PushDlights`), `Quake/r_brush.c` (`R_RenderDynamicLightmaps`,
`R_BuildLightMap`, `R_AddDynamicLights`). The current path injects stationary
seeds as dynamic lights, marking touched surfaces for repeated rebuilding.

- [ ] Assign stable seed identities independently of transient dlight slots.
- [ ] Cache affected world surfaces and additive light contributions. Start with
  a bounded, measured memory budget rather than an all-seeds-by-all-texels table.
- [ ] Preserve the existing nearest-light selection and radius/color semantics.
  Recompose when membership or parameters change; remove departed contributions.
- [ ] Keep cached contributions before final clamp/packing. Combine with animated
  lightstyles and moving lights so overlapping lights retain their existing output.
- [ ] Separate world-surface caching from moving brush models and alias lighting;
  retain those paths until equivalent handling is proven.
- [ ] Invalidate on map transitions and relevant lighting cvars. Recreate GPU
  resources safely after video restarts. Test pause/resume and time discontinuities.
- [ ] Do not rely on short dlight expiry as cache ownership. Preserve gameplay
  lights and test light-pool saturation.
- [ ] Compare stationary views, movement across selection boundaries, explosions,
  flickering styles, moving doors, and map changes. Measure CPU time, uploads,
  memory, and FPS with identical selected lights.

## 2. Shadows without duplicated work

Source: `Quake/r_alias.c` (`GL_DrawAliasShadow`, `R_SetupAliasLighting`) and
`Quake/gl_rmain.c` (`R_DrawShadows`).

- [ ] Cache the original world light sample and hit position per entity and frame
  for reuse between shadow and model rendering. Include view/stereo semantics in
  the validity rules; do not reuse results across incompatible origins or worlds.
- [ ] Preserve the elevated-origin fallback for models whose first sample is black.
  Store the original shadow hit separately from that fallback's lighting result.
- [ ] Preserve animation updates for culled models. Reuse animation preparation
  only if profiling justifies the additional lifetime rules.
- [ ] In a separate experiment, move common blend, depth-write, and texture state
  to the shadow-pass boundaries. Keep per-entity alpha and transforms.
- [ ] Audit early exits, stencil cleanup, multitexture, and alias-state-cache
  interactions. Restore state correctly for subsequent entities, liquids, and HUD.
- [ ] Test no-shadow models, invisible/translucent entities, uneven floors,
  stencil/no-stencil contexts, and distance-gate crossings. Do not reduce shadow
  distance or change geometry as part of these comparisons.

## 3. Invisible effects and invariant decal data

Source: `Quake/r_decals.c` (`R_DrawDecals`, `DecalTexCoord`) and
`Quake/r_part.c` (`R_DrawParticles`, `CL_RunParticles`).

- [ ] Compute decal texture coordinates when final clipped vertices are stored.
  Recycle UV storage with its owning decal slot.
- [ ] Store conservative decal bounds and reject fully offscreen decals before
  texture binds and draw submission. Continue expiration while culled.
- [ ] Reject fully offscreen particle billboards before filling scratch arrays.
  Bounds must cover the actual scaled triangle/quad, including screen-edge and
  near-plane cases; testing only the particle origin is insufficient.
- [ ] Leave particle simulation, spawning, lifetimes, counts, and texture quality
  unchanged. Start with frustum rejection; any PVS rejection is a separate task
  with liquid visibility and multi-leaf bounds considered.
- [ ] Compare camera sweeps, explosions behind the camera, effects straddling
  screen edges, overlapping decals, fading, and maximum pool occupancy.
- [ ] Require a worthwhile measured result before adding more batching complexity.
  Previous decal measurements found little cost, so this is lower priority.

## 4. Audio scratch reuse

Source: `Quake/snd_mix.c` (`S_ApplyFilter`, `S_LowpassFilter`, `S_PaintChannels`).

- [ ] Replace per-invocation allocation/free with scratch storage whose capacity
  covers the filter history plus input block. Grow only when required.
- [ ] Confirm mixer ownership/threading before sharing storage. Handle filter
  quality changes, sound restarts, allocation failure, and cleanup.
- [ ] Compare output samples against the current filter for representative block
  sizes and quality settings. Keep sample rate and filter quality unchanged.
- [ ] Benchmark with the filter active and sound enabled. Additional SIMD is a
  separate profile-driven experiment, not an assumed benefit of this cleanup.

## 5. Liquid visibility research

Source: `Quake/r_world.c` (`R_MarkSurfaces`) and `Quake/gl_model.c`
(`Mod_FindContentsTransparent`, disabled `Mod_BuildExpandedVis`).

The current translucent-liquid fallback can disable PVS rejection for an entire
view. Frustum/backface tests still apply. The previous expansion algorithm failed
visually and an archived review records an earlier exclusion of this area.
This plan includes investigation under the user's current request for all reviewed
improvements; it does not authorize treating the old failed algorithm as fixed.

- [ ] First measure work attributable to the fallback with diagnostics. Opaque
  liquids may be a diagnostic control, never the claimed equivalent-quality fix.
- [ ] Design a conservative visibility extension that retains every leaf visible
  through liquid boundaries. Do not simply remove the NoVis trigger or re-enable
  the disabled expansion routine.
- [ ] Preserve NoVis as the fallback when correctness cannot be established.
  Bound map-load time and memory, including large custom maps.
- [ ] Validate underwater/above-water transitions, multiple connected liquids,
  distant pools, transparent brush entities, map-specified alpha, and maps already
  compiled for transparent liquids. Compare views to the existing fallback.
- [ ] Proceed to shipping only if missing geometry and X-ray artifacts are absent
  across the test set and the measured benefit warrants the complexity.

## 6. Modern shader work

Source: `Quake/r_world.c` (`GLWorld_CreateShaders`) and `Quake/gl_warp.c`
(`R_UpdateWarpTextures`). Retain the fixed-function implementation in the same
binary. Select by tested GPU capability, not CPU family alone.

- [ ] Lightstyles: upload static style layers, combine using changing shader
  weights, and retain existing overbright, wide-lightmap, clamp, fog, and fullbright
  semantics. Budget texture units, atlas memory, and shader compatibility first.
- [ ] Water: reproduce the existing warp function and sampling behavior in a
  shader, replacing intermediate grid rendering/framebuffer copies where valid.
  Test lit/unlit water, animated textures, mipmaps, MSAA, alpha, and map changes.
- [ ] Dynamic lights: design a bounded shader representation after profiling the
  remaining lightmap costs. Preserve attenuation, colours, and brush transforms;
  measure heavy-light scenes rather than assuming modern hardware needs this.
- [ ] Verify Intel and Apple Silicon independently. Keep Radeon R300 safety gates
  and asynchronous texture-memory lifetime protections intact.

## 7. High-refresh rendering with stable simulation

Source: `Quake/host.c` (`Host_FilterTime`, `_Host_Frame`) and associated client,
server, interpolation, particle, sound, input, and demo timing code.

- [ ] Introduce a fixed simulation accumulator and independently paced rendering
  behind a toggle. Specify catch-up limits and behavior after stalls or pause.
- [ ] Interpolate render state without advancing gameplay per rendered frame.
  Separate input sampling from command consumption and network transmission.
- [ ] Audit particle evolution, light decay, emissive lifetimes, audio updates,
  demo playback/timedemo semantics, and watch telemetry for render-rate dependence.
- [ ] Compare movement, jumps, collisions, platforms, combat, and networking at
  low, ordinary, and high render rates using repeatable input where possible.
- [ ] Set modern defaults only after correctness tests. Raising `host_maxfps`
  alone is not the implementation; vsync policy is separate from simulation rate.

## 8. Spend headroom and close the round

- [ ] Preserve full texture detail first. Compare filtering and antialiasing
  settings on capable GPUs; tune each independently of CPU optimizations.
- [ ] Expand emissive coverage, smooth lightstyles, or effect counts only where
  an A/B with the intended play resolution keeps the machine above its floor.
- [ ] Retain conservative settings on machines still below target. Record an
  explicit unresolved floor failure rather than describing the fleet as passing.
- [ ] Compare screenshots and actual play, including dense combat and water-heavy
  scenes. A higher average FPS with distracting popping is not an accepted win.
- [ ] Run the final supported hardware matrix and both repository CI workflows.
  Record unavailable targets as unverified, not inferred passes.

## Build, deployment, and acceptance rules for every stage

Follow current script contracts and ADRs at execution time:

1. Implement one mechanism behind a runtime or launch toggle, with the old path
   available for same-binary A/B. Document toggle timing and defaults.
2. Build through the claimed host and canonical fat-build path. Verify source
   stamps, fresh slices, exact CPU subtypes, and the complete fat artifact. Bump
   the deployed version as required and verify deployment hashes.
3. Use the supported bench scripts. Do not race builds, bypass ownership locks,
   or hard-kill a fullscreen application on fragile machines. Preserve existing
   GPU gates and mode locks; use safe startup modes for resolution comparisons.
4. Smoke all supported available targets and include a map transition. Run focused
   A/B on the bottleneck target, then the required cross-target checks. Restore
   archived cvars after testing so experiments do not alter subsequent gameplay.
5. Keep a result if it preserves appearance and improves performance, or spends
   measured headroom on an intentional visual upgrade while meeting the floor.
   Gate hardware-specific wins. Leave neutral experiments off unless another
   demonstrated benefit justifies their maintenance cost.
6. Follow the code/benchmark commit separation in ADR 0009, preserving unrelated
   work and historical results. Update `docs/KNOBS.md`, raw evidence, and this
   checklist. Record failed experiments in `MISTAKES.md` with the tested scope.

## Results ledger

Append one row per independently tested mechanism. Link raw measurements and
visual evidence rather than copying unsupported percentages from old comments.

| Stage | Code revision / toggle | Machine, GPU, actual mode | A/B evidence | Visual result | Decision |
|---|---|---|---|---|---|
| Planning | No implementation yet | Availability supplied by user; not checked | Existing history reviewed | Not tested | Ready for stage 0 |
