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
// r_efrag.c

#include "quakedef.h"

static mnode_t	*r_pefragtopnode;

// PPC port -- Round v9 item 1 (Ironwail flat-array efrags pattern,
// IRONWAIL_REVIEW.md candidate 1). The legacy efrag system stores a
// per-leaf linked list of (entity, leafnext) pairs; per-frame, the
// BSP walker calls R_StoreEfrags for every visible leaf to chase
// pointers and collect static entities into cl_visedicts. Honest
// expectation on id1 maps (~50-200 statics) is sub-1 % fps; the real
// wins are heap reduction and a stronger CPU cache profile on dense
// custom maps.
//
// New layout: each static entity records (firstleaf, numleaves) into
// cl_flat_efrag_records[]. The leaf indices live consecutively in
// cl_flat_efrag_pool[]. R_StoreStaticEntities walks the records once
// per frame, vis-byte-tests each leaf, and adds the entity to
// cl_visedicts on first hit.
//
// Legacy linked list is also still built so -noflatefrags can fall
// back. Memory cost of the shadow array is small (~5 leaves per
// entity * 4 bytes * 200 entities = 4 KB) and load-time cost is
// trivial (one int store per leaf hit during R_SplitEntityOnNode).

typedef struct {
	entity_t	*ent;
	int		firstleaf;	// index into cl_flat_efrag_pool
	int		numleaves;
} flat_efrag_record_t;

static flat_efrag_record_t cl_flat_efrag_records[MAX_STATIC_ENTITIES];
static int                 cl_num_flat_efrag_records = 0;

// Pool sized at compile time; ~16 K ints = 64 KB BSS. id1 maps with
// ~200 statics * ~5 leaves average = ~1000 entries, so 16x headroom.
// Sys_Error on overflow; a pathological custom map would need this
// raised. (MAX_STATIC_ENTITIES is 4096, FLAT_EFRAG_WORK_MAX is 256,
// absolute upper bound is 1 M ints — but that is far beyond any
// realistic map and would imply raising both knobs together.)
#define FLAT_EFRAG_POOL_MAX	16384
static int                 cl_flat_efrag_pool[FLAT_EFRAG_POOL_MAX];
static int                 cl_flat_efrag_pool_used = 0;

// Working buffer used by R_SplitEntityOnNode for the entity currently
// being split. Bounded by typical leaf-touch counts; Sys_Error if a
// pathological entity blows past it.
#define FLAT_EFRAG_WORK_MAX	256
static int                 cl_flat_efrag_work[FLAT_EFRAG_WORK_MAX];
static int                 cl_flat_efrag_work_used = 0;

qboolean flat_efrags_disabled = false;	/* set by -noflatefrags */


/*
===============================================================================

					ENTITY FRAGMENT FUNCTIONS

ericw -- GLQuake only uses efrags for static entities, and they're never
removed, so I trimmed out unused functionality and fields in efrag_t.

Now, efrags are just a linked list for each leaf of the static
entities that touch that leaf. The efrags are hunk-allocated so there is no
fixed limit.

This is inspired by MH's tutorial, and code from RMQEngine.
http://forums.insideqc.com/viewtopic.php?t=1930

===============================================================================
*/

static vec3_t		r_emins, r_emaxs;

static entity_t		*r_addent;


#define EXTRA_EFRAGS	128

// based on RMQEngine
static efrag_t *R_GetEfrag (void)
{
	// we could just Hunk_Alloc a single efrag_t and return it, but since
	// the struct is so small (2 pointers) allocate groups of them
	// to avoid wasting too much space on the hunk allocation headers.
	if (cl.free_efrags)
	{
		efrag_t *ef = cl.free_efrags;
		cl.free_efrags = ef->leafnext;
		ef->leafnext = NULL;

		cl.num_efrags++;

		return ef;
	}
	else
	{
		int i;

		cl.free_efrags = (efrag_t *) Hunk_AllocName (EXTRA_EFRAGS * sizeof (efrag_t), "efrags");

		for (i = 0; i < EXTRA_EFRAGS - 1; i++)
			cl.free_efrags[i].leafnext = &cl.free_efrags[i + 1];

		cl.free_efrags[i].leafnext = NULL;

		// call recursively to get a newly allocated free efrag
		return R_GetEfrag ();
	}
}

/*
===================
R_SplitEntityOnNode
===================
*/
void R_SplitEntityOnNode (mnode_t *node)
{
	efrag_t		*ef;
	mplane_t	*splitplane;
	mleaf_t		*leaf;
	int			sides;

	if (node->contents == CONTENTS_SOLID)
	{
		return;
	}

// add an efrag if the node is a leaf

	if ( node->contents < 0)
	{
		int		leafidx;

		if (!r_pefragtopnode)
			r_pefragtopnode = node;

		leaf = (mleaf_t *)node;

	// grab an efrag off the free list
		ef = R_GetEfrag();
		ef->entity = r_addent;

	// set the leaf links
		ef->leafnext = leaf->efrags;
		leaf->efrags = ef;

	// PPC port -- v9 item 1: also push the leaf's PVS bit to the
	// working buffer so R_AddEfrags can commit a flat-array record.
	// PVS bit position N corresponds to leafs[N+1] (leaf 0 is the
	// "outside the map" sentinel, never visited via BSP). Storing the
	// PVS bit (rather than the array index) makes the per-frame test
	// `vis[bit>>3] & (1<<(bit&7))` direct.
		leafidx = (int)(leaf - cl.worldmodel->leafs) - 1;
		if (leafidx >= 0)
		{
			if (cl_flat_efrag_work_used < FLAT_EFRAG_WORK_MAX)
				cl_flat_efrag_work[cl_flat_efrag_work_used++] = leafidx;
			else
				Sys_Error ("R_SplitEntityOnNode: entity touches > %d leaves; raise FLAT_EFRAG_WORK_MAX",
				           FLAT_EFRAG_WORK_MAX);
		}

		return;
	}

// NODE_MIXED

	splitplane = node->plane;
	sides = BOX_ON_PLANE_SIDE(r_emins, r_emaxs, splitplane);

	if (sides == 3)
	{
	// split on this plane
	// if this is the first splitter of this bmodel, remember it
		if (!r_pefragtopnode)
			r_pefragtopnode = node;
	}

// recurse down the contacted sides
	if (sides & 1)
		R_SplitEntityOnNode (node->children[0]);

	if (sides & 2)
		R_SplitEntityOnNode (node->children[1]);
}

/*
===========
R_CheckEfrags -- johnfitz -- check for excessive efrag count
===========
*/
void R_CheckEfrags (void)
{
	if (cls.signon < 2)
		return; //don't spam when still parsing signon packet full of static ents

	if (cl.num_efrags > 640 && dev_peakstats.efrags <= 640)
		Con_DWarning ("%i efrags exceeds standard limit of 640.\n", cl.num_efrags);

	dev_stats.efrags = cl.num_efrags;
	dev_peakstats.efrags = q_max(cl.num_efrags, dev_peakstats.efrags);
}

/*
===========
R_AddEfrags
===========
*/
void R_AddEfrags (entity_t *ent)
{
	qmodel_t	*entmodel;
	vec_t		scalefactor;

	if (!ent->model)
		return;

	r_addent = ent;

	r_pefragtopnode = NULL;

	entmodel = ent->model;
	scalefactor = ENTSCALE_DECODE(ent->scale);
	if (scalefactor != 1.0f)
	{
		VectorMA (ent->origin, scalefactor, entmodel->mins, r_emins);
		VectorMA (ent->origin, scalefactor, entmodel->maxs, r_emaxs);
	}
	else
	{
		VectorAdd (ent->origin, entmodel->mins, r_emins);
		VectorAdd (ent->origin, entmodel->maxs, r_emaxs);
	}

	// PPC port -- v9 item 1: reset the working buffer; R_SplitEntityOnNode
	// fills it with this entity's touched leaves.
	cl_flat_efrag_work_used = 0;

	R_SplitEntityOnNode (cl.worldmodel->nodes);

	ent->topnode = r_pefragtopnode;

	// PPC port -- v9 item 1: commit working buffer to the flat pool.
	// Pool is a fixed-size static array; Sys_Error on overflow (no
	// realistic map should hit it; raise FLAT_EFRAG_POOL_MAX if it does).
	if (cl_flat_efrag_work_used > 0 && cl_num_flat_efrag_records < MAX_STATIC_ENTITIES)
	{
		flat_efrag_record_t *rec;

		if (cl_flat_efrag_pool_used + cl_flat_efrag_work_used > FLAT_EFRAG_POOL_MAX)
			Sys_Error ("flat efrag pool overflow (%d + %d > %d); raise FLAT_EFRAG_POOL_MAX",
			           cl_flat_efrag_pool_used, cl_flat_efrag_work_used, FLAT_EFRAG_POOL_MAX);

		rec = &cl_flat_efrag_records[cl_num_flat_efrag_records++];
		rec->ent       = ent;
		rec->firstleaf = cl_flat_efrag_pool_used;
		rec->numleaves = cl_flat_efrag_work_used;
		memcpy (cl_flat_efrag_pool + cl_flat_efrag_pool_used,
		        cl_flat_efrag_work,
		        cl_flat_efrag_work_used * sizeof(int));
		cl_flat_efrag_pool_used += cl_flat_efrag_work_used;
	}

	R_CheckEfrags (); //johnfitz
}

/*
===================
R_ResetFlatEfrags -- PPC port v9 item 1

Called from R_NewMap so the next level starts with empty flat-array
records. The hunk-allocated pool is reset implicitly because Hunk_Free
runs on level transition (or because the pool was Hunk_AllocName'd
into the high hunk); we just reset the counters.
===================
*/
void R_ResetFlatEfrags (void)
{
	cl_num_flat_efrag_records = 0;
	cl_flat_efrag_pool_used   = 0;
	cl_flat_efrag_work_used   = 0;
}

/*
================
R_StoreStaticEntities -- PPC port v9 item 1

Single sequential pass over the flat-array static-entity records.
Replaces the per-leaf R_StoreEfrags walks called from R_MarkSurfaces.
For each static entity, scan its leaf list against vis[]; on first
visible leaf, add to cl_visedicts and break. Cache-friendly read
pattern (linear over cl_flat_efrag_records and cl_flat_efrag_pool)
contrasts with the legacy linked-list pointer chase.
================
*/
void R_StoreStaticEntities (byte *vis)
{
	int n;

	for (n = 0; n < cl_num_flat_efrag_records; n++)
	{
		flat_efrag_record_t *rec = &cl_flat_efrag_records[n];
		entity_t            *ent = rec->ent;
		int                  i;
		int                  endleaf;

		if (ent->visframe == r_framecount)
			continue;	// already added this frame
		if (cl_numvisedicts >= MAX_VISEDICTS)
			break;

		endleaf = rec->firstleaf + rec->numleaves;
		for (i = rec->firstleaf; i < endleaf; i++)
		{
			int bit = cl_flat_efrag_pool[i];
			if (vis[bit >> 3] & (1 << (bit & 7)))
			{
				cl_visedicts[cl_numvisedicts++] = ent;
				ent->visframe = r_framecount;
				break;
			}
		}
	}
}

/*
================
R_StoreEfrags -- johnfitz -- pointless switch statement removed.
================
*/
void R_StoreEfrags (efrag_t **ppefrag)
{
	entity_t	*pent;
	efrag_t		*pefrag;

	while ((pefrag = *ppefrag) != NULL)
	{
		pent = pefrag->entity;

		if ((pent->visframe != r_framecount) && (cl_numvisedicts < MAX_VISEDICTS))
		{
			cl_visedicts[cl_numvisedicts++] = pent;
			pent->visframe = r_framecount;
		}

		ppefrag = &pefrag->leafnext;
	}
}
