#!/bin/bash
# tests/04-ml/test-drift-no-false-positive.sh
#
# Verifies that drift_check correctly reports NO drift when production
# traffic matches the baseline distribution.
#
# This test guards against Engineering Challenge 16: a bug in the
# previous drift_check.py implementation (reconstruct_samples_from_histogram
# + scipy.stats.ks_2samp) where KS p-value was systematically biased to
# 0.0, causing drift_detected to always be True regardless of true
# distribution similarity. The fix (ks_from_histograms in drift_check.py
# >=0.1.4) compares empirical CDFs directly from bucket counts.
#
# Test is ADAPTIVE: it injects normal predictions iteratively until the
# 1h Prometheus window is dominated by normal traffic (PSI < threshold).
# This handles the case where previous test runs left residual drift in
# the window. Each iteration adds 300 normal predictions; max 5 iterations.
#
# Assertions:
#   1. CronJob deployed + image >=0.1.4
#   2. After self-dilution: PSI < 0.2 AND KS p-value finite AND drift=False
#
# Pre-condition: FastAPI on localhost:8000, X_train.npy available.

set -uo pipefail
source "$(dirname "$0")/../_lib.sh"

test_header "Drift detection — no false positive on normal traffic (EC#16)"

REPO="/root/thesis-infra"
NAMESPACE="monitoring"
EXPECTED_MIN_IMAGE_TAG="0.1.4"
FASTAPI_URL="http://localhost:8000"
N_NORMAL_PER_ITER=300
MAX_ITERATIONS=5
PROM_SCRAPE_WAIT=20
JOB_TIMEOUT=120
PSI_THRESHOLD=0.2

# ---------- 1. Pre-flight ----------
if ! kubectl get cronjob evidently-drift-check -n "$NAMESPACE" >/dev/null 2>&1; then
  skip "CronJob evidently-drift-check not found in $NAMESPACE" \
       "run ansible-playbook playbooks/12-evidently.yml first"
  exit 0
fi
pass "CronJob evidently-drift-check is deployed"

CURRENT_IMAGE=$(kubectl get cronjob evidently-drift-check -n "$NAMESPACE" \
  -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].image}' 2>/dev/null)
CURRENT_TAG="${CURRENT_IMAGE##*:}"
if [[ "$CURRENT_TAG" < "$EXPECTED_MIN_IMAGE_TAG" ]]; then
  fail "Image tag $CURRENT_TAG predates EC#16 fix"
  exit 1
fi
pass "Image tag $CURRENT_TAG >= $EXPECTED_MIN_IMAGE_TAG"

if ! curl -sf "$FASTAPI_URL/" >/dev/null 2>&1; then
  skip "FastAPI not reachable at $FASTAPI_URL"
  exit 0
fi
pass "FastAPI reachable at $FASTAPI_URL"

PYTHON_BIN="$REPO/.venv/bin/python"
if [ ! -x "$PYTHON_BIN" ]; then
  fail "Project venv not found at $PYTHON_BIN"
  exit 1
fi

if [ ! -f "$REPO/data/processed/X_train.npy" ]; then
  fail "X_train tensor not found"
  exit 1
fi
pass "X_train tensor available"

# Helper to send a batch of normal predictions
inject_normal() {
  local n="$1"
  local seed="$2"
  "$PYTHON_BIN" <<PYEOF
import time, requests, sys
import numpy as np
try:
    X = np.load("$REPO/data/processed/X_train.npy")
    np.random.seed($seed)
    sel = np.random.choice(len(X), size=$n, replace=False)
    sent = 0
    for w in X[sel]:
        r = requests.post("$FASTAPI_URL/predict", json={"sequence": w.tolist()}, timeout=10)
        r.raise_for_status()
        sent += 1
        time.sleep(0.3)
    print(f"OK sent={sent}")
except Exception as e:
    print(f"ERROR {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

# Helper to run drift check and parse result
run_drift_check() {
  local job_name="$1"
  kubectl create job --from=cronjob/evidently-drift-check \
    -n "$NAMESPACE" "$job_name" >/dev/null 2>&1
  local deadline=$(( $(date +%s) + JOB_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if kubectl get job "$job_name" -n "$NAMESPACE" -o json 2>/dev/null \
       | python3 -c "import sys,json;d=json.load(sys.stdin).get('status',{});sys.exit(0 if d.get('succeeded',0)>=1 else 1)" 2>/dev/null; then
      break
    fi
    sleep 3
  done
  kubectl logs -n "$NAMESPACE" -l "job-name=$job_name" --tail=50 2>/dev/null
  kubectl delete job "$job_name" -n "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1
}

# ---------- 2. Adaptive dilution loop ----------
info "Adaptive dilution: inject normal traffic until PSI < $PSI_THRESHOLD"
info "(max $MAX_ITERATIONS iterations, $N_NORMAL_PER_ITER predictions each)"

PSI=""
KS_PVALUE=""
DRIFT_DECISION=""
RECOVERED="no"
TOTAL_INJECTED=0

for iter in $(seq 1 $MAX_ITERATIONS); do
  info ""
  info "─── Iteration $iter/$MAX_ITERATIONS ───"
  info "Injecting $N_NORMAL_PER_ITER normal predictions..."

  RESULT=$(inject_normal "$N_NORMAL_PER_ITER" "$((42 + iter))")
  if ! echo "$RESULT" | grep -q "^OK "; then
    fail "Normal injection failed: $RESULT"
    exit 1
  fi
  TOTAL_INJECTED=$((TOTAL_INJECTED + N_NORMAL_PER_ITER))
  info "Injected (this iter): $N_NORMAL_PER_ITER; total: $TOTAL_INJECTED"

  info "Waiting ${PROM_SCRAPE_WAIT}s for Prometheus scrape..."
  sleep "$PROM_SCRAPE_WAIT"

  info "Triggering drift-check..."
  JOB_NAME="drift-no-fp-iter${iter}-$$"
  LOGS=$(run_drift_check "$JOB_NAME")

  PSI=$(echo "$LOGS" | grep "PSI =" | tail -1 | grep -oE "PSI = [0-9.]+" | grep -oE "[0-9.]+")
  KS_PVALUE=$(echo "$LOGS" | grep "KS statistic =" | tail -1 | grep -oE "p-value = [^ ]+" | awk '{print $NF}')
  DRIFT_DECISION=$(echo "$LOGS" | grep "Drift detected:" | tail -1 | awk -F': ' '{print $NF}' | tr -d ' ')

  info "  PSI:            $PSI"
  info "  KS p-value:     $KS_PVALUE"
  info "  Drift detected: $DRIFT_DECISION"

  # Check if PSI dropped below threshold
  if python3 -c "exit(0 if float('$PSI') < $PSI_THRESHOLD else 1)" 2>/dev/null; then
    info "✓ PSI < $PSI_THRESHOLD — dilution successful"
    RECOVERED="yes"
    break
  fi
  info "  PSI still above threshold, continuing..."
done

if [ "$RECOVERED" != "yes" ]; then
  fail "Could not dilute drift below $PSI_THRESHOLD in $MAX_ITERATIONS iterations" \
       "total injected: $TOTAL_INJECTED; consider longer 1h Prometheus window settling"
  exit 1
fi
pass "Drift diluted below threshold after $TOTAL_INJECTED normal predictions"

# ---------- 3. Assertions on final state ----------

if python3 -c "import math; v=float('$PSI'); exit(0 if math.isfinite(v) else 1)" 2>/dev/null; then
  pass "PSI is a finite number ($PSI)"
else
  fail "PSI is NaN/inf"
fi

if python3 -c "import math; v=float('$KS_PVALUE'); exit(0 if math.isfinite(v) else 1)" 2>/dev/null; then
  pass "KS p-value is a finite number ($KS_PVALUE)"
else
  fail "KS p-value is NaN — EC#16 regression"
fi

if python3 -c "exit(0 if float('$PSI') < $PSI_THRESHOLD else 1)" 2>/dev/null; then
  pass "PSI < $PSI_THRESHOLD (no drift signal)"
else
  fail "PSI ($PSI) >= $PSI_THRESHOLD"
fi

if [ "$DRIFT_DECISION" = "False" ]; then
  pass "drift_detected = False (no false positive)"
else
  fail "drift_detected = $DRIFT_DECISION (expected False)" \
       "EC#16 may have regressed"
fi

# ---------- Summary ----------
info ""
info "Test outcome: drift_check correctly reports NO drift after"
info "adaptive dilution. KS p-value is finite (EC#16 guard verified)."
info "Total normal predictions injected: $TOTAL_INJECTED"
