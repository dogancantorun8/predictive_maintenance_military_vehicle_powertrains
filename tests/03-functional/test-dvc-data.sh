#!/bin/bash
# tests/03-functional/test-dvc-data.sh
# Verifies that C-MAPSS data is tracked by DVC and pushed to MinIO.

set -uo pipefail
source "$(dirname "$0")/../_lib.sh"

test_header "DVC data tracking and MinIO sync"

VENV="/root/thesis-infra/.venv"
DATA_DIR="/root/thesis-infra/data/raw/cmapss"

# Test 1: venv with DVC exists
if [ -x "$VENV/bin/dvc" ]; then
  DVC_VER=$("$VENV/bin/dvc" --version 2>/dev/null)
  pass "Python venv with DVC installed (version $DVC_VER)"
else
  fail "DVC not found at $VENV/bin/dvc"
  exit 1
fi

# Test 2: All 13 C-MAPSS files exist
FILE_COUNT=$(find "$DATA_DIR" -maxdepth 1 -name "*.txt" -type f 2>/dev/null | wc -l)
if [ "$FILE_COUNT" -ge 13 ]; then
  pass "C-MAPSS data files present: $FILE_COUNT .txt files"
else
  fail "Expected 13+ .txt files in $DATA_DIR, found $FILE_COUNT"
fi

# Test 3: DVC metadata file (cmapss.dvc) exists
DVC_FILE="/root/thesis-infra/data/raw/cmapss.dvc"
if [ -f "$DVC_FILE" ]; then
  pass "DVC metadata file exists: data/raw/cmapss.dvc"
else
  fail "Missing DVC metadata file at $DVC_FILE"
  exit 1
fi

# Test 4: DVC metadata file is valid YAML and has 'outs' field with md5
if grep -q "md5:" "$DVC_FILE" && grep -q "outs:" "$DVC_FILE"; then
  pass "DVC metadata is valid (contains md5 and outs)"
else
  fail "DVC metadata file is malformed" "$(cat "$DVC_FILE")"
fi

# Test 5: DVC remote 'minio-remote' is configured
REMOTE_LIST=$(cd /root/thesis-infra && "$VENV/bin/dvc" remote list 2>/dev/null)
if echo "$REMOTE_LIST" | grep -q "minio-remote"; then
  pass "DVC remote 'minio-remote' configured"
else
  fail "DVC remote not configured" "got: $REMOTE_LIST"
fi

# Test 6: DVC remote endpoint points to MinIO
ENDPOINT=$(cd /root/thesis-infra && "$VENV/bin/dvc" config remote.minio-remote.endpointurl 2>/dev/null)
if echo "$ENDPOINT" | grep -q "localhost:9000"; then
  pass "DVC remote endpoint set to MinIO (localhost:9000)"
else
  fail "DVC remote endpoint misconfigured" "got: $ENDPOINT"
fi

# Test 7: Data files are gitignored (NOT in git status)
cd /root/thesis-infra
GITIGNORED=$(git check-ignore data/raw/cmapss/train_FD001.txt 2>/dev/null || echo "")
if [ -n "$GITIGNORED" ]; then
  pass "Raw data files are gitignored (not in git)"
else
  fail "Raw data files are NOT gitignored — git might commit 17 MB of data!"
fi

# Test 8: MinIO has DVC-uploaded objects
MINIO_POD=$(kubectl get pod -n minio -l app=minio -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$MINIO_POD" ]; then
  skip "MinIO pod not available — cannot verify upload"
  exit 0
fi

# Set MinIO alias (idempotent)
kubectl exec -n minio "$MINIO_POD" -- mc alias set local http://localhost:9000 \
  "$(kubectl get secret -n minio minio -o jsonpath='{.data.rootUser}' | base64 -d)" \
  "$(kubectl get secret -n minio minio -o jsonpath='{.data.rootPassword}' | base64 -d)" \
  >/dev/null 2>&1

# Count DVC-uploaded objects in thesis-data/dvc/
DVC_OBJECTS=$(kubectl exec -n minio "$MINIO_POD" -- \
  mc ls --recursive local/thesis-data/dvc/ 2>/dev/null | wc -l)

if [ "$DVC_OBJECTS" -ge 10 ]; then
  pass "MinIO has $DVC_OBJECTS DVC-tracked objects in thesis-data/dvc/"
else
  fail "MinIO has only $DVC_OBJECTS DVC objects, expected 10+" \
       "(run 'dvc push' if not yet pushed)"
fi
