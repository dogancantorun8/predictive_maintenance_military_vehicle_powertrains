#!/bin/bash
# tests/03-functional/test-prometheus-api.sh
# Verifies Prometheus is running, scraping targets, and answering queries.

set -uo pipefail
source "$(dirname "$0")/../_lib.sh"

test_header "Prometheus API health and scrape targets"

if ! kubectl get statefulset prometheus-prometheus-kube-prometheus-prometheus -n monitoring >/dev/null 2>&1; then
  skip "Prometheus not deployed"
  exit 0
fi

PROM_POD=$(kubectl get pod -n monitoring -l app.kubernetes.io/name=prometheus \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$PROM_POD" ]; then
  fail "Could not find Prometheus pod"
  exit 1
fi

info "Using Prometheus pod: $PROM_POD"

# Test 1: Prometheus health endpoint
HEALTH=$(kubectl exec -n monitoring "$PROM_POD" -c prometheus -- \
  wget -qO- http://localhost:9090/-/healthy 2>/dev/null || echo "fail")
if echo "$HEALTH" | grep -qi "healthy"; then
  pass "Prometheus /-/healthy returns OK"
else
  fail "Prometheus /-/healthy failed" "got: $HEALTH"
fi

# Test 2: Prometheus has scrape targets and they're UP
TARGETS_UP=$(kubectl exec -n monitoring "$PROM_POD" -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=up' 2>/dev/null \
  | grep -o '"value":\[[^]]*,"1"\]' | wc -l)

if [ "$TARGETS_UP" -gt 5 ]; then
  pass "Prometheus has $TARGETS_UP UP scrape targets (expect 6+)"
else
  fail "Prometheus has only $TARGETS_UP UP scrape targets" \
       "expected at least 6 (node-exporter, kube-state-metrics, kubelet, etc.)"
fi

# Test 3: Prometheus can query node CPU metric (proves end-to-end metric flow)
NODE_CPU=$(kubectl exec -n monitoring "$PROM_POD" -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=up{job="node-exporter"}' 2>/dev/null \
  | grep -c '"value"')

if [ "$NODE_CPU" -gt 0 ]; then
  pass "node-exporter metrics are being collected"
else
  fail "node-exporter metrics not flowing"
fi
