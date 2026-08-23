#!/usr/bin/env python3
"""frame-check.py - do these frames look like rendered Quake, or like a bug?

    tests/frame-check.py benchmarks/screenshots/<host>/spasm*.tga

Reads screenshots the engine wrote and asserts properties every correct frame
of this game has, on every machine we ship to. Exit 0 if all pass.

Nothing else in this repo looks at the picture. bench.sh parses an fps line,
smoke-dmg.sh checks the app comes up, deploy.sh md5s the binary, and
screenshot.sh captures images for a human and compares nothing. So a build
could render the world wrongly and pass everything we run. See issue #26.

WHY NOT A REFERENCE IMAGE

The obvious check is a golden frame per machine class, committed and diffed.
This repo cannot have one: a screenshot of a Quake map is id content and
CLAUDE.md's rule is that we ship code, not content (ADR 0012). Even the
capture directory is gitignored. So this checks PROPERTIES of the picture
rather than the picture itself.

That trade decides what it catches. It catches a frame that is blank, black,
blown out, one flat colour, or has lost its texture detail -- old-mac-quake3
found world surfaces rendering untextured while models and HUD were fine, and
that is a loss of local detail. It does NOT catch geometry drawn with the
right textures in the wrong shape. Catching that needs a reference, and a
reference needs a decision about the content rule that is not mine to make.

WHY THE MAIN CHECK IS PER-RUN AND NOT PER-FRAME

This is the part that differs from the sibling ports, and it is measured
rather than inherited. Local detail (mean absolute difference between
horizontally adjacent pixels) separates a textured world from a flat one --
but NOT reliably on a single Quake frame.

Calibrated on all 180 captured frames, e1m1, two GPUs (90 per host), against
30 of the same frames put through a 128px downsample and back up, which strips
texture detail while keeping every shape and colour -- i.e. what an untextured
world looks like. Measured 2026-08-23:

                        per-frame detail        run median
    mini-g4  Radeon 9200   0.48 .. 3.98            1.56
    yosemite Rage 128      0.47 .. 4.08            1.38
    flattened              0.19 .. 0.60            0.35

Per frame the two OVERLAP: real bottoms out at 0.47 on the Rage 128 and
flattened tops out at 0.60. There is no gap at all, so no per-frame threshold
can separate them -- one would either pass stripped frames or refuse
legitimate ones. Quake has genuinely low-detail frames: dark corridors and big
areas of sky.

The run MEDIAN separates cleanly, because the failure this catches -- an
untextured world -- affects every frame, while a dark corridor affects one.
1.38 and 1.56 against 0.35 is a factor of 4 to 4.5. The threshold is 0.80:
1.7x below the lowest real median and 2.3x above the flattened one.

Verified in both directions on 2026-08-23. All 180 real frames pass (exit 0).
A 30-frame stripped run fails (exit 1) at median 0.35 -- and every one of
those 30 passes the per-frame checks, which is precisely why the run median
is the gate and not them.

The per-frame checks are therefore deliberately loose. They exist to catch
catastrophe (all black, one colour, a dead channel), not subtlety, and their
bounds are set far outside the observed range so they never refuse good work.
A gate that refuses good work does not fail loudly, it gets switched off.

DECODING WITHOUT A LIBRARY

Pillow is not installed here or on the fleet, and adding a dependency to run
one test is worse than the test. sips ships with every macOS from 10.4 to 26
and converts TGA or PNG to uncompressed BMP, which is 30 lines of stdlib.
"""
import struct, subprocess, sys, os, tempfile

# --- per-frame bounds: catastrophe only. Observed real range in brackets. ---
LUMA_MIN, LUMA_MAX = 3.0, 240.0     # [ 9.2 .. 76.3]  Quake is a very dark game
SD_MIN             = 2.0            # [5.80 .. 72.00] a single flat colour is 0
CHRATIO_MAX        = 40.0           # [1.54 .. 24.11] lava frames are hugely red
DETAIL_FLOOR       = 0.15           # [0.47 ..  4.08] a blank frame only

# --- the real check, across the whole run ---
MEDIAN_DETAIL_MIN  = 0.80           # real 1.38/1.56, flattened 0.35


def to_bmp(src, tmpdir):
    out = os.path.join(tmpdir, 'frame.bmp')
    p = subprocess.run(['sips', '-s', 'format', 'bmp', src, '--out', out],
                       capture_output=True, text=True)
    if p.returncode != 0 or not os.path.exists(out):
        raise RuntimeError(f"sips could not decode: {p.stderr.strip()[:120]}")
    return out


def load_bmp(path):
    """Return (w, h, rows) with rows[y][x] = (r, g, b), y from the top."""
    with open(path, 'rb') as f:
        data = f.read()
    if data[:2] != b'BM':
        raise RuntimeError(f"{path}: not a BMP")
    pixoff = struct.unpack_from('<I', data, 10)[0]
    w, h = struct.unpack_from('<ii', data, 18)
    bpp = struct.unpack_from('<H', data, 28)[0]
    comp = struct.unpack_from('<I', data, 30)[0]
    if bpp not in (24, 32) or comp not in (0, 3):
        raise RuntimeError(f"{path}: unsupported BMP ({bpp} bpp, compression {comp})")
    bp = bpp // 8
    stride = ((w * bp + 3) // 4) * 4
    flipped = h > 0                  # positive height means rows are bottom-up
    h = abs(h)
    rows = []
    for y in range(h):
        o = pixoff + y * stride
        # BMP stores each pixel BGR, so red is the third byte
        rows.append([(data[o+x*bp+2], data[o+x*bp+1], data[o+x*bp]) for x in range(w)])
    if flipped:
        rows.reverse()
    return w, h, rows


def measure(w, h, rows):
    lum = [[(p[0]*299 + p[1]*587 + p[2]*114) // 1000 for p in r] for r in rows]
    flat = [v for r in lum for v in r]
    mean = sum(flat) / len(flat)
    sd = (sum((v - mean) ** 2 for v in flat) / len(flat)) ** 0.5
    acc = n = 0
    for r in lum:
        for x in range(len(r) - 1):
            acc += abs(r[x] - r[x+1]); n += 1
    detail = acc / n if n else 0.0
    ch = [sum(p[i] for r in rows for p in r) / (w * h) for i in range(3)]
    lo, hi = min(ch), max(ch)
    ratio = hi / lo if lo > 0 else 999.0
    return mean, sd, detail, ratio


def check_frame(path):
    with tempfile.TemporaryDirectory() as tmp:
        w, h, rows = load_bmp(to_bmp(path, tmp))
    mean, sd, detail, ratio = measure(w, h, rows)
    fails = []
    if not LUMA_MIN <= mean <= LUMA_MAX:
        fails.append(f"mean luma {mean:.1f} outside {LUMA_MIN}..{LUMA_MAX}")
    if sd <= SD_MIN:
        fails.append(f"luma stddev {sd:.1f}: the frame is one flat colour")
    if ratio >= CHRATIO_MAX:
        fails.append(f"channel means {ratio:.1f}x apart: a colour channel looks dead")
    if detail < DETAIL_FLOOR:
        fails.append(f"local detail {detail:.2f}: the frame is blank")
    return (w, h, mean, sd, detail, ratio), fails


FRAME_EXT = ('.tga', '.png')


def expand(args):
    """Accept frame paths, or a directory to take every frame out of.

    A directory argument means the caller does not need a glob, a pipe or
    xargs to invoke this -- each of which fails silently in its own way. An
    unmatched glob under zsh aborts the command without running it, and a
    pipe hides the exit status of the thing being relied on.
    """
    out = []
    for a in args:
        if os.path.isdir(a):
            out += [os.path.join(a, f) for f in sorted(os.listdir(a))
                    if f.lower().endswith(FRAME_EXT) and f.startswith('spasm')]
        elif not a.endswith('manifest.txt'):
            out.append(a)
    return out


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    shots = expand(argv[1:])
    if not shots:
        print(f"!! no frames found in: {' '.join(argv[1:])}", file=sys.stderr)
        print("   (expected spasm*.tga or spasm*.png)", file=sys.stderr)
        return 1
    details, bad, errors = [], 0, 0
    print(f"{'frame':<20} {'size':>10} {'mean':>7} {'sd':>6} {'detail':>7} {'chr':>7}")
    for path in shots:
        name = os.path.basename(path)
        try:
            (w, h, mean, sd, detail, ratio), fails = check_frame(path)
        except Exception as e:
            print(f"{name:<20} ERROR: {e}")
            errors += 1
            continue
        details.append(detail)
        print(f"{name:<20} {w}x{h:<6} {mean:7.1f} {sd:6.1f} {detail:7.2f} {ratio:7.2f}"
              + ("   FAIL" if fails else ""))
        for f in fails:
            print(f"    !! {f}")
        if fails:
            bad += 1

    print()
    if errors:
        print(f"!! {errors} frame(s) could not be decoded -- that is a failure, not a skip")
    if not details:
        print("!! no frames measured")
        return 1

    s = sorted(details)
    median = s[len(s)//2] if len(s) % 2 else (s[len(s)//2 - 1] + s[len(s)//2]) / 2
    print(f"run median local detail {median:6.2f}   want >= {MEDIAN_DETAIL_MIN}")
    run_bad = median < MEDIAN_DETAIL_MIN
    if run_bad:
        print(f"    !! the world looks untextured or blurred across the whole run")
        print("       (real runs measure 1.38 on a Rage 128 and 1.56 on a Radeon 9200;")
        print("        a texture-stripped run measures 0.35)")

    print(f"{len(details) - bad} of {len(details)} frame(s) pass the per-frame checks")
    return 1 if (bad or run_bad or errors) else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
