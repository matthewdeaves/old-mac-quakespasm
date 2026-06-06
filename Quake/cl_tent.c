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
// cl_tent.c -- client side temporary entities

#include "quakedef.h"

int			num_temp_entities;
entity_t	cl_temp_entities[MAX_TEMP_ENTITIES];
beam_t		cl_beams[MAX_BEAMS];

sfx_t			*cl_sfx_wizhit;
sfx_t			*cl_sfx_knighthit;
sfx_t			*cl_sfx_tink1;
sfx_t			*cl_sfx_ric1;
sfx_t			*cl_sfx_ric2;
sfx_t			*cl_sfx_ric3;
sfx_t			*cl_sfx_r_exp3;

/*
=================
CL_ParseTEnt
=================
*/
void CL_InitTEnts (void)
{
	cl_sfx_wizhit = S_PrecacheSound ("wizard/hit.wav");
	cl_sfx_knighthit = S_PrecacheSound ("hknight/hit.wav");
	cl_sfx_tink1 = S_PrecacheSound ("weapons/tink1.wav");
	cl_sfx_ric1 = S_PrecacheSound ("weapons/ric1.wav");
	cl_sfx_ric2 = S_PrecacheSound ("weapons/ric2.wav");
	cl_sfx_ric3 = S_PrecacheSound ("weapons/ric3.wav");
	cl_sfx_r_exp3 = S_PrecacheSound ("weapons/r_exp3.wav");
}

/*
=================
CL_ParseBeam
=================
*/
void CL_ParseBeam (qmodel_t *m, qboolean lightning)
{
	int		ent;
	vec3_t	start, end;
	beam_t	*b;
	int		i;

	ent = MSG_ReadShort ();

	start[0] = MSG_ReadCoord (cl.protocolflags);
	start[1] = MSG_ReadCoord (cl.protocolflags);
	start[2] = MSG_ReadCoord (cl.protocolflags);

	end[0] = MSG_ReadCoord (cl.protocolflags);
	end[1] = MSG_ReadCoord (cl.protocolflags);
	end[2] = MSG_ReadCoord (cl.protocolflags);

	// PPC port -- scorch the wall where lightning terminates. The bolt is
	// the only client signal of a thunderbolt hit (no impact temp entity),
	// so use the beam end. Beams arrive ~10/sec while firing, so throttle:
	// only mark when the endpoint has moved (a sweep rakes a dotted trail)
	// or after a firing gap (re-marks a held spot), never stacking during a
	// continuous burst on one point. (Not the grapple beam -- lightning only.)
	if (lightning)
	{
		static vec3_t last_pos;
		static float  last_time;
		vec3_t        d;
		VectorSubtract (end, last_pos, d);
		if (VectorLength (d) > 24.0f || (cl.time - last_time) > 0.5)
		{
			R_SpawnDecal (end, DECALTYPE_LIGHTNING);
			VectorCopy (end, last_pos);
			last_time = cl.time;
		}
	}

// override any beam with the same entity
	for (i=0, b=cl_beams ; i< MAX_BEAMS ; i++, b++)
		if (b->entity == ent)
		{
			b->entity = ent;
			b->model = m;
			b->endtime = cl.time + 0.2;
			VectorCopy (start, b->start);
			VectorCopy (end, b->end);
			return;
		}

// find a free beam
	for (i=0, b=cl_beams ; i< MAX_BEAMS ; i++, b++)
	{
		if (!b->model || b->endtime < cl.time)
		{
			b->entity = ent;
			b->model = m;
			b->endtime = cl.time + 0.2;
			VectorCopy (start, b->start);
			VectorCopy (end, b->end);
			return;
		}
	}

	//johnfitz -- less spammy overflow message
	if (!dev_overflows.beams || dev_overflows.beams + CONSOLE_RESPAM_TIME < realtime )
	{
		Con_Printf ("Beam list overflow!\n");
		dev_overflows.beams = realtime;
	}
	//johnfitz
}

/*
=================
CL_ParseTEnt
=================
*/
void CL_ParseTEnt (void)
{
	int		type;
	vec3_t	pos;
	dlight_t	*dl;
	int		rnd;
	int		colorStart, colorLength;

	type = MSG_ReadByte ();
	switch (type)
	{
	case TE_WIZSPIKE:			// spike hitting wall
		pos[0] = MSG_ReadCoord (cl.protocolflags);
		pos[1] = MSG_ReadCoord (cl.protocolflags);
		pos[2] = MSG_ReadCoord (cl.protocolflags);
		R_RunParticleEffect (pos, vec3_origin, 20, 30);
		R_SpawnDecal (pos, DECALTYPE_SCORCH);
		S_StartSound (-1, 0, cl_sfx_wizhit, pos, 1, 1);
		break;

	case TE_KNIGHTSPIKE:			// spike hitting wall
		pos[0] = MSG_ReadCoord (cl.protocolflags);
		pos[1] = MSG_ReadCoord (cl.protocolflags);
		pos[2] = MSG_ReadCoord (cl.protocolflags);
		R_RunParticleEffect (pos, vec3_origin, 226, 20);
		R_SpawnDecal (pos, DECALTYPE_SCORCH);
		S_StartSound (-1, 0, cl_sfx_knighthit, pos, 1, 1);
		break;

	case TE_SPIKE:			// spike hitting wall
		pos[0] = MSG_ReadCoord (cl.protocolflags);
		pos[1] = MSG_ReadCoord (cl.protocolflags);
		pos[2] = MSG_ReadCoord (cl.protocolflags);
		R_RunParticleEffect (pos, vec3_origin, 0, 10);
		R_SpawnDecal (pos, DECALTYPE_NAIL);
		if ( rand() % 5 )
			S_StartSound (-1, 0, cl_sfx_tink1, pos, 1, 1);
		else
		{
			rnd = rand() & 3;
			if (rnd == 1)
				S_StartSound (-1, 0, cl_sfx_ric1, pos, 1, 1);
			else if (rnd == 2)
				S_StartSound (-1, 0, cl_sfx_ric2, pos, 1, 1);
			else
				S_StartSound (-1, 0, cl_sfx_ric3, pos, 1, 1);
		}
		break;
	case TE_SUPERSPIKE:			// super spike hitting wall
		pos[0] = MSG_ReadCoord (cl.protocolflags);
		pos[1] = MSG_ReadCoord (cl.protocolflags);
		pos[2] = MSG_ReadCoord (cl.protocolflags);
		R_RunParticleEffect (pos, vec3_origin, 0, 20);
		R_SpawnDecal (pos, DECALTYPE_SUPERNAIL);

		if ( rand() % 5 )
			S_StartSound (-1, 0, cl_sfx_tink1, pos, 1, 1);
		else
		{
			rnd = rand() & 3;
			if (rnd == 1)
				S_StartSound (-1, 0, cl_sfx_ric1, pos, 1, 1);
			else if (rnd == 2)
				S_StartSound (-1, 0, cl_sfx_ric2, pos, 1, 1);
			else
				S_StartSound (-1, 0, cl_sfx_ric3, pos, 1, 1);
		}
		break;

	case TE_GUNSHOT:			// bullet hitting wall
		pos[0] = MSG_ReadCoord (cl.protocolflags);
		pos[1] = MSG_ReadCoord (cl.protocolflags);
		pos[2] = MSG_ReadCoord (cl.protocolflags);
		R_RunParticleEffect (pos, vec3_origin, 0, 20);
		// Stock Quake sends the SAME TE_GUNSHOT for an axe wall-hit and a
		// shotgun/grunt bullet, so the packet can't tell them apart. But the
		// client knows the local player's active weapon: you can't fire a gun
		// while the axe is out, so a TE_GUNSHOT landing within melee reach of
		// the player while the axe is equipped is an axe chop -> slash. The
		// range gate keeps a nearby grunt's gunshots (also TE_GUNSHOT) from
		// being mistaken for axe marks.
		{
			vec3_t d;
			VectorSubtract (pos, cl_entities[cl.viewentity].origin, d);
			if (cl.stats[STAT_ACTIVEWEAPON] == IT_AXE && VectorLength (d) < 90.0f)
				R_SpawnDecal (pos, DECALTYPE_SLASH);
			else
				R_SpawnDecal (pos, DECALTYPE_BULLET);
		}
		break;

	case TE_EXPLOSION:			// rocket explosion
		pos[0] = MSG_ReadCoord (cl.protocolflags);
		pos[1] = MSG_ReadCoord (cl.protocolflags);
		pos[2] = MSG_ReadCoord (cl.protocolflags);
		R_ParticleExplosion (pos);
		R_SpawnDecal (pos, DECALTYPE_BURN);
		dl = CL_AllocDlight (0);
		VectorCopy (pos, dl->origin);
		dl->radius = 350;
		dl->die = cl.time + 0.5;
		dl->decay = 300;
		S_StartSound (-1, 0, cl_sfx_r_exp3, pos, 1, 1);
		break;

	case TE_TAREXPLOSION:			// tarbaby explosion
		pos[0] = MSG_ReadCoord (cl.protocolflags);
		pos[1] = MSG_ReadCoord (cl.protocolflags);
		pos[2] = MSG_ReadCoord (cl.protocolflags);
		R_BlobExplosion (pos);
		R_SpawnDecal (pos, DECALTYPE_SCORCH);

		S_StartSound (-1, 0, cl_sfx_r_exp3, pos, 1, 1);
		break;

	case TE_LIGHTNING1:				// lightning bolts
		CL_ParseBeam (Mod_ForName("progs/bolt.mdl", true), true);
		break;

	case TE_LIGHTNING2:				// lightning bolts
		CL_ParseBeam (Mod_ForName("progs/bolt2.mdl", true), true);
		break;

	case TE_LIGHTNING3:				// lightning bolts
		CL_ParseBeam (Mod_ForName("progs/bolt3.mdl", true), true);
		break;

// PGM 01/21/97
	case TE_BEAM:				// grappling hook beam
		CL_ParseBeam (Mod_ForName("progs/beam.mdl", true), false);
		break;
// PGM 01/21/97

	case TE_LAVASPLASH:
		pos[0] = MSG_ReadCoord (cl.protocolflags);
		pos[1] = MSG_ReadCoord (cl.protocolflags);
		pos[2] = MSG_ReadCoord (cl.protocolflags);
		R_LavaSplash (pos);
		break;

	case TE_TELEPORT:
		pos[0] = MSG_ReadCoord (cl.protocolflags);
		pos[1] = MSG_ReadCoord (cl.protocolflags);
		pos[2] = MSG_ReadCoord (cl.protocolflags);
		R_TeleportSplash (pos);
		break;

	case TE_EXPLOSION2:				// color mapped explosion
		pos[0] = MSG_ReadCoord (cl.protocolflags);
		pos[1] = MSG_ReadCoord (cl.protocolflags);
		pos[2] = MSG_ReadCoord (cl.protocolflags);
		colorStart = MSG_ReadByte ();
		colorLength = MSG_ReadByte ();
		R_ParticleExplosion2 (pos, colorStart, colorLength);
		R_SpawnDecal (pos, DECALTYPE_BURN);
		dl = CL_AllocDlight (0);
		VectorCopy (pos, dl->origin);
		dl->radius = 350;
		dl->die = cl.time + 0.5;
		dl->decay = 300;
		S_StartSound (-1, 0, cl_sfx_r_exp3, pos, 1, 1);
		break;

	default:
		Sys_Error ("CL_ParseTEnt: bad type");
	}
}


/*
=================
CL_NewTempEntity
=================
*/
entity_t *CL_NewTempEntity (void)
{
	entity_t	*ent;

	if (cl_numvisedicts == MAX_VISEDICTS)
		return NULL;
	if (num_temp_entities == MAX_TEMP_ENTITIES)
		return NULL;
	ent = &cl_temp_entities[num_temp_entities];
	memset (ent, 0, sizeof(*ent));
	num_temp_entities++;
	cl_visedicts[cl_numvisedicts] = ent;
	cl_numvisedicts++;
	ent->scale = ENTSCALE_DEFAULT;
	ent->colormap = vid.colormap;
	return ent;
}


/*
=================
CL_UpdateTEnts
=================
*/
void CL_UpdateTEnts (void)
{
	int			i, j; //johnfitz -- use j instead of using i twice, so we don't corrupt memory
	beam_t		*b;
	vec3_t		dist, org;
	float		d;
	entity_t	*ent;
	float		yaw, pitch;
	float		forward;

	num_temp_entities = 0;

	srand ((int) (cl.time * 1000)); //johnfitz -- freeze beams when paused

// update lightning
	for (i=0, b=cl_beams ; i< MAX_BEAMS ; i++, b++)
	{
		if (!b->model || b->endtime < cl.time)
			continue;

	// if coming from the player, update the start position
		if (b->entity == cl.viewentity)
		{
			VectorCopy (cl_entities[cl.viewentity].origin, b->start);
		}

	// calculate pitch and yaw
		VectorSubtract (b->end, b->start, dist);

		if (dist[1] == 0 && dist[0] == 0)
		{
			yaw = 0;
			if (dist[2] > 0)
				pitch = 90;
			else
				pitch = 270;
		}
		else
		{
			yaw = (int) (atan2(dist[1], dist[0]) * 180 / M_PI);
			if (yaw < 0)
				yaw += 360;

			forward = sqrt (dist[0]*dist[0] + dist[1]*dist[1]);
			pitch = (int) (atan2(dist[2], forward) * 180 / M_PI);
			if (pitch < 0)
				pitch += 360;
		}

	// add new entities for the lightning
		VectorCopy (b->start, org);
		d = VectorNormalize(dist);
		while (d > 0)
		{
			ent = CL_NewTempEntity ();
			if (!ent)
				return;
			VectorCopy (org, ent->origin);
			ent->model = b->model;
			ent->angles[0] = pitch;
			ent->angles[1] = yaw;
			ent->angles[2] = rand()%360;

			//johnfitz -- use j instead of using i twice, so we don't corrupt memory
			for (j=0 ; j<3 ; j++)
				org[j] += dist[j]*30;
			d -= 30;
		}
	}
}
