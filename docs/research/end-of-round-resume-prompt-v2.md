# End-of-round v3 resume prompt — v2 (post-compact, 2026-05-08)

This is the **fresh-context** entry point for the remaining v3 tasks
after the BGRA failure + g4mini integration session was compacted.
Paste the link or the contents into a new Claude Code session.

## Round status

Branch: `master`. Working tree should be clean.

Tasks completed in the previous session:

- ✅ Pass B kill-bucket cleanup (~250 LOC dead-code removal)
- ✅ Pass B latent-bug sweep (5 fixes: realloc-leak, malloc-NULL, etc.)
- ✅ Pass B revive B1: HUD item-pickup blink restored (`sbar.c`)
- ✅ Pass B revive B2: `dumppacket` console command bound
- ✅ Pass B revive B3: cvar autoexec defaults consolidated
- ❌ Pass A item 5: BGRA static-texture upload — **REVERTED**, see
  `MISTAKES.md` first entry. Do NOT re-attempt without changing the
  implementation strategy (allocate fresh BGRA buffer, no in-place
  swap).
- ✅ Pass B revive B6: `-r128-cva` opt-in retest hatch (commits
  `612a8ad9` + `f011a80c`). User can flip the R128 CVA Lock skip at
  launch for visual A/B without rebuild.
- ✅ Pass B revive B4: `-noglslalias` Lion A/B — verified no-op on
  GMA 950 (GL 1.4 / no GLSL); engine already routes through Fitz
  alias path. Comment landed in `scripts/bundle/autoexec-lion.cfg`
  (commit `36874f59`).

Bench numbers as of `612a8ad9` (last bench-and-commit):

| target | demo1 1024×768 | demo1 640×480 |
|--------|----------------|---------------|
| G3     | 23.05 fps      | 46.10 fps     |
| G4     | 106.10 fps     | 127.50 fps    |
| Lion   | 95.60 fps      | 218.35 fps    |

(g4mini is in scripts but not in the recent smoke; will be in the
round-wrap full-grid.)

## Discipline reminders before you edit anything

The BGRA failure in the previous session crashed all 4 bench targets
and burned ~90 minutes of recovery. Two things would have caught it
earlier:

1. **Read MISTAKES.md before lighting up an idea that smells "easy"
   or "load-time only / zero risk".** That prediction is exactly how
   BGRA was tagged. The crash signature, the root cause, and the
   five lessons are all there.

2. **Smoke-bench every target before committing — even for changes
   tagged "load-time only".** A smoke that runs only `demo1` won't
   catch a bug that surfaces during map load, because demo1 doesn't
   transition. Where possible, run a multi-demo smoke OR walk a
   first map manually before claiming a phase is clean.

3. **Pre-task code review.** For each remaining task, *read the
   target code top-to-bottom first*, identify all callsites of any
   changed function, sketch the change in plain English in the
   commit message, *then* implement. The user explicitly asked for
   this discipline going forward.

4. **In-place buffer mutation on shared hunk allocations is a
   footgun.** If a phase needs a different data layout, allocate
   fresh and copy in. Don't mutate a buffer the caller may still
   reach.

5. **Endian-only gating is suspicious as a fix.** If your "fix" is
   "only run on little-endian" or "only run on big-endian", and the
   bug appeared on multiple endiannesses before that gating, the
   gate is masking a deeper problem.

## Remaining tasks

The tasks below are roughly in order. **Tackle them sequentially**
unless you have a specific reason to reorder.

### Task #9 — Phase 4.4 + §14.3 item 4 AltiVec retuning

Currently both AltiVec phases ship as **opt-in cmdline flags** because
they regressed (-0.5..-2.3% Phase 4.4) or went neutral (§14.3 item 4)
at smoke. They're preserved in tree as `-altivec-lm` and
`-altivec-dlights` so a future round can tune them.

**Files**:

- `Quake/r_brush.c:1169-1252` — Phase 4.4 lightmap compose AltiVec
  block (gated on `lm_altivec_disabled`). Current threshold is
  `size >= 6`; the actual loop processes 16-byte chunks of `bl[k]
  += lightmap[k] * scale`.
- `Quake/r_brush.c:983-1122` — `R_AddDynamicLights`. §14.3 item 4
  AltiVec block at lines 1038-1093, gated on `dlights_altivec_disabled`.
- `Quake/gl_rmisc.c:259-280` — flag parsing for both opt-ins.

**Three retuning paths to consider** (per resume-prompt-v1):

(a) **Raise the size threshold.** Phase 4.4 currently kicks in at
    `size >= 6` (i.e. 18 u32 accumulator words). The vector setup
    cost (lvsl + scale broadcast + zero) may not amortise until
    `size >= 16` or higher. A perfprint-instrumented A/B with
    threshold sweeps would settle this.

(b) **Memcpy to aligned scratch.** The `lightmap` source is unaligned
    in general — current code uses `lvsl + double-load + vec_perm`.
    Per-iteration cost is ~3 vec-ops. For larger `size` values, a
    one-shot `memcpy(scratch, lightmap, N)` to a 16-byte-aligned
    static buffer eliminates the permute entirely and lets us use
    plain `vec_ld`. Trade: one extra pass over the data.

(c) **Bundle compose + dlight.** Both loops walk `bl[]` over the
    same surface. Current shape: compose runs over all maps then
    `R_AddDynamicLights` is called separately. A combined pass that
    accumulates lightstyle * sample AND dlight contribution in one
    pass over `bl[]` halves the working-set traffic.

**Recommended first step**: don't pick blind. Pick (a) — it's the
smallest, safest change. Sweep thresholds 6 / 16 / 32 / 64 on G4 and
g4mini, demo3 1024 (the dlight-heavy demo), and pick the threshold
that wins or doesn't regress at any cell. If (a) shows no winning
threshold, reconsider whether to revisit at all — Phase 4.4 may
just not be a vectorisation win on these workloads.

**Smoke targets**: G4 + g4mini (AltiVec), G3 (regression check on
the scalar fallback compile path), Lion (Intel — verify the
`#ifdef __ALTIVEC__` doesn't accidentally fire). Demo3 1024 is the
diagnostic cell.

**If retuning still nets neutral or negative**: keep both paths
opt-in, add a paragraph to MISTAKES.md describing what was tried
and why it didn't pay off. Don't ship a regression to the default.

### Task #10 — Distance-gated `R_DrawShadows` (Pass C HIGH)

Source: `docs/research/perfprint-pass-c-analysis.md` flagged this as
the biggest leverable item for G4 demo3. Current state: G4 ships
with `r_shadows 1` (alias drop-shadow) and pays ~11% fps for it. The
shadow draw runs on every visible alias regardless of distance — but
beyond ~500 units a shadow is a single-pixel smear nobody can see.

**Goal**: add an `r_shadow_distance` cvar (default ~512 units) that
short-circuits `R_DrawShadows` for any alias farther than that. On
G4 demo3 the expected save is in the 4-7% fps range without any
visible quality loss.

**Files**:

- `Quake/r_alias.c` — find `R_DrawShadows` / `GL_DrawAliasShadow`
  (exact name varies). Compute distance from `r_origin` to
  `currententity->origin`, skip if `> r_shadow_distance.value`.
- New cvar registration in the same file or `r_main.c`.

**Discipline check before editing**:

- Read the entire shadow-draw function first; understand how it's
  called per-frame.
- Check whether `R_DrawAliasModel` already does early-out distance
  culling (don't duplicate it).
- Default the cvar to `0` (disabled / no clip) initially so existing
  G4 autoexec shadow=1 setting doesn't suddenly drop shadows on
  far entities. THEN enable it via autoexec-g4.cfg with a sane
  default like 512.

**Smoke targets**: G4 demo3 1024 (the cell where Pass C predicted
the win). Visual eyes-on at G4 to confirm no obvious "shadow popping"
on entity transitions across the threshold.

### Task #11 — §14.4 round-wrap full-grid bench

After #9 and #10 land:

```
scripts/bench-and-commit.sh "v3 round wrap"
```

(no `--quick`). Sweeps demo1/2/3 × 1024×768/640×480 × 3 runs across
all 4 targets = 72 cells. Wall time ~25 min driven by the G3 leg.

This is the canonical round-end bench — captures the cumulative
trajectory from v2 baseline (commit ~`6c7c7d76`-ish era) through v3.

After the commit lands, append a v3-summary table to PPC_PLAN.md
showing v2 → v3 deltas at each cell.

### Task #12 — §14.5 fat-binary tooling

Source: `docs/research/fat-binary-feasibility.md`. Goal: produce a
single `quakespasm` Mach-O that runs on G3, G4, and Intel — replaces
the current "ship 3 binaries to 3 different `Quakespasm.app`s"
workflow.

**Pre-work**:

- Read `docs/research/fat-binary-feasibility.md` end-to-end.
- Check what `lipo` is available on Lion (the build host).
- Determine whether SDL.framework needs to be lipo'd too (yes — it
  currently has separate fat slices but the PPC slice is 10.6-built
  and crashes on Panther, hence the `SDL-panther.dylib` swap in
  `deploy.sh g3`). Fat-binary packaging needs a strategy for that.

**Deliverable**: `scripts/build-fat.sh` that produces
`build/quakespasm-fat` containing `ppc_750 + ppc_7400 + x86_64`
slices, plus `scripts/deploy-fat.sh` that ships a single `.app`
to whichever target.

**Risk**: this is tooling work, not engine work. Smoke is "does the
fat binary launch cleanly on each of the 4 targets" — no perf
delta expected.

## Hosts (durable, in CLAUDE.md)

- `lion` — Intel Mac mini Macmini2,1, 2.33 GHz Core 2 Duo, GMA 950,
  10.7.5 Lion. Build host AND bench target. Sleeps aggressively;
  if `build.sh` fails with "No route to host", wake it.
- `PowerMacG3` — Blue & White, 450 MHz, 10.3.9 Panther, Rage 128.
- `g4` — Quicksilver, 867 MHz, 10.4.11 Tiger, Radeon 9000, AltiVec.
- `g4mini` — Mac mini G4, 1.42 GHz 7447A, 10.4.11 Tiger, Radeon
  9200/32 MB, AltiVec.

SSH legacy crypto is already configured in `~/.ssh/config`.

## Bench cadence (durable, in CLAUDE.md)

Per phase: edit + build + deploy → smoke (`parallel-bench.sh
--quick`, dirty-tree, throwaway) → if clean, commit code → then
`scripts/bench-and-commit.sh "<phase>" --quick` for the official
rows. Two commits per phase (code + bench).

Round-wrap (after all phases land): `scripts/bench-and-commit.sh
"v3 round wrap"` *without* `--quick` — 72-cell grid.

**Negative results still get committed** as `bench: <phase>
[REGRESSED]`. They're signal for redirecting upcoming phases.

## Don't re-trip these wires

- **Don't run `bench.sh g3 ... &` and `bench.sh g4 ... &` in parallel
  from one shell.** Workstation network stress corrupts G3 timing.
  Use `parallel-bench.sh` (separate process management) or run
  serially.
- **Don't run `build.sh g3` and `g4` in parallel** — they race on
  `make -j2` in `lion:quakespasm/Quake/` and stamp the wrong CPU
  subtype. The script has a flock; don't bypass it.
- **Don't use Bash `pkill`** on Tiger/Panther — not installed. Use
  `killall -KILL quakespasm`.
- **Don't use `sleep 0.2` on Panther** — integer-only sleep,
  fractional values exit immediately. Use `sleep 1` minimum.
- **Tiger/Panther Cocoa requires a real `.app` bundle** with
  Info.plist + NSPrincipalClass + NSMainNibFile. `deploy.sh` already
  does this; don't ship bare binaries.
- **G3 needs `MacOSX/SDL-panther.dylib`** swapped over the
  bundled SDL.framework's `Versions/A/SDL` slot — the bundled SDL
  was built against the 10.6 SDK and crashes on Panther.
  `deploy.sh g3` already handles this.

## Tooling to invoke (don't reinvent inline)

```
scripts/build.sh <g3|g4|lion>            cross-build (g3/g4) or native (lion)
scripts/deploy.sh <g3|g4|g4mini|lion>    assemble app + ship
scripts/bench.sh <target> <demo> <res>   single cell, append CSV row
scripts/full-bench.sh [target] [--quick] matrix sweep
scripts/parallel-bench.sh [--quick]      4 legs concurrently
scripts/bench-and-commit.sh "<msg>" [--quick]  pinned bench + commit
```

Plus the `/bench`, `/deploy` slash commands and `ppc-ops` skill at
`.claude/skills/ppc-ops/SKILL.md`.

## Where to start

```
git status                      # confirm clean tree
git log --oneline -5            # confirm 36874f59 is HEAD
cat MISTAKES.md                 # read in full before any edits
cat PPC_PLAN.md | head -100     # round status
```

Then begin **Task #9** with the deep-review-before-edit discipline:
read `r_brush.c:983-1252` end-to-end, sketch the chosen retuning
path (start with (a) — threshold sweep), then implement.
