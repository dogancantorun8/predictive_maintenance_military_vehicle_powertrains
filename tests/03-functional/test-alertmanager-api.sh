#!/bin/bash
set -uo pipefail
source "$(dirname "$0")/../_lib.sh"

test_header "Alertmanager API health"

if ! kubectl get statefulset alertmanager-prometheus-kube-prometheus-alertmanager -n monitoring >/dev/null 2>&1; then
  skip "Alertmanager not deployed"
  exit 0
fi

AM_POD=$(kubectl get pod -n monitoring -l app.kubernetes.io/name=alertmanager \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
info "Using Alertmanager pod: $AM_POD"

AM_SVC="prometheus-kube-prometheus-alertmanager.monitoring.svc.cluster.local:9093"

READY=$(kubectl run am-test-$$ --rm -i --restart=Never \
  --image=busybox:1.36 --quiet -- \
  wget -qO- "http://${AM_SVC}/-/ready" 2>/dev/null; echo "DONE")

if echo "$READY" | grep -qE "DONE$"; then
  pass "Alertmanager /-/ready returns OK"
else
  fail "Alertmanager /-/ready failed" "got: $READY"
fi

STATUS=$(kubectl run am-test-$$ --rm -i --restart=Never \
  --image=busybox:1.36 --quiet -- \
  wget -qO- "http://${AM_SVC}/api/v2/status" 2>/dev/null || echo "")

if echo "$STATUS" | grep -qE '"config"|"configYAML"|"cluster"'; then
  pass "Alertmanager /api/v2/status returns a valid response"
else
  fail "Alertmanager status endpoint check failed" "got first 200 chars: ${STATUS:0:200}"
fi
