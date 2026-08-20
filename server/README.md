# QuakeSpasm dedicated server, Linux

A headless Quake server built from the same source as the Mac fat binary. One
ELF binary, no packages to install.

## What is in the tarball

```
quakespasm-server            the server
server.cfg                   configuration, goes in id1/
systemd/quakespasm-server.service
BUILD-INFO.txt               what this was built from
```

No game data. Quake's content is id Software's and is not ours to ship. You
supply `id1/pak0.pak` and `id1/pak1.pak` from your own copy.

## Requirements

Any Linux with glibc 2.31 or newer, which means Ubuntu 20.04 and up, Debian 11
and up. Nothing to install: the only shared libraries this binary loads are
part of glibc itself.

SDL is compiled in, statically, with every backend disabled. There is no
OpenGL in this binary at all, so it cannot be used as a client.

## Install

```sh
sudo useradd --system --home /opt/quakespasm-server --shell /usr/sbin/nologin quake
sudo mkdir -p /opt/quakespasm-server/id1
sudo tar xzf quakespasm-server-*-linux-x86_64.tar.gz --strip-components=1 \
     -C /opt/quakespasm-server
sudo cp /opt/quakespasm-server/server.cfg /opt/quakespasm-server/id1/server.cfg

# your own copy of the game
sudo cp pak0.pak pak1.pak /opt/quakespasm-server/id1/

sudo chown -R quake:quake /opt/quakespasm-server
sudo cp /opt/quakespasm-server/systemd/quakespasm-server.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now quakespasm-server
```

`server.cfg` has to be in `id1/`, not next to the binary. Quake's `exec`
searches the game directory, so a copy in the wrong place is never read and
never complains.

## Changing the map, and everything else

NetQuake has no rcon. The only way in is the server's own console, which the
systemd unit exposes as a FIFO:

```sh
echo "map e1m2"     | sudo tee /run/quakespasm-server/console
echo "status"       | sudo tee /run/quakespasm-server/console
echo "fraglimit 30" | sudo tee /run/quakespasm-server/console
```

Console output goes to the journal:

```sh
journalctl -u quakespasm-server -f
```

If you would rather watch it live and type into it directly, run the binary
under `tmux` instead of systemd and attach when you want it.

## The network side

Default port is UDP 26000. Only that one port needs to be reachable.

```sh
sudo ufw allow from <their.ip.here> to any port 26000 proto udp
sudo ufw allow from <your.ip.here>  to any port 26000 proto udp
```

Be aware of what this protocol is. Quake's netcode is from 1996, it has no
authentication and no encryption, and NetQuake has no password: there is no
setting that makes the server challenge someone who connects. If it is
reachable, it is joinable. So the firewall is not belt and braces here, it is
the only lock on the door. If both ends have dynamic addresses, re-resolve a
dynamic DNS name from a cron job and rewrite the rules rather than opening the
port to the world.

The server is not advertised anywhere. `sv_public 0` is set explicitly and the
three master server addresses are blanked, so it appears in no public list.

### Amplification

Measured against this exact build, Quake 1 is by far the best behaved of the
four servers in this family:

| Query | Sent | Received | Amplification |
|---|---|---|---|
| `CCREQ_SERVER_INFO` | 12 bytes | 36 bytes | 3x |

Three times is not worth an attacker's trouble, because a reflector is only
useful if it multiplies. For comparison the others measure 101x (Half-Life),
32x (Quake III) and 23x (Quake II). NetQuake's control protocol simply does
not hand out much.

It is also the engine closest to upstream: our tree is 12 commits behind, none
of them security related. Combined with the fuzzing below, this is the server
of the four that needs the least worrying about, which is a pleasant inversion
of it being the oldest game.

The out-of-band handler survived 4000 malformed packets without crashing, and
its remaining unbounded string copies are all on startup arguments or local
socket addresses, not on anything a stranger can send.

## Connecting

From the Mac client, on any of the machines the port supports:

```
connect your.server.address
```

A hostname works too, and is the better answer: the engine resolves through
`getaddrinfo`, so point an A record at the box and that name is all either of
you types.

## Tuned for the machines that will actually connect

The clients are the fat binary: `ppc750`, `ppc7400`, `i386`, `x86_64` and
`arm64` from one app, and the config is aimed at the oldest of those.

`net_messagetimeout` is left at 300 rather than tightened, because a vintage
Mac stalling briefly on a slow link should not be dropped for it. Keep the map
rotation to maps you have watched run on the oldest machine that will join.

Endianness needs nothing from you. The server is little-endian and the PowerPC
clients are big-endian; the protocol handles it, and it is the same code path
the Mac builds already use on a LAN.

One thing specific to Quake 1: this server speaks protocol 666 (FitzQuake),
which is what our client build expects. A stock 1996 Quake client speaking
protocol 15 is not what is connecting here, so there is nothing to trade away.

## Player limit

Set by `-dedicated N` in the systemd unit, not by `server.cfg`. NetQuake fixes
the limit before any config file is read, so it can only come from the command
line. Eight is the shipped default.

## Building it yourself

```sh
scripts/build-server-linux.sh                 # x86_64
scripts/build-server-linux.sh --arch aarch64  # ARM VPS
```

Needs Docker or Colima and nothing else. The build runs in a Debian 11
container so the result depends on glibc 2.31 rather than on whatever the
build machine happens to have.
