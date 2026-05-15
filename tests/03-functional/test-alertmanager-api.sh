#!/bin/bash
# tests/03-functional/test-alertmanager-api.sh
# Verifies Alertmanager is up and ready to receive alerts.

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

# Test 1: Alertmanager ready endpoint
READY=$(kubectl exec -n monitoring "$AM_POD" -c alertmanager -- \
  wget -qO- http://localhost:9093/-/ready 2>/dev/null || echo "fail")

if echo "$READY" | grep -qi "ok\|ready"; then
  pass "Alertmanager /-/ready returns OK"
else
  fail "Alertmanager /-/ready failed" "got: $READY"
fi

# Test 2: Alertmanager status endpoint reports a valid config
STATUS=$(kubectl exec -n monitoring "$AM_POD" -c alertmanager -- \
  wget -qO- http://localhost:9093/api/v2/status 2>/dev/null || echo "")

if echo "$STATUS" | grep -q '"configYAML"'; then
  pass "Alertmanager /api/v2/status returns a valid config"
else
  fail "Alertmanager status endpoint missing config"
fi
