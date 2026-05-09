# Static analysis & QA report index

This directory holds the output and triage notes for every analysis tool
wired into the QuakeSpasm port. Each tool's full output goes under
`raw/<tool>/` (gitignored — too bulky for git); the summarised log and
triage notes are committed.

## Conventions

- `<tool>.log` — stdout/stderr capture from the most recent sweep. Truncated
  to ≤ 5000 lines so it stays readable in git.
- `<tool>-triage.md` — human notes: which findings are real bugs, which
  are false positives, which were filed as TODO Track B candidates.
- `suppressions/<tool>.txt` — per-tool suppression lists. Every entry has
  a one-line rationale comment.
- `perf-candidates.md` — opt-info / vectoriser-miss output triaged into
  candidate optimisations for the next round.

## Tool inventory (Round v5 wrap, 2026-05-09)

| Tool | Status | Last run | Findings | Verdict |
|------|--------|----------|----------|---------|
| cppcheck | run | 2026-05-09 | ~25 path-warnings | All FPs: cppcheck doesn't credit Sys_Error noreturn through macro layer; OOB-bound checks are upstream qpic_t flexible-array idiom |
| gcc -fanalyzer | run | 2026-05-09 | (in fanalyzer.log) | No new findings vs Round v5 A2 (already triaged) |
| shellcheck | run | 2026-05-09 | 41 lines / ~10 issues | Cosmetic SC2086/SC2029 in scripts; not blocking |
| ASan (gcc) | wired | 2026-05-08 | clean | Demo run completed, no leaks/OOB |
| UBSan (gcc) | wired | 2026-05-08 | 5 fixed | All landed in 463ec405 + d564b16a |
| Compiler warnings (Linux) | run | 2026-05-09 | 1595 lines | Mostly Wfloat-equal (491) + Wdouble-promotion (490) — all expected for the precision-critical hot path. 2 Wduplicated-branches (cl_input.c:195 intentional placeholder; sbar.c:455 upstream Sbar_ColorForMap quirk) |
| scan-build (clang SA) | run | 2026-05-09 | 113 lines / 6 paths | All scan-build noreturn-blind FPs (Sys_Error path-impossible). Already-fixed gl_texmgr.c div-by-zero shows but is gated by 1104-1105 early return. |
| clang-tidy | run | 2026-05-09 (round v6 suppression) | 6326 lines / 446 warnings | Down from 70K lines / 16K warnings after `.clang-tidy` suppression sweep. Suppressed: bugprone-narrowing-conversions (6090, Quake int↔float idiom), misc-include-cleaner (5152, header graph), readability-identifier-length (2215, single-letter loops), readability-uppercase-literal-suffix (747), readability-math-missing-parentheses (456), clang-analyzer-security.insecureAPI.DeprecatedOrUnsafeBufferHandling (239), readability-function-cognitive-complexity (129), bugprone-easily-swappable-parameters (128), and 8 more style/structural checks. Single source of truth in `.clang-tidy` (cmdline `--checks=` was clobbering it pre-fix). Remaining 446 warnings are real-bug-prone categories — most concentrated in vendored libs (lodepng.c, miniz.c). Top kept categories: bugprone-implicit-widening-of-multiplication (104), bugprone-macro-parentheses (53), bugprone-assignment-in-if-condition (49), clang-analyzer-deadcode.DeadStores (19), clang-analyzer-security.insecureAPI.strcpy (16), clang-analyzer-core.NullDereference (3, all in vendored miniz/lodepng). |
| flawfinder | broken | 2026-05-09 | UTF-8 decode error in in_sdl.c | Non-UTF8 byte in author comment block; cosmetic, would re-run with PYTHONUTF8=0 if we cared |
| sparse | run | 2026-05-09 | 13925 lines | All noise: 4200 "mixing decl + code" (intentional C99), 1314 "unknown attribute __access__" (sparse < gcc), rest in glibc headers |
| iwyu | skipped | 2026-05-09 | — | Needs `bear` (not installed) for compile_commands.json |
| Infer | not packaged in apt | — | — | Release tarball; deferred |

**Headline: no new actionable bugs surfaced this run.** Round v5 A2 +
A4 sweeps caught the meaningful UB and uninit-read class issues.
Remaining warnings are upstream Quake codebase idioms (qpic_t flexible
array, Sbar_ColorForMap, johnfitz comment markers), scan-build's
noreturn-blindness, or modern compilers' "memset is unsafe" noise.

## How to run

```
scripts/analyze-all.sh           # full battery, results land here
scripts/build-linux.sh asan      # ASan-instrumented binary → build/quakespasm-linux-asan
scripts/build-linux.sh ubsan     # UBSan-instrumented binary
scripts/build-linux.sh analyze   # gcc -fanalyzer (warnings only)
```

Each tool also has a single-tool wrapper for fast iteration:
`scripts/analyze-cppcheck.sh`, `scripts/analyze-fanalyzer.sh`, etc.
