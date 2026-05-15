#!/bin/bash
# tests/03-functional/test-mlflow-smoke.sh
# Verifies that MLflow can:
#   1) connect to PostgreSQL backend (creates experiment)
#   2) log parameters and metrics (writes to DB)
#   3) log artifacts to MinIO (writes to S3 bucket)
#
# This is the canonical "MLOps platform works end-to-end" test.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

test_header "MLflow smoke test (PostgreSQL + MinIO integration)"

# --- Pre-flight: MLflow pod must exist ---
if ! kubectl get deployment mlflow -n mlops >/dev/null 2>&1; then
  skip "MLflow not deployed yet"
  exit 0
fi

MLFLOW_POD=$(kubectl get pod -n mlops -l app.kubernetes.io/name=mlflow \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$MLFLOW_POD" ]; then
  fail "Could not find MLflow pod"
  exit 1
fi

info "Using MLflow pod: $MLFLOW_POD"

# --- Run the smoke test inside the pod ---
EXPERIMENT_NAME="ci-smoke-$(date +%s)"
RUN_NAME="ci-run"

SMOKE_OUTPUT=$(kubectl exec -n mlops "$MLFLOW_POD" -- python3 -c "
import mlflow
mlflow.set_tracking_uri('http://localhost:5000')
mlflow.set_experiment('$EXPERIMENT_NAME')
with mlflow.start_run(run_name='$RUN_NAME') as run:
    mlflow.log_param('source', 'test-mlflow-smoke.sh')
    mlflow.log_metric('val_rmse', 16.4)
    with open('/tmp/ci-test.txt', 'w') as f:
        f.write('end-to-end test artifact')
    mlflow.log_artifact('/tmp/ci-test.txt')
    print('RUN_ID=' + run.info.run_id)
    print('EXP_ID=' + run.info.experiment_id)
" 2>&1)

if echo "$SMOKE_OUTPUT" | grep -q "RUN_ID="; then
  pass "MLflow logged param, metric, and artifact"
  RUN_ID=$(echo "$SMOKE_OUTPUT" | grep RUN_ID= | cut -d= -f2)
  EXP_ID=$(echo "$SMOKE_OUTPUT" | grep EXP_ID= | cut -d= -f2)
  info "Run ID: $RUN_ID"
  info "Experiment ID: $EXP_ID"
else
  fail "MLflow smoke test failed" "$SMOKE_OUTPUT"
  exit 1
fi

# --- Verify metadata in PostgreSQL ---
PG_RESULT=$(kubectl exec -n mlops postgres-0 -- psql -U postgres -d mlflow -tAc \
  "SELECT name FROM experiments WHERE name = '$EXPERIMENT_NAME';" 2>/dev/null)

if [ "$PG_RESULT" = "$EXPERIMENT_NAME" ]; then
  pass "Experiment metadata persisted to PostgreSQL"
else
  fail "Experiment NOT found in PostgreSQL" "got: '$PG_RESULT'"
fi

# --- Verify artifact in MinIO ---
MINIO_POD=$(kubectl get pod -n minio -l app=minio -o jsonpath='{.items[0].metadata.name}')
ARTIFACT_PATH="thesis-mlflow/${EXP_ID}/${RUN_ID}/artifacts/ci-test.txt"

# Set mc alias (idempotent)
kubectl exec -n minio "$MINIO_POD" -- mc alias set local http://localhost:9000 \
  "$(kubectl get secret -n minio minio -o jsonpath='{.data.rootUser}' | base64 -d)" \
  "$(kubectl get secret -n minio minio -o jsonpath='{.data.rootPassword}' | base64 -d)" \
  >/dev/null 2>&1

if kubectl exec -n minio "$MINIO_POD" -- mc ls "local/$ARTIFACT_PATH" >/dev/null 2>&1; then
  pass "Artifact persisted to MinIO ($ARTIFACT_PATH)"
else
  fail "Artifact NOT found in MinIO at $ARTIFACT_PATH"
fi
