# Round v5 closeout — 2026-05-09

Round v5 closed. The "morning checklist" version of this file lived
through 2026-05-08/09 overnight; the rolled-up state is now in
`PPC_PLAN.md §15`. This file is the at-a-glance summary.

## Final headline numbers (Round v5 wrap pass 2, commit `acdf433e`)

| Machine | demo1 1024 | demo3 1024 | demo3 640 |
|---------|---:|---:|---:|
| yosemite (G3 B&W / R128) | 24.20 | **20.25** | 37.30 |
| sawtooth (G4 AGP / GeForce2 MX) | 57.95 | 47.75 | 58.90 |
| quicksilver (G4 / Radeon 9000) | 110.85 | 85.75 | 101.85 |
| mini-g4 (G4 mini / Radeon 9200) | 76.05 | 67.00 | 116.60 |
| mini-intel (Lion / GMA 950) | 96.40 | 44.85 | 207.40 |

All targets above their playability floor. Sawtooth (newest addition,
fixed-function G4) clears 50+ fps on demo1/demo2, 47+ on demo3.

## Visual stack shipping per target

| Target | Stack |
|--------|-------|
| yosemite | classic warp, gl_subdivide_size 256, r_shadows 1, r_dynamic_distance 768, r_lavaalpha/r_telealpha/r_slimealpha/r_wateralpha 0.6, gl_zfix |
| sawtooth | classic warp, trilinear, r_dynamic_distance 768, r_lavaalpha/r_telealpha/r_slimealpha/r_wateralpha 0.6, gl_zfix |
| quicksilver | shader water, aniso 16, trilinear, r_shadows 1, r_shadow_distance 512, r_lavaalpha/r_telealpha/r_slimealpha/r_wateralpha 0.6, gl_zfix |
| mini-g4 | (same as quicksilver — Radeon 9200 inherits the Quicksilver tuning) |
| mini-intel | classic warp (no GLSL on GMA 950), aniso 16, trilinear, r_shadows 1, r_shadow_distance 512, r_lavaalpha/r_telealpha/r_slimealpha/r_wateralpha 0.6, gl_zfix |

Full toggleable knobs inventory in `CLAUDE.md` under "Toggleable
knobs".

## Round v6 starter list (filed)

- **B6 AngleVectors per-entity caching** — bigger refactor; needs
  the 5-machine A/B to separate the cache-hit win from existing
  lerpmove caching.
- **gl_sky.c:562 inner loop** — vec3 inner loop in `Sky_ClipPoly`,
  not currently hot enough alone but if other clip-poly paths get
  the same treatment it could cumulate.
- **iwyu**: needs `apt install bear` for compile_commands.json.
- **Static analyser noise reduction** —
  `clang-analyzer-security.insecureAPI.DeprecatedOrUnsafeBufferHandling`
  fires on every memset/memcpy/sprintf. A focused suppression sweep
  shrinks the clang-tidy log from 70K lines to readable.
- **Sawtooth-specific tuning** — sawtooth ships with the most
  conservative config; if a future round wants to push visuals
  further on GeForce2 MX, candidates: r_shadows 1 (carefully — could
  break the 60-fps floor), r_shadow_distance 256 (ultra-aggressive)
  to compensate.

## Tooling state

All five static analysers (cppcheck, scan-build, clang-tidy, sparse,
flawfinder) plus gcc -fanalyzer + ASan + UBSan ran on the closed-out
tree. Snapshot: `analysis/INDEX.md` (Round v5 wrap row, 2026-05-09).
No new actionable findings.
