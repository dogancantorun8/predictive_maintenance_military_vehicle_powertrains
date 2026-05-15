#!/bin/bash
# tests/03-functional/test-fastapi.sh
# Verifies FastAPI inference service: pod health, /healthz, /predict, /metrics.

set -uo pipefail
source "$(dirname "$0")/../_lib.sh"

test_header "FastAPI inference service health and prediction"

if ! kubectl get deployment fastapi -n mlops >/dev/null 2>&1; then
  skip "FastAPI not deployed yet"
  exit 0
fi

POD=$(kubectl get pod -n mlops -l app=fastapi -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
info "Using FastAPI pod: $POD"

SVC_URL="http://fastapi.mlops.svc.cluster.local:8000"

# Test 1: /healthz
HEALTH=$(kubectl run fapi-h-$$ --rm -i --restart=Never \
  --image=busybox:1.36 --quiet -- \
  wget -qO- "$SVC_URL/healthz" 2>/dev/null || echo "fail")

if echo "$HEALTH" | grep -q '"ok"'; then
  pass "/healthz returns ok"
else
  fail "/healthz failed" "got: $HEALTH"
fi

# Test 2: /readyz
READY=$(kubectl run fapi-r-$$ --rm -i --restart=Never \
  --image=busybox:1.36 --quiet -- \
  wget -qO- "$SVC_URL/readyz" 2>/dev/null || echo "fail")

if echo "$READY" | grep -q '"ready"'; then
  pass "/readyz returns ready"
else
  fail "/readyz failed" "got: $READY"
fi

# Test 3: /predict — 21 features, RUL float
PREDICT_BODY='{"features":[0.0023,-0.0003,100.0,518.67,641.82,1589.7,1400.6,14.62,21.61,554.36,2388.06,9046.19,1.3,47.47,521.66,2388.02,8138.62,8.4195,0.03,392,2388]}'

PREDICT=$(kubectl run fapi-p-$$ --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --quiet -- \
  curl -sf -X POST "$SVC_URL/predict" \
    -H 'Content-Type: application/json' \
    -d "$PREDICT_BODY" 2>/dev/null || echo "fail")

if echo "$PREDICT" | grep -q '"rul"'; then
  pass "/predict returns RUL prediction"
  info "Response: $PREDICT"
else
  fail "/predict failed" "got: $PREDICT"
fi

# Test 4: /metrics — Prometheus scrape format
METRICS=$(kubectl run fapi-m-$$ --rm -i --restart=Never \
  --image=busybox:1.36 --quiet -- \
  wget -qO- "$SVC_URL/metrics" 2>/dev/null || echo "fail")

if echo "$METRICS" | grep -q "rul_requests_total"; then
  pass "/metrics exposes rul_requests_total counter"
else
  fail "/metrics missing expected Prometheus metric" "got first 100 chars: ${METRICS:0:100}"
fi

# Test 5: Prometheus actually scrapes FastAPI (ServiceMonitor works)
PROM_SVC="prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090"
PROM_TARGETS=$(kubectl run prom-fapi-$$ --rm -i --restart=Never \
  --image=busybox:1.36 --quiet -- \
  wget -qO- "http://${PROM_SVC}/api/v1/query?query=up%7Bjob%3D%22fastapi%22%7D" 2>/dev/null || echo "")

if echo "$PROM_TARGETS" | grep -q '"value":\[[^]]*,"1"\]'; then
  pass "Prometheus scrapes FastAPI (ServiceMonitor working)"
else
  info "Prometheus has not yet scraped FastAPI (allow ~60s after first deploy)"
fi
