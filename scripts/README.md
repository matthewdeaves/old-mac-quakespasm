# scripts/ — build, deploy, bench tooling for QuakeSpasm

Multi-host workflow: edit on Ubuntu → build on `mini-intel` (Lion) →
run on the 6 bench machines. SSH config aliases (`yosemite`,
`sawtooth`, `quicksilver`, `mini-g4`, `mini-intel`, `imac-2019`)
expected in `~/.ssh/config`.

Project goal, toggleability requirement, and the full perf-knob
inventory live in `/CLAUDE.md` and `docs/KNOBS.md`. Per-machine
shipping defaults: `scripts/bundle/autoexec-<machine>.cfg`.
For LLM-facing per-script notes see `scripts/CLAUDE.md`.

**Bench machines (6 machines, 3 distinct binaries):**

| machine     | hardware                                                              | binary                |
|-------------|-----------------------------------------------------------------------|-----------------------|
| yosemite    | PowerMac1,1  G3 B&W 449 MHz, Rage 128 16 MB, Panther 10.3.9           | `quakespasm-g3`       |
| sawtooth    | PowerMac3,1  G4 AGP 500 MHz, GeForce2 MX 32 MB, Tiger 10.4.11         | `quakespasm-g4`       |
| quicksilver | PowerMac3,5  G4 QS  733 MHz, Radeon 9000 Pro 64 MB, Tiger 10.4.11    | `quakespasm-g4`       |
| mini-g4     | PowerMac10,1 Mac mini G4 1.25 GHz, Radeon 9200 32 MB, Tiger 10.4.11   | `quakespasm-g4`       |
| mini-intel  | Macmini2,1   C2D 2.33 GHz, GMA 950 64 MB shared, Lion 10.7.5          | `quakespasm-lion`     |
| imac-2019   | iMac19,1     i5-9600K 3.70 GHz (6c), Radeon Pro 580X 8 GB, Sequoia 15.7.5 | `quakespasm-lion` |

`mini-intel` is both the cross-build host AND a runnable bench reference.
The matrix spans the GPU axis from fixed-function (Rage 128, GeForce2 MX)
through programmable-pre-shader-2.0 (Radeon 9000/9200) and early Intel
integrated (GMA 950) to modern discrete (Radeon Pro 580X) — useful for
separating GPU-bound from CPU-bound effects.

The three G4 machines share `build/quakespasm-g4` (`-mcpu=7400 -maltivec`
is correct for all three; the 7450 + 7447A run 7400 baseline happily).
The two Intel machines share `build/quakespasm-lion`.

## Quick start

```bash
# Build binaries (PPC cross-compile on mini-intel + native x86_64 on mini-intel)
scripts/build.sh g3
scripts/build.sh g4
scripts/build.sh lion

# Deploy (assemble Quakespasm.app + ship to ~/Desktop/quake/ on the host).
# G4 trio reuses build/quakespasm-g4; Intel pair reuses build/quakespasm-lion.
scripts/deploy.sh yosemite
scripts/deploy.sh sawtooth
scripts/deploy.sh quicksilver
scripts/deploy.sh mini-g4
scripts/deploy.sh mini-intel
scripts/deploy.sh imac-2019

# Run a single bench
scripts/bench.sh quicksilver demo1 1024x768
scripts/bench.sh imac-2019   demo1 1024x768

# Run the full baseline matrix (3 demos × 2 res × 3 runs each)
scripts/full-bench.sh ppc        # 4 PPC machines
scripts/full-bench.sh intel      # 2 Intel machines
scripts/full-bench.sh all        # all 6 machines
scripts/full-bench.sh sawtooth   # one machine

# Same matrix in parallel (≈ wall time of the slowest leg = yosemite).
# Default runs all 6 machines; --no-<machine> skips a leg if it's offline.
scripts/parallel-bench.sh
scripts/parallel-bench.sh --no-mini-intel --no-imac-2019

# Quick iteration loop: demo1 only at both res, all 6 machines parallel (~3-4 min)
scripts/parallel-bench.sh --quick

# Bench HEAD and commit the resulting CSV rows + raw logs in one shot.
# Canonical post-phase action — enforces the bench-and-commit cadence.
scripts/bench-and-commit.sh "Phase 2.1 BGRA lightmaps"

# Custom subsets via env vars
DEMOS=demo1 RESES=640x480 RUNS=2 scripts/full-bench.sh quicksilver
```

`benchmarks/results.csv` is a **rolling history** — every grid run appends.
This is how we see the optimization trajectory across phases. Use
`parallel-bench.sh --reset` only when starting a fresh optimization round
(it wipes after backing up to `results.csv.bak.<ts>`).

Raw `qconsole.log`s live in `benchmarks/raw/<commit>_<machine>_<demo>_<res>_runN.log`.

**Historical CSV note:** rows tagged with the OLD machine names (`g3`, `g4`,
`g4mini`, `lion`) refer to the same hardware as `yosemite`, `quicksilver`,
`mini-g4`, `mini-intel` respectively. The rename happened 2026-05-09; rows
before that commit use the old names, rows after use the new names.

## Scripts

| script | purpose |
|---|---|
| `build.sh <g3\|g4\|lion>` | rsync sources to mini-intel, compile (PPC cross via gcc-4.0 for g3/g4, native x86_64 via clang for lion), install_name fixup, fetch binary to `build/quakespasm-<chip>`. The `g3/g4/lion` arg names a CHIP FAMILY, not a machine — one g4 binary serves three machines. |
| `deploy.sh <machine>` | assemble `Quakespasm.app` bundle (binary + codecs + SDL + nib + icon + Info.plist) and rsync to `<machine>:~/Desktop/quake/`. The case statement maps machine→binary internally. |
| `bench.sh <machine> <demo> <WxH> [runs]` | run timedemo on already-deployed bundle; append row to `benchmarks/results.csv`. Honors `$COMMIT` env (callers pin HEAD); exits non-zero on any NA run. mini-intel uses 60 s timeout (Core 2 Duo finishes timedemo fast); G4s 120 s (sawtooth 180 s — slower CPU); yosemite 240 s. |
| `full-bench.sh [<machine>\|ppc\|intel\|all] [--quick]` | sweep demo1/demo2/demo3 × 1024x768/640x480 × 3 runs (sequential when more than one machine); `--quick` = demo1 only. `ppc` = the 4 PPC machines, `intel` = the 2 Intel machines, `all` = all 6 (default). |
| `parallel-bench.sh [--reset] [--quick] [--no-<machine> ...]` | same sweep on all 6 machines concurrently. Default appends to `results.csv` (rolling history). `--reset` wipes both CSV + raw/ after backup; `--keep-csv` is a deprecated no-op kept for muscle memory. `--no-<machine>` flags skip individual machines if one is offline. Pins `$COMMIT` from HEAD at start so side commits during the bench can't drift the row tags. Wall time is dominated by the slowest leg (yosemite). |
| `bench-and-commit.sh "<phase>"` | bench HEAD + commit the data in one shot. Refuses dirty trees, pins HEAD, then `parallel-bench.sh "$@"`, stages CSV + new raw logs, lands `bench: <phase> (HEAD <hash>)` commit with median fps summary. The canonical second-of-two commits per phase. |
| `parse_qconsole.py <log>` | extract fps + GL info from a `qconsole.log` (`--json` for machine-readable) |
| `make-icon.py [source.png]` | regenerate `MacOSX/QuakeSpasm.icns` from a source PNG (default: `MacOSX/newiconfinal.png`). **Legacy-only ICNS chunks** (Panther/Tiger compat — see file header for why iconutil is wrong). Default also refreshes `docs/images/quakespasm-icon{,-256}.png` (README hero strip); `--no-readme-refresh` to skip. `--keep-bg` to skip auto bg-removal if the source already has alpha (canonical Photoshop-touch-up workflow). Requires `~/quakespasm/.venv` (Pillow + numpy + scipy). |
| `install-host-tools.sh [hosts...]` | push `scripts/host-bin/*` to `~/bin/` on every bench Mac. Idempotent. Default hosts: `yosemite sawtooth quicksilver mini-g4 mini-intel imac-2019`. Re-run after editing the source scripts in `scripts/host-bin/` or adding a new bench machine. |
| `host-bin/qsreboot.sh` | runs **on the Mac**. SSH-side reboot. Tier 1: `sudo -n /sbin/reboot` (definite kernel reboot, works through wedged Finder / corrupt Rage 128 LUT). Tier 2: Finder Apple Event. Use as `ssh <machine> '~/bin/qsreboot.sh'`. |
| `host-bin/qsreboot-setup.sh` | runs **on the Mac**. ONE-TIME `sudo ~/bin/qsreboot-setup.sh` per machine to install the NOPASSWD sudoers entry that enables Tier 1 above. Backs up `/etc/sudoers`, validates with `visudo -c`, restores backup on failure. Idempotent re-runs. |

## Parallel-safety notes

`parallel-bench.sh` runs up to six `bench.sh` instances concurrently.
Two races to know about:

- **CSV header init.** `bench.sh` creates the CSV with a header on first
  use. Parallel procs racing on a missing CSV could each write a header.
  Worked around with bash `noclobber` (`set -C`, atomic `O_CREAT|O_EXCL`).
- **CSV row appends.** `>>` is atomic on Linux/macOS for writes ≤ PIPE_BUF
  (4 KB). Our rows are ~80 bytes, well under, so rows from the six legs
  never interleave inside a line.

Raw log filenames include the machine name
(`<commit>_<machine>_<demo>_<res>_runN.log`) so they never collide.
SSH connections to the six hosts are independent.

## Bundle layout (what `deploy.sh` builds)

Brief:

```
Quakespasm.app/
  Contents/
    Info.plist             scripts/bundle/Info.plist
    MacOS/
      quakespasm           build/quakespasm-<chip>  (g3/g4/lion or fat)
      lib*.dylib           MacOSX/codecs/lib/*.dylib (fat ppc+i386+x86_64)
      SDL.framework/       MacOSX/SDL.framework (fat; ppc slice is Panther-built)
    Resources/
      QuakeSpasm.icns
      English.lproj/       Launcher.nib + InfoPlist.strings
```

Bundle is byte-for-byte identical across machines when using the
fat binary (`scripts/deploy.sh fat <machine>`). Full Info.plist
key list, install_name_tool fixup, and the fat-SDL build recipe
live in `MacOSX/CLAUDE.md`.

## Why all the SSH knob-twiddling

mini-intel's OpenSSH 5.6 and yosemite's older one don't speak modern
algorithms. The SSH config entries pin the legacy crypto (`ssh-rsa`
host keys + pubkeys, pre-2014 KEX, RSA `id_rsa_tiger` — not ed25519).
`bench.sh` / `deploy.sh` inherit that; no inline `-o` flags needed.

For yosemite specifically, rsync runs in `--protocol=29` mode because
Panther ships rsync 2.5.x.
