/*
Copyright (C) 1996-2001 Id Software, Inc.
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

#include "quakedef.h"

#include <time.h>	// sysreport: report timestamp

#ifdef __APPLE__
#include <sys/sysctl.h>	// sysreport: hw.model / CPU / RAM probing
#include <fcntl.h>	// sysreport: disk benchmark (open flags, F_NOCACHE)
#include <unistd.h>	// sysreport: read/write/fsync/close
#endif

static void CL_FinishTimeDemo (void);
static void CL_SysReport_Step (void);
static qboolean CL_SysReport_Active (void);

/*
==============================================================================

DEMO CODE

When a demo is playing back, all NET_SendMessages are skipped, and
NET_GetMessages are read from the demo file.

Whenever cl.time gets past the last received message, another message is
read from the demo file.
==============================================================================
*/

// from ProQuake: space to fill out the demo header for record at any time
static byte		*demo_head;
static int		*demo_head_sizes;

/*
==============
CL_ClearSignons
==============
*/
void CL_ClearSignons (void)
{
	VEC_CLEAR (demo_head);
	VEC_CLEAR (demo_head_sizes);
	cls.signon = 0;
}

/*
==============
CL_StopPlayback

Called when a demo file runs out, or the user starts a game
==============
*/
void CL_StopPlayback (void)
{
	if (!cls.demoplayback)
		return;

	fclose (cls.demofile);
	cls.demoplayback = false;
	cls.demopaused = false;
	cls.demofile = NULL;
	cls.state = ca_disconnected;

	if (cls.timedemo)
		CL_FinishTimeDemo ();
}

/*
====================
CL_WriteDemoMessage

Dumps the current net message, prefixed by the length and view angles
====================
*/
static void CL_WriteDemoMessage (void)
{
	int	len;
	int	i;
	float	f;

	len = LittleLong (net_message.cursize);
	fwrite (&len, 4, 1, cls.demofile);
	for (i = 0; i < 3; i++)
	{
		f = LittleFloat (cl.viewangles[i]);
		fwrite (&f, 4, 1, cls.demofile);
	}
	fwrite (net_message.data, net_message.cursize, 1, cls.demofile);
	fflush (cls.demofile);
}

static int CL_GetDemoMessage (void)
{
	int	r, i;
	float	f;

	if (cls.demopaused)
		return 0;

	// decide if it is time to grab the next message
	if (cls.signon == SIGNONS)	// always grab until fully connected
	{
		if (cls.timedemo)
		{
			if (host_framecount == cls.td_lastframe)
				return 0;	// already read this frame's message
			cls.td_lastframe = host_framecount;
		// if this is the second frame, grab the real td_starttime
		// so the bogus time on the first frame doesn't count
			if (host_framecount == cls.td_startframe + 1)
				cls.td_starttime = realtime;
		}
		else if (/* cl.time > 0 && */ cl.time <= cl.mtime[0])
		{
			return 0;	// don't need another message yet
		}
	}

// get the next message
	if (! fread(&net_message.cursize, 4, 1, cls.demofile))
		Sys_Error ("Demo read error");
	VectorCopy (cl.mviewangles[0], cl.mviewangles[1]);
	for (i = 0 ; i < 3 ; i++)
	{
		r = fread (&f, 4, 1, cls.demofile);
		cl.mviewangles[0][i] = LittleFloat (f);
	}

	net_message.cursize = LittleLong (net_message.cursize);
	if (net_message.cursize > MAX_MSGLEN)
		Sys_Error ("Demo message > MAX_MSGLEN");
	r = fread (net_message.data, net_message.cursize, 1, cls.demofile);
	if (r != 1)
	{
		CL_StopPlayback ();
		return 0;
	}

	return 1;
}

/*
====================
CL_GetMessage

Handles recording and playback of demos, on top of NET_ code
====================
*/
int CL_GetMessage (void)
{
	int	r;

	if (cls.demoplayback)
		return CL_GetDemoMessage ();

	while (1)
	{
		r = NET_GetMessage (cls.netcon);

		if (r != 1 && r != 2)
			return r;

	// discard nop keepalive message
		if (net_message.cursize == 1 && net_message.data[0] == svc_nop)
			Con_Printf ("<-- server to client keepalive\n");
		else
			break;
	}

	if (cls.demorecording)
		CL_WriteDemoMessage ();

	if (cls.signon < 2)
	{
	// record messages before full connection, so that a
	// demo record can happen after connection is done
		Vec_Append ((void**)&demo_head, 1, net_message.data, net_message.cursize);
		VEC_PUSH (demo_head_sizes, net_message.cursize);
	}

	return r;
}


/*
====================
CL_Stop_f

stop recording a demo
====================
*/
void CL_Stop_f (void)
{
	if (cmd_source != src_command)
		return;

	if (!cls.demorecording)
	{
		Con_Printf ("Not recording a demo.\n");
		return;
	}

// write a disconnect message to the demo file
	SZ_Clear (&net_message);
	MSG_WriteByte (&net_message, svc_disconnect);
	CL_WriteDemoMessage ();

// finish up
	fclose (cls.demofile);
	cls.demofile = NULL;
	cls.demorecording = false;
	Con_Printf ("Completed demo\n");
	
// ericw -- update demo tab-completion list
	DemoList_Rebuild ();
}

/*
====================
CL_Record_f

record <demoname> <map> [cd track]
====================
*/
void CL_Record_f (void)
{
	int		c;
	char	name[MAX_OSPATH];
	int		track;

	if (cmd_source != src_command)
		return;

	if (cls.demoplayback)
	{
		Con_Printf ("Can't record during demo playback\n");
		return;
	}

	if (cls.demorecording)
		CL_Stop_f();

	c = Cmd_Argc();
	if (c != 2 && c != 3 && c != 4)
	{
		Con_Printf ("record <demoname> [<map> [cd track]]\n");
		return;
	}

	if (strstr(Cmd_Argv(1), ".."))
	{
		Con_Printf ("Relative pathnames are not allowed.\n");
		return;
	}

	if (c == 2 && cls.state == ca_connected)
	{
		if (cls.signon < 2)
		{
			Con_Printf("Can't record - try again when connected\n");
			return;
		}
	}

// write the forced cd track number, or -1
	if (c == 4)
	{
		track = atoi(Cmd_Argv(3));
		Con_Printf ("Forcing CD track to %i\n", cls.forcetrack);
	}
	else
	{
		track = -1;
	}

	q_snprintf (name, sizeof(name), "%s/%s", com_gamedir, Cmd_Argv(1));

// start the map up
	if (c > 2)
	{
		Cmd_ExecuteString ( va("map %s", Cmd_Argv(2)), src_command);
		if (cls.state != ca_connected)
			return;
	}

// open the demo file
	COM_AddExtension (name, ".dem", sizeof(name));

	Con_Printf ("recording to %s.\n", name);
	cls.demofile = fopen (name, "wb");
	if (!cls.demofile)
	{
		Con_Printf ("ERROR: couldn't create %s\n", name);
		return;
	}

	cls.forcetrack = track;
	fprintf (cls.demofile, "%i\n", cls.forcetrack);

	cls.demorecording = true;

	// from ProQuake: initialize the demo file if we're already connected
	if (c == 2 && cls.state == ca_connected)
	{
		static byte tmpbuf[NET_MAXMESSAGE];
		byte *data = net_message.data;
		int cursize = net_message.cursize;
		int maxsize = net_message.maxsize;
		int i, count;

		net_message.data = demo_head;
		for (i = 0, count = VEC_SIZE (demo_head_sizes); i < count; i++)
		{
			net_message.cursize = demo_head_sizes[i];
			CL_WriteDemoMessage ();
			net_message.data += net_message.cursize;
		}

		net_message.data = tmpbuf;
		net_message.maxsize = sizeof (tmpbuf);
		SZ_Clear (&net_message);

		// current names, colors, and frag counts
		for (i = 0; i < cl.maxclients; i++)
		{
			MSG_WriteByte (&net_message, svc_updatename);
			MSG_WriteByte (&net_message, i);
			MSG_WriteString (&net_message, cl.scores[i].name);
			MSG_WriteByte (&net_message, svc_updatefrags);
			MSG_WriteByte (&net_message, i);
			MSG_WriteShort (&net_message, cl.scores[i].frags);
			MSG_WriteByte (&net_message, svc_updatecolors);
			MSG_WriteByte (&net_message, i);
			MSG_WriteByte (&net_message, cl.scores[i].colors);
		}

		// send all current light styles
		for (i = 0; i < MAX_LIGHTSTYLES; i++)
		{
			MSG_WriteByte (&net_message, svc_lightstyle);
			MSG_WriteByte (&net_message, i);
			MSG_WriteString (&net_message, cl_lightstyle[i].map);
		}

		// what about the CD track or SVC fog... future consideration.
		MSG_WriteByte (&net_message, svc_updatestat);
		MSG_WriteByte (&net_message, STAT_TOTALSECRETS);
		MSG_WriteLong (&net_message, cl.stats[STAT_TOTALSECRETS]);

		MSG_WriteByte (&net_message, svc_updatestat);
		MSG_WriteByte (&net_message, STAT_TOTALMONSTERS);
		MSG_WriteLong (&net_message, cl.stats[STAT_TOTALMONSTERS]);

		MSG_WriteByte (&net_message, svc_updatestat);
		MSG_WriteByte (&net_message, STAT_SECRETS);
		MSG_WriteLong (&net_message, cl.stats[STAT_SECRETS]);

		MSG_WriteByte (&net_message, svc_updatestat);
		MSG_WriteByte (&net_message, STAT_MONSTERS);
		MSG_WriteLong (&net_message, cl.stats[STAT_MONSTERS]);

		// view entity
		MSG_WriteByte (&net_message, svc_setview);
		MSG_WriteShort (&net_message, cl.viewentity);

		// signon
		MSG_WriteByte (&net_message, svc_signonnum);
		MSG_WriteByte (&net_message, 3);

		CL_WriteDemoMessage();

		// restore net_message
		net_message.data = data;
		net_message.cursize = cursize;
		net_message.maxsize = maxsize;
	}
}


/*
====================
CL_PlayDemo_f

play [demoname]
====================
*/
void CL_PlayDemo_f (void)
{
	char	name[MAX_OSPATH];

	if (cmd_source != src_command)
		return;

	if (Cmd_Argc() != 2)
	{
		Con_Printf ("playdemo <demoname> : plays a demo\n");
		return;
	}

// disconnect from server
	CL_Disconnect ();

// open the demo file
	q_strlcpy (name, Cmd_Argv(1), sizeof(name));
	COM_AddExtension (name, ".dem", sizeof(name));

	Con_Printf ("Playing demo from %s.\n", name);

	COM_FOpenFile (name, &cls.demofile, NULL);
	if (!cls.demofile)
	{
		Con_Printf ("ERROR: couldn't open %s\n", name);
		cls.demonum = -1;	// stop demo loop
		return;
	}

// ZOID, fscanf is evil
// O.S.: if a space character e.g. 0x20 (' ') follows '\n',
// fscanf skips that byte too and screws up further reads.
//	fscanf (cls.demofile, "%i\n", &cls.forcetrack);
	if (fscanf (cls.demofile, "%i", &cls.forcetrack) != 1 || fgetc (cls.demofile) != '\n')
	{
		fclose (cls.demofile);
		cls.demofile = NULL;
		cls.demonum = -1;	// stop demo loop
		Con_Printf ("ERROR: demo \"%s\" is invalid\n", name);
		return;
	}

	cls.demoplayback = true;
	cls.demopaused = false;
	cls.state = ca_connected;

// get rid of the menu and/or console
	key_dest = key_game;
}

/*
==============================================================================

SYSREPORT

Community spec + benchmark collector. `sysreport` runs the canonical
3-demo x 3-run timedemo grid unattended, gathers the machine's hardware
specs (hw.model / CPU / RAM via sysctl on Apple) plus the live GL driver
strings, and writes one self-contained report to the user's Desktop for
them to email back. This is the in-engine sibling of scripts/bench.sh:
a community member runs one command and ships us everything we need to
mint a per-machine autoexec-<model>.cfg and tune against real fps.

The grid is driven through the command buffer (one `timedemo` queued per
finished run) rather than recursively from CL_FinishTimeDemo, so each
demo's teardown completes before the next loads.
==============================================================================
*/

#define SYSREPORT_NUM_DEMOS	3
#define SYSREPORT_NUM_RUNS	3
static const char * const sysreport_demos[SYSREPORT_NUM_DEMOS] = { "demo1", "demo2", "demo3" };

static qboolean	sysreport_running = false;
static int	sysreport_demo;		// 0..sysreport_ndemos-1
static int	sysreport_run;		// 0..sysreport_runs-1
static int	sysreport_runs = SYSREPORT_NUM_RUNS;	// runs per demo (1..MAX), arg-overridable
static int	sysreport_ndemos = SYSREPORT_NUM_DEMOS;	// demos to run (1..MAX), arg-overridable
static float	sysreport_fps[SYSREPORT_NUM_DEMOS][SYSREPORT_NUM_RUNS];

// result of the timedemo that just finished, stashed by CL_FinishTimeDemo
static float	sysreport_last_fps;

// audio volumes saved at sysreport start, restored at finish (the benchmark
// runs silent regardless of how the engine was launched)
static float	sysreport_saved_volume;
static float	sysreport_saved_bgmvolume;

static qboolean CL_SysReport_Active (void)
{
	return sysreport_running;
}

// end a sysreport run (normal completion or abort): restore audio + clear flag
static void CL_SysReport_Finish (void)
{
	sysreport_running = false;
	Cvar_SetValue ("volume", sysreport_saved_volume);
	Cvar_SetValue ("bgmvolume", sysreport_saved_bgmvolume);
}

static float SR_MedianN (const float *v, int n)
{
	float	a[SYSREPORT_NUM_RUNS];
	int	i, j;

	if (n <= 0)
		return 0.0f;
	if (n > SYSREPORT_NUM_RUNS)
		n = SYSREPORT_NUM_RUNS;
	for (i = 0; i < n; i++)
		a[i] = v[i];
	for (i = 1; i < n; i++)	// insertion sort
	{
		float k = a[i];
		j = i - 1;
		while (j >= 0 && a[j] > k) { a[j+1] = a[j]; j--; }
		a[j+1] = k;
	}
	if (n & 1)
		return a[n/2];
	return (a[n/2 - 1] + a[n/2]) * 0.5f;
}

static qboolean SR_CopyFile (const char *src, const char *dst)
{
	FILE	*in, *out;
	char	buf[8192];
	size_t	n;

	in = fopen (src, "rb");
	if (!in)
		return false;
	out = fopen (dst, "wb");
	if (!out)
	{
		fclose (in);
		return false;
	}
	while ((n = fread (buf, 1, sizeof(buf), in)) > 0)
	{
		if (fwrite (buf, 1, n, out) != n)
			break;
	}
	fclose (in);
	fclose (out);
	return true;
}

#ifdef __APPLE__
static void SR_SysctlStr (const char *name, char *out, size_t outlen)
{
	size_t len = outlen;
	out[0] = '\0';
	if (sysctlbyname (name, out, &len, NULL, 0) != 0)
		out[0] = '\0';
	out[outlen - 1] = '\0';
}

static qboolean SR_SysctlU64 (const char *name, unsigned long long *v)
{
	uint64_t val = 0;
	size_t len = sizeof(val);
	if (sysctlbyname (name, &val, &len, NULL, 0) != 0)
		return false;
	*v = (unsigned long long) val;
	return true;
}

static qboolean SR_SysctlInt (const char *name, int *v)
{
	int val = 0;
	size_t len = sizeof(val);
	if (sysctlbyname (name, &val, &len, NULL, 0) != 0)
		return false;
	*v = val;
	return true;
}

// Pull the marketing OS version (e.g. "10.4.11") out of the system plist.
// It's XML text on every OS X release, so a naive key->string scan is robust
// without dragging in a plist parser.
static void SR_OSVersion (char *out, size_t outlen)
{
	FILE *f;
	char buf[8192];
	size_t n;
	const char *k, *p, *e;

	out[0] = '\0';
	f = fopen ("/System/Library/CoreServices/SystemVersion.plist", "rb");
	if (!f)
		return;
	n = fread (buf, 1, sizeof(buf) - 1, f);
	fclose (f);
	buf[n] = '\0';

	k = strstr (buf, "ProductVersion");
	if (!k)
		return;
	p = strstr (k, "<string>");
	if (!p)
		return;
	p += 8;
	e = strstr (p, "</string>");
	if (!e)
		return;
	n = (size_t)(e - p);
	if (n >= outlen)
		n = outlen - 1;
	memcpy (out, p, n);
	out[n] = '\0';
}

// Best-effort GPU detail (chipset + VRAM + native panel resolution) from
// system_profiler. GL_RENDERER already names the GPU, but VRAM drives
// texture/picmip tuning, so it's worth the few seconds. Fails silently to an
// empty string on machines/SDKs where the keys differ or the tool is absent.
static void SR_GPUInfo (char *out, size_t outlen)
{
	FILE	*p;
	char	line[256];

	out[0] = '\0';
	p = popen ("system_profiler SPDisplaysDataType 2>/dev/null", "r");
	if (!p)
		return;
	while (fgets (line, sizeof(line), p))
	{
		if (strstr (line, "VRAM") || strstr (line, "Chipset") || strstr (line, "Resolution"))
		{
			char *s = line, *nl;
			while (*s == ' ' || *s == '\t')
				s++;
			nl = strchr (s, '\n');
			if (nl)
				*nl = '\0';
			if (out[0])
				q_strlcat (out, " | ", outlen);
			q_strlcat (out, s, outlen);
		}
	}
	pclose (p);
}

// trim trailing whitespace in place
static void SR_RTrim (char *s)
{
	size_t n = strlen (s);
	while (n > 0 && (s[n-1] == ' ' || s[n-1] == '\t' || s[n-1] == '\r' || s[n-1] == '\n'))
		s[--n] = '\0';
}

// Storage identity from system_profiler: the boot drive's Model string (often
// reveals an SSD by name even on Tiger, which has no Medium Type field) and the
// explicit Medium Type when a newer OS provides it. Optical drives are skipped.
static void SR_StorageInfo (char *model_out, size_t model_len, char *medium_out, size_t medium_len)
{
	FILE	*p;
	char	line[256];

	model_out[0] = '\0';
	medium_out[0] = '\0';
	p = popen ("system_profiler SPSerialATADataType SPParallelATADataType SPNVMeDataType 2>/dev/null", "r");
	if (!p)
		return;
	while (fgets (line, sizeof(line), p))
	{
		char *c, *nl;
		if (!model_out[0] && (c = strstr (line, "Model:")))
		{
			c += 6;
			while (*c == ' ' || *c == '\t') c++;
			nl = strchr (c, '\n'); if (nl) *nl = '\0';
			// skip optical drives -- we want the boot disk
			if (!strstr (c, "CD") && !strstr (c, "DVD") && !strstr (c, "RW") &&
			    !strstr (c, "Optical") && !strstr (c, "SuperDrive"))
			{
				q_strlcpy (model_out, c, model_len);
				SR_RTrim (model_out);
			}
		}
		if (!medium_out[0] && (strstr (line, "Medium Type:") || strstr (line, "Solid State:")))
		{
			c = strchr (line, ':');
			if (c)
			{
				c++;
				while (*c == ' ' || *c == '\t') c++;
				nl = strchr (c, '\n'); if (nl) *nl = '\0';
				q_strlcpy (medium_out, c, medium_len);
				SR_RTrim (medium_out);
			}
		}
	}
	pclose (p);
}

// Disk benchmark on a temp file, all uncached (F_NOCACHE bypasses the buffer
// cache so reads hit the device, not RAM):
//   *wmb / *rmb  -- sequential write / read MB/s
//   *iops        -- random 4K read IOPS, the robust SSD-vs-spinning signal
//                   (spinning disks are seek-bound ~100-250 IOPS; SSDs do
//                    thousands, independent of the old ATA bus's bandwidth).
static void SR_DiskBench (double *wmb, double *rmb, double *iops)
{
	enum { CHUNK = 1024 * 1024, NCHUNKS = 32, NRAND = 400 };	// 32 MB working set
	char	tmppath[MAX_OSPATH];
	char	*buf;
	char	small[4096];
	int	fd, i;
	double	t0, t1;
	double	totalmb = (double)NCHUNKS;

	*wmb = *rmb = *iops = 0.0;
	buf = (char *) malloc (CHUNK);
	if (!buf)
		return;
	memset (buf, 0xA5, CHUNK);

	q_snprintf (tmppath, sizeof(tmppath), "%s/qs_diskbench.tmp", com_basedir);

	fd = open (tmppath, O_WRONLY | O_CREAT | O_TRUNC, 0666);
	if (fd != -1)
	{
#ifdef F_NOCACHE
		fcntl (fd, F_NOCACHE, 1);
#endif
		t0 = Sys_DoubleTime ();
		for (i = 0; i < NCHUNKS; i++)
			if (write (fd, buf, CHUNK) != (ssize_t)CHUNK)
				break;
		fsync (fd);
		t1 = Sys_DoubleTime ();
		close (fd);
		if (t1 > t0)
			*wmb = totalmb / (t1 - t0);
	}

	fd = open (tmppath, O_RDONLY);
	if (fd != -1)
	{
#ifdef F_NOCACHE
		fcntl (fd, F_NOCACHE, 1);
#endif
		t0 = Sys_DoubleTime ();
		while (read (fd, buf, CHUNK) > 0)
			;
		t1 = Sys_DoubleTime ();
		if (t1 > t0)
			*rmb = totalmb / (t1 - t0);

		// random 4K reads: scatter offsets with a Weyl-style stride (no rand()
		// needed -- deterministic, well-distributed across the 32 MB file).
		{
			off_t	span = (off_t)NCHUNKS * CHUNK - sizeof(small);
			unsigned hash = 0;
			int	ok = 0;

			t0 = Sys_DoubleTime ();
			for (i = 0; i < NRAND; i++)
			{
				off_t off;
				hash += 2654435761u;			// Knuth multiplicative step
				off = (off_t)(hash % (unsigned)span) & ~((off_t)4095);
				if (lseek (fd, off, SEEK_SET) == (off_t)-1)
					break;
				if (read (fd, small, sizeof(small)) == (ssize_t)sizeof(small))
					ok++;
			}
			t1 = Sys_DoubleTime ();
			if (t1 > t0 && ok > 0)
				*iops = ok / (t1 - t0);
		}
		close (fd);
	}

	remove (tmppath);
	free (buf);
}
#endif	// __APPLE__

// dump one cvar's current value, skipping cvars absent from this build so the
// same settings list is safe across engine revisions.
static void SR_WriteCvar (FILE *f, const char *name)
{
	cvar_t *c = Cvar_FindVar (name);
	if (c)
		fprintf (f, "  %-24s %s\n", name, c->string);
}

// The render/display/perf knobs the per-machine autoexec cfgs tune -- this is
// "what settings produced these fps". Keep in sync with scripts/bundle/autoexec-*.cfg.
static const char * const sysreport_cvars[] = {
	"vid_width", "vid_height", "vid_bpp", "vid_fullscreen", "vid_desktopfullscreen",
	"vid_fsaa", "vid_vsync", "host_maxfps", "viewsize",
	"gl_texturemode", "gl_texture_anisotropy", "gl_texture_lodbias",
	"gl_clear", "gl_zfix", "gl_subdivide_size", "gl_aliasstate_cache",
	"r_oldwater", "r_waterwarp", "r_wateralpha", "r_lavaalpha", "r_slimealpha", "r_telealpha",
	"r_shadows", "r_shadow_distance", "r_dynamic_distance",
	"r_particles", "r_lerplightstyles",
	"r_emissive_lights", "r_emissive_lights_radius", "r_emissive_lights_max",
};

/*
====================
CL_SysReport_Write

Collect specs + the captured fps grid and write the report to disk.
====================
*/
static void CL_SysReport_Write (void)
{
	char	path[MAX_OSPATH], logpath[MAX_OSPATH];
	const char *logsrc;
	char	model[128], cpubrand[160], osver[64], modelclean[128];
	char	osrelease[64], gpuinfo[512];
	char	drivemodel[128], drivemedium[64];
	double	diskw = 0.0, diskr = 0.0, diskiops = 0.0;
	char	res[32];
	unsigned long long memsize = 0, cpufreq = 0, busfreq = 0;
	int	ncpu = 0, altivec = 0, l2cache = 0;
	const char *glvendor = NULL, *glrenderer = NULL, *glversion = NULL;
	size_t	ci;
	time_t	now;
	char	tstamp[32];
	FILE	*f;
	int	i;

	VID_GetGLStrings (&glvendor, &glrenderer, &glversion);
	if (!glvendor)   glvendor = "unknown";
	if (!glrenderer) glrenderer = "unknown";
	if (!glversion)  glversion = "unknown";

	q_strlcpy (model, "unknown", sizeof(model));
	cpubrand[0] = '\0';
	osver[0] = '\0';
	osrelease[0] = '\0';
	gpuinfo[0] = '\0';
	drivemodel[0] = '\0';
	drivemedium[0] = '\0';

#ifdef __APPLE__
	SR_SysctlStr ("hw.model", model, sizeof(model));
	if (!model[0])
		q_strlcpy (model, "unknown", sizeof(model));
	SR_SysctlStr ("machdep.cpu.brand_string", cpubrand, sizeof(cpubrand));
	SR_SysctlU64 ("hw.memsize", &memsize);
	SR_SysctlU64 ("hw.cpufrequency", &cpufreq);
	SR_SysctlU64 ("hw.busfrequency", &busfreq);
	SR_SysctlInt ("hw.ncpu", &ncpu);
	SR_SysctlInt ("hw.l2cachesize", &l2cache);
	SR_SysctlInt ("hw.optional.altivec", &altivec);
	SR_SysctlStr ("kern.osrelease", osrelease, sizeof(osrelease));
	SR_OSVersion (osver, sizeof(osver));
	SR_GPUInfo (gpuinfo, sizeof(gpuinfo));
	SR_StorageInfo (drivemodel, sizeof(drivemodel), drivemedium, sizeof(drivemedium));
	SR_DiskBench (&diskw, &diskr, &diskiops);
#endif
	if (!cpubrand[0])
		q_strlcpy (cpubrand, "n/a", sizeof(cpubrand));
	if (!osver[0])
		q_strlcpy (osver, "n/a", sizeof(osver));

	// sanitize the model for use in a filename (PowerMac8,2 -> PowerMac8-2)
	q_strlcpy (modelclean, model, sizeof(modelclean));
	for (i = 0; modelclean[i]; i++)
	{
		char c = modelclean[i];
		if (c == ',' || c == ' ' || c == '/' || c == '\\')
			modelclean[i] = '-';
	}

	now = time (NULL);
	strftime (tstamp, sizeof(tstamp), "%Y-%m-%dT%H:%M:%SZ", gmtime (&now));
	q_snprintf (res, sizeof(res), "%dx%d", glwidth, glheight);

#ifdef __APPLE__
	{
		const char *home = getenv ("HOME");
		if (home && home[0])
		{
			q_snprintf (path,    sizeof(path),    "%s/Desktop/quakespasm-sysreport-%s.txt", home, modelclean);
			q_snprintf (logpath, sizeof(logpath), "%s/Desktop/quakespasm-sysreport-%s.log", home, modelclean);
		}
		else
		{
			q_snprintf (path,    sizeof(path),    "quakespasm-sysreport-%s.txt", modelclean);
			q_snprintf (logpath, sizeof(logpath), "quakespasm-sysreport-%s.log", modelclean);
		}
	}
#else
	q_snprintf (path,    sizeof(path),    "quakespasm-sysreport-%s.txt", modelclean);
	q_snprintf (logpath, sizeof(logpath), "quakespasm-sysreport-%s.log", modelclean);
#endif

	f = fopen (path, "w");
	if (!f)
	{
		Con_Printf ("sysreport: FAILED to write %s\n", path);
		return;
	}

	fprintf (f, "QuakeSpasm sysreport\n");
	fprintf (f, "====================\n");
	fprintf (f, "engine     : QuakeSpasm %s\n", QUAKESPASM_VER_STRING);
	fprintf (f, "generated  : %s\n\n", tstamp);

	fprintf (f, "HARDWARE\n");
	fprintf (f, "  hw.model : %s\n", model);
	fprintf (f, "  cpu      : %s\n", cpubrand);
	fprintf (f, "  cpu cores: %d\n", ncpu);
	if (cpufreq)
		fprintf (f, "  cpu clock: %.0f MHz\n", cpufreq / 1000000.0);
	if (busfreq)
		fprintf (f, "  bus clock: %.0f MHz\n", busfreq / 1000000.0);
	if (l2cache)
		fprintf (f, "  l2 cache : %d KB\n", l2cache / 1024);
	if (memsize)
		fprintf (f, "  ram      : %.0f MB\n", memsize / (1024.0 * 1024.0));
	fprintf (f, "  altivec  : %s\n", altivec ? "yes" : "no");
	fprintf (f, "  os       : %s%s%s\n\n", osver,
		osrelease[0] ? " / Darwin " : "", osrelease);

	fprintf (f, "GRAPHICS\n");
	fprintf (f, "  GL_VENDOR  : %s\n", glvendor);
	fprintf (f, "  GL_RENDERER: %s\n", glrenderer);
	fprintf (f, "  GL_VERSION : %s\n", glversion);
	fprintf (f, "  bench res  : %s\n", res);
	if (gpuinfo[0])
		fprintf (f, "  display    : %s\n", gpuinfo);
	fprintf (f, "\n");

	// storage: drive identity + crude sequential throughput. SSD vs spinning
	// from Medium Type when the OS reports it, otherwise inferred from speed
	// (and the drive Model often names the SSD outright, e.g. on Tiger).
	if (drivemodel[0] || drivemedium[0] || diskw > 0.0 || diskr > 0.0)
	{
		const char *est;
		if (drivemedium[0])
			est = drivemedium;			// OS told us outright (10.7+)
		else if (diskiops > 600.0)
			est = "likely SSD (high random-read IOPS)";
		else if (diskiops > 0.0)
			est = "likely spinning HDD (seek-bound IOPS)";
		else
			est = "unknown (see drive model)";

		fprintf (f, "STORAGE\n");
		if (drivemodel[0])
			fprintf (f, "  drive    : %s\n", drivemodel);
		fprintf (f, "  type     : %s\n", est);
		if (diskw > 0.0)
			fprintf (f, "  seq write: %.1f MB/s\n", diskw);
		if (diskr > 0.0)
			fprintf (f, "  seq read : %.1f MB/s\n", diskr);
		if (diskiops > 0.0)
			fprintf (f, "  rand read: %.0f IOPS (4K)\n", diskiops);
		fprintf (f, "\n");
	}

	// what settings the benchmark actually ran with -- the per-machine
	// autoexec values in force at sysreport time. fps is only meaningful
	// alongside these.
	fprintf (f, "SETTINGS (cvar values during benchmark)\n");
	for (ci = 0; ci < sizeof(sysreport_cvars)/sizeof(sysreport_cvars[0]); ci++)
		SR_WriteCvar (f, sysreport_cvars[ci]);
	fprintf (f, "\n");

	fprintf (f, "BENCHMARK (%d demos x %d runs, fps)\n", sysreport_ndemos, sysreport_runs);
	for (i = 0; i < sysreport_ndemos; i++)
	{
		int r;
		float med = SR_MedianN (sysreport_fps[i], sysreport_runs);
		fprintf (f, "  %-6s:", sysreport_demos[i]);
		for (r = 0; r < sysreport_runs; r++)
			fprintf (f, " %6.1f", sysreport_fps[i][r]);
		fprintf (f, "   median %6.1f\n", med);
	}

	// results.csv-compatible block (matches benchmarks/results.csv schema) so
	// the rows paste straight into the analysis pipeline. machine = hw.model.
	fprintf (f, "\nCSV (paste into benchmarks/results.csv)\n");
	fprintf (f, "timestamp,commit,machine,demo,res,run1_fps,run2_fps,run3_fps,median_fps,extra_cvars,rendered_res\n");
	for (i = 0; i < sysreport_ndemos; i++)
	{
		int r;
		float med = SR_MedianN (sysreport_fps[i], sysreport_runs);
		// quote model: hw.model values like "PowerMac8,2" contain a comma
		// that would otherwise split into an extra CSV column.
		fprintf (f, "%s,qs-%s,\"%s\",%s,%s,",
			tstamp, QUAKESPASM_VER_STRING, model, sysreport_demos[i], res);
		for (r = 0; r < SYSREPORT_NUM_RUNS; r++)	// keep 3 run columns; NA past the run count
		{
			if (r < sysreport_runs)
				fprintf (f, "%.1f,", sysreport_fps[i][r]);
			else
				fprintf (f, "NA,");
		}
		fprintf (f, "%.2f,\"\",%s\n", med, res);
	}

	fclose (f);

	Con_Printf ("\nsysreport: written to\n  %s\n", path);

	// drop a copy of the console log (covering all runs) next to the report.
	logsrc = Con_LogFilename ();
	if (logsrc && SR_CopyFile (logsrc, logpath))
		Con_Printf ("sysreport: console log copied to\n  %s\n", logpath);

	Con_Printf ("sysreport: email both files so your machine can be tuned. Thanks!\n");

#ifdef __APPLE__
	// reveal the report in Finder so a non-technical user finds it immediately.
	{
		char cmd[MAX_OSPATH + 16];
		q_snprintf (cmd, sizeof(cmd), "open -R \"%s\" &", path);
		system (cmd);
	}
#endif
}

/*
====================
CL_SysReport_Step

Record the run that just finished and either queue the next timedemo or,
when the grid is complete, write the report.
====================
*/
static void CL_SysReport_Step (void)
{
	sysreport_fps[sysreport_demo][sysreport_run] = sysreport_last_fps;
	Con_Printf ("sysreport: %s run %d/%d = %.1f fps\n",
		sysreport_demos[sysreport_demo], sysreport_run + 1, sysreport_runs, sysreport_last_fps);

	if (++sysreport_run >= sysreport_runs)
	{
		sysreport_run = 0;
		sysreport_demo++;
	}

	if (sysreport_demo >= sysreport_ndemos)
	{
		CL_SysReport_Write ();
		CL_SysReport_Finish ();
		return;
	}

	Cbuf_AddText (va("timedemo %s\n", sysreport_demos[sysreport_demo]));
}

/*
====================
CL_SysReport_f

sysreport : collect machine specs + run the timedemo grid, write to Desktop
====================
*/
void CL_SysReport_f (void)
{
	if (cmd_source != src_command)
		return;

	if (sysreport_running)
	{
		Con_Printf ("sysreport: already running\n");
		return;
	}

	// optional args: sysreport [runs] [ndemos] -- defaults to the full grid.
	// e.g. `sysreport 1 1` is a fast single-demo smoke test.
	sysreport_runs = SYSREPORT_NUM_RUNS;
	sysreport_ndemos = SYSREPORT_NUM_DEMOS;
	if (Cmd_Argc() >= 2)
		sysreport_runs = atoi (Cmd_Argv(1));
	if (Cmd_Argc() >= 3)
		sysreport_ndemos = atoi (Cmd_Argv(2));
	sysreport_runs   = CLAMP (1, sysreport_runs,   SYSREPORT_NUM_RUNS);
	sysreport_ndemos = CLAMP (1, sysreport_ndemos, SYSREPORT_NUM_DEMOS);

	memset (sysreport_fps, 0, sizeof(sysreport_fps));
	sysreport_demo = 0;
	sysreport_run = 0;
	sysreport_running = true;

	// run the benchmark silent: save + zero the audio volumes (restored in
	// CL_SysReport_Finish). Keeps fps clean and spares the user the demo audio.
	sysreport_saved_volume = Cvar_VariableValue ("volume");
	sysreport_saved_bgmvolume = Cvar_VariableValue ("bgmvolume");
	Cvar_SetValue ("volume", 0);
	Cvar_SetValue ("bgmvolume", 0);

	// clear/open the console log so the Desktop copy covers exactly this run
	Con_LogStart ();

	Con_Printf ("sysreport: benchmarking %d demos x %d runs -- do not touch the controls...\n",
		sysreport_ndemos, sysreport_runs);

	Cbuf_AddText (va("timedemo %s\n", sysreport_demos[0]));
}

/*
====================
CL_FinishTimeDemo

====================
*/
static void CL_FinishTimeDemo (void)
{
	int	frames;
	float	time;

	cls.timedemo = false;

// the first frame didn't count
	frames = (host_framecount - cls.td_startframe) - 1;
	time = realtime - cls.td_starttime;
	if (!time)
		time = 1;
	Con_Printf ("%i frames %5.1f seconds %5.1f fps\n", frames, time, frames/time);
	R_DecalStats_Report ();	// no-op unless r_decal_stats is set

	sysreport_last_fps = frames / time;
	if (CL_SysReport_Active ())
		CL_SysReport_Step ();
}

/*
====================
CL_TimeDemo_f

timedemo [demoname]
====================
*/
void CL_TimeDemo_f (void)
{
	if (cmd_source != src_command)
		return;

	if (Cmd_Argc() != 2)
	{
		Con_Printf ("timedemo <demoname> : gets demo speeds\n");
		return;
	}

	CL_PlayDemo_f ();
	if (!cls.demofile)
	{
		// a sysreport grid can't continue if a demo is missing (e.g. the
		// user has no pak0.pak demos): bail out of the run instead of
		// stalling forever waiting for a CL_FinishTimeDemo that won't come.
		if (CL_SysReport_Active ())
		{
			CL_SysReport_Finish ();
			Con_Printf ("sysreport: aborted -- demo '%s' not found (need id1/pak0.pak)\n", Cmd_Argv(1));
		}
		return;
	}

// cls.td_starttime will be grabbed at the second frame of the demo, so
// all the loading time doesn't get counted

	cls.timedemo = true;
	cls.td_startframe = host_framecount;
	cls.td_lastframe = -1;	// get a new message this frame

	R_DecalStats_Reset ();	// counters cover exactly this run
}

