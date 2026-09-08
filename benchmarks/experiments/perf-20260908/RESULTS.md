# Performance batch, 2026-09-08

Release: v1.15.14, code commit 178fdc70819f40a98a8e52d5fa78c7db3ab1b5d6.
Final fat source stamp: 240ccf530a06 (all six slices matched this source).
The final deployed bundle is ad-hoc signed, so its on-host executable hash is
recorded with the host validation below rather than compared to the unsigned
build artifact. The benchmark rows tagged 178fdc70 are the release build.
The tracked-source patch and build logs are preserved here. Subsequent documentation
edits do not describe a rebuild of the candidate. Experimental cvars default to zero.

Each cell uses three launches of demo3, reporting the mean of runs 2 and 3.
Both sides use the same binary and graphics settings, with perf-batch-off.cfg
or perf-batch-on.cfg. All runs use -nosound, so they do not measure audio reuse.

| Machine / OS | Actual pixels | Off FPS | On FPS | Interpretation |
|---|---|---:|---:|---|
| G3 Tiger | 800x600 | 27.90 | 27.85 | No measured gain |
| G4 Quicksilver Tiger | 1680x1050 | 44.50 | 45.10 | Small gain, +1.35%; earlier test1 also improved |
| Intel iMac | 2560x1440 | 181.85 | 181.95 | No meaningful gain |
| Local Apple Silicon | 2560x1080 | 257.40 | 260.15 | +1.07%; needs repeat before promotion |

The final default-on G5 Panther release smoke is recorded in
`benchmarks/results.csv`: 65.6/65.7/65.7 FPS, median 65.70, actual 1680x1050.
The deployed host reported Mac OS X 10.3.9 and PowerMac7,3; its signed
executable MD5 was `79d289d9062a1646a5911959e169a757`.

The earlier ON rows for G5 Panther and iMac G5 were completed in the same
session but their CSV append was interrupted by a benchmark-script edit. Their
raw logs are retained and their values are 65.70 and 87.45 FPS respectively;
the release smoke above is the canonical default-on row for the committed
release.

## Visual and correctness checks

The implementation harness passes under ASan/UBSan. It checks lightmap invalidation,
bit-identical filtered audio, conservative particle bounds and shadow GL state lifecycle.
Paused demo1/demo2/demo3 captures match between off and on on G3 Tiger,
G4 Quicksilver, Intel iMac and PowerMac7,3 Panther after excluding the top 60
pixels containing changing console notifications. The Intel captures used test1;
the others used test2. No claim is made about unseen scenes or excluded pixels.
Screenshots are kept locally under benchmarks/screenshots/perf-20260908.

Panther 10.3.9 rendering is now verified on the 2.7 GHz PowerMac7,3 with
ATI Radeon 9600 OpenGL Engine. The initial attempt lacked accessible game data;
after staging existing packs and restoring SSH availability, all captures completed.
Alternate boot partitions remain untested in this session.
