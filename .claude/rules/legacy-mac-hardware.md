---
paths:
  - "scripts/**/*.sh"
  - "MacOSX/**"
---

Full text and reasons: `docs/legacy-mac-hardware.md` (`grep -n '^## '`, read by section).

- Never trust "done" or exit 0. After a build check fresh mtimes on every `build/quakespasm-*` slice and `scripts/macho-archs.sh build/quakespasm-fat` showing six slices; read `deploy.sh`'s md5 comparison (WARN = target not running your build). ADR 0002.
- `build-fat.sh` refuses a slice whose `SOURCE-STAMP` differs from the tree. `scripts/source-stamp.sh` is build-host's canonical file: never edit it; port excludes go in `scripts/source-stamp-excludes.sh`. ADR 0014.
- Every PowerPC slice carries its exact cpusubtype, never `ppc (ALL)`. Read it with `macho-archs.sh`, not `file` or `lipo`. ADR 0002.
- Bench every change on all targets, 3 runs, code and bench in separate commits; a regression verdict needs a same-session A/B. ADR 0009.
- Every per-target knob stays flippable without a rebuild (ADR 0008, `docs/KNOBS.md`).
- Release: content-verify the DMG, build it on a Tiger host, install it the end-user way on the oldest and newest targets. ADR 0005. Bump `QS_PORT_VERSION` for every deployed build, tag first. ADR 0004.
- Never hard-KILL the engine in fullscreen on G3 or G5: TERM, grace, then `killall -KILL quakespasm`. ADR 0007.
- Never run `build.sh g3` and `g4` in parallel, or `bench.sh` legs in parallel from one shell.
- No `pkill` on Tiger or Panther (`killall`); Panther `sleep` is integer-only; Leopard `sudo` has no `-n`.
- G5 must run Panther 10.3.9+: keep the 10.3.9 SDK and min-10.3 flags, never restore the Leopard floor.
- The orchestration host needs real rsync (`brew install rsync`), not openrsync. Minis' `/Developer/SDKs/*` are read-only.
- We ship code, not content (ADR 0012). QuakeSpasm is GL-only: no software renderer, no upstream PowerPC code.
