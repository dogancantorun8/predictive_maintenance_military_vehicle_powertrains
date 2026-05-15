# Tests

Automated tests for the thesis-infra MLOps stack. Tests are organized in
4 categories, run in order from cheapest to most expensive:

| Category          | Purpose                                              | Cost   |
|-------------------|------------------------------------------------------|--------|
| 01-infra          | Pods Running, PVCs Bound, RAM/CPU healthy            | <5s    |
| 02-connectivity   | DNS resolution, service-to-service reachability      | ~30s   |
| 03-functional     | Each component does its actual job (R/W, API, ...)   | ~1min  |
| 99-integration    | End-to-end multi-component scenarios                 | ~2min  |

## Running

```bash
# Run everything
./tests/run-all.sh

# Run only one category
./tests/run-all.sh 03-functional

# Run a single test
./tests/03-functional/test-mlflow-smoke.sh
```

## Output

Each test prints color-coded results:
- `PASS` — green, the assertion held
- `FAIL` — red, the assertion didn't hold (with reason)
- `SKIP` — yellow, the underlying component isn't deployed yet
- `INFO` — blue, informational only

## Writing a new test

```bash
#!/bin/bash
set -uo pipefail
source "$(dirname "$0")/../_lib.sh"

test_header "Your test description"

# Use the helpers:
pass "Something worked"
fail "Something didn't work" "optional detail"
skip "Component not deployed yet"
assert_eq "$actual" "expected" "Description"

# Mark the script executable:
#   chmod +x tests/<category>/test-<name>.sh
```
