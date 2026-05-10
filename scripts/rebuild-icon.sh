#!/usr/bin/env bash
#
# rebuild-icon.sh — regenerate MacOSX/QuakeSpasm.icns from a source PNG.
#
# Pipeline:
#   1. Pillow on Ubuntu resizes the source PNG into the standard Apple
#      iconset (icon_NxN.png + icon_NxN@2x.png at all canonical sizes).
#   2. The iconset is tar-piped to the cross-build host (mini-intel,
#      Lion 10.7) and run through `iconutil -c icns`. Apple's canonical
#      Apple-format encoder produces TOC + modern PNG chunks (ic07-ic14)
#      plus the smaller legacy chunks (is32/s8mk/il32/l8mk).
#   3. A small Python step appends the larger legacy chunks
#      (ih32/h8mk/it32/t8mk) that iconutil omits but Tiger 10.4 Finder
#      uses for 48-px and 128-px display. Without these, Tiger shows a
#      blurry upscale of the 32-px legacy chunk at larger Finder sizes.
#
# The resulting .icns is universal: Panther 10.3 + Tiger 10.4 + Lion 10.7
# + Sequoia 15.7 + Retina-aware modern macOS all render the icon at full
# native quality.
#
# Usage:
#   scripts/rebuild-icon.sh [source.png] [out.icns]
#     defaults: MacOSX/quake_icon_holes_filled.png  →  MacOSX/QuakeSpasm.icns
#
# Pre-reqs: Pillow on Ubuntu (python3 -m pip install Pillow), Lion host
# alias `mini-intel` reachable, iconutil on Lion (preinstalled).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_PNG="${1:-$REPO_ROOT/MacOSX/newiconfinal.png}"
OUT_ICNS="${2:-$REPO_ROOT/MacOSX/QuakeSpasm.icns}"
BUILD_HOST="${BUILD_HOST:-mini-intel}"

if [ ! -f "$SRC_PNG" ]; then
  echo "[rebuild-icon] ERROR: source PNG not found: $SRC_PNG" >&2
  exit 2
fi

# Stage temp work area; cleaned up on exit.
WORK=$(mktemp -d -t qsicon.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

ICONSET="$WORK/QuakeSpasm.iconset"
mkdir -p "$ICONSET"

echo "[rebuild-icon] source: $SRC_PNG"
echo "[rebuild-icon] output: $OUT_ICNS"
echo "[rebuild-icon] build host: $BUILD_HOST"
echo "[rebuild-icon] work dir: $WORK"

# Step 1: Pillow resize → iconset directory
echo "[rebuild-icon] step 1/3: building iconset (Pillow)"
python3 <<EOF
from PIL import Image
src = Image.open("$SRC_PNG").convert("RGBA")
print(f"  source: {src.size} {src.mode}")
sizes = [
    (16,   "icon_16x16.png"),
    (32,   "icon_16x16@2x.png"),
    (32,   "icon_32x32.png"),
    (64,   "icon_32x32@2x.png"),
    (128,  "icon_128x128.png"),
    (256,  "icon_128x128@2x.png"),
    (256,  "icon_256x256.png"),
    (512,  "icon_256x256@2x.png"),
    (512,  "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]
for px, name in sizes:
    out = src.resize((px, px), Image.LANCZOS)
    out.save("$ICONSET/" + name, format="PNG", optimize=True)
EOF

# Step 2: ship iconset to Lion + run iconutil
echo "[rebuild-icon] step 2/3: iconutil on $BUILD_HOST"
( cd "$WORK" && tar cf - QuakeSpasm.iconset ) | \
  ssh "$BUILD_HOST" 'rm -rf /tmp/QuakeSpasm.iconset && cd /tmp && tar xf -'
ssh "$BUILD_HOST" '
  cd /tmp
  rm -f QuakeSpasm-iconutil.icns
  iconutil -c icns QuakeSpasm.iconset -o QuakeSpasm-iconutil.icns
'
scp -q "$BUILD_HOST:/tmp/QuakeSpasm-iconutil.icns" "$WORK/iconutil.icns"

# Step 3: splice in legacy 48/128 chunks (iconutil emits is32/il32 but
#         drops ih32/it32; Tiger 10.4 Finder uses those at large sizes).
#         Also splice in the Panther-era 1-bit ICN# / ics# chunks that
#         iconutil never produces — Panther 10.3 Finder may walk these
#         first when CFBundleIconFile resolves.
#         Then REORDER the chunks so legacy chunks come BEFORE TOC and
#         the ic07-ic14 modern PNG chunks. Tiger walks chunks linearly
#         and stops at the first match for the requested display size;
#         a leading TOC + giant PNG chunks can otherwise cause Tiger
#         Finder to fall back to the default app icon. Modern macOS
#         doesn't care about chunk order — it uses TOC offsets when
#         present and walks linearly otherwise.
echo "[rebuild-icon] step 3/3: splice legacy + reorder for Tiger/Panther"
python3 <<EOF
import struct
from PIL import Image

def rle_channel(data):
    out = bytearray(); i = 0; n = len(data)
    while i < n:
        run = 1
        while i + run < n and data[i+run] == data[i] and run < 130:
            run += 1
        if run >= 3:
            out.append(run + 125); out.append(data[i]); i += run
        else:
            ls = i
            while i < n:
                if i+2 < n and data[i] == data[i+1] == data[i+2]:
                    break
                i += 1
                if i - ls >= 128: break
            ll = i - ls
            out.append(ll - 1); out.extend(data[ls:ls+ll])
    return bytes(out)

def rgb_chunk(img, size, with_header):
    img = img.resize((size, size), Image.LANCZOS).convert("RGBA")
    pix = list(img.getdata())
    payload = (rle_channel(bytes(p[0] for p in pix)) +
               rle_channel(bytes(p[1] for p in pix)) +
               rle_channel(bytes(p[2] for p in pix)))
    return (b"\x00\x00\x00\x00" + payload) if with_header else payload

def mask_chunk(img, size):
    img = img.resize((size, size), Image.LANCZOS).convert("RGBA")
    return bytes(p[3] for p in img.getdata())

def bw_pair(img, size):
    """1-bit bitmap + mask, classic Mac ICN# / ics# format."""
    img = img.resize((size, size), Image.LANCZOS).convert("RGBA")
    pix = list(img.getdata())
    bits = bytearray(); mask = bytearray()
    bb = 0; mb = 0; nb = 0
    for r,g,b,a in pix:
        gray = (r*299 + g*587 + b*114) // 1000
        if a > 16:
            bb = (bb << 1) | (1 if gray < 128 else 0)
            mb = (mb << 1) | 1
        else:
            bb = (bb << 1); mb = (mb << 1)
        nb += 1
        if nb == 8:
            bits.append(bb); mask.append(mb)
            bb = mb = nb = 0
    return bytes(bits), bytes(mask)

def chunk(four_cc, payload):
    return four_cc + struct.pack(">I", 8 + len(payload)) + payload

with open("$WORK/iconutil.icns","rb") as f:
    icnu = f.read()
assert icnu[:4] == b"icns"

src = Image.open("$SRC_PNG").convert("RGBA")

# Walk what iconutil produced
existing = []
off = 8
while off < len(icnu):
    typ = icnu[off:off+4]
    sz = struct.unpack(">I", icnu[off+4:off+8])[0]
    existing.append((typ, icnu[off:off+sz]))
    off += sz

existing_types = {c[0] for c in existing}

# Build all the chunks we want (favouring iconutil's where it produced one).
all_chunks = {}

# 1-bit Panther chunks (iconutil doesn't emit these)
ib32, im32 = bw_pair(src, 32)
ib16, im16 = bw_pair(src, 16)
all_chunks[b"ICN#"] = chunk(b"ICN#", ib32 + im32)
all_chunks[b"ics#"] = chunk(b"ics#", ib16 + im16)

# Legacy color chunks 16/32 (iconutil emits these — keep its versions)
for c in existing:
    if c[0] in (b"is32", b"s8mk", b"il32", b"l8mk"):
        all_chunks[c[0]] = c[1]

# Larger legacy color chunks 48/128 (iconutil omits — we synthesize)
all_chunks[b"ih32"] = chunk(b"ih32", rgb_chunk(src, 48,  False))
all_chunks[b"h8mk"] = chunk(b"h8mk", mask_chunk(src, 48))
all_chunks[b"it32"] = chunk(b"it32", rgb_chunk(src, 128, True))
all_chunks[b"t8mk"] = chunk(b"t8mk", mask_chunk(src, 128))

# Modern PNG chunks (iconutil's output) and the TOC
for c in existing:
    if c[0] in (b"ic07", b"ic08", b"ic09", b"ic10", b"ic11", b"ic12", b"ic13", b"ic14", b"TOC "):
        all_chunks[c[0]] = c[1]

# Order: legacy 1-bit + 32-bit + masks (Panther/Tiger walk these first),
# then modern PNG chunks (Lion+ Retina), then TOC last (modern macOS
# rebuilds offsets from chunks anyway when TOC is missing/wrong).
LEGACY_ORDER = [b"ICN#", b"ics#",
                b"is32", b"s8mk", b"il32", b"l8mk",
                b"ih32", b"h8mk", b"it32", b"t8mk"]
MODERN_PNG   = [b"ic07", b"ic08", b"ic09", b"ic10",
                b"ic11", b"ic12", b"ic13", b"ic14"]

body = b""
for typ in LEGACY_ORDER + MODERN_PNG + [b"TOC "]:
    if typ in all_chunks:
        body += all_chunks[typ]

new_total = 8 + len(body)
out_bytes = b"icns" + struct.pack(">I", new_total) + body

with open("$OUT_ICNS","wb") as f:
    f.write(out_bytes)

print(f"  wrote {new_total} bytes, chunk inventory:")
off = 8
while off < new_total:
    typ = out_bytes[off:off+4].decode("ascii", errors="replace")
    sz  = struct.unpack(">I", out_bytes[off+4:off+8])[0]
    print(f"    {typ!r:<8s} {sz} bytes")
    off += sz
EOF

# Step 4: refresh docs/images PNG copies for README hero strip.
echo "[rebuild-icon] step 4/4: refresh docs/images/quakespasm-icon*.png"
python3 <<EOF
from PIL import Image
src = Image.open("$SRC_PNG").convert("RGBA")
src.resize((256, 256), Image.LANCZOS).save("$REPO_ROOT/docs/images/quakespasm-icon-256.png", optimize=True)
src.resize((1024, 1024), Image.LANCZOS).save("$REPO_ROOT/docs/images/quakespasm-icon.png", optimize=True)
EOF

echo "[rebuild-icon] done."
echo "[rebuild-icon] next: deploy with scripts/deploy.sh <machine> to ship the new icon"
