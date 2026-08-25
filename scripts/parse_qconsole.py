#!/usr/bin/env python3
"""Extract structured info from a QuakeSpasm qconsole.log.

usage:  parse_qconsole.py <path-to-qconsole.log> [--json]

Without --json, prints a 1-line summary: "<demo>: <fps> fps (<frames> frames, <seconds>s)"
With --json, prints a full dict with detected GL info, warnings, fps, etc.
"""

from __future__ import annotations
import argparse
import json
import re
import sys


FPS_RE = re.compile(r"^\s*(\d+)\s+frames\s+([\d.]+)\s+seconds\s+([\d.]+)\s+fps\s*$")
VIDEO_MODE_RE = re.compile(r"^Video mode\s+(\d+x\d+)")
GL_RE = re.compile(r"^GL_(VENDOR|RENDERER|VERSION|MAX_TEXTURE_UNITS):\s*(.+)$")
DEMO_RE = re.compile(r"^Playing demo from (\S+)\.dem")
HEAP_RE = re.compile(r"([\d.]+)\s+megabyte heap")


def parse(path: str) -> dict:
    out: dict = {
        "frames": None, "seconds": None, "fps": None,
        "demo": None,
        "video_mode": None,
        "gl_vendor": None, "gl_renderer": None, "gl_version": None,
        "gl_max_texture_units": None,
        "heap_mb": None,
        "warnings": [],
    }
    with open(path, "r", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            m = FPS_RE.match(line)
            if m:
                out["frames"] = int(m.group(1))
                out["seconds"] = float(m.group(2))
                out["fps"] = float(m.group(3))
                continue
            m = VIDEO_MODE_RE.search(line)
            if m:
                out["video_mode"] = m.group(1)
                continue
            m = GL_RE.match(line)
            if m:
                key = "gl_" + m.group(1).lower()
                out[key] = m.group(2).strip()
                if key == "gl_max_texture_units":
                    try:
                        out[key] = int(out[key])
                    except ValueError:
                        pass
                continue
            m = DEMO_RE.match(line)
            if m:
                out["demo"] = m.group(1)
                continue
            m = HEAP_RE.search(line)
            if m:
                out["heap_mb"] = float(m.group(1))
                continue
            if line.startswith("Warning:"):
                out["warnings"].append(line[len("Warning:"):].strip())
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("logpath")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    data = parse(args.logpath)
    if args.json:
        json.dump(data, sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        if data["fps"] is None:
            print(f"{args.logpath}: no fps line found")
            return 1
        print(f"{data['demo'] or 'demo?'}: {data['fps']:.1f} fps "
              f"({data['frames']} frames, {data['seconds']:.1f}s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
