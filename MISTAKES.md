# Mistakes log — things we tried that were bad

Append-only record of changes that landed in tree (or were attempted)
and turned out to be wrong, harmful, or otherwise misjudged. Each
entry exists so future rounds don't re-litigate the same idea on
incomplete information.

Format: date, what we tried, what went wrong, what the fix was, what
we learned. Newest at the top.

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
