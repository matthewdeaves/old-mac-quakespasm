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
	if (strstr (name, "button") || strstr (name, "btn")
	 || strstr (name, "basebut") || strstr (name, "switch"))
	{
		// red/orange button/switch glow — covers '+0button', 'button1',
		// 'basebutn3' (id1 base set), 'switch_1', etc. Round v7 phase 7
		// added 'basebut' + 'switch' after diagnostic dump from e1m1
		// showed both being skipped by the original 'btn'-only filter.
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
	if (strstr (name, "exit"))
	{
		// emissive exit signage (e.g. 'z_exit') — green like a fire-exit
		// sign, brighter than ambient room lighting so it reads as a
		// directional cue.
		out[0] = 0.25f; out[1] = 1.0f; out[2] = 0.35f;
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

	Con_Printf ("R_BuildEmissiveLights: %d seeds for %s\n",
	             r_num_emissive_seeds, world->name);

	// Round v7 phase 2 diagnostic: when r_emissive_lights is on, print
	// every seeded texture so the user can tell why a particular button
	// or light isn't being picked up by the name-table heuristic. id1
	// texture naming is inconsistent (e.g. lift buttons can land on
	// `_button1` / `metalbrick` / `bigwheel` etc. — not all of which
	// match the light/button/comp/tech/panel/screen filter). Listing
	// seeded names + skipped fullbright names makes the gap visible.
	if (r_emissive_lights.value > 0.0f)
	{
		int seen[MAX_EMISSIVE_SEEDS];
		int n_unique = 0;
		int j2;
		Con_Printf ("R_BuildEmissiveLights seed textures: ");
		for (i = 0; i < r_num_emissive_seeds; i++)
		{
			qboolean dup = false;
			for (j2 = 0; j2 < n_unique; j2++)
			{
				if (r_emissive_seeds[seen[j2]].src_surf->texinfo->texture
				 == r_emissive_seeds[i].src_surf->texinfo->texture)
				{
					dup = true;
					break;
				}
			}
			if (!dup && n_unique < MAX_EMISSIVE_SEEDS)
			{
				seen[n_unique++] = i;
				Con_Printf ("%s ", r_emissive_seeds[i].src_surf->texinfo->texture->name);
			}
		}
		Con_Printf ("\n");

		// Also list fullbright textures that were SKIPPED by the
		// R_PickEmissiveColor name-filter — these are candidates for
		// adding to the heuristic if the user wants them lit.
		Con_Printf ("R_BuildEmissiveLights skipped (fullbright but unmatched): ");
		{
			int skipped_unique[256];
			int n_skipped = 0;
			vec3_t throwaway;
			for (i = 0; i < world->numsurfaces && n_skipped < 256; i++)
			{
				msurface_t *s = &world->surfaces[i];
				qboolean dup = false;
				int k;
				if (!s->texinfo || !s->texinfo->texture) continue;
				if (!s->texinfo->texture->fullbright)    continue;
				if (s->flags & (SURF_DRAWSKY | SURF_DRAWTURB)) continue;
				if (R_PickEmissiveColor (s->texinfo->texture->name, throwaway))
					continue;  // matched, already seeded
				for (k = 0; k < n_skipped; k++)
				{
					if (skipped_unique[k] >= 0
					 && world->surfaces[skipped_unique[k]].texinfo->texture
					 == s->texinfo->texture)
					{
						dup = true; break;
					}
				}
				if (!dup)
				{
					skipped_unique[n_skipped++] = i;
					Con_Printf ("%s ", s->texinfo->texture->name);
				}
			}
		}
		Con_Printf ("\n");
	}
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
/*
================
R_PushEmissiveLights

Pick the N nearest emissive seeds to r_origin and inject them into
cl_dlights[]. Round v7 phase 7 changed selection from FIFO (first N
that pass the distance gate) to nearest-N — without this fix, on
maps that hit MAX_EMISSIVE_SEEDS (128) like e1m1, the lift button
right in front of the player could be evicted from the per-frame
budget by an arbitrary distant light that happened to sort earlier
in the seed array.

Cost: O(N_seeds * max_active) for the partial-sort top-N walk.
With N_seeds = 128 and max_active = 12 (quicksilver), that's 1536
float compares per frame — sub-millisecond on every target. Cheaper
than a full qsort and avoids dynamic allocation.
================
*/
void R_PushEmissiveLights (void)
{
	int       i, j, max_active, n_picked;
	dlight_t *dl;
	float     md, d2, max_d2;
	vec3_t    diff;
	float     scale;

	// Top-N working set: parallel arrays of seed-index + distance².
	// Sized to the 56-slot upper bound from the MAX_DLIGHTS-8 clamp.
	int       picked_idx[MAX_DLIGHTS - 8];
	float     picked_d2 [MAX_DLIGHTS - 8];

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

	// First pass: collect up to max_active nearest seeds (insertion-sort
	// into the picked[] array, replacing the farthest current pick when
	// a closer seed is found). Distance gate also enforced here.
	n_picked = 0;
	max_d2 = 0.0f;       // current largest d² in picked[]; only valid when n_picked == max_active
	(void) max_d2;       // unused on first fill; touched below

	for (i = 0; i < r_num_emissive_seeds; i++)
	{
		VectorSubtract (r_emissive_seeds[i].origin, r_origin, diff);
		d2 = DotProduct (diff, diff);

		// Distance gate (squared compare). 0 = unlimited.
		if (md > 0.0f && d2 > md * md)
			continue;

		if (n_picked < max_active)
		{
			// Still filling — append, then re-find the new max.
			picked_idx[n_picked] = i;
			picked_d2 [n_picked] = d2;
			n_picked++;
			if (n_picked == max_active)
			{
				// Compute initial max_d2 once budget is full.
				max_d2 = picked_d2[0];
				for (j = 1; j < n_picked; j++)
					if (picked_d2[j] > max_d2) max_d2 = picked_d2[j];
			}
		}
		else if (d2 < max_d2)
		{
			// Budget full — evict the farthest entry, replace with this
			// closer seed, then re-scan to update max_d2.
			int evict = 0;
			float new_max = 0.0f;
			for (j = 1; j < n_picked; j++)
				if (picked_d2[j] > picked_d2[evict]) evict = j;
			picked_idx[evict] = i;
			picked_d2 [evict] = d2;
			for (j = 0; j < n_picked; j++)
				if (picked_d2[j] > new_max) new_max = picked_d2[j];
			max_d2 = new_max;
		}
	}

	// Second pass: inject the picked seeds into cl_dlights[].
	for (i = 0; i < n_picked; i++)
	{
		int s = picked_idx[i];
		// allocate a fresh cl_dlights slot. key=0 means no cross-frame
		// carryover; CL_AllocDlight returns first dead slot (or oldest
		// if all are alive).
		dl = CL_AllocDlight (0);
		VectorCopy (r_emissive_seeds[s].origin, dl->origin);
		VectorCopy (r_emissive_seeds[s].color,  dl->color);
		dl->radius   = r_emissive_seeds[s].radius * scale;
		// Round v7 review B1: BRIGHTLIGHT/DIMLIGHT-style "expires before
		// next frame" idiom. 0.1s would leave ~6 living slots/seed at
		// 60 fps, saturating MAX_DLIGHTS=64 and stomping cl_dlights[0]
		// (the player muzzle-flash slot). 0.001s ensures the slot is
		// dead before R_PushDlights runs again next frame.
		dl->die      = cl.time + 0.001f;
		dl->minlight = 0.0f;
		dl->decay    = 0.0f;
	}
}
