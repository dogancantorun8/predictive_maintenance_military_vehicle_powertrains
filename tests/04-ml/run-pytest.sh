#!/bin/bash
# Wrapper to integrate pytest tests into bash test orchestrator.

set -uo pipefail
source "$(dirname "$0")/../_lib.sh"

test_header "Preprocessing pipeline unit tests"

VENV="/root/thesis-infra/.venv"

if [ ! -x "$VENV/bin/pytest" ]; then
  skip "pytest not installed in venv"
  exit 0
fi

# Run pytest, capture output
output=$("$VENV/bin/python" -m pytest "$(dirname "$0")" -v --tb=short 2>&1)
exit_code=$?

# Parse pytest summary line: "10 passed in 2.45s" or "1 failed, 9 passed"
summary=$(echo "$output" | tail -10 | grep -E "passed|failed" | tail -1)

if [ "$exit_code" -eq 0 ]; then
  pass "All pytest tests passed: $summary"
else
  fail "Pytest tests failed" "$summary"
  echo "$output" | tail -30
fi
