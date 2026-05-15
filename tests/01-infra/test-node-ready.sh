#!/bin/bash
set -uo pipefail
source "$(dirname "$0")/../_lib.sh"

test_header "Kubernetes node is Ready"

NODE_STATUS=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}')
assert_eq "$NODE_STATUS" "Ready" "Node 'mlops-master' is Ready"
