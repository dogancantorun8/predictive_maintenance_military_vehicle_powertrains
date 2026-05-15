#!/bin/bash
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}

pass() { echo -e "    ${GREEN}PASS${NC}  $1"; TESTS_PASSED=$((TESTS_PASSED+1)); }
fail() {
  echo -e "    ${RED}FAIL${NC}  $1"
  if [ "${2:-}" != "" ]; then echo -e "          ${RED}↳${NC} $2"; fi
  TESTS_FAILED=$((TESTS_FAILED+1))
}
skip() {
  echo -e "    ${YELLOW}SKIP${NC}  $1"
  if [ "${2:-}" != "" ]; then echo -e "          ${YELLOW}↳${NC} $2"; fi
  TESTS_SKIPPED=$((TESTS_SKIPPED+1))
}
info() { echo -e "    ${BLUE}INFO${NC}  $1"; }
test_header() { echo ""; echo "  ─── $1 ───"; }

assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3" "expected '$2', got '$1'"; fi
}
assert_contains() {
  if echo "$1" | grep -q "$2"; then pass "$3"; else fail "$3" "'$2' not found in output"; fi
}
assert_command_succeeds() {
  if eval "$1" >/dev/null 2>&1; then pass "$2"; else fail "$2" "command failed: $1"; fi
}
