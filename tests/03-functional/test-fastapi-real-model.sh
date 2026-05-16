#!/bin/bash
# tests/03-functional/test-fastapi-real-model.sh
# Verifies FastAPI serves a real (non-stub) model from MLflow Registry.
#
# Complementary to test-fastapi.sh:
#   - test-fastapi.sh tests endpoint reachability and response shape.
#     It PASSes even when FastAPI falls back to the stub model.
#   - This test (test-fastapi-real-model.sh) asserts a real model is
#     loaded and producing input-sensitive predictions.
#
# Preconditions:
#   - FastAPI deployment Running in mlops namespace
#   - A model version tagged with the 'production' alias in MLflow Registry
#   - FastAPI image contains all model dependencies (e.g., torch for PyTorch
#     LSTM, sklearn for tree models, etc.)
#
# Test methodology: in-cluster via `kubectl run` (no port-forward needed).

set -uo pipefail
source "$(dirname "$0")/../_lib.sh"

test_header "FastAPI real model serving (post-promotion)"

# ---------- Preconditions ----------

if ! kubectl get deployment fastapi -n mlops >/dev/null 2>&1; then
  skip "FastAPI not deployed yet"
  exit 0
fi

SVC_URL="http://fastapi.mlops.svc.cluster.local:8000"

# ---------- Test 1: GET / returns is_stub=false ----------

INFO_RESP=$(kubectl run fapi-rm-info-$$ --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --quiet -- \
  curl -sf "$SVC_URL/" 2>/dev/null || echo "")

if [ -z "$INFO_RESP" ]; then
  fail "GET / did not respond"
  exit 1
fi

IS_STUB=$(echo "$INFO_RESP" | python3 -c \
  "import sys, json; print(json.load(sys.stdin).get('is_stub', 'unknown'))" 2>/dev/null)

MODEL_VER=$(echo "$INFO_RESP" | python3 -c \
  "import sys, json; print(json.load(sys.stdin).get('model_version', 'unknown'))" 2>/dev/null)

if [ "$IS_STUB" = "False" ] || [ "$IS_STUB" = "false" ]; then
  pass "Production model loaded (is_stub=false, version=$MODEL_VER)"
else
  fail "FastAPI is still serving stub model (is_stub=$IS_STUB)" \
       "promote model to 'production' alias in MLflow and rollout restart fastapi"
  exit 1
fi

# ---------- Test 2: POST /predict returns a non-stub RUL ----------

# Use a normalized feature vector (16 features, matching scaler output [0,1] range)
PREDICT_BODY='{"features":[0.5,0.3,0.7,0.4,0.2,0.8,0.6,0.5,0.3,0.7,0.4,0.5,0.6,0.2,0.8,0.5]}'

PREDICT_RESP=$(kubectl run fapi-rm-pred-$$ --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --quiet -- \
  curl -sf -X POST "$SVC_URL/predict" \
    -H 'Content-Type: application/json' \
    -d "$PREDICT_BODY" 2>/dev/null || echo "")

if [ -z "$PREDICT_RESP" ]; then
  fail "POST /predict did not respond"
  exit 1
fi

RUL_VALUE=$(echo "$PREDICT_RESP" | python3 -c \
  "import sys, json; print(json.load(sys.stdin).get('rul', 'unknown'))" 2>/dev/null)

if [ "$RUL_VALUE" = "unknown" ] || [ -z "$RUL_VALUE" ]; then
  fail "POST /predict response missing 'rul' field" "$PREDICT_RESP"
  exit 1
fi

# Reject the stub default value (125.0 — STUB_RUL constant)
if python3 -c "v=float('$RUL_VALUE'); exit(0 if abs(v - 125.0) > 0.001 else 1)" 2>/dev/null; then
  pass "POST /predict returned real RUL prediction (rul=$RUL_VALUE)"
else
  fail "POST /predict returned stub default RUL=125.0" "$PREDICT_RESP"
  exit 1
fi

# ---------- Test 3: Model is input-sensitive ----------
# Three very different feature vectors must produce three distinguishable RULs.
# If they're all identical, the model has effectively become a constant function
# (indicating either a stub, a broken model, or untrained weights).

RUL_LOW=$(kubectl run fapi-rm-low-$$ --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --quiet -- \
  curl -sf -X POST "$SVC_URL/predict" \
    -H 'Content-Type: application/json' \
    -d '{"features":[0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1]}' \
    2>/dev/null | python3 -c \
      "import sys, json; print(json.load(sys.stdin)['rul'])" 2>/dev/null || echo "")

RUL_MID=$(kubectl run fapi-rm-mid-$$ --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --quiet -- \
  curl -sf -X POST "$SVC_URL/predict" \
    -H 'Content-Type: application/json' \
    -d '{"features":[0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5]}' \
    2>/dev/null | python3 -c \
      "import sys, json; print(json.load(sys.stdin)['rul'])" 2>/dev/null || echo "")

RUL_HIGH=$(kubectl run fapi-rm-high-$$ --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --quiet -- \
  curl -sf -X POST "$SVC_URL/predict" \
    -H 'Content-Type: application/json' \
    -d '{"features":[0.9,0.9,0.9,0.9,0.9,0.9,0.9,0.9,0.9,0.9,0.9,0.9,0.9,0.9,0.9,0.9]}' \
    2>/dev/null | python3 -c \
      "import sys, json; print(json.load(sys.stdin)['rul'])" 2>/dev/null || echo "")

if [ -n "$RUL_LOW" ] && [ -n "$RUL_MID" ] && [ -n "$RUL_HIGH" ]; then
  info "RUL for [0.1, ..., 0.1] = $RUL_LOW"
  info "RUL for [0.5, ..., 0.5] = $RUL_MID"
  info "RUL for [0.9, ..., 0.9] = $RUL_HIGH"

  DISTINCT=$(python3 -c "
vals = [float('$RUL_LOW'), float('$RUL_MID'), float('$RUL_HIGH')]
# 'meaningfully different' = at least one pair differs by > 0.5 cycle
spreads = [abs(vals[0]-vals[1]), abs(vals[1]-vals[2]), abs(vals[0]-vals[2])]
print('YES' if max(spreads) > 0.5 else 'NO')
")
  if [ "$DISTINCT" = "YES" ]; then
    pass "Model is input-sensitive (3 inputs produce distinguishable RULs)"
  else
    fail "Model produces near-identical RULs for different inputs" \
         "low=$RUL_LOW mid=$RUL_MID high=$RUL_HIGH"
  fi
else
  fail "One or more /predict calls in input-sensitivity test failed to parse"
fi
