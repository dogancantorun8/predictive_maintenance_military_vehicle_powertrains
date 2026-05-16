# C-MAPSS EDA Findings — FD001 Subset

**Source notebook**: `notebooks/01_eda.ipynb`
**Date**: May 2026
**Author**: Dogancan Torun

This document summarizes the findings of the exploratory data analysis
performed on the FD001 subset of the NASA C-MAPSS turbofan degradation
dataset. The findings ground the preprocessing and modeling decisions
made in subsequent notebooks.

---

## 1. Dataset Structure

| Property | Value |
|---|---|
| Sub-dataset | FD001 (1 operating condition, 1 fault mode — HPC degradation) |
| Total engines | 100 |
| Total training rows | 20,631 |
| Columns | 26 (2 ID + 3 op_settings + 21 sensors) |
| Cycles to failure (min / median / max) | 128 / 199 / 362 |

### Why FD001?

The four C-MAPSS sub-datasets vary in complexity:

| Dataset | Engines | Op. conditions | Fault modes |
|---|---|---|---|
| **FD001** | 100 | 1 | 1 |
| FD002 | 260 | 6 | 1 |
| FD003 | 100 | 1 | 2 |
| FD004 | 249 | 6 | 2 |

FD001 is the **simplest** — a natural starting point for the baseline
model. Extending to FD002-FD004 is documented as Future Work.

---

## 2. Engine Lifespan Distribution

The lifespan distribution is **right-skewed**:
mean = 206 cycles, median = 199 cycles. Most engines fail within a
narrow window around the median, but a minority survives well beyond
300 cycles.

**Implication**: predicting RUL > 125 is operationally less valuable
(maintenance decisions concern engines near failure) and statistically
less reliable (training signal is sparse at high RUL values). The
preprocessing pipeline will **cap RUL at 125** — a standard practice
in C-MAPSS literature (Heimes 2008, Zheng et al. 2017).

---

## 3. Constant Features (Dropped)

Eight features have standard deviation below 10⁻³, meaning they are
effectively constant across all 20,631 training samples. They carry
zero information for RUL prediction.

| Feature | Constant value | Reason |
|---|---|---|
| `op_setting_2` | ~0.0 | FD001 has only 1 op condition |
| `op_setting_3` | 100.0 | FD001 has only 1 op condition |
| `sensor_01` | 518.67 | Total temperature at fan inlet — no response |
| `sensor_05` | 14.62 | Pressure ratio (P21/P0) — no response |
| `sensor_10` | 1.30 | Engine pressure ratio (P50/P2) — no response |
| `sensor_16` | 0.03 | Burner fuel-air ratio — no response |
| `sensor_18` | 2388.0 | Demanded fan speed — controlled, not sensed |
| `sensor_19` | 100.0 | Demanded corrected fan speed — controlled |

These features are dropped before model training, reducing the LSTM
input dimensionality from 24 to **16**.

---

## 4. Informative Features (Retained)

Sixteen features show meaningful variance and measurable correlation
with RUL. Pearson correlation coefficients (sorted by absolute value):

| Feature | Correlation with RUL | Strength |
|---|---|---|
| sensor_11 | -0.6962 | Strong negative |
| sensor_12 | +0.6720 | Strong positive |
| sensor_07 | +0.6572 | Strong positive |
| sensor_21 | +0.6357 | Strong positive |
| sensor_20 | +0.6294 | Strong positive |
| sensor_04 | -0.6427 (approx) | Strong negative |
| sensor_15 | -0.6427 | Strong negative |
| sensor_02 | -0.6065 | Strong negative |
| sensor_17 | -0.6062 | Strong negative |
| sensor_03 | -0.5845 | Moderate negative |
| sensor_08 | -0.5640 | Moderate negative |
| sensor_13 | -0.5626 | Moderate negative |
| sensor_14 | (mid-range) | Moderate |
| sensor_06 | -0.1283 | Weak |
| sensor_09 | (mid-range) | Moderate |
| op_setting_1 | -0.0032 | Effectively zero — candidate for removal |

**Note on op_setting_1**: Although it passes the variance threshold
(std > 0.001), its correlation with RUL is essentially zero. We retain
it in the baseline feature set for now but note it as a candidate for
removal in a future ablation study.

### Interpretation

Most informative sensors are negatively correlated with RUL — they
**increase** as the engine approaches failure (temperatures, vibrations).
A smaller set increases as RUL increases (positive correlation), which
in practice means they decrease as the engine ages.

This is the canonical degradation signature LSTM-based RUL models
exploit.

---

## 5. RUL Target Derivation

C-MAPSS training data does not include the RUL column directly. We
derive it for each engine:
RUL(t) = max_cycle_for_engine - current_cycle(t)
At the failure point (last cycle of each engine's life), RUL = 0.
This produces exactly **100 rows with RUL=0** in the training set
(one per engine), confirming our derivation is correct.

### RUL distribution

Right-skewed, peaking near 0 and decaying toward the long tail at
~300+ cycles. The capping decision (RUL_max = 125) reshapes this into
a more model-friendly distribution that:
- Concentrates training signal where it matters operationally
- Reduces the dynamic range the model must learn
- Aligns with standard practice in published C-MAPSS benchmarks

---

## 6. Sensor Trajectory Patterns

Examining `sensor_07` across 10 sample engines (aligned by RUL):
all engines show a **consistent drift pattern** as they approach
failure. This consistency is precisely what makes RUL prediction
tractable — the sensors evolve in a predictable way regardless of
which specific engine.

This finding supports the LSTM architecture choice: the model needs to
learn a **temporal pattern** in sensor readings, not engine-specific
behavior.

---

## 7. Decisions Made (Inputs to Notebook 02 — Preprocessing)

| Decision | Value | Justification |
|---|---|---|
| Sub-dataset | FD001 | Simplest case (1 op condition, 1 fault mode) |
| Features retained | 16 | std > 10⁻³, mostly with abs(corr) > 0.5 |
| Features dropped | 8 | std ≈ 0, no information |
| Target | RUL (derived) | Standard practice |
| RUL cap | 125 cycles | Heimes 2008, Zheng 2017 convention |
| Train/validation split | Engine-based | Avoid temporal leakage |
| Sequence window | 30 cycles (TBD) | To be confirmed in Notebook 02 |

---

## 8. Implications for Thesis Defense

These findings establish a **data-driven foundation** for all
modeling decisions. Each architectural choice in subsequent notebooks
can be traced back to a specific figure or table in this notebook:

- LSTM input size = 16 → justified by Cell 9 (constant feature analysis)
- RUL cap at 125 → justified by Cell 12 (RUL distribution histogram)
- Feature ordering for inspection → justified by Cell 15 (correlation ranking)
- Single-engine architecture (vs per-engine model) → justified by Cell 14 (cross-engine pattern consistency)

This grounds the methodology in observable properties of the dataset
rather than literature defaults, strengthening the defensibility of
the thesis methodology.
