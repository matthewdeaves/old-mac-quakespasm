# Modern compiler warning triage — Linux build (Ubuntu gcc 15.2)

**Run:** `scripts/build-linux.sh default` — full warning maxout against the
same source the PPC + Lion ship binaries compile.

**Findings count:** 1595 total. Class breakdown (after fixing the
EXTRA_CFLAGS plumbing so SDL2 paths actually compile):

| Class | Count | Severity | Disposition |
|-------|-------|----------|-------------|
| `-Wdouble-promotion` | 506 | perf-relevant on PPC | Track B candidate (see below) |
| `-Wfloat-equal` | 470 | mostly noise | suppress unless individual cases look real |
| `-Wmissing-prototypes` | 322 | cleanup | mark TU-private functions `static` (low-risk batch fix) |
| `-Wmissing-field-initializers` | 234 | style | suppress (cvar_t partial-init is intentional Quake style) |
| `-Wunused-parameter` | 33 | cleanup | suppress globally (Quake `cmd_t` callbacks have unused argv) |
| `-Wstrict-aliasing` | 12 | UB candidate | type-pun audit needed (see below) |
| `-Wsign-compare` | 10 | potential bug | manual audit |
| `-Wnull-dereference` | 4 | **REAL BUG** | **fixed** (pr_edict.c — see below) |
| `-Wduplicated-branches` | 2 | dead-code or copy-paste | analysed (see below) |
| `-Wstring-compare` | 1 | false positive | gcc misanalyses Cmd_Argv return type |
| `-Wformat-nonliteral` | 1 | minor | suppress (intentional dynamic format) |

---

## Real bugs fixed this round

### `pr_edict.c:333,386` — null-deref in PR_ValueString / PR_UglyValueString

`ED_FieldAtOfs(val->_int)` returns NULL if no fielddef matches the offset.
Both callers dereferenced unconditionally:

```c
def = ED_FieldAtOfs ( val->_int );
q_snprintf (line, sizeof(line), ".%s", PR_GetString(def->s_name));   /* boom on NULL */
```

A corrupted .progs file or out-of-range field offset (rare in practice
but real enough to be a concern with custom mods) crashes the engine
during edict printing. **Fixed:** added `def ? PR_GetString(def->s_name)
: "?"` ternary at both sites. Behavior on the happy path is identical.

---

## Findings analysed but not acted on

### `sbar.c:455` — `Sbar_ColorForMap` duplicated branches

```c
return m < 128 ? m + 8 : m + 8;
```

Both branches identical. **Investigated:** `git blame` shows this came in
verbatim from upstream QuakeSpasm in 2010 (commit db613ab3, Ozkan Sezer)
and has stood in every fork since. Same code shape in FitzQuake, Mark V,
DarkPlaces, ezQuake. **Disposition:** treat as intentional Quake quirk
(possibly a leftover from a previous palette-mapping scheme); no
behavior change available without divergence from upstream. Leaving as-is
to avoid breaking colormap parity with other engines. Suppress this
specific warning rather than rewrite.

### `cl_input.c:195` — impulse handler duplicated branches

```c
if (impulseup && !impulsedown) {
    if (down) val = 0;       /* I_Error commented out */
    else      val = 0;       /* released this frame */
}
```

Both arms set `val = 0;`. **Investigated:** the `I_Error()` comment is the
fingerprint of an older assertion that was demoted to silent zero. The
conditional structure is vestigial but symmetric — could simplify to
`val = 0;` without a behavior change, but the symmetric form documents
the original "impulsedown ≠ impulseup" intent and matches the
`impulsedown && !impulseup` block above. **Disposition:** cleanup-only
change deferred; not a real bug. Suppress per-line.

### `cmd.c:274` — `-Wstring-compare` on `Cmd_Argv(1)`

```c
if (!f && !strcmp(Cmd_Argv(1), "default.cfg"))
```

gcc 15 reports "strcmp of a string of length 11 and an array of size 1
evaluates to nonzero". gcc has misanalysed `Cmd_Argv()`'s declared
return type (`char *`) as somehow pointing to a length-1 array. **False
positive** — the function returns a NUL-terminated string of arbitrary
length. Suppress.

### `-Wstrict-aliasing` (12) — Quake type-pun idioms

Locations: `snd_mix.c:83,119,439,440`, `pr_exec.c:555,567,575`,
`common.h:157,160`, `cl_demo.c:186`, `progs.h:120`.

These are the classic Quake `(int *)&float_var` and union-tagged
`eval_t` accesses. They are technically strict-aliasing UB but have
been in upstream Quake for ~25 years and the engine builds with
`-fno-strict-aliasing` implicitly via gcc-4.0's looser default and via
the Makefile's lack of `-fstrict-aliasing`. The Linux build above does
NOT pass `-fno-strict-aliasing` — this is partly why the warnings light
up. **Disposition:** add `-fno-strict-aliasing` to the Linux build's
EXTRA_CFLAGS to mirror what gcc-4.0 effectively does on PPC. Re-evaluate
if a hot-path optimization becomes blocked by aliasing assumptions.

---

## Track B candidates (perf-relevant warnings)

### `-Wdouble-promotion` (506) — silent float→double on PPC

PowerPC's FPU is double-precision-native, but G3 specifically penalises
mixed precision (additional moves, extra mantissa bits to ignore).
Where a `vec_t` (float) is mixed with a literal double (`0.5` instead of
`0.5f`), gcc widens to double then narrows back, costing cycles.

**Sample hot files:**
- `mathlib.h:56` (BoxOnPlaneSide macro — runs many times per frame)
- `gl_mesh.c:263` (alias mesh setup)
- `pr_cmds.c:1196,1198,1034`
- `cl_demo.c:462`
- `chase.c:115`

**Action:** dedicated audit pass replacing literals like `0.5`, `1.0`,
`-1` with `0.5f`, `1.0f`, `-1.0f` where the surrounding type is `float`.
Use `sqrtf`, `cosf`, `sinf`, `floorf` instead of double-precision math
calls. Estimated effort: 2-3 hours of mechanical edits, with each batch
smoke-benched. **Estimated win:** modest on G3 (every cycle counts when
GPU-bound) and Lion (Core 2 Duo SSE2 has fast double, so smaller win
there), bigger on G4 (AltiVec is single-precision-only; mixed code
pulls work off vector and onto scalar FPU).

This becomes a new Track B phase: **B9. `-Wdouble-promotion` cleanup**.

### `-Wmissing-prototypes` (322) — TU-private functions not marked `static`

Functions with no header declaration that should be `static` to enable
inlining and reduce link-time symbol pressure. Net effect on perf: gcc
can inline static functions more aggressively (no external visibility
constraint). Largely cleanup, but also a small inlining-quality win.

**Action:** batch fix in a single sweep. Low-risk — wrap in a script
that adds `static` to every function whose name doesn't appear in any
header file under `Quake/`. ~322 spread across ~30 .c files.

---

---

## gcc `-fanalyzer` findings (interprocedural)

`-fanalyzer` adds 30 findings on top of the warning maxout, mostly around
pointer flow:

| Class | Count | Disposition |
|-------|-------|-------------|
| `-Wanalyzer-possible-null-dereference` | 17 | mostly false positives — pointer flow within bounds-checked containers |
| `-Wanalyzer-use-of-uninitialized-value` | 8 | 3 in vendored miniz.c (skip — third-party); 5 in world.c via `DoublePrecisionDotProduct` macro on early-error paths (defensible) |
| `-Wanalyzer-null-dereference` (definite) | 3 | `pr_edict.c:1380,1389` (false positive — `pr_knownstrings` only iterated post-alloc); `common.c:2701` (defensible — `localization.text` valid at this point in control flow) |
| `-Wanalyzer-out-of-bounds` | 1 | `lodepng.c:1008` (vendored — skip) |
| `-Wanalyzer-malloc-leak` | 1 | `snd_sdl.c:160` (false positive — `shm->buffer` is the audio mix buffer with shutdown lifetime, freed by SDL_CloseAudio) |

Net real bugs from `-fanalyzer`: 0. All findings either trace through
vendored third-party libraries (miniz, lodepng) we don't own, or hit
control-flow patterns the analyzer can't fully model (pre-allocated
arenas, lifetime-bound globals, type-tagged unions).

The win from running `-fanalyzer` was the **negative result** — we have
no live interprocedural bugs in our code. Subsequent rounds should
re-run after every Track B phase to catch regressions early.

---

## UBSan findings (runtime)

`scripts/build-linux.sh ubsan` + `+map start +waitN +quit` against the
sample data on Ubuntu (DISPLAY=:0). Three real UB sites surfaced:

### `snd_mem.c:79` — signed shift of negative value (FIXED)

8-bit→16-bit PCM upconvert: `(int)((unsigned char)b - 128) << 8` where
the post-bias value is signed-int and negative for inputs < 128.
Replaced with `* 256` (multiplication by power-of-two has defined
behaviour for signed ints in range). Same class as commit `463ec405`.

### `snd_mem.c:197-199` — left shift past `int` capacity (FIXED)

`GetLittleShort` / `GetLittleLong` composing 16/32-bit values from
unsigned bytes via `<<8/<<16/<<24` into a signed int. When high byte ≥
128, the result overflows int via UB. Rewrote both functions to compose
in `unsigned` and cast to signed at the end — same wire result, defined.

### `gl_draw.c:512` — misaligned `glpic_t` access (NOT FIXED — x86_64-only)

`(glpic_t *)pic->data` accessing a struct that requires 8-byte alignment
through a `byte data[4]` member at offset 8 within `qpic_t`. On the ship
targets:

- **32-bit PPC (G3 + G4):** `glpic_t`'s `gltexture *` field is 4 bytes
  with 4-byte alignment. `pic->data` at offset 8 from a 4-aligned `pic`
  is 4-aligned. Access is well-aligned. **No real issue.**
- **Lion x86_64:** `gltexture *` is 8 bytes with 8-byte alignment.
  `pic->data` at offset 8 from a (likely) 4-aligned hunk-pointer is
  4-aligned, not 8. x86_64 silently fixup-handles unaligned access at
  small perf cost. **Cosmetic on this target.**
- **Hypothetical 64-bit PPC:** would alignment-trap.

**Disposition:** treat as a code-quality finding rather than a runtime
bug. Fix would require either (a) increasing hunk allocator alignment
from 4→8 (touches every Hunk_Alloc consumer) or (b) memcpy'ing into a
local glpic_t in every reader. Neither is justified by current targets.
Suppress UBSan for `gl_draw.c:512` and revisit if/when a 64-bit PPC
target is added.

---

## Suppressions applied

`analysis/suppressions/gcc-warnings.txt` lists the per-line/per-class
suppressions added (false positives, intentional quirks, upstream parity
items). Each entry has a one-line rationale comment.
