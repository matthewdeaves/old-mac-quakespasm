# watchlink: live player-state UDP feed (Apple Watch tactical computer)

`Quake/cl_watchlink.c` pushes the ranger's live in-game state out over UDP as
newline-delimited JSON, so an external companion can render
health / armor / ammo / weapon / powerups on a second screen.

It is the **Quake 1 sibling** of the same feature in the
[old-mac-quake2](https://github.com/matthewdeaves/old-mac-quake2) port: it speaks
the **same wire format** on the **same UDP port (27999)** and discovers the
**same Bonjour service (`_q2watch._udp`)**, so one unchanged companion app drives
both games. The companion (iPhone relay + watchOS app) lives in its own repo:
**[quake2-tactical-watch](https://github.com/matthewdeaves/quake2-tactical-watch)**.

Quake 1 has no in-game help computer (no F1 objectives screen), so the companion
simply shows the sector name with no objectives panel, a graceful, cut-down HUD.
Everything the watch shows for Quake II that Quake 1 *does* have, health, armor,
ammo, current weapon, powerups (with an estimated countdown), pickups, damage
haptics, works identically.

**Off by default.** The whole feature is gated on the `watch_host` cvar: empty ⇒
no socket touched, no per-frame work, no packets. The default fleet build, the
benchmarks and the DMG behave identically. This is a *runtime* opt-in, not a
load-time change (see [`MISTAKES.md`](../MISTAKES.md) on "zero-risk load-time"
traps).

## Cvars

| cvar | default | meaning |
|---|---|---|
| `watch_host` | `""` | destination `ip` / `ip:port`, or `"auto"` for Bonjour; empty disables the feature |
| `watch_port` | `27999` | port used when `watch_host` omits one |
| `watch_rate` | `10` | vitals heartbeat, Hz (floored to ≥1 ms interval) |
| `watch_events` | `1` | also emit discrete damage / centerprint / sound events |

All four are `CVAR_ARCHIVE`, so they persist in `config.cfg`. Set live from the
console, or from an `autoexec-*.cfg`:

```
set watch_host "192.168.1.50"
```

On the fleet, `set watch_host "auto"` belongs in the per-machine bundle cfg
(`autoexec-<machine>.cfg`) so it runs after `config.cfg`.

## Wire format (newline-delimited JSON: UDP)

Endianness-proof on the big-endian PPC fleet; debuggable with `nc -ul 27999`.

```
{"t":"vitals","hp":87,"armor":50,"ammo":24,"sel":"Super Shotgun",
 "frags":3,"flashes":0,"layouts":0,"spec":0,"pu":{"icon":"quad","sec":18}}
{"t":"meta","level":"the Slipgate Complex","items":["Axe","Shotgun",...]}  // once per map load
{"t":"event","kind":"centerprint","msg":"You got the Rocket Launcher"}
{"t":"event","kind":"damage","health":1,"armor":1,"ammo":0}                // on svc_damage
{"t":"event","kind":"psound","msg":"pain1"}                               // local-player SFX basename
```

- **vitals**, throttled to `watch_rate` Hz from `cl.stats[]` / `cl.items`.
  `sel` is the active weapon name (mapped from `cl.stats[STAT_ACTIVEWEAPON]`).
  `pu.icon` is one of `quad` / `pent` / `ring` / `envir` (Quad, Pentagram,
  Ring of Shadows, Biosuit) with `sec` estimated from `cl.item_gettime` against
  Quake's 30-second powerup duration. Quake 1 has no `STAT_LAYOUTS` or
  spectator stat, so `layouts` / `spec` are always `0`. `flashes` mirrors the
  most recent `svc_damage` (bit 1 = blood, bit 2 = armor) so the wrist buzz
  rides the reliable vitals heartbeat as well as the discrete `damage` event;
  it clears the moment the heartbeat carries it. The wire shape is kept
  identical to the Quake II feed.
- **meta**, level name (`cl.levelname`, falling back to `cl.mapname`) plus the
  weapons currently owned (synthesised from `cl.items`; Quake 1 has no item-name
  configstring table). Sent once per map load, sub-MTU so it never fragments.
- **event/centerprint**, mirrors `SCR_CenterPrint` (pickups, story text).
- **event/damage**, fired the instant `svc_damage` arrives, for a wrist haptic;
  `health`/`armor` flag which subsystem took the hit.
- **event/psound**, the local player's vocal / pickup sounds, forwarded as the
  bare basename: `player/*` (vocals), `items/*` (health/armor/powerups),
  `weapons/pkup.wav` (weapon pickup), `weapons/lock4.wav` (ammo + backpack
  pickup), and `misc/*key*.wav` (door / rune keys).

There is **no** `objectives` event (Quake 1 has no F1 help computer); the
companion shows the sector name only and hides its objectives panel.

## Integration points

- `CL_WatchLink_Init`, `cl_main.c` `CL_Init` (registers cvars).
- `CL_WatchLink_Frame`, `host.c` `_Host_Frame`, after `CL_ReadFromServer`
  (heartbeat + map-change detection + queued meta).
- `CL_WatchLink_CenterPrint`, `gl_screen.c` `SCR_CenterPrint`.
- `CL_WatchLink_Damage`, `view.c` `V_ParseDamage`.
- `CL_WatchLink_Sound`, `cl_parse.c` `CL_ParseStartSoundPacket`, for the local
  player's entity only (`ent == cl.viewentity`).

watchlink opens its **own** non-blocking UDP socket (POSIX everywhere the fleet
runs; Winsock on Windows builds) rather than borrowing the engine's net layer:
in single-player the client talks to the local server over loopback and has no
socket usable for a real LAN destination. Sends are fire-and-forget, so an
unreachable `watch_host` never stalls the frame.

## Zero-config discovery (macOS)

`watch_host "auto"` browses Bonjour for the companion's `_q2watch._udp` service
(libSystem/mDNSResponder, present on every Mac the fleet targets, Panther 10.3.9
through Lion). The browse/resolve SDK headers drifted across OS versions; the
single source file papers over the gaps (see the comments at the top of
`cl_watchlink.c`) so one slice compiles, and auto-discovers, for every fleet
arch. Discovery is time-bounded (~30 s) and re-arms on each map load, so a
phoneless game costs no CPU.

## Desktop testing

```
nc -ul 27999                          # one terminal, raw JSON
# then in-game:  set watch_host "127.0.0.1"
```

The Quake II repo also ships `scripts/watchlink-listen.py`, a friendlier desktop
listener that decodes the same feed.
