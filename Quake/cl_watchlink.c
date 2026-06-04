/*
 * Copyright (C) 2026 QuakeSpasm PPC port
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or (at
 * your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * General Public License for more details.
 *
 * =======================================================================
 *
 * watchlink -- pushes the player's live in-game state out over UDP so an
 * external companion (an Apple Watch "tactical computer", or just `nc -ul`)
 * can render the ranger's health / armor / ammo / weapon / powerups on a
 * second screen.
 *
 * This is the Quake 1 sibling of cl_watchlink.c in the Quake II PPC port:
 * it speaks the SAME newline-delimited JSON wire format on the SAME UDP port
 * (27999) and discovers the SAME Bonjour service ("_q2watch._udp"), so one
 * unchanged iPhone/Apple Watch companion drives both games. Quake 1 has no
 * in-game help computer (no F1 objectives screen), so the companion simply
 * shows the sector name and no objectives panel -- a graceful, cut-down HUD.
 *
 * Everything here is gated on the `watch_host` cvar: when it is empty the
 * feature is completely inert -- no sockets touched, no per-frame work, no
 * packets emitted -- so the default fleet build behaves exactly as before.
 * This is a runtime-gated opt-in, NOT a load-time change.
 *
 * Transport is newline-delimited JSON. The retro PPC fleet is big-endian, so
 * a hand-rolled binary struct would invite byte-order bugs; JSON via snprintf
 * is endianness-proof and debuggable with `nc -ul 27999`. Two heartbeat kinds
 * plus discrete events:
 *
 *   {"t":"vitals", ...}        ~watch_rate Hz, the status bar
 *   {"t":"meta", ...}          once per map load: level name + weapon table
 *   {"t":"event","kind":...}   damage / centerprint / sounds, as they happen
 *
 * Sends go out on watchlink's OWN non-blocking UDP socket (single-player has
 * no usable client socket), fire-and-forget, so an unreachable watch_host
 * never stalls the frame.
 *
 * =======================================================================
 */

#include "quakedef.h"

#include <string.h>
#include <stdlib.h>

/*
 * Portable, non-blocking outbound UDP. POSIX everywhere the fleet runs
 * (macOS PPC, Linux); Winsock for Windows builds. We open our own socket
 * rather than borrowing the engine's net layer: in single-player the client
 * talks to the local server over loopback and has no socket usable for a real
 * LAN destination, so a private UDP socket sidesteps the whole net-config /
 * connection state.
 */
#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
typedef SOCKET wl_socket_t;
#define WL_INVALID_SOCKET	INVALID_SOCKET
static int		wl_wsa_started;
#else
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include <fcntl.h>
typedef int		wl_socket_t;
#define WL_INVALID_SOCKET	(-1)
#define closesocket		close
#endif

/*
 * Zero-config discovery (macOS only). When watch_host is the literal "auto"
 * we browse Bonjour for the companion's "_q2watch._udp" service instead of
 * resolving a typed IP, so the phone never has to be addressed by hand. This
 * is libSystem/mDNSResponder, present on every Mac the fleet targets (Panther
 * 10.3 .. Leopard 10.5 .. Lion), and is compiled out everywhere else. The
 * service type is shared with the Quake II port on purpose: one companion,
 * both games.
 *
 * The browse/resolve calls ship on all fleet OSes, but the SDK *headers*
 * drifted across versions, so we paper over the gaps to keep ONE source file
 * compiling for every slice (g3 10.3.9, g4 10.4u, g5 10.5, lion):
 *   - DNSSD_API and kDNSServiceInterfaceIndexAny first appear in the 10.4u
 *     SDK; the 10.3.9 headers lack both. We supply a no-op / zero fallback.
 *   - DNSServiceGetAddrInfo (explicit A-record lookup) is 10.5+. On 10.3/10.4
 *     we fall back to handing the resolver's hosttarget to getaddrinfo.
 *   - The DNSServiceResolveReply txtRecord arg is `const char *` through 10.4u
 *     and `const unsigned char *` from 10.5 on; we match each exactly.
 */
#ifdef __APPLE__
#include <AvailabilityMacros.h>
#include <dns_sd.h>
#include <sys/select.h>
#define WATCHLINK_BONJOUR 1

#if defined(MAC_OS_X_VERSION_MAX_ALLOWED) && MAC_OS_X_VERSION_MAX_ALLOWED < 1040
#ifndef DNSSD_API
#define DNSSD_API
#endif
#define kDNSServiceInterfaceIndexAny 0
#endif

#if defined(MAC_OS_X_VERSION_MAX_ALLOWED) && MAC_OS_X_VERSION_MAX_ALLOWED >= 1050
#define WATCHLINK_HAVE_ADDRINFO 1
#define WATCHLINK_TXTREC const unsigned char
#else
#define WATCHLINK_TXTREC const char
#endif
#endif /* __APPLE__ */

extern double	realtime;	/* monotonic wall clock, seconds */

static cvar_t	watch_host = {"watch_host", "", CVAR_ARCHIVE};   /* "ip"/"ip:port", "auto", "" => off */
static cvar_t	watch_port = {"watch_port", "27999", CVAR_ARCHIVE};
static cvar_t	watch_rate = {"watch_rate", "10", CVAR_ARCHIVE}; /* vitals heartbeat, Hz */
static cvar_t	watch_events = {"watch_events", "1", CVAR_ARCHIVE};

static wl_socket_t	watch_sock = WL_INVALID_SOCKET;
static struct sockaddr_in watch_sin;	/* resolved companion destination */
static qboolean		watch_sin_valid;
static int		watch_sent_count;	/* packets since last (re)connect */

static double		watch_last_send;	/* realtime of last vitals heartbeat */
static char		watch_last_vitals[1024];/* last vitals payload (change-detect) */
static qboolean		watch_meta_pending;	/* meta queued; send once dest resolves */
static char		watch_lastmap[128];	/* detect map changes to re-arm + send meta */
static char		watch_last_cp[1024];	/* last centerprint forwarded (dedup re-fires) */

#ifdef WATCHLINK_BONJOUR
static DNSServiceRef	watch_browse_ref;
static DNSServiceRef	watch_resolve_ref;
static qboolean		watch_discovering;
static uint16_t		watch_disc_port;	/* service port (network byte order) */
static double		watch_disc_until;	/* realtime deadline to give up a fruitless browse */
#define WATCHLINK_DISCOVERY_SECS 30.0
#ifdef WATCHLINK_HAVE_ADDRINFO
static DNSServiceRef	watch_addr_ref;
#endif
#endif

/* Quake 1 weapon bit (cl.stats[STAT_ACTIVEWEAPON]) -> display name. */
static const char *
WatchLink_WeaponName (int w)
{
	switch (w)
	{
	case IT_AXE:			return "Axe";
	case IT_SHOTGUN:		return "Shotgun";
	case IT_SUPER_SHOTGUN:		return "Super Shotgun";
	case IT_NAILGUN:		return "Nailgun";
	case IT_SUPER_NAILGUN:		return "Super Nailgun";
	case IT_GRENADE_LAUNCHER:	return "Grenade Launcher";
	case IT_ROCKET_LAUNCHER:	return "Rocket Launcher";
	case IT_LIGHTNING:		return "Thunderbolt";
	default:			return "";
	}
}

/* Quake 1 powerups, in display priority. idx is the cl.item_gettime[] slot
   (the bit position), used to estimate the 30 s countdown. The icon tokens
   match the companion's neutral powerup labels (quad/pent/ring/envir). */
static const struct { int bit; int idx; const char *icon; } watch_powerups[] =
{
	{ IT_QUAD,		22, "quad"  },	/* QUAD DAMAGE   */
	{ IT_INVULNERABILITY,	20, "pent"  },	/* INVULNERABLE  */
	{ IT_INVISIBILITY,	19, "ring"  },	/* INVISIBILITY  */
	{ IT_SUIT,		21, "envir" }	/* ENVIRO-SUIT   */
};

/* Weapons the companion may want to list once per map (cl.items snapshot). */
static const struct { int bit; const char *name; } watch_arsenal[] =
{
	{ IT_AXE,		"Axe" },
	{ IT_SHOTGUN,		"Shotgun" },
	{ IT_SUPER_SHOTGUN,	"Super Shotgun" },
	{ IT_NAILGUN,		"Nailgun" },
	{ IT_SUPER_NAILGUN,	"Super Nailgun" },
	{ IT_GRENADE_LAUNCHER,	"Grenade Launcher" },
	{ IT_ROCKET_LAUNCHER,	"Rocket Launcher" },
	{ IT_LIGHTNING,		"Thunderbolt" }
};

static qboolean WatchLink_IsAuto (void);
static void WatchLink_Sync (void);

/*
 * Fill watch_sin from a host (numeric IPv4 or a name getaddrinfo can resolve)
 * and port. A name is resolved once, synchronously -- fine: it only happens on
 * (re)connect, and .local mDNS names resolve locally.
 */
static void
WatchLink_SetDest (const char *host, int port)
{
	struct addrinfo	hints, *res;

	watch_sin_valid = false;

	if (!host || !host[0] || port <= 0 || port > 65535)
		return;

	memset (&watch_sin, 0, sizeof(watch_sin));
	watch_sin.sin_family = AF_INET;
	watch_sin.sin_port = htons ((unsigned short)port);

	if (inet_pton (AF_INET, host, &watch_sin.sin_addr) == 1)
	{
		watch_sin_valid = true;
		return;
	}

	memset (&hints, 0, sizeof(hints));
	hints.ai_family = AF_INET;
	hints.ai_socktype = SOCK_DGRAM;
	res = NULL;
	if (getaddrinfo (host, NULL, &hints, &res) == 0 && res != NULL)
	{
		watch_sin.sin_addr = ((struct sockaddr_in *)res->ai_addr)->sin_addr;
		watch_sin_valid = true;
	}
	if (res)
		freeaddrinfo (res);
}

/*
 * Resolve the watch_host cvar ("ip" or "ip:port") into watch_sin. When no port
 * is given, watch_port is appended. Called lazily whenever a destination is
 * needed so the user can retarget live from the console.
 */
static void
WatchLink_Resolve (void)
{
	char	buf[128];
	char	*colon;
	int	port;

	watch_sin_valid = false;

	if (!watch_host.string[0])
		return;

	q_strlcpy (buf, watch_host.string, sizeof(buf));
	colon = strrchr (buf, ':');
	if (colon)
	{
		*colon = '\0';
		port = atoi (colon + 1);
	}
	else
	{
		port = (int)watch_port.value;
	}

	WatchLink_SetDest (buf, port);
}

static qboolean
WatchLink_IsAuto (void)
{
	return (watch_host.string[0] && !q_strcasecmp (watch_host.string, "auto")) ? true : false;
}

#ifdef WATCHLINK_BONJOUR
static void
WatchLink_StopDiscovery (void)
{
#ifdef WATCHLINK_HAVE_ADDRINFO
	if (watch_addr_ref) { DNSServiceRefDeallocate (watch_addr_ref); watch_addr_ref = NULL; }
#endif
	if (watch_resolve_ref) { DNSServiceRefDeallocate (watch_resolve_ref); watch_resolve_ref = NULL; }
	if (watch_browse_ref) { DNSServiceRefDeallocate (watch_browse_ref); watch_browse_ref = NULL; }
	watch_discovering = false;
}

/* Adopt a discovered host:port as the live destination. */
static void
WatchLink_Discovered (const char *host, int port)
{
	qboolean had = watch_sin_valid;

	WatchLink_SetDest (host, port);
	if (watch_sin_valid && !had)
		Con_SafePrintf ("watchlink: discovered companion at %s:%d\n", host, port);
}

#ifdef WATCHLINK_HAVE_ADDRINFO
/* Stage 3 (10.5+): the host's IPv4 address arrived -> build the destination. */
static void DNSSD_API
WatchLink_AddrReply (DNSServiceRef sdRef, DNSServiceFlags flags,
		uint32_t interfaceIndex, DNSServiceErrorType err,
		const char *hostname, const struct sockaddr *address,
		uint32_t ttl, void *context)
{
	const struct sockaddr_in *sin;
	char	ip[64];

	(void)sdRef; (void)flags; (void)interfaceIndex; (void)hostname;
	(void)ttl; (void)context;

	if (err != kDNSServiceErr_NoError || !address ||
			address->sa_family != AF_INET)
		return;

	sin = (const struct sockaddr_in *)address;
	if (!inet_ntop (AF_INET, &sin->sin_addr, ip, sizeof(ip)))
		return;

	WatchLink_Discovered (ip, (int)ntohs (watch_disc_port));
}
#endif /* WATCHLINK_HAVE_ADDRINFO */

/* Stage 2: a service instance resolved to host:port. On 10.5+ resolve its
   IPv4 explicitly; on older SDKs hand the hosttarget to getaddrinfo. */
static void DNSSD_API
WatchLink_ResolveReply (DNSServiceRef sdRef, DNSServiceFlags flags,
		uint32_t interfaceIndex, DNSServiceErrorType err,
		const char *fullname, const char *hosttarget, uint16_t port,
		uint16_t txtLen, WATCHLINK_TXTREC *txtRecord, void *context)
{
	(void)sdRef; (void)flags; (void)fullname;
	(void)txtLen; (void)txtRecord; (void)context;

	if (err != kDNSServiceErr_NoError)
		return;

	watch_disc_port = port; /* network byte order */

#ifdef WATCHLINK_HAVE_ADDRINFO
	if (watch_addr_ref)
	{
		DNSServiceRefDeallocate (watch_addr_ref);
		watch_addr_ref = NULL;
	}
	DNSServiceGetAddrInfo (&watch_addr_ref, 0, interfaceIndex,
			kDNSServiceProtocol_IPv4, hosttarget,
			WatchLink_AddrReply, NULL);
#else
	(void)interfaceIndex;
	WatchLink_Discovered (hosttarget, (int)ntohs (port));
#endif
}

/* Stage 1: a companion appeared on the LAN -> resolve it. */
static void DNSSD_API
WatchLink_BrowseReply (DNSServiceRef sdRef, DNSServiceFlags flags,
		uint32_t interfaceIndex, DNSServiceErrorType err,
		const char *serviceName, const char *regtype,
		const char *replyDomain, void *context)
{
	(void)sdRef; (void)context;

	if (err != kDNSServiceErr_NoError || !(flags & kDNSServiceFlagsAdd))
		return; /* ignore errors and "service went away" notifications */

	if (watch_resolve_ref)
	{
		DNSServiceRefDeallocate (watch_resolve_ref);
		watch_resolve_ref = NULL;
	}
	DNSServiceResolve (&watch_resolve_ref, 0, interfaceIndex,
			serviceName, regtype, replyDomain,
			WatchLink_ResolveReply, NULL);
}

static void
WatchLink_StartDiscovery (void)
{
	DNSServiceErrorType err;

	WatchLink_StopDiscovery ();

	err = DNSServiceBrowse (&watch_browse_ref, 0, kDNSServiceInterfaceIndexAny,
			"_q2watch._udp", NULL, WatchLink_BrowseReply, NULL);

	if (err != kDNSServiceErr_NoError)
	{
		Con_SafePrintf ("watchlink: Bonjour browse failed (err %d); "
				"set watch_host to an IP instead\n", (int)err);
		watch_browse_ref = NULL;
		return;
	}

	watch_discovering = true;
	watch_disc_until = realtime + WATCHLINK_DISCOVERY_SECS;
	Con_SafePrintf ("watchlink: browsing for companion (_q2watch._udp)...\n");
}

/* Service one ready DNS-SD socket, without blocking the frame. */
static void
WatchLink_PumpRef (DNSServiceRef ref)
{
	int		fd;
	fd_set		set;
	struct timeval	tv;

	if (!ref)
		return;

	fd = DNSServiceRefSockFD (ref);
	if (fd < 0)
		return;

	FD_ZERO (&set);
	FD_SET (fd, &set);
	tv.tv_sec = 0;
	tv.tv_usec = 0;

	if (select (fd + 1, &set, NULL, NULL, &tv) > 0 && FD_ISSET (fd, &set))
		DNSServiceProcessResult (ref);
}

static void
WatchLink_PumpDiscovery (void)
{
	WatchLink_PumpRef (watch_browse_ref);
	WatchLink_PumpRef (watch_resolve_ref);
#ifdef WATCHLINK_HAVE_ADDRINFO
	WatchLink_PumpRef (watch_addr_ref);
#endif
}
#endif /* WATCHLINK_BONJOUR */

/*
 * Reconcile internal state with the watch_host cvar and, in "auto" mode, drive
 * Bonjour discovery. Cheap to call every frame; only does real work when the
 * cvar string changed or a discovery socket has data pending. QuakeSpasm's
 * cvar_t has no "modified" flag (unlike Quake II), so we detect edits by
 * remembering the last value we acted on.
 */
static char watch_host_seen[128] = "\001"; /* sentinel: forces first reconcile */

static void
WatchLink_Sync (void)
{
	if (strcmp (watch_host.string, watch_host_seen) != 0)
	{
		q_strlcpy (watch_host_seen, watch_host.string, sizeof(watch_host_seen));
		watch_sin_valid = false;
#ifdef WATCHLINK_BONJOUR
		WatchLink_StopDiscovery ();
#endif
		if (WatchLink_IsAuto ())
		{
#ifdef WATCHLINK_BONJOUR
			WatchLink_StartDiscovery ();
#else
			Con_SafePrintf ("watchlink: \"auto\" needs macOS Bonjour; "
					"set watch_host to an IP instead\n");
#endif
		}
	}

#ifdef WATCHLINK_BONJOUR
	if (watch_discovering)
	{
		WatchLink_PumpDiscovery ();

		/* Stop browsing once we have a destination, or after the window
		   elapses with no companion found -- a phoneless game then pays
		   nothing per frame. Re-armed on the next map load. */
		if (watch_sin_valid)
		{
			WatchLink_StopDiscovery ();
		}
		else if (realtime > watch_disc_until)
		{
			WatchLink_StopDiscovery ();
			Con_SafePrintf ("watchlink: no companion found; idling "
					"(load a map to retry)\n");
		}
	}
#endif
}

/*
 * True when the feature is armed and a destination is known. A typed IP is
 * resolved here lazily; in "auto" mode the address is supplied asynchronously
 * by Bonjour discovery (WatchLink_Sync).
 */
static qboolean
WatchLink_DestReady (void)
{
	if (!watch_host.string[0])
		return false;

	if (!watch_sin_valid && !WatchLink_IsAuto ())
		WatchLink_Resolve ();

	return watch_sin_valid;
}

static void
WatchLink_Send (const char *line)
{
	int	len = (int)strlen (line);

	if (len <= 0 || !watch_sin_valid)
		return;

	if (watch_sock == WL_INVALID_SOCKET)
	{
#ifdef _WIN32
		if (!wl_wsa_started)
		{
			WSADATA wsa;
			if (WSAStartup (MAKEWORD(2,2), &wsa) == 0)
				wl_wsa_started = 1;
		}
#endif
		watch_sock = socket (AF_INET, SOCK_DGRAM, 0);
		if (watch_sock != WL_INVALID_SOCKET)
		{
#ifdef _WIN32
			u_long nb = 1;
			ioctlsocket (watch_sock, FIONBIO, &nb);
#else
			fcntl (watch_sock, F_SETFL, O_NONBLOCK);
#endif
		}
	}

	if (watch_sock == WL_INVALID_SOCKET)
		return;

	sendto (watch_sock, line, len, 0,
			(struct sockaddr *)&watch_sin, sizeof(watch_sin));

	if (watch_sent_count++ == 0)
		Con_SafePrintf ("watchlink: streaming to %s:%u\n",
				inet_ntoa (watch_sin.sin_addr),
				(unsigned)ntohs (watch_sin.sin_port));
}

/*
 * Copy src into dst with the characters JSON forbids bare (", \, control
 * chars, and Quake's high-bit "colored" text) escaped or stripped, so a
 * pickup string can never break the line framing.
 */
static void
WatchLink_EscapeJson (char *dst, int dstsize, const char *src)
{
	int	o = 0;

	for (; *src && o < dstsize - 7; src++)
	{
		unsigned char c = (unsigned char)*src;

		c &= 0x7f; /* drop Quake's high-bit colored glyphs */

		if (c == '"' || c == '\\')
		{
			dst[o++] = '\\';
			dst[o++] = c;
		}
		else if (c == '\n')
		{
			dst[o++] = '\\';
			dst[o++] = 'n';
		}
		else if (c >= ' ')
		{
			dst[o++] = c;
		}
		/* other control chars dropped */
	}

	dst[o] = 0;
}

void
CL_WatchLink_Init (void)
{
	Cvar_RegisterVariable (&watch_host);
	Cvar_RegisterVariable (&watch_port);
	Cvar_RegisterVariable (&watch_rate);
	Cvar_RegisterVariable (&watch_events);

	watch_sin_valid = false;
	watch_last_send = 0;
	watch_last_vitals[0] = '\0';
	watch_lastmap[0] = '\0';
	watch_last_cp[0] = '\0';
	/* watch_host_seen's "\001" sentinel forces the first WatchLink_Sync to
	   reconcile, so an archived watch_host (incl. "auto") is honoured at
	   launch without needing a console edit. */
}

/*
 * Emit a one-off event line. kind is the event class ("damage", "centerprint",
 * ...); detail is pre-formatted JSON members (already escaped) appended
 * verbatim, e.g. ,"msg":"You got the Rocket Launcher".
 */
void
CL_WatchLink_Event (const char *kind, const char *detail)
{
	char	line[1280];

	/* Never echo the menu attract-loop / demo playback to the companion. */
	if (cls.demoplayback)
		return;
	if (!watch_host.string[0])
		return;

	WatchLink_Sync ();
	if (!WatchLink_DestReady () || !watch_events.value)
		return;

	q_snprintf (line, sizeof(line),
			"{\"t\":\"event\",\"kind\":\"%s\"%s}\n",
			kind, detail ? detail : "");
	WatchLink_Send (line);
}

/*
 * Hooked from SCR_CenterPrint: forward story / pickup text to the companion.
 */
void
CL_WatchLink_CenterPrint (const char *str)
{
	char	esc[1024];
	char	detail[1100];

	if (!str || !str[0])
		return;

	/* Many Quake 1 maps use trigger_multiple message rooms that re-fire the
	   same centerprint every time you re-touch the trigger (e.g. standing in a
	   doorway). Drop consecutive duplicates so the companion's comms log isn't
	   spammed. Reset per map in WatchLink_Reconnect. */
	if (!strcmp (str, watch_last_cp))
		return;
	q_strlcpy (watch_last_cp, str, sizeof(watch_last_cp));

	WatchLink_EscapeJson (esc, sizeof(esc), str);
	q_snprintf (detail, sizeof(detail), ",\"msg\":\"%s\"", esc);
	CL_WatchLink_Event ("centerprint", detail);
}

/*
 * Hooked from V_ParseDamage: the instant the ranger is hit, raise a "damage"
 * event so the watch can buzz the wrist. armor/blood are the byte amounts the
 * server sent; we forward which subsystem(s) took the hit (1/0), matching the
 * Quake II STAT_FLASHES wire shape.
 */
void
CL_WatchLink_Damage (int armor, int blood)
{
	char	detail[64];

	q_snprintf (detail, sizeof(detail),
			",\"health\":%d,\"armor\":%d,\"ammo\":0",
			(blood > 0) ? 1 : 0, (armor > 0) ? 1 : 0);
	CL_WatchLink_Event ("damage", detail);
}

/*
 * Hooked from CL_ParseStartSoundPacket for the LOCAL player's entity: forward
 * the ranger's vocal sounds and pickup sounds (paths under player/ or items/,
 * plus anything containing "pkup") so the companion can play the real effect.
 * Weapon fire, footsteps and world ambience are skipped.
 * cfgname is the precache path, e.g. "player/pain1.wav", "items/damage.wav" ->
 * we forward the bare basename ("pain1", "damage") as the event msg.
 */
void
CL_WatchLink_Sound (const char *cfgname)
{
	const char	*p;
	const char	*slash;
	char		base[64];
	char		esc[80];
	char		detail[100];
	size_t		n;

	if (cls.demoplayback || !cfgname || !cfgname[0])
		return;

	if (!strncmp (cfgname, "player/", 7))
		p = cfgname + 7;		/* ranger vocal */
	else if (!strncmp (cfgname, "items/", 6))
		p = cfgname + 6;		/* pickups / powerups */
	else if (strstr (cfgname, "pkup"))
		p = cfgname;			/* ammo / weapon pickup */
	else
		return;				/* not a player-feedback sound */

	slash = strrchr (p, '/');
	if (slash)
		p = slash + 1;

	q_strlcpy (base, p, sizeof(base));
	n = strlen (base);
	if (n > 4 && !q_strcasecmp (base + n - 4, ".wav"))
		base[n - 4] = '\0';
	if (!base[0])
		return;

	WatchLink_EscapeJson (esc, sizeof(esc), base);
	q_snprintf (detail, sizeof(detail), ",\"msg\":\"%s\"", esc);
	CL_WatchLink_Event ("psound", detail);
}

/*
 * Build and send the per-map lookup table the watch shows: level name plus the
 * weapons the player owns. Quake 1 has no item-name configstring table (unlike
 * Quake II), so we synthesise the arsenal from cl.items. Sub-MTU by design.
 */
static void
WatchLink_SendMeta (void)
{
	char	line[1024];
	char	name[128];
	int	i, n, off;

	WatchLink_EscapeJson (name, sizeof(name),
			cl.levelname[0] ? cl.levelname : cl.mapname);

	q_snprintf (line, sizeof(line),
			"{\"t\":\"meta\",\"level\":\"%s\",\"items\":[", name);
	off = (int)strlen (line);

	n = 0;
	for (i = 0; i < (int)(sizeof(watch_arsenal) / sizeof(watch_arsenal[0])); i++)
	{
		if (!(cl.items & watch_arsenal[i].bit))
			continue;
		if (off + (int)strlen (watch_arsenal[i].name) + 8 >= (int)sizeof(line))
			break;
		q_snprintf (line + off, sizeof(line) - off,
				n ? ",\"%s\"" : "\"%s\"", watch_arsenal[i].name);
		off += (int)strlen (line + off);
		n++;
	}

	q_strlcat (line, "]}\n", sizeof(line));
	WatchLink_Send (line);
}

/*
 * New map: re-arm discovery so the link freshens for this session (the phone
 * may have reconnected, slept, or changed address) WITHOUT dropping the
 * current target, and reset the per-session change-detect state.
 */
static void
WatchLink_Reconnect (void)
{
	watch_last_send = 0;
	watch_last_vitals[0] = '\0';
	watch_last_cp[0] = '\0';   /* re-allow this map's centerprints */
	watch_sent_count = 0;

#ifdef WATCHLINK_BONJOUR
	if (WatchLink_IsAuto ())
	{
		WatchLink_StartDiscovery ();
		return;
	}
#endif
	WatchLink_Resolve ();
}

/*
 * Per-frame heartbeat. Called from the tail of the client section of
 * _Host_Frame. Throttled to watch_rate Hz, change-detected with a 1 s
 * keepalive. Picks up cvar edits live.
 */
void
CL_WatchLink_Frame (void)
{
	const int	*st;
	char		line[1024];
	const char	*sel;
	const char	*pu_icon;
	int		pu_sec;
	int		i;
	double		interval;

	if (!watch_host.string[0])
		return;			/* feature off -- stay fully inert */

	WatchLink_Sync ();

	/* only meaningful once a human is actually in a level; never stream the
	   menu attract-loop demos. */
	if (cls.state != ca_connected || cls.signon != SIGNONS ||
			cls.demoplayback || !cl.worldmodel)
		return;

	/* New map? re-arm discovery and queue the meta table. Done regardless of
	   whether a destination is known yet (auto mode usually has not resolved
	   at map-load), so the meta still goes out as soon as discovery lands. */
	if (strcmp (cl.mapname, watch_lastmap) != 0)
	{
		q_strlcpy (watch_lastmap, cl.mapname, sizeof(watch_lastmap));
		WatchLink_Reconnect ();
		watch_meta_pending = true;
	}

	if (!WatchLink_DestReady ())
		return;

	if (watch_meta_pending)
	{
		WatchLink_SendMeta ();
		watch_meta_pending = false;
	}

	/* throttle the vitals heartbeat; floor at 1 ms so a large watch_rate
	   can't truncate the interval to 0 and emit on every single frame. */
	interval = (watch_rate.value > 0) ? (1.0 / watch_rate.value) : 0.1;
	if (interval < 0.001)
		interval = 0.001;
	if (realtime - watch_last_send < interval)
		return;

	st = cl.stats;

	sel = WatchLink_WeaponName (st[STAT_ACTIVEWEAPON]);

	/* Active powerup, in priority order. Quake 1 powerups last 30 s; estimate
	   the countdown from when the bit was acquired (cl.item_gettime). */
	pu_icon = "";
	pu_sec = 0;
	for (i = 0; i < (int)(sizeof(watch_powerups) / sizeof(watch_powerups[0])); i++)
	{
		if (cl.items & watch_powerups[i].bit)
		{
			int rem = (int)(30.0 - (cl.time - cl.item_gettime[watch_powerups[i].idx]));
			if (rem < 0)
				rem = 0;
			if (rem > 99)
				rem = 99;
			pu_icon = watch_powerups[i].icon;
			pu_sec = rem;
			break;
		}
	}

	/* Quake 1 has no STAT_FLASHES / STAT_LAYOUTS / spectator: send 0 for those
	   (damage drives the watch haptic via the discrete event above), keeping
	   the wire shape identical to the Quake II feed. */
	q_snprintf (line, sizeof(line),
			"{\"t\":\"vitals\",\"game\":\"q1\","
			"\"hp\":%d,\"armor\":%d,\"ammo\":%d,"
			"\"sel\":\"%s\","
			"\"frags\":%d,\"flashes\":%d,\"layouts\":%d,\"spec\":%d,"
			"\"pu\":{\"icon\":\"%s\",\"sec\":%d}}\n",
			st[STAT_HEALTH], st[STAT_ARMOR], st[STAT_AMMO],
			sel,
			st[STAT_FRAGS], 0, 0, 0,
			pu_icon, pu_sec);

	/* Cut the packet flood: only send when the vitals actually changed, plus a
	   ~1 s keepalive so the companion still sees a live feed (and can detect a
	   dropout) while you stand still. */
	if (strcmp (line, watch_last_vitals) == 0 &&
			realtime - watch_last_send < 1.0)
		return;

	watch_last_send = realtime;
	q_strlcpy (watch_last_vitals, line, sizeof(watch_last_vitals));
	WatchLink_Send (line);
}
