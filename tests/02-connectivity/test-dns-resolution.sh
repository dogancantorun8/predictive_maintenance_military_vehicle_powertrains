#!/bin/bash
set -uo pipefail
source "$(dirname "$0")/../_lib.sh"

test_header "Cluster DNS resolution"

for svc_fqdn in \
  "minio.minio.svc.cluster.local" \
  "postgres.mlops.svc.cluster.local" \
  "mlflow.mlops.svc.cluster.local" \
  "fastapi.mlops.svc.cluster.local" \
  "ml-pipeline.kubeflow.svc.cluster.local" \
  "prometheus-grafana.monitoring.svc.cluster.local" \
  "prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local" \
  "prometheus-kube-prometheus-alertmanager.monitoring.svc.cluster.local"
do
  ns=$(echo "$svc_fqdn" | cut -d. -f2)
  svc=$(echo "$svc_fqdn" | cut -d. -f1)
  if ! kubectl get svc -n "$ns" "$svc" >/dev/null 2>&1; then
    skip "$svc_fqdn (service not deployed)"
    continue
  fi
  RESULT=$(kubectl run dns-test-$$ --rm -i --restart=Never --image=busybox:1.36 \
    --quiet -- nslookup "$svc_fqdn" 2>&1 | grep -c "Address" || true)
  if [ "$RESULT" -gt 0 ]; then
    pass "DNS resolves: $svc_fqdn"
  else
    fail "DNS did NOT resolve: $svc_fqdn"
  fi
done
