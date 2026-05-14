# 🛡️ Self-Updating Predictive Maintenance for Military Vehicle Powertrains

> **A sensor-driven Remaining-Useful-Life system that stays accurate as fleets and operating conditions change.**

[![Python](https://img.shields.io/badge/python-3.11+-blue.svg)](https://www.python.org/)
[![PyTorch](https://img.shields.io/badge/PyTorch-2.5+-EE4C2C.svg)](https://pytorch.org/)
[![Kubeflow](https://img.shields.io/badge/Kubeflow-1.9+-326CE5.svg)](https://www.kubeflow.org/)
[![MLflow](https://img.shields.io/badge/MLflow-2.18+-0194E2.svg)](https://mlflow.org/)
[![License](https://img.shields.io/badge/license-Apache%202.0-green.svg)](LICENSE)
[![Status](https://img.shields.io/badge/status-active%20research-yellow.svg)]()

---

## 📖 Overview

This repository contains the predictive modeling and MLOps integration code for a master's thesis on **self-updating predictive maintenance**. The system predicts the **Remaining Useful Life (RUL)** of vehicle powertrains from multivariate sensor time-series — and, more importantly, **keeps doing so accurately as data distributions drift over time**.

Most published RUL studies stop after reporting RMSE on a static benchmark. This thesis explicitly tackles the **post-deployment lifecycle**: drift detection, automated retraining, champion-challenger promotion, and end-to-end auditability — all running on an on-premises, air-gap-capable Kubernetes stack.

### The Core Question

> Given the last 30 cycles of sensor data from an engine, **how many cycles of operation does it have left before failure** — and how do we keep that prediction accurate as the fleet ages, missions change, and operating environments shift?

---

## 🎯 Why This Matters

Predictive maintenance is a strategic priority for modern militaries. The 2022 U.S. National Defense Authorization Act formally mandated a review of DoD predictive maintenance practices, and the U.S. Army has collected millions of Condition-Based Maintenance (CBM) records from military vehicles.

Unscheduled engine failure in the field can compromise missions and cost lives; replacing a healthy engine on a fixed schedule wastes money. A system that says *"this specific engine has 40 hours of safe operation left"* is materially better than one that says *"replace every engine at 1,000 hours."*

But the predictions must stay reliable **for years**, as:

- 🚙 Vehicles age and components degrade non-uniformly
- 🎯 Mission profiles change (training → deployment → reserve)
- 🌍 Operating environments shift (Central European summer → desert deployment)
- 📊 The underlying sensor data distribution drifts

---

## 🔁 The Closed-Loop Architecture

```
       ┌─────────────┐
       │   Predict   │ ◄────── Sensor windows from fleet
       │  (FastAPI)  │
       └──────┬──────┘
              │
              ▼
       ┌─────────────┐         ┌──────────────────┐
       │   Observe   │────────▶│  Ground truth    │
       │ (Prometheus │         │  (failures, MX)  │
       │   + MinIO)  │         └──────────────────┘
       └──────┬──────┘
              │
              ▼
       ┌─────────────┐
       │ Detect drift│ ◄────── Evidently AI CronJob (hourly)
       │  (PSI, KS)  │         PSI, KS-test on features + predictions
       └──────┬──────┘
              │ drift threshold exceeded
              ▼
       ┌─────────────┐
       │   Retrain   │ ◄────── Kubeflow Pipelines DAG
       │  (Kubeflow) │         data → preprocess → train → eval
       └──────┬──────┘
              │
              ▼
       ┌─────────────┐
       │  Promote?   │ ◄────── Champion-challenger
       │ (NASA RUL   │         Promote only if Δscore > margin
       │   Score)    │         on asymmetric RUL metric
       └──────┬──────┘
              │ promoted
              ▼
       ┌─────────────┐
       │    Audit    │ ◄────── Full lineage: every prediction,
       │  (MLflow +  │         drift event, retraining run, and
       │   GitHub)   │         promotion decision is logged.
       └─────────────┘
```

Every step is logged with full lineage, timestamps, and metric values — the audit trail that defense procurement frameworks and the EU AI Act's high-risk-system provisions require.

---

## 🔬 What This Thesis Measures

The headline contribution is the **drift-to-recovery latency**: the elapsed wall-clock time from the moment drift is detected to the moment a better model is live in production. This is rarely reported in the existing literature, which typically presents drift detection as a static offline analysis.

The drift experiment uses **N-CMAPSS** samples streamed through a system trained on **C-MAPSS** — a controlled, repeatable distribution shift.

### Research Questions

| RQ | Question |
|----|----------|
| **RQ1** | How can a self-updating RUL system be designed under on-premises, auditable, air-gap-capable constraints using only open-source Kubernetes-native components? |
| **RQ2** | How does sensor-data drift affect RUL accuracy over time, and how effectively does an automated drift-detection-and-retraining loop recover that accuracy without human intervention? |
| **RQ3** | What is the operational trade-off between model complexity (MLP, Bi-LSTM, CNN-LSTM, Transformer) and system-level metrics (training time, deployment latency, retraining cost, drift-to-recovery latency, monitoring overhead)? |

---

## 🧠 Predictive Models

Implemented in PyTorch 2.5+ with PyTorch Lightning:

| Model | Architecture | Role | Approx. CPU Training Time |
|-------|-------------|------|---------------------------|
| **MLP** | 2–4 hidden layers, 50–100 neurons, ReLU | Baseline sanity-check | ~1 min |
| **Bi-LSTM** | Bidirectional LSTM, the established RUL baseline | Primary baseline | ~5 min |
| **CNN-LSTM** | Conv1D feature extraction + LSTM temporal modeling | Stronger baseline | ~10 min |
| **Transformer** (stretch) | Lightweight attention-based model | Optional comparison | ~15 min |

### Loss & Evaluation

- **Training loss:** Mean Squared Error
- **Reported metrics:**
  - RMSE
  - **NASA RUL Score** (asymmetric — penalizes late predictions more heavily than early ones, reflecting that a missed failure is worse than premature maintenance)
  - Quadratic-weighted error in the critical zone (RUL ≤ 30 cycles)
- **Interpretability:** SHAP feature attribution on the best model, required for EU AI Act high-risk-system compliance

### Preprocessing

- Min-max normalization per sensor
- Sliding-window sequences (window length 30–50 cycles)
- Train/validation/test split **per engine unit** (no leakage)
- Piecewise-linear RUL labeling with threshold of 130 cycles
- Optional condition-aware clustering for multi-regime sub-datasets (FD002, FD004)

---

## 📊 Datasets

All datasets are public, free of ITAR and EU export-controlled information, and standard benchmarks in the prognostics literature.

| Dataset | Role | Source |
|---------|------|--------|
| **NASA C-MAPSS** (FD001–FD004) | Primary benchmark | [NASA PCoE Repository](https://www.nasa.gov/intelligent-systems-division/discovery-and-systems-health/pcoe/pcoe-data-set-repository/) |
| **N-CMAPSS** | Controlled distribution shift for the drift experiment | [NASA PHM S3](https://phm-datasets.s3.amazonaws.com/NASA/17.+Turbofan+Engine+Degradation+Simulation+Data+Set+2.zip) |
| **U.S. Army CBM (Public Subset)** | Military ground-vehicle validation | [Ardis et al. 2024, arXiv:2407.17654](https://arxiv.org/abs/2407.17654) |
| **AI4I 2020** (optional) | Industrial classification baseline | [UCI Repository](https://archive.ics.uci.edu/dataset/601/ai4i+2020+predictive+maintenance+dataset) |

---

## 🏗️ Tech Stack

This repository contains the **modeling and pipeline code**. The infrastructure provisioning lives in a sister repository (see [Companion Repository](#-companion-repository)).

### Modeling & Pipelines (this repo)

| Layer | Tool | License |
|-------|------|---------|
| ML framework | PyTorch 2.5+ + PyTorch Lightning | BSD-3 / Apache 2.0 |
| Classical baselines | scikit-learn | BSD-3 |
| Hyperparameter search | Optuna (+ optional Kubeflow Katib) | MIT |
| Experiment tracking | MLflow 2.18+ | Apache 2.0 |
| Data versioning | DVC | Apache 2.0 |
| Pipeline orchestration | Kubeflow Pipelines | Apache 2.0 |
| Inference serving | FastAPI + Uvicorn | MIT |
| Drift detection | Evidently AI | Apache 2.0 |
| Interpretability | SHAP | MIT |
| CI/CD | GitHub Actions | (free tier) |

### Platform (companion repo)

`k3s` · `Full Kubeflow Platform` · `Istio` · `Knative` · `cert-manager` · `MetalLB` · `MinIO` · `PostgreSQL` · `Prometheus` · `Grafana` · `Ansible` (12 modular playbooks)

---

## 🚀 Quickstart

### Prerequisites

- Python 3.11+
- An MLflow tracking server (locally or in the companion infrastructure)
- The C-MAPSS dataset downloaded to `data/raw/`

### Install

```bash
git clone https://github.com/<your-username>/<this-repo>.git
cd <this-repo>
python -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"
```

### Reproduce the Bi-LSTM baseline on FD001

```bash
# 1. Download dataset (versioned with DVC)
dvc pull

# 2. Preprocess
python -m src.data.preprocess --subset FD001 --window 30 --rul-cap 130

# 3. Train the baseline
python -m src.models.train \
    --model bilstm \
    --subset FD001 \
    --epochs 100 \
    --mlflow-uri http://<mlflow-host>:5000

# 4. Evaluate
python -m src.eval.report --run-id <mlflow-run-id>
```

### Run the closed-loop drift experiment

```bash
# Inject N-CMAPSS samples into a deployed C-MAPSS-trained model
python -m src.experiments.drift_inject \
    --inference-url http://<fastapi-host>/predict \
    --rate 100 \
    --duration 1h

# Measure drift-to-recovery latency
python -m src.experiments.measure_latency --start <ISO-timestamp>
```

---

## 📁 Repository Structure

```
.
├── src/
│   ├── data/              # Preprocessing, sliding windows, RUL labeling
│   ├── models/            # MLP, Bi-LSTM, CNN-LSTM, Transformer (PyTorch Lightning)
│   ├── pipelines/         # Kubeflow Pipelines DAG definitions
│   ├── serving/           # FastAPI inference service
│   ├── drift/             # Evidently AI integration, PSI / KS computation
│   ├── eval/              # RMSE, NASA RUL Score, critical-zone metrics
│   ├── interpret/         # SHAP analysis
│   └── experiments/       # Drift injection, latency measurement
├── notebooks/             # EDA, ablation studies
├── configs/               # Hydra config files per experiment
├── tests/                 # pytest suite
├── data/                  # DVC-tracked; raw data not committed
├── docs/                  # Architecture diagrams, ADRs
├── .github/workflows/     # CI: lint, test, build, push, redeploy
├── pyproject.toml
└── dvc.yaml
```

---

## 🔗 Companion Repository

The full **Infrastructure-as-Code** stack (12 modular Ansible playbooks that provision the entire platform on a clean Ubuntu VM in ~75 minutes) lives in its own repository:

👉 **[thesis-infra](https://github.com/<your-username>/thesis-infra)** — Ansible playbooks for k3s + Full Kubeflow + MLflow + MinIO + monitoring + drift detection

---

## 📚 Key References

1. **NASA C-MAPSS** — Saxena & Goebel. Turbofan Engine Degradation Simulation Data Set. [NASA PCoE](https://www.nasa.gov/intelligent-systems-division/discovery-and-systems-health/pcoe/pcoe-data-set-repository/)
2. **Chao et al. (2021)** — *Aircraft Engine Run-to-Failure Dataset under Real Flight Conditions* (N-CMAPSS)
3. **Ardis et al. (2024)** — *Generative Learning for Simulation of Vehicle Faults* — [arXiv:2407.17654](https://arxiv.org/abs/2407.17654)
4. **Bayram et al. (2024)** — *Predictive Maintenance for Automotive Vehicle Engines in Military Logistics* — [CEUR-WS 3711](https://ceur-ws.org/Vol-3711/paper21.pdf)
5. **Faria et al. (2025)** — *MLOps Best Practices, Challenges and Maturity Models: A Systematic Literature Review*
6. **Sahoo et al. (2025)** — *Towards Secure MLOps* — [arXiv:2506.02032](https://arxiv.org/html/2506.02032v1)

Full bibliography in [`docs/references.bib`](docs/references.bib).

---

## 📜 License

Code in this repository is released under the **Apache License 2.0**. The thesis text itself remains the academic property of the author and the supervising institution.

All datasets used are publicly available and not subject to ITAR or EU export-control regulations. Thesis development takes place on a personal compute account, fully separated from any employer infrastructure.

---

## ✍️ Citation

If you use this work, please cite the thesis:

```bibtex
@mastersthesis{torun2026selfupdating,
  author  = {Torun, Dogancan},
  title   = {A Self-Updating Predictive Maintenance System for Military 
             Vehicle Powertrains: Forecasting Remaining Useful Life from 
             Sensor Time-Series under Distribution Shift},
  school  = {University of Hull},
  year    = {2026},
  type    = {Master's Thesis}
}
```

---

## 🙋 Acknowledgments

NASA Prognostics Center of Excellence (C-MAPSS, N-CMAPSS datasets); the Kubeflow, MLflow, and Evidently AI open-source communities; the k3s and Ansible maintainers whose work makes a fully reproducible on-prem MLOps stack feasible.
