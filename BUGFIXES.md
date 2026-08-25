# Bug-fix log

One short entry per real bug fixed: what it was, what the fix was. Newest
first. Fuller accounts live in MISTAKES.md, the ADRs, or the issue named.

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
