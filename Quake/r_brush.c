/*
Copyright (C) 1996-2001 Id Software, Inc.
Copyright (C) 2002-2009 John Fitzgibbons and others
Copyright (C) 2007-2008 Kristian Duske
Copyright (C) 2010-2014 QuakeSpasm developers

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.

*/
// r_brush.c: brush model rendering. renamed from r_surf.c

#include "quakedef.h"

// PPC port -- Phase 4.4: AltiVec for the lightmap compose loop in
// R_BuildLightMap. Same conditional pattern as snd_mix.c so G3 (no
// -maltivec) compiles cleanly.
#ifdef __ALTIVEC__
#include <altivec.h>
#endif

extern cvar_t gl_fullbrights, r_drawflat, gl_overbright, r_oldwater; //johnfitz
extern cvar_t gl_zfix; // QuakeSpasm z-fighting fix

int		gl_lightmap_format;
int		lightmap_bytes;

#define MAX_SANITY_LIGHTMAPS (1u<<20)
struct lightmap_s	*lightmaps;
int		lightmap_count;

static int	allocated[LMBLOCK_WIDTH];
static int	last_lightmap_allocated;

// PPC port -- Phase 4.4: aligned to 16 so the AltiVec compose loop in
// R_BuildLightMap can use vec_ld/vec_st without lvsl gymnastics. Cost is
// at most 12 bytes of padding on the .bss; saves a vec_perm per
// 16-byte stride in the hot inner loop.
static unsigned	blocklights[LMBLOCK_WIDTH*LMBLOCK_HEIGHT*3] __attribute__((aligned(16))); //johnfitz -- was 18*18, added lit support (*3) and loosened surface extents maximum (LMBLOCK_WIDTH*LMBLOCK_HEIGHT)

#ifdef __ALTIVEC__
// PPC port -- Phase 4.4: AltiVec lightmap compose is OPT-IN by default
// after the smoke result regressed -0.5% to -2.3% across all four G4
// cells (vs the +3-8% predicted in PPC_PLAN.md §13.2). The code is
// preserved in tree as a starting point for future tuning — the math is
// correct and matches the scalar reference, but per-iteration AltiVec
// overhead (lvsl + double-load + vec_perm + 16-lane init for scale_v)
// appears to outweigh the per-byte throughput win at typical surface
// sizes. Pass `-altivec-lm` on the launch command line to opt in for
// further experimentation.
//
// This default is a deliberate fail-closed: the v2 Phase 5 SGIS
// regression cost a full bench cycle and was reverted entirely, so for
// 4.4 we keep the experimental code reachable but inert.
qboolean lm_altivec_disabled = true;

// PPC port -- §14.3 item 4: -altivec-dlights opt-in (default off, mirrors
// Phase 4.4 conservative shape). Parsed in R_Init (gl_rmisc.c). Set to
// false to enable the AltiVec R_AddDynamicLights inner-loop path.
qboolean dlights_altivec_disabled = true;
#endif


/*
===============
R_TextureAnimation -- johnfitz -- added "frame" param to eliminate use of "currententity" global

Returns the proper texture for a given time and base texture
===============
*/
texture_t *R_TextureAnimation (texture_t *base, int frame)
{
	int		relative;
	int		count;

	if (frame)
		if (base->alternate_anims)
			base = base->alternate_anims;

	if (!base->anim_total)
		return base;

	relative = (int)(cl.time*10) % base->anim_total;

	count = 0;
	while (base->anim_min > relative || base->anim_max <= relative)
	{
		base = base->anim_next;
		if (!base)
			Sys_Error ("R_TextureAnimation: broken cycle");
		if (++count > 100)
			Sys_Error ("R_TextureAnimation: infinite cycle");
	}

	return base;
}

/*
================
DrawGLPoly -- PPC port -- client vertex arrays. glpoly_t::verts is already
interleaved (xyz, s0,t0, s1,t1) at VERTEXSIZE stride, so we point GL
straight at it without copying. We submit GL_POLYGON (convex, same as
the original glBegin/glEnd path) rather than GL_TRIANGLE_FAN — this
keeps the driver's "small polygon" fast path engaged on the ATI/Apple
1.4.18 stack on Tiger.
================
*/
void DrawGLPoly (glpoly_t *p)
{
	glVertexPointer (3, GL_FLOAT, VERTEXSIZE*sizeof(float), &p->verts[0][0]);
	glTexCoordPointer (2, GL_FLOAT, VERTEXSIZE*sizeof(float), &p->verts[0][3]);
	glEnableClientState (GL_VERTEX_ARRAY);
	glEnableClientState (GL_TEXTURE_COORD_ARRAY);
	glDrawArrays (GL_POLYGON, 0, p->numverts);
	glDisableClientState (GL_TEXTURE_COORD_ARRAY);
	glDisableClientState (GL_VERTEX_ARRAY);
	PERF_COUNT (PERF_CNT_SURFACE);
	PERF_COUNT (PERF_CNT_DRAW);
}

/*
================
Chain-level brush vertex array helpers -- PPC port -- Phase 3.3

Phase 3.2 routed three brush-render call sites (TextureOnly, NoTexture,
Glow) through a per-surface DrawGLPolyFromSurface that toggled
glEnableClientState / glVertexPointer on every surface. That re-thrashed
GL state hundreds of times per frame and likely caused the G4 -3.5%
regression on demo1 640 -- the driver invalidates pre-fetch state on
every pointer rebind, even when the new pointer is inside the same
registered VAR range.

These helpers hoist state setup outside the texturechain loop. Pattern:

    R_BindBrushChain_Single();          // or _Multi() for two TMUs
    for (s = chain; s; s = s->texturechain) {
        GL_Bind (texture);
        R_DrawBrushChainSurface(s);     // or _Multi(s)
    }
    R_UnbindBrushChain_Single();        // or _Multi()

When gl_apple_var_able + gl_bmodel_var_pool are live, the Bind helper
sets glVertexPointer/glTexCoordPointer once at the pool base. Per-
surface draw uses glDrawArrays (GL_POLYGON, s->var_firstvert, count) --
the FIRST argument indexes into the bound pointer, no rebind needed.
This is the canonical VAR/VBO usage and what we should have done in
3.2.

When VAR is off (G3, or -novar), the Bind helper enables client state
but leaves pointers unset; per-surface draw rebinds them from the
hunk-allocated glpoly_t. G3 cost is the same as DrawGLPoly's preceding
behavior (still per-surface-rebind), since there's no pool to share.
================
*/
void R_BindBrushChain_Single (void)
{
	if (gl_apple_var_able && gl_bmodel_var_pool)
	{
		glVertexPointer   (3, GL_FLOAT, VERTEXSIZE*sizeof(float), gl_bmodel_var_pool);
		glTexCoordPointer (2, GL_FLOAT, VERTEXSIZE*sizeof(float), gl_bmodel_var_pool + 3);
	}
	glEnableClientState (GL_VERTEX_ARRAY);
	glEnableClientState (GL_TEXTURE_COORD_ARRAY);
}

void R_UnbindBrushChain_Single (void)
{
	glDisableClientState (GL_TEXTURE_COORD_ARRAY);
	glDisableClientState (GL_VERTEX_ARRAY);
}

void R_DrawBrushChainSurface (msurface_t *s)
{
	if (gl_apple_var_able && gl_bmodel_var_pool)
	{
		glDrawArrays (GL_POLYGON, s->var_firstvert, s->polys->numverts);
	}
	else
	{
		float *v = &s->polys->verts[0][0];
		glVertexPointer   (3, GL_FLOAT, VERTEXSIZE*sizeof(float), v);
		glTexCoordPointer (2, GL_FLOAT, VERTEXSIZE*sizeof(float), v + 3);
		glDrawArrays (GL_POLYGON, 0, s->polys->numverts);
	}
	PERF_COUNT (PERF_CNT_SURFACE);
	PERF_COUNT (PERF_CNT_DRAW);
}

void R_BindBrushChain_Multi (void)
{
	if (gl_apple_var_able && gl_bmodel_var_pool)
	{
		glVertexPointer (3, GL_FLOAT, VERTEXSIZE*sizeof(float), gl_bmodel_var_pool);
		GL_ClientActiveTextureFunc (GL_TEXTURE0_ARB);
		glTexCoordPointer (2, GL_FLOAT, VERTEXSIZE*sizeof(float), gl_bmodel_var_pool + 3);
		GL_ClientActiveTextureFunc (GL_TEXTURE1_ARB);
		glTexCoordPointer (2, GL_FLOAT, VERTEXSIZE*sizeof(float), gl_bmodel_var_pool + 5);
	}
	glEnableClientState (GL_VERTEX_ARRAY);
	GL_ClientActiveTextureFunc (GL_TEXTURE0_ARB);
	glEnableClientState (GL_TEXTURE_COORD_ARRAY);
	GL_ClientActiveTextureFunc (GL_TEXTURE1_ARB);
	glEnableClientState (GL_TEXTURE_COORD_ARRAY);
}

void R_UnbindBrushChain_Multi (void)
{
	GL_ClientActiveTextureFunc (GL_TEXTURE1_ARB);
	glDisableClientState (GL_TEXTURE_COORD_ARRAY);
	GL_ClientActiveTextureFunc (GL_TEXTURE0_ARB);
	glDisableClientState (GL_TEXTURE_COORD_ARRAY);
	glDisableClientState (GL_VERTEX_ARRAY);
}

void R_DrawBrushChainSurface_Multi (msurface_t *s)
{
	if (gl_apple_var_able && gl_bmodel_var_pool)
	{
		glDrawArrays (GL_POLYGON, s->var_firstvert, s->polys->numverts);
	}
	else
	{
		float *v = &s->polys->verts[0][0];
		glVertexPointer (3, GL_FLOAT, VERTEXSIZE*sizeof(float), v);
		GL_ClientActiveTextureFunc (GL_TEXTURE0_ARB);
		glTexCoordPointer (2, GL_FLOAT, VERTEXSIZE*sizeof(float), v + 3);
		GL_ClientActiveTextureFunc (GL_TEXTURE1_ARB);
		glTexCoordPointer (2, GL_FLOAT, VERTEXSIZE*sizeof(float), v + 5);
		glDrawArrays (GL_POLYGON, 0, s->polys->numverts);
	}
	PERF_COUNT (PERF_CNT_SURFACE);
	PERF_COUNT (PERF_CNT_DRAW);
}

/*
================
DrawGLTriangleFan -- johnfitz -- like DrawGLPoly but for r_showtris.
PPC port -- client vertex arrays.
================
*/
void DrawGLTriangleFan (glpoly_t *p)
{
	glVertexPointer (3, GL_FLOAT, VERTEXSIZE*sizeof(float), &p->verts[0][0]);
	glEnableClientState (GL_VERTEX_ARRAY);
	glDrawArrays (GL_TRIANGLE_FAN, 0, p->numverts);
	glDisableClientState (GL_VERTEX_ARRAY);
}

/*
=============================================================

	BRUSH MODELS

=============================================================
*/

/*
=================
R_DrawBrushModel
=================
*/
void R_DrawBrushModel (entity_t *e)
{
	int			i, k;
	msurface_t	*psurf;
	float		dot;
	mplane_t	*pplane;
	qmodel_t	*clmodel;

	if (R_CullModelForEntity(e))
		return;

	currententity = e;
	clmodel = e->model;

	VectorSubtract (r_refdef.vieworg, e->origin, modelorg);
	if (e->angles[0] || e->angles[1] || e->angles[2])
	{
		vec3_t	temp;
		vec3_t	forward, right, up;

		VectorCopy (modelorg, temp);
		AngleVectors (e->angles, forward, right, up);
		modelorg[0] = DotProduct (temp, forward);
		modelorg[1] = -DotProduct (temp, right);
		modelorg[2] = DotProduct (temp, up);
	}

	psurf = &clmodel->surfaces[clmodel->firstmodelsurface];

// calculate dynamic lighting for bmodel if it's not an
// instanced model
	if (clmodel->firstmodelsurface != 0 && !gl_flashblend.value)
	{
		for (k=0 ; k<MAX_DLIGHTS ; k++)
		{
			if ((cl_dlights[k].die < cl.time) ||
				(!cl_dlights[k].radius))
				continue;

			R_MarkLights (&cl_dlights[k], k,
				clmodel->nodes + clmodel->hulls[0].firstclipnode);
		}
	}

	glPushMatrix ();
	e->angles[0] = -e->angles[0];	// stupid quake bug
	if (gl_zfix.value)
	{
		e->origin[0] -= DIST_EPSILON;
		e->origin[1] -= DIST_EPSILON;
		e->origin[2] -= DIST_EPSILON;
	}
	R_RotateForEntity (e->origin, e->angles, e->scale);
	if (gl_zfix.value)
	{
		e->origin[0] += DIST_EPSILON;
		e->origin[1] += DIST_EPSILON;
		e->origin[2] += DIST_EPSILON;
	}
	e->angles[0] = -e->angles[0];	// stupid quake bug

	R_ClearTextureChains (clmodel, chain_model);
	for (i=0 ; i<clmodel->nummodelsurfaces ; i++, psurf++)
	{
		pplane = psurf->plane;
		dot = DotProduct (modelorg, pplane->normal) - pplane->dist;
		if (((psurf->flags & SURF_PLANEBACK) && (dot < -BACKFACE_EPSILON)) ||
			(!(psurf->flags & SURF_PLANEBACK) && (dot > BACKFACE_EPSILON)))
		{
			R_ChainSurface (psurf, chain_model);
			R_RenderDynamicLightmaps(psurf);
			rs_brushpolys++;
		}
	}

	R_DrawTextureChains (clmodel, e, chain_model);
	R_DrawTextureChains_Water (clmodel, e, chain_model);

	glPopMatrix ();
}

/*
=================
R_DrawBrushModel_ShowTris -- johnfitz
=================
*/
void R_DrawBrushModel_ShowTris (entity_t *e)
{
	int			i;
	msurface_t	*psurf;
	float		dot;
	mplane_t	*pplane;
	qmodel_t	*clmodel;
	glpoly_t	*p;

	if (R_CullModelForEntity(e))
		return;

	currententity = e;
	clmodel = e->model;

	VectorSubtract (r_refdef.vieworg, e->origin, modelorg);
	if (e->angles[0] || e->angles[1] || e->angles[2])
	{
		vec3_t	temp;
		vec3_t	forward, right, up;

		VectorCopy (modelorg, temp);
		AngleVectors (e->angles, forward, right, up);
		modelorg[0] = DotProduct (temp, forward);
		modelorg[1] = -DotProduct (temp, right);
		modelorg[2] = DotProduct (temp, up);
	}

	psurf = &clmodel->surfaces[clmodel->firstmodelsurface];

	glPushMatrix ();
	e->angles[0] = -e->angles[0];	// stupid quake bug
	R_RotateForEntity (e->origin, e->angles, e->scale);
	e->angles[0] = -e->angles[0];	// stupid quake bug

	//
	// draw it
	//
	for (i=0 ; i<clmodel->nummodelsurfaces ; i++, psurf++)
	{
		pplane = psurf->plane;
		dot = DotProduct (modelorg, pplane->normal) - pplane->dist;
		if (((psurf->flags & SURF_PLANEBACK) && (dot < -BACKFACE_EPSILON)) ||
			(!(psurf->flags & SURF_PLANEBACK) && (dot > BACKFACE_EPSILON)))
		{
			if ((psurf->flags & SURF_DRAWTURB) && R_OldWaterEffective())
				for (p = psurf->polys->next; p; p = p->next)
					DrawGLTriangleFan (p);
			else
				DrawGLTriangleFan (psurf->polys);
		}
	}

	glPopMatrix ();
}

/*
=============================================================

	LIGHTMAPS

=============================================================
*/

/*
================
R_RenderDynamicLightmaps
called during rendering
================
*/
void R_RenderDynamicLightmaps (msurface_t *fa)
{
	byte		*base;
	int			maps;
	glRect_t    *theRect;
	int smax, tmax;

	if (fa->flags & SURF_DRAWTILED) //johnfitz -- not a lightmapped surface
		return;

	// add to lightmap chain
	fa->polys->chain = lightmaps[fa->lightmaptexturenum].polys;
	lightmaps[fa->lightmaptexturenum].polys = fa->polys;

	// check for lightmap modification
	for (maps=0; maps < MAXLIGHTMAPS && fa->styles[maps] != 255; maps++)
		if (d_lightstylevalue[fa->styles[maps]] != fa->cached_light[maps])
			goto dynamic;

	if (fa->dlightframe == r_framecount	// dynamic this frame
		|| fa->cached_dlight)			// dynamic previously
	{
dynamic:
		if (r_dynamic.value)
		{
			struct lightmap_s *lm = &lightmaps[fa->lightmaptexturenum];
			lm->modified = true;
			theRect = &lm->rectchange;
			if (fa->light_t < theRect->t) {
				if (theRect->h)
					theRect->h += theRect->t - fa->light_t;
				theRect->t = fa->light_t;
			}
			if (fa->light_s < theRect->l) {
				if (theRect->w)
					theRect->w += theRect->l - fa->light_s;
				theRect->l = fa->light_s;
			}
			smax = (fa->extents[0]>>4)+1;
			tmax = (fa->extents[1]>>4)+1;
			if ((theRect->w + theRect->l) < (fa->light_s + smax))
				theRect->w = (fa->light_s-theRect->l)+smax;
			if ((theRect->h + theRect->t) < (fa->light_t + tmax))
				theRect->h = (fa->light_t-theRect->t)+tmax;
			base = lm->data;
			base += fa->light_t * LMBLOCK_WIDTH * lightmap_bytes + fa->light_s * lightmap_bytes;
			R_BuildLightMap (fa, base, LMBLOCK_WIDTH*lightmap_bytes);
		}
	}
}

/*
========================
AllocBlock -- returns a texture number and the position inside it
========================
*/
int AllocBlock (int w, int h, int *x, int *y)
{
	int		i, j;
	int		best, best2;
	int		texnum;

	// ericw -- rather than searching starting at lightmap 0 every time,
	// start at the last lightmap we allocated a surface in.
	// This makes AllocBlock much faster on large levels (can shave off 3+ seconds
	// of load time on a level with 180 lightmaps), at a cost of not quite packing
	// lightmaps as tightly vs. not doing this (uses ~5% more lightmaps)
	for (texnum=last_lightmap_allocated ; texnum<MAX_SANITY_LIGHTMAPS ; texnum++)
	{
		if (texnum == lightmap_count)
		{
			struct lightmap_s *new_lightmaps;
			lightmap_count++;
			// realloc-into-self leaks the old block on NULL, so capture
			// into a temporary first.
			new_lightmaps = (struct lightmap_s *) realloc(lightmaps, sizeof(*lightmaps)*lightmap_count);
			if (!new_lightmaps)
				Sys_Error ("AllocBlock: realloc failed (%d lightmaps)", lightmap_count);
			lightmaps = new_lightmaps;
			memset(&lightmaps[texnum], 0, sizeof(lightmaps[texnum]));
			lightmaps[texnum].data = (byte *) calloc(1, 4*LMBLOCK_WIDTH*LMBLOCK_HEIGHT);
			//as we're only tracking one texture, we don't need multiple copies of allocated any more.
			memset(allocated, 0, sizeof(allocated));
		}
		best = LMBLOCK_HEIGHT;

		for (i=0 ; i<LMBLOCK_WIDTH-w ; i++)
		{
			best2 = 0;

			for (j=0 ; j<w ; j++)
			{
				if (allocated[i+j] >= best)
					break;
				if (allocated[i+j] > best2)
					best2 = allocated[i+j];
			}
			if (j == w)
			{	// this is a valid spot
				*x = i;
				*y = best = best2;
			}
		}

		if (best + h > LMBLOCK_HEIGHT)
			continue;

		for (i=0 ; i<w ; i++)
			allocated[*x + i] = best + h;

		last_lightmap_allocated = texnum;
		return texnum;
	}

	Sys_Error ("AllocBlock: full");
	return 0; //johnfitz -- shut up compiler
}


static mvertex_t	*r_pcurrentvertbase;
static  qmodel_t	*currentmodel;

/*
========================
GL_CreateSurfaceLightmap
========================
*/
void GL_CreateSurfaceLightmap (msurface_t *surf)
{
	int		smax, tmax;
	byte	*base;

	if (surf->flags & SURF_DRAWTILED)
	{
		surf->lightmaptexturenum = -1;
		return;
	}

	smax = (surf->extents[0]>>4)+1;
	tmax = (surf->extents[1]>>4)+1;

	surf->lightmaptexturenum = AllocBlock (smax, tmax, &surf->light_s, &surf->light_t);
	base = lightmaps[surf->lightmaptexturenum].data;
	base += (surf->light_t * LMBLOCK_WIDTH + surf->light_s) * lightmap_bytes;
	R_BuildLightMap (surf, base, LMBLOCK_WIDTH*lightmap_bytes);
}

/*
================
BuildSurfaceDisplayList -- called at level load time
================
*/
void BuildSurfaceDisplayList (msurface_t *fa)
{
	int			i, lindex, lnumverts;
	medge_t		*pedges, *r_pedge;
	float		*vec;
	float		s, t, s0, t0, sdiv, tdiv;
	glpoly_t	*poly;

// reconstruct the polygon
	pedges = currentmodel->edges;
	lnumverts = fa->numedges;

	//
	// draw texture
	//
	poly = (glpoly_t *) Hunk_Alloc (sizeof(glpoly_t) + (lnumverts-4) * VERTEXSIZE*sizeof(float));
	poly->next = fa->polys;
	fa->polys = poly;
	poly->numverts = lnumverts;

	if (fa->flags & SURF_DRAWTURB)
	{
		// match Mod_PolyForUnlitSurface
		s0 = t0 = 0.f;
		sdiv = tdiv = 128.f;
	}
	else
	{
		s0 = fa->texinfo->vecs[0][3];
		t0 = fa->texinfo->vecs[1][3];
		sdiv = fa->texinfo->texture->width;
		tdiv = fa->texinfo->texture->height;
	}

	for (i=0 ; i<lnumverts ; i++)
	{
		lindex = currentmodel->surfedges[fa->firstedge + i];

		if (lindex > 0)
		{
			r_pedge = &pedges[lindex];
			vec = r_pcurrentvertbase[r_pedge->v[0]].position;
		}
		else
		{
			r_pedge = &pedges[-lindex];
			vec = r_pcurrentvertbase[r_pedge->v[1]].position;
		}
		s = DotProduct (vec, fa->texinfo->vecs[0]) + s0;
		s /= sdiv;

		t = DotProduct (vec, fa->texinfo->vecs[1]) + t0;
		t /= tdiv;

		VectorCopy (vec, poly->verts[i]);
		poly->verts[i][3] = s;
		poly->verts[i][4] = t;

		// Q64 RERELEASE texture shift
		if (fa->texinfo->texture->shift > 0)
		{
			poly->verts[i][3] /= ( 2 * fa->texinfo->texture->shift);
			poly->verts[i][4] /= ( 2 * fa->texinfo->texture->shift);
		}

		//
		// lightmap texture coordinates
		//
		s = DotProduct (vec, fa->texinfo->vecs[0]) + fa->texinfo->vecs[0][3];
		s -= fa->texturemins[0];
		s += fa->light_s*16;
		s += 8;
		s /= LMBLOCK_WIDTH*16; //fa->texinfo->texture->width;

		t = DotProduct (vec, fa->texinfo->vecs[1]) + fa->texinfo->vecs[1][3];
		t -= fa->texturemins[1];
		t += fa->light_t*16;
		t += 8;
		t /= LMBLOCK_HEIGHT*16; //fa->texinfo->texture->height;

		poly->verts[i][5] = s;
		poly->verts[i][6] = t;
	}

	//johnfitz -- removed gl_keeptjunctions code

	poly->numverts = lnumverts;

	// support r_oldwater 1 on lit water
	if (fa->flags & SURF_DRAWTURB)
		GL_SubdivideSurface (fa);
}

/*
==================
GL_BuildLightmaps -- called at level load time

Builds the lightmap texture
with all the surfaces from all brush models
==================
*/
void GL_BuildLightmaps (void)
{
	char	name[24];
	int		i, j;
	struct lightmap_s *lm;
	qmodel_t	*m;

	r_framecount = 1; // no dlightcache

	//Spike -- wipe out all the lightmap data (johnfitz -- the gltexture objects were already freed by Mod_ClearAll)
	for (i=0; i < lightmap_count; i++)
		free(lightmaps[i].data);
	free(lightmaps);
	lightmaps = NULL;
	last_lightmap_allocated = 0;
	lightmap_count = 0;

	// PPC port (Phase 2.1) -- BGRA + UNSIGNED_INT_8_8_8_8_REV is Apple's
	// documented GL fast path on PPC; RGBA + UNSIGNED_BYTE forces a CPU
	// swizzle inside the driver. R_BuildLightMap's GL_BGRA branch already
	// writes bytes [B][G][R][A], which on big-endian PPC matches the
	// memory layout the driver reads for the _REV packed type. R128 (G3)
	// and Radeon 9000 (G4) both expose EXT_bgra + APPLE_packed_pixels.
	gl_lightmap_format = GL_BGRA;

	switch (gl_lightmap_format)
	{
	case GL_RGBA:
		lightmap_bytes = 4;
		break;
	case GL_BGRA:
		lightmap_bytes = 4;
		break;
	default:
		Sys_Error ("GL_BuildLightmaps: bad lightmap format");
	}

	for (j=1 ; j<MAX_MODELS ; j++)
	{
		m = cl.model_precache[j];
		if (!m)
			break;
		if (m->name[0] == '*')
			continue;
		r_pcurrentvertbase = m->vertexes;
		currentmodel = m;
		for (i=0 ; i<m->numsurfaces ; i++)
		{
			//johnfitz -- rewritten to use SURF_DRAWTILED instead of the sky/water flags
			if (m->surfaces[i].flags & SURF_DRAWTILED)
				continue;
			GL_CreateSurfaceLightmap (m->surfaces + i);
			BuildSurfaceDisplayList (m->surfaces + i);
			//johnfitz
		}
	}

	//
	// upload all lightmaps that were filled
	//
	// PPC port (Phase 2.2) -- APPLE_client_storage: tell the driver to
	// keep our pointer instead of copying. Eliminates the per-upload
	// LMBLOCK_WIDTH × LMBLOCK_HEIGHT × 4 byte copy. Each lm->data is a
	// stable calloc'd block (see AllocBlock); the driver is allowed to
	// reference it for the texture's lifetime. Reset to GL_FALSE after
	// so non-lightmap textures still get the default copy semantics.
	if (gl_apple_client_storage_able)
		glPixelStorei(GL_UNPACK_CLIENT_STORAGE_APPLE, GL_TRUE);

	for (i=0; i<lightmap_count; i++)
	{
		lm = &lightmaps[i];
		lm->modified = false;
		lm->rectchange.l = LMBLOCK_WIDTH;
		lm->rectchange.t = LMBLOCK_HEIGHT;
		lm->rectchange.w = 0;
		lm->rectchange.h = 0;

		//johnfitz -- use texture manager
		sprintf(name, "lightmap%07i",i);
		lm->texture = TexMgr_LoadImage (cl.worldmodel, name, LMBLOCK_WIDTH, LMBLOCK_HEIGHT,
						SRC_LIGHTMAP, lm->data, "", (src_offset_t)lm->data, TEXPREF_LINEAR | TEXPREF_NOPICMIP);
		//johnfitz

		// PPC port (Phase 2.3) -- ask the driver to keep this lightmap
		// in cached VRAM despite client_storage. TexMgr_LoadImage just
		// finished glTexImage2D so the texture is still bound here.
		// Setting the hint after upload is documented to work (may
		// trigger a re-allocation, which is fine at level load).
		if (gl_apple_storage_hint_able)
			glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_STORAGE_HINT_APPLE, GL_STORAGE_CACHED_APPLE);
	}

	if (gl_apple_client_storage_able)
		glPixelStorei(GL_UNPACK_CLIENT_STORAGE_APPLE, GL_FALSE);

	//johnfitz -- warn about exceeding old limits
	//GLQuake limit was 64 textures of 128x128. Estimate how many 128x128 textures we would need
	//given that we are using lightmap_count of LMBLOCK_WIDTH x LMBLOCK_HEIGHT
	i = lightmap_count * ((LMBLOCK_WIDTH / 128) * (LMBLOCK_HEIGHT / 128));
	if (i > 64)
		Con_DWarning("%i lightmaps exceeds standard limit of 64.\n",i);
	//johnfitz
}

/*
=============================================================

	VBO support

=============================================================
*/

GLuint gl_bmodel_vbo = 0;

void GL_DeleteBModelVertexBuffer (void)
{
	if (!(gl_vbo_able && gl_mtexable && gl_max_texture_units >= 3))
		return;

	GL_DeleteBuffersFunc (1, &gl_bmodel_vbo);
	gl_bmodel_vbo = 0;

	GL_ClearBufferBindings ();
}

/*
==================
GL_BuildBModelVertexBuffer

Deletes gl_bmodel_vbo if it already exists, then rebuilds it with all
surfaces from world + all brush models
==================
*/
void GL_BuildBModelVertexBuffer (void)
{
	unsigned int	numverts, varray_bytes, varray_index;
	int		i, j;
	qmodel_t	*m;
	float		*varray;

	if (!(gl_vbo_able && gl_mtexable && gl_max_texture_units >= 3))
		return;

// ask GL for a name for our VBO
	GL_DeleteBuffersFunc (1, &gl_bmodel_vbo);
	GL_GenBuffersFunc (1, &gl_bmodel_vbo);
	
// count all verts in all models
	numverts = 0;
	for (j=1 ; j<MAX_MODELS ; j++)
	{
		m = cl.model_precache[j];
		if (!m || m->name[0] == '*' || m->type != mod_brush)
			continue;

		for (i=0 ; i<m->numsurfaces ; i++)
		{
			numverts += m->surfaces[i].numedges;
		}
	}
	
// build vertex array
	varray_bytes = VERTEXSIZE * sizeof(float) * numverts;
	varray = (float *) malloc (varray_bytes);
	varray_index = 0;
	
	for (j=1 ; j<MAX_MODELS ; j++)
	{
		m = cl.model_precache[j];
		if (!m || m->name[0] == '*' || m->type != mod_brush)
			continue;

		for (i=0 ; i<m->numsurfaces ; i++)
		{
			msurface_t *s = &m->surfaces[i];
			s->vbo_firstvert = varray_index;
			memcpy (&varray[VERTEXSIZE * varray_index], s->polys->verts, VERTEXSIZE * sizeof(float) * s->numedges);
			varray_index += s->numedges;
		}
	}

// upload to GPU
	GL_BindBufferFunc (GL_ARRAY_BUFFER, gl_bmodel_vbo);
	GL_BufferDataFunc (GL_ARRAY_BUFFER, varray_bytes, varray, GL_STATIC_DRAW);
	free (varray);

// invalidate the cached bindings
	GL_ClearBufferBindings ();
}

/*
=============================================================

	APPLE_vertex_array_range support (PPC port -- Phase 3.2)

	Mirror of the gl_bmodel_vbo path above, but using application
	memory registered with glVertexArrayRangeAPPLE so the Apple/ATI
	driver can park the pool in cached VRAM. We use this instead of
	ARB_VBO because the runtime GL on G4 (Tiger ATI Radeon 9000) is
	1.3 — gl_vbo_able stays false, gl_bmodel_vbo never gets built.
	APPLE_vertex_array_range is the only "VRAM-resident static
	geometry" path on this stack. R128 / Panther doesn't expose VAR,
	so this is G4-only at runtime; the pool is never built on G3.

=============================================================
*/

float		*gl_bmodel_var_pool = NULL;	// application memory; lifetime = level
unsigned int	 gl_bmodel_var_bytes = 0;

void GL_DeleteBModelVAR (void)
{
	if (!gl_apple_var_able)
		return;
	if (!gl_bmodel_var_pool)
		return;

	// Disable the VAR client state and unregister the range before
	// freeing the backing memory -- otherwise the driver may keep
	// referring to the pool from its cached copy.
	glDisableClientState (GL_VERTEX_ARRAY_RANGE_APPLE);
	GL_VertexArrayRangeAPPLEFunc (0, NULL);

	free (gl_bmodel_var_pool);
	gl_bmodel_var_pool = NULL;
	gl_bmodel_var_bytes = 0;
}

/*
==================
GL_BuildBModelVAR

Counts brush verts across world + all bmodels, allocates the pool
once, copies each surface's master poly verts in, and registers the
pool with the Apple driver. Layout is identical to
GL_BuildBModelVertexBuffer's: one record per surface, VERTEXSIZE
floats per vert, surface starts at var_firstvert.
==================
*/
void GL_BuildBModelVAR (void)
{
	unsigned int	numverts, varray_index;
	int		i, j;
	qmodel_t	*m;

	if (!gl_apple_var_able)
		return;

	// Mirror GL_BuildBModelVertexBuffer's self-reset behavior so the
	// R_NewMap caller doesn't have to bracket us with a Delete call.
	GL_DeleteBModelVAR ();

	// count all verts in all brush models (world + bsp submodels)
	numverts = 0;
	for (j=1 ; j<MAX_MODELS ; j++)
	{
		m = cl.model_precache[j];
		if (!m || m->name[0] == '*' || m->type != mod_brush)
			continue;

		for (i=0 ; i<m->numsurfaces ; i++)
			numverts += m->surfaces[i].numedges;
	}

	if (numverts == 0)
		return;

	gl_bmodel_var_bytes = VERTEXSIZE * sizeof(float) * numverts;
	gl_bmodel_var_pool  = (float *) malloc (gl_bmodel_var_bytes);
	if (!gl_bmodel_var_pool)
	{
		Con_Warning ("GL_BuildBModelVAR: malloc(%u) failed; falling back to client arrays\n", gl_bmodel_var_bytes);
		gl_bmodel_var_bytes = 0;
		return;
	}

	varray_index = 0;
	for (j=1 ; j<MAX_MODELS ; j++)
	{
		m = cl.model_precache[j];
		if (!m || m->name[0] == '*' || m->type != mod_brush)
			continue;

		for (i=0 ; i<m->numsurfaces ; i++)
		{
			msurface_t *s = &m->surfaces[i];
			s->var_firstvert = varray_index;
			memcpy (&gl_bmodel_var_pool[VERTEXSIZE * varray_index],
			        s->polys->verts,
			        VERTEXSIZE * sizeof(float) * s->numedges);
			varray_index += s->numedges;
		}
	}

	// Apple's documented pattern: set the storage hint *before* the
	// range registration so the driver knows to put it in cached VRAM
	// rather than AGP. Then enable the client state. With static data
	// no per-frame flush is needed.
	GL_VertexArrayParameteriAPPLEFunc (GL_VERTEX_ARRAY_STORAGE_HINT_APPLE, GL_STORAGE_CACHED_APPLE);
	GL_VertexArrayRangeAPPLEFunc (gl_bmodel_var_bytes, gl_bmodel_var_pool);
	glEnableClientState (GL_VERTEX_ARRAY_RANGE_APPLE);
}

/*
===============
R_AddDynamicLights
===============
*/
void R_AddDynamicLights (msurface_t *surf)
{
	int			lnum;
	int			sd, td;
	float		dist, rad, minlight;
	vec3_t		impact, local;
	int			s, t;
	int			i;
	int			smax, tmax;
	mtexinfo_t	*tex;
	//johnfitz -- lit support via lordhavoc
	float		cred, cgreen, cblue, brightness;
	unsigned	*bl;
	//johnfitz

	smax = (surf->extents[0]>>4)+1;
	tmax = (surf->extents[1]>>4)+1;
	tex = surf->texinfo;

	for (lnum=0 ; lnum<MAX_DLIGHTS ; lnum++)
	{
		if (! (surf->dlightbits[lnum >> 5] & (1U << (lnum & 31))))
			continue;		// not lit by this light

		rad = cl_dlights[lnum].radius;
		dist = DotProduct (cl_dlights[lnum].origin, surf->plane->normal) -
				surf->plane->dist;
		rad -= fabs(dist);
		minlight = cl_dlights[lnum].minlight;
		if (rad < minlight)
			continue;
		minlight = rad - minlight;

		for (i=0 ; i<3 ; i++)
		{
			impact[i] = cl_dlights[lnum].origin[i] -
					surf->plane->normal[i]*dist;
		}

		local[0] = DotProduct (impact, tex->vecs[0]) + tex->vecs[0][3];
		local[1] = DotProduct (impact, tex->vecs[1]) + tex->vecs[1][3];

		local[0] -= surf->texturemins[0];
		local[1] -= surf->texturemins[1];

		//johnfitz -- lit support via lordhavoc
		bl = blocklights;
		cred = cl_dlights[lnum].color[0] * 256.0f;
		cgreen = cl_dlights[lnum].color[1] * 256.0f;
		cblue = cl_dlights[lnum].color[2] * 256.0f;
		//johnfitz

#ifdef __ALTIVEC__
		// PPC port -- §14.3 item 4: AltiVec the per-texel attenuation
		// add. Replaces 3 scalar fmul + 3 fcttoint + 3 int-loads/stores
		// inside the gate with one vec_madd (3 lanes used) + one vec_cts
		// + a stack-spill to extract 3 int lanes back to bl[0..2]. The
		// (cred, cgreen, cblue) constant vector is loop-invariant for
		// this dlight's iteration so it hoists out cleanly.
		//
		// AoS/SoA mismatch caveat (carried from Phase 4.4): we cannot
		// 4-wide on `s` because bl strides 3 ints per pixel. Per-pixel
		// 3-channel mul is the only clean shape.
		//
		// Default-disabled like Phase 4.4 because the structural risk
		// is the same — Phase 4.4 also looked clean on paper and
		// regressed at smoke. Opt-in via -altivec-dlights so we can
		// measure the actual delta on G4 demo3 specifically before
		// flipping the default. Pass A predicted +1-3% on demo3 1024;
		// Pass C profile shows R_AddDynamicLights inside `world` which
		// is ~12% of frame, so a 50% gain in this fn = ~6% fps ceiling.
		if (!dlights_altivec_disabled)
		{
			const vector float cv = (vector float){cred, cgreen, cblue, 0.0f};
			const vector float zero_v = (vector float){0.0f, 0.0f, 0.0f, 0.0f};
			union { vector signed int v; int i[4]; } u;

			for (t = 0 ; t<tmax ; t++)
			{
				td = local[1] - t*16;
				if (td < 0)
					td = -td;
				for (s=0 ; s<smax ; s++)
				{
					sd = local[0] - s*16;
					if (sd < 0)
						sd = -sd;
					if (sd > td)
						dist = sd + (td>>1);
					else
						dist = td + (sd>>1);
					if (dist < minlight)
					{
						vector float bv;
						vector float prod;
						brightness = rad - dist;
						bv = (vector float){brightness, brightness, brightness, 0.0f};
						prod = vec_madd (bv, cv, zero_v);
						u.v = vec_cts (prod, 0);
						bl[0] += u.i[0];
						bl[1] += u.i[1];
						bl[2] += u.i[2];
					}
					bl += 3;
				}
			}
		}
		else
#endif
		{
			/* PPC port -- Round v5 B5: scalar dlight cast hoist.
			 *
			 * Original inner loop did per-texel float->int casts (fctiw,
			 * ~12 cyc on G3) AND the gate-firing branch did 3 fmul + 3
			 * fctiw + 3 add (~21 cyc) for the lightmap accumulation.
			 *
			 * The math is integer-valued throughout (light radius, sd/td
			 * coords, brightness are all integer-valued). Only the
			 * float-typed STORAGE was forcing the casts. By precomputing
			 * local[0]/local[1]/rad/minlight as ints once per dlight,
			 * and converting cred/cgreen/cblue to scaled-int once, the
			 * inner loop becomes pure int math:
			 *   per-texel:  ~19 cyc (was ~50 cyc)
			 *   gate-firing: int-mul + int-add (was float-mul + fctiw + add)
			 *
			 * Precision: br * icred where icred = (int)(color * 256.0f)
			 * vs. original (int)(brightness_f * cred_f) -- max divergence
			 * is < 1 unit per channel (sub-palette-resolution: lightmap
			 * stores 8-bit channels, so any difference < 256 is
			 * imperceptible after the final >> in lightmap dispatch).
			 *
			 * Single-texel-edge off-by-one possible at lightmap cells
			 * where local[0]/local[1] has fractional part AND
			 * (local - s*16) crosses zero -- rare and imperceptible.
			 *
			 * Helps G3 (no AltiVec; scalar path is the only path), G4
			 * with -altivec-dlights opt-out, G4mini same, Lion same.
			 * G3 specifically is GPU-bound so this is CPU headroom for
			 * visual effects rather than a direct fps win, but on
			 * dlight-heavy frames where R_AddDynamicLights is ~12% of
			 * frame on G3 (Pass C profile), CPU savings can spill into
			 * fps when those frames are CPU-bound. */
			const int int_local0  = (int)local[0];
			const int int_local1  = (int)local[1];
			const int int_minlight = (int)minlight;
			const int int_rad      = (int)rad;
			const int icred   = (int)(cl_dlights[lnum].color[0] * 256.0f);
			const int icgreen = (int)(cl_dlights[lnum].color[1] * 256.0f);
			const int icblue  = (int)(cl_dlights[lnum].color[2] * 256.0f);

			for (t = 0 ; t<tmax ; t++)
			{
				td = int_local1 - t*16;
				if (td < 0)
					td = -td;
				for (s=0 ; s<smax ; s++)
				{
					int idist;
					sd = int_local0 - s*16;
					if (sd < 0)
						sd = -sd;
					if (sd > td)
						idist = sd + (td>>1);
					else
						idist = td + (sd>>1);
					if (idist < int_minlight)
					//johnfitz -- lit support via lordhavoc
					{
						const int br = int_rad - idist;
						bl[0] += br * icred;
						bl[1] += br * icgreen;
						bl[2] += br * icblue;
					}
					bl += 3;
					//johnfitz
				}
			}
		}
	}
}


/*
===============
R_BuildLightMap -- johnfitz -- revised for lit support via lordhavoc

Combine and scale multiple lightmaps into the 8.8 format in blocklights
===============
*/
void R_BuildLightMap (msurface_t *surf, byte *dest, int stride)
{
	const int overbright = !!gl_overbright.value;
	const int wide10bits = !!r_lightmapwide.value;

	int			smax, tmax;
	unsigned		r, g, b;
	int			i, j, size;
	byte		*lightmap;
	unsigned	scale;
	int			maps;
	unsigned	*bl;

	surf->cached_dlight = (surf->dlightframe == r_framecount);

	smax = (surf->extents[0]>>4)+1;
	tmax = (surf->extents[1]>>4)+1;
	size = smax*tmax;
	lightmap = surf->samples;

	if (cl.worldmodel->lightdata)
	{
	// clear to no light
		memset (&blocklights[0], 0, size * 3 * sizeof (unsigned int)); //johnfitz -- lit support via lordhavoc

	// add all the lightmaps
		if (lightmap)
		{
			for (maps = 0 ; maps < MAXLIGHTMAPS && surf->styles[maps] != 255 ;
				 maps++)
			{
				scale = d_lightstylevalue[surf->styles[maps]];
				surf->cached_light[maps] = scale;	// 8.8 fraction
				//johnfitz -- lit support via lordhavoc
				bl = blocklights;
				i = 0;

#ifdef __ALTIVEC__
				// PPC port -- Phase 4.4: AltiVec lightmap compose.
				//
				// Per scalar reference (3 statements above):
				//     bl[k] += lightmap[k] * scale, for k in [0, size*3).
				//
				// scale is unsigned (8.8 fixed-point); max possible value
				// is 25*22 = 550 (lightstyle 'z' under r_flatlightstyles 2)
				// or 256 (default), well under 16 bits. Fits vec_mule/mulo
				// of u16 × u16 → u32. Per-byte lightmap value is 0..255.
				// Product max = 255 * 550 = 140,250 — well under u32.
				//
				// Per vector iteration: load 16 lightmap bytes, splat scale
				// to 8 u16 lanes, vec_mule + vec_mulo to produce 16 u32
				// products in two halves, accumulate into bl[k..k+15].
				//
				// blocklights is __attribute__((aligned(16))), so
				// vec_ld/vec_st on bl work without permute. lightmap is
				// surf->samples (not aligned in general); use lvsl +
				// double-load + vec_perm idiom for the byte fetch.
				//
				// Replaces 16 scalar (load + zero-extend + mul + load +
				// add + store) sequences with 4 vec_ld + 4 vec_add +
				// 4 vec_st on the accumulator, and 1 lvsl+2 vec_ld+1
				// vec_perm+2 vec_mergeh/l+4 mule/mulo+4 mergeh/l on the
				// product. The runtime opt-out (lm_altivec_disabled) lets
				// the user fall back via -noaltivec-lm if visual bugs
				// show up.
				if (!lm_altivec_disabled && size >= 6)
				{
					int N = size * 3;
					vector unsigned char zero_u8 = (vector unsigned char)vec_splat_u8(0);
					vector unsigned short scale_v = (vector unsigned short){
						(unsigned short)scale, (unsigned short)scale,
						(unsigned short)scale, (unsigned short)scale,
						(unsigned short)scale, (unsigned short)scale,
						(unsigned short)scale, (unsigned short)scale
					};
					int k;

					for (k = 0; k + 16 <= N; k += 16)
					{
						// Unaligned 16-byte byte load.
						vector unsigned char shift = vec_lvsl(0, &lightmap[k]);
						vector unsigned char lm_lo = vec_ld(0,  &lightmap[k]);
						vector unsigned char lm_hi = vec_ld(15, &lightmap[k]);
						vector unsigned char lm   = vec_perm(lm_lo, lm_hi, shift);

						// Zero-extend bytes -> u16 (high half + low half).
						vector unsigned short lm_h = (vector unsigned short)
							vec_mergeh(zero_u8, lm);
						vector unsigned short lm_l = (vector unsigned short)
							vec_mergel(zero_u8, lm);

						// u16 * u16 -> u32 (4 lanes each from even/odd).
						// vec_mule picks lanes 0,2,4,6; vec_mulo picks 1,3,5,7.
						// Re-interleave with merge to recover {0,1,2,3} order.
						vector unsigned int p_he = vec_mule(lm_h, scale_v);
						vector unsigned int p_ho = vec_mulo(lm_h, scale_v);
						vector unsigned int r_h0 = vec_mergeh(p_he, p_ho);
						vector unsigned int r_h1 = vec_mergel(p_he, p_ho);

						vector unsigned int p_le = vec_mule(lm_l, scale_v);
						vector unsigned int p_lo = vec_mulo(lm_l, scale_v);
						vector unsigned int r_l0 = vec_mergeh(p_le, p_lo);
						vector unsigned int r_l1 = vec_mergel(p_le, p_lo);

						// bl is 16-aligned; aligned add-to-memory.
						unsigned int *blk = &bl[k];
						vec_st(vec_add(vec_ld( 0, blk), r_h0),  0, blk);
						vec_st(vec_add(vec_ld(16, blk), r_h1), 16, blk);
						vec_st(vec_add(vec_ld(32, blk), r_l0), 32, blk);
						vec_st(vec_add(vec_ld(48, blk), r_l1), 48, blk);
					}

					// Scalar tail for the remaining (N - k) bytes.
					for (; k < N; k++)
						bl[k] += lightmap[k] * scale;

					bl       += N;
					lightmap += N;
				}
				else
#endif
				for (i=0 ; i<size ; i++)
				{
					*bl++ += *lightmap++ * scale;
					*bl++ += *lightmap++ * scale;
					*bl++ += *lightmap++ * scale;
				}
				//johnfitz
			}
		}

	// add all the dynamic lights
		if (surf->dlightframe == r_framecount)
			R_AddDynamicLights (surf);
	}
	else
	{
	// set to full bright if no light data
		memset (&blocklights[0], 255, size * 3 * sizeof (unsigned int)); //johnfitz -- lit support via lordhavoc
	}

// bound, invert, and shift
// store:
	switch (gl_lightmap_format)
	{
	case GL_RGBA:
		stride -= smax * 4;
		bl = blocklights;
		for (i=0 ; i<tmax ; i++, dest += stride)
		{
			for (j=0 ; j<smax ; j++)
			{
				if (overbright)
				{
					r = *bl++ >> 8;
					g = *bl++ >> 8;
					b = *bl++ >> 8;
				}
				else
				{
					r = *bl++ >> 7;
					g = *bl++ >> 7;
					b = *bl++ >> 7;
					if (wide10bits) {
						// artifically clamp to 255 so gl_overbright 0 renders as expected in the wide10bits case
						r = (r > 255) ? 255 : r;
						g = (g > 255) ? 255 : g;
						b = (b > 255) ? 255 : b;
						goto loc0;
					}
				}
				if (wide10bits)
				{
					r = (r > 1023)? 1023 : r;
					g = (g > 1023)? 1023 : g;
					b = (b > 1023)? 1023 : b;
					loc0:
					*(unsigned int*)dest = (r<<22) | (g<<12) | (b<<2) | 3;
					dest += 4;
				}
				else
				{
					*dest++ = (r > 255)? 255 : r;
					*dest++ = (g > 255)? 255 : g;
					*dest++ = (b > 255)? 255 : b;
					*dest++ = 255;
				}
			}
		}
		break;
	case GL_BGRA:
		stride -= smax * 4;
		bl = blocklights;
		for (i=0 ; i<tmax ; i++, dest += stride)
		{
			for (j=0 ; j<smax ; j++)
			{
				if (overbright)
				{
					r = *bl++ >> 8;
					g = *bl++ >> 8;
					b = *bl++ >> 8;
				}
				else
				{
					r = *bl++ >> 7;
					g = *bl++ >> 7;
					b = *bl++ >> 7;
					if (wide10bits) {
						// artifically clamp to 255 so gl_overbright 0 renders as expected in the wide10bits case
						r = (r > 255) ? 255 : r;
						g = (g > 255) ? 255 : g;
						b = (b > 255) ? 255 : b;
						goto loc1;
					}
				}
				if (wide10bits)
				{
					r = (r > 1023)? 1023 : r;
					g = (g > 1023)? 1023 : g;
					b = (b > 1023)? 1023 : b;
					loc1:
					*(unsigned int*)dest = (b<<22) | (g<<12) | (r<<2) | 3;
					dest += 4;
				}
				else
				{
					// PPC port (Phase 2.1) -- BGRA +
					// UNSIGNED_INT_8_8_8_8_REV expects 32-bit
					// ARGB-packed integers (Apple's GL docs).
					// On big-endian PPC this 32-bit store lands as
					// memory bytes [A][R][G][B], matching what the
					// driver reads. The byte-by-byte [B][G][R][A]
					// write below was correct for UNSIGNED_BYTE but
					// drove blue to saturation under _REV (R↔B
					// swap, alpha takes the B channel).
					const unsigned rr = (r > 255) ? 255 : r;
					const unsigned gg = (g > 255) ? 255 : g;
					const unsigned bb = (b > 255) ? 255 : b;
					*(unsigned int *)dest = (0xFFu << 24) | (rr << 16) | (gg << 8) | bb;
					dest += 4;
				}
			}
		}
		break;
	default:
		Sys_Error ("R_BuildLightMap: bad lightmap format");
	}
}

/*
===============
R_UploadLightmap -- johnfitz -- uploads the modified lightmap to opengl if necessary

assumes lightmap texture is already bound
===============
*/
static void R_UploadLightmap(int lmap)
{
	const int wide10bits = !!r_lightmapwide.value;
	const GLenum type = wide10bits ?
	    GL_UNSIGNED_INT_10_10_10_2 : GL_UNSIGNED_INT_8_8_8_8_REV;
	struct lightmap_s *lm = &lightmaps[lmap];

	if (!lm->modified)
		return;

	lm->modified = false;

	glTexSubImage2D(GL_TEXTURE_2D, 0, 0, lm->rectchange.t, LMBLOCK_WIDTH, lm->rectchange.h, gl_lightmap_format,
			type, lm->data + lm->rectchange.t*LMBLOCK_WIDTH*lightmap_bytes);
	lm->rectchange.l = LMBLOCK_WIDTH;
	lm->rectchange.t = LMBLOCK_HEIGHT;
	lm->rectchange.h = 0;
	lm->rectchange.w = 0;

	rs_dynamiclightmaps++;
}

void R_UploadLightmaps (void)
{
	int lmap;

	for (lmap = 0; lmap < lightmap_count; lmap++)
	{
		if (!lightmaps[lmap].modified)
			continue;

		GL_Bind (lightmaps[lmap].texture);
		R_UploadLightmap(lmap);
	}
}

/*
================
R_RebuildAllLightmaps -- johnfitz -- called when gl_overbright gets toggled
================
*/
void R_RebuildAllLightmaps (void)
{
	const int wide10bits = !!r_lightmapwide.value;
	const GLenum type = wide10bits ?
	    GL_UNSIGNED_INT_10_10_10_2 : GL_UNSIGNED_INT_8_8_8_8_REV;
	int			i, j;
	qmodel_t	*mod;
	msurface_t	*fa;
	byte		*base;

	if (!cl.worldmodel) // is this the correct test?
		return;

	//for each surface in each model, rebuild lightmap with new scale
	for (i=1; i<MAX_MODELS; i++)
	{
		if (!(mod = cl.model_precache[i]))
			continue;
		fa = &mod->surfaces[mod->firstmodelsurface];
		for (j=0; j<mod->nummodelsurfaces; j++, fa++)
		{
			if (fa->flags & SURF_DRAWTILED)
				continue;
			base = lightmaps[fa->lightmaptexturenum].data;
			base += fa->light_t * LMBLOCK_WIDTH * lightmap_bytes + fa->light_s * lightmap_bytes;
			R_BuildLightMap (fa, base, LMBLOCK_WIDTH*lightmap_bytes);
		}
	}

	//for each lightmap, upload it
	for (i=0; i<lightmap_count; i++)
	{
		GL_Bind (lightmaps[i].texture);
		glTexSubImage2D (GL_TEXTURE_2D, 0, 0, 0, LMBLOCK_WIDTH, LMBLOCK_HEIGHT, gl_lightmap_format,
				 type, lightmaps[i].data);
	}
}
