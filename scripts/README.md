# scripts/ — build, deploy, bench tooling for QuakeSpasm

Multi-host workflow: edit on Ubuntu → build on Lion → run on G3/G4/G4mini/Lion.
SSH config aliases (`lion`, `g4`, `g4mini`, `PowerMacG3`) are expected in `~/.ssh/config`.

> **Project goal** is best-looking Quake on G3/G4/Intel while keeping
> framerate comfortably playable (≥ 60 fps on G4 + Lion, ≥ 20 fps on G3).
> Visual upgrades that cost 10-15% fps are in scope when they leave the
> cell above its playability threshold. **Every shipped per-target
> visual / perf knob must be runtime-toggleable** (cvar or `-flag`) so
> end-of-round code review can A/B individual contributions without
> rebuild. Full toggle inventory lives in `CLAUDE.md` under
> "Toggleable knobs". Per-target shipping defaults live in
> `scripts/bundle/autoexec-{g3,g4}.cfg`.

**Targets (4 bench machines, 3 distinct binaries):**
- `g3` — PowerMac B&W, 450 MHz PowerPC 750, Rage 128, 10.3.9 (PPC cross-build → `quakespasm-g3`)
- `g4` — Quicksilver, 867 MHz PowerPC 7450 + AltiVec, Radeon 9000, 10.4.11 (PPC cross-build → `quakespasm-g4`)
- `g4mini` — Mac mini G4, 1.42 GHz 7447A + AltiVec, ATI Radeon 9200 32 MB, 10.4.11 (reuses `quakespasm-g4`; second G4-class data point added 2026-05-08)
- `lion` — Mac mini Macmini2,1, 2.33 GHz Core 2 Duo, GMA 950, 10.7.5 (Intel native build, x86_64 → `quakespasm-lion`)

Lion is both the PPC cross-build host AND a runnable bench reference of its own.
The Intel target was added 2026-05-08 to give a third architectural data point —
useful because the GMA 950 / Core 2 Duo profile has a markedly different
fillrate-vs-CPU balance from either PPC machine, which helps separate GPU-bound
from CPU-bound effects. The Mac mini G4 was added the same day as a second
G4-class machine (different GPU than the Quicksilver — Radeon 9200 32 MB vs
Radeon 9000 64 MB) so we can disambiguate fillrate-bound vs CPU-bound results
within the G4 family.

## Quick start

```bash
# Build binaries (PPC cross-compile on Lion + native x86_64 on Lion)
scripts/build.sh g3
scripts/build.sh g4
scripts/build.sh lion

# Deploy (assemble Quakespasm.app + ship to ~/Desktop/quake/ on the host).
# g4mini reuses build/quakespasm-g4 — no separate build step required.
scripts/deploy.sh g3
scripts/deploy.sh g4
scripts/deploy.sh g4mini
scripts/deploy.sh lion

# Run a single bench
scripts/bench.sh g4     demo1 1024x768
scripts/bench.sh g4mini demo1 1024x768
scripts/bench.sh lion   demo1 1024x768

# Run the full baseline matrix (3 demos × 2 res × 3 runs each)
scripts/full-bench.sh both    # G3 + G4 Quicksilver only (historical default)
scripts/full-bench.sh all     # G3 + G4 + G4mini + Lion (full 4-machine sweep)
scripts/full-bench.sh g4mini  # Mac mini G4 only

# Same matrix in parallel (≈ wall time of the slowest leg = G3).
# Default runs all 4 machines; --no-{lion,g4mini,g4,g3} skips a leg if it's offline.
scripts/parallel-bench.sh
scripts/parallel-bench.sh --no-lion
scripts/parallel-bench.sh --no-g4mini

# Quick iteration loop: demo1 only at both res, all 4 machines in parallel (~3-4 min)
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
| `build.sh <g3\|g4\|lion>` | rsync sources to Lion, compile (PPC cross via gcc-4.0 for g3/g4, native x86_64 via clang for lion), install_name fixup, fetch binary to `build/quakespasm-<target>`. No `g4mini` here — same arch as `g4`, deploy.sh reuses `build/quakespasm-g4`. |
| `deploy.sh <g3\|g4\|g4mini\|lion>` | assemble `Quakespasm.app` bundle (binary + codecs + SDL + nib + icon + Info.plist) and rsync to `<HOST>:~/Desktop/quake/`. `g4mini` deploys the g4 binary to the Mac mini G4 host. |
| `bench.sh <target> <demo> <WxH> [runs]` | run timedemo on already-deployed bundle; append row to `benchmarks/results.csv`. Honors `$COMMIT` env (callers pin HEAD); exits non-zero on any NA run. Lion uses 60 s timeout (Core 2 Duo finishes timedemo fast); G4 + G4mini 120 s; G3 240 s. Targets: `g3 \| g4 \| g4mini \| lion`. |
| `full-bench.sh [g3\|g4\|g4mini\|lion\|both\|all] [--quick]` | sweep demo1/demo2/demo3 × 1024x768/640x480 × 3 runs (sequential when more than one target); `--quick` = demo1 only. `both` = g4+g3 (PPC pair, historical default), `all` = lion+g4+g4mini+g3 (full 4-machine sweep). |
| `parallel-bench.sh [--reset] [--quick] [--no-lion] [--no-g4mini] [--no-g4] [--no-g3]` | same sweep on G3 + G4 + G4mini + Lion concurrently. Default appends to `results.csv` (rolling history). `--reset` wipes both CSV + raw/ after backup; `--keep-csv` is a deprecated no-op kept for muscle memory. `--no-<leg>` flags skip individual machines if one is offline. Pins `$COMMIT` from HEAD at start so side commits during the bench can't drift the row tags. Wall time is dominated by the slowest leg, which is G3. |
| `bench-and-commit.sh "<phase>"` | bench HEAD + commit the data in one shot. Refuses dirty trees, pins HEAD, then `parallel-bench.sh "$@"`, stages CSV + new raw logs, lands `bench: <phase> (HEAD <hash>)` commit with median fps summary. The canonical second-of-two commits per phase. |
| `parse_qconsole.py <log>` | extract fps + GL info from a `qconsole.log` (`--json` for machine-readable) |
| `install-host-tools.sh [hosts...]` | push `scripts/host-bin/*` to `~/bin/` on every bench Mac. Idempotent. Default hosts: `PowerMacG3 g4 g4mini lion`. Re-run after editing the source scripts in `scripts/host-bin/` or adding a new bench machine. |
| `host-bin/qsreboot.sh` | runs **on the Mac**. SSH-side reboot. Tier 1: `sudo -n /sbin/reboot` (definite kernel reboot, works through wedged Finder / corrupt Rage 128 LUT). Tier 2: Finder Apple Event. Use as `ssh <host> '~/bin/qsreboot.sh'`. |
| `host-bin/qsreboot-setup.sh` | runs **on the Mac**. ONE-TIME `sudo ~/bin/qsreboot-setup.sh` per machine to install the NOPASSWD sudoers entry that enables Tier 1 above. Backs up `/etc/sudoers`, validates with `visudo -c`, restores backup on failure. Idempotent re-runs. |

## Parallel-safety notes

`parallel-bench.sh` runs up to four `bench.sh` instances concurrently
(g3, g4, g4mini, lion). Two races to know about:

- **CSV header init.** `bench.sh` creates the CSV with a header on first use.
  Four parallel procs racing on a missing CSV could each write a header.
  Worked around with bash `noclobber` (`set -C`, atomic `O_CREAT|O_EXCL`).
- **CSV row appends.** `>>` is atomic on Linux/macOS for writes ≤ PIPE_BUF
  (4 KB). Our rows are ~80 bytes, well under, so rows from the four machines
  never interleave inside a line.

Raw log filenames include the machine name
(`<commit>_<g3|g4|g4mini|lion>_<demo>_<res>_runN.log`) so they never collide.
SSH connections to the four hosts are independent.

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
