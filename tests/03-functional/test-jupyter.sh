#!/bin/bash
# tests/03-functional/test-jupyter.sh
# Verifies Jupyter Lab systemd service is running and reachable.

set -uo pipefail
source "$(dirname "$0")/../_lib.sh"

test_header "Jupyter Lab systemd service"

# Test 1: systemd service exists and is active
if systemctl is-active jupyter-lab >/dev/null 2>&1; then
  pass "jupyter-lab.service is active"
else
  fail "jupyter-lab.service not active" "$(systemctl status jupyter-lab 2>&1 | head -3)"
  exit 1
fi

# Test 2: Listening on configured port
JUPYTER_PORT=$(grep -oP 'c\.ServerApp\.port = \K[0-9]+' /root/.jupyter/jupyter_lab_config.py 2>/dev/null)
if [ -z "$JUPYTER_PORT" ]; then
  fail "Could not determine jupyter port from config"
  exit 1
fi

info "Configured port: $JUPYTER_PORT"

if ss -tln 2>/dev/null | grep -q ":${JUPYTER_PORT} "; then
  pass "Jupyter listening on port $JUPYTER_PORT"
else
  fail "Nothing listening on port $JUPYTER_PORT"
fi

# Test 3: /lab endpoint reachable
RESPONSE=$(curl -sS -o /dev/null -w "%{http_code}" "http://localhost:${JUPYTER_PORT}/lab" 2>/dev/null || echo "000")
if [ "$RESPONSE" = "200" ]; then
  pass "Jupyter /lab returns HTTP 200"
else
  fail "Jupyter /lab returned HTTP $RESPONSE"
fi

# Test 4: Notebooks directory exists
if [ -d "/root/thesis-infra/notebooks" ]; then
  pass "Notebooks directory exists: /root/thesis-infra/notebooks"
else
  fail "Notebooks directory missing"
fi
