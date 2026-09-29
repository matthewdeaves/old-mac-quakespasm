# Bugfixes

Search by ticket or date; entries are newest first.
Archive: `docs/archive/BUGFIXES.md`.

## 2026-09-13 #47 deploy-dmg.sh reported failure on every genuinely fresh install
The upgrade-with-backup remote script ended with `[ -n "$BACKUP" ] && echo "rollback copy kept..."` as its last statement.
Under `set -e` a fresh install (empty `$BACKUP`) makes that test fail, so the whole script exited 1 though the install was fine.
Caught live on g5-panther's first install (files present, id1 preserved, exit 1 anyway).
Fix: `|| true` on that line. Re-ran on g5-panther, exit 0.

## 2026-09-03 #43 make-dmg.sh staged and shipped every release over the slow workstation link
The .app bundle assembled on the workstation (only host with a modern `lipo`), then rsynced to DMG_HOST over its slow link (same shape that hung in old-mac-build-host#64).
Fix: `DMG_STAGE_HOST` defaults to imac-2019 (Xcode/lipo, same fleet LAN as every DMG_HOST); only the fat binary and finished .dmg cross the slow link, md5-checked. Falls back to local staging if imac-2019 is busy.
Needed fleet-SSH-trust closed first (imac-2019 had no ssh config for mini-g4/quicksilver/sawtooth); old-mac-build-host fixed that live.
Verified end-to-end twice, DMG_HOST mini-g4, content byte-for-byte on both hops.

## 2026-09-03 Fix Launch Problems.command silently no-op'd on macOS that never had the bug
App Translocation (the "couldn't load gfx.wad, Basedir is .../AppTranslocation/..." failure) arrived in 10.12; Panther to 10.11 predate it, so the script did nothing there.
Fix: reads `sw_vers -productVersion`, exits with "you don't need this" below 10.12 before touching anything; unreadable version does not skip (fails safe).
Also corrected README.md: quarantine began in Leopard 10.5 and Gatekeeper in Lion 10.7.3, not "predate entirely". Shipped in v1.15.12; both branches tested.
imac-2019 smoke hit its known Desktop-folder TCC dialog (MISTAKES.md, 2026-08-31): same cause, one manual click needed per binary-signature change.

## 2026-09-03 #42 sv_accelerate was invisible to infra's webadmin, unlike its three movement-cvar siblings
`sv_gravity`/`sv_friction`/`sv_maxspeed` carry `CVAR_NOTIFY|CVAR_SERVERINFO` plus a `Host_Callback_Notify` registration (as `deathmatch`/`coop`, issue #13); `sv_accelerate` in `Quake/sv_user.c` had neither.
Fixed both pieces to match. Verified A/B on a real dedicated server built in the project container (ADR 0011) with a `CCREQ_RULE_INFO` walker.
Before: `sv_accelerate` absent from the nine-key rules reply; after: `sv_accelerate=10`. Shipped in server-v1.19.

## 2026-09-02 arm64 launched windowed, not fullscreen, on real Apple Silicon (MacBook Air, M5)
`autoexec-arm64.cfg` hardcoded `vid_width 1920 vid_height 1080 vid_fullscreen 1`; that mode is not SDL2-enumerable on the Retina panel, so `VID_Restart` aborted and the window stayed small (reproduced 3x).
Fix: `vid_desktopfullscreen 1`, as `autoexec-imac-2019.cfg` and `autoexec-mini-intel.cfg` already use; explicit width/height dropped (SDL2 overrides them: asked 1920x1080, got 1710x1073).
Measured three timedemo runs: 82.6 / 104.9 / 118.5 fps. Not run through `scripts/bench.sh` (no local-workstation target yet).

## 2026-09-02 Reworked the DMG installer: fix-in-place instead of copy to ~/Applications
User directive: run from the same location as the fat binary, like alephone. `Fix-and-Install.command` (v1.15.8/9) replaced by `Fix Launch Problems.command`, which only clears quarantine and re-registers LaunchServices in its own folder.
DMG now ships one self-contained "Quakespasm" folder (`Quakespasm.app`, `quakespasm.pak`, empty `id1/`, the fix script); quarantine logic inlined, no hidden `.fix-support` sidecar (Finder hides dotfiles; alephone hit that live on imac-2019).
Updated `make-dmg.sh`, `scripts/deploy-dmg.sh`, README.md. Kept the id1/pak0.pak-missing warning.

## 2026-09-02 Fix-and-Install.command now warns if id1/pak0.pak is missing
Two users hit "couldn't load gfx.wad" after installing without their own Quake data (flagged by infra, retro-server-infra-43, who verified the served pak0/pak1 valid).
The script now checks `$DEST/id1/pak0.pak` (and case variants) before "Done" and prints where to put it. Shell/text change only, engine untouched.

## 2026-09-02 v1.15.8 formally deploy+smoke-tested on imac-2019 (standing rule for every release)
`deploy-dmg.sh imac-2019 v1.15.8` + `smoke-dmg.sh imac-2019 demo1`: PASS, 216.8 fps, 2560x1440, world rendered to completion.
Standard fleet tooling path on the exact machine that broke, in addition to the ad-hoc Fix-and-Install.command check the same day.

## 2026-09-02 DMG launch failed on imac-2019: App Translocation, not a crash
Safari's quarantine flag survives a plain copy to `~/Desktop/quake/`; macOS then runs the app from a sandboxed copy ("couldn't load gfx.wad, Basedir is: /private/var/.../AppTranslocation/...").
Confirmed on-machine: `xattr -l` showed `com.apple.quarantine`; `scripts/clear-launch-quarantine.sh` cleared it and `ps` showed the real path.
Shipped `scripts/bundle/Fix-and-Install.command` on every DMG (right-click-Open once; installs to `~/Applications/Quakespasm`, clears quarantine); wired into `make-dmg.sh`, README.md and README.txt.

## 2026-08-28 #37 i386 slice moved to imac-2019 (user directive, speed)
imac-2019's default clang SDK is Sequoia's, far newer than the 10.4 target, unlike the Lion minis; pinned `-isysroot` at its staged `MacOSX10.4u.sdk` when `LION=imac-2019` (`SDK=""` on the Lion minis).
Verified via `otool -l`/`lipo -detailed_info`: `i386`, `LC_VERSION_MIN_MACOSX` 10.4, real source linked clean.
`build-fat.sh` claims imac-2019 for this sub-build, falls back to the main build host; the `lion`/x86_64 slice deliberately not moved (no portable SDK).
`scripts/build.sh`, `scripts/build-fat.sh`, ADR 0005.

## 2026-08-28 qsreboot-setup.sh printed the wrong host name in its own "test this" suggestion
`$(hostname -s)` is the target Mac's own name, not the orchestration host's ssh alias; it printed a garbled name on quad-tiger.
Fixed: generic placeholder instead of a guess. `scripts/host-bin/qsreboot-setup.sh`.

## 2026-08-28 bench/smoke/profile scripts deleted qconsole.log before every run (halflife ADR 0018)
Cross-port finding: the engine's `LOG_Init` (`Quake/console.c:1332`) already truncates with `O_TRUNC`, so the `rm -f` gained nothing and destroyed evidence right when something crashed.
Fixed: rotate to `qconsole.prev.log` in `bench.sh`, `bench-arm64-local.sh`, `profile-pass.sh`, `selfhost-download-test.sh`, `smoke-dmg.sh`. Verified live on mini-intel2.

## 2026-08-28 #35 quarantined ad-hoc-signed launches killed by Gatekeeper ~18s in, no crash report
`AppleSystemPolicy` kills ad-hoc-signed quarantined apps (`log show`: "Security policy would not allow process"); App Translocation also broke the sibling `id1/` lookup (`AppController.m -launchCore` chdir from `gArgv[0]`).
Fix: `AppController.m` recovers the real path via dlsym'd `SecTranslocateCreateOriginalPathForURL`; `deploy.sh`/`deploy-dmg.sh` clear quarantine + re-register LaunchServices via shared `clear-launch-quarantine.sh` (old-mac-build-host#34).
`deploy.sh` also gained the ad-hoc codesign step and `cp -a` for `SDL.framework` (`cp -r` flattened symlinks; one cause of MISTAKES.md 2026-08-23 mini-sl entry).
Not fixable without notarization: a real browser download is still quarantined; the DMG readme's right-click-Open remains the path.
Files: `MacOSX/AppController.m`, `scripts/deploy.sh`, `deploy-dmg.sh`, `make-dmg.sh`, `smoke-dmg.sh`, `clear-launch-quarantine.sh`.

## 2026-08-25 #34 results.csv recorded requested mode rather than rendered mode
Machines with `vid_desktopfullscreen 1` (`imac-g5`, `mini-intel2`) render at desktop res (1440x900, 1280x1024), ignoring `+vid_width`/`+vid_height`, so nominal 640x480 / 1024x768 cells were wrong.
Fix: parse the initialized mode from `qconsole.log`, add `rendered_res` (11-column schema), backfill historical rows.
Files: `scripts/bench.sh`, `bench-arm64-local.sh`, `parallel-bench.sh`, `parse_qconsole.py`, `Quake/cl_demo.c`.

## 2026-08-23 #30 GeForce 9400 GPU corruption from client-storage lightmaps
`APPLE_client_storage` kept driver pointers into `lm->data`: in-place rewrites raced queued draws (worker SIGSEGV), free-after-map-change raced deferred deletes (kernel FIFO wedge, display dead until power reset).
Fix: client storage off by default on non-PowerPC (`-client-storage` forces), `glFinish` before lightmap frees where on, MTGL gated off on GeForce 9400 (`-forcemtgl`), batched `glDeleteTextures` on map teardown.
Files: `gl_vidsdl.c`, `r_brush.c`, `gl_texmgr.c`.

## 2026-08-23 qsreboot.sh graceful reboot hangs on a GPU-wedged machine
`/sbin/reboot` waits to kill every process; one stuck unkillably in a GPU kernel fault blocks shutdown forever.
Fix: `--force` tier = `/sbin/reboot -q`. `scripts/host-bin/qsreboot.sh`.

## 2026-08-23 Finder launch "damaged or incomplete" on mini-sl
Three stacked causes: stale `_CodeSignature` from an old signed install, `SDL.framework` symlinks flattened by `deploy.sh`'s `cp -r`, stale LaunchServices registration (`launch-disabled`, empty executable field).
Fixed on the machine: delete the seal, re-ship the framework with `ditto`, `lsregister -f`. deploy.sh-side prevention was still open under #30 (later done, see 2026-08-28 #35).

## 2026-08-23 #28 bench runs permanently re-configured machines via archived cvars
Any `CVAR_ARCHIVE` cvar pinned with `EXTRA_CVARS` was written into `id1/config.cfg` on exit and persisted into real play.
Fix: `bench.sh` snapshots `config.cfg` before the run and restores it in the EXIT trap.

## 2026-08-23 #31 semicolons in // comments in bundle cfgs parsed as commands
`Cbuf_Execute` splits on `;` before comment handling, so comment text after a semicolon became console spam.
Fixed across all 14 bundle cfgs; command-syntax examples rewritten one-per-line.
