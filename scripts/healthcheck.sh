#!/bin/bash
# scripts/healthcheck.sh
# Quick health check for the thesis-infra MLOps stack.
# Run anytime to see what's working and what's broken.

set +e  # don't exit on first error, we want to see all results

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

pass() { echo -e "  ${GREEN}OK${NC}    $1"; }
fail() { echo -e "  ${RED}FAIL${NC}  $1"; }
warn() { echo -e "  ${YELLOW}WARN${NC}  $1"; }

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "=============================================="
echo "  thesis-infra healthcheck"
echo "  $(date)"
echo "=============================================="
echo ""

# --- Node ---
echo "[1] Node status"
NODE_STATUS=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}')
if [ "$NODE_STATUS" = "Ready" ]; then
  pass "Node mlops-master Ready"
else
  fail "Node not Ready (status: $NODE_STATUS)"
fi
echo ""

# --- Namespaces ---
echo "[2] Namespaces and pods"
for ns in kube-system minio mlops kubeflow monitoring; do
  if kubectl get ns $ns >/dev/null 2>&1; then
    not_ready=$(kubectl get pods -n $ns --no-headers 2>/dev/null | grep -v -E 'Running|Completed' | wc -l)
    total=$(kubectl get pods -n $ns --no-headers 2>/dev/null | wc -l)
    if [ $total -eq 0 ]; then
      warn "Namespace $ns exists but has no pods (not yet deployed?)"
    elif [ $not_ready -eq 0 ]; then
      pass "Namespace $ns: $total/$total pods healthy"
    else
      fail "Namespace $ns: $not_ready of $total pods NOT ready"
      kubectl get pods -n $ns --no-headers | grep -v -E 'Running|Completed'
    fi
  else
    warn "Namespace $ns does not exist (not yet deployed?)"
  fi
done
echo ""

# --- PVCs ---
echo "[3] Persistent Volume Claims"
PVC_PENDING=$(kubectl get pvc -A --no-headers 2>/dev/null | grep -v Bound | wc -l)
PVC_TOTAL=$(kubectl get pvc -A --no-headers 2>/dev/null | wc -l)
if [ $PVC_PENDING -eq 0 ] && [ $PVC_TOTAL -gt 0 ]; then
  pass "All $PVC_TOTAL PVCs Bound"
elif [ $PVC_TOTAL -eq 0 ]; then
  warn "No PVCs found yet"
else
  fail "$PVC_PENDING of $PVC_TOTAL PVCs not Bound"
  kubectl get pvc -A --no-headers | grep -v Bound
fi
echo ""

# --- MinIO functional test ---
echo "[4] MinIO functional test"
if kubectl get deploy/minio -n minio >/dev/null 2>&1; then
  if kubectl exec -n minio deploy/minio -- mc alias set local http://localhost:9000 \
       "$(kubectl get secret -n minio minio -o jsonpath='{.data.rootUser}' | base64 -d)" \
       "$(kubectl get secret -n minio minio -o jsonpath='{.data.rootPassword}' | base64 -d)" \
       >/dev/null 2>&1; then
    BUCKETS=$(kubectl exec -n minio deploy/minio -- mc ls local/ 2>/dev/null | awk '{print $NF}' | tr -d '/' | sort | tr '\n' ' ')
    if echo "$BUCKETS" | grep -q "thesis-data" && \
       echo "$BUCKETS" | grep -q "thesis-mlflow" && \
       echo "$BUCKETS" | grep -q "thesis-models"; then
      pass "MinIO reachable, 3 buckets present: $BUCKETS"
    else
      fail "MinIO reachable but expected buckets missing. Found: $BUCKETS"
    fi
  else
    fail "MinIO mc alias failed"
  fi
else
  warn "MinIO not deployed"
fi
echo ""

# --- PostgreSQL functional test ---
echo "[5] PostgreSQL functional test"
if kubectl get pod postgres-0 -n mlops >/dev/null 2>&1; then
  PG_DBS=$(kubectl exec -n mlops postgres-0 -- psql -U postgres -tAc \
    "SELECT datname FROM pg_database WHERE datname IN ('mlflow','kfp');" 2>/dev/null | tr '\n' ' ')
  if echo "$PG_DBS" | grep -q "mlflow" && echo "$PG_DBS" | grep -q "kfp"; then
    pass "PostgreSQL reachable, both databases present: $PG_DBS"
  else
    fail "PostgreSQL reachable but mlflow/kfp databases missing. Found: $PG_DBS"
  fi
else
  warn "PostgreSQL not deployed"
fi
echo ""

# --- Resource usage ---
echo "[6] Resource usage"
NODE_MEM=$(kubectl top nodes --no-headers 2>/dev/null | awk '{print $4}' | tr -d '%')
NODE_CPU=$(kubectl top nodes --no-headers 2>/dev/null | awk '{print $3}' | tr -d '%')
if [ -n "$NODE_MEM" ]; then
  if [ "$NODE_MEM" -gt 85 ]; then
    fail "RAM usage HIGH: ${NODE_MEM}% (CPU: ${NODE_CPU}%)"
  else
    pass "RAM usage OK: ${NODE_MEM}% (CPU: ${NODE_CPU}%)"
  fi
else
  warn "metrics-server not ready yet"
fi
echo ""

echo "=============================================="
echo "  Healthcheck complete"
echo "=============================================="
