/*
Copyright (C) 1996-2001 Id Software, Inc.
Copyright (C) 2002-2009 John Fitzgibbons and others
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

//r_alias.c -- alias model rendering

#include "quakedef.h"

// PPC port -- Phase 4.1: AltiVec lerp on G4 builds. The G3 build sets
// no -maltivec flag (see scripts/build.sh CPUFLAGS), so __ALTIVEC__ is
// undefined there and altivec.h doesn't get included.
#ifdef __ALTIVEC__
#include <altivec.h>
#endif

extern cvar_t r_drawflat, gl_overbright_models, gl_fullbrights, r_lerpmodels, r_lerpmove; //johnfitz
extern cvar_t scr_fov, cl_gun_fovscale;

//up to 16 color translated skins
gltexture_t *playertextures[MAX_SCOREBOARD]; //johnfitz -- changed to an array of pointers

const float	r_avertexnormals[NUMVERTEXNORMALS][3] = {
#include "anorms.h"
};

extern vec3_t	lightcolor; //johnfitz -- replaces "float shadelight" for lit support

// precalculated dot products for quantized angles
#define SHADEDOT_QUANT 16
static const float	r_avertexnormal_dots[SHADEDOT_QUANT][256] = {
#include "anorm_dots.h"
};

extern	vec3_t	lightspot;

static const float	*shadedots = r_avertexnormal_dots[0];
static vec3_t	shadevector;

static float	entalpha; //johnfitz

static qboolean overbright; //johnfitz

static qboolean shading = true; //johnfitz -- if false, disable vertex shading for various reasons (fullbright, r_lightmap, showtris, etc)

//johnfitz -- struct for passing lerp information to drawing functions
typedef struct {
	short pose1;
	short pose2;
	float blend;
	vec3_t origin;
	vec3_t angles;
} lerpdata_t;
//johnfitz

static GLuint r_alias_program;

// uniforms used in vert shader
static GLint  blendLoc;
static GLint  shadevectorLoc;
static GLint  lightColorLoc;

// uniforms used in frag shader
static GLint  texLoc;
static GLint  fullbrightTexLoc;
static GLint  useFullbrightTexLoc;
static GLint  useOverbrightLoc;
static GLint  useAlphaTestLoc;

#define pose1VertexAttrIndex 0
#define pose1NormalAttrIndex 1
#define pose2VertexAttrIndex 2
#define pose2NormalAttrIndex 3
#define texCoordsAttrIndex 4

/*
=============
GLARB_GetXYZOffset

Returns the offset of the first vertex's meshxyz_t.xyz in the vbo for the given
model and pose.
=============
*/
static void *GLARB_GetXYZOffset (aliashdr_t *hdr, int pose)
{
	const int xyzoffs = offsetof (meshxyz_t, xyz);
	return (void *) (currententity->model->vboxyzofs + (hdr->numverts_vbo * pose * sizeof (meshxyz_t)) + xyzoffs);
}

/*
=============
GLARB_GetNormalOffset

Returns the offset of the first vertex's meshxyz_t.normal in the vbo for the
given model and pose.
=============
*/
static void *GLARB_GetNormalOffset (aliashdr_t *hdr, int pose)
{
	const int normaloffs = offsetof (meshxyz_t, normal);
	return (void *)(currententity->model->vboxyzofs + (hdr->numverts_vbo * pose * sizeof (meshxyz_t)) + normaloffs);
}

/*
=============
GLAlias_CreateShaders
=============
*/
void GLAlias_CreateShaders (void)
{
	const glsl_attrib_binding_t bindings[] = {
		{ "TexCoords", texCoordsAttrIndex },
		{ "Pose1Vert", pose1VertexAttrIndex },
		{ "Pose1Normal", pose1NormalAttrIndex },
		{ "Pose2Vert", pose2VertexAttrIndex },
		{ "Pose2Normal", pose2NormalAttrIndex }
	};

	const GLchar *vertSource = \
		"#version 110\n"
		"\n"
		"uniform float Blend;\n"
		"uniform vec3 ShadeVector;\n"
		"uniform vec4 LightColor;\n"
		"attribute vec4 TexCoords; // only xy are used \n"
		"attribute vec4 Pose1Vert;\n"
		"attribute vec3 Pose1Normal;\n"
		"attribute vec4 Pose2Vert;\n"
		"attribute vec3 Pose2Normal;\n"
		"\n"
		"varying float FogFragCoord;\n"
		"\n"
		"float r_avertexnormal_dot(vec3 vertexnormal) // from MH \n"
		"{\n"
		"        float dot = dot(vertexnormal, ShadeVector);\n"
		"        // wtf - this reproduces anorm_dots within as reasonable a degree of tolerance as the >= 0 case\n"
		"        if (dot < 0.0)\n"
		"            return 1.0 + dot * (13.0 / 44.0);\n"
		"        else\n"
		"            return 1.0 + dot;\n"
		"}\n"
		"void main()\n"
		"{\n"
		"	gl_TexCoord[0] = TexCoords;\n"
		"	vec4 lerpedVert = mix(vec4(Pose1Vert.xyz, 1.0), vec4(Pose2Vert.xyz, 1.0), Blend);\n"
		"	gl_Position = gl_ModelViewProjectionMatrix * lerpedVert;\n"
		"	FogFragCoord = gl_Position.w;\n"
		"	float dot1 = r_avertexnormal_dot(Pose1Normal);\n"
		"	float dot2 = r_avertexnormal_dot(Pose2Normal);\n"
		"	gl_FrontColor = LightColor * vec4(vec3(mix(dot1, dot2, Blend)), 1.0);\n"
		"}\n";

	const GLchar *fragSource = \
		"#version 110\n"
		"\n"
		"uniform sampler2D Tex;\n"
		"uniform sampler2D FullbrightTex;\n"
		"uniform bool UseFullbrightTex;\n"
		"uniform bool UseOverbright;\n"
		"uniform bool UseAlphaTest;\n"
		"\n"
		"varying float FogFragCoord;\n"
		"\n"
		"void main()\n"
		"{\n"
		"	vec4 result = texture2D(Tex, gl_TexCoord[0].xy);\n"
		"	if (UseAlphaTest && (result.a < 0.666))\n"
		"		discard;\n"
		"	result *= gl_Color;\n"
		"	if (UseOverbright)\n"
		"		result.rgb *= 2.0;\n"
		"	if (UseFullbrightTex)\n"
		"		result += texture2D(FullbrightTex, gl_TexCoord[0].xy);\n"
		"	result = clamp(result, 0.0, 1.0);\n"
		"	float fog = exp(-gl_Fog.density * gl_Fog.density * FogFragCoord * FogFragCoord);\n"
		"	fog = clamp(fog, 0.0, 1.0);\n"
		"	result = mix(gl_Fog.color, result, fog);\n"
		"	result.a = gl_Color.a;\n" // FIXME: This will make almost transparent things cut holes though heavy fog
		"	gl_FragColor = result;\n"
		"}\n";

	if (!gl_glsl_alias_able)
		return;

	r_alias_program = GL_CreateProgram (vertSource, fragSource, Q_COUNTOF(bindings), bindings);

	if (r_alias_program != 0)
	{
	// get uniform locations
		blendLoc = GL_GetUniformLocation (&r_alias_program, "Blend");
		shadevectorLoc = GL_GetUniformLocation (&r_alias_program, "ShadeVector");
		lightColorLoc = GL_GetUniformLocation (&r_alias_program, "LightColor");
		texLoc = GL_GetUniformLocation (&r_alias_program, "Tex");
		fullbrightTexLoc = GL_GetUniformLocation (&r_alias_program, "FullbrightTex");
		useFullbrightTexLoc = GL_GetUniformLocation (&r_alias_program, "UseFullbrightTex");
		useOverbrightLoc = GL_GetUniformLocation (&r_alias_program, "UseOverbright");
		useAlphaTestLoc = GL_GetUniformLocation (&r_alias_program, "UseAlphaTest");
	}
}

/*
=============
GL_DrawAliasFrame_GLSL -- ericw

Optimized alias model drawing codepath.
Compared to the original GL_DrawAliasFrame, this makes 1 draw call,
no vertex data is uploaded (it's already in the r_meshvbo and r_meshindexesvbo
static VBOs), and lerping and lighting is done in the vertex shader.

Supports optional overbright, optional fullbright pixels.

Based on code by MH from RMQEngine
=============
*/
void GL_DrawAliasFrame_GLSL (aliashdr_t *paliashdr, lerpdata_t lerpdata, gltexture_t *tx, gltexture_t *fb)
{
	float	blend;

	if (lerpdata.pose1 != lerpdata.pose2)
	{
		blend = lerpdata.blend;
	}
	else // poses the same means either 1. the entity has paused its animation, or 2. r_lerpmodels is disabled
	{
		blend = 0;
	}

	GL_UseProgramFunc (r_alias_program);

	GL_BindBuffer (GL_ARRAY_BUFFER, currententity->model->meshvbo);
	GL_BindBuffer (GL_ELEMENT_ARRAY_BUFFER, currententity->model->meshindexesvbo);

	GL_EnableVertexAttribArrayFunc (texCoordsAttrIndex);
	GL_EnableVertexAttribArrayFunc (pose1VertexAttrIndex);
	GL_EnableVertexAttribArrayFunc (pose2VertexAttrIndex);
	GL_EnableVertexAttribArrayFunc (pose1NormalAttrIndex);
	GL_EnableVertexAttribArrayFunc (pose2NormalAttrIndex);

	GL_VertexAttribPointerFunc (texCoordsAttrIndex, 2, GL_FLOAT, GL_FALSE, 0, (void *)(intptr_t)currententity->model->vbostofs);
	GL_VertexAttribPointerFunc (pose1VertexAttrIndex, 4, GL_UNSIGNED_BYTE, GL_FALSE, sizeof (meshxyz_t), GLARB_GetXYZOffset (paliashdr, lerpdata.pose1));
	GL_VertexAttribPointerFunc (pose2VertexAttrIndex, 4, GL_UNSIGNED_BYTE, GL_FALSE, sizeof (meshxyz_t), GLARB_GetXYZOffset (paliashdr, lerpdata.pose2));
// GL_TRUE to normalize the signed bytes to [-1 .. 1]
	GL_VertexAttribPointerFunc (pose1NormalAttrIndex, 4, GL_BYTE, GL_TRUE, sizeof (meshxyz_t), GLARB_GetNormalOffset (paliashdr, lerpdata.pose1));
	GL_VertexAttribPointerFunc (pose2NormalAttrIndex, 4, GL_BYTE, GL_TRUE, sizeof (meshxyz_t), GLARB_GetNormalOffset (paliashdr, lerpdata.pose2));

// set uniforms
	GL_Uniform1fFunc (blendLoc, blend);
	GL_Uniform3fFunc (shadevectorLoc, shadevector[0], shadevector[1], shadevector[2]);
	GL_Uniform4fFunc (lightColorLoc, lightcolor[0], lightcolor[1], lightcolor[2], entalpha);
	GL_Uniform1iFunc (texLoc, 0);
	GL_Uniform1iFunc (fullbrightTexLoc, 1);
	GL_Uniform1iFunc (useFullbrightTexLoc, (fb != NULL) ? 1 : 0);
	GL_Uniform1fFunc (useOverbrightLoc, overbright);
	GL_Uniform1iFunc (useAlphaTestLoc, (currententity->model->flags & MF_HOLEY) ? 1 : 0);

// set textures
	GL_SelectTexture (GL_TEXTURE0);
	GL_Bind (tx);

	if (fb)
	{
		GL_SelectTexture (GL_TEXTURE1);
		GL_Bind (fb);
	}

// draw
	glDrawElements (GL_TRIANGLES, paliashdr->numindexes, GL_UNSIGNED_SHORT, (void *)(intptr_t)currententity->model->vboindexofs);

// clean up
	GL_DisableVertexAttribArrayFunc (texCoordsAttrIndex);
	GL_DisableVertexAttribArrayFunc (pose1VertexAttrIndex);
	GL_DisableVertexAttribArrayFunc (pose2VertexAttrIndex);
	GL_DisableVertexAttribArrayFunc (pose1NormalAttrIndex);
	GL_DisableVertexAttribArrayFunc (pose2NormalAttrIndex);

	GL_UseProgramFunc (0);
	GL_SelectTexture (GL_TEXTURE0);

	rs_aliaspasses += paliashdr->numtris;
}

/*
=============
GL_DrawAliasFrame -- johnfitz -- rewritten to support colored light, lerping, entalpha, multitexture, and r_drawflat

PPC port -- glDrawElements + scratch lerp, factored into Begin/Draw/End
helpers so a single CVA lock + lerp can span multiple draws of the same
vertex range (R_DrawAliasModel overbright case 3 pass 1+2).

Replaces the strip/fan walk over paliashdr->commands with a single
glDrawElements per pass, consuming the prebuilt index buffer that
GL_MakeAliasModelDisplayLists already builds for the GLSL path
(paliashdr->indexes, ->meshdesc, ->numindexes, ->numverts_vbo).

Texcoords are pose-invariant so we point straight at the aliasmesh_t
array's st[] field, no copy. Positions and shaded colors lerp into
static scratch sized to MAXALIASVERTS (loader-enforced cap).

The public GL_DrawAliasFrame() composes Begin+Draw+End for callers that
need a single self-contained pass (shadow, showtris, single-pass cases).
For the multi-draw case, callers invoke Begin once, Draw N times, End
once — see R_DrawAliasModel case 3.

Cheat caveat: r_drawflat_cheatsafe loses the per-substrip rainbow
(commands list is no longer walked). Substituted with one random color
per pass — debug visual drift acceptable.
=============
*/
// PPC port -- Phase 4.1: alias_pos_scratch is laid out 4 floats per
// vertex (xyz + 1 padding lane) so AltiVec's float4 vec_madd can do the
// lerp in one instruction per vert. The 4th lane is junk (consumer
// asks for size=3 with stride=16 in glVertexPointer). The 16-byte
// alignment lets vec_st store directly without the unaligned-store
// dance.
//
// Cost of pad-to-4: 8 KB extra static scratch (32 KB instead of 24 KB
// for MAXALIASVERTS=2000). Trivial vs the L2/L3 budget.
//
// On G3 builds (__ALTIVEC__ undefined per scripts/build.sh's CPUFLAGS)
// the lerp loop falls through to scalar code that writes the same
// padded layout. Stride update applies to both targets so the layout
// stays uniform; G3 just doesn't get the SIMD speedup.
static float alias_pos_scratch[MAXALIASVERTS * 4] __attribute__((aligned(16)));
static float alias_color_scratch[MAXALIASVERTS * 4] __attribute__((aligned(16)));

// Scope state captured at Begin so End cleans up symmetrically even if
// the caller has flipped a global between Begin and End. Not a cache —
// just the matching close-paren for an open-paren.
static qboolean alias_scope_had_color = false;
static qboolean alias_scope_had_mtex  = false;
static qboolean alias_scope_locked    = false;
static int      alias_scope_numverts  = 0;

// PPC port -- CVA lock only pays off when the same locked vertex range
// is consumed by MULTIPLE glDrawElements calls (driver caches transformed
// verts across draws). Per-call locking is pure overhead for single-pass
// uses, so we gate on this flag: single-pass call sites (the public
// composer) pass false; the explicit multipass scope in case 3 passes
// true.
static qboolean alias_scope_want_lock = false;

static void GL_AliasFrame_Begin (aliashdr_t *paliashdr, lerpdata_t lerpdata)
{
	trivertx_t		*verts1, *verts2;
	aliasmesh_t		*desc;
	meshst_t		*st;
	float			blend, iblend;
	qboolean		lerping;
	qboolean		want_color = (shading && !r_drawflat_cheatsafe);
	qboolean		want_mtex  = mtexenabled;
	int				i, n;

	n = paliashdr->numverts_vbo;

	// PPC port -- desc[].vertindex indexes into paliashdr->vertexes (the
	// raw original-order trivertx_t array, stride paliashdr->numverts per
	// pose) — NOT into paliashdr->posedata (which is BuildTris-reordered
	// for the GL command list with stride paliashdr->poseverts). Same
	// invariant the GLSL path relies on at gl_mesh.c:501.
	if (lerpdata.pose1 != lerpdata.pose2)
	{
		lerping = true;
		verts1  = (trivertx_t *)((byte *)paliashdr + paliashdr->vertexes);
		verts2  = verts1;
		verts1 += lerpdata.pose1 * paliashdr->numverts;
		verts2 += lerpdata.pose2 * paliashdr->numverts;
		blend  = lerpdata.blend;
		iblend = 1.0f - blend;
	}
	else
	{
		lerping = false;
		verts1  = (trivertx_t *)((byte *)paliashdr + paliashdr->vertexes);
		verts2  = verts1;
		verts1 += lerpdata.pose1 * paliashdr->numverts;
		blend = iblend = 0;
	}

	desc = (aliasmesh_t *)((byte *)paliashdr + paliashdr->meshdesc);
	st   = (meshst_t    *)((byte *)paliashdr + paliashdr->meshst);

	// --- lerp positions (and compute shaded colors when wanted) into scratch ---
	//
	// PPC port -- Phase 4.1: scratch is laid out 4 floats per vert
	// (xyz + 1 padding lane). The AltiVec branches use vec_madd to do
	// the lerp in one instruction per vertex; the byte→float work for
	// the trivertx_t inputs goes through gcc's (vector float){...}
	// constructor, which spills via memory but stays off the FP unit
	// so it can run in parallel with the math. On G3 builds
	// __ALTIVEC__ is undefined and the loop falls through to scalar
	// code that writes the same padded layout.
	//
	// Demo1 is brush-heavy so this won't move the needle on smoke
	// timedemo (only the viewmodel is alias). Demo3 (zombies, ogres)
	// is where we should see the +2-5% the plan predicts; full grid
	// at end-of-round captures it.
#ifdef __ALTIVEC__
	// vec_splats() landed in altivec.h around GCC 4.4; we ship on
	// Apple's gcc-4.0 (Lion's /usr/bin/gcc-4.0). Use the constructor
	// form, which gcc 4.0 supports as a vector extension. It compiles
	// to a stack temp + lvx -- not as tight as a true vec_splat but
	// hoisted out of the loop, so cost is amortised.
	const vector float vblend  = (vector float){blend,  blend,  blend,  blend};
	const vector float viblend = (vector float){iblend, iblend, iblend, iblend};
	const vector float vzero   = (vector float){0.0f, 0.0f, 0.0f, 0.0f};

	// PPC port -- Phase 4.6: fuse the per-vertex `s * lightcolor[*]`
	// scalar muls into one vec_madd. Layout is (R, G, B, alpha):
	//   color_v[k] = s * lightcolor[k] + entalpha_addend[k]
	// where entalpha_addend = (0, 0, 0, entalpha) puts entalpha into
	// the 4th lane while preserving s*lightcolor[0..2] in the first
	// three. Replaces 3 fmul + 4 fp store with 1 vec_madd + 1 vec_st
	// (and a vec_splat-style splat of `s` per iteration).
	const vector float vlightcolor   = (vector float){
		lightcolor[0], lightcolor[1], lightcolor[2], 0.0f
	};
	const vector float ventalpha_lane = (vector float){
		0.0f, 0.0f, 0.0f, entalpha
	};
#endif
	if (want_color)
	{
		if (lerping)
		{
			for (i = 0; i < n; i++)
			{
				int idx = desc[i].vertindex;
				float s = shadedots[verts1[idx].lightnormalindex] * iblend
				        + shadedots[verts2[idx].lightnormalindex] * blend;
#ifdef __ALTIVEC__
				vector float v1 = (vector float){
					(float)verts1[idx].v[0],
					(float)verts1[idx].v[1],
					(float)verts1[idx].v[2],
					0.0f
				};
				vector float v2 = (vector float){
					(float)verts2[idx].v[0],
					(float)verts2[idx].v[1],
					(float)verts2[idx].v[2],
					0.0f
				};
				vec_st(vec_madd(v1, viblend, vec_madd(v2, vblend, vzero)), 0, &alias_pos_scratch[i*4]);
#else
				alias_pos_scratch[i*4+0] = verts1[idx].v[0]*iblend + verts2[idx].v[0]*blend;
				alias_pos_scratch[i*4+1] = verts1[idx].v[1]*iblend + verts2[idx].v[1]*blend;
				alias_pos_scratch[i*4+2] = verts1[idx].v[2]*iblend + verts2[idx].v[2]*blend;
#endif
#ifdef __ALTIVEC__
				// PPC port -- Phase 4.6: fused color = s * lightcolor + entalpha-lane.
				{
					vector float vs = (vector float){s, s, s, s};
					vec_st(vec_madd(vs, vlightcolor, ventalpha_lane),
					       0, &alias_color_scratch[i*4]);
				}
#else
				alias_color_scratch[i*4+0] = s * lightcolor[0];
				alias_color_scratch[i*4+1] = s * lightcolor[1];
				alias_color_scratch[i*4+2] = s * lightcolor[2];
				alias_color_scratch[i*4+3] = entalpha;
#endif
			}
		}
		else
		{
			// Non-lerping: byte→float position copy can't usefully be
			// AltiVec'd (single byte per element, no math). The color
			// computation IS Phase 4.6-fusable (same shape as the
			// lerping branch), so we apply it here too. Demo3 alias
			// models always lerp, so this branch is a vanity case —
			// included for consistency.
			for (i = 0; i < n; i++)
			{
				int idx = desc[i].vertindex;
				float s = shadedots[verts1[idx].lightnormalindex];
				alias_pos_scratch[i*4+0] = verts1[idx].v[0];
				alias_pos_scratch[i*4+1] = verts1[idx].v[1];
				alias_pos_scratch[i*4+2] = verts1[idx].v[2];
#ifdef __ALTIVEC__
				{
					vector float vs = (vector float){s, s, s, s};
					vec_st(vec_madd(vs, vlightcolor, ventalpha_lane),
					       0, &alias_color_scratch[i*4]);
				}
#else
				alias_color_scratch[i*4+0] = s * lightcolor[0];
				alias_color_scratch[i*4+1] = s * lightcolor[1];
				alias_color_scratch[i*4+2] = s * lightcolor[2];
				alias_color_scratch[i*4+3] = entalpha;
#endif
			}
		}
	}
	else
	{
		if (lerping)
		{
			for (i = 0; i < n; i++)
			{
				int idx = desc[i].vertindex;
#ifdef __ALTIVEC__
				vector float v1 = (vector float){
					(float)verts1[idx].v[0],
					(float)verts1[idx].v[1],
					(float)verts1[idx].v[2],
					0.0f
				};
				vector float v2 = (vector float){
					(float)verts2[idx].v[0],
					(float)verts2[idx].v[1],
					(float)verts2[idx].v[2],
					0.0f
				};
				vec_st(vec_madd(v1, viblend, vec_madd(v2, vblend, vzero)), 0, &alias_pos_scratch[i*4]);
#else
				alias_pos_scratch[i*4+0] = verts1[idx].v[0]*iblend + verts2[idx].v[0]*blend;
				alias_pos_scratch[i*4+1] = verts1[idx].v[1]*iblend + verts2[idx].v[1]*blend;
				alias_pos_scratch[i*4+2] = verts1[idx].v[2]*iblend + verts2[idx].v[2]*blend;
#endif
			}
		}
		else
		{
			for (i = 0; i < n; i++)
			{
				int idx = desc[i].vertindex;
				alias_pos_scratch[i*4+0] = verts1[idx].v[0];
				alias_pos_scratch[i*4+1] = verts1[idx].v[1];
				alias_pos_scratch[i*4+2] = verts1[idx].v[2];
			}
		}
	}

	// --- bind streams + enable client states ---
	// PPC port -- Phase 4.1: stride is 4 floats (16 bytes), not 0
	// (tightly-packed 3-float). The 4th lane is padding; OpenGL only
	// reads xyz per the size=3 here.
	glVertexPointer (3, GL_FLOAT, 4*sizeof(float), alias_pos_scratch);
	glEnableClientState (GL_VERTEX_ARRAY);

	if (want_mtex)
	{
		GL_ClientActiveTextureFunc (GL_TEXTURE0_ARB);
		glTexCoordPointer (2, GL_FLOAT, 0, &st[0].st[0]);
		glEnableClientState (GL_TEXTURE_COORD_ARRAY);
		GL_ClientActiveTextureFunc (GL_TEXTURE1_ARB);
		glTexCoordPointer (2, GL_FLOAT, 0, &st[0].st[0]);
		glEnableClientState (GL_TEXTURE_COORD_ARRAY);
	}
	else
	{
		glTexCoordPointer (2, GL_FLOAT, 0, &st[0].st[0]);
		glEnableClientState (GL_TEXTURE_COORD_ARRAY);
	}

	if (want_color)
	{
		glColorPointer (4, GL_FLOAT, 0, alias_color_scratch);
		glEnableClientState (GL_COLOR_ARRAY);
	}

	// --- optional CVA lock so transformed verts cache across multipass.
	//     Only locks when the caller explicitly opts in via
	//     alias_scope_want_lock — single-call composer paths skip this. ---
	if (gl_cva_able && alias_scope_want_lock)
	{
		GL_LockArraysEXTFunc (0, n);
		alias_scope_locked = true;
	}
	else
		alias_scope_locked = false;

	alias_scope_had_color = want_color;
	alias_scope_had_mtex  = want_mtex;
	alias_scope_numverts  = n;
}

static void GL_AliasFrame_Draw (aliashdr_t *paliashdr)
{
	// drawflat cheat: re-roll color per draw (per-substrip walk is gone).
	if (shading && r_drawflat_cheatsafe)
	{
		srand((unsigned int)(uintptr_t)paliashdr ^ (unsigned int)(cl.time * 1000.0));
		glColor3f (rand()%256/255.0f, rand()%256/255.0f, rand()%256/255.0f);
	}

	glDrawElements (GL_TRIANGLES, paliashdr->numindexes, GL_UNSIGNED_SHORT,
	                (unsigned short *)((byte *)paliashdr + paliashdr->indexes));
	rs_aliaspasses += paliashdr->numtris;
}

static void GL_AliasFrame_End (void)
{
	if (alias_scope_locked)
	{
		GL_UnlockArraysEXTFunc ();
		alias_scope_locked = false;
	}

	if (alias_scope_had_color)
		glDisableClientState (GL_COLOR_ARRAY);

	if (alias_scope_had_mtex)
	{
		glDisableClientState (GL_TEXTURE_COORD_ARRAY);
		GL_ClientActiveTextureFunc (GL_TEXTURE0_ARB);
	}
	glDisableClientState (GL_TEXTURE_COORD_ARRAY);
	glDisableClientState (GL_VERTEX_ARRAY);
}

void GL_DrawAliasFrame (aliashdr_t *paliashdr, lerpdata_t lerpdata)
{
	alias_scope_want_lock = false;  // single-pass: lock would be pure overhead
	GL_AliasFrame_Begin (paliashdr, lerpdata);
	GL_AliasFrame_Draw  (paliashdr);
	GL_AliasFrame_End   ();
}

/*
=================
R_SetupAliasFrame -- johnfitz -- rewritten to support lerping
=================
*/
void R_SetupAliasFrame (aliashdr_t *paliashdr, int frame, lerpdata_t *lerpdata)
{
	entity_t		*e = currententity;
	int				posenum, numposes;

	if ((frame >= paliashdr->numframes) || (frame < 0))
	{
		Con_DPrintf ("R_AliasSetupFrame: no such frame %d for '%s'\n", frame, e->model->name);
		frame = 0;
	}

	posenum = paliashdr->frames[frame].firstpose;
	numposes = paliashdr->frames[frame].numposes;

	if (numposes > 1)
	{
		e->lerptime = paliashdr->frames[frame].interval;
		posenum += (int)(cl.time / e->lerptime) % numposes;
	}
	else
		e->lerptime = 0.1;

	if (e->lerpflags & LERP_RESETANIM) //kill any lerp in progress
	{
		e->lerpstart = 0;
		e->previouspose = posenum;
		e->currentpose = posenum;
		e->lerpflags -= LERP_RESETANIM;
	}
	else if (e->currentpose != posenum) // pose changed, start new lerp
	{
		if (e->lerpflags & LERP_RESETANIM2) //defer lerping one more time
		{
			e->lerpstart = 0;
			e->previouspose = posenum;
			e->currentpose = posenum;
			e->lerpflags -= LERP_RESETANIM2;
		}
		else
		{
			e->lerpstart = cl.time;
			e->previouspose = e->currentpose;
			e->currentpose = posenum;
		}
	}

	//set up values
	if (r_lerpmodels.value && !(e->model->flags & MOD_NOLERP && r_lerpmodels.value != 2))
	{
		if (e->lerpflags & LERP_FINISH && numposes == 1)
			lerpdata->blend = CLAMP (0.0f, (float)(cl.time - e->lerpstart) / (e->lerpfinish - e->lerpstart), 1.0f);
		else
			lerpdata->blend = CLAMP (0.0f, (float)(cl.time - e->lerpstart) / e->lerptime, 1.0f);
		if (lerpdata->blend == 1.0f)
			e->previouspose = e->currentpose;
		lerpdata->pose1 = e->previouspose;
		lerpdata->pose2 = e->currentpose;
	}
	else //don't lerp
	{
		lerpdata->blend = 1;
		lerpdata->pose1 = posenum;
		lerpdata->pose2 = posenum;
	}
}

/*
=================
R_SetupEntityTransform -- johnfitz -- set up transform part of lerpdata
=================
*/
void R_SetupEntityTransform (entity_t *e, lerpdata_t *lerpdata)
{
	float blend;
	vec3_t d;
	int i;

	// if LERP_RESETMOVE, kill any lerps in progress
	if (e->lerpflags & LERP_RESETMOVE)
	{
		e->movelerpstart = 0;
		VectorCopy (e->origin, e->previousorigin);
		VectorCopy (e->origin, e->currentorigin);
		VectorCopy (e->angles, e->previousangles);
		VectorCopy (e->angles, e->currentangles);
		e->lerpflags -= LERP_RESETMOVE;
	}
	else if (!VectorCompare (e->origin, e->currentorigin) || !VectorCompare (e->angles, e->currentangles)) // origin/angles changed, start new lerp
	{
		e->movelerpstart = cl.time;
		VectorCopy (e->currentorigin, e->previousorigin);
		VectorCopy (e->origin,  e->currentorigin);
		VectorCopy (e->currentangles, e->previousangles);
		VectorCopy (e->angles,  e->currentangles);
	}

	//set up values
	if (r_lerpmove.value && e != &cl.viewent && e->lerpflags & LERP_MOVESTEP)
	{
		if (e->lerpflags & LERP_FINISH)
			blend = CLAMP (0.0f, (float)(cl.time - e->movelerpstart) / (e->lerpfinish - e->movelerpstart), 1.0f);
		else
			blend = CLAMP (0.0f, (float)(cl.time - e->movelerpstart) / 0.1f, 1.0f);

		//translation
		VectorSubtract (e->currentorigin, e->previousorigin, d);
		lerpdata->origin[0] = e->previousorigin[0] + d[0] * blend;
		lerpdata->origin[1] = e->previousorigin[1] + d[1] * blend;
		lerpdata->origin[2] = e->previousorigin[2] + d[2] * blend;

		//rotation
		VectorSubtract (e->currentangles, e->previousangles, d);
		for (i = 0; i < 3; i++)
		{
			if (d[i] > 180)  d[i] -= 360;
			if (d[i] < -180) d[i] += 360;
		}
		lerpdata->angles[0] = e->previousangles[0] + d[0] * blend;
		lerpdata->angles[1] = e->previousangles[1] + d[1] * blend;
		lerpdata->angles[2] = e->previousangles[2] + d[2] * blend;
	}
	else //don't lerp
	{
		VectorCopy (e->origin, lerpdata->origin);
		VectorCopy (e->angles, lerpdata->angles);
	}
}

/*
=================
R_SetupAliasLighting -- johnfitz -- broken out from R_DrawAliasModel and rewritten
=================
*/
void R_SetupAliasLighting (entity_t	*e)
{
	vec3_t		dist;
	float		add;
	int			i;
	int		quantizedangle;
	float		radiansangle;

	// if the initial trace is completely black, try again from above
	// this helps with models whose origin is slightly below ground level
	// (e.g. some of the candles in the DOTM start map)
	if (!R_LightPoint (e->origin))
	{
		vec3_t lpos;
		VectorCopy (e->origin, lpos);
		lpos[2] += e->model->maxs[2] * 0.5f;
		R_LightPoint (lpos);
	}

	//add dlights
	for (i=0 ; i<MAX_DLIGHTS ; i++)
	{
		if (cl_dlights[i].die >= cl.time)
		{
			VectorSubtract (currententity->origin, cl_dlights[i].origin, dist);
			add = cl_dlights[i].radius - VectorLength(dist);
			if (add > 0)
				VectorMA (lightcolor, add, cl_dlights[i].color, lightcolor);
		}
	}

	// minimum light value on gun (24)
	if (e == &cl.viewent)
	{
		add = 72.0f - (lightcolor[0] + lightcolor[1] + lightcolor[2]);
		if (add > 0.0f)
		{
			lightcolor[0] += add / 3.0f;
			lightcolor[1] += add / 3.0f;
			lightcolor[2] += add / 3.0f;
		}
	}

	// minimum light value on players (8)
	if (currententity > cl_entities && currententity <= cl_entities + cl.maxclients)
	{
		add = 24.0f - (lightcolor[0] + lightcolor[1] + lightcolor[2]);
		if (add > 0.0f)
		{
			lightcolor[0] += add / 3.0f;
			lightcolor[1] += add / 3.0f;
			lightcolor[2] += add / 3.0f;
		}
	}

	// clamp lighting so it doesn't overbright as much (96)
	if (overbright)
	{
		add = 288.0f / (lightcolor[0] + lightcolor[1] + lightcolor[2]);
		if (add < 1.0f)
			VectorScale(lightcolor, add, lightcolor);
	}

	//hack up the brightness when fullbrights but no overbrights (256)
	if (gl_fullbrights.value && !gl_overbright_models.value)
		if (e->model->flags & MOD_FBRIGHTHACK)
		{
			lightcolor[0] = 256.0f;
			lightcolor[1] = 256.0f;
			lightcolor[2] = 256.0f;
		}

	quantizedangle = ((int)(e->angles[1] * (SHADEDOT_QUANT / 360.0))) & (SHADEDOT_QUANT - 1);

//ericw -- shadevector is passed to the shader to compute shadedots inside the
//shader, see GLAlias_CreateShaders()
	radiansangle = (quantizedangle / 16.0) * 2.0 * 3.14159;
	shadevector[0] = cos(-radiansangle);
	shadevector[1] = sin(-radiansangle);
	shadevector[2] = 1;
	VectorNormalize(shadevector);
//ericw --

	shadedots = r_avertexnormal_dots[quantizedangle];
	VectorScale (lightcolor, 1.0f / 200.0f, lightcolor);
}

/*
=================
R_DrawAliasModel -- johnfitz -- almost completely rewritten
=================
*/
void R_DrawAliasModel (entity_t *e)
{
	aliashdr_t	*paliashdr;
	int		anim, skinnum;
	gltexture_t	*tx, *fb;
	lerpdata_t	lerpdata;
	qboolean	alphatest = !!(e->model->flags & MF_HOLEY);
	float		fovscale = 1.0f;

	//
	// setup pose/lerp data -- do it first so we don't miss updates due to culling
	//
	paliashdr = (aliashdr_t *)Mod_Extradata (e->model);
	R_SetupAliasFrame (paliashdr, e->frame, &lerpdata);
	R_SetupEntityTransform (e, &lerpdata);

	//
	// cull it
	//
	if (R_CullModelForEntity(e))
		return;

	//
	// transform it
	//
	if (e == &cl.viewent && scr_fov.value > 90.f && cl_gun_fovscale.value)
		fovscale = tan(scr_fov.value * (0.5f * M_PI / 180.f));

	glPushMatrix ();
	R_RotateForEntity (lerpdata.origin, lerpdata.angles, e->scale);
	glTranslatef (paliashdr->scale_origin[0], paliashdr->scale_origin[1] * fovscale, paliashdr->scale_origin[2] * fovscale);
	glScalef (paliashdr->scale[0], paliashdr->scale[1] * fovscale, paliashdr->scale[2] * fovscale);

	//
	// random stuff
	//
	if (gl_smoothmodels.value && !r_drawflat_cheatsafe)
		glShadeModel (GL_SMOOTH);
	if (gl_affinemodels.value)
		glHint (GL_PERSPECTIVE_CORRECTION_HINT, GL_FASTEST);
	overbright = !!gl_overbright_models.value;
	shading = true;

	//
	// set up for alpha blending
	//
	if (r_drawflat_cheatsafe || r_lightmap_cheatsafe) //no alpha in drawflat or lightmap mode
		entalpha = 1;
	else
		entalpha = ENTALPHA_DECODE(e->alpha);
	if (entalpha == 0)
		goto cleanup;
	if (entalpha < 1)
	{
		if (!gl_texture_env_combine) overbright = false; //overbright can't be done in a single pass without combiners
		glDepthMask(GL_FALSE);
		glEnable(GL_BLEND);
	}
	else if (alphatest)
		glEnable (GL_ALPHA_TEST);

	//
	// set up lighting
	//
	rs_aliaspolys += paliashdr->numtris;
	R_SetupAliasLighting (e);

	//
	// set up textures
	//
	GL_DisableMultitexture();
	anim = (int)(cl.time*10) & 3;
	skinnum = e->skinnum;
	if ((skinnum >= paliashdr->numskins) || (skinnum < 0))
	{
		Con_DPrintf ("R_DrawAliasModel: no such skin # %d for '%s'\n", skinnum, e->model->name);
		// ericw -- display skin 0 for winquake compatibility
		skinnum = 0;
	}
	tx = paliashdr->gltextures[skinnum][anim];
	fb = paliashdr->fbtextures[skinnum][anim];
	if (e->colormap != vid.colormap && !gl_nocolors.value)
	{
		if ((uintptr_t)e >= (uintptr_t)&cl_entities[1] && (uintptr_t)e <= (uintptr_t)&cl_entities[cl.maxclients]) /* && !strcmp (currententity->model->name, "progs/player.mdl") */
			tx = playertextures[e - cl_entities - 1];
	}
	if (!gl_fullbrights.value)
		fb = NULL;

	//
	// draw it
	//
	if (r_drawflat_cheatsafe)
	{
		glDisable (GL_TEXTURE_2D);
		GL_DrawAliasFrame (paliashdr, lerpdata);
		glEnable (GL_TEXTURE_2D);
		srand((int) (cl.time * 1000)); //restore randomness
	}
	else if (r_fullbright_cheatsafe)
	{
		GL_Bind (tx);
		shading = false;
		glColor4f(1,1,1,entalpha);
		GL_DrawAliasFrame (paliashdr, lerpdata);
		if (fb)
		{
			glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE);
			GL_Bind(fb);
			glEnable(GL_BLEND);
			glBlendFunc (GL_ONE, GL_ONE);
			glDepthMask(GL_FALSE);
			glColor3f(entalpha,entalpha,entalpha);
			Fog_StartAdditive ();
			GL_DrawAliasFrame (paliashdr, lerpdata);
			Fog_StopAdditive ();
			glDepthMask(GL_TRUE);
			glBlendFunc (GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
			glDisable(GL_BLEND);
		}
	}
	else if (r_lightmap_cheatsafe)
	{
		glDisable (GL_TEXTURE_2D);
		shading = false;
		glColor3f(1,1,1);
		GL_DrawAliasFrame (paliashdr, lerpdata);
		glEnable (GL_TEXTURE_2D);
	}
// call fast path if possible. if the shader compliation failed for some reason,
// r_alias_program will be 0.
	else if (r_alias_program != 0)
	{
		GL_DrawAliasFrame_GLSL (paliashdr, lerpdata, tx, fb);
	}
	else if (overbright)
	{
		if  (gl_texture_env_combine && gl_mtexable && gl_texture_env_add && fb) //case 1: everything in one pass
		{
			GL_Bind (tx);
			glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_COMBINE_EXT);
			glTexEnvi(GL_TEXTURE_ENV, GL_COMBINE_RGB_EXT, GL_MODULATE);
			glTexEnvi(GL_TEXTURE_ENV, GL_SOURCE0_RGB_EXT, GL_TEXTURE);
			glTexEnvi(GL_TEXTURE_ENV, GL_SOURCE1_RGB_EXT, GL_PRIMARY_COLOR_EXT);
			glTexEnvf(GL_TEXTURE_ENV, GL_RGB_SCALE_EXT, 2.0f);
			GL_EnableMultitexture(); // selects TEXTURE1
			GL_Bind (fb);
			glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_ADD);
			glEnable(GL_BLEND);
			GL_DrawAliasFrame (paliashdr, lerpdata);
			glDisable(GL_BLEND);
			GL_DisableMultitexture();
			glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);
		}
		else if (gl_texture_env_combine) //case 2: overbright in one pass, then fullbright pass
		{
		// first pass
			GL_Bind(tx);
			glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_COMBINE_EXT);
			glTexEnvi(GL_TEXTURE_ENV, GL_COMBINE_RGB_EXT, GL_MODULATE);
			glTexEnvi(GL_TEXTURE_ENV, GL_SOURCE0_RGB_EXT, GL_TEXTURE);
			glTexEnvi(GL_TEXTURE_ENV, GL_SOURCE1_RGB_EXT, GL_PRIMARY_COLOR_EXT);
			glTexEnvf(GL_TEXTURE_ENV, GL_RGB_SCALE_EXT, 2.0f);
			GL_DrawAliasFrame (paliashdr, lerpdata);
			glTexEnvf(GL_TEXTURE_ENV, GL_RGB_SCALE_EXT, 1.0f);
			glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);
		// second pass
			if (fb)
			{
				glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE);
				GL_Bind(fb);
				glEnable(GL_BLEND);
				glBlendFunc (GL_ONE, GL_ONE);
				glDepthMask(GL_FALSE);
				shading = false;
				glColor3f(entalpha,entalpha,entalpha);
				Fog_StartAdditive ();
				GL_DrawAliasFrame (paliashdr, lerpdata);
				Fog_StopAdditive ();
				glDepthMask(GL_TRUE);
				glBlendFunc (GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
				glDisable(GL_BLEND);
				glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);
			}
		}
		else //case 3: overbright in two passes, then fullbright pass
		{
		// PPC port -- pass 1+2 share lerp + arrays + shading=true. Wrap them
		// in one Begin/End scope so the lerp runs once and (when CVA is
		// available) the lock spans both glDrawElements calls — driver
		// transform-cache hit on pass 2. This is the single multi-draw CVA
		// opportunity in the engine.
		// first pass
			GL_Bind(tx);
			glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE);
			alias_scope_want_lock = true;  // case 3 pass 1+2 share the lock
			GL_AliasFrame_Begin (paliashdr, lerpdata);
			GL_AliasFrame_Draw  (paliashdr);
		// second pass -- additive with black fog, to double the object colors but not the fog color
			glEnable(GL_BLEND);
			glBlendFunc (GL_ONE, GL_ONE);
			glDepthMask(GL_FALSE);
			Fog_StartAdditive ();
			GL_AliasFrame_Draw  (paliashdr);
			Fog_StopAdditive ();
			GL_AliasFrame_End   ();
			glDepthMask(GL_TRUE);
			glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);
			glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
			glDisable(GL_BLEND);
		// third pass
			if (fb)
			{
				glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE);
				GL_Bind(fb);
				glEnable(GL_BLEND);
				glBlendFunc (GL_ONE, GL_ONE);
				glDepthMask(GL_FALSE);
				shading = false;
				glColor3f(entalpha,entalpha,entalpha);
				Fog_StartAdditive ();
				GL_DrawAliasFrame (paliashdr, lerpdata);
				Fog_StopAdditive ();
				glDepthMask(GL_TRUE);
				glBlendFunc (GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
				glDisable(GL_BLEND);
				glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);
			}
		}
	}
	else
	{
		if (gl_mtexable && gl_texture_env_add && fb) //case 4: fullbright mask using multitexture
		{
			GL_DisableMultitexture(); // selects TEXTURE0
			GL_Bind (tx);
			glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE);
			GL_EnableMultitexture(); // selects TEXTURE1
			GL_Bind (fb);
			glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_ADD);
			glEnable(GL_BLEND);
			GL_DrawAliasFrame (paliashdr, lerpdata);
			glDisable(GL_BLEND);
			GL_DisableMultitexture();
			glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);
		}
		else //case 5: fullbright mask without multitexture
		{
		// first pass
			GL_Bind(tx);
			glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE);
			GL_DrawAliasFrame (paliashdr, lerpdata);
		// second pass
			if (fb)
			{
				GL_Bind(fb);
				glEnable(GL_BLEND);
				glBlendFunc (GL_ONE, GL_ONE);
				glDepthMask(GL_FALSE);
				shading = false;
				glColor3f(entalpha,entalpha,entalpha);
				Fog_StartAdditive ();
				GL_DrawAliasFrame (paliashdr, lerpdata);
				Fog_StopAdditive ();
				glDepthMask(GL_TRUE);
				glBlendFunc (GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
				glDisable(GL_BLEND);
			}
		}
	}

cleanup:
	glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);
	glHint (GL_PERSPECTIVE_CORRECTION_HINT, GL_NICEST);
	glShadeModel (GL_FLAT);
	glDepthMask(GL_TRUE);
	glDisable(GL_BLEND);
	if (alphatest)
		glDisable (GL_ALPHA_TEST);
	glColor3f(1,1,1);
	glPopMatrix ();
}

//johnfitz -- values for shadow matrix
#define SHADOW_SKEW_X -0.7 //skew along x axis. -0.7 to mimic glquake shadows
#define SHADOW_SKEW_Y 0 //skew along y axis. 0 to mimic glquake shadows
#define SHADOW_VSCALE 0 //0=completely flat
#define SHADOW_HEIGHT 0.1 //how far above the floor to render the shadow
//johnfitz

/*
=============
GL_DrawAliasShadow -- johnfitz -- rewritten

TODO: orient shadow onto "lightplane" (a global mplane_t*)
=============
*/
void GL_DrawAliasShadow (entity_t *e)
{
	float	shadowmatrix[16] = {1,				0,				0,				0,
								0,				1,				0,				0,
								SHADOW_SKEW_X,	SHADOW_SKEW_Y,	SHADOW_VSCALE,	0,
								0,				0,				SHADOW_HEIGHT,	1};
	float		lheight;
	aliashdr_t	*paliashdr;
	lerpdata_t	lerpdata;

	if (R_CullModelForEntity(e))
		return;

	if (e == &cl.viewent || e->model->flags & MOD_NOSHADOW)
		return;

	entalpha = ENTALPHA_DECODE(e->alpha);
	if (entalpha == 0) return;

	paliashdr = (aliashdr_t *)Mod_Extradata (e->model);
	R_SetupAliasFrame (paliashdr, e->frame, &lerpdata);
	R_SetupEntityTransform (e, &lerpdata);
	R_LightPoint (e->origin);
	lheight = currententity->origin[2] - lightspot[2];

// set up matrix
	glPushMatrix ();
	glTranslatef (lerpdata.origin[0],  lerpdata.origin[1],  lerpdata.origin[2]);
	glTranslatef (0,0,-lheight);
	glMultMatrixf (shadowmatrix);
	glTranslatef (0,0,lheight);
	glRotatef (lerpdata.angles[1],  0, 0, 1);
	glRotatef (-lerpdata.angles[0],  0, 1, 0);
	glRotatef (lerpdata.angles[2],  1, 0, 0);
	glTranslatef (paliashdr->scale_origin[0], paliashdr->scale_origin[1], paliashdr->scale_origin[2]);
	glScalef (paliashdr->scale[0], paliashdr->scale[1], paliashdr->scale[2]);

// draw it
	glDepthMask(GL_FALSE);
	glEnable (GL_BLEND);
	GL_DisableMultitexture ();
	glDisable (GL_TEXTURE_2D);
	shading = false;
	glColor4f(0,0,0,entalpha * 0.5);
	GL_DrawAliasFrame (paliashdr, lerpdata);
	glEnable (GL_TEXTURE_2D);
	glDisable (GL_BLEND);
	glDepthMask(GL_TRUE);

//clean up
	glPopMatrix ();
}

/*
=================
R_DrawAliasModel_ShowTris -- johnfitz
=================
*/
void R_DrawAliasModel_ShowTris (entity_t *e)
{
	aliashdr_t	*paliashdr;
	lerpdata_t	lerpdata;
	float	fovscale = 1.0f;

	if (R_CullModelForEntity(e))
		return;

	paliashdr = (aliashdr_t *)Mod_Extradata (e->model);
	R_SetupAliasFrame (paliashdr, e->frame, &lerpdata);
	R_SetupEntityTransform (e, &lerpdata);

	if (e == &cl.viewent && scr_fov.value > 90.f && cl_gun_fovscale.value)
		fovscale = tan(scr_fov.value * (0.5f * M_PI / 180.f));

	glPushMatrix ();
	R_RotateForEntity (lerpdata.origin,lerpdata.angles, e->scale);
	glTranslatef (paliashdr->scale_origin[0], paliashdr->scale_origin[1] * fovscale, paliashdr->scale_origin[2] * fovscale);
	glScalef (paliashdr->scale[0], paliashdr->scale[1] * fovscale, paliashdr->scale[2] * fovscale);

	shading = false;
	glColor3f(1,1,1);
	GL_DrawAliasFrame (paliashdr, lerpdata);

	glPopMatrix ();
}
