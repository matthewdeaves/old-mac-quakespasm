# scripts/ — build, deploy, bench tooling for QuakeSpasm

Multi-host workflow: edit on Ubuntu → build on Lion → run on G3/G4/Lion.
SSH config aliases (`lion`, `g4`, `PowerMacG3`) are expected in `~/.ssh/config`.

**Targets:**
- `g3` — PowerMac B&W, 450 MHz PowerPC 750, Rage 128, 10.3.9 (PPC cross-build)
- `g4` — Quicksilver, 867 MHz PowerPC 7450 + AltiVec, Radeon 9000, 10.4.11 (PPC cross-build)
- `lion` — Mac mini Macmini2,1, 2.33 GHz Core 2 Duo, GMA 950, 10.7.5 (Intel native build, x86_64)

Lion is both the PPC cross-build host AND a runnable bench reference of its own.
The Intel target was added 2026-05-08 to give a third data point — useful because
the GMA 950 / Core 2 Duo profile has a markedly different fillrate-vs-CPU balance
from either PPC machine, which helps separate GPU-bound from CPU-bound effects.

## Quick start

```bash
# Build binaries (PPC cross-compile on Lion + native x86_64 on Lion)
scripts/build.sh g3
scripts/build.sh g4
scripts/build.sh lion

# Deploy (assemble Quakespasm.app + ship to ~/Desktop/quake/ on the host)
scripts/deploy.sh g3
scripts/deploy.sh g4
scripts/deploy.sh lion

# Run a single bench
scripts/bench.sh g4   demo1 1024x768
scripts/bench.sh lion demo1 1024x768

# Run the full baseline matrix (3 demos × 2 res × 3 runs each)
scripts/full-bench.sh both    # G3 + G4 (the historical default)
scripts/full-bench.sh all     # G3 + G4 + Lion (adds the Intel reference)
scripts/full-bench.sh lion    # Lion only

# Same matrix in parallel (≈ wall time of the slowest leg = G3)
# Default includes all three machines; --no-lion to skip if Lion is unavailable.
scripts/parallel-bench.sh
scripts/parallel-bench.sh --no-lion

# Quick iteration loop: demo1 only at both res, all machines in parallel (~3-4 min)
scripts/parallel-bench.sh --quick

# Bench HEAD and commit the resulting CSV rows + raw logs in one shot.
# Canonical post-phase action — enforces the bench-and-commit cadence.
scripts/bench-and-commit.sh "Phase 2.1 BGRA lightmaps"

# Custom subsets via env vars
DEMOS=demo1 RESES=640x480 RUNS=2 scripts/full-bench.sh g4
```

`benchmarks/results.csv` is a **rolling history** — every grid run appends.
This is how we see the optimization trajectory across phases. Use
`parallel-bench.sh --reset` only when starting a fresh optimization round
(it wipes after backing up to `results.csv.bak.<ts>`).

Raw `qconsole.log`s live in `benchmarks/raw/<commit>_<target>_<demo>_<res>_runN.log`.

## Scripts

| script | purpose |
|---|---|
| `build.sh <g3\|g4\|lion>` | rsync sources to Lion, compile (PPC cross via gcc-4.0 for g3/g4, native x86_64 via clang for lion), install_name fixup, fetch binary to `build/quakespasm-<target>` |
| `deploy.sh <g3\|g4\|lion>` | assemble `Quakespasm.app` bundle (binary + codecs + SDL + nib + icon + Info.plist) and rsync to `<HOST>:~/Desktop/quake/` |
| `bench.sh <target> <demo> <WxH> [runs]` | run timedemo on already-deployed bundle; append row to `benchmarks/results.csv`. Honors `$COMMIT` env (callers pin HEAD); exits non-zero on any NA run. Lion uses 60 s timeout (Core 2 Duo finishes timedemo fast); G4 120 s; G3 240 s. |
| `full-bench.sh [g3\|g4\|lion\|both\|all] [--quick]` | sweep demo1/demo2/demo3 × 1024x768/640x480 × 3 runs (sequential when more than one target); `--quick` = demo1 only. `both` = g4+g3, `all` = g4+g3+lion. |
| `parallel-bench.sh [--reset] [--quick] [--no-lion]` | same sweep on G3 + G4 + Lion concurrently. Default appends to `results.csv` (rolling history). `--reset` wipes both CSV + raw/ after backup; `--keep-csv` is a deprecated no-op kept for muscle memory. `--no-lion` skips the Lion leg if Lion is offline. Pins `$COMMIT` from HEAD at start so side commits during the bench can't drift the row tags. Wall time is dominated by the slowest leg, which is G3. |
| `bench-and-commit.sh "<phase>"` | bench HEAD + commit the data in one shot. Refuses dirty trees, pins HEAD, then `parallel-bench.sh "$@"`, stages CSV + new raw logs, lands `bench: <phase> (HEAD <hash>)` commit with median fps summary. The canonical second-of-two commits per phase. |
| `parse_qconsole.py <log>` | extract fps + GL info from a `qconsole.log` (`--json` for machine-readable) |

## Parallel-safety notes

`parallel-bench.sh` runs up to three `bench.sh` instances concurrently
(g3, g4, lion). Two races to know about:

- **CSV header init.** `bench.sh` creates the CSV with a header on first use.
  Three parallel procs racing on a missing CSV could each write a header.
  Worked around with bash `noclobber` (`set -C`, atomic `O_CREAT|O_EXCL`).
- **CSV row appends.** `>>` is atomic on Linux/macOS for writes ≤ PIPE_BUF
  (4 KB). Our rows are ~80 bytes, well under, so rows from the three machines
  never interleave inside a line.

Raw log filenames include the machine name
(`<commit>_<g3|g4|lion>_<demo>_<res>_runN.log`) so they never collide. SSH
connections to the three hosts are independent.

## Bundle layout (what `deploy.sh` builds)

```
Quakespasm.app/
  Contents/
    Info.plist             scripts/bundle/Info.plist
    MacOS/
      quakespasm           build/quakespasm-<target>
      lib*.dylib           MacOSX/codecs/lib/*.dylib (10 codec libs, fat ppc+i386+x86_64)
      SDL.framework/       MacOSX/SDL.framework (fat ppc+i386+x86_64)
                           + (G3 only) SDL-panther.dylib swapped in
    Resources/
      QuakeSpasm.icns      MacOSX/QuakeSpasm.icns
      English.lproj/       MacOSX/English.lproj (Launcher.nib + InfoPlist.strings)
```

The bundle is identical for all three targets except for the binary itself
and the SDL slice the dynamic linker picks at runtime. The codec dylibs and
the bundled `SDL.framework` are pre-built fat — they include `ppc`, `i386`,
**and** `x86_64` slices, so the same bundle layout serves all three targets.

The G3 needs a 10.3-targeted SDL because `MacOSX/SDL.framework`'s ppc slice
was built against the 10.6 SDK and crashes inside `SDL_VideoInit` on Panther.
`MacOSX/SDL-panther.dylib` is a PPC-only build of SDL 1.2.15 (built on Lion
against the 10.3.9 SDK) that deploy.sh swaps into the framework's
`Versions/A/SDL` slot for G3 deployments only.

## Why all the SSH knob-twiddling

Lion's OpenSSH 5.6 and Panther's older one don't speak modern algorithms. The
SSH config entries pin the legacy crypto. The `bench.sh` and `deploy.sh` scripts
inherit that — no inline `-o` flags needed.

For G3 specifically, rsync runs in `--protocol=29` mode because Panther ships
rsync 2.5.x.
