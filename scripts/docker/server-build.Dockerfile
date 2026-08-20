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
FROM debian:11

RUN apt-get update && apt-get install -y --no-install-recommends \
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
