#!/usr/bin/env python3
"""Compile the actual cache/filter/culling functions against controlled inputs.

No GL context or game data required. This checks invalidation and numerical
equivalence; hardware rendering and performance still require the fleet tests.
Run on the orchestration Mac: python3 tests/perf-reuse-check.py
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def function(file, name):
    text = (ROOT / "Quake" / file).read_text()
    import re
    match = re.search(r"^(?:static )?(?:void|qboolean) " + name + r"\s*\(", text, re.M)
    if not match:
        raise ValueError(name)
    start = text.index("{", match.start())
    depth = 1
    end = start + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[match.start():end]


mix = (ROOT / "Quake/snd_mix.c").read_text()
filter_start = mix.index("typedef struct {\n\tfloat *memory;")
filter_type = mix[filter_start:mix.index("} filter_t;", filter_start) + len("} filter_t;")]

prefix = r'''
#include "quakedef.h"
#include <assert.h>
#define GL_SILENCE_DEPRECATION 1
#define PAINTBUFFER_SIZE 2048
cvar_t gl_lightmap_reuse = {"gl_lightmap_reuse", "0", CVAR_NONE};
cvar_t r_dynamic = {"r_dynamic", "1", CVAR_NONE};
cvar_t snd_filter_reuse = {"snd_filter_reuse", "0", CVAR_NONE};
int r_framecount, d_lightstylevalue[256], lightmap_bytes = 4;
dlight_t cl_dlights[MAX_DLIGHTS];
unsigned int r_changed_dlights[(MAX_DLIGHTS + 31) >> 5];
mplane_t frustum[4];
struct lightmap_s *lightmaps;
static int *dirty_lightmaps, n_dirty_lightmaps, dirty_lightmaps_cap;
static qboolean dirtylmlist_disabled;
static int builds;
qboolean gl_perfprint_counters_on;
uint32_t gl_perf_counters[PERF_CNT_COUNT];
cvar_t gl_shadowstate, gl_shadowlight_reuse, r_shadows, r_drawentities, r_shadow_distance;
qboolean r_drawflat_cheatsafe, r_lightmap_cheatsafe, mtexenabled;
int gl_stencilbits, cl_numvisedicts;
entity_t *currententity, *cl_visedicts[MAX_VISEDICTS];
client_state_t cl;
vec3_t r_origin, lightspot, lightcolor;
static float entalpha;
static qboolean shading;
static unsigned int alias_light_serial = 1;
typedef struct { short pose1, pose2; float blend; vec3_t origin, angles; } lerpdata_t;
#define SHADOW_SKEW_X -0.7
#define SHADOW_SKEW_Y 0
#define SHADOW_VSCALE 0
#define SHADOW_HEIGHT 0.1
static int texture_on = 1, blend_on, depth_on = 1, stencil_on, matrix_depth;
static int draws, sets, traces;
void glEnable(GLenum cap) {
    if (cap == GL_TEXTURE_2D) texture_on = 1;
    if (cap == GL_BLEND) blend_on = 1;
    if (cap == GL_STENCIL_TEST) stencil_on = 1;
}
void glDisable(GLenum cap) {
    if (cap == GL_TEXTURE_2D) texture_on = 0;
    if (cap == GL_BLEND) blend_on = 0;
    if (cap == GL_STENCIL_TEST) stencil_on = 0;
}
void glDepthMask(GLboolean v) { depth_on = v; if (!v) sets++; }
void glClear(GLbitfield v) { (void)v; }
void glStencilFunc(GLenum a, GLint b, GLuint c) { (void)a;(void)b;(void)c; }
void glStencilOp(GLenum a, GLenum b, GLenum c) { (void)a;(void)b;(void)c; }
void glPushMatrix(void) { matrix_depth++; }
void glPopMatrix(void) { assert(matrix_depth > 0); matrix_depth--; }
void glTranslatef(GLfloat x, GLfloat y, GLfloat z) { (void)x;(void)y;(void)z; }
void glRotatef(GLfloat a, GLfloat x, GLfloat y, GLfloat z) { (void)a;(void)x;(void)y;(void)z; }
void glScalef(GLfloat x, GLfloat y, GLfloat z) { (void)x;(void)y;(void)z; }
void glMultMatrixf(const GLfloat *p) { (void)p; }
void glColor4f(GLfloat r, GLfloat g, GLfloat b, GLfloat a) {
    assert(r == 0 && g == 0 && b == 0 && a == entalpha * 0.5f);
}
void GL_DisableMultitexture(void) { mtexenabled = false; }
qboolean R_CullModelForEntity(entity_t *e) { return e->effects == 123; }
void *Mod_Extradata(qmodel_t *m) {
    static aliashdr_t hdr;
    if (!m->cache.data) {
        assert(texture_on && !blend_on && depth_on);
        m->cache.data = &hdr;
    }
    return m->cache.data;
}
static void R_SetupAliasFrame(aliashdr_t *h, int f, lerpdata_t *l) {
    (void)h; (void)f; memset(l, 0, sizeof(*l));
}
static void R_SetupEntityTransform(entity_t *e, lerpdata_t *l) { VectorCopy(e->origin, l->origin); }
int R_LightPoint(vec3_t org) { traces++; VectorCopy(org, lightspot); return 100; }
static void GL_DrawAliasFrame(aliashdr_t *h, lerpdata_t l) {
    (void)h; (void)l;
    assert(!texture_on && blend_on && !depth_on && !mtexenabled && !shading);
    assert(matrix_depth == 1); draws++;
}
int VectorCompare(vec3_t a, vec3_t b) {
    return a[0] == b[0] && a[1] == b[1] && a[2] == b[2];
}
void R_BuildLightMap(msurface_t *s, byte *dest, int stride) {
    int i;
    (void)dest; (void)stride;
    builds++;
    s->cached_dlight = s->dlightframe == r_framecount;
    s->cached_dlightframe = 0;
    for (i = 0; i < MAXLIGHTMAPS && s->styles[i] != 255; i++)
        s->cached_light[i] = d_lightstylevalue[s->styles[i]];
}
'''

checks = r'''
static void lightmap_checks(void) {
    msurface_t s = {0};
    glpoly_t poly = {0};
    struct lightmap_s lm = {0};
    byte data[4 * LMBLOCK_WIDTH * LMBLOCK_HEIGHT];
    int before, i;
    lm.data = data; lightmaps = &lm; s.polys = &poly;
    memset(s.styles, 255, sizeof(s.styles));
    s.styles[0] = 0; d_lightstylevalue[0] = 256;
    gl_lightmap_reuse.value = r_dynamic.value = 1;
    r_framecount = 10;
    cl_dlights[0].radius = 100;
    R_TrackDlightChanges(); ++r_framecount;
    s.dlightframe = r_framecount; s.dlightbits[0] = 1;
    R_RenderDynamicLightmaps(&s, true);
    assert(builds == 1);
    R_TrackDlightChanges(); ++r_framecount; s.dlightframe = r_framecount;
    R_RenderDynamicLightmaps(&s, true);
    assert(builds == 1); /* unchanged light and style */

    for (i = 0; i < 4; i++) {
        if (i == 0) cl_dlights[0].radius += 1;
        if (i == 1) cl_dlights[0].minlight += 1;
        if (i == 2) cl_dlights[0].color[1] += 1;
        if (i == 3) cl_dlights[0].origin[2] += 1;
        R_TrackDlightChanges(); ++r_framecount; s.dlightframe = r_framecount;
        before = builds; R_RenderDynamicLightmaps(&s, true);
        assert(builds == before + 1);
    }
    /* Changes to another slot cannot invalidate this surface. */
    cl_dlights[63].radius = 500;
    R_TrackDlightChanges(); ++r_framecount; s.dlightframe = r_framecount;
    before = builds; R_RenderDynamicLightmaps(&s, true); assert(builds == before);
    /* Light entering the upper mask word must rebuild. */
    R_TrackDlightChanges(); ++r_framecount; s.dlightframe = r_framecount;
    s.dlightbits[1] = 1U << 31;
    R_RenderDynamicLightmaps(&s, true); assert(builds == before + 1);
    R_TrackDlightChanges(); ++r_framecount; s.dlightframe = r_framecount;
    d_lightstylevalue[0]++;
    before = builds; R_RenderDynamicLightmaps(&s, true); assert(builds == before + 1);
    /* Visibility gap and non-world surfaces use the original rebuild. */
    r_framecount += 5; R_TrackDlightChanges(); ++r_framecount;
    s.dlightframe = r_framecount;
    before = builds; R_RenderDynamicLightmaps(&s, true); assert(builds == before + 1);
    R_TrackDlightChanges(); ++r_framecount; s.dlightframe = r_framecount;
    before = builds; R_RenderDynamicLightmaps(&s, false); assert(builds == before + 1);
    assert(s.cached_dlightframe == 0);
    /* Last light disappearing must clear its contribution. */
    ++r_framecount;
    before = builds; R_RenderDynamicLightmaps(&s, true); assert(builds == before + 1);
    assert(!s.cached_dlight);
    gl_lightmap_reuse.value = 0;
    ++r_framecount; s.dlightframe = r_framecount;
    before = builds; R_RenderDynamicLightmaps(&s, true); assert(builds == before + 1);
}

static void audio_checks(void) {
    filter_t a = {0}, b = {0};
    int left[PAINTBUFFER_SIZE * 2], right[PAINTBUFFER_SIZE * 2];
    int m, count, i;
    for (m = 126; m <= 222; m += 24) {
        S_UpdateFilter(&a, m, 0.1125f); S_UpdateFilter(&b, m, 0.1125f);
        for (count = 1; count <= PAINTBUFFER_SIZE; count = count < 1024 ? count * 2 : count + 1024) {
            for (i = 0; i < count * 2; i++) left[i] = right[i] = ((i * 31337) % 1000000) - 500000;
            snd_filter_reuse.value = 0; S_ApplyFilter(&a, left, 2, count);
            snd_filter_reuse.value = 1; S_ApplyFilter(&b, right, 2, count);
            assert(!memcmp(left, right, count * 2 * sizeof(int)));
            assert(a.parity == b.parity);
            assert(!memcmp(a.memory, b.memory, a.kernelsize * sizeof(float)));
        }
    }
    free(a.memory); free(a.kernel); free(b.memory); free(b.kernel);
}

static void particle_checks(void) {
    /* Test each plane direction. A billboard crossing the plane must survive,
       including when its origin is outside. Rotated bases are covered too. */
    int axis, sign, i, j;
    for (axis = 0; axis < 3; axis++) for (sign = -1; sign <= 1; sign += 2) {
        vec3_t up = {1.1f, -0.7f, 0.3f}, right = {-0.4f, 0.2f, 1.4f};
        float support[4];
        memset(frustum, 0, sizeof(frustum));
        for (i = 0; i < 4; i++) frustum[i].dist = -1000;
        frustum[0].normal[axis] = sign; frustum[0].dist = 0;
        for (i = 0; i < 4; i++) {
            float u = DotProduct(up, frustum[i].normal), r = DotProduct(right, frustum[i].normal);
            support[i] = q_max(0.f, u) + q_max(0.f, r);
        }
        for (j = -100; j <= 100; j++) {
            vec3_t org = {0,0,0}; float scale = 2.3f;
            qboolean any_inside = false;
            org[axis] = j * 0.05f;
            for (i = 0; i < 4; i++) {
                float corner = org[axis] + scale * ((i & 1 ? up[axis] : 0) + (i & 2 ? right[axis] : 0));
                if (corner * sign >= 0) any_inside = true;
            }
            assert(!any_inside || !R_CullParticle(org, scale, support));
            if (org[axis] * sign + scale * support[0] < -0.02f)
                assert(R_CullParticle(org, scale, support));
        }
    }
}
static void shadow_checks(void) {
    qmodel_t model = {0};
    entity_t e = {0};
    int mode;
    model.type = mod_alias; e.model = &model;
    r_shadows.value = r_drawentities.value = 1;
    gl_stencilbits = 8;
    cl.viewent.model = &model;
    cl_visedicts[0] = &e; cl_visedicts[1] = &cl.viewent; cl_visedicts[2] = &e;
    cl_numvisedicts = 3;
    for (mode = 0; mode <= 1; mode++) {
        draws = sets = traces = 0; gl_shadowstate.value = mode;
        R_DrawShadows();
        assert(draws == 2 && traces == 2 && sets == (mode ? 1 : 2));
        assert(texture_on && !blend_on && depth_on && !stencil_on && !matrix_depth);
        e.effects = 123; draws = sets = 0;
        R_DrawShadows(); assert(!draws && !sets && !stencil_on);
        e.effects = 0;
        model.flags = MOD_NOSHADOW;
        R_DrawShadows(); assert(!draws && !sets && !stencil_on);
        model.flags = 0;
    }
    {
        qboolean active = false;
        currententity = &e; draws = sets = 0;
        GL_DrawAliasShadow(&e, &active);
        model.cache.data = NULL; /* uploads during cache reload require ordinary GL state */
        GL_DrawAliasShadow(&e, &active);
        GL_EndAliasShadows(&active);
        assert(draws == 2 && sets == 2 && !active);
        assert(texture_on && !blend_on && depth_on && !matrix_depth);
    }
}
int main(void) {
    lightmap_checks(); audio_checks(); particle_checks(); shadow_checks();
    puts("PASS: lightmap invalidation, bit-identical audio, conservative particle bounds, shadow state lifecycle");
    return 0;
}
'''

parts = [prefix, filter_type]
for file, name in [
    ("gl_rlight.c", "R_TrackDlightChanges"),
    ("r_brush.c", "R_RenderDynamicLightmaps"),
    ("snd_mix.c", "S_MakeBlackmanWindowKernel"),
    ("snd_mix.c", "S_UpdateFilter"),
    ("snd_mix.c", "S_ApplyFilter"),
    ("r_part.c", "R_CullParticle"),
    ("r_alias.c", "GL_EndAliasShadows"),
    ("r_alias.c", "GL_DrawAliasShadow"),
    ("gl_rmain.c", "R_DrawShadows"),
]:
    parts.append(function(file, name))
parts.append(checks)
with tempfile.TemporaryDirectory(prefix="qs-perf-check-") as tmp:
    source, exe = Path(tmp) / "check.c", Path(tmp) / "check"
    source.write_text("\n".join(parts))
    subprocess.run(["clang", "-std=gnu99", "-O2", "-Wall", "-Werror",
                    "-Wno-missing-field-initializers", "-fsanitize=address,undefined",
                    "-Wno-deprecated-declarations",
                    "-DUSE_SDL2", "-DSDL_FRAMEWORK", "-DNO_SDL_CONFIG",
                    "-I", str(ROOT / "Quake"), "-F", str(ROOT / "MacOSX"),
                    str(source), "-o", str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
