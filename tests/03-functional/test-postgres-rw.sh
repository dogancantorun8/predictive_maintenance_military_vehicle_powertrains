#!/bin/bash
set -uo pipefail
source "$(dirname "$0")/../_lib.sh"

test_header "PostgreSQL read/write/drop cycle"

if ! kubectl get pod postgres-0 -n mlops >/dev/null 2>&1; then
  skip "PostgreSQL not deployed"
  exit 0
fi

# Test: list databases
PG_DBS=$(kubectl exec -n mlops postgres-0 -- psql -U postgres -tAc \
  "SELECT datname FROM pg_database WHERE datname IN ('mlflow','kfp');" 2>/dev/null \
  | tr '\n' ' ')
for db in mlflow kfp; do
  if echo "$PG_DBS" | grep -q "$db"; then
    pass "Database exists: $db"
  else
    fail "Database missing: $db"
  fi
done

# Test: write/read/drop a temp table
TABLE_NAME="ci_healthcheck_$(date +%s)"
kubectl exec -n mlops postgres-0 -- psql -U postgres -d mlflow -c "
CREATE TABLE $TABLE_NAME (id SERIAL PRIMARY KEY, msg TEXT);
INSERT INTO $TABLE_NAME (msg) VALUES ('e2e-test');
" >/dev/null 2>&1 && pass "Table create + insert" || fail "Create/insert failed"

ROW_COUNT=$(kubectl exec -n mlops postgres-0 -- psql -U postgres -d mlflow -tAc \
  "SELECT COUNT(*) FROM $TABLE_NAME;" 2>/dev/null | tr -d ' ')
assert_eq "$ROW_COUNT" "1" "Row count matches after insert"

kubectl exec -n mlops postgres-0 -- psql -U postgres -d mlflow -c \
  "DROP TABLE $TABLE_NAME;" >/dev/null 2>&1 && pass "Table dropped (cleanup)" || fail "Drop failed"
