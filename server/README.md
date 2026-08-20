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

## Connecting

From the Mac client, on any of the machines the port supports:

```
connect your.server.address
```

Nothing about the client differs for internet play. The server is
little-endian and the PowerPC clients are big-endian; the protocol handles
that, and it is the same code path the Mac builds already use on a LAN.

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
