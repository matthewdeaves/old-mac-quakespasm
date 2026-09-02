# Bug-fix log

One short entry per real bug fixed: what it was, what the fix was. Newest
first. Fuller accounts live in MISTAKES.md, the ADRs, or the issue named.

- **2026-09-02 — Fix-and-Install.command now warns if id1/pak0.pak is
  missing.** Two real users hit "couldn't load gfx.wad" the same night after
  running the installer without their own Quake data yet, with no way to
  tell which of several plausible folders the engine actually wanted
  (flagged by infra, retro-server-infra-43, who ruled out the served game
  data — verified valid pak0.pak/pak1.pak — before pointing at the
  installer's silence). The script now checks `$DEST/id1/pak0.pak` (and
  common case variants) right before the final "Done" message and, if
  missing, prints exactly where to put it. Pure shell/text change, engine
  binary untouched.

- **2026-09-02 — v1.15.8 formally deploy+smoke-tested on imac-2019 (standing
  rule: every release must be, before it counts as live).** `deploy-dmg.sh
  imac-2019 v1.15.8` + `smoke-dmg.sh imac-2019 demo1`: PASS, 216.8 fps,
  2560x1440, world rendered to completion. In addition to the ad-hoc
  Fix-and-Install.command verification done earlier the same day (see next
  entry) — this is the standard fleet tooling path, on the exact machine
  that broke.

- **2026-09-02 — DMG launch failed on imac-2019: App Translocation, not a
  crash.** User downloaded the release DMG via Safari, copied
  `Quakespasm.app` + `quakespasm.pak` + `id1/` to `~/Desktop/quake/` by hand,
  double-clicked, got "W_LoadWadFile: couldn't load gfx.wad, Basedir is:
  /private/var/.../AppTranslocation/.../d". The quarantine flag Safari
  stamps on download survives a plain file copy (it does not require a
  fresh browser download each time), and macOS runs a quarantined app from a
  random sandboxed copy instead of its real folder, so it can't see `id1/`
  sitting next to it. Confirmed on-machine: `xattr -l` showed
  `com.apple.quarantine` on the copied `.app`; running the existing
  `scripts/clear-launch-quarantine.sh` against the folder cleared it, and
  the app then launched from its real path (verified via `ps` showing the
  real `~/Desktop/quake/...` path, not an AppTranslocation one). Shipped the
  actual fix so a person doesn't have to know any of this: a new
  `scripts/bundle/Fix-and-Install.command`, included on every DMG from this
  release on, that a user right-click-Opens once -- it installs to
  `~/Applications/Quakespasm` and clears quarantine for them. Wired into
  `make-dmg.sh`; README.md and the in-DMG README.txt both lead with it now.
- **2026-08-28 — i386 slice moved to imac-2019 (user directive, speed).**
  Not a straight host swap: unlike the Lion minis (where "no isysroot"
  naturally resolves to a compatible OS since the compiler runs ON a
  Lion-class machine), imac-2019's default clang SDK is Sequoia's, a dozen
  releases newer than the 10.4 deployment target. Pinned an explicit
  `-isysroot` at the `MacOSX10.4u.sdk` already staged there (for #37's PPC
  work) when `LION=imac-2019`; unchanged (`SDK=""`) on the Lion minis.
  Verified via `otool -l`/`lipo -detailed_info`: correct `i386` architecture,
  correct `LC_VERSION_MIN_MACOSX` 10.4, real quakespasm source (not a toy
  test) built and linked clean. `build-fat.sh` claims imac-2019 for this one
  sub-build, falls back to the main build host if it's unavailable. The
  sibling `lion`/x86_64 slice was deliberately NOT moved -- no portable SDK
  exists to pin it against elsewhere. `scripts/build.sh`, `scripts/build-fat.sh`,
  ADR 0005.

- **2026-08-28 — `qsreboot-setup.sh` printed the wrong host name in its own
  "test this" suggestion.** `$(hostname -s)` is the target Mac's own
  OS-reported name, not the ssh alias the orchestration host uses to reach
  it -- that mapping only exists in the orchestration host's own
  `~/.ssh/config` and isn't knowable from the target side. Printed a garbled
  name on quad-tiger. Fixed: generic placeholder instead of a guess that can
  be wrong. `scripts/host-bin/qsreboot-setup.sh`.

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
