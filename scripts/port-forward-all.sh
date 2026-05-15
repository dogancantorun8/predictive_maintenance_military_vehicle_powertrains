#!/bin/bash
# scripts/port-forward-all.sh
# Starts kubectl port-forward for all thesis MLOps UIs in the background.

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

forward() {
  local local_port=$1 ns=$2 svc=$3 remote_port=$4 label=$5

  if ! kubectl get svc -n "$ns" "$svc" >/dev/null 2>&1; then
    echo "  SKIP  $label — svc/$svc not found in $ns (not yet deployed)"
    return
  fi

  if ss -tln 2>/dev/null | grep -q ":${local_port} "; then
    if pgrep -f "port-forward.*${ns}.*${svc}.*${local_port}" >/dev/null; then
      echo "  OK    $label — http://localhost:${local_port} (already running)"
    else
      echo "  BUSY  $label — port ${local_port} in use by another process. Run: $0 stop"
    fi
    return
  fi

  nohup kubectl port-forward -n "$ns" "svc/$svc" "${local_port}:${remote_port}" \
    > "/tmp/pf-${svc}.log" 2>&1 &
  disown 2>/dev/null

  sleep 2
  if ss -tln 2>/dev/null | grep -q ":${local_port} "; then
    echo "  OK    $label — http://localhost:${local_port}"
  else
    echo "  FAIL  $label — see /tmp/pf-${svc}.log"
    tail -2 "/tmp/pf-${svc}.log" | sed 's/^/         /'
  fi
}

case "${1:-start}" in
  status)
    echo "=== Active port-forwards ==="
    if ! pgrep -f "kubectl port-forward" >/dev/null; then
      echo "(none)"
    else
      ps -eo pid,etime,cmd | grep "kubectl port-forward" | grep -v grep
    fi
    echo ""
    echo "=== Listening ports ==="
    ss -tln 2>/dev/null | grep -E ":(8080|9000|9001|5000|3000|9090|8000) " || echo "(none)"
    ;;

  stop)
    echo "Stopping all port-forwards..."
    pkill -f "kubectl port-forward" 2>/dev/null
    sleep 1
    if pgrep -f "kubectl port-forward" >/dev/null; then
      pkill -9 -f "kubectl port-forward" 2>/dev/null
    fi
    echo "Done."
    ;;

  restart)
    $0 stop
    sleep 1
    $0 start
    ;;

  start|"")
    echo "=== Starting port-forwards ==="
    forward 9001 minio      minio-console                   9001  "MinIO Console"
    forward 9000 minio      minio                           9000  "MinIO S3 API"
    forward 8080 kubeflow   ml-pipeline-ui                  80    "Kubeflow Pipelines UI"
    forward 5000 mlops      mlflow                          5000  "MLflow"
    forward 3000 monitoring grafana                         80    "Grafana"
    forward 9090 monitoring prometheus-kube-prometheus-prom 9090  "Prometheus"
    forward 8000 mlops      fastapi                         8000  "FastAPI"
    echo ""
    echo "Useful: $0 status | $0 stop | $0 restart"
    ;;

  *)
    echo "Usage: $0 [start|stop|status|restart]"
    exit 1
    ;;
esac
