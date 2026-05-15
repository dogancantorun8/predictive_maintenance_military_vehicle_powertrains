#!/bin/bash
set -uo pipefail
source "$(dirname "$0")/../_lib.sh"

test_header "Prometheus API health and scrape targets"

if ! kubectl get statefulset prometheus-prometheus-kube-prometheus-prometheus -n monitoring >/dev/null 2>&1; then
  skip "Prometheus not deployed"
  exit 0
fi

PROM_POD=$(kubectl get pod -n monitoring -l app.kubernetes.io/name=prometheus \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
info "Using Prometheus pod: $PROM_POD"

PROM_SVC="prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090"

HEALTH=$(kubectl run prom-test-$$ --rm -i --restart=Never \
  --image=busybox:1.36 --quiet -- \
  wget -qO- "http://${PROM_SVC}/-/healthy" 2>/dev/null || echo "fail")

if echo "$HEALTH" | grep -qi "healthy"; then
  pass "Prometheus /-/healthy returns OK"
else
  fail "Prometheus /-/healthy failed" "got: $HEALTH"
fi

TARGETS_RESPONSE=$(kubectl run prom-test-$$ --rm -i --restart=Never \
  --image=busybox:1.36 --quiet -- \
  wget -qO- "http://${PROM_SVC}/api/v1/query?query=up" 2>/dev/null || echo "")

TARGETS_UP=$(echo "$TARGETS_RESPONSE" | grep -o '"value":\[[^]]*,"1"\]' | wc -l)

if [ "$TARGETS_UP" -gt 5 ]; then
  pass "Prometheus has $TARGETS_UP UP scrape targets (expect 6+)"
else
  fail "Prometheus has only $TARGETS_UP UP scrape targets" \
       "expected at least 6 (node-exporter, kube-state-metrics, kubelet, etc.)"
fi

NODE_RESPONSE=$(kubectl run prom-test-$$ --rm -i --restart=Never \
  --image=busybox:1.36 --quiet -- \
  wget -qO- "http://${PROM_SVC}/api/v1/query?query=up%7Bjob%3D%22node-exporter%22%7D" 2>/dev/null || echo "")

NODE_COUNT=$(echo "$NODE_RESPONSE" | grep -c '"value"' || true)

if [ "$NODE_COUNT" -gt 0 ]; then
  pass "node-exporter metrics are being collected"
else
  fail "node-exporter metrics not flowing"
fi
