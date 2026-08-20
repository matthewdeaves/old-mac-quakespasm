# Apple Graphics Tools (Tiger / Xcode 2.5 vintage)

`graphics-tools.tar.gz` (1.5 MB) is the `Applications/Graphics Tools/`
folder extracted from `prereqs/xcode25_8m2558_developerdvd.dmg`'s
`OpenGLApps.pkg` payload. Contains:

- **OpenGL Profiler.app** (v78, April 2007), PPC + i386 universal.
  Apple's official OpenGL profiler: per-call timing, state inspection,
  software-fallback warnings, function trace. Documented in
  [TN2178](https://developer.apple.com/library/archive/technotes/tn2178/_index.html).
- **OpenGL Driver Monitor.app**, VRAM/AGP usage + GPU stats meter.
- **OpenGL Shader Builder.app**, GLSL editor (not relevant for our
  GL 1.3 targets, included for completeness).
- `ardbgd`, AppleRemoteDebugDaemon: remote-profiling agent that lets
  another machine running OpenGL Profiler attach to a target over the
  network. Useful if local-on-G4 profiling becomes too clunky.

## Why this is here

Apple removed the Tiger-era standalone OpenGL Profiler downloads from
[developer.apple.com/download/all](https://developer.apple.com/download/all/)
years ago, the oldest item that still appears under any "graphics"
search is "Graphics Tools for Xcode - March 2012", which is Lion-only
and may not include the PowerPC slice we need to run on a G4.

The G4 (PowerMac Quicksilver / Tiger 10.4) needs a profiler that
*runs on PPC*. The Xcode 2.5 OpenGLApps.pkg shipped exactly that, and
since we already vendored the Xcode 2.5 DMG for the 10.3.9 SDK, the
profiler comes free.

## Install on G4

```sh
scp prereqs/graphics-tools/graphics-tools.tar.gz g4:~/Desktop/
ssh g4 'cd ~/Desktop && tar xzf graphics-tools.tar.gz'
ssh g4 'open "/Users/mini/Desktop/Graphics Tools/OpenGL Profiler.app"'
```

`open` requires the full path on Tiger (relative paths fail with
"No such file"). After launch the GUI presents the standard "Attach
to Process" dialog, point it at quakespasm and start a trace.

## Verifying the Phase 5 SGIS regression

The motivation for vendoring this: during round v2 epilogue we
shipped a Phase 5 attempt (SGIS warpimage with frame-cadence
throttle) that regressed -35% on G4 demo1 1024, far worse than the
archive plan's -3 to -5 fps prediction. Without OpenGL Profiler we
couldn't see whether the cost was in software mipgen, in the
glCopyTexSubImage2D path, or somewhere unexpected. With it, we can.
