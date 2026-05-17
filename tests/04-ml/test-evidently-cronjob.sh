#!/bin/bash
# tests/04-ml/test-evidently-cronjob.sh
# Verifies the Evidently drift detection CronJob end-to-end.
#
# This test triggers a one-shot job from the CronJob template (rather
# than waiting for the hourly schedule), captures its logs, and verifies
# that the full chain works:
#   baseline.json -> ConfigMap mount -> drift_check.py inference ->
#   Prometheus query -> PSI + KS computation -> Pushgateway -> Prometheus
#
# Asserted behaviour:
#   1. CronJob, ConfigMap, image are all deployed
#   2. The triggered job runs to completion (Succeeded status)
#   3. Logs contain expected drift metrics (PSI, KS p-value, drift decision)
#   4. Metrics were pushed and visible in Prometheus
#
# The test cleans up its triggered job (CronJob scheduled runs unaffected).

set -uo pipefail
source "$(dirname "$0")/../_lib.sh"

test_header "Evidently drift-check CronJob (end-to-end integration)"

NAMESPACE="monitoring"
CRONJOB="evidently-drift-check"
JOB_NAME="drift-check-test-$$"
TIMEOUT_SECONDS=120

# ---------- Preconditions ----------

if ! kubectl get cronjob "$CRONJOB" -n "$NAMESPACE" >/dev/null 2>&1; then
  skip "CronJob $CRONJOB not deployed in namespace $NAMESPACE" \
       "run: ansible-playbook playbooks/12-evidently.yml --ask-vault-pass"
  exit 0
fi
pass "CronJob '$CRONJOB' is deployed in '$NAMESPACE'"

if ! kubectl get configmap evidently-baseline -n "$NAMESPACE" >/dev/null 2>&1; then
  fail "ConfigMap evidently-baseline not found" \
       "run Playbook 12 to create it"
  exit 1
fi
pass "ConfigMap 'evidently-baseline' exists"

CRONJOB_IMAGE=$(kubectl get cronjob "$CRONJOB" -n "$NAMESPACE" \
  -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].image}' 2>/dev/null)
if [ -z "$CRONJOB_IMAGE" ]; then
  fail "CronJob image reference not readable"
  exit 1
fi
pass "CronJob configured with image: $CRONJOB_IMAGE"

# ---------- Trigger a one-shot job ----------

info "Triggering manual job '$JOB_NAME' from CronJob template..."
if ! kubectl create job --from="cronjob/$CRONJOB" -n "$NAMESPACE" "$JOB_NAME" >/dev/null 2>&1; then
  fail "Could not create job from CronJob template"
  exit 1
fi
pass "Job '$JOB_NAME' created"

cleanup() {
  kubectl delete job "$JOB_NAME" -n "$NAMESPACE" --ignore-not-found=true \
    --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ---------- Wait for completion ----------

info "Waiting for job to complete (timeout: ${TIMEOUT_SECONDS}s)..."
END=$(($(date +%s) + TIMEOUT_SECONDS))
JOB_STATUS="Unknown"

while [ "$(date +%s)" -lt "$END" ]; do
  SUCCEEDED=$(kubectl get job "$JOB_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.succeeded}' 2>/dev/null)
  FAILED=$(kubectl get job "$JOB_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.failed}' 2>/dev/null)

  if [ "$SUCCEEDED" = "1" ]; then
    JOB_STATUS="Succeeded"
    break
  fi
  if [ -n "$FAILED" ] && [ "$FAILED" != "0" ]; then
    JOB_STATUS="Failed"
    break
  fi
  sleep 3
done

if [ "$JOB_STATUS" = "Succeeded" ]; then
  pass "Job completed successfully"
elif [ "$JOB_STATUS" = "Failed" ]; then
  fail "Job failed"
  echo "    --- Pod logs ---"
  kubectl logs -n "$NAMESPACE" -l "job-name=$JOB_NAME" --tail=30 2>/dev/null \
    | sed 's/^/      /'
  exit 1
else
  fail "Job did not complete within ${TIMEOUT_SECONDS}s"
  exit 1
fi

# ---------- Capture and validate logs ----------

LOGS=$(kubectl logs -n "$NAMESPACE" -l "job-name=$JOB_NAME" --tail=200 2>/dev/null)

if [ -z "$LOGS" ]; then
  fail "No logs captured from job pod"
  exit 1
fi

if echo "$LOGS" | grep -q "Loading baseline from"; then
  pass "Job loaded baseline from mounted ConfigMap"
else
  fail "No 'Loading baseline' message in logs"
fi

if echo "$LOGS" | grep -q "Fetching production histogram"; then
  pass "Job queried Prometheus for production data"
else
  fail "No 'Fetching production histogram' message in logs"
fi

PSI_LINE=$(echo "$LOGS" | grep -oP 'PSI = \K[0-9.-]+' | head -1)
if [ -n "$PSI_LINE" ]; then
  pass "PSI computed: $PSI_LINE"
else
  fail "PSI value not found in logs"
fi

KS_LINE=$(echo "$LOGS" | grep -oP 'p-value = \K[0-9.eE+-]+' | head -1)
if [ -n "$KS_LINE" ]; then
  pass "KS p-value computed: $KS_LINE"
else
  fail "KS p-value not found in logs"
fi

DRIFT_DECISION=$(echo "$LOGS" | grep -oP 'Drift detected: \K\w+' | head -1)
if [ -n "$DRIFT_DECISION" ]; then
  pass "Drift decision logged: $DRIFT_DECISION"
else
  fail "Drift decision not found in logs"
fi

if echo "$LOGS" | grep -q "Metrics pushed to"; then
  pass "Job pushed metrics to Pushgateway"
else
  fail "No 'Metrics pushed' confirmation in logs"
fi

# ---------- Prometheus verification ----------

info "Waiting 15s for Prometheus to scrape Pushgateway..."
sleep 15

PROM_PSI=$(kubectl run "drift-test-prom-$$" -n "$NAMESPACE" \
  --rm -i --restart=Never --image=curlimages/curl:8.10.1 --quiet -- \
  curl -sG "http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090/api/v1/query" \
  --data-urlencode 'query=drift_psi' 2>/dev/null \
  | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    if d.get('status') == 'success' and d['data']['result']:
        print(d['data']['result'][0]['value'][1])
    else:
        print('NO_DATA')
except Exception:
    print('PARSE_ERROR')
" 2>/dev/null)

if [ -n "$PROM_PSI" ] && [ "$PROM_PSI" != "NO_DATA" ] && [ "$PROM_PSI" != "PARSE_ERROR" ]; then
  pass "drift_psi metric visible in Prometheus: $PROM_PSI"
else
  fail "drift_psi metric not found in Prometheus" \
       "result: $PROM_PSI — pushgateway scrape may be delayed"
fi

PROM_DETECTED=$(kubectl run "drift-test-detect-$$" -n "$NAMESPACE" \
  --rm -i --restart=Never --image=curlimages/curl:8.10.1 --quiet -- \
  curl -sG "http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090/api/v1/query" \
  --data-urlencode 'query=drift_detected' 2>/dev/null \
  | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    if d.get('status') == 'success' and d['data']['result']:
        print(d['data']['result'][0]['value'][1])
    else:
        print('NO_DATA')
except Exception:
    print('PARSE_ERROR')
" 2>/dev/null)

if [ -n "$PROM_DETECTED" ] && [ "$PROM_DETECTED" != "NO_DATA" ]; then
  pass "drift_detected metric visible in Prometheus: $PROM_DETECTED"
else
  info "drift_detected metric not yet in Prometheus (Pushgateway scrape can take up to 30s)"
fi

# ---------- Summary ----------

info ""
info "Drift detection summary:"
info "  PSI value:      $PSI_LINE"
info "  KS p-value:     $KS_LINE"
info "  Drift detected: $DRIFT_DECISION"
info ""
info "View live drift score:"
info "  http://localhost:9090/graph?query=drift_psi"
info ""
info "If drift is detected, an alert was fired to Alertmanager:"
info "  http://localhost:9093"
