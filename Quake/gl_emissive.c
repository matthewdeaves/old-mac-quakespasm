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

// gl_emissive.c -- PPC port (Round v7 phase 2): emissive-fullbright dynamic lights
//
// Surfaces whose textures carry emissive (fullbright) pixels — buttons,
// computer panels, light fixtures — should cast coloured dynamic light
// onto surrounding geometry, the way muzzle flashes and rocket trails
// already do.
//
// At map load (R_BuildEmissiveLights, called from R_NewMap), we walk
// every world brush surface whose texinfo->texture->fullbright is
// non-null, compute the surface centroid (offset 4 units along the
// surface normal so the light sits in front of the wall, not embedded
// in it), pick a representative colour from the texture name, and pick
// a radius proportional to surface extent. Cap at MAX_EMISSIVE_SEEDS
// (128) — large enough to capture every button/light in a typical id1
// map; brightest seeds win at the cap.
//
// Per frame (R_PushEmissiveLights, called from R_PushDlights head),
// iterate active seeds, apply r_dynamic_distance gating (same gate
// muzzle/rocket dlights use on G3), and inject up to
// r_emissive_lights_max into the cl_dlights[] pool by calling
// CL_AllocDlight. The existing dlight pipeline (R_MarkLights →
// R_AddDynamicLights → lightmap reblend) handles them transparently
// from here. Setting die = cl.time + 0.1f means each emissive light
// dies before next frame, making room for the next-frame inject.
//
// Toggleability: r_emissive_lights cvar (default 0 — opt-in via
// console or per-machine autoexec). r_emissive_lights_radius scales
// the per-light radius (default 1.0 = use computed value).
// r_emissive_lights_max caps simultaneously injected count
// (default 16 — fits comfortably alongside the muzzle-flash budget
// in the 64-slot cl_dlights array).
//
// G3 cost reasoning: R128 has no fragment-shader dlight path, so each
// active emissive light = a full extra blending pass over every
// surface its sphere touches (the same regime that drove
// r_dynamic_distance 768). Tight per-light radius + low max count +
// distance gating contain the cost. Honest expectation: 5-15% fps
// drop on dlight-heavy demos. The cvar OFF default means no impact
// unless the user opts in.

#include "quakedef.h"

cvar_t r_emissive_lights        = {"r_emissive_lights",        "0",   CVAR_ARCHIVE};
cvar_t r_emissive_lights_radius = {"r_emissive_lights_radius", "1.0", CVAR_ARCHIVE};
cvar_t r_emissive_lights_max    = {"r_emissive_lights_max",    "16",  CVAR_ARCHIVE};

#define MAX_EMISSIVE_SEEDS 128

typedef struct
{
	vec3_t      origin;
	vec3_t      color;
	float       radius;
	msurface_t *src_surf;   // reserved for v2 (animation modulation)
} r_emissive_seed_t;

static r_emissive_seed_t r_emissive_seeds[MAX_EMISSIVE_SEEDS];
static int               r_num_emissive_seeds = 0;

void R_EmissiveLights_Init (void)
{
	Cvar_RegisterVariable (&r_emissive_lights);
	Cvar_RegisterVariable (&r_emissive_lights_radius);
	Cvar_RegisterVariable (&r_emissive_lights_max);
}

/*
================
R_PickEmissiveColor

Heuristic colour from texture name. Returns 1 if the name matches a
known emissive category (light / button / comp-tech-panel-screen),
0 otherwise. Avoids reading the fullbright gltexture's pixel data
(which lives behind the GL driver post-upload). Doesn't try to be
perfect — id1's emissive texture set is small (maybe a dozen distinct
names) and a short name-match table covers the common cases without
per-map authoring.

Why the explicit return value (Round v7 review B2): Mod_CheckFullbrights
flags ANY texture with even one fullbright pixel, and most id1 wall
textures (wbrick*, wmet*, etc.) carry trim pixels in that range. Without
a name-table filter the seed array fills with walls before the first
real button/light is seen. We only seed surfaces whose texture name
clearly belongs to an emissive category.
================
*/
static int R_PickEmissiveColor (const char *name, vec3_t out)
{
	// default warm white (used when caller wants a colour even without match)
	out[0] = 1.0f; out[1] = 0.9f; out[2] = 0.7f;

	if (!name) return 0;

	// case-sensitive substring match. Quake texture names are 16-char
	// max and lowercase by convention.
	if (strstr (name, "light") || strstr (name, "lite"))
	{
		// fluorescent / incandescent — warm yellow-white
		out[0] = 1.0f; out[1] = 0.95f; out[2] = 0.65f;
		return 1;
	}
	if (strstr (name, "button") || strstr (name, "btn"))
	{
		// red/orange button glow — covers '+0button', 'button1', etc.
		out[0] = 1.0f; out[1] = 0.45f; out[2] = 0.15f;
		return 1;
	}
	if (strstr (name, "comp") || strstr (name, "tech")
	 || strstr (name, "panel") || strstr (name, "screen"))
	{
		// cool computer-panel cyan
		out[0] = 0.45f; out[1] = 0.85f; out[2] = 1.0f;
		return 1;
	}

	return 0;  // not an emissive category — caller should skip
}

/*
================
R_BuildEmissiveLights

Called from R_NewMap. Walks the world brush model's surfaces,
collects up to MAX_EMISSIVE_SEEDS emissive seeds, stores them as
load-time-fixed (origin / color / radius / src_surf).

Skips sky and water/lava/slime/tele turbulent surfaces — they have
fullbright pixels but flood the seed budget and produce visually wrong
"glowing pool" effects. Buttons + light fixtures + computer panels
only.
================
*/
void R_BuildEmissiveLights (qmodel_t *world)
{
	int          i, j, k;
	msurface_t  *surf;
	glpoly_t    *p;
	vec3_t       centroid;
	float        area, radius;
	float        normal_sign;
	const char  *texname;

	r_num_emissive_seeds = 0;

	if (!world) return;
	if (!world->surfaces) return;

	for (i = 0; i < world->numsurfaces; i++)
	{
		vec3_t color;

		if (r_num_emissive_seeds >= MAX_EMISSIVE_SEEDS)
			break;

		surf = &world->surfaces[i];

		if (!surf->texinfo || !surf->texinfo->texture) continue;
		if (!surf->texinfo->texture->fullbright)       continue;
		if (surf->flags & (SURF_DRAWSKY | SURF_DRAWTURB)) continue;
		if (!surf->polys || surf->polys->numverts < 3) continue;
		if (!surf->plane) continue;  // defensive: empty surface

		// Round v7 review B2: pre-filter to surfaces whose texture name
		// matches a known emissive category. Without this, id1 wall
		// textures with stray fullbright trim pixels (wbrick*, wmet*)
		// pass the Mod_CheckFullbrights gate and crowd out real
		// buttons/lights at the MAX_EMISSIVE_SEEDS cap.
		texname = surf->texinfo->texture->name;
		if (!R_PickEmissiveColor (texname, color))
			continue;

		// centroid of master poly's verts
		p = surf->polys;
		centroid[0] = centroid[1] = centroid[2] = 0.0f;
		for (j = 0; j < p->numverts; j++)
		{
			for (k = 0; k < 3; k++)
				centroid[k] += p->verts[j][k];
		}
		centroid[0] /= (float)p->numverts;
		centroid[1] /= (float)p->numverts;
		centroid[2] /= (float)p->numverts;

		// offset 4 units along surface-facing normal so the light is
		// in front of the wall, not embedded.
		normal_sign = (surf->flags & SURF_PLANEBACK) ? -4.0f : 4.0f;
		for (k = 0; k < 3; k++)
			centroid[k] += surf->plane->normal[k] * normal_sign;

		// radius proportional to surface extent. Bound 48..192 so a
		// huge emissive surface doesn't dominate the room and a tiny
		// blip still casts visible light.
		area = (float)((surf->extents[0] + 16) * (surf->extents[1] + 16));
		radius = sqrtf (area) * 1.4f;
		if (radius < 48.0f)  radius = 48.0f;
		if (radius > 192.0f) radius = 192.0f;

		// store seed (color was already populated by the matched
		// R_PickEmissiveColor call above)
		VectorCopy (centroid, r_emissive_seeds[r_num_emissive_seeds].origin);
		VectorCopy (color,    r_emissive_seeds[r_num_emissive_seeds].color);
		r_emissive_seeds[r_num_emissive_seeds].radius   = radius;
		r_emissive_seeds[r_num_emissive_seeds].src_surf = surf;
		r_num_emissive_seeds++;
	}

	Con_DPrintf ("R_BuildEmissiveLights: %d seeds for %s\n",
	             r_num_emissive_seeds, world->name);
}

/*
================
R_PushEmissiveLights

Called at the head of R_PushDlights, before the cl_dlights[] sweep.
Iterates seeds, distance-gates against r_origin via r_dynamic_distance
(squared compare), and injects up to r_emissive_lights_max active
seeds into cl_dlights via CL_AllocDlight. die = cl.time + 0.1f means
each injected light survives one frame and is reaped by the next-frame
inject — no zombie state to clean up.

Cheap: O(r_num_emissive_seeds) distance compares + up to N
CL_AllocDlight calls per frame. Each AllocDlight is a linear scan of
cl_dlights[] but MAX_DLIGHTS is 64.
================
*/
void R_PushEmissiveLights (void)
{
	int       i, max_active;
	dlight_t *dl;
	float     md, d2;
	vec3_t    diff;
	float     scale;

	if (r_emissive_lights.value <= 0.0f) return;
	if (r_num_emissive_seeds == 0)       return;

	max_active = (int)r_emissive_lights_max.value;
	if (max_active <= 0) return;
	// Round v7 review (recommendation 1): leave 8 slots of headroom in
	// cl_dlights[64] for muzzle/rocket/gib lights even when the user
	// raises r_emissive_lights_max well past the budget. Belt-and-
	// braces over the die=0.001s fix.
	if (max_active > MAX_DLIGHTS - 8) max_active = MAX_DLIGHTS - 8;

	scale = r_emissive_lights_radius.value;
	if (scale < 0.05f) scale = 0.05f;
	if (scale > 4.0f)  scale = 4.0f;

	md = r_dynamic_distance.value;

	for (i = 0; i < r_num_emissive_seeds && max_active > 0; i++)
	{
		// distance gate (squared compare). 0 = unlimited.
		if (md > 0.0f)
		{
			VectorSubtract (r_emissive_seeds[i].origin, r_origin, diff);
			d2 = DotProduct (diff, diff);
			if (d2 > md * md)
				continue;
		}

		// allocate a fresh cl_dlights slot. key=0 means no cross-frame
		// carryover; CL_AllocDlight returns first dead slot (or oldest
		// if all are alive).
		dl = CL_AllocDlight (0);
		VectorCopy (r_emissive_seeds[i].origin, dl->origin);
		VectorCopy (r_emissive_seeds[i].color,  dl->color);
		dl->radius   = r_emissive_seeds[i].radius * scale;
		// Round v7 review B1: BRIGHTLIGHT/DIMLIGHT-style "expires before
		// next frame" idiom. 0.1s would leave ~6 living slots/seed at
		// 60 fps, saturating MAX_DLIGHTS=64 and stomping cl_dlights[0]
		// (the player muzzle-flash slot). 0.001s ensures the slot is
		// dead before R_PushDlights runs again next frame.
		dl->die      = cl.time + 0.001f;
		dl->minlight = 0.0f;
		dl->decay    = 0.0f;

		max_active--;
	}
}
