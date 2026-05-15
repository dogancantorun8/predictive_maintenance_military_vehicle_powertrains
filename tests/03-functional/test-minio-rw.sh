#!/bin/bash
set -uo pipefail
source "$(dirname "$0")/../_lib.sh"

test_header "MinIO read/write/delete cycle"

if ! kubectl get deployment minio -n minio >/dev/null 2>&1; then
  skip "MinIO not deployed"
  exit 0
fi

MINIO_POD=$(kubectl get pod -n minio -l app=minio -o jsonpath='{.items[0].metadata.name}')
TEST_KEY="ci-test-$(date +%s).txt"
TEST_CONTENT="test-$(date +%s%N)"

kubectl exec -n minio "$MINIO_POD" -- mc alias set local http://localhost:9000 \
  "$(kubectl get secret -n minio minio -o jsonpath='{.data.rootUser}' | base64 -d)" \
  "$(kubectl get secret -n minio minio -o jsonpath='{.data.rootPassword}' | base64 -d)" \
  >/dev/null 2>&1

# Test: list buckets
BUCKETS=$(kubectl exec -n minio "$MINIO_POD" -- mc ls local/ 2>/dev/null \
  | awk '{print $NF}' | tr -d '/' | sort | tr '\n' ' ')
for b in thesis-data thesis-mlflow thesis-models; do
  if echo "$BUCKETS" | grep -q "$b"; then
    pass "Bucket exists: $b"
  else
    fail "Bucket missing: $b"
  fi
done

# Test: write, read, delete
kubectl exec -n minio "$MINIO_POD" -- sh -c "
  echo '$TEST_CONTENT' > /tmp/$TEST_KEY
  mc cp /tmp/$TEST_KEY local/thesis-data/$TEST_KEY >/dev/null 2>&1
" && pass "Wrote $TEST_KEY to thesis-data" || fail "Write failed"

READ_CONTENT=$(kubectl exec -n minio "$MINIO_POD" -- mc cat "local/thesis-data/$TEST_KEY" 2>/dev/null)
assert_eq "$READ_CONTENT" "$TEST_CONTENT" "Read content matches written content"

kubectl exec -n minio "$MINIO_POD" -- mc rm "local/thesis-data/$TEST_KEY" >/dev/null 2>&1 \
  && pass "Deleted $TEST_KEY (cleanup)" || fail "Delete failed"
