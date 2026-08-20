# 11. The dedicated server is a Linux ELF built in a container

Date: 2026-08-20
Status: accepted

## Context

The clients are vintage Macs. Hosting a game on one of them means the oldest,
slowest and least secure machine in the fleet is the one exposed to the network.
A separate headless server built from the same source removes that.

## Decision

**`scripts/build-server-linux.sh` builds a headless Linux server from the same
tree, in a Debian 11 container** (`--arch aarch64` for an ARM VPS). Needs Docker
or Colima and nothing else; the container is what pins the result to glibc 2.31
rather than to whatever the build machine happens to have.

- **One ELF, no packages to install.** Runs on any Linux with glibc 2.31 or
  newer, which is Ubuntu 20.04+ and Debian 11+. The only shared libraries it
  loads are part of glibc.
- **SDL is compiled in statically with every backend disabled, and there is no
  OpenGL in the binary at all**, so it cannot be used as a client. This is the
  one place in the project that builds with `USE_SDL2=1` (ADR 0003).
- **No game data ships.** ADR 0012.
- **Not advertised anywhere.** `sv_public 0` is set explicitly and the three
  master server addresses are blanked.
- **The firewall is the only lock on the door**, and the README says so rather
  than implying belt and braces. Quake's netcode is from 1996: NetQuake has no
  authentication, no encryption and no password, and there is no setting that
  makes the server challenge a connection. If it is reachable, it is joinable.
- `server.cfg` must be in `id1/`, not beside the binary, Quake's `exec`
  searches the game directory, and a copy in the wrong place is never read and
  never complains.
- **The player limit comes from `-dedicated N` in the systemd unit, not from
  `server.cfg`.** NetQuake fixes the limit before any config file is read.
  Eight is the shipped default.
- **NetQuake has no rcon.** The only way in is the server's own console, which
  the systemd unit exposes as a FIFO at `/run/quakespasm-server/console`; output
  goes to the journal.

## Security measurements

Measured against this exact build:

| Query | Sent | Received | Amplification |
|---|---|---|---|
| `CCREQ_SERVER_INFO` | 12 bytes | 36 bytes | **3×** |

Three times is not worth an attacker's trouble, because a reflector is only
useful if it multiplies. For comparison the sister servers in this family
measure **101× (Half-Life), 32× (Quake III), 23× (Quake II)**. NetQuake's
control protocol simply does not hand out much.

The out-of-band handler survived **4000 malformed packets** without crashing,
and its remaining unbounded string copies are all on startup arguments or local
socket addresses, not on anything a stranger can send.

This tree is **12 commits behind upstream, none of them security related**, the
closest to upstream of the four ports in this family.

## Consequences

- A 449 MHz G3 and a 2019 iMac can share the same public server.
- The server is little-endian and the PowerPC clients are big-endian; the
  protocol handles it, and it is the same code path the Mac builds already use
  on a LAN. Nothing to configure.
- **The server speaks protocol 666 (FitzQuake)**, which is what this client
  build expects. A stock 1996 Quake client speaking protocol 15 is not what
  connects here, so there is nothing to trade away.
- `net_messagetimeout` is left at 300 rather than tightened, because a vintage
  Mac stalling briefly on a slow link should not be dropped for it.
- Keep the map rotation to maps that have been watched running on the oldest
  machine that will join.
