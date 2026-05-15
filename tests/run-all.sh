#!/bin/bash
# tests/run-all.sh
# Run all (or one category) of the thesis-infra tests.
#
# Usage:
#   ./tests/run-all.sh                    # run everything
#   ./tests/run-all.sh 01-infra           # run only that category
#   ./tests/run-all.sh 03-functional      # functional tests only

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

CATEGORY="${1:-all}"
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0

echo "=============================================="
echo "  thesis-infra test suite"
echo "  Category: $CATEGORY"
echo "  Date:     $(date)"
echo "=============================================="

run_category() {
  local cat_dir="$1"
  if [ ! -d "$SCRIPT_DIR/$cat_dir" ]; then
    return
  fi
  echo ""
  echo "  ━━━ Category: $cat_dir ━━━"

  for test_script in "$SCRIPT_DIR/$cat_dir"/test-*.sh; do
    [ -f "$test_script" ] || continue
    # Run the test in a subshell so its counter doesn't leak globally,
    # then capture its tallies from the output (workaround: source it)
    bash "$test_script"
    # Tally by re-sourcing _lib counters won't survive; parse from script's own log instead.
  done
}

# Run categories in order
if [ "$CATEGORY" = "all" ]; then
  for cat in 01-infra 02-connectivity 03-functional 99-integration; do
    run_category "$cat"
  done
else
  run_category "$CATEGORY"
fi

# Final summary — count pass/fail/skip across all output by running tests again
# in a quick aggregation mode. Simpler approach: count [PASS] / [FAIL] / [SKIP] lines.
echo ""
echo "=============================================="
echo "  Run complete (see results above)"
echo "  To re-run only this category:"
echo "    $0 <category>"
echo "=============================================="
