# Round v3 → v4 transition prompt — fat binary + screenshot pass

> Drop-in prompt for the post-context-clear session. Use after `/clear`.
> Author: prior session, 2026-05-08 evening (handoff).

## What just shipped (round v3)

All eleven planned tasks landed. Round v3 closed at HEAD `56ca0347`,
master clean.

**Headline win:** Task #10 distance-gated `R_DrawShadows`. Cvar
`r_shadow_distance` (CVAR_ARCHIVE, default 0 = unlimited); G4
autoexec sets 512. Squared compare against `r_origin` in
`R_DrawShadows`, skips the per-entity R_LightPoint BSP trace +
matrix setup + GL_DrawAliasFrame for visually-negligible distant
entities.

Bench numbers, full grid 23.5/24 cells (one transient Lion NA on
demo3 1024 run2; documented in commit `37f26f74`). HEAD-tag 5480d89c.

| host    | demo1 1024 | demo1 640 | demo3 1024 | demo3 640 |
|---------|-----------|-----------|-----------|-----------|
| g3      | 23.10     | 46.35     | 19.50     | 35.40     |
| g4      | 108.30    | 133.00    | 82.80     | 96.95     |
| g4mini  | 76.65     | 148.20    | 67.30     | 117.55    |
| lion    | 95.70     | 218.45    | 44.70     | 189.25    |

G4 demo1 1024 is +1.8% vs v2 baseline (106.10 → 108.30). G4 demo1 640
is +4.3% (127.50 → 133.00). All cells well above per-platform
playability floors (G4/Lion ≥ 60 fps, G3 ≥ 20 fps). Visual upgrades
shipped: `r_shadows 1`, trilinear filtering, anisotropy 16,
`r_lavaalpha 0.6` and friends — all on G4 + Lion.

## Other v3 deliverables (background context, no action needed)

- Pass B revive sweep: B1 HUD pickup flash, B2 CL_DumpPacket, B3 cvar
  autoexec defaults, B4 Lion `-noglslalias` verified-no-op, B6 Rage 128
  CVA Lock retest hatch (`-r128-cva` opt-in flag preserved).
- Phase 4.4 + §14.3 item 4 AltiVec retuning closed as no-win-found
  (commit `5ee613ee`). Both blocks remain opt-in via `-altivec-lm` and
  `-altivec-dlights`. Documented in `PPC_PLAN.md` §13.2.
- Mac mini G4 (`g4mini` host) added as a 4th bench leg
  (`a1cd13c2`). Same arch + SDK as Quicksilver; tooling support
  spans build/deploy/bench/parallel-bench/full-bench.
- Pass A item 5 BGRA static-texture upload reverted; mistakes log
  captures the failure mode (`MISTAKES.md`, top entry).

## What's left for round v4

### Task #12 (carried over): fat-binary deployment with per-host defaults

User confirmed in the prior session: **the goal is one
`Quakespasm.app` bundle that runs at sane 1024×768 defaults on G3
Panther + G4 Tiger + Intel Lion**. Three implementation paths were
sketched; the user picked **Option A**.

Option A = per-arch autoexec files in the bundle's `id1/` + a small
engine hook that picks the right one. Smallest patch, reuses the
existing per-target autoexecs we already maintain.

**Already in tree (round v3 checkpoint, `56ca0347`):**

- `scripts/build-fat.sh` — runs `build.sh g3 && build.sh g4 &&
  build.sh lion` sequentially, then `lipo -create` on the Lion
  build host. Output: `build/quakespasm-fat` (3 slices: ppc750,
  ppc7400, x86_64). Ready to run end-to-end; not yet validated.

**Round v4 Option A work:**

1. **Engine hook.** Find where the engine queues `exec quake.rc` at
   startup (in `Host_Init` / `Common_Init` / similar). Quake's
   `quake.rc` lives in pak0 and itself does `exec config.cfg` then
   `exec autoexec.cfg`. After the `Cbuf_AddText("exec quake.rc\n")`
   line, append a single `Cbuf_AddText("exec autoexec-<ARCH>.cfg\n")`,
   where `<ARCH>` is a compile-time macro:
   ```c
   #if defined(__VEC__)
       Cbuf_AddText ("exec autoexec-ppc7400.cfg\n");
   #elif defined(__ppc__)
       Cbuf_AddText ("exec autoexec-ppc750.cfg\n");
   #elif defined(__x86_64__)
       Cbuf_AddText ("exec autoexec-x86_64.cfg\n");
   #endif
   ```
   The order matters: `quake.rc`'s exec uses `Cbuf_InsertText` to
   prepend the file contents, so `autoexec.cfg` runs FIRST and our
   per-arch one runs SECOND, layering on top. That's correct.

2. **Bundle the per-arch autoexec files.** Copy the existing
   `scripts/bundle/autoexec-{g3,g4,g4mini,lion}.cfg` content into:
   - `scripts/bundle/autoexec-ppc750.cfg`  (= autoexec-g3.cfg)
   - `scripts/bundle/autoexec-ppc7400.cfg` (unify g4 + g4mini —
     same CPU subtype, same compiled slice; the only differences
     between today's two configs are comments)
   - `scripts/bundle/autoexec-x86_64.cfg`  (= autoexec-lion.cfg)

3. **Update `scripts/deploy.sh`** to support a `fat` target. Layout:
   ```
   Quakespasm.app/Contents/MacOS/quakespasm    ← build/quakespasm-fat
   id1/autoexec-ppc750.cfg
   id1/autoexec-ppc7400.cfg
   id1/autoexec-x86_64.cfg
   ```
   No `id1/autoexec.cfg` — let the engine hook pick the per-arch
   file directly. (Or ship one with comments only, to avoid user
   confusion about "where do I put my own tweaks?")

4. **Validate on every host.** Deploy fat to G3, G4, G4mini, Lion.
   `+timedemo demo1 +quit` per host. Verify each picks its slice
   (`file Quakespasm.app/Contents/MacOS/quakespasm` shows fat;
   the runtime selects per-host) and the right autoexec — confirm
   via console (cvar values match what the per-target autoexec set).

5. **SDL.framework story (still open).** The bundled
   `MacOSX/SDL.framework/Versions/A/SDL` is fat (x86_64 + i386 +
   ppc) but its PPC slice was 10.6-SDK-built and crashes on Panther.
   Today `deploy.sh g3` swaps in `MacOSX/SDL-panther.dylib`. For a
   single fat bundle, we need ONE SDL.framework that works on G3 +
   G4 + Lion. Two viable shapes:
   - **a)** `lipo -replace ppc` of the bundled SDL with
     `SDL-panther.dylib` (a single PPC slice that's
     Panther-compatible). Open question from
     `docs/research/fat-binary-feasibility.md`: does Panther-built
     SDL run cleanly on Tiger? If yes → ship a fat with one PPC SDL
     slice, simplest path. If no → option (b).
   - **b)** Build a Tiger-native SDL slice + lipo it alongside the
     Panther slice into a 4-slice SDL fat (x86_64 + i386 +
     ppc750 + ppc7400). More invasive but bullet-proof.

   Test for the open question: deploy a fat bundle to G4 with the
   SDL-panther swap, run `+timedemo demo1`, verify no SDL crash.

### New sub-task: screenshot tool for blog content

User wants screenshots from each host while the fat binary is running
— for blog post screenshots. Quake has a built-in `screenshot` console
command that dumps a TGA into `id1/screenshots/`. Approach:

1. New helper `scripts/screenshot.sh <host>` (or extend bench.sh).
   Launches Quake on a map (`+map e1m1`), waits a beat, dumps 1-3
   screenshots via console commands, scp's the .tga back to the
   orchestration host, optionally converts to PNG (`convert` /
   `tga2png`).

2. Probable command line:
   ```
   ./Quakespasm.app/Contents/MacOS/quakespasm -nolauncher -basedir . \
     -fullscreen -width 1024 -height 768 \
     +map e1m1 +wait 200 +screenshot +wait 60 +screenshot +quit
   ```
   The `+wait N` insert spaces frames so the engine has time to
   simulate before the shot. Tune N per-host (G3 needs more wait
   per frame).

3. Run after the fat binary is verified-good on each host. Capture
   shots from each: same map, same vantage, so the visual difference
   between hosts (R128 classic warp vs Radeon 9000 new shader vs GMA
   950 trilinear) is comparable side-by-side.

## State of the tree

- Branch: `master`, ahead of origin by ~86 commits, clean.
- HEAD: `56ca0347` "Pre-fat-binary checkpoint: build-fat.sh + cadence
  rule + doc updates"
- Recent commit chain (newest first):
  1. `56ca0347` Pre-fat-binary checkpoint
  2. `37f26f74` bench: v3 round wrap (HEAD 5480d89c) — 23.5/24 cells
  3. `5480d89c` bench: Task #10 distance-gated shadows
  4. `79b6207e` Task #10: distance-gated R_DrawShadows
  5. `5ee613ee` Task #9 close as no-win-found
  6. `a1cd13c2` Tooling: g4mini support across all bench scripts
  7. `f847c421` Resume prompt v2 (the prior handoff)

## Discipline reminders

1. **Read `MISTAKES.md` before lighting up an idea that smells "easy"
   or "load-time only / zero risk".** The Pass A item 5 BGRA failure
   ate 90 min and crashed all 4 hosts. Top entry, dated 2026-05-08.

2. **Smoke-bench every host before committing**, even for changes
   tagged "load-time only" or "harmless engine hook". The fat-binary
   engine hook in §1 above touches startup. Smoke after deploy:
   each host must boot, load demo1, render correctly, and exit
   cleanly. Don't skip this on the assumption that "it's just one
   line of Cbuf_AddText".

3. **The blog-post recap doc lives at
   `/home/matt/Desktop/quakespasm-ppc-day1-recap.md`.** Last updated
   end of v3 (Day 6 section). User may ask for it to be updated again
   at end of v4.

4. **The full plan is in `PPC_PLAN.md`.** §14.5 is the fat-binary
   tooling phase; §13.2 is Phase 4.4 status (informational only —
   AltiVec retuning closed). §14.4 Round-wrap full-grid bench is
   already done.

5. **Bench cadence: read `CLAUDE.md` "Bench-and-commit cadence"
   section.** New subsection added in `56ca0347`: manual-commit
   override when parallel-bench refuses on a transient flake.

6. **g4mini autoexec.** Currently identical content to g4.cfg
   except for some comments. When unifying into autoexec-ppc7400.cfg,
   the merged file should reflect "shared by Quicksilver + Mac mini"
   intent in its comments.

## Tooling reference

- `scripts/build.sh <g3|g4|lion>` — single-target build
- `scripts/build-fat.sh` — 3-arch fat build (NEW, untested end-to-end)
- `scripts/deploy.sh <g3|g4|g4mini|lion>` — per-target deploy
  (needs `fat` target added in round v4)
- `scripts/bench.sh <target> <demo> <res> [runs]` — single-cell bench
- `scripts/parallel-bench.sh [--quick] [--no-X]` — full grid
- `scripts/bench-and-commit.sh "<phase>" [--quick]` — bench + commit

SSH aliases (in `~/.ssh/config`): `g4`, `g4mini`, `PowerMacG3`, `lion`.

## First action

Run `git status && git log --oneline -8` to confirm `56ca0347` is HEAD,
then read `MISTAKES.md` end-to-end and `PPC_PLAN.md` §14.5 before
touching the engine. After that, the §1 engine hook is the entry
point — find where `quake.rc` is queued and add the per-arch
`Cbuf_AddText`.
