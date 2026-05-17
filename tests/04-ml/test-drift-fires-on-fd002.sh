#!/bin/bash
# tests/04-ml/test-drift-fires-on-fd002.sh
#
# Verifies that drift_check correctly fires drift_detected=True when
# production traffic is dominated by FD002 (different operating
# conditions than training data FD001). This guards drift detection
# sensitivity after the EC#16 fix — the fix should NOT silence true
# drift signals while suppressing the false-positive bias.
#
# Test workflow:
#   1. Verify Evidently CronJob is deployed and image >=0.1.4
#   2. Inject 300 FD002-derived drift predictions via FastAPI
#      (using FD001 normalization ranges to amplify the drift signal)
#   3. Wait for Prometheus scrape
#   4. Trigger a manual drift-check job
#   5. Parse logs and verify:
#      - PSI > 0.2 threshold (drift signal strong)
#      - drift_detected == "True"
#   6. Clean up
#
# Pre-condition: FastAPI on localhost:8000, FD002 + FD001 normalization
# data available, project venv at /root/thesis-infra/.venv.

set -uo pipefail
source "$(dirname "$0")/../_lib.sh"

test_header "Drift detection — fires on FD002 traffic (EC#16 sensitivity)"

REPO="/root/thesis-infra"
NAMESPACE="monitoring"
EXPECTED_MIN_IMAGE_TAG="0.1.4"
FASTAPI_URL="http://localhost:8000"
N_DRIFT_PREDICTIONS=300
PROM_SCRAPE_WAIT=30
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

# FastAPI reachable?
if ! curl -sf "$FASTAPI_URL/" >/dev/null 2>&1; then
  skip "FastAPI not reachable at $FASTAPI_URL" \
       "run scripts/port-forward-all.sh restart"
  exit 0
fi
pass "FastAPI reachable at $FASTAPI_URL"

# FD002 test data + normalization params exist
if [ ! -f "$REPO/data/raw/cmapss/test_FD002.txt" ]; then
  fail "FD002 test data not found at $REPO/data/raw/cmapss/test_FD002.txt"
  exit 1
fi
if [ ! -f "$REPO/data/processed/normalization_params.json" ]; then
  fail "FD001 normalization params not found"
  exit 1
fi
pass "FD002 test data + FD001 normalization params available"

# ---------- 2. Inject drift predictions ----------
info "Injecting $N_DRIFT_PREDICTIONS FD002 drift predictions to FastAPI..."

PYTHON_BIN="$REPO/.venv/bin/python"
if [ ! -x "$PYTHON_BIN" ]; then
  fail "Project venv not found at $PYTHON_BIN"
  exit 1
fi

INJECT_RESULT=$("$PYTHON_BIN" <<PYEOF
import json, time, requests, sys
import numpy as np
import pandas as pd

REPO = "$REPO"
URL = "$FASTAPI_URL/predict"
N = $N_DRIFT_PREDICTIONS

try:
    with open(f"{REPO}/data/processed/normalization_params.json") as f:
        norm = json.load(f)

    cols_meta = ["unit_id", "time_cycle"] + [f"op_setting_{i}" for i in range(1, 4)] + [f"sensor_{i}" for i in range(1, 22)]
    fd002 = pd.read_csv(f"{REPO}/data/raw/cmapss/test_FD002.txt",
                        sep=r"\s+", header=None, names=cols_meta)

    FEATURE_COLS = ["op_setting_1", "op_setting_2",
                    "sensor_2", "sensor_3", "sensor_4", "sensor_7", "sensor_8",
                    "sensor_9", "sensor_11", "sensor_12", "sensor_13", "sensor_14",
                    "sensor_15", "sensor_17", "sensor_20", "sensor_21"]
    feat = fd002[FEATURE_COLS].copy()
    for col in FEATURE_COLS:
        rng = norm[col]["max"] - norm[col]["min"]
        if rng > 0:
            feat[col] = (feat[col] - norm[col]["min"]) / rng
    feat["unit_id"] = fd002["unit_id"].values
    feat["time_cycle"] = fd002["time_cycle"].values

    wins = []
    for _, eng in feat.groupby("unit_id"):
        eng = eng.sort_values("time_cycle")
        arr = eng[FEATURE_COLS].values
        if len(arr) < 30:
            continue
        for s in range(len(arr) - 29):
            wins.append(arr[s:s+30])
    wins = np.array(wins, dtype=np.float32)

    np.random.seed(42)  # deterministic for repeatable test
    sel = np.random.choice(len(wins), size=N, replace=False)

    preds = []
    for i, w in enumerate(wins[sel]):
        r = requests.post(URL, json={"sequence": w.tolist()}, timeout=10)
        r.raise_for_status()
        preds.append(r.json()["rul"])
        time.sleep(0.3)   # ~5min/300

    print(f"OK n={len(preds)} mean={np.mean(preds):.2f} median={np.median(preds):.2f}")
except Exception as e:
    print(f"ERROR {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
)

if echo "$INJECT_RESULT" | grep -q "^OK "; then
  pass "Drift predictions sent: $INJECT_RESULT"
else
  fail "Drift injection failed: $INJECT_RESULT"
  exit 1
fi

# ---------- 3. Wait for Prometheus scrape ----------
info "Waiting ${PROM_SCRAPE_WAIT}s for Prometheus to scrape FastAPI metrics..."
sleep "$PROM_SCRAPE_WAIT"

# ---------- 4. Trigger drift-check job ----------
JOB_NAME="drift-fires-test-$$"
trap "kubectl delete job $JOB_NAME -n $NAMESPACE --ignore-not-found --wait=false >/dev/null 2>&1 || true" EXIT

if ! kubectl create job --from=cronjob/evidently-drift-check \
     -n "$NAMESPACE" "$JOB_NAME" >/dev/null 2>&1; then
  fail "Could not create one-shot drift-check job"
  exit 1
fi
pass "Triggered one-shot job: $JOB_NAME"

info "Waiting for job to complete (max ${JOB_TIMEOUT}s)..."
DEADLINE=$(( $(date +%s) + JOB_TIMEOUT ))
JOB_DONE="no"
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  STATUS=$(kubectl get job "$JOB_NAME" -n "$NAMESPACE" -o json 2>/dev/null)
  if echo "$STATUS" | python3 -c "import sys,json;d=json.load(sys.stdin).get('status',{});sys.exit(0 if d.get('succeeded',0)>=1 else 1)" 2>/dev/null; then
    JOB_DONE="succeeded"
    break
  fi
  if echo "$STATUS" | python3 -c "import sys,json;d=json.load(sys.stdin).get('status',{});sys.exit(0 if d.get('failed',0)>=1 else 1)" 2>/dev/null; then
    JOB_DONE="failed"
    break
  fi
  sleep 3
done
if [ "$JOB_DONE" != "succeeded" ]; then
  fail "Job did not succeed within ${JOB_TIMEOUT}s (status: $JOB_DONE)"
  exit 1
fi
pass "Job completed successfully"

# ---------- 5. Parse logs ----------
LOGS=$(kubectl logs -n "$NAMESPACE" -l "job-name=$JOB_NAME" --tail=50 2>/dev/null)
PSI_LINE=$(echo "$LOGS" | grep "PSI =" | tail -1)
KS_LINE=$(echo "$LOGS" | grep "KS statistic =" | tail -1)
DRIFT_LINE=$(echo "$LOGS" | grep "Drift detected:" | tail -1)

PSI=$(echo "$PSI_LINE" | grep -oE "PSI = [0-9.]+" | grep -oE "[0-9.]+")
KS_PVALUE=$(echo "$KS_LINE" | grep -oE "p-value = [^ ]+" | awk '{print $NF}')
DRIFT_DECISION=$(echo "$DRIFT_LINE" | awk -F': ' '{print $NF}' | tr -d ' ')

info "Parsed metrics:"
info "  PSI:            $PSI"
info "  KS p-value:     $KS_PVALUE"
info "  Drift detected: $DRIFT_DECISION"

# ---------- 6. Assertions ----------

# 6a. KS p-value is finite (EC#16 guard)
if python3 -c "import math; v=float('$KS_PVALUE'); exit(0 if math.isfinite(v) else 1)" 2>/dev/null; then
  pass "KS p-value is finite ($KS_PVALUE)"
else
  fail "KS p-value is NaN — EC#16 regression"
fi

# 6b. PSI exceeds threshold
if python3 -c "exit(0 if float('$PSI') > $PSI_THRESHOLD else 1)" 2>/dev/null; then
  pass "PSI > $PSI_THRESHOLD (drift signal strong)"
else
  fail "PSI ($PSI) below threshold ($PSI_THRESHOLD)" \
       "drift signal too weak — check Prometheus 1h window, may need fresher injection or smaller window"
fi

# 6c. drift_detected == "True"
if [ "$DRIFT_DECISION" = "True" ]; then
  pass "drift_detected = True (correctly fires on FD002)"
else
  fail "drift_detected = $DRIFT_DECISION (expected True)" \
       "drift signal not detected — sensitivity regression"
fi

# ---------- Summary ----------
info ""
info "Test outcome: drift_check correctly fires drift_detected=True"
info "on FD002 traffic. PSI ($PSI) above $PSI_THRESHOLD threshold."
info "EC#16 fix preserves drift detection sensitivity."
