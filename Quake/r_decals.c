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
// r_decals.c -- world damage-mark (decal) subsystem
//
// Ported from the sister Quake II PPC port's r_decal.c (itself derived
// from KMQuake2's fragment clipper, id Tech 2 lineage, GPLv2). The whole
// subsystem lives renderer-side: the client only calls R_SpawnDecal()
// with an impact point and a decal type.
//
// Key differences from the Q2 source, all because Q1 temp-entity packets
// carry only a position (no surface normal, unlike Q2's MSG_ReadDir):
//   * R_SpawnDecal() traces six cardinal axes against the world hull to
//     recover the nearest surface + its plane normal before clipping.
//   * Q1 BSP leaf test is node->contents < 0 (Q2 used == -1).
//   * Q1 surfaces are uniquely owned by one node, so the Q2 per-surface
//     checkCount de-dup is unnecessary and dropped.
//   * Textures are generated procedurally (like R_InitParticleTextures)
//     rather than loaded from disk, so nothing has to ship in id1/.
//
// Toggleable per docs/GATING.md: r_decals (master on/off), r_decal_max
// (cap), r_decal_life / r_decal_fade (seconds). All CVAR_ARCHIVE.

#include "quakedef.h"

/* ----- fragment clipper tunables ----- */
#define DECAL_ON_EPSILON       0.1
#define MAX_FRAGMENT_POINTS    128
#define MAX_FRAGMENT_PLANES    6

/* ----- storage caps ----- */
#define MAX_DECALS         128
/* Each decal slot owns a fixed window of the vertex pool, so recycling a
 * FIFO slot overwrites only that slot's own old geometry -- a free-running
 * pool head could otherwise stomp a still-live decal's verts (visual glitch).
 * A decal needing more than one window's worth of verts is dropped. */
#define DECAL_VERTS_PER    64
#define MAX_DECAL_VERTS    (MAX_DECALS * DECAL_VERTS_PER)

/* ----- decal types (must match the DECALTYPE_* macros in glquake.h) ----- */
enum {
	DECAL_BULLET = 0,	/* shotgun / axe wall hits */
	DECAL_NAIL,			/* nailgun (smaller) */
	DECAL_SUPERNAIL,	/* super nailgun (bigger) */
	DECAL_SCORCH,		/* energy spikes (wizard, hell-knight, tarbaby) */
	DECAL_BURN,			/* rocket / grenade explosions */
	DECAL_LIGHTNING,	/* thunderbolt */
	DECAL_SLASH,		/* axe melee gash */
	DECAL_TYPE_COUNT
};

/* ----- texture atlas (several decal types share one texture) ----- */
enum {
	DTEX_BULLET = 0,
	DTEX_SCORCH,
	DTEX_BURN,
	DTEX_LIGHTNING,
	DTEX_SLASH,
	DTEX_COUNT
};

typedef struct {
	int firstPoint;
	int numPoints;
} decalfrag_t;

/* synthesized clip plane (axis-aligned bbox sides around the impact) */
typedef struct {
	vec3_t normal;
	float  dist;
	int    type;	/* 0/1/2 axial, 3 = general */
} decalplane_t;

typedef struct {
	qboolean inUse;
	float    fadeStart;	/* cl.time at which fade begins */
	float    fadeEnd;	/* cl.time at which it is fully gone */
	gltexture_t *texture;
	int      firstPoint;	/* into r_decal_verts[] */
	int      numFragments;
	int      fragOffsets[16];
	int      fragLens[16];
	/* texgen basis, captured at spawn so the draw pass derives accurate
	 * (s,t) per vertex instead of approximating from a fragment centroid
	 * (which leaves a visible square outline on the wall). */
	vec3_t   origin;
	vec3_t   right;
	vec3_t   up;
	float    radius;
	float    rotCos, rotSin;	/* per-decal random in-plane rotation */
} r_decal_t;

static r_decal_t r_decal_list[MAX_DECALS];
static vec3_t    r_decal_verts[MAX_DECAL_VERTS];
static int       r_decal_next;		/* FIFO slot head */

/* clipper working state, reset per R_MarkFragments call */
static int          cm_numMarkPoints;
static int          cm_maxMarkPoints;
static vec3_t      *cm_markPoints;
static int          cm_numMarkFragments;
static int          cm_maxMarkFragments;
static decalfrag_t *cm_markFragments;
static decalplane_t cm_markPlanes[MAX_FRAGMENT_PLANES];

static gltexture_t *r_decal_textures[DTEX_COUNT];

/* per-type: which texture, the decal radius (texture half-extent), and the
 * distance the surface-finding probe reaches. Explosions float in open air,
 * so BURN needs a longer reach to find the wall/floor it went off against. */
static const int   decal_tex   [DECAL_TYPE_COUNT] =
	{ DTEX_BULLET, DTEX_BULLET, DTEX_BULLET, DTEX_SCORCH, DTEX_BURN, DTEX_LIGHTNING, DTEX_SLASH };
static const float decal_radius[DECAL_TYPE_COUNT] =
	{ 8.0f,        6.0f,        9.0f,        12.0f,       30.0f,     10.0f,          13.0f };
static const float decal_probe [DECAL_TYPE_COUNT] =
	{ 18.0f,       18.0f,       18.0f,       18.0f,       48.0f,     22.0f,          18.0f };

cvar_t r_decals      = {"r_decals",      "1",  CVAR_ARCHIVE};
cvar_t r_decal_max   = {"r_decal_max",   "32", CVAR_ARCHIVE};
cvar_t r_decal_life  = {"r_decal_life",  "30", CVAR_ARCHIVE};
cvar_t r_decal_fade  = {"r_decal_fade",  "5",  CVAR_ARCHIVE};

/* Instrumentation, off by default and reported only at the end of a
 * timedemo, so a bench run costs nothing extra until it is asked for.
 * Exists because an A/B of r_decals 0 vs 1 is meaningless unless we can
 * show a decal was actually spawned, kept and drawn during the run. */
cvar_t r_decal_stats = {"r_decal_stats", "0", CVAR_NONE};

static unsigned long ds_spawn_calls;	/* R_SpawnDecal entered, before any gate */
static unsigned long ds_spawn_gated;	/* dropped: r_decals 0 or bad type */
static unsigned long ds_probe_fail;	/* no surface found within probe reach */
static unsigned long ds_add_calls;	/* probe hit, R_AddDecal entered */
static unsigned long ds_drop_nofrag;	/* clipper produced no fragments */
static unsigned long ds_drop_verts;	/* fragment set too big for one slot */
static unsigned long ds_committed;	/* decal actually stored in a slot */
static unsigned long ds_draw_frames;	/* R_DrawDecals entered with r_decals on */
static unsigned long ds_draw_empty;	/* ...and took the nothing-live early out */
static unsigned long ds_draw_work;	/* ...and drew at least one decal */
static unsigned long ds_drawn_decals;	/* decal-draws summed over frames */
static unsigned long ds_drawn_frags;	/* triangle fans issued */
static unsigned long ds_drawn_verts;	/* vertices issued */
static int           ds_peak_live;	/* most decals live in any one frame */

void R_DecalStats_Reset (void)
{
	ds_spawn_calls = ds_spawn_gated = ds_probe_fail = ds_add_calls = 0;
	ds_drop_nofrag = ds_drop_verts = ds_committed = 0;
	ds_draw_frames = ds_draw_empty = ds_draw_work = 0;
	ds_drawn_decals = ds_drawn_frags = ds_drawn_verts = 0;
	ds_peak_live = 0;
}

void R_DecalStats_Report (void)
{
	if (!r_decal_stats.value)
		return;

	Con_Printf ("decalstats: spawn=%lu gated=%lu probefail=%lu add=%lu "
			"dropnofrag=%lu dropverts=%lu committed=%lu\n",
			ds_spawn_calls, ds_spawn_gated, ds_probe_fail, ds_add_calls,
			ds_drop_nofrag, ds_drop_verts, ds_committed);
	Con_Printf ("decalstats: drawframes=%lu empty=%lu work=%lu "
			"decaldraws=%lu frags=%lu verts=%lu peaklive=%d\n",
			ds_draw_frames, ds_draw_empty, ds_draw_work,
			ds_drawn_decals, ds_drawn_frags, ds_drawn_verts, ds_peak_live);
}

/*
=================================================================
 Fragment clipper -- carves a square decal patch out of the BSP
 geometry around an impact point, clipping each world polygon to
 the six bounding-box planes of the decal.
=================================================================
*/

static int
PlaneTypeForNormal (const vec3_t normal)
{
	if (normal[0] == 1.0f) return 0;
	if (normal[1] == 1.0f) return 1;
	if (normal[2] == 1.0f) return 2;
	return 3;
}

static float *
worldVert (int i, msurface_t *surf)
{
	int e = cl.worldmodel->surfedges[surf->firstedge + i];
	if (e >= 0)
		return &cl.worldmodel->vertexes[cl.worldmodel->edges[e].v[0]].position[0];
	return &cl.worldmodel->vertexes[cl.worldmodel->edges[-e].v[1]].position[0];
}

static void
R_ClipFragment (int numPoints, vec3_t points, int stage, decalfrag_t *mf)
{
	int           i, f;
	float        *p;
	qboolean      frontSide;
	vec3_t        front[MAX_FRAGMENT_POINTS];
	float         dist, dists[MAX_FRAGMENT_POINTS];
	int           sides[MAX_FRAGMENT_POINTS];
	decalplane_t *plane;

	if (numPoints > MAX_FRAGMENT_POINTS - 2)
		return;	/* silent drop -- better than tearing the map */

	if (stage == MAX_FRAGMENT_PLANES)
	{
		if (numPoints > 2)
		{
			/* clamp to remaining pool BEFORE recording the count, so the
			 * fragment never advertises more verts than were stored --
			 * otherwise R_AddDecal's copy loop reads past scratch_points[]. */
			if (cm_numMarkPoints + numPoints > cm_maxMarkPoints)
				numPoints = cm_maxMarkPoints - cm_numMarkPoints;

			mf->numPoints = numPoints;
			mf->firstPoint = cm_numMarkPoints;

			for (i = 0, p = points; i < numPoints; i++, p += 3)
				VectorCopy (p, cm_markPoints[cm_numMarkPoints + i]);

			cm_numMarkPoints += numPoints;
		}
		return;
	}

	frontSide = false;
	plane = &cm_markPlanes[stage];
	for (i = 0, p = points; i < numPoints; i++, p += 3)
	{
		if (plane->type < 3)
			dists[i] = dist = p[plane->type] - plane->dist;
		else
			dists[i] = dist = DotProduct (p, plane->normal) - plane->dist;

		if (dist > DECAL_ON_EPSILON)
		{
			frontSide = true;
			sides[i] = SIDE_FRONT;
		}
		else if (dist < -DECAL_ON_EPSILON)
			sides[i] = SIDE_BACK;
		else
			sides[i] = SIDE_ON;
	}

	if (!frontSide)
		return;

	dists[i] = dists[0];
	sides[i] = sides[0];
	VectorCopy (points, (points + (i * 3)));

	f = 0;
	for (i = 0, p = points; i < numPoints; i++, p += 3)
	{
		switch (sides[i])
		{
		case SIDE_FRONT:
			VectorCopy (p, front[f]);
			f++;
			break;
		case SIDE_BACK:
			break;
		case SIDE_ON:
			VectorCopy (p, front[f]);
			f++;
			break;
		}

		if (sides[i] == SIDE_ON || sides[i + 1] == SIDE_ON || sides[i + 1] == sides[i])
			continue;

		dist = dists[i] / (dists[i] - dists[i + 1]);
		front[f][0] = p[0] + (p[3] - p[0]) * dist;
		front[f][1] = p[1] + (p[4] - p[1]) * dist;
		front[f][2] = p[2] + (p[5] - p[2]) * dist;
		f++;
	}

	R_ClipFragment (f, front[0], stage + 1, mf);
}

static void
R_ClipFragmentToSurface (msurface_t *surf, const vec3_t normal)
{
	qboolean planeback = (surf->flags & SURF_PLANEBACK) != 0;
	int      i;
	float    d;
	vec3_t   points[MAX_FRAGMENT_POINTS];
	decalfrag_t *mf;

	if (cm_numMarkPoints >= cm_maxMarkPoints ||
	    cm_numMarkFragments >= cm_maxMarkFragments)
		return;

	/* reject surfaces too oblique to the impact normal */
	d = DotProduct (normal, surf->plane->normal);
	if ((planeback && d > -0.75f) || (!planeback && d < 0.75f))
		return;

	for (i = 2; i < surf->numedges; i++)
	{
		mf = &cm_markFragments[cm_numMarkFragments];
		mf->firstPoint = mf->numPoints = 0;

		VectorCopy (worldVert (0,     surf), points[0]);
		VectorCopy (worldVert (i - 1, surf), points[1]);
		VectorCopy (worldVert (i,     surf), points[2]);

		R_ClipFragment (3, points[0], 0, mf);

		if (mf->numPoints)
		{
			cm_numMarkFragments++;
			if (cm_numMarkPoints >= cm_maxMarkPoints ||
			    cm_numMarkFragments >= cm_maxMarkFragments)
				return;
		}
	}
}

static void
R_RecursiveMarkFragments (const vec3_t origin, const vec3_t normal,
		float radius, mnode_t *node)
{
	int         i;
	float       dist;
	mplane_t   *plane;
	msurface_t *surf;

	if (cm_numMarkPoints >= cm_maxMarkPoints ||
	    cm_numMarkFragments >= cm_maxMarkFragments)
		return;

	if (node->contents < 0)
		return;	/* reached a leaf */

	plane = node->plane;
	if (plane->type < 3)
		dist = origin[plane->type] - plane->dist;
	else
		dist = DotProduct (origin, plane->normal) - plane->dist;

	if (dist > radius)
	{
		R_RecursiveMarkFragments (origin, normal, radius, node->children[0]);
		return;
	}
	if (dist < -radius)
	{
		R_RecursiveMarkFragments (origin, normal, radius, node->children[1]);
		return;
	}

	surf = cl.worldmodel->surfaces + node->firstsurface;
	for (i = 0; i < (int)node->numsurfaces; i++, surf++)
	{
		/* skip sky / liquid / tiled / untextured surfaces */
		if (surf->flags & (SURF_DRAWSKY | SURF_DRAWTURB | SURF_DRAWTILED | SURF_NOTEXTURE))
			continue;
		R_ClipFragmentToSurface (surf, normal);
	}

	R_RecursiveMarkFragments (origin, normal, radius, node->children[0]);
	R_RecursiveMarkFragments (origin, normal, radius, node->children[1]);
}

static int
R_MarkFragments (const vec3_t origin, const vec3_t axis[3], float radius,
		int maxPoints, vec3_t *points, int maxFragments, decalfrag_t *fragments)
{
	int   i;
	float dot;

	if (!cl.worldmodel || !cl.worldmodel->nodes)
		return 0;

	cm_numMarkPoints = 0;
	cm_maxMarkPoints = maxPoints;
	cm_markPoints = points;

	cm_numMarkFragments = 0;
	cm_maxMarkFragments = maxFragments;
	cm_markFragments = fragments;

	for (i = 0; i < 3; i++)
	{
		dot = DotProduct (origin, axis[i]);

		VectorCopy (axis[i], cm_markPlanes[i * 2 + 0].normal);
		cm_markPlanes[i * 2 + 0].dist = dot - radius;
		cm_markPlanes[i * 2 + 0].type = PlaneTypeForNormal (cm_markPlanes[i * 2 + 0].normal);

		cm_markPlanes[i * 2 + 1].normal[0] = -axis[i][0];
		cm_markPlanes[i * 2 + 1].normal[1] = -axis[i][1];
		cm_markPlanes[i * 2 + 1].normal[2] = -axis[i][2];
		cm_markPlanes[i * 2 + 1].dist = -dot - radius;
		cm_markPlanes[i * 2 + 1].type = PlaneTypeForNormal (cm_markPlanes[i * 2 + 1].normal);
	}

	R_RecursiveMarkFragments (origin, axis[0], radius, cl.worldmodel->nodes);

	return cm_numMarkFragments;
}

/*
=================================================================
 Decal manager
=================================================================
*/

void R_ClearDecals (void)
{
	memset (r_decal_list, 0, sizeof(r_decal_list));
	r_decal_next = 0;
}

/* Build an orthonormal (right, up) basis around the surface normal. */
static void
MakeNormalVectors (const vec3_t normal, vec3_t right, vec3_t up)
{
	float  d;
	vec3_t tmp;

	if (fabs(normal[0]) < 0.9f)
	{
		tmp[0] = 1.0f; tmp[1] = 0.0f; tmp[2] = 0.0f;
	}
	else
	{
		tmp[0] = 0.0f; tmp[1] = 1.0f; tmp[2] = 0.0f;
	}

	d = DotProduct (tmp, normal);
	right[0] = tmp[0] - d * normal[0];
	right[1] = tmp[1] - d * normal[1];
	right[2] = tmp[2] - d * normal[2];
	VectorNormalize (right);

	CrossProduct (normal, right, up);
}

static void
R_AddDecal (const vec3_t origin, const vec3_t normal, float radius, int type)
{
	int          maxDecals, i, slot, numFrags, verts_needed;
	vec3_t       axis[3];
	vec3_t       scratch_points[MAX_FRAGMENT_POINTS];
	decalfrag_t  scratch_frags[16];
	r_decal_t   *d;
	float        now;

	ds_add_calls++;

	if (!r_decals.value || !cl.worldmodel)
		return;
	if (type < 0 || type >= DECAL_TYPE_COUNT || !r_decal_textures[decal_tex[type]])
		return;

	maxDecals = (int)r_decal_max.value;
	if (maxDecals > MAX_DECALS) maxDecals = MAX_DECALS;
	if (maxDecals < 1) maxDecals = 1;

	VectorCopy (normal, axis[0]);
	MakeNormalVectors (normal, axis[1], axis[2]);

	numFrags = R_MarkFragments (origin, (const vec3_t *)axis, radius,
			MAX_FRAGMENT_POINTS, scratch_points, 16, scratch_frags);
	if (numFrags <= 0)
		{ ds_drop_nofrag++; return; }

	verts_needed = 0;
	for (i = 0; i < numFrags; i++)
		verts_needed += scratch_frags[i].numPoints;
	if (verts_needed <= 0 || verts_needed > DECAL_VERTS_PER)
		{ ds_drop_verts++; return; }	/* too complex for one slot's vertex window */

	slot = r_decal_next % maxDecals;
	r_decal_next = (r_decal_next + 1) % maxDecals;
	d = &r_decal_list[slot];

	d->firstPoint = slot * DECAL_VERTS_PER;	/* this slot's fixed window */
	d->numFragments = (numFrags > 16) ? 16 : numFrags;

	{
		int frag_i, dst_off = 0;
		for (frag_i = 0; frag_i < d->numFragments; frag_i++)
		{
			int n = scratch_frags[frag_i].numPoints;
			int src_first = scratch_frags[frag_i].firstPoint;
			int j;
			d->fragOffsets[frag_i] = dst_off;
			d->fragLens[frag_i] = n;
			for (j = 0; j < n; j++)
				VectorCopy (scratch_points[src_first + j],
						r_decal_verts[d->firstPoint + dst_off + j]);
			dst_off += n;
		}
	}

	VectorCopy (origin, d->origin);
	VectorCopy (axis[1], d->right);
	VectorCopy (axis[2], d->up);
	d->radius = radius;

	{
		float ang = (rand() & 0xfff) * (2.0f * (float)M_PI / 4096.0f);
		d->rotCos = cos(ang);
		d->rotSin = sin(ang);
	}

	now = cl.time;
	d->inUse = true;
	d->fadeStart = now + r_decal_life.value;
	d->fadeEnd   = d->fadeStart + r_decal_fade.value;
	d->texture = r_decal_textures[decal_tex[type]];
	ds_committed++;
}

/*
=================================================================
 Surface probe + public spawn entry point
=================================================================
*/

/* Trace six cardinal axes against the world hull to find the nearest
 * surface to an impact point and recover its plane normal. Q1 temp
 * entities give us only a position; this recovers the normal the
 * fragment clipper needs. Mirrors the Q2 port's CL_TraceExplosionSurface. */
static qboolean
R_DecalProbeSurface (const vec3_t origin, float probe, vec3_t out_pos, vec3_t out_normal)
{
	static const vec3_t dirs[6] = {
		{ 1, 0, 0 }, { -1, 0, 0 },
		{ 0, 1, 0 }, { 0, -1, 0 },
		{ 0, 0, 1 }, { 0, 0, -1 }
	};
	int      i;
	float    best = 1.0f;
	qboolean found = false;
	vec3_t   start, end;
	/* Back the probe start up a few units against its own direction. A
	 * hitscan impact (shotgun) sits just off the open side of the surface,
	 * but a projectile impact (nailgun/super-nailgun TE_SPIKE) can be a
	 * couple of units EMBEDDED in the solid, which would make every
	 * outward probe start in solid (startsolid) and find nothing -> no
	 * decal. Starting BACKUP units behind origin guarantees the probe
	 * begins in open space and still crosses the surface. */
	const float BACKUP = 4.0f;

	if (!cl.worldmodel || !cl.worldmodel->nodes)
		return false;

	for (i = 0; i < 6; i++)
	{
		trace_t tr;

		VectorMA (origin, -BACKUP, dirs[i], start);
		VectorMA (origin, probe, dirs[i], end);

		/* SV_RecursiveHullCheck follows the SV_Move convention: caller
		 * pre-fills fraction=1 / endpos=end and seeds allsolid=true (the
		 * "never left solid" guard is only ever cleared, never set). It
		 * writes endpos/plane/fraction only on an actual hit. */
		memset (&tr, 0, sizeof(tr));
		tr.fraction = 1.0f;
		tr.allsolid = true;
		VectorCopy (end, tr.endpos);

		SV_RecursiveHullCheck (cl.worldmodel->hulls, 0, 0, 1, start, end, &tr);

		if (tr.allsolid || tr.startsolid)
			continue;
		if (tr.fraction < best)
		{
			best = tr.fraction;
			VectorCopy (tr.endpos, out_pos);
			VectorCopy (tr.plane.normal, out_normal);
			found = true;
		}
	}

	return found;
}

/* Public: called from cl_tent.c on a weapon impact. */
void R_SpawnDecal (const vec3_t pos, int type)
{
	vec3_t hit, normal;

	/* counted before the gate: proves the demo produced impacts at all,
	 * even on the r_decals 0 leg of an A/B */
	ds_spawn_calls++;

	if (!r_decals.value)
		{ ds_spawn_gated++; return; }
	if (type < 0 || type >= DECAL_TYPE_COUNT)
		{ ds_spawn_gated++; return; }

	if (R_DecalProbeSurface (pos, decal_probe[type], hit, normal))
		R_AddDecal (hit, normal, decal_radius[type], type);
	else
		ds_probe_fail++;
}

/*
=================================================================
 Procedural texture generation (no disk assets, like particles)
=================================================================
*/

/* light separable 3-tap blur over the alpha channel, softens the
 * radial edges the way the Q2 generator's GaussianBlur did. */
static void
DecalBlurAlpha (byte *rgba, int w, int h)
{
	static byte tmp[128 * 128];
	int x, y;

	for (y = 0; y < h; y++)
		for (x = 0; x < w; x++)
		{
			int a0 = rgba[(y * w + ((x > 0) ? x - 1 : x)) * 4 + 3];
			int a1 = rgba[(y * w + x) * 4 + 3];
			int a2 = rgba[(y * w + ((x < w - 1) ? x + 1 : x)) * 4 + 3];
			tmp[y * w + x] = (byte)((a0 + 2 * a1 + a2) >> 2);
		}
	for (y = 0; y < h; y++)
		for (x = 0; x < w; x++)
		{
			int a0 = tmp[((y > 0) ? y - 1 : y) * w + x];
			int a1 = tmp[y * w + x];
			int a2 = tmp[((y < h - 1) ? y + 1 : y) * w + x];
			rgba[(y * w + x) * 4 + 3] = (byte)((a0 + 2 * a1 + a2) >> 2);
		}
}

static void
GenBulletHole (byte *dst)	/* 64x64: dark concentric impact */
{
	int x, y;
	const int S = 64, H = 32;
	for (y = 0; y < S; y++)
		for (x = 0; x < S; x++)
		{
			float dx = x - H + 0.5f, dy = y - H + 0.5f;
			float r = sqrt (dx * dx + dy * dy);
			int a, lum;
			if (r < 8)        { a = 220; lum = 30; }
			else if (r < 16)  { a = (int)(220 * (1.0f - (r - 8) / 8.0f)) + 40; lum = 30 + (int)(30 * (r - 8) / 8.0f); }
			else if (r < 26)  { a = (int)(120 * (1.0f - (r - 16) / 10.0f)); if (a < 0) a = 0; lum = 60; }
			else              { a = 0; lum = 0; }
			*dst++ = lum; *dst++ = lum; *dst++ = lum; *dst++ = a;
		}
}

static void
GenScorch (byte *dst)	/* 64x64: radial black scorch, irregular edge */
{
	int x, y;
	const int S = 64, H = 32;
	for (y = 0; y < S; y++)
		for (x = 0; x < S; x++)
		{
			float dx = x - H + 0.5f, dy = y - H + 0.5f;
			float r = sqrt (dx * dx + dy * dy);
			float ang = atan2 (dy, dx);
			float wob = 1.0f + 0.15f * sin (ang * 7) + 0.10f * sin (ang * 11 + 1.3f);
			float re = r / wob;
			int a;
			if (re < 10)      a = 240;
			else if (re < 28) a = (int)(240 * (1.0f - (re - 10) / 18.0f));
			else              a = 0;
			if (a < 0) a = 0;
			*dst++ = 10; *dst++ = 8; *dst++ = 6; *dst++ = a;
		}
}

static void
GenBurn (byte *dst)	/* 128x128: big charred explosion mark with soot streaks */
{
	int x, y, k;
	const int S = 128, H = 64;
	const float core = 26, edge = 60;
	static const float streaks[11] = {
		0.3f, 1.1f, 1.9f, 2.6f, 3.4f, 4.0f, 4.7f, 5.3f, 5.9f, 0.7f, 2.2f
	};
	for (y = 0; y < S; y++)
		for (x = 0; x < S; x++)
		{
			float dx = x - H + 0.5f, dy = y - H + 0.5f;
			float r = sqrt (dx * dx + dy * dy);
			float ang = atan2 (dy, dx);
			float wob = 1.0f + 0.18f * sin (ang * 5) + 0.12f * sin (ang * 9 + 0.7f) + 0.07f * sin (ang * 17);
			float re = r / wob;
			int a, lum;
			if (re < core)      { a = 245; lum = 8; }
			else if (re < edge) { float t = (re - core) / (edge - core); a = (int)(245 * (1.0f - t)); lum = 8 + (int)(22 * t); }
			else                { a = 0; lum = 0; }
			if (re < edge * 1.25f && r > core * 0.5f)
			{
				for (k = 0; k < 11; k++)
				{
					float dd = fabs (fmod (ang - streaks[k] + M_PI + 2 * M_PI, 2 * M_PI) - M_PI);
					if (dd < 0.06f)
					{
						int sa = (int)(120 * (1.0f - re / (edge * 1.25f)));
						if (sa > a) { a = sa; lum = 14; }
						break;
					}
				}
			}
			if (a < 0) a = 0; if (a > 255) a = 255;
			*dst++ = lum; *dst++ = lum; *dst++ = lum; *dst++ = a;
		}
}

static void
GenLightning (byte *dst)	/* 64x64: electric scorch — dark burn ring, hot bluish core, crackle tendrils */
{
	int x, y, k;
	const int S = 64, H = 32;
	static const float tendrils[7] = { 0.4f, 1.3f, 2.1f, 3.0f, 3.9f, 4.8f, 5.6f };
	for (y = 0; y < S; y++)
		for (x = 0; x < S; x++)
		{
			float dx = x - H + 0.5f, dy = y - H + 0.5f;
			float r = sqrt (dx * dx + dy * dy);
			float ang = atan2 (dy, dx);
			int a, cr, cg, cb;
			if (r < 5)        { a = 215; cr = 180; cg = 205; cb = 255; }	/* hot bluish-white core */
			else if (r < 13)  { float t = (r - 5) / 8.0f;  a = (int)(190 * (1.0f - t)) + 25;
			                    cr = (int)(110 * (1 - t) + 25 * t); cg = (int)(135 * (1 - t) + 22 * t); cb = (int)(175 * (1 - t) + 28 * t); }
			else if (r < 26)  { float t = (r - 13) / 13.0f; a = (int)(115 * (1.0f - t)); cr = 25; cg = 24; cb = 32; }
			else              { a = 0; cr = cg = cb = 0; }
			/* crackle tendrils — bright bluish spokes radiating out */
			if (r > 4 && r < 30)
			{
				for (k = 0; k < 7; k++)
				{
					float dd = fabs (fmod (ang - tendrils[k] + M_PI + 2 * M_PI, 2 * M_PI) - M_PI);
					if (dd < 0.05f)
					{
						int ta = (int)(175 * (1.0f - r / 30.0f));
						if (ta > a) { a = ta; cr = 150; cg = 180; cb = 235; }
						break;
					}
				}
			}
			if (a < 0) a = 0; if (a > 255) a = 255;
			*dst++ = cr; *dst++ = cg; *dst++ = cb; *dst++ = a;
		}
}

static void
GenSlash (byte *dst)	/* 64x64: axe gash — a few tapered parallel cut scratches */
{
	int x, y, k;
	const int S = 64, H = 32;
	static const float voff[3] = { -5.0f, 1.0f, 7.0f };	/* across-gash offset */
	static const float vlen[3] = { 22.0f, 26.0f, 18.0f };	/* half-length along gash */
	for (y = 0; y < S; y++)
		for (x = 0; x < S; x++)
		{
			float u = x - H + 0.5f;	/* along the gash */
			float v = y - H + 0.5f;	/* across the gash */
			int a = 0;
			for (k = 0; k < 3; k++)
			{
				float dv = fabs (v - voff[k]);
				float au = fabs (u);
				if (au < vlen[k] && dv < 3.0f)
				{
					float te = 1.0f - au / vlen[k];	/* fade toward the ends */
					float td = 1.0f - dv / 3.0f;	/* fade across the scratch */
					int   sa = (int)(230.0f * te * td);
					if (sa > a) a = sa;
				}
			}
			if (a < 0) a = 0; if (a > 255) a = 255;
			*dst++ = 12; *dst++ = 10; *dst++ = 8; *dst++ = a;	/* dark cut */
		}
}

void R_InitDecals (void)
{
	static byte bullet_data[64 * 64 * 4];
	static byte scorch_data[64 * 64 * 4];
	static byte burn_data[128 * 128 * 4];
	static byte lightning_data[64 * 64 * 4];
	static byte slash_data[64 * 64 * 4];

	Cvar_RegisterVariable (&r_decals);
	Cvar_RegisterVariable (&r_decal_max);
	Cvar_RegisterVariable (&r_decal_life);
	Cvar_RegisterVariable (&r_decal_fade);
	Cvar_RegisterVariable (&r_decal_stats);

	GenBulletHole (bullet_data);
	DecalBlurAlpha (bullet_data, 64, 64);
	r_decal_textures[DTEX_BULLET] = TexMgr_LoadImage (NULL, "decal_bullet", 64, 64,
			SRC_RGBA, bullet_data, "", (src_offset_t)bullet_data,
			TEXPREF_PERSIST | TEXPREF_ALPHA | TEXPREF_LINEAR);

	GenScorch (scorch_data);
	DecalBlurAlpha (scorch_data, 64, 64);
	r_decal_textures[DTEX_SCORCH] = TexMgr_LoadImage (NULL, "decal_scorch", 64, 64,
			SRC_RGBA, scorch_data, "", (src_offset_t)scorch_data,
			TEXPREF_PERSIST | TEXPREF_ALPHA | TEXPREF_LINEAR);

	GenBurn (burn_data);
	DecalBlurAlpha (burn_data, 128, 128);
	r_decal_textures[DTEX_BURN] = TexMgr_LoadImage (NULL, "decal_burn", 128, 128,
			SRC_RGBA, burn_data, "", (src_offset_t)burn_data,
			TEXPREF_PERSIST | TEXPREF_ALPHA | TEXPREF_LINEAR);

	GenLightning (lightning_data);
	DecalBlurAlpha (lightning_data, 64, 64);
	r_decal_textures[DTEX_LIGHTNING] = TexMgr_LoadImage (NULL, "decal_lightning", 64, 64,
			SRC_RGBA, lightning_data, "", (src_offset_t)lightning_data,
			TEXPREF_PERSIST | TEXPREF_ALPHA | TEXPREF_LINEAR);

	GenSlash (slash_data);
	DecalBlurAlpha (slash_data, 64, 64);
	r_decal_textures[DTEX_SLASH] = TexMgr_LoadImage (NULL, "decal_slash", 64, 64,
			SRC_RGBA, slash_data, "", (src_offset_t)slash_data,
			TEXPREF_PERSIST | TEXPREF_ALPHA | TEXPREF_LINEAR);

	R_ClearDecals ();
}

/*
=================================================================
 Render pass -- called from R_RenderScene after the opaque world
 and entities, before dlights/particles. Alpha-blended, depth-test
 on, depth-write off, polygon-offset toward camera so the coplanar
 decals never z-fight the wall.
=================================================================
*/

static void
DecalTexCoord (const vec3_t v, const r_decal_t *d, float *s, float *t)
{
	vec3_t diff;
	float  inv = 0.5f / d->radius;
	float  pr, pu;
	VectorSubtract (v, d->origin, diff);
	pr = DotProduct (diff, d->right) * inv;
	pu = DotProduct (diff, d->up)    * inv;
	*s = 0.5f + pr * d->rotCos - pu * d->rotSin;
	*t = 0.5f + pr * d->rotSin + pu * d->rotCos;
}

void R_DrawDecals (void)
{
	int   i, frag_i, j;
	float now, alpha;
	int   any_in_use;
	int   live_this_frame = 0;

	if (!r_decals.value)
		return;

	ds_draw_frames++;

	/* Fast path: skip every GL state change when nothing is live. The
	 * Tiger ATI driver flushes the pipeline on each enable/disable, so an
	 * empty decal pass is not free. */
	any_in_use = 0;
	for (i = 0; i < MAX_DECALS; i++)
		if (r_decal_list[i].inUse) { any_in_use = 1; break; }
	if (!any_in_use)
		{ ds_draw_empty++; return; }

	ds_draw_work++;

	now = cl.time;

	GL_DisableMultitexture ();	/* single TMU0; the world pass left TMU1 (lightmap) bound */

	glEnable (GL_BLEND);
	glBlendFunc (GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
	glDepthMask (GL_FALSE);
	glDisable (GL_ALPHA_TEST);
	GL_PolygonOffset (-2);
	glTexEnvf (GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE);

	for (i = 0; i < MAX_DECALS; i++)
	{
		r_decal_t *d = &r_decal_list[i];
		if (!d->inUse)
			continue;
		if (now > d->fadeEnd)
		{
			d->inUse = false;
			continue;
		}

		alpha = 1.0f;
		if (now > d->fadeStart && d->fadeEnd > d->fadeStart)
			alpha = 1.0f - (now - d->fadeStart) / (d->fadeEnd - d->fadeStart);

		glColor4f (1.0f, 1.0f, 1.0f, alpha);
		GL_Bind (d->texture);
		ds_drawn_decals++;
		live_this_frame++;

		for (frag_i = 0; frag_i < d->numFragments; frag_i++)
		{
			int   fn = d->fragLens[frag_i];
			int   base = d->firstPoint + d->fragOffsets[frag_i];
			float s, t;

			ds_drawn_frags++;
			ds_drawn_verts += (unsigned long)fn;

			glBegin (GL_TRIANGLE_FAN);
			for (j = 0; j < fn; j++)
			{
				DecalTexCoord (r_decal_verts[base + j], d, &s, &t);
				glTexCoord2f (s, t);
				glVertex3fv (r_decal_verts[base + j]);
			}
			glEnd ();
		}
	}

	if (live_this_frame > ds_peak_live)
		ds_peak_live = live_this_frame;

	GL_PolygonOffset (0);
	glDepthMask (GL_TRUE);
	glDisable (GL_BLEND);
	glColor4f (1.0f, 1.0f, 1.0f, 1.0f);
	glTexEnvf (GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);
}
