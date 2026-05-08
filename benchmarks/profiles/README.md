# Sample-based profiles

Stack-sample profiles captured via Tiger's `/usr/bin/sample` while a
QuakeSpasm timedemo plays. Each file:

- Records ~20s of execution at 100 Hz sampling rate (≈1850-2000 samples)
- Filename pattern: `sample_<commit>_<target>_<demo>_<res>.txt`
- Captured pattern: launch QS with timedemo, sleep 3s for boot, then
  `sample $PID 20 -file <out>`, kill QS

Use `sample` instead of OpenGL Profiler because the Xcode 2.5-vintage
Profiler ships v3.4(78) but Tiger 10.4.11's system nub is v3.1(33),
and the version mismatch crashes the Profiler at attach time. `sample`
has no GL framework dependency and works reliably on both PowerPC
targets.

The sample format is Apple's classic stack-sample tree — an inverted
call graph where each indent level is a callee, the leading number is
"samples spent in this function or descendants". The bottom of each
file has two summary tables:

- "Total number in stack" — function appeared this many times anywhere
  in the call graph (cumulative)
- "Sort by top of stack" — function was actually executing at sample
  time (self-time, the most useful for finding hot spots)

## Baseline: `sample_99cb89c4_g4_demo3_1024x768.txt`

G4 / Tiger 10.4.11 / Radeon 9000, demo3 1024×768, shipping config
(`r_oldwater 0`, anisotropy 8, Phase 2/3-default-off/4 active).
Captures the round v2 epilogue's −10.6% demo3 640 trade-off in its
1024 sibling.

**Headline finding:** ~50% of brush rendering time is in
`R_UploadLightmaps`, dominated by per-call kernel-IPC overhead
(`mach_msg_trap`), not the data path. Phase 2.x optimised the data
path; what's left is per-call cost. Coalescing dirty rects per frame
into fewer `glTexSubImage2D` calls is the v3 lever for this.

See PPC_PLAN.md §13 for the v3 plan derived from this profile.
