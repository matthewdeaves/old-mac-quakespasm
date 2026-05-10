#!/usr/bin/env python3
"""
Build a maximally-compatible Mac OS ICNS file from a source PNG.

Produces both:
  - Legacy chunks (RLE-compressed RGB + 8-bit alpha mask) for sizes
    16/32/48/128 — recognized by Panther 10.3 and Tiger 10.4 Finders.
  - Modern PNG-encoded chunks (ic07/ic08/ic09/ic10) for 128/256/512/1024 —
    used by Snow Leopard 10.6 and later.

ICNS RLE format (per legacy 'is32'/'il32'/'ih32'/'it32' chunks):
  - 'it32' (128x128) only: 4 leading zero bytes, then channels.
  - Three channels concatenated in order: red, green, blue.
  - Each channel is a stream of:
      * If first byte >= 0x80: run-of-same. Length = byte - 125 (so 3..130).
        Followed by 1 data byte; emit it `length` times.
      * Else: literal run. Length = byte + 1 (so 1..128). Followed by
        `length` data bytes; emit each.

Mask chunks ('s8mk'/'l8mk'/'h8mk'/'t8mk') are plain uncompressed 8-bit
alpha values (1 byte per pixel, no RLE, no header).
"""

import io
import struct
import sys
from PIL import Image


def rle_channel(data: bytes) -> bytes:
    """Encode a single channel using ICNS RLE."""
    out = bytearray()
    i = 0
    n = len(data)
    while i < n:
        # Try to extend a run (same byte 3+ times).
        run_len = 1
        while i + run_len < n and data[i + run_len] == data[i] and run_len < 130:
            run_len += 1
        if run_len >= 3:
            out.append(run_len + 125)  # 0x80..0xff range
            out.append(data[i])
            i += run_len
        else:
            # Literal run: extend until we'd start a >=3 run or hit 128 max.
            lit_start = i
            while i < n:
                if i + 2 < n and data[i] == data[i + 1] == data[i + 2]:
                    break
                i += 1
                if i - lit_start >= 128:
                    break
            lit_len = i - lit_start
            out.append(lit_len - 1)  # 0..127
            out.extend(data[lit_start:lit_start + lit_len])
    return bytes(out)


def encode_legacy_rgb(img: Image.Image, size: int, with_header: bool) -> bytes:
    """Encode a size×size RGBA image as RLE RGB chunk (with 4-byte zero
    header for it32; without for is32/il32/ih32)."""
    img = img.resize((size, size), Image.LANCZOS).convert("RGBA")
    pixels = list(img.getdata())
    r = bytes(p[0] for p in pixels)
    g = bytes(p[1] for p in pixels)
    b = bytes(p[2] for p in pixels)
    payload = rle_channel(r) + rle_channel(g) + rle_channel(b)
    if with_header:
        return b"\x00\x00\x00\x00" + payload
    return payload


def encode_legacy_mask(img: Image.Image, size: int) -> bytes:
    """Encode a size×size 8-bit alpha mask (uncompressed)."""
    img = img.resize((size, size), Image.LANCZOS).convert("RGBA")
    return bytes(p[3] for p in img.getdata())


def encode_png_chunk(img: Image.Image, size: int) -> bytes:
    """Encode a size×size image as PNG bytes (for modern ic07/ic08/etc.)."""
    img = img.resize((size, size), Image.LANCZOS).convert("RGBA")
    buf = io.BytesIO()
    img.save(buf, format="PNG", optimize=True)
    return buf.getvalue()


def make_chunk(four_cc: bytes, payload: bytes) -> bytes:
    """Build an ICNS sub-chunk: 4-byte type + 4-byte big-endian length
    (= 8 + len(payload)) + payload."""
    assert len(four_cc) == 4
    return four_cc + struct.pack(">I", 8 + len(payload)) + payload


def build_icns(src_png: str, dst_icns: str) -> None:
    src = Image.open(src_png).convert("RGBA")
    print(f"source: {src.size} {src.mode}")

    chunks = []

    # Legacy chunks for Panther/Tiger Finder compatibility.
    # is32 (16) + s8mk (16)
    chunks.append(make_chunk(b"is32", encode_legacy_rgb(src, 16,  False)))
    chunks.append(make_chunk(b"s8mk", encode_legacy_mask(src, 16)))
    # il32 (32) + l8mk (32)
    chunks.append(make_chunk(b"il32", encode_legacy_rgb(src, 32,  False)))
    chunks.append(make_chunk(b"l8mk", encode_legacy_mask(src, 32)))
    # ih32 (48) + h8mk (48)
    chunks.append(make_chunk(b"ih32", encode_legacy_rgb(src, 48,  False)))
    chunks.append(make_chunk(b"h8mk", encode_legacy_mask(src, 48)))
    # it32 (128) + t8mk (128) -- it32 has the 4-byte zero header
    chunks.append(make_chunk(b"it32", encode_legacy_rgb(src, 128, True)))
    chunks.append(make_chunk(b"t8mk", encode_legacy_mask(src, 128)))

    # Modern PNG-encoded chunks for Snow Leopard+ and Retina:
    # ic07 (128), ic08 (256), ic09 (512), ic10 (1024)
    chunks.append(make_chunk(b"ic07", encode_png_chunk(src, 128)))
    chunks.append(make_chunk(b"ic08", encode_png_chunk(src, 256)))
    chunks.append(make_chunk(b"ic09", encode_png_chunk(src, 512)))
    chunks.append(make_chunk(b"ic10", encode_png_chunk(src, 1024)))

    body = b"".join(chunks)
    total = 8 + len(body)
    icns = b"icns" + struct.pack(">I", total) + body

    with open(dst_icns, "wb") as f:
        f.write(icns)

    print(f"wrote {dst_icns}: {total} bytes")
    # Print chunk inventory for verification.
    off = 8
    while off < total:
        typ = icns[off:off+4].decode("ascii")
        sz = struct.unpack(">I", icns[off+4:off+8])[0]
        print(f"  {typ!r:<8s} {sz} bytes")
        off += sz


if __name__ == "__main__":
    src = sys.argv[1] if len(sys.argv) > 1 else "/home/matt/Downloads/quake_icon_holes_filled.png"
    dst = sys.argv[2] if len(sys.argv) > 2 else "/tmp/QuakeSpasm.icns"
    build_icns(src, dst)
