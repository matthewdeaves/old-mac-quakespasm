# Architecture decision records

One record per decision that shapes the port. Each states the decision, the
evidence for it, what was rejected and what it costs. They do not narrate
history; superseded detail belongs in `docs/archive/`, and recorded negative
results belong in `../../MISTAKES.md`.

| # | Decision |
|---|---|
| [0001](0001-four-slices-chosen-by-cpu-capability.md) | Four slices, chosen by CPU capability and not by OS version |
| [0002](0002-every-powerpc-slice-carries-its-exact-cpusubtype.md) | Every PowerPC slice carries its exact cpusubtype, and the build asserts it |
| [0003](0003-every-shipped-slice-links-sdl-1-2.md) | Every shipped slice links SDL 1.2, and the PowerPC slices are hand-built |
| [0004](0004-the-fat-is-composed-by-lipo-from-four-separate-builds.md) | The fat binary is composed by lipo from four separate builds, not one pass |
| [0005](0005-build-on-an-intel-lion-mini-package-the-dmg-on-tiger.md) | Build on an Intel Lion mini, package the disk image on a Tiger box |
| [0006](0006-settings-are-layered-per-arch-then-per-machine.md) | Settings are layered per-arch then per-machine, from inside the bundle |
| [0007](0007-fragile-gpus-are-gated-on-the-renderer-string-and-mode-locked.md) | Fragile GPUs are gated on the renderer string, and their video mode is locked |
| [0008](0008-every-knob-is-toggleable-gate-a-change-do-not-drop-it.md) | Every per-target knob is toggleable, and a split result is gated, not dropped |
| [0009](0009-benchmarks-are-three-runs-on-hardware-with-a-same-session-ab.md) | Benchmarks are three runs on real hardware, and a verdict needs a same-session A/B |
| [0010](0010-the-bundle-is-a-real-app-that-carries-everything-it-needs.md) | The bundle is a real .app, location-agnostic, carrying everything it needs |
| [0011](0011-the-dedicated-server-is-a-linux-elf-built-in-a-container.md) | The dedicated server is a Linux ELF built in a container |
| [0012](0012-we-ship-code-not-content.md) | We ship code, not content |
| [0013](0013-two-more-slices-i386-for-2006-intel-and-arm64-for-apple-silicon.md) | Two more slices: i386 for 2006 Intel, arm64 for Apple Silicon |
| [0014](0014-a-slice-is-fused-only-if-it-was-built-from-this-source.md) | A slice is fused only if it was built from this source |
