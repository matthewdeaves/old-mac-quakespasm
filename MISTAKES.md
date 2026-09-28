# Mistakes log: things we tried that were bad
Changes that landed (or were attempted) and turned out wrong, so a future round does not re-litigate them. Newest first.
Find one with `grep -n '#NNN' MISTAKES.md` or `grep -n '^## ' MISTAKES.md`; full original text in docs/archive/MISTAKES-full.md.
> Naming (2026-05-09): older entries use `g3`/`g4`/`g4mini`/`lion` = `yosemite`/`quicksilver`/`mini-g4`/`mini-intel`; `sawtooth` (G4 AGP) joined later.

## 2026-09-25 #64 batching download chunks per server tick wedged the download on real hardware
Download throughput was bounded by `sys_ticrate` (one `svcdp_downloaddata` chunk per ~50ms tick), measured on mini-intel server + mini-g4 client. Batching several chunks per tick died with `UDP_Write, sendto: Message too long` once a flush passed a few KB.
`Datagram_SendMessage` only fragments above 64000 bytes, so smaller sends go out as one raw `sendto()`; `SV_SendClientMessages` batches signon buffers only for a local client (`if (!local) break;`).
Shipped instead: single chunk 1024 -> 1400 bytes (one MTU-safe datagram), about 1.3x rather than the hoped ~8x.
Lesson: the buffer size (`MAX_MSGLEN` 64000) is not the safe wire size; check the local-vs-network "one flush, one send" line before assuming a bigger reliable message is free.

## 2026-08-31 imac-2019's DMG-installed launch hung on a live Desktop-folder TCC prompt, not a crash
v1.15.7 `deploy-dmg.sh` + `smoke-dmg.sh` hung with no fps line; the process was alive (S state, near-zero CPU) for 2+ minutes. A "would like to access files in your Desktop folder" dialog needed a human click; allowing it gave 215.8 fps.
Cause: every target installs to `~/Desktop/quake/` (TCC-protected), and each version bump changes the ad-hoc CDHash so macOS re-prompts every release; `smoke-dmg.sh`'s 45s timeout misreports it as FAIL.
Lesson: a genuinely alive, low-CPU process on a machine with a display may be a blocked GUI dialog; check before filing an engine hang. Not fixed (deploy path still targets Desktop).

## 2026-08-28 #37 #38 a modern tool's default silently assumes a modern Mac: check the output, not "it compiled"
Three near-misses, none shipped. (1) g5 slice is `-mmacosx-version-min=10.5`, but dyld picks it on any G5 CPU, so it crashes on g5-panther/g5-tiger/quad-tiger (`___stderrp` missing) - expected, 3 for 3.
(2) create-dmg (#38) makes a GPT image; PowerPC needs Apple Partition Map, so adopting it would have made DMGs unmountable on the oldest machines. Not wired in.
(3) imac-2019 as i386 build host (#37): default SDK is Sequoia's, not 10.4; fixed with explicit `-isysroot`, verified with `otool -l`/`lipo -detailed_info`; `lion`/x86_64 slice left on the Lion minis.
Lesson: deployment-target flags paper over API surface, not partition schemes, ABI startup objects or SDK headers; verify `LC_VERSION_MIN_MACOSX` / packaging output whenever a step moves to newer hardware.

## 2026-08-23 #30 APPLE_client_storage on an async driver corrupted a GPU until power reset
Phase 2.2 client storage was safe on sync PPC drivers but on mini-sl (GeForce 9400, 10.6.8) `R_BuildLightMap` rewrote `lm->data` under queued draws (worker SIGSEGV) and `GL_BuildLightmaps` freed it before the driver dropped it (`glDeleteTextures` hang, `NVDA(OpenGL): Channel exception! Fifo: Parse Error`).
Graceful `/sbin/reboot` hung ~2.5 h with WindowServer wedged in the GPU kernel driver, until a power reset.
Fixed: client storage OFF on non-PowerPC (`-client-storage` forces), `glFinish` before frees, `qsreboot.sh --force` (`/sbin/reboot -q`).
Lesson: zero-copy is a lifetime contract; gate pointer-handoff paths to the platforms they were proven on, and give recovery tooling a forceful tier.

## 2026-08-23 #28 benching an archived cvar silently re-configures the machine
An A/B pinned `+r_decals 0` on yosemite and mini-g4; `Host_WriteConfiguration` (`host.c:386`) archived it to `id1/config.cfg` on clean exit, leaving decals OFF for hours (no bundle cfg sets `r_decals`; 13 files set `r_shadows`). `-noarchautoexec` does not stop the write.
Lesson: a bench CONFIGURES the machine; after benching a `CVAR_ARCHIVE` cvar check `id1/config.cfg`. Make instrumentation-only cvars `CVAR_NONE` (as `r_decal_stats`).
Tracked as #28.

## 2026-08-23 a failed log fetch reported the PREVIOUS run's fps as a result
`bench.sh` did `scp ... || true` then grepped a fixed path, so a failed copy recorded the stale file's number: a decals-OFF leg logged 34.6 fps that was the decals-ON leg's run 3 (proved by mtime and `gated=0`). Both legs also shared one log name.
Lesson: the contamination is directional (stale number comes from the other leg), biasing toward "no difference".
Fixed in `f3c8a490`: delete first, treat a failed fetch as a failed run and record NA, put cvars in the log name; it caught a real 3/3 G3 failure within the hour.

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
