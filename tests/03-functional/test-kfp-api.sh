#!/bin/bash
set -uo pipefail
source "$(dirname "$0")/../_lib.sh"

test_header "KFP API health"

if ! kubectl get deployment ml-pipeline -n kubeflow >/dev/null 2>&1; then
  skip "KFP not deployed"
  exit 0
fi

# KFP API server has /apis/v1beta1/healthz endpoint
KFP_API=$(kubectl get pod -n kubeflow -l app=ml-pipeline -o jsonpath='{.items[0].metadata.name}')
HEALTH=$(kubectl exec -n kubeflow "$KFP_API" -- \
  wget -qO- http://localhost:8888/apis/v1beta1/healthz 2>/dev/null || echo "fail")

if echo "$HEALTH" | grep -q "multi_user"; then
  pass "KFP API server responds to /healthz"
else
  fail "KFP API server health check failed" "got: $HEALTH"
fi
