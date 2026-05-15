# Tests — Verification Suite for the Thesis MLOps Platform

Automated, layered tests that verify the MLOps stack after each Ansible
playbook deployment. The suite is intentionally written in pure bash with
`kubectl exec` for in-cluster execution — no Python venv, no external test
runner — so the verification methodology itself is fully reproducible
alongside the infrastructure it tests.

---

## Testing Strategy

A four-tier hierarchical test suite was implemented at `tests/` to verify
the MLOps platform after each Ansible playbook deployment. The hierarchy
mirrors the layered nature of the system: **infrastructure** (Kubernetes
resources), **connectivity** (network and DNS), **functional**
(component-specific read/write operations), and **integration**
(cross-component end-to-end scenarios).

Tests are pure bash scripts using `kubectl exec` for in-cluster execution —
no external dependencies — which means the verification methodology itself
is fully reproducible alongside the infrastructure. Each test follows a
**fail-loud design**: it prints the failed assertion with context, exits
non-zero, and is suitable for CI integration (e.g., as a GitHub Action that
gates `git push` to `main`).

### Test Hierarchy

| Tier | Directory          | Purpose                                              | Typical Cost |
|------|--------------------|------------------------------------------------------|--------------|
| 1    | `01-infra/`        | Pods Running, PVCs Bound, RAM/CPU within budget      | < 5 s        |
| 2    | `02-connectivity/` | Cluster DNS resolution, service-to-service reachability | ~ 30 s    |
| 3    | `03-functional/`   | Each component executes its actual job (R/W, API)    | ~ 1 min      |
| 4    | `99-integration/`  | End-to-end multi-component scenarios                 | ~ 2 min      |

The tiers run from cheapest to most expensive. A failure in tier 1 makes
running tiers 2-4 pointless: there is no reason to test DNS resolution if a
pod isn't Running. The orchestrator preserves this ordering.

### Design Principles

1. **Pure bash, no runtime dependencies.** Tests run from any shell that
   can reach `kubectl`. No `pytest`, no `pip install`, no virtualenv. This
   makes the suite as portable as the kubeconfig itself.

2. **Self-contained per test.** Each `test-*.sh` is a standalone executable
   that sources `_lib.sh` for shared helpers but is otherwise independent.
   You can run a single test, or all of them, or one category — the
   orchestrator just discovers `test-*.sh` files in each tier.

3. **Graceful degradation.** Tests detect their preconditions: if MinIO
   isn't deployed yet, the MinIO tests `SKIP` (yellow) rather than fail.
   This makes the same suite useful both during incremental playbook
   rollout and against the final complete stack.

4. **Fail-loud.** A failing assertion prints the actual vs. expected
   values, the command that failed, and exits with a non-zero status —
   ready for CI gating without modification.

5. **No external state.** Tests create their own temporary objects (table
   names, S3 keys, experiment names — all suffixed with `$(date +%s)`) and
   clean them up afterwards. Re-running the suite has zero side-effects on
   the platform.

---

## Running the Suite

```bash
# Run everything (all four tiers in order)
./tests/run-all.sh

# Run only one tier
./tests/run-all.sh 01-infra
./tests/run-all.sh 03-functional

# Run a single test
./tests/03-functional/test-mlflow-smoke.sh
```

### Output Format

Each test prints color-coded results:

| Marker | Color  | Meaning                                            |
|--------|--------|----------------------------------------------------|
| `PASS` | green  | Assertion held                                     |
| `FAIL` | red    | Assertion did not hold (reason printed underneath) |
| `SKIP` | yellow | Underlying component is not deployed yet           |
| `INFO` | blue   | Informational only (pod name, run ID, etc.)       |

Example:
---

## Current Test Inventory

### Tier 1 — Infrastructure (`01-infra/`)

| Test                       | Verifies                                                 |
|----------------------------|----------------------------------------------------------|
| `test-node-ready.sh`       | `kubectl get nodes` reports `mlops-master` as Ready      |
| `test-namespaces.sh`       | All deployed namespaces have all pods in Running state   |
| `test-pvcs.sh`             | Every PersistentVolumeClaim is `Bound` (none Pending)    |

### Tier 2 — Connectivity (`02-connectivity/`)

| Test                       | Verifies                                                 |
|----------------------------|----------------------------------------------------------|
| `test-dns-resolution.sh`   | Cluster DNS resolves each deployed `<svc>.<ns>.svc.cluster.local` |

### Tier 3 — Functional (`03-functional/`)

| Test                       | Verifies                                                 |
|----------------------------|----------------------------------------------------------|
| `test-minio-rw.sh`         | All three thesis buckets exist + write/read/delete cycle |
| `test-postgres-rw.sh`      | `mlflow` + `kfp` databases exist + table create/insert/drop |
| `test-mlflow-smoke.sh`     | MLflow logs param, metric, and artifact (DB + S3 verified) |
| `test-kfp-api.sh`          | KFP API server `/apis/v1beta1/healthz` returns OK        |

### Tier 4 — Integration (`99-integration/`)

End-to-end scenarios are added here as the platform grows (e.g., a full
"train → log to MLflow → trigger KFP pipeline → deploy via FastAPI" test
will live here once Playbook 09 is in place).

---

## Writing a New Test

Templates and helpers are designed to keep new tests under 30 lines of
script.

```bash
#!/bin/bash
set -uo pipefail
source "$(dirname "$0")/../_lib.sh"

test_header "Your test description"

# 1. Pre-flight: skip if the component isn't deployed yet
if ! kubectl get deployment <name> -n <ns> >/dev/null 2>&1; then
  skip "Component not deployed yet"
  exit 0
fi

# 2. Use the helpers
pass "Something worked"
fail "Something didn't work" "optional detail"
assert_eq  "$actual" "expected" "Description"
assert_contains "$haystack" "$needle" "Description"
assert_command_succeeds "kubectl exec ..." "Description"
```

Mark the script executable and the orchestrator will pick it up
automatically:

```bash
chmod +x tests/<tier>/test-<name>.sh
```

---

## Relation to `scripts/healthcheck.sh`

The repository contains two related but distinct verification tools:

- **`scripts/healthcheck.sh`** — single-screen "is everything roughly
  alive?" snapshot. Quick visual check, runs in under 5 seconds. Used
  before/after Ansible runs to confirm baseline.

- **`tests/run-all.sh`** — comprehensive correctness suite. Verifies that
  components not only exist but actually perform their job (read/write,
  API endpoints, cross-component flows). Used for deeper verification,
  regression testing, and as a CI gate.

The two are intentionally separate: a fast eyeball check is different from
a rigorous correctness test, and conflating them dilutes both.

---

## Future Work

- **CI integration**: GitHub Actions workflow that SSHes into the Hetzner
  VM, runs `./tests/run-all.sh`, and gates `git push` to `main` on the
  result.
- **Drift-recovery scenario test** (tier 4, planned): inject synthetic
  drift into FastAPI traffic, verify Evidently detects it, verify
  Alertmanager fires the webhook, verify KFP launches a retraining
  pipeline, measure end-to-end **drift-to-recovery latency** — the
  thesis's primary measured metric.
