/*
 * gl_perfprint.h -- Phase 7 in-engine per-region timing for the renderer.
 *
 * PPC port: Tiger has no usable OpenGL Profiler (system nub v3.1(33) vs
 * the only available profiler binary v3.4(78)) and Panther has no nub at
 * all. Sample-based profiling via /usr/bin/sample is our usual fallback,
 * but it has no notion of which renderer region a given function belongs
 * to. This header carries minimal in-engine instrumentation so we can
 * answer "where is the frame time going on G4 demo3-1024 right now?"
 * with a single console line.
 *
 * Cost when `gl_perfprint` cvar is 0 (the default): one branch + one
 * cvar dereference per region per frame. ~10 cycles. Predictor handles
 * the always-zero case cleanly.
 *
 * Output format (Con_Printf'd every PERF_PRINT_INTERVAL frames when the
 * cvar is nonzero):
 *
 *   gl_perfprint: world=2.3ms alias=0.8ms part=0.2ms warp=0.1ms
 *                 sky=0.3ms swap=0.5ms total=5.7ms (175.4 fps)
 *
 * Implementation lives in gl_rmain.c (close to R_RenderScene where most
 * regions are wrapped). The cvar is registered in R_Init (gl_rmisc.c)
 * and the -perfprint command-line flag (parsed in R_Init too) bumps it
 * to 1 at startup so you can profile the first frame without a console
 * round-trip.
 */
#ifndef _GL_PERFPRINT_H
#define _GL_PERFPRINT_H

#include <stdint.h>

typedef enum {
    PERF_FRAME = 0,        // R_RenderView (everything between BeginRendering and EndRendering)
    PERF_WARP,             // R_UpdateWarpTextures (water/lava warp procedural updates)
    PERF_SKY,              // Sky_DrawSky (sky pass — box or layered)
    PERF_WORLD,            // R_DrawWorld (brush surfaces — multitex + single-tex chains)
    PERF_WORLD_WATER,      // R_DrawWorld_Water (transparent liquid surfaces)
    PERF_ALIAS,            // R_DrawEntitiesOnList non-alpha pass (alias/brush/sprite entities)
    PERF_ALIAS_ALPHA,      // R_DrawEntitiesOnList alpha pass
    PERF_PARTICLES,        // R_DrawParticles
    PERF_VIEWMODEL,        // R_DrawViewModel
    PERF_SWAP,             // GL_EndRendering — driver SwapBuffers (vsync wait lives here)
    PERF_REGION_COUNT
} perf_region_t;

/* Round v5 A6 -- API-call counters. Per-frame integer counts of
 * potentially expensive OpenGL submissions, used to discover whether
 * driver-side state thrash is contributing to the GPU-bound regime on
 * G3 (R128, GL 1.1, no VBOs). Free when gl_perfprint == 0; cheap
 * (one increment per event) when active. Printed as a second line
 * when gl_perfprint >= 2 so we keep the original one-line summary
 * uncluttered for routine timing work.
 *
 * Decision criterion these feed (per round-v5 plan B2): if G3 demo3
 * binds > 1000 textures/frame we batch by texture; < 500 means the
 * bind path isn't a contributor and B2 is dropped.
 */
typedef enum {
    PERF_CNT_BIND = 0,         // GL_Bind() — every state change to a different texture
    PERF_CNT_DRAW,             // glBegin/glDrawElements — primitive submissions
    PERF_CNT_DLIGHT,           // dlights actually marked into surfaces this frame
    PERF_CNT_SURFACE,          // brush surfaces submitted to the renderer
    PERF_CNT_ALIAS_TRIS,       // alias-model triangles submitted (sum across entities)
    PERF_CNT_COUNT
} perf_counter_t;

#ifdef __APPLE__
#include <mach/mach_time.h>
extern qboolean gl_perfprint_active;        // mirrors (gl_perfprint.value > 0)
extern qboolean gl_perfprint_counters_on;   // mirrors (gl_perfprint.value >= 2)
extern uint64_t gl_perf_accum[PERF_REGION_COUNT];
extern uint32_t gl_perf_counters[PERF_CNT_COUNT];

#define PERF_BEGIN(region) \
    uint64_t _perf_t0_##region = gl_perfprint_active ? mach_absolute_time() : 0
#define PERF_END(region) \
    do { if (gl_perfprint_active) gl_perf_accum[(region)] += mach_absolute_time() - _perf_t0_##region; } while (0)

/* Counters are gated on the level-2 mirror: routine timing-only runs
 * pay nothing, full instrumentation runs (rare, manual `gl_perfprint 2`
 * before a benchmark) pay one untaken branch + one increment per
 * event. The PERF_CNT_ADD form lets sites batch (e.g. submit N alias
 * triangles in one call) without N branches. */
#define PERF_COUNT(counter) \
    do { if (gl_perfprint_counters_on) gl_perf_counters[(counter)]++; } while (0)
#define PERF_COUNT_ADD(counter, n) \
    do { if (gl_perfprint_counters_on) gl_perf_counters[(counter)] += (uint32_t)(n); } while (0)
#else
/* Non-Apple platforms: compile out entirely. The PPC port targets only
 * Apple's PowerPC OS X, but keep the renderer files portable for any
 * upstream merges. */
#define PERF_BEGIN(region)        ((void)0)
#define PERF_END(region)          ((void)0)
#define PERF_COUNT(counter)       ((void)0)
#define PERF_COUNT_ADD(counter,n) ((void)0)
#endif

void R_PerfPrint_FrameEnd (void);  // called once per frame from GL_EndRendering
void R_PerfPrint_Init (void);      // called from R_Init — registers cvar + parses -perfprint

#endif /* _GL_PERFPRINT_H */
