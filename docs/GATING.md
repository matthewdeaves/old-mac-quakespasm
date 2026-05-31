# Toggleability + per-machine gating

How per-target visual/perf changes stay reviewable and how to ship a change that
helps some machines but hurts others. Root [`CLAUDE.md`](../CLAUDE.md) carries
the one-line rule; this is the full mechanism set. Knob inventory:
[`KNOBS.md`](KNOBS.md).

## Toggleability is a hard requirement

Every per-target visual / perf knob must be flippable at runtime (cvar) or at
launch (cmdline `-flag`) so end-of-round code review can A/B individual
contributions without a rebuild. Inventory lives in [`KNOBS.md`](KNOBS.md) — keep
it current.

Visual-quality floor: an fps win must not regress visuals on any target. Gate
fps-trading modes behind a cvar rather than making them unconditional.

## Per-machine gating is a legitimate pattern

When an optimisation helps some machines and hurts others, gate it — don't drop
it. Three mechanisms, most to least restrictive:

1. **Compile-time gate by build slice** — `#if (__ppc__ && !__VEC__)` for
   G3-only, `#if __VEC__` for G4, `#if __x86_64__` for Intel. Used when the
   runtime check itself would matter on the slice we want to skip, or when the
   code is incompatible with the slice (AltiVec intrinsics on G3). Example: Round
   v11 `gl_aliasstate_cache` compiled out of the G3 slice via
   `QS_DISABLE_ALIAS_STATE_CACHE` in `r_alias.c`.

2. **Per-machine autoexec** (`scripts/bundle/autoexec-<machine>.cfg` in the
   source tree → shipped inside `Quakespasm.app/Contents/Resources/` in the
   deployed bundle, loaded via CFBundle by `QS_ExecConfigFromBundle` at
   `host.c:53`; per-machine pick uses `sysctl hw.model` at `host.c:1024`). Right
   tool when the difference is hardware/driver.

   Two config layers ship in the bundle: the per-arch baseline
   (`autoexec-ppc750/ppc7400/ppc970/x86_64.cfg`, picked at compile time via
   `QS_ARCH_PPC970`/`__VEC__`/`__ppc__`/`__x86_64__` in `host.c` — 970 checked
   first since it also defines `__VEC__`) and the per-machine overlay
   (`autoexec-<machine>.cfg`, picked at boot by `sysctl hw.model`). The overlay
   layers on top of the baseline.

   Since the v1.5 real-conditions change, `bench.sh` STAGES the per-arch +
   per-machine cfg concatenation as a temp `id1/autoexec.cfg` on the target (read
   from the source-tree cfgs) and passes `-noarchautoexec` only to suppress the
   CFBundle layer so it isn't double-applied — so per-machine autoexec state IS
   in effect during benches (real play conditions). `EXTRA_CVARS="+cvar val"`
   still wins (it's a stuffcmd that runs after the autoexec); use it to A/B a
   single cvar without editing the cfg. A compile-time gate is still in effect
   regardless.

3. **Runtime cvar / cmdline opt-out** — everywhere-available toggle for
   end-of-round A/B review.

Don't bury a beneficial change behind a runtime cvar if the beneficiaries are
5/6 of the matrix — gate it to the regressor and ship the wins.

## Boot-order subtlety (the `vid_lock` example)

The CFBundle `.app` autoexec runs AFTER `host.c`'s post-`quake.rc` `vid_unlock`,
so a `vid_lock` placed at the end of a per-arch baseline sticks for real `.app`
launches. The bench-staged `id1/autoexec.cfg` runs via `quake.rc` BEFORE that
`vid_unlock`, so its `vid_lock` is cleared — benching and `-width`/`-height`
overrides are unaffected. See [MISTAKES.md](../MISTAKES.md) 2026-05-31 (G3 Rage
128 resolution-switch crash) for why the fragile-GPU machines lock the mode.
