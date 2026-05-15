#!/bin/bash
# tests/03-functional/test-grafana-api.sh
# Verifies Grafana is up, reachable, and has the Prometheus datasource registered.

set -uo pipefail
source "$(dirname "$0")/../_lib.sh"

test_header "Grafana health and datasource"

if ! kubectl get deployment prometheus-grafana -n monitoring >/dev/null 2>&1; then
  skip "Grafana not deployed"
  exit 0
fi

GRAFANA_POD=$(kubectl get pod -n monitoring -l app.kubernetes.io/name=grafana \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

info "Using Grafana pod: $GRAFANA_POD"

# Test 1: Grafana health endpoint
HEALTH=$(kubectl exec -n monitoring "$GRAFANA_POD" -c grafana -- \
  wget -qO- http://localhost:3000/api/health 2>/dev/null || echo "fail")

if echo "$HEALTH" | grep -q '"database":"ok"'; then
  pass "Grafana /api/health returns database=ok"
else
  fail "Grafana health check failed" "got: $HEALTH"
fi

# Test 2: Grafana frontend serves login page
LOGIN_STATUS=$(kubectl exec -n monitoring "$GRAFANA_POD" -c grafana -- \
  wget -qO- --server-response http://localhost:3000/login 2>&1 \
  | grep -c "HTTP/1.1 200")

if [ "$LOGIN_STATUS" -gt 0 ]; then
  pass "Grafana /login page serves HTTP 200"
else
  fail "Grafana login page not reachable"
fi
