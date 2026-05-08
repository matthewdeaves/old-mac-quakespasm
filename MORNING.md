# Morning summary — Round v5 overnight progress

## What landed (5 commits)

```
81d6d760 Round v5 A4 + B4/B7: PPC sweep null result, B4/B7 already done
180ce9dc Round v5 B1: r_dynamic_distance — G3 dlight distance gate (headline)
aa1018ea Round v5 A5: capture optimisation-report sweep -- mostly null result
cfd31d68 Round v5 B3: try LTO/PGO on Lion -- LTO neutral, PGO unsupported
765e2da4 Round v5 A6: gl_perfprint API-call counters (gl_perfprint 2)
2813dc2f Round v5 A1/A2/A7: wire static analysis tooling + fix surfaced UB
```

## Headline

**B1 dlight distance gate is in tree and ready for G3 bench validation.**
This is the round's predicted-biggest G3 lever. Code mirrors the
shipped `r_shadow_distance` Pass C HIGH pattern. Engine default 0 =
upstream parity (Lion confirmed neutral); G3 autoexec sets 768.

## Real bugs found and fixed via the new tooling

1. **`pr_edict.c` null-deref** (2 sites) — `ED_FieldAtOfs(NULL)` deref
   during edict printing. Defensive fix.
2. **`snd_mem.c` signed-shift UB** (3 sites) — same class as Pass B
   `463ec405`. UBSan caught all of them; rewrote in unsigned.

## What needs your attention (in order)

### 1. Sudo install (one command, then I can finish A2)

```
sudo apt install -y clang-tools clang-tidy flawfinder sparse iwyu
```

This unlocks scan-build, clang-tidy, flawfinder, sparse, iwyu — five
more analysers that need root. After that, `scripts/analyze-all.sh`
runs the full battery and any further bugs surface there.

### 2. Power on G3 + G4 + G4mini, then bench

```
scripts/parallel-bench.sh --quick
```

Expected outcomes:
- **G3 demo3 1024×768: +5–15% over baseline.** This is B1's headline
  test (dlight-heavy demo on the GPU-bound target).
- **G3 demo1 / demo2: neutral.** Sparse dlights, distance gate has
  nothing to elide.
- **G4 / G4mini: neutral.** Engine default 0 = same as before.
- **Lion: neutral.** Already confirmed (96.75 vs 96.65 fps within
  noise).

If demo3 doesn't move, the gate is firing on too few dlights — try
`r_dynamic_distance 512` on G3 (more aggressive) before declaring B1
a flop.

### 3. Run gl_perfprint 2 on G3 to gate B2 decision

```
ssh PowerMacG3 "..." # with +gl_perfprint 2 +timedemo demo3
```

Look for the `gl_perfprint: binds=… draws=… dlights=… surfs=… atris=…`
line in qconsole.log. Decision rule:

- **binds/frame > 1000:** B2 (state-change batching) is justified.
  Sort opaque world surface chains by texture before draw.
- **binds/frame < 500:** drop B2, not worth the implementation
  effort.
- **500–1000:** judgment call.

Lion shows ~30–50 binds/frame at demo1, suggesting G3 will be
similarly low and B2 likely drops. But measure before deciding.

## What I deferred and why

| Phase | Why deferred |
|-------|--------------|
| **B5** scalar dlight cast hoist | Visual fidelity needs G3/G4 verification (lightmap precision diff). Pure CPU win on a GPU-bound target. Worth doing, low priority. |
| **B6** AngleVectors caching | Larger refactor; needs G4-side bench validation. Speculative win. |
| **B8** G3 visual re-enable | Gated on B1 cumulative outcome. |
| **End-of-round full grid** | Final step after B-track closes. |

## Things that turned out to be already-done or unworkable

- **B3 LTO/PGO**: Lion's clang is LLVM 2.9-based, much older than the
  plan estimated. PGO instrumentation silently no-ops, LTO is neutral.
  Kept `LTO=1` opt-in flag for future newer-clang targets. Documented
  in `MISTAKES.md`.
- **B4 R_CullBox unroll**: gcc -O3 already unrolls the 4-iter loop
  automatically. Inspecting `gl_rmain.c:466` showed nothing manual
  to gain.
- **B7 R_MarkLights goto**: Already done in tree. `gl_rlight.c:168`
  uses the goto-loop pattern.
- **A5 opt-info**: Vectoriser misses are mostly irreducible (GL
  walls, vec3 below 4-wide minimum). Existing AltiVec hand-paths
  already cover what's vectorisable. Negative result is signal —
  Round v6 won't relitigate.

## Files of interest

- `analysis/INDEX.md` — tool inventory and run status
- `analysis/warnings-triage.md` — full disposition for every warning
  class found (Linux + PPC + sanitisers)
- `analysis/perf-candidates.md` — vectoriser-miss triage
- `MISTAKES.md` — new entry on B3
- `PPC_PLAN.md` §15 — round v5 progress log

## A note on autonomy

You said "decide-and-ship on impl details; only ask for plan-level
pivots". I took that to mean: when B5/B6/B8 hit the "needs visual
verification on G3" wall, defer rather than ship a probable-but-
unverified visual change. The user-stated visual-quality floor
overrides "more shipped is better". I think that's right; let me
know if you'd have rather I shipped them with `-Wcast-align`-class
notes for you to verify in the morning instead.
