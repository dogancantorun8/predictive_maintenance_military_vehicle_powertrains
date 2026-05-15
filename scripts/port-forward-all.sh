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
    # Port is in use — check if it's our kubectl
    local pid=$(ss -tlnp 2>/dev/null | grep ":${local_port} " | grep -oP 'pid=\K[0-9]+' | head -1)
    if [ -n "$pid" ] && ps -p "$pid" -o cmd= 2>/dev/null | grep -q "kubectl"; then
      echo "  OK    $label — http://localhost:${local_port} (already running, PID $pid)"
    else
      echo "  BUSY  $label — port ${local_port} in use by non-kubectl process. Run: $0 stop"
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
    echo "=== Active kubectl port-forwards ==="
    # Find PIDs holding our ports, then resolve each to its kubectl command
    local_pids=$(ss -tlnp 2>/dev/null \
      | grep -E ":(3000|5000|8000|8080|9000|9001|9090|9093) " \
      | grep -oP 'pid=\K[0-9]+' | sort -u)
    if [ -z "$local_pids" ]; then
      echo "(none)"
    else
      for pid in $local_pids; do
        cmd=$(ps -p "$pid" -o cmd= 2>/dev/null)
        etime=$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ')
        if [ -n "$cmd" ] && echo "$cmd" | grep -q "port-forward"; then
          echo "  PID $pid  uptime $etime  $cmd"
        fi
      done
    fi
    echo ""
    echo "=== Listening ports ==="
    ss -tln 2>/dev/null | grep -E ":(8080|9000|9001|5000|3000|9090|9093|8000) " || echo "(none)"
    ;;
  stop)
    echo "Stopping all port-forwards..."
    # Find PIDs of kubectl processes that hold MLOps ports, kill them
    pids=$(ss -tlnp 2>/dev/null \
      | grep -E ":(3000|5000|8000|8080|9000|9001|9090|9093) " \
      | grep -oP 'pid=\K[0-9]+' | sort -u)
    if [ -n "$pids" ]; then
      for pid in $pids; do
        cmd=$(ps -p "$pid" -o cmd= 2>/dev/null)
        if echo "$cmd" | grep -q "kubectl"; then
          kill "$pid" 2>/dev/null
        fi
      done
      sleep 1
      # Force-kill anything that remained
      for pid in $pids; do
        if kill -0 "$pid" 2>/dev/null; then
          kill -9 "$pid" 2>/dev/null
        fi
      done
    fi
    pkill -f "kubectl port-forward" 2>/dev/null
    echo "Done."
    ;;
  restart)
    $0 stop
    sleep 1
    $0 start
    ;;
  start|"")
    echo "=== Starting port-forwards ==="
    forward 9001 minio      minio-console                                  9001 "MinIO Console"
    forward 9000 minio      minio                                          9000 "MinIO S3 API"
    forward 8080 kubeflow   ml-pipeline-ui                                 80   "Kubeflow Pipelines UI"
    forward 5000 mlops      mlflow                                         5000 "MLflow"
    forward 3000 monitoring prometheus-grafana                             80   "Grafana"
    forward 9090 monitoring prometheus-kube-prometheus-prometheus          9090 "Prometheus"
    forward 9093 monitoring prometheus-kube-prometheus-alertmanager        9093 "Alertmanager"
    forward 8000 mlops      fastapi                                        8000 "FastAPI"
    echo ""
    echo "Useful: $0 status | $0 stop | $0 restart"
    ;;
  *)
    echo "Usage: $0 [start|stop|status|restart]"
    exit 1
    ;;
esac
