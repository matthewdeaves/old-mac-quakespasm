#!/usr/bin/env bash
# Run the full static-analysis battery against the Linux build of QuakeSpasm.
# Each tool's output lands under analysis/<tool>.log; raw artifacts under
# analysis/raw/<tool>/ (gitignored).
#
# This is the orchestrator. Single-tool wrappers (analyze-cppcheck.sh, etc.)
# call into individual stages so you can iterate on one tool without
# re-running the whole battery.
#
# usage: scripts/analyze-all.sh [tool [tool...]]
#   tools: cppcheck fanalyzer warnings shellcheck scanbuild clangtidy flawfinder sparse iwyu
#   default (no args): all tools that have install dependencies satisfied

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

mkdir -p analysis/suppressions analysis/raw

ALL_TOOLS=(cppcheck fanalyzer warnings shellcheck scanbuild clangtidy flawfinder sparse iwyu)
TOOLS=("$@")
[ ${#TOOLS[@]} -eq 0 ] && TOOLS=("${ALL_TOOLS[@]}")

# Track which tools ran cleanly vs which were skipped due to missing deps.
declare -a RAN SKIPPED FAILED

run_tool() {
  local tool="$1"; shift
  echo "================================================================"
  echo "== $tool"
  echo "================================================================"
  if "$@"; then
    RAN+=("$tool")
  else
    FAILED+=("$tool")
  fi
}

skip_tool() {
  local tool="$1"; shift
  local reason="$1"; shift
  echo "[skip] $tool — $reason"
  SKIPPED+=("$tool ($reason)")
}

t_cppcheck() {
  command -v cppcheck >/dev/null || { skip_tool cppcheck "not installed"; return 0; }
  cppcheck --enable=all --inconclusive --std=c89 --quiet \
    --suppress=missingIncludeSystem --suppress=unusedFunction \
    --suppress=unmatchedSuppression \
    --suppressions-list=analysis/suppressions/cppcheck.txt 2>/dev/null || true \
    -I Quake/ Quake/*.c Quake/*.h 2> analysis/cppcheck.log
  echo "cppcheck: $(wc -l < analysis/cppcheck.log) lines"
}

t_fanalyzer() {
  scripts/build-linux.sh analyze 2>&1 | tee /tmp/qs-build-linux-analyze.log >/dev/null
  grep -E '(error|warning):' /tmp/qs-build-linux-analyze.log > analysis/fanalyzer.log
  echo "fanalyzer: $(wc -l < analysis/fanalyzer.log) lines"
}

t_warnings() {
  scripts/build-linux.sh default 2>&1 | tee /tmp/qs-build-linux-default.log >/dev/null
  grep -E '(error|warning):' /tmp/qs-build-linux-default.log > analysis/warnings-linux-default.log
  echo "warnings (linux): $(wc -l < analysis/warnings-linux-default.log) lines"
  grep -oE '\[-W[a-z=-]+\]' analysis/warnings-linux-default.log | sort | uniq -c | sort -rn | head -15
}

t_shellcheck() {
  command -v shellcheck >/dev/null || { skip_tool shellcheck "not installed"; return 0; }
  shellcheck scripts/*.sh > analysis/shellcheck.log 2>&1 || true
  echo "shellcheck: $(wc -l < analysis/shellcheck.log) lines"
}

t_scanbuild() {
  command -v scan-build >/dev/null || { skip_tool scanbuild "needs apt install clang-tools"; return 0; }
  rm -rf analysis/raw/scanbuild analysis/scanbuild
  scan-build -o analysis/scanbuild --keep-empty \
    make -C Quake -f Makefile clean >/dev/null 2>&1 || true
  scan-build -o analysis/scanbuild \
    make -C Quake -f Makefile -j"$(nproc)" \
      USE_SDL2=1 USE_CODEC_WAVE=1 USE_CODEC_VORBIS=1 \
      USE_CODEC_MP3=0 USE_CODEC_FLAC=0 USE_CODEC_OPUS=0 \
      USE_CODEC_MIKMOD=0 USE_CODEC_UMX=0 \
      EXTRA_CFLAGS="-O0 -g" 2> analysis/scanbuild.log
  echo "scan-build: $(wc -l < analysis/scanbuild.log) lines"
}

t_clangtidy() {
  command -v clang-tidy >/dev/null || { skip_tool clangtidy "needs apt install clang-tidy"; return 0; }
  # NB: no --checks= here. Cmdline --checks= REPLACES the .clang-tidy file's
  # Checks: setting (verified with clang-tidy 20 --list-checks), so the
  # negations in .clang-tidy were silently dropped. Single source of truth
  # is .clang-tidy at the repo root.
  clang-tidy \
    --header-filter='Quake/' \
    Quake/*.c -- -I Quake/ -I /usr/include/SDL2 -DUSE_SDL2 -DUSE_CODEC_WAVE -DUSE_CODEC_VORBIS \
    > analysis/clang-tidy.log 2>&1 || true
  echo "clang-tidy: $(wc -l < analysis/clang-tidy.log) lines"
}

t_flawfinder() {
  command -v flawfinder >/dev/null || { skip_tool flawfinder "needs apt install flawfinder"; return 0; }
  flawfinder --quiet --csv Quake/ > analysis/flawfinder.csv 2> /dev/null || true
  flawfinder --quiet Quake/ > analysis/flawfinder.log 2>&1 || true
  echo "flawfinder: $(wc -l < analysis/flawfinder.log) lines"
}

t_sparse() {
  command -v cgcc >/dev/null || { skip_tool sparse "needs apt install sparse"; return 0; }
  make -C Quake -f Makefile clean >/dev/null 2>&1 || true
  make -C Quake -f Makefile -j"$(nproc)" \
    USE_SDL2=1 USE_CODEC_WAVE=1 USE_CODEC_VORBIS=1 \
    USE_CODEC_MP3=0 USE_CODEC_FLAC=0 USE_CODEC_OPUS=0 \
    USE_CODEC_MIKMOD=0 USE_CODEC_UMX=0 \
    CC='cgcc -Wsparse-all' 2> analysis/sparse.log >/dev/null || true
  echo "sparse: $(wc -l < analysis/sparse.log) lines"
}

t_iwyu() {
  command -v iwyu_tool >/dev/null || { skip_tool iwyu "needs apt install iwyu"; return 0; }
  # iwyu wants a compile_commands.json; bear can produce one. Skip if bear missing.
  command -v bear >/dev/null || { skip_tool iwyu "needs bear (apt install bear) for compile_commands.json"; return 0; }
  bear -- make -C Quake -f Makefile -j"$(nproc)" \
    USE_SDL2=1 USE_CODEC_WAVE=1 USE_CODEC_VORBIS=1 \
    USE_CODEC_MP3=0 USE_CODEC_FLAC=0 USE_CODEC_OPUS=0 \
    USE_CODEC_MIKMOD=0 USE_CODEC_UMX=0 >/dev/null 2>&1 || true
  iwyu_tool -p Quake/ > analysis/iwyu.log 2>&1 || true
  echo "iwyu: $(wc -l < analysis/iwyu.log) lines"
}

for t in "${TOOLS[@]}"; do
  case "$t" in
    cppcheck)   run_tool cppcheck   t_cppcheck ;;
    fanalyzer)  run_tool fanalyzer  t_fanalyzer ;;
    warnings)   run_tool warnings   t_warnings ;;
    shellcheck) run_tool shellcheck t_shellcheck ;;
    scanbuild)  run_tool scanbuild  t_scanbuild ;;
    clangtidy)  run_tool clangtidy  t_clangtidy ;;
    flawfinder) run_tool flawfinder t_flawfinder ;;
    sparse)     run_tool sparse     t_sparse ;;
    iwyu)       run_tool iwyu       t_iwyu ;;
    *) echo "unknown tool: $t" >&2; exit 2 ;;
  esac
done

echo
echo "================================================================"
echo "== Summary"
echo "================================================================"
echo "Ran:     ${RAN[*]:-(none)}"
echo "Skipped: ${SKIPPED[*]:-(none)}"
echo "Failed:  ${FAILED[*]:-(none)}"
echo
echo "Reports under analysis/. INDEX.md has the map."
