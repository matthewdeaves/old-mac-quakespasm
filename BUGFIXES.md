# Bug-fix log

One short entry per real bug fixed: what it was, what the fix was. Newest
first. Fuller accounts live in MISTAKES.md, the ADRs, or the issue named.

- **2026-08-28 — bench/smoke/profile scripts deleted qconsole.log as a "clean
  slate" before every run, destroying the previous run's evidence right when
  something crashed (cross-port finding, halflife ADR 0018).** The engine's
  own `LOG_Init` (`Quake/console.c:1332`) opens the log with `O_TRUNC`, so it
  already truncates on its own next launch -- the `rm -f` bought nothing.
  Fixed: rotate to `qconsole.prev.log` instead of deleting, across
  `bench.sh`, `bench-arm64-local.sh`, `profile-pass.sh`,
  `selfhost-download-test.sh`, `smoke-dmg.sh`. Verified live on mini-intel2.

- **2026-08-28 — quarantined ad-hoc-signed launches killed by Gatekeeper ~18s
  in, no crash report (#35).** `AppleSystemPolicy` terminates an ad-hoc-signed
  (not Developer-ID) app under `com.apple.quarantine` a few seconds into an
  apparently normal launch (window opens, no error dialog); `log show` caught
  it: `ASP: Security policy would not allow process`. A separate, secondary
  bug rode along: App Translocation redirects a quarantined, Finder-copied
  app to an isolated read-only container, breaking its sibling `id1/` lookup
  (`AppController.m -launchCore` derives its chdir from `gArgv[0]`). Fix:
  `AppController.m` recovers the real pre-translocation path via
  `SecTranslocateCreateOriginalPathForURL` (dlsym'd, no-ops pre-10.12 and on
  the PPC/Lion/i386 SDKs that can't declare it); `deploy.sh`/`deploy-dmg.sh`
  now clear quarantine + re-register LaunchServices on the target after
  install via the shared `clear-launch-quarantine.sh` primitive
  (old-mac-build-host#34); `deploy.sh` also gained the ad-hoc codesign step
  it never had (make-dmg.sh had it, deploy.sh didn't -- an unsigned arm64
  slice hard-crashes regardless of quarantine) and switched `SDL.framework`'s
  copy from `cp -r` to `cp -a` (`-r` follows symlinks it meets while
  recursing, flattening the framework -- one of three stacked causes of
  MISTAKES.md's 2026-08-23 mini-sl "damaged or incomplete" entry, left
  unfixed on the deploy.sh side until now). NOT fixed and not scriptable
  without paid notarization: a genuine third-party browser download still
  gets quarantined regardless of what packaging clears (Finder ties the flag
  to the download/mount event, not the file object) -- the DMG readme's
  right-click-to-Open is the remaining one-click Apple-sanctioned path.
  `MacOSX/AppController.m`, `scripts/deploy.sh`, `scripts/deploy-dmg.sh`,
  `scripts/make-dmg.sh`, `scripts/smoke-dmg.sh`,
  `scripts/clear-launch-quarantine.sh`.

- **2026-08-25 — `results.csv` recorded requested mode rather than rendered mode (#34).**
  Machines with `vid_desktopfullscreen 1` (e.g. `imac-g5`, `mini-intel2`) capture
  the desktop mode (e.g. 1440x900, 1280x1024), ignoring requested `+vid_width` /
  `+vid_height`, so nominal 640x480 / 1024x768 cells actually rendered at desktop
  res. Fix: parse initialized mode from `qconsole.log`, record `rendered_res` in
  `results.csv` (11-column schema, preserving both requested and rendered resolution),
  and backfill historical rows. `scripts/bench.sh`, `scripts/bench-arm64-local.sh`,
  `scripts/parallel-bench.sh`, `scripts/parse_qconsole.py`, `Quake/cl_demo.c`.

- **2026-08-23 — GeForce 9400 GPU corruption from client-storage lightmaps
  (#30).** `APPLE_client_storage` handed the driver long-lived pointers into
  `lm->data`; in-place rewrites raced queued draws (worker SIGSEGV) and the
  free-after-map-change raced deferred deletes (kernel FIFO wedge, display
  dead until power reset). Fix: client storage off by default on non-PowerPC
  (`-client-storage` to force), `glFinish` before the lightmap frees where it
  stays on, MTGL gated off on GeForce 9400 (`-forcemtgl` to force), batched
  `glDeleteTextures` on map teardown. `gl_vidsdl.c`, `r_brush.c`,
  `gl_texmgr.c`.

- **2026-08-23 — `qsreboot.sh` graceful reboot hangs on a GPU-wedged
  machine.** `/sbin/reboot` waits to kill every process; one stuck unkillably
  in a GPU kernel fault blocks shutdown forever. Fix: `--force` tier =
  `/sbin/reboot -q`. `scripts/host-bin/qsreboot.sh`.

- **2026-08-23 — Finder launch "damaged or incomplete" on mini-sl.** Three
  stacked causes: stale `_CodeSignature` from an old signed install that
  `deploy.sh` neither creates nor removes; `SDL.framework` symlinks flattened
  to real files by `deploy.sh`'s `cp -r`; stale LaunchServices registration
  (`launch-disabled` flag, empty executable field). Fixed on the machine by
  deleting the seal, re-shipping the framework with `ditto`, and
  `lsregister -f`. deploy.sh-side prevention still open under #30.

- **2026-08-23 — bench runs permanently re-configured machines via archived
  cvars (#28).** Any `CVAR_ARCHIVE` cvar pinned with `EXTRA_CVARS` was written
  into `id1/config.cfg` on exit and persisted for real play. Fix: `bench.sh`
  snapshots `config.cfg` before the run and restores it in the EXIT trap.

- **2026-08-23 — semicolons in `//` comments in bundle cfgs parsed as
  commands (#31).** `Cbuf_Execute` splits on `;` before comment handling, so
  comment text after a semicolon became console spam. Fixed across all 14
  bundle cfgs; command-syntax examples rewritten one-per-line.
