# Build environment for the Linux dedicated server release.
#
# Debian 11 on purpose, not something current. The oldest glibc we build
# against is the oldest system the result will run on, and glibc symbol
# versioning only works in that direction: a binary built against 2.31 runs on
# 2.35, never the reverse. Debian 11 gives glibc 2.31, so the release runs on
# Ubuntu 20.04 and everything newer, which covers every distro anyone is
# realistically going to put on a VPS.
#
# This is the same reasoning as the 10.6 deployment target on the Intel Mac
# slice: build against the floor, run everywhere above it.
# Pinned for reproducibility: the base by digest (multi-arch index), and apt to
# a snapshot.debian.org date. Debian 11 LTS ended 2026-08-31 and bullseye is
# leaving the live mirrors (404s on amd64, 2026-09-23); archive.debian.org
# fails against this newer image ("held broken packages"). The snapshot keeps
# glibc 2.31-13+deb11u14, so the Debian 11 / Ubuntu 20.04 floor is unchanged.
# Measured by old-mac-build-host, 2026-09-23.
FROM debian:11@sha256:99cdf7792e25416bd801861ccd8e2fb27fb527b25e8d9a8704ebc3ead2015675

ARG SNAPSHOT=20260820T000000Z
RUN printf 'deb http://snapshot.debian.org/archive/debian/%s bullseye main\ndeb http://snapshot.debian.org/archive/debian/%s bullseye-updates main\ndeb http://snapshot.debian.org/archive/debian-security/%s bullseye-security main\n' \
      "$SNAPSHOT" "$SNAPSHOT" "$SNAPSHOT" > /etc/apt/sources.list \
 && rm -f /etc/apt/sources.list.d/*

RUN apt-get -o Acquire::Check-Valid-Until=false update && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      curl \
      file \
      libgl1-mesa-dev \
      pkg-config \
      procps \
      iproute2 \
      xz-utils \
 && rm -rf /var/lib/apt/lists/*
