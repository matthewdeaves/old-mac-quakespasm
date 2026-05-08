# Static analysis & QA report index

This directory holds the output and triage notes for every analysis tool
wired into the QuakeSpasm port. Each tool's full output goes under
`raw/<tool>/` (gitignored — too bulky for git); the summarised log and
triage notes are committed.

## Conventions

- `<tool>.log` — stdout/stderr capture from the most recent sweep. Truncated
  to ≤ 5000 lines so it stays readable in git.
- `<tool>-triage.md` — human notes: which findings are real bugs, which
  are false positives, which were filed as TODO Track B candidates.
- `suppressions/<tool>.txt` — per-tool suppression lists. Every entry has
  a one-line rationale comment.
- `perf-candidates.md` — opt-info / vectoriser-miss output triaged into
  candidate optimisations for the next round.

## Tool inventory (Round v5 baseline)

| Tool | Status | Last run | Findings | Notes |
|------|--------|----------|----------|-------|
| cppcheck | wired | (pending) | — | Pattern + flow; standalone, no build needed |
| gcc -fanalyzer | wired | (pending) | — | Interprocedural; runs as part of `build-linux.sh analyze` |
| shellcheck | wired | (pending) | — | scripts/ tree quality |
| ASan (gcc) | wired | (pending) | — | `build-linux.sh asan` + headless timedemo |
| UBSan (gcc) | wired | (pending) | — | `build-linux.sh ubsan` + headless timedemo |
| Compiler warnings (Linux) | wired | (pending) | — | Modern gcc 15 maxout in `build-linux.sh default` |
| scan-build (clang SA) | **needs `apt install clang-tools`** | — | — | sudo gate; install in morning |
| clang-tidy | **needs `apt install clang-tidy`** | — | — | sudo gate; install in morning |
| flawfinder | **needs `apt install flawfinder`** | — | — | sudo gate; install in morning |
| sparse | **needs `apt install sparse`** | — | — | sudo gate; install in morning |
| iwyu | **needs `apt install iwyu`** | — | — | sudo gate; install in morning |
| Infer | not packaged in apt | — | — | release tarball; deferred |

**Morning install command:**

```
sudo apt install -y clang-tools clang-tidy flawfinder sparse iwyu
```

After install, rerun `scripts/analyze-all.sh` to add their results.

## How to run

```
scripts/analyze-all.sh           # full battery, results land here
scripts/build-linux.sh asan      # ASan-instrumented binary → build/quakespasm-linux-asan
scripts/build-linux.sh ubsan     # UBSan-instrumented binary
scripts/build-linux.sh analyze   # gcc -fanalyzer (warnings only)
```

Each tool also has a single-tool wrapper for fast iteration:
`scripts/analyze-cppcheck.sh`, `scripts/analyze-fanalyzer.sh`, etc.
