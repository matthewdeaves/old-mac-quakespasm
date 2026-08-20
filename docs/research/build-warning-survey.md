# QuakeSpasm Build Warning Survey: g3 / g4 / lion

> Research-only report drafted by an investigation agent on 2026-05-08
> at the user's request. Goal: survey gcc/clang warnings emitted when
> building QuakeSpasm for our three targets and report what's worth
> fixing, with an emphasis on **don't just silence noise**, the
> categories that hint at latent perf wins or that a feature is
> reachable now matter more than the suppression list.
>
> **Three quick wins from this report were applied in commit 88bd6fb6**
> (`-Wl,-w` for PPC linker, `-Qunused-arguments` for Lion clang, and
> the missing `#include "gl_perfprint.h"` in `gl_rmisc.c`). The rest of
> the recommendations are captured here for end-of-round and round-v4
> action.

## 1. Warning inventory

Counts are from clean builds with the production flag set
(`-O3 -Wall`, the project's default). A second pass under stricter
flags (`-Wextra -Wcast-align -Wpointer-arith -Wshadow -Wundef
-Wstrict-aliasing=2`) is shown where it surfaced new signal.

### Default `-Wall -O3` (what we ship today)

| Target | Source warnings | Linker warnings | Total |
|---|---|---|---|
| g3 (gcc-4.0, 10.3.9 SDK, ppc750)  | 0 | 2 (crt1, crt2 `-mlong-branch`) | 2 |
| g4 (gcc-4.0, 10.4u SDK, ppc7400 +AltiVec) | 0 | 1 (crt1 `-mlong-branch`) | 1 |
| lion (clang 1.7, native x86_64, 10.7) | 332 (4 kinds × 83 TUs) | 0 | 332 |

The codebase is **completely clean under `-Wall -O3` on both PPC
builds.** Lion's 332 warnings are all "unused argument" complaints
from clang about flags the Makefile feeds it that it ignores
(one per translation unit, four kinds: `-O3`, `-fweb`,
`-frename-registers`, `-mmacosx-version-min=10.6`). All silenced by
the `-Qunused-arguments` quick-fix in build.sh.

### Stricter pass: `-Wextra -Wcast-align -Wpointer-arith -Wshadow -Wundef`

| Kind | g3 (gcc) | g4 (gcc) | lion (clang flag) |
|---|---|---|---|
| `-Wshadow` (`index` shadowed by `<strings.h>`) | 9,454 | n/a (skipped `-Wshadow`) | 0 (clang folds to 15 real shadows in our code) |
| `-Wshadow` (`id` shadowed) | 53 | n/a | 0 |
| `-Wmissing-field-initializers` (cvar partial init) | 165 | 234 | 170 |
| `-Wcast-align` (BSP `byte *` → typed *) | (skipped on gcc-4.0 ppc, no effect) | (skipped) | 232 |
| `-Wsign-compare` | 9 | 13 | 13 |
| `-Wunused-parameter` | 50 | 56 | 44 |
| `-Wimplicit-function-declaration` | 1 | 1 | 1 |
| `-Wunsigned-always-true` | 1 (lodepng) | 1 (lodepng) | 0 |
| `__STDC_VERSION__` undef in opus_types.h | 0 | 1 | 0 |

**Notable:** gcc-4.0's `-Wcast-align` doesn't fire on ppc because
`byte *` and `unsigned int *` have identical alignment requirements on
a 32-bit big-endian target with `-malign-natural`. clang on x86_64
sees the same casts and warns 232 times because pointer alignments
differ between archs, **same source, different alignment math**.

## 2. Triage

### Noise (suppress)

- **`ld: warning: ... -mlong-branch which is no longer needed`** (3
  instances total). Already documented in CLAUDE.md as cosmetic.
  **Applied:** `-Wl,-w` in g3+g4 LDFLAGS, commit 88bd6fb6.
- **clang `argument unused` × 332 on lion**. The Makefile's `check_gcc`
  macro tests with `-Werror -S -o /dev/null` but clang accepts unknown
  flags with a soft warning rather than an error, so `-fweb` and
  `-frename-registers` (gcc-only) get added even on clang. Plus
  duplicate `-O3` (CPUFLAGS) vs `-O2` (Makefile DEBUG=0 path) and
  duplicate `-mmacosx-version-min`. **Applied:** `-Qunused-arguments`
  in lion CPUFLAGS, commit 88bd6fb6.
- **`-Wshadow` for `index` / `id`**, comes from SDL's `SDL_opengl.h`
  and Quake's own `glquake.h` using `index`/`id` as parameter names.
  Upstream we can't fix without forking SDL. Don't enable `-Wshadow`
  project-wide; not actionable.
- **lodepng.c `unsigned >= 0 always true`**, vendored upstream; ignore.
- **opus_types.h `__STDC_VERSION__ is not defined` (g4 only)**,
  vendored opus header; ignore.

### Latent bug (worth fixing)

- **`gl_rmisc.c:240: implicit declaration of R_PerfPrint_Init`**,
  one-liner, all targets. **Applied:** `#include "gl_perfprint.h"`
  added, commit 88bd6fb6.
- **`-Wcast-align` 232 instances on lion**, mostly `byte *` →
  `unsigned int *` / `dvertex_t *` / `dledge_t *` casts loading BSP
  file data. Not bugs in practice (BSP lumps are 4-aligned by
  convention), but they are *undefined behavior on ppc* if a malformed
  BSP ever reaches them with odd alignment. **The interesting subset
  for AltiVec:**
  - `gl_texmgr.c:1247,1286,1355,1495`, `(unsigned *)data` for
    `TexMgr_LoadImage32` upload path.
  - `r_brush.c:1240,1285,1302`, **the lightmap rebuild inner loop**
    `*(unsigned int *)dest = packed` writes. This is the exact code
    Phase 2.x targets for AltiVec.
  - `gl_mesh.c:494,495,546`, `r_alias.c:396,397,605`, alias model VBO
    assembly. Brush/alias hot paths.
  
  None of these are *bugs*, but the warnings are **a high-quality
  alignment audit list** for any future AltiVec work.
- **`-Wsign-compare` 9–13 instances**. Mostly `int i; ... i <
  strlen(buf)` patterns in common.c and image.c. Not currently bugs
  but classic underflow trap if `i` ever goes negative. Worth a sweep.

### Feature gate

**Nothing of substance.** Setting `-DGL_SILENCE_DEPRECATION=1` in the
Makefile globally silences GL deprecation warnings. We have zero
deprecation warnings under any target. Two follow-ups worth knowing:

- The 10.3.9 and 10.4u SDKs **predate the deprecation attribute era**,
  so the PPC builds wouldn't surface deprecations even if we removed
  `GL_SILENCE_DEPRECATION`. There's no hidden "10.7 unlock" we'd find
  here.
- The `MAC_OS_X_VERSION_MAX_ALLOWED >= 1040` guard around
  `kCGLCEMPEngine` in `gl_vidsdl.c:1381` is *correct, not noise*,
  feature-gated multi-threaded GL call that doesn't exist on 10.3.9.

### Perf hint

- **gcc-4.0 vectorizer fails on the hot AltiVec targets.** Re-running
  G4 with `-ftree-vectorize -ftree-vectorizer-verbose=2` shows:
  - `mathlib.c:79` (`VectorNormalize` / `VectorLength`):
    "unsupported use in stmt." Auto-vectorize gives up.
  - `snd_mix.c:271, 449, 507, 611` (`SND_PaintChannelFrom8/16` write
    loops): "unhandled data ref: paintbuffer[].left". Auto-vectorize
    gives up.
  - `r_brush.c:1176` (`R_BuildLightMap` inner loop): "mixed
    data-types"; line 1184: "unsupported use in stmt". Auto-vectorize
    gives up.

  Across the whole build gcc-4.0 successfully auto-vectorizes
  **21 loops** (lodepng init, sky-scroll UV, particle init, COM_Strip*,
  host_cmd serializers). None of those are perf-critical. The hot
  loops in `mathlib.c` / `snd_mix.c` / `r_brush.c` *all* fail,
  confirming the AltiVec list in CLAUDE.md is exactly the right
  manual-intrinsics target.

- No `-Wstack-usage` or `-Wstringop-overflow` warnings (those flags
  didn't exist in gcc-4.0; clang 1.7 has them but doesn't emit any).
- No strict-aliasing violations under `-Wstrict-aliasing=2`. The
  vendored `lodepng.c` and `miniz.c` are clean; our code never
  type-puns through pointers.

### Already documented

- The `-mlong-branch` crt warnings.
- The `kCGLCEMPEngine` 10.4 guard.
- The Obj-C dot-notation patches at `pl_osx.m:92-95` (no longer
  warning, already patched).
- The NSString-encoding shim in QuakeArguments.m / AppController.m
  (no longer warning, already patched).

## 3. Cross-target divergence

Most of the cross-target deltas are alignment math:

- **`-Wcast-align`: 0 on g3/g4 (gcc-4.0 ppc), 232 on lion (clang
  x86_64).** Same source, different result, because gcc-4.0 on ppc
  with `-malign-natural` treats `byte *` and `unsigned int *` as
  same-aligned, while clang on x86_64 LP64 sees stricter alignment for
  8-byte types. Not divergence-as-bug, divergence-as-different-
  architecture-rule.
- **`-Wmissing-field-initializers`: 165 (g3) vs 234 (g4)**. Same
  `cvar_t` literals; the delta is a stale-build artifact.
- **`__STDC_VERSION__ is not defined`**, fires on g4 not g3 because
  `USE_CODEC_OPUS` path differs. One-line vendored opus header issue.
- **`unused parameter '<x>'`: similar volume across all three**,
  same source files, nothing target-specific.

I expected divergence from `#ifdef MAC_OS_X_VERSION_MAX_ALLOWED`
paths: there is none surfaced as a warning. Either the conditional
code is genuinely target-correct, or the warnings get subsumed into
"missing initializer" / "unused parameter" buckets.

## 4. AltiVec-specific warnings

**None.** Including `<altivec.h>` with `-maltivec -mabi=altivec`
produces zero warnings on gcc-4.0. No `vector` literal cast warnings,
no `vec_ld` alignment complaints.

The vectorizer notes from §2 (perf hint) are the closest thing to
"AltiVec warnings" we get, they're informational notes from
`-ftree-vectorizer-verbose`, not warnings, and they're already useful
as a Phase-2/Phase-4 implementation guide.

If we add more AltiVec code, expect type-cast warnings around
`(vector signed char)` ↔ `(vector unsigned char)` conversions,
silenced with explicit `vec_cast`-style intrinsics.

## 5. PPC SDK age warnings

The 10.3.9 / 10.4u SDKs do **not** trigger any "C99-only" warnings,
because:

- gcc-4.0 defaults to `-std=gnu89`, which already permits C99
  features as GNU extensions: compound literals, designated
  initializers, mid-block `for(int i = 0; ...)`. The Makefile leaves
  `-std` unset.
- The codebase happens to use only `-std=gnu89`-clean C anyway (no
  compound literals in the engine, no designated initializers in cvar
  tables, that's why we get 165+ "missing field initializer" instead
  of named-init).

**One inversion to note:** if we *moved to* designated initializers in
cvars (`cvar_t r_norefresh = {.name="r_norefresh", .string="0",
.flags=CVAR_NONE};`), gcc-4.0 accepts it AND the
`-Wmissing-field-initializers` warnings disappear because designated
init exempts unnamed fields from the warning. **170+ warnings could
be deleted by switching cvar literals to designated init**, costs
zero perf, costs one mechanical sweep, makes the cvar registration
syntax self-documenting.

## 6. Unlockable features

- **Stricter Makefile defaults.** Currently `CFLAGS = -Wall -MMD`.
  Adding `-Wimplicit-function-declaration
  -Werror=implicit-function-declaration` would have caught the
  `R_PerfPrint_Init` issue at compile time. gcc-4.0 + clang both
  support it.
- **Designated cvar initializers** unlock `-Wmissing-field-initializers`
  cleanliness, which then unlocks `-Wextra` as a regular CFLAGS
  addition. `-Wextra` would catch real bugs going forward without
  170+ noise warnings.
- **Fixed `check_gcc` macro.** Today it lets `-fweb` and
  `-frename-registers` flow into clang where they're ignored. Beyond
  cosmetic noise, this means **lion currently isn't getting the
  `-fweb` / `-frename-registers` optimizations our PPC builds get**
  (which is fine because clang has its own scheduler), but **`-O3` is
  silently downgraded to `-O2` on lion** (since `-O2` comes after
  `-O3` in the command line). Fixing this would actually let `-O3`
  apply on lion. **Bench numbers may move.**
- **`-Wl,-w` for g3/g4 LDFLAGS**, applied.
- **`-Qunused-arguments` for lion**, applied.

## 7. Recommended actions (ROI-ordered)

1. **(applied 88bd6fb6) Add `#include "gl_perfprint.h"` to gl_rmisc.c.**
2. **(applied 88bd6fb6) Add `-Wl,-w` to g3+g4 LDFLAGS.**
3. **(applied 88bd6fb6) Add `-Qunused-arguments` to lion's CFLAGS.**
4. **(15-min, medium signal, DEFERRED) Fix the `-O3 → -O2` downgrade
   on lion.** Makefile.darwin appends `-O2` after CPUFLAGS' `-O3`.
   Either drop the `-O2` from the DEBUG=0 path when CPUFLAGS already
   specifies `-O*`, or have lion's CPUFLAGS specify nothing and let
   the Makefile's `-O2` win. **Side effect: lion benchmarks may move
   when `-O3` actually applies.** Run `parallel-bench.sh --quick`
   after to confirm.
5. **(30-min, medium signal, DEFERRED) Fix `check_gcc` macro to also
   detect clang's "argument unused" warning.** This is the proper fix
   for #3.
6. **(2-hour sweep, DEFERRED) Convert cvar literals to designated
   initializers** across `gl_rmain.c`, `host.c`, `gl_screen.c`,
   `cl_main.c`, `in_sdl.c`, `snd_dma.c`, `gl_vidsdl.c`, `gl_warp.c`,
   `gl_texmgr.c`, `view.c`, `cl_input.c`, `pr_edict.c`, `host_cmd.c`
   (top contributors per the strict-pass count). Eliminates ~170
   missing-init warnings AND makes cvar registration grep-friendly.
   **Cost: pure mechanical edit.** Risk: low. Unblocks `-Wextra` as a
   permanent CFLAGS addition.
7. **(1-hour sweep, DEFERRED) Sign-compare cleanup** in common.c
   (loop counters), image.c, gl_rlight.c, r_brush.c. ~13 instances.
   Convert loop iterators from `int` to `size_t` where they range
   over `strlen()` / `Cmd_Argc()` results.
8. **(deferred, Phase 2.x prep) Treat the lion `-Wcast-align` list as
   the AltiVec alignment audit checklist.** The 25 hits in
   `gl_texmgr.c`, `r_brush.c`, `gl_mesh.c`, `r_alias.c`, `gl_model.c`
   map directly to the data paths AltiVec rewrites would touch. Don't
   fix them yet, when implementing AltiVec lightmap update or AltiVec
   mesh upload, revisit each cast site, document the alignment
   guarantee in a comment, and add a debug-build `assert((uintptr_t)ptr
   % 16 == 0)` before any `vec_ld`.
9. **(skip) Don't bother with `-Wshadow` project-wide.** 9,500 hits
   from upstream SDL/glquake `index` parameter names. Not actionable.
10. **(skip) Don't enable `-Wcast-align` on PPC.** gcc-4.0 doesn't flag
    the casts (different alignment math), and forcing them would
    create a divergence between targets where the lion CI catches
    things the PPC builds miss. Use lion as the cast-align lint
    reference and let PPC stay quiet.

## Files of interest

- `/home/matt/quakespasm/Quake/Makefile.darwin`, flag pipeline; the
  `check_gcc` macro at line 35, the `-O2`/`-O3` collision at line 60.
- `/home/matt/quakespasm/scripts/build.sh`, per-target CPUFLAGS, the
  place where `-Wl,-w` (g3/g4) and `-Qunused-arguments` (lion) live.
- `/home/matt/quakespasm/Quake/cvar.h:80`, `cvar_t` struct that 170+
  literals partially-init.
- `/home/matt/quakespasm/Quake/r_brush.c:1235-1306`, the
  `R_BuildLightMap` inner loop, AltiVec target.
- `/home/matt/quakespasm/Quake/snd_mix.c:271,449,507,611`,
  `SND_PaintChannelFrom*` write loops.
- `/home/matt/quakespasm/Quake/mathlib.c:79`,
  `VectorNormalize`/`VectorLength` area.

## Raw logs (not preserved)

The gcc/clang stdout/stderr from the strict-pass builds was kept on
Lion at `/tmp/qs-warn-{g3,g4,lion}.log` and
`/tmp/qs-warn-{g3,g4,lion}-strict.log` during the agent's
investigation but those `/tmp` files are not preserved across reboots.
Re-run via the agent's described command if needed.
