#!/bin/bash
set -uo pipefail
source "$(dirname "$0")/../_lib.sh"

test_header "PersistentVolumeClaims are Bound"

PVC_TOTAL=$(kubectl get pvc -A --no-headers 2>/dev/null | wc -l)
PVC_PENDING=$(kubectl get pvc -A --no-headers 2>/dev/null | grep -v Bound | wc -l)

if [ "$PVC_TOTAL" -eq 0 ]; then
  skip "No PVCs found"
elif [ "$PVC_PENDING" -eq 0 ]; then
  pass "All $PVC_TOTAL PVCs Bound"
else
  fail "$PVC_PENDING of $PVC_TOTAL PVCs not Bound"
fi
