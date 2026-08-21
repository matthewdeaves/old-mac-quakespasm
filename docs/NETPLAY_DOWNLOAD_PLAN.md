# Online network play + auto-download missing maps: implementation plan

**Status: SHIPPED.** Evidence-gathered 2026-06-06 (codebase audit + QSS/FTE/
DarkPlaces/ironwail source read); implemented and in the tree since. This
document is kept for the reasoning and the rejected alternatives, not as a
to-do list. It said "not started" until 2026-08-21, long after the feature was
live, which is how it got read as outstanding work.

Where it landed:

| Part | Code |
|---|---|
| `allow_download` cvar, default `0` | `Quake/common.c` `COM_InitFilesystem` |
| Server side | `Quake/host_cmd.c` `Host_Download_f` |
| Client side | `Quake/cl_main.c`, `Quake/cl_parse.c` (`svcdp_downloaddata`) |
| Operator documentation | [`KNOBS.md`](KNOBS.md), `../server/README.md` |

**One shipped limitation worth knowing:** `Host_Download_f` opens
`com_gamedir/<name>` with `fopen` and therefore serves **loose files only, never
anything inside a pak**. Custom content delivered to a server as a `.pak` makes
`allow_download 1` look enabled and transfer nothing, with no error the operator
can see: the client simply gets `cl_downloadbegin -1`, the same reply as "file
not permitted". Package server content as loose files.

**Goal:** let the fat binary join Quake servers over the internet and
automatically fetch the maps / models / sounds it's missing, instead of crashing
with `Host_Error("Model %s not found")`. Reach a usable "browse → join → auto-
download → play" loop on all targets (G3 Panther … Lion Intel).

**Headline finding, NO TLS, NO libcurl, NO new libraries required.** The modern
reference implementation (QuakeSpasm-Spiked) does this entirely **in-protocol
over the existing UDP game connection**. TLS only ever matters for the *optional*
HTTPS fast-download mirror path, which QSS itself doesn't bother with. See
[§7 TLS](#7-tls--the-optional-last-5-not-part-of-this-plan).

Cross-refs: [`adr/0008`](adr/0008-every-knob-is-toggleable-gate-a-change-do-not-drop-it.md)
(toggleability), [`KNOBS.md`](KNOBS.md)
(knob inventory, add the new cvar there), [`adr/0009`](adr/0009-benchmarks-are-three-runs-on-hardware-with-a-same-session-ab.md)
(bench cadence), [`../MISTAKES.md`](../MISTAKES.md) (read the caveats in §8).

---

## 1. Strategic decision: copy QSS's DP-style in-protocol download

Four modern engines were read on GitHub (2026-06-06):

| Engine | Download mechanism | Useful here? |
|---|---|---|
| **QuakeSpasm-Spiked** (`Shpoike/Quakespasm`, branch `qsrebase`) | **In-protocol UDP**, DarkPlaces-style. No curl/http/TLS anywhere in its tree. ~400 LOC. | **YES, primary copy target.** Closest to our codebase. |
| DarkPlaces (`DarkPlacesEngine/DarkPlaces`) | Both in-protocol AND libcurl HTTP (`sv_curl_*`). | Reference for security guards (`FS_CheckNastyPath`) + optional later HTTP. |
| FTE (`fte-team/fteqw`) | Chunked-download protocol extension (`PEXT_CHUNKEDDOWNLOADS 0x20000000`). | QSS deliberately rejected this, handles packet loss better but more complex. Not used. |
| ironwail (`andrei-drexler/ironwail`) | **libcurl/TLS add-on browser only**, no join-time downloader at all. | **Dead end.** Don't model on it. |

QSS's own comment in `protocol.h` (line 61 in its tree):
```c
//#define PEXT1_CHUNKEDDOWNLOADS 0x20000000 //favour DP's download protocol instead. its simpler and better established (though doesn't cope with packetloss so well).
```

**Decision: port QSS's DarkPlaces-style in-protocol download verbatim.** It rides
on plain `PROTOCOL_NETQUAKE`(15) / `PROTOCOL_FITZQUAKE`(666) / `PROTOCOL_RMQ`(999)
, no protocol-version bump, no pext handshake. Negotiated with stuffcmds + two
reused DP message bytes.

---

## 2. The mechanism we're copying (QSS reference)

### Negotiation (stuffcmd-based, no protocol flag)
1. Server advertises by sending `svc_stufftext` + `"cl_serverextension_download 1\n"`.
2. Client's `cl_serverextension_download` command handler sets `cl.protocol_dpdownload`.
3. Client requests a file with `clc_stringcmd "download \"<file>\"\n"`.
4. Server replies `svc_stufftext "cl_downloadbegin <size> \"<name>\"\n"`.
5. Client replies `clc_stringcmd "sv_startdownload\n"`, opens `<file>.tmp`.
6. Data flows as `svcdp_downloaddata` chunks; client acks with `clcdp_ackdownloaddata`.
7. Server finishes with `svc_stufftext "cl_downloadfinished <size> <crc> \"<name>\"\n"`.
8. Client verifies size + CRC, `rename()`s `.tmp` → final, else `unlink`s.

### Two reused DarkPlaces protocol constants (add to `protocol.h`)
```c
#define svcdp_downloaddata     50   // S->C: [long] start [short] size [bytes...]
#define clcdp_ackdownloaddata  51   // C->S: [long] start [short] size
```
Our highest used svc is `svc_localsound = 56`, and clc only goes to
`clc_stringcmd = 4`, so **50 and 51 are free** in our tree and we match DP/QSS
numbering exactly for wire compatibility with real QSS servers.

### Client driver `CL_CheckDownloads()`
Walks the precache *name* lists; for each missing file (skipping `*`-prefixed
inline brush models), downloads it; fetches `.lit` before its `.bsp`. Returns
false while a download is pending, which **gates the signon** so we don't
`prespawn` until content is present.

### Security chokepoint `COM_DownloadNameOkay()` (~46 LOC: called both ends)
Gated by one cvar `allow_download`. Enforces:
- **Directory allowlist:** name must start with `sound/`, `progs/`, `maps/`, or `models/`.
- **Char blocks:** reject `\ : * ? "`, reject `//`, reject leading `.` or any `/.` (kills `..`, absolute paths, hidden files).
- **Extension allowlist:** only `bsp mdl iqm md3 spr spr32 wav ogg tga png lux lit2 lit`. Everything else (`.cfg .dat .dll .so .exe .bat …`) refused by omission.
- **Server-side extra:** refuse files served from inside a pak, refuse `> 50 MB`, refuse nonexistent.
- **Integrity:** size + `CRC_Block` checked after transfer; mismatch → discard temp.

---

## 3. Codebase integration points (verified against our tree)

All line numbers are **our** `old-mac-quakespasm/Quake/` as of 2026-06-06.

| Piece | Our location | Action |
|---|---|---|
| Missing-model fatal crash | `cl_parse.c:408-412` `CL_ParseServerInfo`, `Mod_ForName(...)==NULL` → `Host_Error("Model %s not found")` | Stop crashing; defer load; queue download |
| Static-sound NULL deref | `cl_parse.c:964` `CL_ParseStaticSound`, `S_StaticSound(cl.sound_precache[n], …)` | Guard NULL precache slot |
| Signon `prespawn` send | `cl_main.c:192-193` `CL_SignonReply` case 1 | Insert `CL_CheckDownloads()` gate before sending `prespawn` |
| clc send path | `cl_main.c:728` `CL_SendCmd`, buffer `cls.message`; `clc_stringcmd=4` at `protocol.h:233` | Reuse as-is |
| svc dispatch switch | `cl_parse.c:1069` `CL_ParseServerMessage` (highest svc = `svc_localsound`=56) | Add `case svcdp_downloaddata` |
| File write → gamedir | `common.c:1612-1631` `COM_WriteFile` writes under `com_gamedir`; existing `..` guards at `common.c:2186, 2362` | Reuse + add `COM_DownloadNameOkay` |
| File search / pak vs loose | `common.c` `COM_FindFile`/`COM_OpenFile`; `com_gamedir` at `common.c:1577` | `COM_DownloadNameOkay` server-side checks `file_from_pak` |
| Build | `Makefile.darwin` OBJS list (`NET_LIBS` **empty**, confirmed no curl/tls) | Add one `cl_download.o`, **no libs** |

### The one structural prerequisite (Phase 1: verified, mandatory)
`CL_ParseServerInfo` currently stores precache **names** in **stack-local**
arrays:
```c
// cl_parse.c:292-293  -- LOCAL to the function, lost on return
char model_precache[MAX_MODELS][MAX_QPATH];
char sound_precache[MAX_SOUNDS][MAX_QPATH];
```
The `cl` struct keeps only the resolved pointers, **not the names**:
```c
// client.h:203-204
struct qmodel_s *model_precache[MAX_MODELS];
struct sfx_s    *sound_precache[MAX_SOUNDS];
```
`CL_CheckDownloads()` runs *later* (during the signon gate) and needs the names
to know what's missing. **So before any download code, we must persist the names
onto `cl` and make the load loop deferred + non-fatal**, exactly the shape QSS
uses. This is the real bulk of the work; the download protocol itself is
mechanical once the names survive.

---

## 4. Phased plan (each phase independently shippable + benched)

### Phase 1: Deferred, name-driven precache (the risky refactor; do first)
**No new feature yet, pure refactor, must bench neutral on all targets.**
- Add to `client_state_t` (`client.h`): `char model_name[MAX_MODELS][MAX_QPATH];`
  and `char sound_name[MAX_SOUNDS][MAX_QPATH];` (mirror QSS field names for
  diff-ability).
- In `CL_ParseServerInfo` (`cl_parse.c:357-422`): write names into
  `cl.model_name[]`/`cl.sound_name[]` instead of stack locals.
- Split the load loop out into a helper (e.g. `CL_LoadPrecaches()`) that does the
  `Mod_ForName`/`S_PrecacheSound` pass. On a missing model **do not** `Host_Error`
 , leave the slot NULL and remember it's missing.
- Guard `CL_ParseStaticSound` (`cl_parse.c:964`) against NULL precache.
- Behaviour with no download support yet: a missing map should fail *gracefully*
  (disconnect with a console message) instead of hard `Host_Error`. Confirm
  single-player + LAN co-op unaffected; bench timedemo neutral.

### Phase 2: In-protocol download (delivers the goal)
- `protocol.h`: add `svcdp_downloaddata=50`, `clcdp_ackdownloaddata=51`.
- `client.h`: add the `download` sub-struct to `client_static_t` (`active`,
  `size`, `current[MAX_QPATH]`, `temp[MAX_OSPATH]`, `FILE *file`), plus
  `cl.protocol_dpdownload`, `cl.wronggamedir`, and `model_download`/`sound_download`
  cursors.
- New file `cl_download.c` (add `cl_download.o` to `Makefile.darwin` OBJS after
  `cl_parse.o`): `CL_CheckDownloads`, `CL_CheckDownload`, `CL_Download_Begin_f`,
  `CL_Download_Data`, `CL_Download_Finished_f`, `CL_StopDownload_f`,
  `CL_ServerExtension_Download_f`. Register the `cl_serverextension_download`,
  `cl_downloadbegin`, `cl_downloadfinished`, `stopdownload` commands.
- `common.c`: add `COM_DownloadNameOkay()` and the `allow_download` cvar.
- `cl_parse.c:1069` switch: add `case svcdp_downloaddata:` → `CL_Download_Data()`
  (error if `!cl.protocol_dpdownload`).
- `cl_main.c` `CL_SignonReply` case 1: gate the `prespawn` send on
  `CL_CheckDownloads()` (don't advance while a download is pending; pump from
  `CL_ReadFromServer`).
- **Server side** (so our binary can also *host* downloadable games):
  `host_cmd.c` `Host_Download_f` / `Host_StartDownload_f` / `Host_AppendDownloadData`
  / `Host_DownloadAck`; advertise via `svc_stufftext` in `sv_main.c`; dispatch
  `clcdp_ackdownloaddata` in `sv_user.c`; append chunks from the per-client send
  in `sv_main.c`. Add `download.*` fields to the server client struct (`server.h`).
- This makes "join an internet server by IP and auto-download the map" work.

### Phase 3: Internet server browser (DPMaster, also UDP, no TLS)
- Port QSS's DPMaster query in `net_dgrm.c`: `getservers`/`getserversResponse`,
  per-server `getinfo`/`infoResponse`. Masters e.g.
  `dpmaster.deathmask.net:27950`, `master.frag-net.com:27950`. Cvars
  `net_masterextra1..3`, `sv_public` (heartbeat), `com_protocolname`.
- Lets the in-game server list show public internet games instead of LAN-only
  broadcast. Independent of downloads, can land before or after Phase 2.

### Phase 4 (OPTIONAL: later), HTTP fast-download, then HTTPS
Only if in-protocol UDP proves too slow in practice (see §8 packet-loss caveat).
- 4a: plain-`http://` `sv_downloadurl` redirect via a ~200-line raw-socket
  HTTP/1.1 GET client. **Still no TLS.**
- 4b: `https://` support via bundled **mbedTLS 2.28 LTS** (static, big-endian PPC
  OK, `gcc -arch ppc -std=c99 -DMBEDTLS_NO_PLATFORM_ENTROPY`) + a shipped
  `cacert.pem` in `Contents/Resources/`. Prefer `ChaCha20-Poly1305` (faster than
  AES-GCM without hardware AES on the G3). See §7.

---

## 5. Gating + toggleability (hard requirement: see ADR 0008)

- **Master cvar `allow_download`** (matches QSS): governs both client fetch and
  server serve. **Default it to `0` on this port** given the vintage-OS attack
  surface (untrusted data parsed + written to disk on unpatched 2003 OSes). End
  users / autoexec opt in per machine. A/B-able without rebuild.
- `cl_serverextension_download` already acts as the per-connection enable.
- Add `allow_download` (and any Phase-4 `cl_dl_allow_https`) to
  [`KNOBS.md`](KNOBS.md).
- Phase 4b TLS must be a separate **default-off** cvar, it's the highest-risk,
  lowest-value piece.

---

## 6. Testing + bench

- **Functional:** stand up a QSS (or our own Phase-2) server on `mini-intel`
  hosting a small custom map absent from a client box; `connect` from each target
  and confirm auto-download → play. Verify `..`/absolute/`.cfg`/`.exe` names are
  refused (drive `COM_DownloadNameOkay` with hostile inputs).
- **Regression:** single-player + LAN co-op must be unaffected by Phase 1's
  precache refactor. Confirm a *truly* missing map now disconnects gracefully
  instead of `Host_Error`-crashing.
- **Bench:** Phase 1 must be timedemo-neutral on all targets (it touches the hot
  signon/precache path). Phases 2-4 don't touch the render loop, so timedemo
  should be unchanged, still run the cadence in ADR 0009
  and commit numbers. Download throughput is a separate manual measurement, not a
  timedemo.

---

## 6b. Internet test targets (when the work is done)

### Protocol reality check: test NetQuake, NOT QuakeWorld
QuakeSpasm/QSS speak **NetQuake** (default port **26000**). They do **not** speak
**QuakeWorld** (port 27500, the `ezQuake`/`nQuake` world). The big active
competitive Q1 multiplayer scene is QuakeWorld, **those servers will never work
with our engine.** Ignore QW/ezQuake/nQuake listings and the QuakeWorld tabs on
gametracker. Our targets are NetQuake servers (mostly co-op + some DM/mod),
served by ProQuake / Qrack / DarkPlaces / QSS / FTE-in-NQ-mode.

### Which servers exercise which feature
- **Connect + play (Phase 2/3 baseline):** any NetQuake server. But id1 deathmatch
  servers (maps `dm2`/`dm4`/`dm6`) do **not** test download, you already ship
  those maps.
- **Auto-download (the headline feature):** only triggers when **(a)** the server
  runs an engine that advertises `cl_serverextension_download`, i.e. **QSS or
  DarkPlaces** (ProQuake/Qrack likely won't), **and (b)** it's hosting content
  you don't have locally. **Co-op servers running custom map packs are the ideal
  target**, they routinely host non-id1 maps, which is exactly the download path.
- **Most reliable download test = self-host on `mini-intel`** (already in §6): run
  our own Phase-2 server with a known custom map absent from the client box.
  Deterministic, repeatable, independent of third-party uptime. Do this first;
  use real servers as confirmation.

### Live browsers: pull current addresses at test time (IPs are volatile)
- `https://dpmaster.deathmask.net/?game=quake`, DPMaster web frontend; **this is
  the same master our Phase-3 browser queries**, so it doubles as ground truth.
- `https://servers.quakeone.com/`, most active NetQuake browser (has a NetQuake tab).

### Master servers (also the Phase-3 browser query targets)
- `dpmaster.deathmask.net:27950`
- `master.frag-net.com:27950`

DPMaster `getservers`/`getinfo`; `com_protocolname` must match
(`"FTE-Quake DarkPlaces-Quake"`) to be listed/returned.

### Concrete persistent candidates (snapshot 2026-06-06: re-verify live first)
Prefer the persistent hostnames over raw IPs where given:
- **Co-op (best download candidates):** `sv.netquake.io:26010`; "Coopera"
  (`5.196.63.132:26000`); "FlufyBuny's Quake COOP" (`75.192.156.65:26001`);
  "Cheese Eating Surrender Monkey" (`35.237.45.226:26000`, also `:27000`).
- **DM / mods (connect+play, mostly id1 maps so no download):**
  `acheesecake.servequake.com:26000`, `choosymoms.servequake.com:26000`,
  `quake.shmack.net:26000` (Rune Quake) / `:26001` (Rocket Arena),
  `denver.quakeone.com:26000` (CRMOD), `dallas.quakeone.com:26000` (CTF),
  `37.153.1.44:26000` (WEBA, `dm2`).

Caveat: NetQuake is quiet, most servers sit at 0/N players. For protocol +
download validation that's fine (connect to an empty co-op server, let it push the
custom map). For actual gameplay you'll need to coordinate with another player.

---

## 7. TLS: the optional last 5%, NOT part of this plan

Confirmed by reading the QSS tree: **its download path uses zero TLS, zero curl,
zero http.** The only thing TLS ever buys is reaching `https://` fast-download
*mirrors* (Phase 4b), a DarkPlaces/ioquake3 convenience. The system crypto on
these Macs (Tiger/Leopard OpenSSL, Secure Transport) predates TLS 1.2/SNI/modern
ciphers/current root CAs and cannot complete a 2026 handshake, so *if* we ever do
4b we bundle our own: **mbedTLS 2.28 LTS**, static, pure C, builds on the gcc-4.0
PPC toolchain, big-endian clean, + a shipped Mozilla `cacert.pem`. But that's
strictly optional and downstream of everything above.

**Bottom line: ship the whole "browse → join → auto-download → play" loop with no
new dependency at all.**

---

## 8. Caveats to respect (MISTAKES.md discipline)

- **This is NOT "load-time / zero risk."** It's a live network attack surface:
  untrusted data parsed and written to disk on unpatched 20-year-old OSes. The
  `COM_DownloadNameOkay` allowlists (dir + extension), the 50 MB cap, the
  temp-then-rename, and **default-off `allow_download`** are non-negotiable.
- **Packet loss:** QSS's DP-style data rides the *unreliable* datagram with an
  ack/rewind window. Spike's own comment notes it "doesn't cope with packetloss
  so well." On a G3 over real-internet WiFi expect slow-but-eventual, sometimes
  stalled, downloads. If that's unacceptable in practice, Phase 4a (HTTP) is the
  escape hatch, not FTE's chunked extension (more complexity for marginal gain).
- **Wire compatibility:** keep `svcdp_downloaddata=50` / `clcdp_ackdownloaddata=51`
  exactly so our client interoperates with stock QSS servers and vice-versa.
- **Phase 1 is the real risk**, not the protocol. The precache refactor touches
  the signon hot path that every connect goes through, bench it neutral and test
  SP/coop hard before building Phase 2 on top.

---

## 9. Effort estimate

- Phase 1 (precache refactor): the genuinely fiddly part, touches shared signon
  code. Small LOC, high care.
- Phase 2 (in-protocol download): ~400 LOC lifted from QSS across `cl_download.c`
  (new), `host_cmd.c`, `common.c`, plus ~10 small insertions in `protocol.h`,
  `client.h`, `server.h`, `cl_parse.c`, `sv_user.c`, `sv_main.c`, `Makefile.darwin`.
  No new deps.
- Phase 3 (DPMaster browser): self-contained in `net_dgrm.c`.
- Phase 4 (HTTP/TLS): optional, only if §8 packet-loss bites.

### Source URLs read for this plan (2026-06-06)
- QSS: `https://github.com/Shpoike/Quakespasm` (branch `qsrebase`, `Quake/`)
- DarkPlaces: `https://github.com/DarkPlacesEngine/DarkPlaces` (`libcurl.c`, `fs.c`, `cl_parse.c`, `sv_main.c`)
- FTE: `https://github.com/fte-team/fteqw` (`engine/common/protocol.h`)
- ironwail: `https://github.com/andrei-drexler/ironwail` (`Quake/host_cmd.c`)
- Server landscape: `https://dpmaster.deathmask.net/?game=quake`, `https://servers.quakeone.com/`
