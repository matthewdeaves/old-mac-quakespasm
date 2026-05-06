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
//gl_warp.c -- warping animation support

#include "quakedef.h"

extern cvar_t r_drawflat;

// r_oldwater values:
//   0 = always new water (screen-copy refraction)
//   1 = always classic warped water
//   2 = auto: classic above 640x480, new at/below. Workaround for GPUs
//       where the screen-copy pass misbehaves at higher resolutions
//       (e.g. ATI Rage 128 + 1024x768 → bright-blue water tint bug).
cvar_t r_oldwater = {"r_oldwater", "0", CVAR_ARCHIVE};
cvar_t r_waterquality = {"r_waterquality", "8", CVAR_NONE};
cvar_t r_waterwarp = {"r_waterwarp", "1", CVAR_NONE};

qboolean R_OldWaterEffective (void)
{
	int v = (int)r_oldwater.value;
	if (v <= 0) return false;
	if (v == 1) return true;
	return (vid.width > 640 || vid.height > 480);
}

int gl_warpimagesize;
float load_subdivide_size; //johnfitz -- remember what subdivide_size value was when this map was loaded

static const float	turbsin[] = {
#include "gl_warp_sin.h"
};

#define WARPCALC(s,t) ((s + turbsin[(int)((t*2)+(cl.time*(128.0/M_PI))) & 255]) * (1.0/64)) //johnfitz -- correct warp
#define WARPCALC2(s,t) ((s + turbsin[(int)((t*0.125+cl.time)*(128.0/M_PI)) & 255]) * (1.0/64)) //johnfitz -- old warp

//==============================================================================
//
//  OLD-STYLE WATER
//
//==============================================================================

static msurface_t	*warpface;

cvar_t gl_subdivide_size = {"gl_subdivide_size", "128", CVAR_ARCHIVE};

static void BoundPoly (int numverts, float *verts, vec3_t mins, vec3_t maxs)
{
	int		i, j;
	float	*v;

	mins[0] = mins[1] = mins[2] = FLT_MAX;
	maxs[0] = maxs[1] = maxs[2] = -FLT_MAX;
	v = verts;
	for (i=0 ; i<numverts ; i++)
		for (j=0 ; j<3 ; j++, v++)
		{
			if (*v < mins[j])
				mins[j] = *v;
			if (*v > maxs[j])
				maxs[j] = *v;
		}
}

static void SubdividePolygon (int numverts, float *verts)
{
	int		i, j, k;
	vec3_t	mins, maxs;
	float	m;
	float	*v;
	vec3_t	front[64], back[64];
	int		f, b;
	float	dist[64];
	float	frac;
	glpoly_t	*poly;
	float	s, t;

	if (numverts > 60)
		Sys_Error ("SubdividePolygon: numverts = %i", numverts);

	BoundPoly (numverts, verts, mins, maxs);

	for (i=0 ; i<3 ; i++)
	{
		m = (mins[i] + maxs[i]) * 0.5;
		m = gl_subdivide_size.value * floor (m/gl_subdivide_size.value + 0.5);
		if (maxs[i] - m < 8)
			continue;
		if (m - mins[i] < 8)
			continue;

		// cut it
		v = verts + i;
		for (j=0 ; j<numverts ; j++, v+= 3)
			dist[j] = *v - m;

		// wrap cases
		dist[j] = dist[0];
		v-=i;
		VectorCopy (verts, v);

		f = b = 0;
		v = verts;
		for (j=0 ; j<numverts ; j++, v+= 3)
		{
			if (dist[j] >= 0)
			{
				VectorCopy (v, front[f]);
				f++;
			}
			if (dist[j] <= 0)
			{
				VectorCopy (v, back[b]);
				b++;
			}
			if (dist[j] == 0 || dist[j+1] == 0)
				continue;
			if ( (dist[j] > 0) != (dist[j+1] > 0) )
			{
				// clip point
				frac = dist[j] / (dist[j] - dist[j+1]);
				for (k=0 ; k<3 ; k++)
					front[f][k] = back[b][k] = v[k] + frac*(v[3+k] - v[k]);
				f++;
				b++;
			}
		}

		SubdividePolygon (f, front[0]);
		SubdividePolygon (b, back[0]);
		return;
	}

	poly = (glpoly_t *) Hunk_Alloc (sizeof(glpoly_t) + (numverts-4) * VERTEXSIZE*sizeof(float));
	poly->next = warpface->polys->next;
	warpface->polys->next = poly;
	poly->numverts = numverts;
	for (i=0 ; i<numverts ; i++, verts+= 3)
	{
		VectorCopy (verts, poly->verts[i]);
		s = DotProduct (verts, warpface->texinfo->vecs[0]);
		t = DotProduct (verts, warpface->texinfo->vecs[1]);
		poly->verts[i][3] = s;
		poly->verts[i][4] = t;
	}
}

/*
================
GL_SubdivideSurface
================
*/
void GL_SubdivideSurface (msurface_t *fa)
{
	vec3_t	verts[64];
	int		i;

	if (fa->polys->numverts > 64)
		Sys_Error ("GL_SubdivideSurface: numverts = %i", fa->polys->numverts);

	warpface = fa;

	//the first poly in the chain is the undivided poly for newwater rendering.
	//grab the verts from that.
	for (i=0; i<fa->polys->numverts; i++)
		VectorCopy (fa->polys->verts[i], verts[i]);

	SubdividePolygon (fa->polys->numverts, verts[0]);
}

/*
================
DrawWaterPoly -- johnfitz
PPC port -- client vertex arrays. Texcoords mutate per draw (WARPCALC),
so we can't point GL at glpoly_t::verts directly the way DrawGLPoly does.
Use a per-call C99 VLA so the warp scratch always tracks p->numverts —
gl_subdivide_size is a user-tunable cvar with no hard cap, and dropping
a draw to fit a fixed buffer would leave visible holes in water.
================
*/
void DrawWaterPoly (glpoly_t *p)
{
	float	st[p->numverts * 2];
	float	*v;
	int		i;

	v = p->verts[0];
	if (load_subdivide_size > 48)
	{
		for (i = 0; i < p->numverts; i++, v += VERTEXSIZE)
		{
			st[i*2+0] = WARPCALC2(v[3], v[4]);
			st[i*2+1] = WARPCALC2(v[4], v[3]);
		}
	}
	else
	{
		for (i = 0; i < p->numverts; i++, v += VERTEXSIZE)
		{
			st[i*2+0] = WARPCALC(v[3], v[4]);
			st[i*2+1] = WARPCALC(v[4], v[3]);
		}
	}

	glVertexPointer (3, GL_FLOAT, VERTEXSIZE*sizeof(float), &p->verts[0][0]);
	glTexCoordPointer (2, GL_FLOAT, 0, st);
	glEnableClientState (GL_VERTEX_ARRAY);
	glEnableClientState (GL_TEXTURE_COORD_ARRAY);
	glDrawArrays (GL_POLYGON, 0, p->numverts);
	glDisableClientState (GL_TEXTURE_COORD_ARRAY);
	glDisableClientState (GL_VERTEX_ARRAY);
}

//==============================================================================
//
//  RENDER-TO-FRAMEBUFFER WATER
//
//==============================================================================

/*
=============
R_UpdateWarpTextures -- johnfitz -- each frame, update warping textures
=============
*/
#ifdef __WATCOMC__ /* OW1.9 doesn't have floorf() */
#define floorf(_val)		(float)floor((_val))
#endif
void R_UpdateWarpTextures (void)
{
	texture_t *tx;
	int i;
	float x, y, x2, warptess;

	if (R_OldWaterEffective() || cl.paused || r_drawflat_cheatsafe || r_lightmap_cheatsafe)
		return;

	warptess = 128.0f/CLAMP (3.0f, floorf(r_waterquality.value), 64.0f);

	for (i=0; i<cl.worldmodel->numtextures; i++)
	{
		if (!(tx = cl.worldmodel->textures[i]))
			continue;

		if (!tx->update_warp)
			continue;

		//render warp
		GL_SetCanvas (CANVAS_WARPIMAGE);
		GL_Bind (tx->gltexture);
		for (x=0.0; x<128.0; x=x2)
		{
			x2 = x + warptess;
			glBegin (GL_TRIANGLE_STRIP);
			for (y=0.0; y<128.01; y+=warptess) // .01 for rounding errors
			{
				glTexCoord2f (WARPCALC(x,y), WARPCALC(y,x));
				glVertex2f (x,y);
				glTexCoord2f (WARPCALC(x2,y), WARPCALC(y,x2));
				glVertex2f (x2,y);
			}
			glEnd();
		}

		//copy to texture
		GL_Bind (tx->warpimage);
		glCopyTexSubImage2D (GL_TEXTURE_2D, 0, 0, 0, glx, gly+glheight-gl_warpimagesize, gl_warpimagesize, gl_warpimagesize);
		if (GL_GenerateMipmap)
			GL_GenerateMipmap (GL_TEXTURE_2D);

		tx->update_warp = false;
	}

	// ericw -- workaround for osx 10.6 driver bug when using FSAA. R_Clear only clears the warpimage part of the screen.
	GL_SetCanvas(CANVAS_DEFAULT);

	//if warp render went down into sbar territory, we need to be sure to refresh it next frame
	if (gl_warpimagesize + sb_lines > glheight)
		Sbar_Changed ();

	//if viewsize is less than 100, we need to redraw the frame around the viewport
	scr_tileclear_updates = 0;
}
