# Mistakes log — things we tried that were bad

Append-only record of changes that landed in tree (or were attempted)
and turned out to be wrong, harmful, or otherwise misjudged. Each
entry exists so future rounds don't re-litigate the same idea on
incomplete information.

Format: date, what we tried, what went wrong, what the fix was, what
we learned. Newest at the top.

> **Naming note (2026-05-09):** historical entries below reference the
> old machine names (`g3`, `g4`, `g4mini`, `lion`). After the rename
> round those map to `yosemite`, `quicksilver`, `mini-g4`, `mini-intel`
> respectively (and the new `sawtooth` G4 AGP tower joined the matrix).
> Same hardware, just renamed. See CLAUDE.md "Hosts" for the full table.

## 2026-07-25 — `-faltivec` silently un-stamps the ppc7400 cpusubtype

**Tried:** rebuilding the G4 slice against the 10.3.9 SDK at min-10.3 (so a G4
booted on Panther can load it, issue #1). The 10.3.9 SDK's Carbon
`MachineExceptions.h` declares an AltiVec `vector` field and won't parse without
Apple's `-faltivec`, so that flag was added alongside the existing
`-mcpu=7400 -maltivec -mabi=altivec`.

**What went wrong:** the resulting slice came out as generic `ppc (ALL)` instead
of `ppc7400`. `-mcpu=7400` normally propagates into the Mach-O cpusubtype;
`-faltivec` defeats that. Nothing in the build complained — `lipo -info` was the
only signal.

**Why it matters:** this is not cosmetic. Panther's lax 2003 dyld accepts a
generic `ppc` slice, but the Tiger/Leopard **kernel** mis-grades a fat of
`[ppc ALL, ppc7400, ppc970]` on a 750 host and refuses to exec it at all. The
sister Half-Life port shipped exactly that bug in its v1.0.0 and could not launch
on the G3 under Tiger.

**Fix:** `build.sh` now asserts the expected cpusubtype after every PPC build and
re-stamps the Mach-O header (4-byte big-endian field at offset 8) if the compiler
drifted. Idempotent, and it fails loudly if the stamp doesn't take.

**Learned:** don't trust the compiler to stamp the subtype. Assert it. A build
that exits 0 and produces a runnable-looking binary can still be unlaunchable on
a machine you didn't test.


---

## 2026-05-31 — DMG pipeline could ship a silently-corrupt binary (caught on the Q2 sister port)

**What happened (to Quake II, our shared DMG pipeline's other consumer).**
The Q2 `.dmg` shipped a **single flipped byte** in the ppc7400 code slice: a
register-save `stw r31,...` (`0x93e1fffc`) became `0xe7e1fffc` — an illegal
64-bit-only opcode that traps as privileged on a G4 → `EXC_PPC_PRIVINST` →
instant crash at init on every G4. The build binary was fine; only the **DMG
copy** was corrupt. Our `make-dmg.sh` was the parent that Q2's was adapted
from, so QuakeSpasm carried the **same latent risk**.

**Why it slipped past everything.**
- It wasn't a transfer loss (TCP/SSH/rsync all checksum). The flip happened in
  RAM/on disk on a build-hop machine *outside* the protected path — prime
  suspect the non-ECC RAM / 25-year-old disk on the **1999 Panther G3** we ran
  `hdiutil` on.
- **`hdiutil verify` does NOT catch it** — it only checks that the UDIF
  container's compressed blocks decompress to whatever was stored, NOT that
  what was stored matches the source. A bad byte baked in at creation passes.
- We only ever tested `+timedemo` via `deploy.sh` (direct rsync, no DMG hop).
  We validated the wrong artifact; the DMG-install path was never smoke-tested.

**The fix (three parts, mirroring Q2).**
1. *End-to-end content verification in `make-dmg.sh`.* After building, mount the
   finished image and md5 the 12 shipped code artifacts (engine binary + 10
   codec dylibs + SDL) inside it against the source; retry up to 3× and **fail
   loud** if it can't be made byte-identical. Also md5-check the scp-back.
   Dropped rsync `--partial` (it can reuse a stale chunk on a retry).
2. *Build on Tiger (`mini-g4`), not the G3.* The default `DMG_HOST` now
   auto-picks the first reachable Tiger box (mini-g4 → quicksilver → sawtooth).
   A Tiger UDZO still mounts on Panther→modern; Lion's hdiutil writes a
   container Panther can't mount (no flag fixes it), so Lion stays out for any
   G3-bound image. Binary is still built on Lion (mini-intel) — only the
   `hdiutil` packaging step moved to healthier hardware.
3. *Smoke-test the real artifact.* New `scripts/deploy-dmg.sh` (installs from
   the DMG exactly as a human does) + `scripts/smoke-dmg.sh` (launches the
   installed copy with the **production** bundle config — no `-noarchautoexec`,
   no vid override — plus a `+timedemo` so it self-exits, reporting renderer +
   actual resolution + fps). This is the gate the corrupt DMG slipped past.

**Outcome.** Re-verified the already-published **v1.8** DMG: all 12 artifacts
byte-identical to source — it dodged the corruption (luck: it was built on the
G3). Then rebuilt through the hardened pipeline and smoke-tested all four
reachable machines (G3 800x600 / mini-g4 1024x768 / iMac G5 1440x900 native /
mini-intel 1024x768) — all rendered demo1 to completion, no crash.

**Lessons.**
- `hdiutil verify` is a container checksum, not a content check. If you ship a
  DMG, verify the bytes *inside* it against source end-to-end, every build.
- Don't build release artifacts on the flakiest hardware in the fleet. The G3
  is for *testing the install*, not *creating the image*.
- Test the artifact the user actually runs (DMG → install → launch with the
  production config), not just the convenience path (`deploy.sh` + bench).

---

## 2026-05-31 — G3 Rage 128: a live in-game resolution SWITCH crashes the engine

**What we tried.** Shipped the G3 (`yosemite`, PowerMac1,1, Rage 128,
Panther 10.3.9) with the boot resolution forced in TWO layered cfgs: the
per-arch baseline `autoexec-ppc750.cfg` set `vid_width 1024` **and called
`vid_restart`**, while the per-machine overlay `autoexec-yosemite.cfg` set
`vid_width 800` but **had no `vid_restart`**.

**What went wrong.** The overlay runs after the baseline, but with no
`vid_restart` its 800x600 only landed in the cvars (→ config.cfg), never the
live mode — so the engine actually ran at the baseline's **1024x768**. The
user, seeing the wrong res, opened the video menu and selected 800x600. That
fired a **live fullscreen resolution switch on the Rage 128**, which
**hard-crashed** (black screen, display LUT wedged, OS alive over SSH —
recovered with `ssh yosemite '~/bin/qsreboot.sh'` + a forced reboot). Same
class of fragility as the G5 R300 mode-switch wedge, just a different
failure mode (engine crash vs whole-OS hang).

**The fix (two parts).**
1. *Boot at the target res with ONE mode-set.* Moved 800x600 into the
   ppc750 **baseline** (matching the overlay) so there's a single boot
   `vid_restart` to 800x600 and the overlay just re-asserts the same cvars
   (no second switch). 800x600 is the documented Rage 128 sweet spot.
2. *Disable in-game switching on fragile GPUs.* Exposed `vid_lock` as a
   console command (upstream only locked internally during gamedir changes)
   and call it as the LAST line of `autoexec-ppc750.cfg` (G3) and
   `autoexec-ppc970.cfg` (G5), AFTER the boot `vid_restart`. Also gated
   `VID_Toggle` (alt-enter) and the three video-menu choosers
   (`VID_Menu_ChooseNextMode/Bpp/Rate`) on `vid_locked` — otherwise the menu
   would still mutate `vid_*` cvars (poisoning config.cfg → a hazardous
   mode switch on the NEXT boot) even though the apply itself no-ops. The
   menu/alt-enter/`vid_restart` are now inert on G3+G5 until `vid_unlock`.

**Lessons.**
- A two-layer cfg where the overlay changes a resolution cvar **without a
  `vid_restart`** is a silent no-op for the live mode — the value only shows
  up as a phantom in config.cfg. Put the authoritative boot res (and its one
  restart) in ONE place.
- On a GPU that can't survive a live mode switch, booting at the right res
  isn't enough — the **video menu and alt-enter are loaded guns**. Lock the
  mode (and gate the cvar-mutating menu paths) so the user can't pull the
  trigger. `vid_unlock` stays as the escape hatch for known-safe GPUs.
- The lock placement exploits boot order: the CFBundle `.app` autoexec runs
  AFTER host.c's post-`quake.rc` `vid_unlock`, so its `vid_lock` sticks for
  real play; the bench-staged `id1/autoexec.cfg` runs BEFORE that
  `vid_unlock`, so benching/`-width` overrides are unaffected.

---

## 2026-05-31 — iMac G5: GLSL/VBO on the ATI Radeon 9600 hard-hangs the whole OS

**What we tried.** Bringing the new iMac G5 (`PowerMac8,2`, ppc970, ATI
Radeon 9600 / RV351, Leopard 10.5.8) online as a bench/deploy target.
First deploy + `bench.sh imac-g5 ... -fullscreen` HARD-HUNG the machine:
grey screen, no ping, no SSH, fans to max (SMU thermal failsafe when the
kernel stops servicing it). Required a physical power-cycle. A later
**windowed** smoke also wedged it (more gently — SSH stayed up).

**What went wrong — two red herrings before the real cause.**
1. *Suspected fullscreen SDL.* We rebuilt SDL 1.2.15 against the 10.5 SDK
   as a dedicated `ppc970` slice (the shipped slice is the 10.3.9/Panther
   build). The new SDL loaded + rendered fine **windowed**... then wedged
   anyway. So SDL was **not** the hang (the Leopard SDL slice is still
   the right thing to ship — see MacOSX/CLAUDE.md — just not the cure).
2. *The real cause: the GL 2.0 / GLSL / VBO path.* The Radeon 9600 (R300)
   is the **only GPU in the fleet that advertises OpenGL 2.0**, so it's the
   only one that ever ran QuakeSpasm's GLSL + VBO renderer. The R300's Mac
   GL2 driver on Leopard is broken — exercising GLSL locks the GPU (and the
   OS). Every other box (Rage128, GeForce2 MX, Radeon 9000/9200) is GL
   1.2–1.3 and silently uses fixed-function, so none ever hit it. Matches
   QuakeSpasm bug #43 (same card+OS) and its regression window ("0.85.x
   worked, 0.91.0 broke" = exactly when GLSL/VBO landed).

**The fix.** Runtime renderer gate in `gl_vidsdl.c GL_CheckExtensions`
(same idiom as the Rage128 CVA skip): on `Radeon 9500/9600/9700/9800`,
force the GL 1.x fixed-function path (skip VBO, NPOT, GLSL, warp-mipmaps),
`-atigl` overrides for A/B. Validated first with the existing
`-noglsl -novbo -notexturenpot -nowarpmipmaps` flags (no rebuild). Result:
stable **119 fps at native 1440x900 fullscreen 32bpp** with the full GL-1.x
visual stack (same as the G4s). Confirmed via cmdline flags AND the
baked-in gate auto-firing with zero flags.

**Also: never do a fullscreen mode-SWITCH on this card.** The first
full-OS-death was a 1024x768 fullscreen on a 1440x900 desktop (a mode
*switch*). Use `vid_desktopfullscreen 1` → same-mode display CAPTURE at the
native panel res (1440x900 / 1680x1050) — the driver survives a capture but
not a switch. Added SDL-1.2 support for this (substitute captured
`display_*` in `VID_SetMode`); SDL2 gets it free via
`SDL_WINDOW_FULLSCREEN_DESKTOP`.

**Lessons.**
- A GPU that *advertises* GL2 on an old Mac driver is a trap. The first
  GL-2.0-class GPU in a fleet exercises code paths nothing else did. Gate on
  the **renderer string**, not the CPU/slice (NVIDIA G5s drive GLSL fine).
- GL 1.x here is **not** a compromise — fixed-function ran 119 fps with the
  full visual stack, and R300 GLSL is partly software-emulated (likely
  *slower*). No meaningful fps/visuals are left on the table.
- **Leopard `sudo` has no `-n` flag** (`sudo: illegal option -n`), so
  `qsreboot.sh`'s `sudo -n /sbin/reboot` Tier-1 silently fails on 10.5. Use
  plain `sudo /sbin/reboot` (NOPASSWD entry still works). `qsreboot.sh`
  needs a Leopard fallback.
- Wedge severity splits by trigger: **fullscreen mode-switch (+GLSL) = full
  OS death** (power-cycle only); **windowed/GLSL distress = half-alive** (SSH
  up, `sudo /sbin/reboot` recovers). Iterate windowed/native-same-mode only.

---

## 2026-05-29 — Code-review cheap win: vid_bpp 32 hard-wedged mini-g4 (Radeon 9200)

**What we tried.** Code-review finding #1: every target defaults to
`vid_bpp 16`, which forces `stencilbits=0` (gl_vidsdl.c:609-618), so
`r_shadows`' stencil self-intersection mask (`if (gl_stencilbits)`,
gl_rmain.c:1081) never runs and shadows render the doubled-alpha way.
Fix: set `vid_bpp 32` (→ 24-bit depth + 8-bit stencil) in the per-machine
autoexec for the machines with GPU headroom, plus a one-line `VID_Restart`
fsaa-refresh fix so a paired `vid_fsaa` could also take effect. Each
machine config set `vid_bpp 32` + `vid_restart` at boot.

**What went wrong.** First bench launch on **mini-g4 (Radeon 9200 /
Tiger)** HARD-WEDGED the GPU during boot video-mode init: qconsole.log
stopped right after "256 megabyte heap" and before the "Video mode" line,
SSH went unreachable (whole OS hung, not just the display), and the
machine auto-rebooted. **quicksilver (Radeon 9000) ran the identical
32bpp + vid_restart path through ~7 launches with zero issues** and a
clean +stencil/24-bit-depth result (verified 16-bit-z at vid_bpp 16 vs
24-bit-z at 32), so the binary/config pattern is fine — it's
9200-driver-specific.

**Muddier on retest.** After reverting the mini-g4 autoexec, the machine
still booted 32bpp (its config.cfg had saved `vid_bpp "32"` from the
wedged session — `deploy.sh` does NOT seed config.cfg) and this time ran
demo2/demo1 FINE at 24-bit-z. And with config.cfg forced to 16, mini-g4's
depth negotiation came back **inconsistent between launches** (demo1 run1
= 16-bit z-buffer, run2 = 24-bit, same config). So the 9200's mode/depth
negotiation is simply flaky, and the wedge is **intermittent** — which is
worse to ship than a deterministic failure. Cause is ambiguous between
the 32bpp mode itself and the *extra* boot `vid_restart` the machine
config added (the per-arch ppc7400.cfg already does one boot vid_restart;
the machine line made it two).

**Disposition.** Gate mini-g4 to the engine-default 16bpp (no `vid_bpp`
line, no machine vid_restart). Keep `vid_bpp 32` on quicksilver (9000,
verified stable, ~3% cost, holds 60 floor) and ship it unverified on
imac-2019 (modern Radeon Pro 580X — a 2004-era driver wedge does not
apply; and the real iMac win there is `vid_fsaa 8` MSAA). Per-machine
gating doc: gate to the regressor, ship the wins.

**Lessons.**
- `vid_bpp`'s `x32` in the "Video mode" log is the *colour* depth (often
  forced to the desktop's 32-bit by VID_ValidMode fallback regardless of
  the cvar); the meaningful field is "(N-bit z-buffer)" — 16-bit z = no
  stencil, 24-bit z = stencil 8. Read that, not the `xNN`.
- An autoexec-driven boot `vid_restart` is NOT free on old GPU drivers —
  it tears down + recreates the GL context during early init and the
  Radeon 9200 can hang the whole OS doing it. Don't add a second boot
  restart on PPC machines without per-machine bench proof.
- `deploy.sh` does not seed config.cfg, so a cvar the engine saved during
  a test run (here vid_bpp 32) persists on the target and silently
  changes the next launch. Reset config.cfg explicitly when reverting.
- A modern bench machine being offline (imac-2019 here) means the headline
  visual win ships unverified — flag it loudly in the cfg + commit msg.

---

## 2026-05-10 — Round v9 + v10 misattribution: a "code regression" that wasn't

**What happened.** Round v9 wrap full grid showed catastrophic demo3
regression across every PPC + Lion machine (yosemite -24.5%, sawtooth
-23.3%, quicksilver -28.6%, mini-g4 -32.9%, mini-intel -18.0%) plus
demo1 -15% on iMac. Round v9's only landed item was the Ironwail flat-
array efrags pattern (commit 6f3976f8). Reverted at 13b6876a on the
strength of "bench shows demo3 regression on every machine".

**Round v10 take 2 (flat efrags + per-leaf cull) was implemented to fix
the v9 demo3 regression** — the hypothesis being that v9's
R_StoreStaticEntities tested only PVS, not per-leaf frustum, so it
added bonus alias-lerp setup on entities the legacy efrag walk would
have culled. Take 2 hooked into R_MarkSurfaces' existing leaf cull
loop and tested a per-leaf-visible bitmask in R_StoreStaticEntities.

**Bisect outcome.** v10 take 2 binary on yosemite demo3 1024: 15.00 fps
flat path / 15.10 fps `-noflatefrags` legacy path. Same number. v10
wasn't the fix because there was nothing in v9 to fix.

**Real cause.** Demo3 regression was an **autoexec change** on the
PPC machines, not a code change. The autoexec-yosemite.cfg history:

  7a545e03 (2026-05-09 07:29): added r_lavaalpha 0.6 / r_telealpha 0.6 /
                                r_slimealpha 0.6 → benched 20.25 fps OK
  ...
  969ff... (later 2026-05-09):  autoexec: enable Tier A emissive lights
                                across all 6 machines

Today's f2df151d-rebuilt bench (same code as yesterday's 19.80 fps
baseline, today's autoexec) → 14.45 fps. The same bench with
id1/autoexec.cfg renamed → 19.45 fps. The cost was in autoexec, not
code. Bisect on autoexec lines pointed to `r_lavaalpha 0.6` as the
single largest contributor (-26 % alone). Tele + slime alpha together
also regressed.

Why did 7a545e03 bench at 20.25 fps with the same content? **The
yosemite hardware/state reads ~5 fps slower today** in the same
configuration. Possibly thermal accumulation across multiple bench
sessions, possibly capacitor age (1999 silicon), possibly a stuck OS
state that even reboots don't fully clear. Either way the real-world
fps today doesn't match the bench from 2026-05-09 morning, so the
historical value isn't a good comparison target.

**Fix.** f1fea29f drops r_lavaalpha / r_telealpha / r_slimealpha from
the G3 autoexec, keeps r_wateralpha (water see-through is the most-
common transparent-liquid effect in regular play and was already in
baseline at 0.6). Yosemite demo3 1024 recovered to 20.60 fps.

**Lessons.**
- Bench delta MUST first be checked against the autoexec diff. The
  per-machine cfg files are CVAR-ARCHIVE state that compounds across
  rounds — adding a cvar in autoexec for one round can regress fps on
  later rounds without any code change.
- "Same code, same machine, same bench script" is not enough. The
  cvar set in effect is part of the bench. Verify by running with
  `id1/autoexec.cfg` removed before blaming code.
- v9 item 1 was reverted on a misattribution. The Ironwail flat-array
  pattern's actual fps impact on this codebase was **neutral** on G3
  (15.10 legacy vs 15.00 flat at the time, both regressed by autoexec).
  It might have been a small win without the autoexec confound but
  also might have been net neutral; we don't know. Filed if a future
  round wants to revisit, but only after locking down the autoexec-
  cost question first.
- v10 take 2 was implemented + bench'd cleanly + reverted because it
  delivered no win on G3 (-2.5%) or mini-intel (flat). Consistent with
  the "no fix needed for v9" finding. Net cost: ~1 round of work.
- Yosemite needs **more frequent reboots** during long bench cycles.
  User confirmed empirically. Several mid-session benches today read
  inconsistently between 14.4 and 20.6 fps for the same effective
  config; reboot fixed each time.

**If we revisit:**
- A `r_lavaalpha_distance` cvar (mirroring `r_dynamic_distance` from
  round v5) would let close-up lava blend transparently while far-
  field lava stays opaque. ~1 round of code work; recovers the visual
  effect on G3 without the full-scene fillrate cost. Worth doing if a
  round explicitly targets G3 visual polish.
- The autoexec drift detection problem is real: at minimum, deploy.sh
  could echo a SHA of the deployed `id1/autoexec.cfg` so bench rows
  carry that fingerprint alongside the binary commit hash. CSV schema
  bump candidate.

---

## 2026-05-09 — Round v6 wrap mini-g4 stale-binary CSV pollution

**What happened.** Round v6 wrap full-grid bench appended mini-g4 rows
tagged with the v6 wrap commit `5cbcf785` while a STALE pre-watervis
binary was still deployed on the machine (deployed 11:07Z that morning
under an earlier commit; superseded mid-day by the watervis fat). The
discovery was made post-bench; sawtooth + imac-2019 were re-benched on
the corrected binary, but mini-g4 was missed and shipped wrong rows in
the v6 wrap commit (`3c4de53f`).

**How it surfaced.** Round v7 wrap end-of-round full grid showed mini-g4
demo1 1024 dropping from "v6 baseline 72.20 → 50.30" — a 30% regression
that didn't reproduce in any other phase smoke and didn't match round
v5 wrap pre-watervis numbers.

**Bisect.** Checked out `5cbcf785` in working tree, built G4 binary from
v6 head, deployed to mini-g4, ran standalone bench. Got 53.40 fps —
not 72.20. Confirmed v6 wrap row was stale-binary data. The v7 wrap
50.30 was the actual post-watervis state, properly comparable to the
true v6 baseline of 53.40, i.e. **-5.8%** instead of "-30%".

**Cleanup.** Deleted the 12 stale rows from `benchmarks/results.csv`,
re-ran a full mini-g4 grid at v6 head to capture the correct baseline,
relabeled raw logs accordingly. `docs/archive/PPC_PLAN_v2-v11.md §17.7`
documents the correction.

**Lessons.**
- After ANY mid-bench binary refresh, re-bench EVERY affected machine
  before the wrap commit — not just the ones with most-suspect rows.
- "Stale binary" is invisible to bench scripts: the `.app` MD5 should
  be checked + logged per cell, OR the deploy timestamp should appear
  in CSV alongside the commit hash. Building this in is round-v8 work.
- Cross-validate the v6 wrap CSV against round v5 wrap numbers (which
  had no stale-binary issue): v5 mini-g4 demo1 1024 = 76.00 (pre-
  watervis), v6 stale row = 72.20, v6 actual = 53.40. The v6 stale
  was much closer to v5 than to actual v6, which should have been a
  red flag at wrap-bench time.

**If we revisit:** the mini-g4 demo3 1024 +42% / 640 +46% wins from
v7 phase 1 (sky hoist) on the Radeon 9200's ATI driver are the round
v7 headline. Confirm them in any future bisect — they're the win that
makes the round meaningful.

---

## 2026-05-09 — Round v5 B5: scalar dlight cast hoist — REVERT WAS WRONG, RE-APPLIED

**Read this first.** The original revert below was driven by a bad
baseline reading. A proper A/B done same-session, same-warm-state, on
the same g4mini hardware shows **B5 is a clean +2.9% on demo3 1024 and
+0.9% on demo3 640** with zero regression. Phase A (no B5) and Phase B
(B5) ran back-to-back on warm g4mini, 5 runs per cell, MD5-verified
binaries on both sides. Spread inside each phase < 0.2 fps. See commits
6d386dde (the inconclusive retest that prompted the proper A/B) and the
B5-reapply commit that follows this addendum.

The lesson stands and is now load-bearing: **never declare a regression
without an apples-to-apples same-session A/B on the suspected target.**
The prior workflow compared a fresh-bench reading against a historical
CSV row taken under unknown machine state; the noise band on g4mini for
unchanged code spans 65.20 → 69.30 across recent commits, which is
~6% — wide enough to swallow a +3% real signal.

---

## 2026-05-09 — Round v5 B5: scalar dlight cast hoist (ORIGINAL REVERT — superseded above)

**What we tried.** Round v5 plan B5: replace the scalar fallback's
per-texel `(int)(brightness_f * cred_f)` (3 fmul + 3 fctiw) with
integer-only math (`br * icred` on precomputed scaled-int color
constants and integer-typed local[X], rad, minlight). Cycle estimate
~62% reduction in the inner loop on G3.

Built clean on G3, G4, G4mini, Lion + Linux; visual math difference
is < 1 unit per channel = sub-palette-resolution.

**What went wrong.** Bench result split across the four targets:

* G4 (Quicksilver): demo3 1024 +2.3%, demo3 640 +3.8% — solid win.
* G3: neutral (GPU-bound; CPU savings don't move framerate).
* Lion: neutral (Intel is fast enough that fmul vs imul doesn't
  show).
* **G4mini: demo3 1024 -2.6% reproducibly** (warm runs 66.4 fps vs
  pre-B5 68.15). Outside noise band.

The G4 vs G4mini divergence is the surprise. Both are ppc7400-class
AltiVec, both run the same scalar fallback (`-altivec-dlights` is
opt-in, default off, so neither uses the AltiVec dlight path). Yet
G4 wins and G4mini loses on the same code change. Likely
microarchitectural — G4 Quicksilver is MPC7450, G4 mini is MPC7447A
generation. Cache subsystem and integer/FP scheduling differ
subtly. Without a real hardware profiler we can't pin it exactly.

**Disposition.** Revert. Project rule is no fps regression on any
target. Ship-or-skip — and "ship with G4mini regression" violates
the rule.

**If we revisit.** A flag-gated opt-in (`-scalardlight-int`) would
let G4 pick up the +2-4% without hurting G4mini. But two reasons
to not bother: (1) G3 doesn't benefit (the bigger goal), so the
juice is only G4-Quicksilver-specific. (2) AltiVec dlights
(`-altivec-dlights` opt-in path) is a better future direction for
the AltiVec targets if we ever make it default-on, since it
addresses the same hot loop with the right tool.

Numbers retained in benchmarks/results.csv tagged `2e8f7861`
(pre-revert). The revert lands as a clean revert commit.

**Retest 2026-05-09 (post all four machines fresh-rebooted) — INITIALLY
mis-verdicted.** First retest compared B5-applied binary against
historical no-B5 readings from the rolling CSV. G4mini came in at 65.00
with B5, sitting inside the 65.20-69.30 historical cluster — read as
"neutral, original revert stands". This was wrong because the historical
cluster itself spans 6%+ noise; a +2.9% real signal hides in there.

**Proper A/B 2026-05-09 (same-session, no reboot between phases).**
Both binaries deployed back-to-back on warm g4mini, 5 runs each cell,
MD5-verified on the target. Result:
* demo3 1024: no-B5 65.10 → B5 67.00 = **+2.9%**
* demo3 640:  no-B5 115.50 → B5 116.50 = **+0.9%**
Each phase tight to 0.2 fps spread. The +2.9% is far outside the
within-phase noise floor. **Original revert was wrong; re-applying B5
in the commit that follows.** Future bench discipline: any
"regression" verdict needs a same-session A/B on the suspected target
before it sticks. Comparing against historical CSV rows under unknown
machine state is unreliable when the target is sensitive to microarch
state (cache, OS bookkeeping, AGP traffic patterns).

---

## 2026-05-09 — Round v5 B3: Lion PGO/LTO (mostly skipped; LTO kept opt-in but neutral)

**What we tried.** Round v5 plan B3 was "Lion PGO + LTO build" expecting
+5–12% on Intel. Two-phase build via `-fprofile-instr-generate` →
timedemo → `llvm-profdata merge` → `-fprofile-instr-use=… -flto`
rebuild.

**What went wrong.** Lion's `/usr/bin/clang` is **Apple clang 1.7
(LLVM 2.9-based)** — much older than the planning estimate of "Apple
LLVM 3.0–3.1 era". Two consequences:

1. `-fprofile-instr-generate` is *silently accepted* (no compile error)
   but produces no instrumentation in the binary — it ran a test
   binary and no `*.profraw` ever appeared. Modern instrumentation
   profile (IR-PGO) landed in LLVM 3.4+; Lion's clang predates it.
   `-fprofile-generate` (gcc-style PGO) is also accepted but Lion's
   `gcc-4.2.1` produced .gcda files normally so it works there — but
   switching the Lion build from clang to gcc-4.2 is a much bigger
   change than a single flag and not justified for an experimental
   PGO try.

2. `-flto` does work and produces a valid binary. Smoke bench at Lion
   demo1 1024×768 × 3 runs:
   * **without LTO:** 96.65 fps (median run 2,3)
   * **with LTO:**    96.85 fps (median run 2,3)
   * **delta:** +0.2 fps, within run-to-run noise (within-run spread
     was 0.8 fps).

   LLVM 2.9-era LTO can't do much that `-O3` isn't already doing.
   Modern LTO (LLVM 7+) typically nets 3–8%; this vintage doesn't.

**Disposition.** Kept `-flto` as a `LTO=1` opt-in env var on
`scripts/build.sh lion` (default off, neutral when on, easy to remove,
useful template if a future Mac target gets a newer toolchain). PGO
not wired — no path that produces real instrumentation on this
toolchain. **B3 closed; B-track perf gains for Intel must come from
algorithmic phases (B4, B5, B6, B7) rather than compiler-driven
optimisation.**

**If we revisit.** Don't redo this on Lion's clang. If a future Lion
replacement has a newer clang (LLVM 3.4+ for IR-PGO, LLVM 7+ for
worthwhile LTO), reopen — the infrastructure (`-flto` opt-in, the
build.sh comment block) is in place to retry quickly. Until then,
Intel perf wins come from source-level changes, not compiler flags.

---

## 2026-05-08 — Pass A item 5: BGRA static-texture upload (reverted)

**What we tried.** Per `docs/research/pass-a-fps-visual-review.md` §1a,
extend Phase 2.1's GL_BGRA + GL_UNSIGNED_INT_8_8_8_8_REV upload format
from per-frame lightmaps to all static textures (world brushes, alias
skins, particle/sky/HUD pics) via `TexMgr_LoadImage32`. Implementation
was an in-place RGBA→BGRA byte swap on the source buffer, then a
format-constant change at the `glTexImage2D` call.

Pass A predicted this as a load-time-only win (zero per-frame fps,
faster map-load wall-clock on Apple's GL stacks). Risk was tagged
medium. Toggleability behind `-nobgra-static` cmdline.

**What went wrong.** Reproducibly crashed **all four bench targets**
during map load: G3 Panther / Rage 128, G4 Quicksilver / Radeon 9000
/ Tiger, G4 Mac mini / Radeon 9200 / Tiger, Lion x86_64 / GMA 950.
Crash signature was identical on every target:

```
EXC_BAD_ACCESS / SIGSEGV  in COM_FindFile + ~256
called from           Image_LoadImage (recursing through extensions)
called from           Mod_LoadTextures (replacement-image lookup)
called from           Mod_LoadBrushModel
called from           Mod_LoadModel
called from           CL_ParseServerInfo
```

The faulting register held an address in the high stack region (e.g.
`0x3f9f08b4`, `0xff3808b4`, derived from r30/rsi pointing into trashed
strings) — i.e. corrupted hunk-allocated filename memory adjacent to
where the texture buffer lived. Engine couldn't find the next
replacement texture's filename and dereferenced through garbage.

**My initial misdiagnosis.** First commit (`cea45842`) gated the path
on `host_bigendian` — I assumed only PPC was broken because the engine
explicitly disables `EXT_packed_pixels` on big-endian
(`gl_vidsdl.c:1424`, upstream sezero/quakespasm#114). That diagnosis
was wrong: Lion (little-endian Intel) also crashed once the new binary
was deployed. The endianness fix was a partial mask of a deeper bug.

**Why Phase 2.1 lightmaps work but this didn't.** The lightmap path
in `R_BuildLightMap` writes bytes directly into the lightmap buffer
in `[B][G][R][A]` order — the data is born in BGRA layout and the
upload format `GL_BGRA + GL_UNSIGNED_INT_8_8_8_8_REV` consumes it
correctly. My static-texture path took an existing RGBA buffer, did
an in-place swap, then handed it to the same upload format. Somewhere
between the swap, the optional resample / mipmap-down / alpha-edge-fix
steps, and the upload, the buffer ended up writing past its allocation
and trashing the adjacent hunk strings. The exact mechanism is
unknown — the byte-count math and buffer-size invariants all looked
correct on inspection.

**Fix.** Reverted to legacy `GL_RGBA + GL_UNSIGNED_BYTE` upload
unconditionally. The BGRA-static path has no fps hot loop attached so
shipping the revert costs nothing measurable. The `bgra_static_disabled`
flag and `-nobgra-static` cmdline are kept in tree as inert plumbing
in case a future round wants to retry with a non-in-place
implementation (allocate a fresh BGRA buffer, copy + swap into it,
pass that to glTexImage2D).

**Lessons.**

1. **Smoke-bench every target before committing**, even for changes
   tagged "load-time only / zero fps move." This change shipped
   through code commits + a smoke bench that passed on all three
   machines (b186ae44 row in `benchmarks/results.csv` shows Lion at
   95.7 fps demo1 1024 with BGRA enabled). Smoke ran demo1 cleanly,
   the crash only surfaces on certain map-load sequences. **Demo1
   is not enough exposure.** A smoke that includes at least one map
   transition (multi-demo loop, or running both demo1 and demo3)
   would have caught this earlier.

2. **In-place buffer mutation is a footgun on shared hunk
   allocations.** The replacement-image lookups happen BEFORE
   TexMgr_LoadImage32 returns, but the buffer was being passed
   around with the assumption that only this function touches it.
   In-place swap meant the corrupted state persists in any buffer
   that's still reachable. If we revisit, allocate fresh.

3. **"Apple's documented fast path" is not a green light.** The
   GL_BGRA + 8_8_8_8_REV combo is genuinely faster on Apple GL when
   the data layout matches. But "matches" needs to be proven, not
   assumed. Phase 2.1 worked because lightmaps are built byte-by-byte
   for that format. Reusing the same upload constants with a
   different data origin path does not automatically inherit the
   correctness.

4. **Endian-only gating is suspicious as a fix.** When my first
   diagnosis was "PPC big-endian only," the same crash on Lion
   should have been a stronger signal that the underlying issue
   wasn't endianness at all. Acted on insufficient evidence.

5. **Lion is now a load-bearing third bench leg.** Without Lion in
   the matrix this round, the bug would have looked PPC-specific and
   the wrong fix could have shipped to round v3. The diversity
   value of having Intel + PPC + multiple GPUs is concrete.

**Cost.** Three engine crashes on G3 (one required a hard reboot),
one on Quicksilver G4, one on Mac mini G4, one on Lion x86_64.
Several commits and a few rounds of re-deploying. ~90 minutes of
session time before reverting.

**Related commits.**

- `b186ae44` — original Pass A item 5 BGRA conversion (now reverted)
- `cea45842` — partial fix gating BGRA on `!host_bigendian` (still
  broken on Lion, also reverted)
- This commit — full revert, mistakes-log entry, autoexec changes
  preserved.
