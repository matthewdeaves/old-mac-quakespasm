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
// r_world.c: world model rendering

#include "quakedef.h"

extern cvar_t gl_fullbrights, r_drawflat, gl_overbright, r_oldwater, r_oldskyleaf, r_showtris; //johnfitz

byte *SV_FatPVS (vec3_t org, qmodel_t *worldmodel);

// PPC port -- Round v8 item 2 -- multitex enable/disable hoist.
// Set true by `-nomtexhoist` cmdline parsed in gl_rmisc.c R_Init. When
// false (default) the legacy non-array path of R_DrawTextureChains_Multitexture
// enables TMU1 once before the texture loop and disables it once after,
// instead of toggling per texture chain. Hygiene cleanup for state-thrash;
// expected sub-1% on R128 (driver shrugs at no-op enables) but real cycles.
qboolean mtexhoist_disabled = false;

//==============================================================================
//
// SETUP CHAINS
//
//==============================================================================

/*
================
R_ClearTextureChains -- ericw

clears texture chains for all textures used by the given model, and also
clears the lightmap chains
================
*/
void R_ClearTextureChains (qmodel_t *mod, texchain_t chain)
{
	int i;

	// set all chains to null
	for (i=0 ; i<mod->numtextures ; i++)
		if (mod->textures[i])
			mod->textures[i]->texturechains[chain] = NULL;

	// clear lightmap chains
	for (i=0 ; i<lightmap_count ; i++)
		lightmaps[i].polys = NULL;
}

/*
================
R_ChainSurface -- ericw -- adds the given surface to its texture chain
================
*/
void R_ChainSurface (msurface_t *surf, texchain_t chain)
{
	surf->texturechain = surf->texinfo->texture->texturechains[chain];
	surf->texinfo->texture->texturechains[chain] = surf;
}

/*
================
R_BackFaceCull -- johnfitz -- returns true if the surface is facing away from vieworg
================
*/
qboolean R_BackFaceCull (msurface_t *surf)
{
	double dot;

	if (surf->plane->type < 3)
		dot = r_refdef.vieworg[surf->plane->type] - surf->plane->dist;
	else
		dot = DotProduct (r_refdef.vieworg, surf->plane->normal) - surf->plane->dist;

	if ((dot < 0) ^ !!(surf->flags & SURF_PLANEBACK))
		return true;

	return false;
}

/*
===============
R_MarkSurfaces -- johnfitz -- mark surfaces based on PVS and rebuild texture chains
===============
*/
void R_MarkSurfaces (void)
{
	byte		*vis;
	mleaf_t		*leaf;
	msurface_t	*surf, **mark;
	int			i, j;
	qboolean	nearwaterportal;

	// clear lightmap chains
	for (i=0 ; i<lightmap_count ; i++)
		lightmaps[i].polys = NULL;

	// check this leaf for water portals
	// TODO: loop through all water surfs and use distance to leaf cullbox
	nearwaterportal = false;
	for (i=0, mark = r_viewleaf->firstmarksurface; i < r_viewleaf->nummarksurfaces; i++, mark++)
		if ((*mark)->flags & SURF_DRAWTURB)
			nearwaterportal = true;

	// PPC port (Round v6) — translucent-liquid mode. The map's PVS was
	// compiled assuming water/lava/slime are opaque, so leaves on the
	// far side of a liquid surface aren't in PVS. With r_wateralpha<1
	// the engine draws the liquid surface translucently, exposing
	// whatever (sky, void, distant unrelated geometry) is in the
	// framebuffer behind it. Result: the X-ray glitch the user keeps
	// seeing on id1 maps. Real fix is watervis-patched BSPs at compile
	// time; runtime fix is to bypass PVS culling for the world. Cost
	// is more world-surface draws per frame; on G3/G4 with the ~600-leaf
	// id1 maps it's fine.
	//
	// Trigger only when (a) wateralpha is actually translucent AND (b)
	// the worldmodel reports it isn't already vis'd transparent for
	// that liquid type (Mod_FindContentsTransparent). Watervis-patched
	// maps stay on the optimal PVS path.
	{
		qboolean want_translucent_liquid = false;
		if (cl.worldmodel)
		{
			int ct = cl.worldmodel->contentstransparent;
			if (r_wateralpha.value < 1.0f && !(ct & SURF_DRAWWATER))
				want_translucent_liquid = true;
			if (r_lavaalpha.value > 0.0f && r_lavaalpha.value < 1.0f && !(ct & SURF_DRAWLAVA))
				want_translucent_liquid = true;
			if (r_slimealpha.value > 0.0f && r_slimealpha.value < 1.0f && !(ct & SURF_DRAWSLIME))
				want_translucent_liquid = true;
			if (r_telealpha.value > 0.0f && r_telealpha.value < 1.0f && !(ct & SURF_DRAWTELE))
				want_translucent_liquid = true;
		}

		if (r_novis.value
		 || want_translucent_liquid
		 || r_viewleaf->contents == CONTENTS_SOLID
		 || r_viewleaf->contents == CONTENTS_SKY)
			vis = Mod_NoVisPVS (cl.worldmodel);
		else if (nearwaterportal)
			vis = SV_FatPVS (r_origin, cl.worldmodel);
		else
			vis = Mod_LeafPVS (r_viewleaf, cl.worldmodel);
	}

	r_visframecount++;

	// set all chains to null
	for (i=0 ; i<cl.worldmodel->numtextures ; i++)
		if (cl.worldmodel->textures[i])
			cl.worldmodel->textures[i]->texturechains[chain_world] = NULL;

	// iterate through leaves, marking surfaces
	leaf = &cl.worldmodel->leafs[1];
	for (i=0 ; i<cl.worldmodel->numleafs ; i++, leaf++)
	{
		if (vis[i>>3] & (1<<(i&7)))
		{
			if (R_CullBox(leaf->minmaxs, leaf->minmaxs + 3))
				continue;

			if (r_oldskyleaf.value || leaf->contents != CONTENTS_SKY)
				for (j=0, mark = leaf->firstmarksurface; j<leaf->nummarksurfaces; j++, mark++)
				{
					surf = *mark;
					if (surf->visframe != r_visframecount)
					{
						surf->visframe = r_visframecount;
						if (!R_CullBox(surf->mins, surf->maxs) && !R_BackFaceCull (surf))
						{
							rs_brushpolys++; //count wpolys here
							R_ChainSurface(surf, chain_world);
							R_RenderDynamicLightmaps(surf);
							if (surf->texinfo->texture->warpimage)
								surf->texinfo->texture->update_warp = true;
						}
					}
				}

			// add static models
			if (leaf->efrags)
				R_StoreEfrags (&leaf->efrags);
		}
	}
}

//==============================================================================
//
// DRAW CHAINS
//
//==============================================================================

/*
=============
R_BeginTransparentDrawing -- ericw
=============
*/
static void R_BeginTransparentDrawing (float entalpha)
{
	if (entalpha < 1.0f)
	{
		glDepthMask (GL_FALSE);
		glEnable (GL_BLEND);
		glTexEnvf (GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE);
		glColor4f (1,1,1,entalpha);
	}
}

/*
=============
R_EndTransparentDrawing -- ericw
=============
*/
static void R_EndTransparentDrawing (float entalpha)
{
	if (entalpha < 1.0f)
	{
		glDepthMask (GL_TRUE);
		glDisable (GL_BLEND);
		glTexEnvf (GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);
		glColor3f (1, 1, 1);
	}
}

/*
================
R_DrawTextureChains_ShowTris -- johnfitz
================
*/
void R_DrawTextureChains_ShowTris (qmodel_t *model, texchain_t chain)
{
	int			i;
	msurface_t	*s;
	texture_t	*t;
	glpoly_t	*p;

	for (i=0 ; i<model->numtextures ; i++)
	{
		t = model->textures[i];
		if (!t)
			continue;

		if (R_OldWaterEffective() && t->texturechains[chain] && (t->texturechains[chain]->flags & SURF_DRAWTURB))
		{
			for (s = t->texturechains[chain]; s; s = s->texturechain)
				for (p = s->polys->next; p; p = p->next)
				{
					DrawGLTriangleFan (p);
				}
		}
		else
		{
			for (s = t->texturechains[chain]; s; s = s->texturechain)
			{
				DrawGLTriangleFan (s->polys);
			}
		}
	}
}

/*
================
R_DrawTextureChains_Drawflat -- johnfitz
================
*/
void R_DrawTextureChains_Drawflat (qmodel_t *model, texchain_t chain)
{
	int			i;
	msurface_t	*s;
	texture_t	*t;
	glpoly_t	*p;

	for (i=0 ; i<model->numtextures ; i++)
	{
		t = model->textures[i];
		if (!t)
			continue;

		if (R_OldWaterEffective() && t->texturechains[chain] && (t->texturechains[chain]->flags & SURF_DRAWTURB))
		{
			for (s = t->texturechains[chain]; s; s = s->texturechain)
				for (p = s->polys->next; p; p = p->next)
				{
					srand((unsigned int) (uintptr_t) p);
					glColor3f (rand()%256/255.0, rand()%256/255.0, rand()%256/255.0);
					DrawGLPoly (p);
					rs_brushpasses++;
				}
		}
		else
		{
			for (s = t->texturechains[chain]; s; s = s->texturechain)
			{
				srand((unsigned int) (uintptr_t) s->polys);
				glColor3f (rand()%256/255.0, rand()%256/255.0, rand()%256/255.0);
				DrawGLPoly (s->polys);
				rs_brushpasses++;
			}
		}
	}
	glColor3f (1,1,1);
	srand ((int) (cl.time * 1000));
}

/*
================
R_DrawTextureChains_Glow -- johnfitz
================
*/
void R_DrawTextureChains_Glow (qmodel_t *model, entity_t *ent, texchain_t chain)
{
	int			i;
	msurface_t	*s;
	texture_t	*t;
	gltexture_t	*glt;
	qboolean	bound;

	R_BindBrushChain_Single ();   // PPC port -- Phase 3.3: hoist client state setup
	for (i=0 ; i<model->numtextures ; i++)
	{
		t = model->textures[i];

		if (!t || !t->texturechains[chain] || !(glt = R_TextureAnimation(t, ent != NULL ? ent->frame : 0)->fullbright))
			continue;

		bound = false;

		for (s = t->texturechains[chain]; s; s = s->texturechain)
		{
			if (!bound) //only bind once we are sure we need this texture
			{
				GL_Bind (glt);
				bound = true;
			}
			R_DrawBrushChainSurface (s);
			rs_brushpasses++;
		}
	}
	R_UnbindBrushChain_Single ();
}

//==============================================================================
//
// VBO SUPPORT
//
//==============================================================================

static int R_NumTriangleIndicesForSurf (msurface_t *s)
{
	return 3 * (s->numedges - 2);
}

/*
================
R_TriangleIndicesForSurf

Writes out the triangle indices needed to draw s as a triangle list.
The number of indices it will write is given by R_NumTriangleIndicesForSurf.
================
*/
static void R_TriangleIndicesForSurfBase (msurface_t *s, unsigned int base, unsigned int *dest)
{
	int i;
	for (i=2; i<s->numedges; i++)
	{
		*dest++ = base;
		*dest++ = base + i - 1;
		*dest++ = base + i;
	}
}

static void R_TriangleIndicesForSurf (msurface_t *s, unsigned int *dest)
{
	// GLSL/VBO path indexes into gl_bmodel_vbo by vbo_firstvert.
	R_TriangleIndicesForSurfBase (s, s->vbo_firstvert, dest);
}

#define MAX_BATCH_SIZE 4096

static unsigned int vbo_indices[MAX_BATCH_SIZE];
static unsigned int num_vbo_indices;

/*
================
R_ClearBatch
================
*/
static void R_ClearBatch (void)
{
	num_vbo_indices = 0;
}

/*
================
R_FlushBatch

Draw the current batch if non-empty and clears it, ready for more R_BatchSurface calls.
================
*/
static void R_FlushBatch (void)
{
	if (num_vbo_indices > 0)
	{
		glDrawElements (GL_TRIANGLES, num_vbo_indices, GL_UNSIGNED_INT, vbo_indices);
		num_vbo_indices = 0;
	}
}

/*
================
R_BatchSurface

Add the surface to the current batch, or just draw it immediately if we're not
using VBOs.
================
*/
static void R_BatchSurface (msurface_t *s)
{
	int num_surf_indices = R_NumTriangleIndicesForSurf (s);

	if (num_surf_indices <= 0)
	{
	//	Con_DWarning ("bad numedges for surface\n");
		return;
	}

	if (num_vbo_indices + num_surf_indices > MAX_BATCH_SIZE)
		R_FlushBatch();

	R_TriangleIndicesForSurf (s, &vbo_indices[num_vbo_indices]);
	num_vbo_indices += num_surf_indices;
}

/*
================
R_BatchSurfaceVar -- experiment/gl-surfbatch

Like R_BatchSurface, but indexes into the GL 1.x fixed-function client/VAR
brush pool by s->var_firstvert (R_BatchSurface uses s->vbo_firstvert, which is
only valid on the GLSL/VBO path that never runs on this hardware). Shares the
same vbo_indices[] accumulator + R_FlushBatch -- the GLSL and GL1 world paths
never execute in the same frame, so reusing the buffer is safe.
================
*/
static void R_BatchSurfaceVar (msurface_t *s)
{
	int num_surf_indices = R_NumTriangleIndicesForSurf (s);

	if (num_surf_indices <= 0)
		return;

	if (num_vbo_indices + num_surf_indices > MAX_BATCH_SIZE)
		R_FlushBatch();

	R_TriangleIndicesForSurfBase (s, s->var_firstvert, &vbo_indices[num_vbo_indices]);
	num_vbo_indices += num_surf_indices;
}

/*
================
R_DrawTextureChains_Multitexture -- johnfitz

PPC port -- Phase 3.3: two paths depending on whether the static brush
verts are VRAM-resident (gl_apple_var_able + pool built + opt-in).

  Array path (gl_apple_var_arrays_mtex && gl_apple_var_able): pointers
  bound once at the VAR pool base, per-surface draw is one glDrawArrays.
  This is the canonical "data parked in VRAM, driver re-fetches by
  index" pattern. Apple's ATI 1.4.18 driver should beat its own glBegin
  fast path here because the verts no longer move through client memory
  on every poly.

  Legacy glBegin path (G3 / -novar / -noarrays-mtex): unchanged from
  pre-3.3. The history note: Phase 1.1c's array conversion against
  client memory regressed -3 to -4% on this stack because the driver's
  small-poly glBegin path beat glDrawArrays when the data wasn't
  cached. Without VAR there's no win to be had on this path, so we
  preserve the legacy code as the fallback.
================
*/
void R_DrawTextureChains_Multitexture (qmodel_t *model, entity_t *ent, texchain_t chain)
{
	int			i, j;
	msurface_t	*s;
	texture_t	*t;
	float		*v;
	qboolean	bound;
	int			lastlightmap;	// batch_path: flush the glDrawElements batch on lightmap change
	// PPC port -- finding #4: the array path (bind once + glDrawArrays per
	// surface, no per-vertex glBegin) is taken when the brush pool is live,
	// either as the G4/Lion VAR pool (gated by -noarrays-mtex opt-out) or
	// as the G3 -g3clbrush plain client-array pool, or as the gl_surfbatch
	// experiment's auto-built plain pool.
	const qboolean array_path = (((gl_apple_var_arrays_mtex && gl_apple_var_able) || gl_bmodel_clientpool || gl_surfbatch.value) && gl_bmodel_var_pool);
	// experiment/gl-surfbatch: when on (and the pool is therefore live),
	// coalesce consecutive same-lightmap surfaces into a single
	// glDrawElements instead of one glDrawArrays per surface.
	const qboolean batch_path = array_path && gl_surfbatch.value;

	// PPC port -- Round v8 item 2 -- enable TMU1 once before the texture
	// loop on the legacy path too (array_path always did). The pre-v8 code
	// called GL_EnableMultitexture / GL_DisableMultitexture inside the loop
	// per texture chain (~30-50x per frame). Hoist saves the no-op
	// glEnable/glDisable + GL_SelectTexture pairs; only "select TMU1" is
	// retained per chain for binding the lightmap. Cmdline -nomtexhoist
	// reverts to per-chain toggles for bisection.
	const qboolean mtex_hoisted = !mtexhoist_disabled;
	const qboolean enable_once  = array_path || (!array_path && mtex_hoisted);

	if (array_path)
	{
		// Lightmap texcoords live at +5 in VERTEXSIZE -- TEXTURE1.
		// Diffuse texcoords at +3 -- TEXTURE0.
		R_BindBrushChain_Multi ();
	}
	if (enable_once)
		GL_EnableMultitexture ();    // selects TEXTURE1 + glEnable(TEXTURE_2D)

	for (i=0 ; i<model->numtextures ; i++)
	{
		t = model->textures[i];

		if (!t || !t->texturechains[chain] || t->texturechains[chain]->flags & (SURF_DRAWTURB | SURF_DRAWTILED | SURF_NOTEXTURE))
			continue;

		bound = false;
		lastlightmap = -1;	// batch_path: forces the first lightmap bind; the matching flush is a no-op on the empty batch
		if (batch_path)
			R_ClearBatch ();
		for (s = t->texturechains[chain]; s; s = s->texturechain)
		{
			if (!bound) //only bind once we are sure we need this texture
			{
				GL_SelectTexture (GL_TEXTURE0_ARB);
				GL_Bind ((R_TextureAnimation(t, ent != NULL ? ent->frame : 0))->gltexture);

				if (t->texturechains[chain]->flags & SURF_DRAWFENCE)
					glEnable (GL_ALPHA_TEST); // Flip alpha test back on

				// PPC port -- v8 item 2: when hoisted, TMU1 is already
				// enabled; just re-select it for the lightmap bind below.
				if (enable_once)
					GL_SelectTexture (GL_TEXTURE1_ARB);
				else
					GL_EnableMultitexture();   // legacy: enable+select TMU1

				bound = true;
			}
			if (batch_path)
			{
				// experiment/gl-surfbatch: accumulate surfaces sharing one
				// lightmap into a single glDrawElements; flush + rebind TMU1
				// only when the lightmap changes (mirrors the GLSL path).
				// Diffuse texture is constant for the whole chain, so the only
				// in-chain state break is the lightmap. Vertex + both TMU
				// texcoord arrays were bound once by R_BindBrushChain_Multi.
				if (s->lightmaptexturenum != lastlightmap)
				{
					R_FlushBatch ();
					GL_Bind (lightmaps[s->lightmaptexturenum].texture);	// TMU1 is the active unit here
					lastlightmap = s->lightmaptexturenum;
				}
				R_BatchSurfaceVar (s);
			}
			else
			{
				GL_Bind (lightmaps[s->lightmaptexturenum].texture);
				if (array_path)
				{
					R_DrawBrushChainSurface_Multi (s);
				}
				else
				{
					glBegin(GL_POLYGON);
					v = s->polys->verts[0];
					for (j=0 ; j<s->polys->numverts ; j++, v+= VERTEXSIZE)
					{
						GL_MTexCoord2fFunc (GL_TEXTURE0_ARB, v[3], v[4]);
						GL_MTexCoord2fFunc (GL_TEXTURE1_ARB, v[5], v[6]);
						glVertex3fv (v);
					}
					glEnd ();
				}
			}
			rs_brushpasses++;
		}
		if (batch_path)
			R_FlushBatch ();	// drain the last lightmap group before the diffuse texture changes
		// PPC port -- v8 item 2: legacy path no longer disables TMU1
		// per-texture when hoist is active; we disable once after the loop.
		if (!array_path && !mtex_hoisted)
			GL_DisableMultitexture(); // legacy fallback: per-chain disable

		if (bound && t->texturechains[chain]->flags & SURF_DRAWFENCE)
			glDisable (GL_ALPHA_TEST); // Flip alpha test back off
	}

	if (enable_once)
		GL_DisableMultitexture ();   // selects TEXTURE0 for rest of pipeline
	if (array_path)
		R_UnbindBrushChain_Multi ();
}

/*
================
R_DrawTextureChains_NoTexture -- johnfitz

draws surfs whose textures were missing from the BSP
================
*/
void R_DrawTextureChains_NoTexture (qmodel_t *model, texchain_t chain)
{
	int			i;
	msurface_t	*s;
	texture_t	*t;
	qboolean	bound;

	R_BindBrushChain_Single ();   // PPC port -- Phase 3.3
	for (i=0 ; i<model->numtextures ; i++)
	{
		t = model->textures[i];

		if (!t || !t->texturechains[chain] || !(t->texturechains[chain]->flags & SURF_NOTEXTURE))
			continue;

		bound = false;

		for (s = t->texturechains[chain]; s; s = s->texturechain)
		{
			if (!bound) //only bind once we are sure we need this texture
			{
				GL_Bind (t->gltexture);
				bound = true;
			}
			R_DrawBrushChainSurface (s);
			rs_brushpasses++;
		}
	}
	R_UnbindBrushChain_Single ();
}

/*
================
R_DrawTextureChains_TextureOnly -- johnfitz
================
*/
void R_DrawTextureChains_TextureOnly (qmodel_t *model, entity_t *ent, texchain_t chain)
{
	int			i;
	msurface_t	*s;
	texture_t	*t;
	qboolean	bound;

	R_BindBrushChain_Single ();   // PPC port -- Phase 3.3
	for (i=0 ; i<model->numtextures ; i++)
	{
		t = model->textures[i];

		if (!t || !t->texturechains[chain] || t->texturechains[chain]->flags & (SURF_DRAWTURB | SURF_DRAWSKY))
			continue;

		bound = false;

		for (s = t->texturechains[chain]; s; s = s->texturechain)
		{
			if (!bound) //only bind once we are sure we need this texture
			{
				GL_Bind ((R_TextureAnimation(t, ent != NULL ? ent->frame : 0))->gltexture);

				if (t->texturechains[chain]->flags & SURF_DRAWFENCE)
					glEnable (GL_ALPHA_TEST); // Flip alpha test back on

				bound = true;
			}
			R_DrawBrushChainSurface (s);
			rs_brushpasses++;
		}

		if (bound && t->texturechains[chain]->flags & SURF_DRAWFENCE)
			glDisable (GL_ALPHA_TEST); // Flip alpha test back off
	}
	R_UnbindBrushChain_Single ();
}

/*
================
GL_WaterAlphaForEntitySurface -- ericw

Returns the water alpha to use for the entity and surface combination.
================
*/
float GL_WaterAlphaForEntitySurface (entity_t *ent, msurface_t *s)
{
	float entalpha;
	if (ent == NULL || ent->alpha == ENTALPHA_DEFAULT)
		entalpha = GL_WaterAlphaForSurface(s);
	else
		entalpha = ENTALPHA_DECODE(ent->alpha);
	return entalpha;
}

static GLuint r_world_program;
extern GLuint gl_bmodel_vbo;

// uniforms used in vert shader

// uniforms used in frag shader
static GLint  texLoc;
static GLint  LMTexLoc;
static GLint  fullbrightTexLoc;
static GLint  useFullbrightTexLoc;
static GLint  useOverbrightLoc;
static GLint  useAlphaTestLoc;
static GLint  useLightmapWideLoc;
static GLint  useLightmapOnlyLoc;
static GLint  alphaLoc;

#define vertAttrIndex 0
#define texCoordsAttrIndex 1
#define LMCoordsAttrIndex 2

/*
================
R_DrawTextureChains_Water -- johnfitz
================
*/
void R_DrawTextureChains_Water (qmodel_t *model, entity_t *ent, texchain_t chain)
{
	int			i;
	msurface_t	*s;
	texture_t	*t;
	glpoly_t	*p;
	qboolean	bound;
	float entalpha;
	int		lastlightmap;
	qboolean	has_lit_water;
	qboolean	has_unlit_water;

	if (r_drawflat_cheatsafe || r_lightmap_cheatsafe) // ericw -- !r_drawworld_cheatsafe check moved to R_DrawWorld_Water ()
		return;

	has_lit_water = false;
	has_unlit_water = false;

	if (R_OldWaterEffective())
	{
		// PPC port -- Round v7 phase 6: hoist GL_VERTEX_ARRAY +
		// GL_TEXTURE_COORD_ARRAY client state out of DrawWaterPoly's
		// per-poly toggle. R_BeginTransparentDrawing (called inside
		// the loop) only touches depth-mask / blend / texenv-mode /
		// color — not client state — so see-through water (r_wateralpha
		// 0.6 + watervis NoVis) is unaffected. -nodgp-water-hoist
		// reverts to the per-poly pattern for A/B.
		extern qboolean water_hoist_disabled;
		const qboolean hoist_water = !water_hoist_disabled;
		if (hoist_water)
		{
			glEnableClientState (GL_VERTEX_ARRAY);
			glEnableClientState (GL_TEXTURE_COORD_ARRAY);
		}
		for (i=0 ; i<model->numtextures ; i++)
		{
			t = model->textures[i];
			if (!t || !t->texturechains[chain] || !(t->texturechains[chain]->flags & SURF_DRAWTURB))
				continue;
			bound = false;
			entalpha = 1.0f;
			for (s = t->texturechains[chain]; s; s = s->texturechain)
			{
				if (!bound) //only bind once we are sure we need this texture
				{
					entalpha = GL_WaterAlphaForEntitySurface (ent, s);
					R_BeginTransparentDrawing (entalpha);
					GL_Bind (t->gltexture);
					bound = true;
				}
				for (p = s->polys->next; p; p = p->next)
				{
					DrawWaterPoly (p);
					rs_brushpasses++;
				}
			}
			R_EndTransparentDrawing (entalpha);
		}
		if (hoist_water)
		{
			glDisableClientState (GL_TEXTURE_COORD_ARRAY);
			glDisableClientState (GL_VERTEX_ARRAY);
		}
	}
	else if (cl.worldmodel->haslitwater && r_litwater.value && r_world_program != 0)
	{
		const int overbright = !!gl_overbright.value;
		const int wide10bits = !!r_lightmapwide.value;

		has_lit_water = true;

		GL_UseProgramFunc (r_world_program);

		// Bind the buffers
		GL_BindBuffer (GL_ARRAY_BUFFER, gl_bmodel_vbo);
		GL_BindBuffer (GL_ELEMENT_ARRAY_BUFFER, 0);

		GL_EnableVertexAttribArrayFunc (vertAttrIndex);
		GL_EnableVertexAttribArrayFunc (texCoordsAttrIndex);
		GL_EnableVertexAttribArrayFunc (LMCoordsAttrIndex);

		GL_VertexAttribPointerFunc (vertAttrIndex,      3, GL_FLOAT, GL_FALSE, VERTEXSIZE * sizeof(float), ((float *)0));
		GL_VertexAttribPointerFunc (texCoordsAttrIndex, 2, GL_FLOAT, GL_FALSE, VERTEXSIZE * sizeof(float), ((float *)0) + 3);
		GL_VertexAttribPointerFunc (LMCoordsAttrIndex,  2, GL_FLOAT, GL_FALSE, VERTEXSIZE * sizeof(float), ((float *)0) + 5);

		// Set uniforms
		GL_Uniform1iFunc (texLoc, 0);
		GL_Uniform1iFunc (LMTexLoc, 1);
		GL_Uniform1iFunc (fullbrightTexLoc, 2);
		GL_Uniform1iFunc (useFullbrightTexLoc, 0);
		GL_Uniform1iFunc (useOverbrightLoc, overbright);
		GL_Uniform1iFunc (useAlphaTestLoc, 0);
		GL_Uniform1iFunc (useLightmapWideLoc, wide10bits);
		GL_Uniform1iFunc (useLightmapOnlyLoc, 0);

		for (i=0 ; i<model->numtextures ; i++)
		{
			t = model->textures[i];

			if (!t || !t->texturechains[chain] || !(t->texturechains[chain]->flags & SURF_DRAWTURB))
				continue;

			if (t->texturechains[chain]->texinfo->flags & TEX_SPECIAL)
			{
				has_unlit_water = true;
				continue;
			}

			bound = false;
			entalpha = 1.0f;
			lastlightmap = 0;
			for (s = t->texturechains[chain]; s; s = s->texturechain)
			{
				if (!bound) //only bind once we are sure we need this texture
				{
					entalpha = GL_WaterAlphaForEntitySurface (ent, s);
					if (entalpha < 1.0f)
					{
						GL_Uniform1fFunc (alphaLoc, entalpha);
						R_BeginTransparentDrawing (entalpha);
					}

					GL_SelectTexture (GL_TEXTURE0);
					GL_Bind (t->warpimage);

					if (model != cl.worldmodel)
					{
						// ericw -- this is copied from R_DrawSequentialPoly.
						// If the poly is not part of the world we have to
						// set this flag
						t->update_warp = true; // FIXME: one frame too late!
					}

					bound = true;
					lastlightmap = s->lightmaptexturenum;
				}

				if (s->lightmaptexturenum != lastlightmap)
					R_FlushBatch ();

				GL_SelectTexture (GL_TEXTURE1);
				GL_Bind (lightmaps[s->lightmaptexturenum].texture);
				lastlightmap = s->lightmaptexturenum;
				R_BatchSurface (s);

				rs_brushpasses++;
			}
			R_FlushBatch ();
			R_EndTransparentDrawing (entalpha);
		}

		// clean up
		GL_DisableVertexAttribArrayFunc (vertAttrIndex);
		GL_DisableVertexAttribArrayFunc (texCoordsAttrIndex);
		GL_DisableVertexAttribArrayFunc (LMCoordsAttrIndex);
		GL_UseProgramFunc (0);
		GL_SelectTexture (GL_TEXTURE0);
	}
	else
		has_unlit_water = true;

	if (has_unlit_water)
	{
		// Unlit water
		for (i=0 ; i<model->numtextures ; i++)
		{
			t = model->textures[i];
			if (!t || !t->texturechains[chain] || !(t->texturechains[chain]->flags & SURF_DRAWTURB))
				continue;
			if (has_lit_water && !(t->texturechains[chain]->texinfo->flags & TEX_SPECIAL))
				continue;
			bound = false;
			entalpha = 1.0f;
			for (s = t->texturechains[chain]; s; s = s->texturechain)
			{
				if (!bound) //only bind once we are sure we need this texture
				{
					entalpha = GL_WaterAlphaForEntitySurface (ent, s);
					R_BeginTransparentDrawing (entalpha);
					GL_Bind (t->warpimage);

					if (model != cl.worldmodel)
					{
						// ericw -- this is copied from R_DrawSequentialPoly.
						// If the poly is not part of the world we have to
						// set this flag
						t->update_warp = true; // FIXME: one frame too late!
					}

					bound = true;
				}
				DrawGLPoly (s->polys);
				rs_brushpasses++;
			}
			R_EndTransparentDrawing (entalpha);
		}
	}
}

/*
================
R_DrawTextureChains_White -- johnfitz -- draw sky and water as white polys when r_lightmap is 1
================
*/
void R_DrawTextureChains_White (qmodel_t *model, texchain_t chain)
{
	int			i;
	msurface_t	*s;
	texture_t	*t;

	glDisable (GL_TEXTURE_2D);
	for (i=0 ; i<model->numtextures ; i++)
	{
		t = model->textures[i];

		if (!t || !t->texturechains[chain] || !(t->texturechains[chain]->flags & SURF_DRAWTILED))
			continue;

		for (s = t->texturechains[chain]; s; s = s->texturechain)
		{
			DrawGLPoly (s->polys);
			rs_brushpasses++;
		}
	}
	glEnable (GL_TEXTURE_2D);
}

/*
================
R_DrawLightmapChains -- johnfitz -- R_BlendLightmaps stripped down to almost nothing
PPC port -- client vertex arrays (lightmap texcoords at +5 in glpoly_t::verts).
Cheat path (r_lightmap_cheatsafe) only; trivial fold-in for code-completeness.
================
*/
void R_DrawLightmapChains (void)
{
	int			i;
	glpoly_t	*p;
	float		*v;

	glEnableClientState (GL_VERTEX_ARRAY);
	glEnableClientState (GL_TEXTURE_COORD_ARRAY);

	for (i=0 ; i<lightmap_count ; i++)
	{
		if (!lightmaps[i].polys)
			continue;

		GL_Bind (lightmaps[i].texture);
		for (p = lightmaps[i].polys; p; p=p->chain)
		{
			v = p->verts[0];
			glVertexPointer (3, GL_FLOAT, VERTEXSIZE*sizeof(float), v);
			glTexCoordPointer (2, GL_FLOAT, VERTEXSIZE*sizeof(float), v + 5);
			glDrawArrays (GL_POLYGON, 0, p->numverts);
			rs_brushpasses++;
		}
	}

	glDisableClientState (GL_TEXTURE_COORD_ARRAY);
	glDisableClientState (GL_VERTEX_ARRAY);
}

/*
=============
GLWorld_CreateShaders
=============
*/
void GLWorld_CreateShaders (void)
{
	const glsl_attrib_binding_t bindings[] = {
		{ "Vert", vertAttrIndex },
		{ "TexCoords", texCoordsAttrIndex },
		{ "LMCoords", LMCoordsAttrIndex }
	};

	// Driver bug workarounds:
	// - "Intel(R) UHD Graphics 600" version "4.6.0 - Build 26.20.100.7263"
	//    crashing on glUseProgram with `vec3 Vert` and
	//    `gl_ModelViewProjectionMatrix * vec4(Vert, 1.0);`. Work around with
	//    making Vert a vec4. (https://sourceforge.net/p/quakespasm/bugs/39/)
	const GLchar *vertSource = \
		"#version 110\n"
		"\n"
		"attribute vec4 Vert;\n"
		"attribute vec2 TexCoords;\n"
		"attribute vec2 LMCoords;\n"
		"\n"
		"varying float FogFragCoord;\n"
		"\n"
		"void main()\n"
		"{\n"
		"	gl_TexCoord[0] = vec4(TexCoords, 0.0, 0.0);\n"
		"	gl_TexCoord[1] = vec4(LMCoords, 0.0, 0.0);\n"
		"	gl_Position = gl_ModelViewProjectionMatrix * Vert;\n"
		"	FogFragCoord = gl_Position.w;\n"
		"}\n";
	
	const GLchar *fragSource = \
		"#version 110\n"
		"\n"
		"uniform sampler2D Tex;\n"
		"uniform sampler2D LMTex;\n"
		"uniform sampler2D FullbrightTex;\n"
		"uniform bool UseFullbrightTex;\n"
		"uniform bool UseOverbright;\n"
		"uniform bool UseAlphaTest;\n"
		"uniform bool UseLightmapWide;\n"
		"uniform bool UseLightmapOnly;\n"
		"uniform float Alpha;\n"
		"\n"
		"varying float FogFragCoord;\n"
		"\n"
		"void main()\n"
		"{\n"
		"	vec4 result = texture2D(Tex, gl_TexCoord[0].xy);\n"
		"	if (UseLightmapOnly)\n"
		"		result = vec4(0.5, 0.5, 0.5, 1.0);\n"
		"	if (UseAlphaTest && (result.a < 0.666))\n"
		"		discard;\n"
		"	result *= texture2D(LMTex, gl_TexCoord[1].xy);\n"
		"	if (UseLightmapWide)\n"
		"	    result.rgb *= 4.0;\n"
		"	if (UseOverbright)\n"
		"		result.rgb *= 2.0;\n"
		"	if (UseFullbrightTex)\n"
		"		result += texture2D(FullbrightTex, gl_TexCoord[0].xy);\n"
		"	result = clamp(result, 0.0, 1.0);\n"
		"	float fog = exp(-gl_Fog.density * gl_Fog.density * FogFragCoord * FogFragCoord);\n"
		"	fog = clamp(fog, 0.0, 1.0);\n"
		"	result = mix(gl_Fog.color, result, fog);\n"
		"	result.a = Alpha;\n" // FIXME: This will make almost transparent things cut holes though heavy fog
		"	gl_FragColor = result;\n"
		"}\n";

	if (!gl_glsl_alias_able)
		return;

	r_world_program = GL_CreateProgram (vertSource, fragSource, Q_COUNTOF(bindings), bindings);
	
	if (r_world_program != 0)
	{
		// get uniform locations
		texLoc = GL_GetUniformLocation (&r_world_program, "Tex");
		LMTexLoc = GL_GetUniformLocation (&r_world_program, "LMTex");
		fullbrightTexLoc = GL_GetUniformLocation (&r_world_program, "FullbrightTex");
		useFullbrightTexLoc = GL_GetUniformLocation (&r_world_program, "UseFullbrightTex");
		useOverbrightLoc = GL_GetUniformLocation (&r_world_program, "UseOverbright");
		useAlphaTestLoc = GL_GetUniformLocation (&r_world_program, "UseAlphaTest");
		useLightmapWideLoc = GL_GetUniformLocation (&r_world_program, "UseLightmapWide");
		useLightmapOnlyLoc = GL_GetUniformLocation (&r_world_program, "UseLightmapOnly");
		alphaLoc = GL_GetUniformLocation (&r_world_program, "Alpha");
	}
}

/*
================
R_DrawTextureChains_GLSL -- ericw

Draw lightmapped surfaces with fulbrights in one pass, using VBO.
Requires 3 TMUs, OpenGL 2.0
================
*/
void R_DrawTextureChains_GLSL (qmodel_t *model, entity_t *ent, texchain_t chain)
{
	const float	entalpha = (ent != NULL) ?
			 ENTALPHA_DECODE(ent->alpha) : 1.0f;
	const int	overbright = !!gl_overbright.value;
	const int	wide10bits = !!r_lightmapwide.value;

	int			i;
	msurface_t	*s;
	texture_t	*t;
	qboolean	bound;
	int		lastlightmap;
	gltexture_t	*fullbright = NULL;

// enable blending / disable depth writes
	if (entalpha < 1)
	{
		glDepthMask (GL_FALSE);
		glEnable (GL_BLEND);
	}

	GL_UseProgramFunc (r_world_program);

// Bind the buffers
	GL_BindBuffer (GL_ARRAY_BUFFER, gl_bmodel_vbo);
	GL_BindBuffer (GL_ELEMENT_ARRAY_BUFFER, 0); // indices come from client memory!

	GL_EnableVertexAttribArrayFunc (vertAttrIndex);
	GL_EnableVertexAttribArrayFunc (texCoordsAttrIndex);
	GL_EnableVertexAttribArrayFunc (LMCoordsAttrIndex);

	GL_VertexAttribPointerFunc (vertAttrIndex,      3, GL_FLOAT, GL_FALSE, VERTEXSIZE * sizeof(float), ((float *)0));
	GL_VertexAttribPointerFunc (texCoordsAttrIndex, 2, GL_FLOAT, GL_FALSE, VERTEXSIZE * sizeof(float), ((float *)0) + 3);
	GL_VertexAttribPointerFunc (LMCoordsAttrIndex,  2, GL_FLOAT, GL_FALSE, VERTEXSIZE * sizeof(float), ((float *)0) + 5);

// set uniforms
	GL_Uniform1iFunc (texLoc, 0);
	GL_Uniform1iFunc (LMTexLoc, 1);
	GL_Uniform1iFunc (fullbrightTexLoc, 2);
	GL_Uniform1iFunc (useFullbrightTexLoc, 0);
	GL_Uniform1iFunc (useOverbrightLoc, overbright);
	GL_Uniform1iFunc (useAlphaTestLoc, 0);
	GL_Uniform1iFunc (useLightmapWideLoc, wide10bits);
	GL_Uniform1iFunc (useLightmapOnlyLoc, 0);
	GL_Uniform1fFunc (alphaLoc, entalpha);

	for (i=0 ; i<model->numtextures ; i++)
	{
		t = model->textures[i];

		if (!t || !t->texturechains[chain] || t->texturechains[chain]->flags & (SURF_DRAWTURB | SURF_DRAWTILED | SURF_NOTEXTURE))
			continue;

	// Enable/disable TMU 2 (fullbrights)
	// FIXME: Move below to where we bind GL_TEXTURE0
		if (gl_fullbrights.value && (fullbright = R_TextureAnimation(t, ent != NULL ? ent->frame : 0)->fullbright))
		{
			GL_SelectTexture (GL_TEXTURE2);
			GL_Bind (fullbright);
			GL_Uniform1iFunc (useFullbrightTexLoc, 1);
		}
		else
			GL_Uniform1iFunc (useFullbrightTexLoc, 0);

		R_ClearBatch ();

		bound = false;
		lastlightmap = 0; // avoid compiler warning
		for (s = t->texturechains[chain]; s; s = s->texturechain)
		{
			if (!bound) //only bind once we are sure we need this texture
			{
				GL_SelectTexture (GL_TEXTURE0);
				GL_Bind ((R_TextureAnimation(t, ent != NULL ? ent->frame : 0))->gltexture);
				if (t->texturechains[chain]->flags & SURF_DRAWFENCE)
					GL_Uniform1iFunc (useAlphaTestLoc, 1); // Flip alpha test back on
										
				bound = true;
				lastlightmap = s->lightmaptexturenum;
			}
				
			if (s->lightmaptexturenum != lastlightmap)
				R_FlushBatch ();

			GL_SelectTexture (GL_TEXTURE1);
			GL_Bind (lightmaps[s->lightmaptexturenum].texture);
			lastlightmap = s->lightmaptexturenum;
			R_BatchSurface (s);

			rs_brushpasses++;
		}

		R_FlushBatch ();

		if (bound && t->texturechains[chain]->flags & SURF_DRAWFENCE)
			GL_Uniform1iFunc (useAlphaTestLoc, 0); // Flip alpha test back off
	}

	// clean up
	GL_DisableVertexAttribArrayFunc (vertAttrIndex);
	GL_DisableVertexAttribArrayFunc (texCoordsAttrIndex);
	GL_DisableVertexAttribArrayFunc (LMCoordsAttrIndex);

	GL_UseProgramFunc (0);
	GL_SelectTexture (GL_TEXTURE0);

	if (entalpha < 1)
	{
		glDepthMask (GL_TRUE);
		glDisable (GL_BLEND);
	}
}

/*
================
R_DrawLightmapChains_GLSL -- ericw
================
*/
void R_DrawLightmapChains_GLSL(qmodel_t* model, entity_t* ent, texchain_t chain)
{
	const int	overbright = !!gl_overbright.value;
	const int	wide10bits = !!r_lightmapwide.value;

	int			i;
	msurface_t* s;
	texture_t* t;
	int		lastlightmap;

	GL_UseProgramFunc(r_world_program);

	// Bind the buffers
	GL_BindBuffer(GL_ARRAY_BUFFER, gl_bmodel_vbo);
	GL_BindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0); // indices come from client memory!

	GL_EnableVertexAttribArrayFunc(vertAttrIndex);
	GL_EnableVertexAttribArrayFunc(texCoordsAttrIndex);
	GL_EnableVertexAttribArrayFunc(LMCoordsAttrIndex);

	GL_VertexAttribPointerFunc(vertAttrIndex, 3, GL_FLOAT, GL_FALSE, VERTEXSIZE * sizeof(float), ((float*)0));
	GL_VertexAttribPointerFunc(texCoordsAttrIndex, 2, GL_FLOAT, GL_FALSE, VERTEXSIZE * sizeof(float), ((float*)0) + 3);
	GL_VertexAttribPointerFunc(LMCoordsAttrIndex, 2, GL_FLOAT, GL_FALSE, VERTEXSIZE * sizeof(float), ((float*)0) + 5);

	// set uniforms
	GL_Uniform1iFunc(texLoc, 0);
	GL_Uniform1iFunc(LMTexLoc, 1);
	GL_Uniform1iFunc(fullbrightTexLoc, 2);
	GL_Uniform1iFunc(useFullbrightTexLoc, 0);
	GL_Uniform1iFunc(useOverbrightLoc, overbright);
	GL_Uniform1iFunc(useAlphaTestLoc, 0);
	GL_Uniform1iFunc(useLightmapWideLoc, wide10bits);
	GL_Uniform1fFunc(alphaLoc, 1.0f);
	GL_Uniform1iFunc(useFullbrightTexLoc, 0);
	GL_Uniform1iFunc(useLightmapOnlyLoc, 1);

	R_ClearBatch();
	lastlightmap = -1;

	for (i = 0; i < model->numtextures; i++)
	{
		t = model->textures[i];

		if (!t || !t->texturechains[chain] || t->texturechains[chain]->flags & (SURF_DRAWTILED | SURF_NOTEXTURE))
			continue;

		if (t->texturechains[chain]->texinfo->flags & TEX_SPECIAL)
			continue; // unlit water

		for (s = t->texturechains[chain]; s; s = s->texturechain)
		{
			if (s->lightmaptexturenum < 0)
				continue;

			if (s->lightmaptexturenum != lastlightmap)
			{
				R_FlushBatch();

				GL_SelectTexture(GL_TEXTURE1);
				GL_Bind(lightmaps[s->lightmaptexturenum].texture);
				lastlightmap = s->lightmaptexturenum;
			}
			R_BatchSurface(s);

			rs_brushpasses++;
		}
	}

	R_FlushBatch();

	// clean up
	GL_DisableVertexAttribArrayFunc(vertAttrIndex);
	GL_DisableVertexAttribArrayFunc(texCoordsAttrIndex);
	GL_DisableVertexAttribArrayFunc(LMCoordsAttrIndex);

	GL_UseProgramFunc(0);
	GL_SelectTexture(GL_TEXTURE0);
}

/*
=============
R_DrawWorld -- johnfitz -- rewritten
=============
*/
void R_DrawTextureChains (qmodel_t *model, entity_t *ent, texchain_t chain)
{
	float entalpha;
	
	if (ent != NULL)
		entalpha = ENTALPHA_DECODE(ent->alpha);
	else
		entalpha = 1;

	R_UploadLightmaps ();

	if (r_drawflat_cheatsafe)
	{
		glDisable (GL_TEXTURE_2D);
		R_DrawTextureChains_Drawflat (model, chain);
		glEnable (GL_TEXTURE_2D);
		return;
	}

	if (r_fullbright_cheatsafe)
	{
		R_BeginTransparentDrawing (entalpha);
		R_DrawTextureChains_TextureOnly (model, ent, chain);
		R_EndTransparentDrawing (entalpha);
		goto fullbrights;
	}

	if (r_lightmap_cheatsafe)
	{
		if (r_world_program != 0)
		{
			R_DrawLightmapChains_GLSL(model, ent, chain);
			return;
		}

		if (!gl_overbright.value)
		{
			glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE);
			glColor3f(0.5, 0.5, 0.5);
		}
		R_DrawLightmapChains ();
		if (!gl_overbright.value)
		{
			glColor3f(1,1,1);
			glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);
		}
		R_DrawTextureChains_White (model, chain);
		return;
	}

	R_BeginTransparentDrawing (entalpha);

	R_DrawTextureChains_NoTexture (model, chain);

	// OpenGL 2 fast path
	if (r_world_program != 0)
	{
		R_EndTransparentDrawing (entalpha);
		
		R_DrawTextureChains_GLSL (model, ent, chain);
		return;
	}

	if (gl_overbright.value)
	{
		if (gl_texture_env_combine && gl_mtexable) //case 1: texture and lightmap in one pass, overbright using texture combiners
		{
			GL_EnableMultitexture ();
			glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_COMBINE_EXT);
			glTexEnvi(GL_TEXTURE_ENV, GL_COMBINE_RGB_EXT, GL_MODULATE);
			glTexEnvi(GL_TEXTURE_ENV, GL_SOURCE0_RGB_EXT, GL_PREVIOUS_EXT);
			glTexEnvi(GL_TEXTURE_ENV, GL_SOURCE1_RGB_EXT, GL_TEXTURE);
			glTexEnvf(GL_TEXTURE_ENV, GL_RGB_SCALE_EXT, 2.0f);
			GL_DisableMultitexture ();
			R_DrawTextureChains_Multitexture (model, ent, chain);
			GL_EnableMultitexture ();
			glTexEnvf(GL_TEXTURE_ENV, GL_RGB_SCALE_EXT, 1.0f);
			glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE);
			GL_DisableMultitexture ();
			glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);
		}
		else if (entalpha < 1) //case 2: can't do multipass if entity has alpha, so just draw the texture
		{
			R_DrawTextureChains_TextureOnly (model, ent, chain);
		}
		else //case 3: texture in one pass, lightmap in second pass using 2x modulation blend func, fog in third pass
		{
			//to make fog work with multipass lightmapping, need to do one pass
			//with no fog, one modulate pass with black fog, and one additive
			//pass with black geometry and normal fog
			Fog_DisableGFog ();
			R_DrawTextureChains_TextureOnly (model, ent, chain);
			Fog_EnableGFog ();
			glDepthMask (GL_FALSE);
			glEnable (GL_BLEND);
			glBlendFunc (GL_DST_COLOR, GL_SRC_COLOR); //2x modulate
			Fog_StartAdditive ();
			R_DrawLightmapChains ();
			Fog_StopAdditive ();
			if (Fog_GetDensity() > 0)
			{
				glBlendFunc(GL_ONE, GL_ONE); //add
				glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE);
				glColor3f(0,0,0);
				R_DrawTextureChains_TextureOnly (model, ent, chain);
				glColor3f(1,1,1);
				glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);
			}
			glBlendFunc (GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
			glDisable (GL_BLEND);
			glDepthMask (GL_TRUE);
		}
	}
	else
	{
		if (gl_mtexable) //case 4: texture and lightmap in one pass, regular modulation
		{
			GL_EnableMultitexture ();
			glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE);
			GL_DisableMultitexture ();
			R_DrawTextureChains_Multitexture (model, ent, chain);
			glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);
		}
		else if (entalpha < 1) //case 5: can't do multipass if entity has alpha, so just draw the texture
		{
			R_DrawTextureChains_TextureOnly (model, ent, chain);
		}
		else //case 6: texture in one pass, lightmap in a second pass, fog in third pass
		{
			//to make fog work with multipass lightmapping, need to do one pass
			//with no fog, one modulate pass with black fog, and one additive
			//pass with black geometry and normal fog
			Fog_DisableGFog ();
			R_DrawTextureChains_TextureOnly (model, ent, chain);
			Fog_EnableGFog ();
			glDepthMask (GL_FALSE);
			glEnable (GL_BLEND);
			glBlendFunc(GL_ZERO, GL_SRC_COLOR); //modulate
			Fog_StartAdditive ();
			R_DrawLightmapChains ();
			Fog_StopAdditive ();
			if (Fog_GetDensity() > 0)
			{
				glBlendFunc(GL_ONE, GL_ONE); //add
				glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE);
				glColor3f(0,0,0);
				R_DrawTextureChains_TextureOnly (model, ent, chain);
				glColor3f(1,1,1);
				glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);
			}
			glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
			glDisable (GL_BLEND);
			glDepthMask (GL_TRUE);
		}
	}

	R_EndTransparentDrawing (entalpha);

fullbrights:
	if (gl_fullbrights.value)
	{
		glDepthMask (GL_FALSE);
		glEnable (GL_BLEND);
		glBlendFunc (GL_ONE, GL_ONE);
		glTexEnvf (GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE);
		glColor3f (entalpha, entalpha, entalpha);
		Fog_StartAdditive ();
		R_DrawTextureChains_Glow (model, ent, chain);
		Fog_StopAdditive ();
		glColor3f (1, 1, 1);
		glTexEnvf (GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);
		glBlendFunc (GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
		glDisable (GL_BLEND);
		glDepthMask (GL_TRUE);
	}
}

/*
=============
R_DrawWorld -- ericw -- moved from R_DrawTextureChains, which is no longer specific to the world.
=============
*/
void R_DrawWorld (void)
{
	if (!r_drawworld_cheatsafe)
		return;

	R_DrawTextureChains (cl.worldmodel, NULL, chain_world);
}

/*
=============
R_DrawWorld_Water -- ericw -- moved from R_DrawTextureChains_Water, which is no longer specific to the world.
=============
*/
void R_DrawWorld_Water (void)
{
	if (!r_drawworld_cheatsafe)
		return;

	// PPC port (Round v6) — back to upstream behaviour. The depth
	// prepass + GL_LEQUAL pairing was a dead end: it caused water-
	// surface tearing on Radeon 9000 (depth round-trip wasn't
	// bit-exact). NoVisPVS-when-translucent in R_MarkSurfaces is now
	// the load-bearing fix; water just blends over fully-drawn world
	// geometry the standard way.
	R_DrawTextureChains_Water (cl.worldmodel, NULL, chain_world);
}

/*
=============
R_DrawWorld_ShowTris -- ericw -- moved from R_DrawTextureChains_ShowTris, which is no longer specific to the world.
=============
*/
void R_DrawWorld_ShowTris (void)
{
	if (!r_drawworld_cheatsafe)
		return;

	R_DrawTextureChains_ShowTris (cl.worldmodel, chain_world);
}
