# First Look Guide

Operational quick reference for the thesis-infra MLOps stack.
**Everything you need to start, verify, and access the platform — in one page.**

---

## 0. Connect to the VM

```bash
# From your laptop (VSCode Remote-SSH does this for you):
ssh root@<VM_IP>
cd /root/thesis-infra
```

---

## 1. Start Port-Forwards (access from your laptop browser)

```bash
./scripts/port-forward-all.sh           # start all 8 services
./scripts/port-forward-all.sh status    # check what's running
./scripts/port-forward-all.sh stop      # kill all forwards
./scripts/port-forward-all.sh restart   # stop + start
```

---

## 2. Access Endpoints

### Browser URLs (after port-forward is running)

| Service              | URL                       | Login                                  |
|----------------------|---------------------------|----------------------------------------|
| MinIO Console        | http://localhost:9001     | `thesisadmin` + vault MinIO password   |
| MinIO S3 API         | http://localhost:9000     | machine-only — browser redirects       |
| Kubeflow Pipelines   | http://localhost:8080     | none                                   |
| MLflow               | http://localhost:5000     | none                                   |
| Grafana              | http://localhost:3000     | `admin` + vault Grafana password       |
| Prometheus           | http://localhost:9090     | none                                   |
| Alertmanager         | http://localhost:9093     | none                                   |
| FastAPI root         | http://localhost:8000     | none (JSON service info)               |
| FastAPI Swagger UI   | http://localhost:8000/docs | none (interactive API)                |
| FastAPI metrics      | http://localhost:8000/metrics | none (Prometheus format)            |

### Get the Grafana password (from encrypted vault)

```bash
ansible-vault view inventory/group_vars/vault.yml | grep grafana
```

Vault password is the one you set when running Playbooks 04+.

### Cluster-internal addresses (for pod-to-pod traffic)

These are the addresses your applications use, **not your browser**.

| Service          | Internal address                                                       |
|------------------|------------------------------------------------------------------------|
| MinIO S3         | `http://minio.minio.svc.cluster.local:9000`                            |
| PostgreSQL       | `postgres.mlops.svc.cluster.local:5432`                                |
| MLflow           | `http://mlflow.mlops.svc.cluster.local:5000`                           |
| FastAPI          | `http://fastapi.mlops.svc.cluster.local:8000`                          |
| KFP API          | `http://ml-pipeline.kubeflow.svc.cluster.local:8888`                   |
| Prometheus       | `http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090` |
| Grafana          | `http://prometheus-grafana.monitoring.svc.cluster.local:80`            |
| Alertmanager     | `http://prometheus-kube-prometheus-alertmanager.monitoring.svc.cluster.local:9093` |

---

## 3. Run Tests

### Health snapshot (fast, ~5 seconds)

```bash
./scripts/healthcheck.sh
```

### Full test suite (35+ assertions)

```bash
./tests/run-all.sh                  # all 4 tiers (~2 min)
./tests/run-all.sh 01-infra         # only infrastructure tier
./tests/run-all.sh 02-connectivity  # only network/DNS tier
./tests/run-all.sh 03-functional    # only functional tier
```

### Single test

```bash
./tests/03-functional/test-mlflow-smoke.sh
./tests/03-functional/test-minio-rw.sh
./tests/03-functional/test-prometheus-api.sh
./tests/03-functional/test-grafana-api.sh
./tests/03-functional/test-alertmanager-api.sh
./tests/03-functional/test-dvc-data.sh
./tests/03-functional/test-fastapi.sh
./tests/01-infra/test-namespaces.sh
```

### Save test output (useful for thesis appendix)

```bash
./tests/run-all.sh 2>&1 | tee /tmp/test-run-$(date +%Y%m%d-%H%M).log
```

### Reading output

| Marker | Meaning                                       |
|--------|-----------------------------------------------|
| `PASS` | green — assertion held                        |
| `FAIL` | red — assertion didn't hold (reason below)    |
| `SKIP` | yellow — component not deployed yet           |
| `INFO` | blue — informational only                     |

---

## 4. Common Kubernetes Inspection Commands

```bash
# What's running and where
kubectl get pods -A                            # all pods, all namespaces
kubectl get pods -n mlops                      # postgres + mlflow + fastapi
kubectl get pods -n monitoring                 # check Prometheus/Grafana stack
kubectl get svc -A                             # all services
kubectl get pvc -A                             # all volumes

# Resource usage
kubectl top nodes                              # CPU + RAM of the VM
kubectl top pods -A --sort-by=memory           # biggest RAM eaters
free -h                                        # system memory

# Why is a pod unhappy?
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace> --tail=50 --follow

# Get a shell inside a pod
kubectl exec -it <pod-name> -n <namespace> -- bash
kubectl exec -it postgres-0 -n mlops -- psql -U postgres
```

---

## 5. Run Ansible Playbooks

```bash
# Single playbook (no secrets)
ansible-playbook playbooks/01-system-prep.yml
ansible-playbook playbooks/02-k3s.yml
ansible-playbook playbooks/03-helm-tools.yml
ansible-playbook playbooks/06-kfp-standalone.yml

# Playbook with secrets (asks for vault password)
ansible-playbook playbooks/04-minio.yml --ask-vault-pass
ansible-playbook playbooks/05-postgres.yml --ask-vault-pass
ansible-playbook playbooks/07-mlflow.yml --ask-vault-pass
ansible-playbook playbooks/08-monitoring.yml --ask-vault-pass
ansible-playbook playbooks/09-fastapi.yml --ask-vault-pass
ansible-playbook playbooks/10-data-and-dev-env.yml --ask-vault-pass

# Vault file management
ansible-vault view inventory/group_vars/vault.yml      # read decrypted
ansible-vault edit inventory/group_vars/vault.yml      # edit decrypted
ansible-vault encrypt inventory/group_vars/vault.yml   # encrypt plain text
```

---

## 6. Deployment Status

| #  | Playbook              | Status   | Pods / Artifacts                                   |
|----|-----------------------|----------|----------------------------------------------------|
| 01 | system-prep           | done     | n/a (host-level config)                            |
| 02 | k3s                   | done     | 3 in kube-system (coredns, local-path, metrics)    |
| 03 | helm-tools            | done     | n/a (CLI tools)                                    |
| 04 | minio                 | done     | 1 in minio                                         |
| 05 | postgres              | done     | 1 in mlops (postgres-0)                            |
| 06 | kfp-standalone        | done     | 14 in kubeflow                                     |
| 07 | mlflow                | done     | 1 in mlops (mlflow-...)                            |
| 08 | monitoring            | done     | 6 in monitoring (Prom + Grafana + AM + exporters)  |
| 09 | fastapi               | done     | 1 in mlops (fastapi-...)                           |
| 10 | data-and-dev-env      | done     | .venv + 13 C-MAPSS files (DVC, MinIO sync)         |

**Total**: 27 pods running across 5 namespaces. All 10 playbooks complete (9/9 infrastructure + 1 dev env).

---

## 7. FastAPI Operations (inference service)

### Test endpoints from the VM

```bash
# Service info
curl -s http://localhost:8000/ | python3 -m json.tool

# Health & readiness
curl -s http://localhost:8000/healthz
curl -s http://localhost:8000/readyz

# Make a prediction (21 C-MAPSS sensor features)
curl -s -X POST http://localhost:8000/predict \
  -H 'Content-Type: application/json' \
  -d '{"features":[0.0023,-0.0003,100.0,518.67,641.82,1589.7,1400.6,14.62,21.61,554.36,2388.06,9046.19,1.3,47.47,521.66,2388.02,8138.62,8.4195,0.03,392,2388]}'

# Prometheus metrics (counters, histograms)
curl -s http://localhost:8000/metrics | head -30
```

### Stub model vs real model

FastAPI starts with a **stub** that returns `RUL=125.0` until you register
a real model in MLflow under name `cmapss-rul` with stage `Production`.

The `/` endpoint shows the current state:

```json
{
  "service": "C-MAPSS RUL Inference",
  "model_name": "cmapss-rul",
  "model_stage": "Production",
  "model_version": "stub",   // ← becomes "1", "2" etc. once trained
  "is_stub": true            // ← becomes false once trained
}
```

### Load a trained model

Once you train and register a model:

```bash
# Restart FastAPI deployment to reload model from MLflow
kubectl rollout restart deployment/fastapi -n mlops

# Verify new model is loaded
curl -s http://localhost:8000/ | python3 -m json.tool
# is_stub: false, model_version: "1" (or higher)
```

### Rebuild the image (after editing files/fastapi/app/main.py)

The entire build is wrapped in Playbook 09 — just rerun it:

```bash
ansible-playbook playbooks/09-fastapi.yml --ask-vault-pass
```

The playbook detects code changes via the rolling restart at the end and
deploys the new image automatically.

---

## 8. DVC Operations (data versioning)

### Activate the Python venv first

```bash
source /root/thesis-infra/.venv/bin/activate
```

### Common DVC commands

```bash
# Check current data state vs. tracked state
dvc status

# Show configured remotes
dvc remote list

# Pull tracked data from MinIO (e.g. on a fresh VM)
dvc pull

# Push local changes to MinIO (after modifying data)
dvc add data/raw/cmapss        # re-hash and update metadata
dvc push                       # upload changed files to MinIO

# Inspect what's in MinIO under DVC's namespace
kubectl exec -n minio deploy/minio -- mc ls --recursive local/thesis-data/dvc/
```

### Restoring data on a fresh VM (full reproducibility)

```bash
git clone <thesis-infra-repo>
cd thesis-infra
ansible-playbook playbooks/10-data-and-dev-env.yml --ask-vault-pass
# This recreates venv AND restores the C-MAPSS data from MinIO.

# OR (if venv + DVC already exist on the VM):
source .venv/bin/activate
dvc pull
```

---

## 9. Git Workflow

```bash
git status                                     # what changed?
git diff                                       # show changes
git add -A && git commit -m "your message"
git push origin main

# Check the vault is encrypted before committing:
head -1 inventory/group_vars/vault.yml         # must start with $ANSIBLE_VAULT

# After modifying data:
dvc add data/raw/cmapss
git add data/raw/cmapss.dvc .gitignore
git commit -m "data: update C-MAPSS subset"
dvc push                                       # don't forget to push data!
git push origin main
```

---

## 10. Typical First-Look Sequence (5 minutes)

After SSHing into the VM, do this to "get oriented":

```bash
cd /root/thesis-infra

# 1. Is everything alive?
./scripts/healthcheck.sh

# 2. Open the UIs (laptop browser)
./scripts/port-forward-all.sh

# 3. Quick deep-check
./tests/run-all.sh 01-infra

# 4. Activate venv if you'll work with Python/DVC
source .venv/bin/activate
dvc status

# 5. Verify FastAPI is serving
curl -s http://localhost:8000/healthz
```

If all checks are green, the platform is ready. Open in browser:
- http://localhost:9001 (MinIO Console — see the 3 buckets)
- http://localhost:5000 (MLflow — see experiments)
- http://localhost:8080 (Kubeflow Pipelines)
- http://localhost:3000 (Grafana — see Kubernetes dashboards)
- http://localhost:9090 (Prometheus — see scrape targets)
- http://localhost:8000/docs (FastAPI Swagger UI — interactive `/predict`)

---

## 11. Troubleshooting

| Symptom                                     | Likely Fix                                    |
|---------------------------------------------|-----------------------------------------------|
| Browser shows nothing on http://localhost:X | port-forward not running — `./scripts/port-forward-all.sh` |
| "port X already in use"                     | `./scripts/port-forward-all.sh stop` then start again |
| `port-forward-all.sh status` shows `(none)` but ports listening | Old kubectl process holds port — `pkill -9 -f "kubectl port-forward"` then restart |
| `kubectl` shows pods Pending                | RAM/CPU pressure — `kubectl top nodes` to check |
| Pod `CrashLoopBackOff`                      | `kubectl logs <pod> -n <ns> --tail=50`        |
| `ansible-vault` says "no vault secrets"     | Add `--ask-vault-pass` to the playbook command |
| VSCode tunnel broken                        | Reload window: `Ctrl+Shift+P` → "Reload Window" |
| Grafana login fails                         | Get password: `ansible-vault view inventory/group_vars/vault.yml \| grep grafana` |
| `dvc push` fails with auth error            | Make sure port-forward 9000 is up: `./scripts/port-forward-all.sh status \| grep 9000` |
| `dvc init` fails with `_DIR_MARK` import    | DVC < 3.59 has a pathspec bug — upgrade via Playbook 10 |
| C-MAPSS download error in Playbook 10       | NASA wraps files in a doubly-nested zip; Playbook 10 handles both layers |
| FastAPI shows `is_stub: true` after training | `kubectl rollout restart deployment/fastapi -n mlops` |
| FastAPI image build fails (buildkit not found) | apt has no buildkit on Ubuntu 22.04 — Playbook 09 installs binary release |
| Prometheus doesn't show `up{job="fastapi"}` | Wait ~60s after deploy, ServiceMonitor scrape interval is 30s |

---

## 12. Useful Files

| Path                                              | What it is                              |
|---------------------------------------------------|-----------------------------------------|
| `README.md`                                       | Project goal + architecture diagram     |
| `inventory/group_vars/all.yml`                    | All Ansible variables (versions, names) |
| `inventory/group_vars/vault.yml`                  | Encrypted secrets                       |
| `playbooks/0X-*.yml`                              | The 10 Ansible playbooks                |
| `files/monitoring/kube-prometheus-stack-values.yaml` | Helm values for Playbook 08          |
| `files/data/requirements.txt`                     | Python deps for Playbook 10             |
| `files/fastapi/Dockerfile`                        | FastAPI multi-stage build               |
| `files/fastapi/app/main.py`                       | FastAPI application (200 lines)         |
| `files/fastapi/k8s/*.yaml`                        | FastAPI K8s manifests (3 files)         |
| `.dvc/config`                                     | DVC remote (MinIO) configuration        |
| `data/raw/cmapss.dvc`                             | DVC metadata pointer (data is in MinIO) |
| `scripts/healthcheck.sh`                          | Fast health snapshot                    |
| `scripts/port-forward-all.sh`                     | Open all UIs to laptop                  |
| `tests/run-all.sh`                                | Full test suite orchestrator            |
| `tests/README.md`                                 | Testing strategy + design principles    |
| `docs/FIRST_LOOK.md`                              | This file                               |
