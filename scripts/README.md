# scripts/ — PPC build, deploy, bench tooling

Three-host workflow: edit on Ubuntu → cross-compile on Lion → run on G3/G4.
SSH config aliases (`lion`, `g4`, `PowerMacG3`) are expected in `~/.ssh/config`.

## Quick start

```bash
# Build PPC binaries on Lion
scripts/build.sh g3
scripts/build.sh g4

# Deploy to PPC machines (assemble Quakespasm.app + ship)
scripts/deploy.sh g3
scripts/deploy.sh g4

# Run a single bench
scripts/bench.sh g4 demo1 1024x768

# Run the full v2 baseline matrix (3 demos × 2 res × 3 runs each, both machines)
scripts/full-bench.sh both

# Same matrix, but G3 and G4 in parallel (≈ half the wall time)
# Appends to the rolling benchmarks/results.csv (history across phases).
scripts/parallel-bench.sh

# Quick iteration loop: demo1 only at both res, both machines in parallel (~3-4 min)
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
| `build.sh <g3\|g4>` | rsync sources to Lion, compile, install_name fixup, fetch binary to `build/quakespasm-<target>` |
| `deploy.sh <g3\|g4>` | assemble `Quakespasm.app` bundle (binary + codecs + SDL + nib + icon + Info.plist) and rsync to `<HOST>:~/Desktop/quake/` |
| `bench.sh <target> <demo> <WxH> [runs]` | run timedemo on already-deployed bundle; append row to `benchmarks/results.csv`. Honors `$COMMIT` env (callers pin HEAD); exits non-zero on any NA run. |
| `full-bench.sh [g3\|g4\|both] [--quick]` | sweep demo1/demo2/demo3 × 1024x768/640x480 × 3 runs (sequential when `both`); `--quick` = demo1 only |
| `parallel-bench.sh [--reset] [--quick]` | same sweep on G3 + G4 concurrently. Default appends to `results.csv` (rolling history). `--reset` wipes both CSV + raw/ after backup; `--keep-csv` is a deprecated no-op kept for muscle memory. Pins `$COMMIT` from HEAD at start so side commits during the bench can't drift the row tags. |
| `bench-and-commit.sh "<phase>"` | bench HEAD + commit the data in one shot. Refuses dirty trees, pins HEAD, then `parallel-bench.sh "$@"`, stages CSV + new raw logs, lands `bench: <phase> (HEAD <hash>)` commit with median fps summary. The canonical second-of-two commits per phase. |
| `parse_qconsole.py <log>` | extract fps + GL info from a `qconsole.log` (`--json` for machine-readable) |

## Parallel-safety notes

`parallel-bench.sh` runs two `bench.sh` instances concurrently, one per machine.
Two races to know about:

- **CSV header init.** `bench.sh` creates the CSV with a header on first use.
  Two parallel procs racing on a missing CSV could both write a header.
  Worked around with bash `noclobber` (`set -C`, atomic `O_CREAT|O_EXCL`).
- **CSV row appends.** `>>` is atomic on Linux/macOS for writes ≤ PIPE_BUF
  (4 KB). Our rows are ~80 bytes, well under, so rows from the two machines
  never interleave inside a line.

Raw log filenames include the machine name (`<commit>_<g3|g4>_<demo>_<res>_runN.log`)
so they never collide. SSH connections to the two hosts are independent.

## Bundle layout (what `deploy.sh` builds)

```
Quakespasm.app/
  Contents/
    Info.plist             scripts/bundle/Info.plist
    MacOS/
      quakespasm           build/quakespasm-<target>
      lib*.dylib           MacOSX/codecs/lib/*.dylib (10 codec libs)
      SDL.framework/       MacOSX/SDL.framework + (G3 only) SDL-panther.dylib swapped in
    Resources/
      QuakeSpasm.icns      MacOSX/QuakeSpasm.icns
      English.lproj/       MacOSX/English.lproj (Launcher.nib + InfoPlist.strings)
```

The G3 needs a 10.3-targeted SDL because `MacOSX/SDL.framework` was built against
the 10.6 SDK and crashes inside `SDL_VideoInit` on Panther. `MacOSX/SDL-panther.dylib`
is a PPC-only build of SDL 1.2.15 (built on Lion against the 10.3.9 SDK) that
deploy.sh swaps into the framework's `Versions/A/SDL` slot for G3 deployments only.

## Why all the SSH knob-twiddling

Lion's OpenSSH 5.6 and Panther's older one don't speak modern algorithms. The
SSH config entries pin the legacy crypto. The `bench.sh` and `deploy.sh` scripts
inherit that — no inline `-o` flags needed.

For G3 specifically, rsync runs in `--protocol=29` mode because Panther ships
rsync 2.5.x.
