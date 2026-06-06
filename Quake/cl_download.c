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

// cl_download.c -- DarkPlaces-style in-protocol file download (client side).
// Ported from QuakeSpasm-Spiked (Shpoike/Quakespasm, branch qsrebase).
// Wire-protocol values 50/51 match QSS/DP for interoperability.

#include "quakedef.h"

// ============================================================
// Internal helpers
// ============================================================

/*
CL_StopDownload
Abort the active download and clean up temp file.
*/
void CL_StopDownload (void)
{
	if (cls.download.file)
	{
		fclose (cls.download.file);
		cls.download.file = NULL;
	}
	if (cls.download.temp[0])
	{
		remove (cls.download.temp);
		cls.download.temp[0] = 0;
	}
	cls.download.active = false;
	cls.download.current[0] = 0;
	cls.download.size = 0;
}

// ============================================================
// Stuffcmd handlers registered by CL_Download_Init
// ============================================================

/*
CL_ServerExtension_Download_f
Stuffcmd: "cl_serverextension_download 1"
Sets cl.protocol_dpdownload so CL_CheckDownloads knows the server will serve files.
*/
static void CL_ServerExtension_Download_f (void)
{
	if (Cmd_Argc() > 1 && atoi(Cmd_Argv(1)) == 1)
		cl.protocol_dpdownload = true;
}

/*
CL_Download_Begin_f
Stuffcmd: "cl_downloadbegin SIZE \"NAME\""
SIZE < 0 means the server refused the file (not found, not allowed, etc.).
*/
static void CL_Download_Begin_f (void)
{
	int	size;
	const char *name;

	size = atoi(Cmd_Argv(1));
	name = Cmd_Argv(2);

	if (!cls.download.active)
	{
		Con_DPrintf ("cl_downloadbegin: no pending download\n");
		return;
	}

	if (q_strcasecmp(name, cls.download.current))
	{
		Con_DPrintf ("cl_downloadbegin: name mismatch (%s vs %s)\n",
		             name, cls.download.current);
		CL_StopDownload ();
		CL_CheckDownloads ();
		return;
	}

	// SECURITY: the name arrives via server stuffcmd — re-validate before we
	// build a filesystem path from it (defense in depth; CL_CheckDownloads
	// already screened cls.download.current).
	if (!COM_DownloadNameOkay (name))
	{
		Con_Printf ("Refusing unsafe download name: %s\n", name);
		CL_StopDownload ();
		CL_CheckDownloads ();
		return;
	}

	if (size < 0)
	{
		// Server refused or file not found.
		Con_DPrintf ("Server refused download of %s\n", name);
		CL_StopDownload ();
		// CL_CheckDownloads already advanced the cursor before queuing the
		// request, so calling it again moves to the next missing file.
		CL_CheckDownloads ();
		return;
	}

	// SECURITY: cap the server-declared size (matches the server-side serve cap)
	// so a hostile server can't make us allocate/write an enormous temp file.
	if (size > 50*1024*1024)
	{
		Con_Printf ("Refusing oversized download (%d bytes): %s\n", size, name);
		CL_StopDownload ();
		CL_CheckDownloads ();
		return;
	}

	cls.download.size = size;

	// Open temp file for writing.
	q_snprintf (cls.download.temp, sizeof(cls.download.temp),
	            "%s/%s.tmp", com_gamedir, name);

	// Ensure the directory exists.
	{
		char dir[MAX_OSPATH];
		q_strlcpy (dir, cls.download.temp, sizeof(dir));
		COM_CreatePath (dir);
	}

	cls.download.file = fopen (cls.download.temp, "wb");
	if (!cls.download.file)
	{
		Con_Printf ("CL_Download_Begin_f: can't open %s\n", cls.download.temp);
		cls.download.temp[0] = 0;
		CL_StopDownload ();
		CL_CheckDownloads ();
		return;
	}

	// Tell the server to start sending.
	MSG_WriteByte (&cls.message, clc_stringcmd);
	MSG_WriteString (&cls.message, "sv_startdownload\n");
}

/*
CL_Download_Finished_f
Stuffcmd: "cl_downloadfinished SIZE CRC \"NAME\""
Verify the download, rename temp→final, trigger reload.
*/
static void CL_Download_Finished_f (void)
{
	int	size, crc;
	const char *name;
	char	finalpath[MAX_OSPATH];
	byte	*buf;
	unsigned short computed_crc;
	long	actual_size;

	size = atoi(Cmd_Argv(1));
	crc  = atoi(Cmd_Argv(2));
	name = Cmd_Argv(3);

	if (!cls.download.active || !cls.download.file)
	{
		Con_DPrintf ("cl_downloadfinished: no active download\n");
		return;
	}

	fflush (cls.download.file);

	// Verify size.
	fseek (cls.download.file, 0, SEEK_END);
	actual_size = ftell (cls.download.file);
	fclose (cls.download.file);
	cls.download.file = NULL;

	if ((int)actual_size != size)
	{
		Con_Printf ("Download %s: size mismatch (got %ld, expected %d) — discarding\n",
		            name, actual_size, size);
		goto discard;
	}

	// Verify CRC. Any failure to *complete* the check (alloc/open/read) must
	// discard — never rename an unverified file into place. CRC is integrity
	// only (CRC16 is forgeable), not authentication, but a clean check is the
	// floor before we hand the bytes to the model/sound loaders.
	{
		FILE *f;
		size_t got;

		buf = (size > 0) ? (byte *)malloc (size) : NULL;
		if (!buf)
		{
			Con_Printf ("Download %s: out of memory verifying — discarding\n", name);
			goto discard;
		}
		f = fopen (cls.download.temp, "rb");
		if (!f)
		{
			free (buf);
			Con_Printf ("Download %s: can't reopen temp to verify — discarding\n", name);
			goto discard;
		}
		got = fread (buf, 1, size, f);
		fclose (f);
		computed_crc = CRC_Block (buf, size);
		free (buf);

		if (got != (size_t)size || computed_crc != (unsigned short)crc)
		{
			Con_Printf ("Download %s: CRC/read mismatch — discarding\n", name);
			goto discard;
		}
	}

	// Move temp → final.
	q_snprintf (finalpath, sizeof(finalpath), "%s/%s", com_gamedir, name);
	COM_CreatePath (finalpath);

	remove (finalpath); // remove any existing file before rename
	if (rename(cls.download.temp, finalpath) != 0)
	{
		Con_Printf ("Download %s: rename failed\n", name);
		goto discard;
	}

	cls.download.temp[0] = 0;
	cls.download.active = false;
	cls.download.current[0] = 0;
	cls.download.size = 0;

	Con_Printf ("Downloaded: %s\n", name);

	// Reload the file into the appropriate precache slot.
	// Model?
	{
		int i;
		for (i = 1; i < MAX_MODELS && cl.model_name[i][0]; i++)
		{
			if (!q_strcasecmp(cl.model_name[i], name) && !cl.model_precache[i])
			{
				cl.model_precache[i] = Mod_ForName (name, false);
				if (i == 1 && cl.model_precache[1] && !cl.worldinit)
				{
					cl_entities[0].model = cl.worldmodel = cl.model_precache[1];
					R_NewMap ();
					cl.worldinit = true;
				}
				break;
			}
		}
	}
	// Sound?
	{
		int i;
		for (i = 1; i < MAX_SOUNDS && cl.sound_name[i][0]; i++)
		{
			if (!q_strcasecmp(cl.sound_name[i], name) && !cl.sound_precache[i])
			{
				cl.sound_precache[i] = S_PrecacheSound (name);
				break;
			}
		}
	}

	// Continue checking for more missing files / send prespawn when done.
	CL_CheckDownloads ();
	return;

discard:
	if (cls.download.temp[0])
	{
		remove (cls.download.temp);
		cls.download.temp[0] = 0;
	}
	cls.download.active = false;
	cls.download.current[0] = 0;
	cls.download.size = 0;

	// Try to continue; the missing file will just stay NULL.
	CL_CheckDownloads ();
}

/*
CL_StopDownload_f
Stuffcmd: "stopdownload"
Server aborted an in-flight download.
*/
static void CL_StopDownload_f (void)
{
	if (cls.download.active)
	{
		Con_DPrintf ("Server stopped download of %s\n", cls.download.current);
		CL_StopDownload ();
	}
}

// ============================================================
// Public API
// ============================================================

/*
CL_Download_Data
Handle an svcdp_downloaddata (50) message:
  [long start][short size][data...]
Write received bytes to the temp file.  Ack each chunk.
*/
void CL_Download_Data (void)
{
	int	start, size;
	byte	buf[4096];

	start = MSG_ReadLong ();
	size  = MSG_ReadShort ();	// NB: signed — 0x8000..0xFFFF read as negative,
					// which the bounds check below rejects. Do not
					// widen this to unsigned without re-checking buf[].

	if (size < 0 || size > (int)sizeof(buf))
	{
		Host_Error ("CL_Download_Data: bad chunk size %d", size);
		return; // unreachable
	}

	// Read raw bytes from the message buffer.
	{
		int j;
		for (j = 0; j < size; j++)
			buf[j] = (byte)MSG_ReadByte ();
	}

	// Ack immediately (even bad chunks, so the server's window advances).
	MSG_WriteByte (&cls.message, clcdp_ackdownloaddata);
	MSG_WriteLong (&cls.message, start);
	MSG_WriteShort (&cls.message, (short)size);

	if (!cls.download.active || !cls.download.file)
		return; // download was cancelled; keep acking to drain the pipe

	// SECURITY: clamp the server-controlled write offset to the declared file
	// size so a malicious server can't fseek us to ~2GB and balloon the temp
	// file (DoS / fill the disk on a vintage Mac). start+size must stay within
	// the size announced in cl_downloadbegin.
	if (start < 0 || start > cls.download.size ||
	    size > cls.download.size - start)
	{
		Con_Printf ("CL_Download_Data: chunk [%d+%d] outside declared size %d\n",
		            start, size, cls.download.size);
		CL_StopDownload ();
		return;
	}

	if (fseek(cls.download.file, start, SEEK_SET) != 0 ||
	    fwrite(buf, 1, size, cls.download.file) != (size_t)size)
	{
		Con_Printf ("CL_Download_Data: write error for %s\n", cls.download.current);
		CL_StopDownload ();
	}
}

/*
CL_CheckDownloads
Walk the model/sound precache name lists.  For each slot that is still NULL,
request a download (if allow_download and server support both on) and return
false.  When everything is loaded, call R_NewMap if needed and send prespawn,
returning true.

Called from CL_SignonReply case 1 (initial check) and from CL_Download_Finished_f
(after each file completes).
*/
qboolean CL_CheckDownloads (void)
{
	int i;

	// Still waiting on an in-flight download.
	if (cls.download.active)
		return false;

	// Walk missing model slots.
	for (i = cl.model_download; i < MAX_MODELS && cl.model_name[i][0]; i++)
	{
		cl.model_download = i + 1;

		if (cl.model_precache[i])
			continue; // already loaded

		// Skip inline brush models (e.g. *1, *2).
		if (cl.model_name[i][0] == '*')
			continue;

		// SECURITY: never download a name we wouldn't be allowed to write.
		// The server's name is fully untrusted; validate before we ask.
		if (allow_download.value && cl.protocol_dpdownload &&
		    COM_DownloadNameOkay (cl.model_name[i]))
		{
			q_strlcpy (cls.download.current, cl.model_name[i],
			           sizeof(cls.download.current));
			cls.download.active = true;
			cls.download.file   = NULL;

			MSG_WriteByte (&cls.message, clc_stringcmd);
			MSG_WriteString (&cls.message,
			    va("download \"%s\"\n", cl.model_name[i]));
			return false;
		}
		// No download support, or unsafe name: warn but continue.
		Con_DPrintf ("Missing model: %s\n", cl.model_name[i]);
	}

	// Walk missing sound slots.
	for (i = cl.sound_download; i < MAX_SOUNDS && cl.sound_name[i][0]; i++)
	{
		cl.sound_download = i + 1;

		if (cl.sound_precache[i])
			continue;

		// SECURITY: validate the untrusted server name before requesting.
		if (allow_download.value && cl.protocol_dpdownload &&
		    COM_DownloadNameOkay (cl.sound_name[i]))
		{
			q_strlcpy (cls.download.current, cl.sound_name[i],
			           sizeof(cls.download.current));
			cls.download.active = true;
			cls.download.file   = NULL;

			MSG_WriteByte (&cls.message, clc_stringcmd);
			MSG_WriteString (&cls.message,
			    va("download \"%s\"\n", cl.sound_name[i]));
			return false;
		}
		Con_DPrintf ("Missing sound: %s\n", cl.sound_name[i]);
	}

	// All content is present (or best-effort without downloads).
	// If R_NewMap hasn't been called yet (world was downloaded), do it now.
	if (!cl.worldinit)
	{
		if (cl.model_precache[1])
		{
			cl_entities[0].model = cl.worldmodel = cl.model_precache[1];
			R_NewMap ();
			cl.worldinit = true;
		}
		else
		{
			Con_Printf ("World model still missing — cannot prespawn\n");
			CL_Disconnect ();
			return false;
		}
	}

	// Send prespawn to advance the signon.
	MSG_WriteByte (&cls.message, clc_stringcmd);
	MSG_WriteString (&cls.message, "prespawn");
	return true;
}

/*
CL_Download_Init
Register all stuffcmd handlers needed by the download protocol.
Called from CL_Init.
*/
void CL_Download_Init (void)
{
	Cmd_AddCommand ("cl_serverextension_download", CL_ServerExtension_Download_f);
	Cmd_AddCommand ("cl_downloadbegin",            CL_Download_Begin_f);
	Cmd_AddCommand ("cl_downloadfinished",         CL_Download_Finished_f);
	Cmd_AddCommand ("stopdownload",                CL_StopDownload_f);
}
