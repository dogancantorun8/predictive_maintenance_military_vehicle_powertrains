#!/bin/bash
set -uo pipefail
source "$(dirname "$0")/../_lib.sh"

test_header "Namespace and pod health"

for ns in kube-system minio mlops kubeflow monitoring; do
  if ! kubectl get ns "$ns" >/dev/null 2>&1; then
    skip "Namespace '$ns' not deployed yet"
    continue
  fi
  total=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l)
  not_ready=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null \
    | grep -v -E 'Running|Completed' | wc -l)
  if [ "$total" -eq 0 ]; then
    skip "Namespace '$ns' has no pods"
  elif [ "$not_ready" -eq 0 ]; then
    pass "Namespace '$ns': $total/$total pods healthy"
  else
    fail "Namespace '$ns': $not_ready of $total pods NOT ready"
  fi
done
