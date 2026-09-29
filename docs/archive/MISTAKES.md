# Mistakes archive

Original entries moved from active history; wording is retained verbatim.
Search by ticket or heading, then read that entry.

## 2026-08-20 "this port uses SDL2" was wrong; every shipped slice is SDL 1.2
Commit `fd507839` claimed the port was on SDL2; `Makefile.darwin:13` sets `USE_SDL2=0` and `otool -L build/quakespasm-fat` shows SDL 12.4.0 (1.2.15). The vendored fat `MacOSX/SDL2.framework` and an arm64 probe linking `USE_SDL2=1` caused the error.
Lesson: check what the artifact links, not what the source tree contains. ADR 0003.

## Older than 60 days
Full text of each is in docs/archive/MISTAKES-full.md.
- 2026-07-25 `-faltivec` silently un-stamps the ppc7400 cpusubtype; assert it, ADR 0002 (see docs/archive/MISTAKES-full.md)
- 2026-05-31 the DMG pipeline could ship a silently-corrupt binary; `hdiutil verify` is not a content check, ADR 0005 (see docs/archive/MISTAKES-full.md)
- 2026-05-31 G3 Rage 128: a live in-game resolution switch crashes the engine; overlay without `vid_restart`, ADR 0006, ADR 0007 (see docs/archive/MISTAKES-full.md)
- 2026-05-31 iMac G5: GLSL/VBO on the ATI Radeon 9600 hard-hangs the whole OS; gate on renderer string, ADR 0007 (see docs/archive/MISTAKES-full.md)
- 2026-05-29 `vid_bpp 32` hard-wedged mini-g4 (Radeon 9200) at boot video init, ADR 0006, ADR 0007 (see docs/archive/MISTAKES-full.md)
- 2026-05-10 rounds v9 and v10: a "code regression" that was an `r_lavaalpha 0.6` autoexec change, flat-array efrags, ADR 0009 (see docs/archive/MISTAKES-full.md)
- 2026-05-09 round v6: stale-binary CSV pollution read as a 30% regression (really -5.8%), ADR 0009 (see docs/archive/MISTAKES-full.md)
- 2026-05-09 round v5 B5: scalar dlight cast hoist revert was wrong, same-session A/B showed +2.9% on mini-g4, ADR 0009, ADR 0008 (see docs/archive/MISTAKES-full.md)
- 2026-05-09 round v5 B3: Lion PGO and LTO expected +5-12%, delivered nothing (Apple clang 1.7), ADR 0005 (see docs/archive/MISTAKES-full.md)
- 2026-05-08 Pass A item 5: BGRA static-texture upload crashed all four targets in `COM_FindFile`, reverted; commits `b186ae44`, `cea45842` (see docs/archive/MISTAKES-full.md)
- undated Phase 1.1c multitexture client-array conversion (`c00a07a7` era) cost G4 -3 to -4%; `gl_surfbatch`, `gl_groupdraw`, Phase 3.3 `fdd1b09a`, `docs/KNOBS.md` (see docs/archive/MISTAKES-full.md)
