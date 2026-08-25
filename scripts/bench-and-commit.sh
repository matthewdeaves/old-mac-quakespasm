#!/usr/bin/env bash
# Bench the current HEAD and commit the resulting CSV rows + raw logs.
# Use as the second-of-two commits per phase (the first being the code change):
#
#   git commit -m "Phase 2.1: ..."        # phase code commit
#   scripts/bench-and-commit.sh "Phase 2.1 BGRA lightmaps"   # bench + bench commit
#
# This is the canonical way to land a phase's bench data — it enforces the
# cadence rule documented in CLAUDE.md (Bench-and-commit cadence) without
# anyone having to remember each step.
#
# usage: scripts/bench-and-commit.sh "<phase description>" [parallel-bench args...]
#   --quick is the most common extra arg (smoke grid instead of full).
#   Other args (--reset etc.) pass straight through to parallel-bench.sh.
#
# Exit codes:
#   0    bench succeeded and committed
#   1    bench produced no new rows (something went wrong; nothing committed)
#   2    working tree dirty (refuse to commit ambiguous data)
#   3    bench failed (parallel-bench returned non-zero)

set -euo pipefail

if [ $# -lt 1 ]; then
  sed -n '2,21p' "$0"
  exit 2
fi

DESC="$1"; shift
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Refuse to bench against a dirty tree — the resulting CSV rows would tag the
# wrong commit. The phase code commit MUST land before this script runs.
if ! git diff-index --quiet HEAD; then
  echo "[bench-and-commit] working tree is dirty — commit your phase changes first" >&2
  echo "[bench-and-commit] (the bench data tags HEAD; ambiguous if uncommitted edits affect the binary)" >&2
  exit 2
fi

COMMIT=$(git rev-parse --short HEAD)
SUBJECT=$(git log -1 --pretty=%s)
echo "[bench-and-commit] HEAD = $COMMIT — $SUBJECT"
echo "[bench-and-commit] phase = $DESC"

# parallel-bench.sh exports its own COMMIT, but we set it here too so any
# direct bench.sh invocations from this script (none today, but defensive)
# would also be pinned.
export COMMIT

# Snapshot existing row count so we can detect 'no new rows' afterwards.
CSV="$REPO_ROOT/benchmarks/results.csv"
ROWS_BEFORE=0
if [ -f "$CSV" ]; then
  ROWS_BEFORE=$(($(wc -l < "$CSV") - 1))
  [ "$ROWS_BEFORE" -lt 0 ] && ROWS_BEFORE=0
fi

# Run the bench. parallel-bench exits non-zero if either leg failed or any
# cell returned NA fps (via bench.sh's NA detection).
BENCH_RC=0
"$REPO_ROOT/scripts/parallel-bench.sh" "$@" || BENCH_RC=$?
if [ "$BENCH_RC" -ne 0 ]; then
  echo "[bench-and-commit] parallel-bench failed (exit $BENCH_RC) — NOT committing" >&2
  echo "[bench-and-commit] partial data preserved in benchmarks/results.csv and raw/" >&2
  exit 3
fi

# Verify new rows landed for the right commit.
NEW_ROWS=$(grep -c ",$COMMIT," "$CSV" || true)
ROWS_AFTER=$(($(wc -l < "$CSV") - 1))
ROWS_ADDED=$((ROWS_AFTER - ROWS_BEFORE))

if [ "$NEW_ROWS" -eq 0 ] || [ "$ROWS_ADDED" -eq 0 ]; then
  echo "[bench-and-commit] no rows for $COMMIT landed in CSV — nothing to commit" >&2
  exit 1
fi

echo "[bench-and-commit] $NEW_ROWS rows for $COMMIT in CSV (added $ROWS_ADDED this run)"

# Stage CSV + raw logs for THIS commit (don't sweep up logs from prior runs).
git add "$CSV"
shopt -s nullglob
RAW_LOGS=("$REPO_ROOT/benchmarks/raw/${COMMIT}_"*.log)
shopt -u nullglob
if [ "${#RAW_LOGS[@]}" -gt 0 ]; then
  git add "${RAW_LOGS[@]}"
fi

if git diff --cached --quiet; then
  echo "[bench-and-commit] nothing staged — bench data may already be committed" >&2
  exit 1
fi

# Build a summary of medians by (machine, demo, res) for the commit message.
SUMMARY=$(grep ",$COMMIT," "$CSV" | awk -F, '{if ($11 != "" && $11 != $5) printf "  %s %-5s %-10s (rendered %s)  %s fps\n", $3, $4, $5, $11, $9; else printf "  %s %-5s %-10s  %s fps\n", $3, $4, $5, $9}' | sort)

git commit -m "$(cat <<EOF
bench: ${DESC} (HEAD ${COMMIT})

${SUMMARY}
EOF
)"

echo "[bench-and-commit] OK — bench commit landed on top of ${COMMIT}"
