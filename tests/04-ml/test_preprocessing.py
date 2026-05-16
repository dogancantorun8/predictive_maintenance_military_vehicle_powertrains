"""
Critical preprocessing invariants for the C-MAPSS pipeline.

Scope: only the correctness-critical functions whose bugs would silently
corrupt the model. Exhaustive coverage of preprocessing is out of scope.
"""

import sys
from pathlib import Path
import numpy as np
import pandas as pd
import pytest

# Add project root to path
PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT_ROOT))

from src.preprocessing import (
    compute_rul,
    piecewise_rul,
    engine_based_split,
    create_sequences,
    fit_scaler,
    apply_scaler,
    get_feature_columns,
    C_MAPSS_COLUMNS,
    RUL_CAP,
    DEFAULT_WINDOW,
)


# ----------------------------------------------------------------------
# Fixture: synthetic C-MAPSS-shaped DataFrame
# ----------------------------------------------------------------------

@pytest.fixture
def synthetic_cmapss():
    """
    Build a tiny synthetic dataset:
      - 3 engines (IDs 1, 2, 3)
      - Engine 1: 100 cycles (long)
      - Engine 2: 50 cycles (medium)
      - Engine 3: 40 cycles (short, < window=30 in some tests)
    """
    rows = []
    for engine_id, n_cycles in [(1, 100), (2, 50), (3, 40)]:
        for t in range(1, n_cycles + 1):
            row = {
                'unit_number': engine_id,
                'time_in_cycles': t,
                'op_setting_1': 0.0,
                'op_setting_2': 0.0,
                'op_setting_3': 100.0,
            }
            for s in range(1, 22):
                row[f'sensor_{s:02d}'] = float(t * s)  # arbitrary values
            rows.append(row)
    return pd.DataFrame(rows)


# ----------------------------------------------------------------------
# TEST 1 — RUL derivation correctness
# ----------------------------------------------------------------------

def test_compute_rul_final_cycle_is_zero(synthetic_cmapss):
    """At the last cycle of each engine's life, RUL must equal 0."""
    df = compute_rul(synthetic_cmapss)

    for engine_id in df['unit_number'].unique():
        engine_df = df[df['unit_number'] == engine_id]
        last_cycle_rul = engine_df.iloc[-1]['RUL']
        assert last_cycle_rul == 0, (
            f"Engine {engine_id}: last cycle RUL should be 0, got {last_cycle_rul}"
        )


def test_compute_rul_decreases_monotonically(synthetic_cmapss):
    """For each engine, RUL must decrease as time_in_cycles increases."""
    df = compute_rul(synthetic_cmapss)

    for engine_id in df['unit_number'].unique():
        engine_df = df[df['unit_number'] == engine_id].sort_values('time_in_cycles')
        rul_values = engine_df['RUL'].values
        diffs = np.diff(rul_values)
        assert np.all(diffs == -1), (
            f"Engine {engine_id}: RUL should decrease by exactly 1 each step, "
            f"got diffs {diffs[:5]}..."
        )


def test_piecewise_rul_caps_at_threshold(synthetic_cmapss):
    """RUL values above the cap must be clamped to the cap."""
    df = compute_rul(synthetic_cmapss)
    df_capped = piecewise_rul(df, cap=50)

    assert df_capped['RUL'].max() <= 50, "RUL exceeded cap"
    # Values <= cap should be unchanged
    below_cap_mask = df['RUL'] <= 50
    assert (df_capped.loc[below_cap_mask, 'RUL'] == df.loc[below_cap_mask, 'RUL']).all(), (
        "Values below cap should be unchanged"
    )


# ----------------------------------------------------------------------
# TEST 2 — Engine-based split has no data leakage
# ----------------------------------------------------------------------

def test_engine_based_split_no_leakage(synthetic_cmapss):
    """No engine may appear in both train and val splits."""
    df_train, df_val = engine_based_split(synthetic_cmapss, val_fraction=0.33, random_seed=42)

    train_engines = set(df_train['unit_number'].unique())
    val_engines = set(df_val['unit_number'].unique())

    overlap = train_engines & val_engines
    assert len(overlap) == 0, f"Data leakage detected — engines in both splits: {overlap}"


def test_engine_based_split_uses_all_engines(synthetic_cmapss):
    """Every engine in the input must end up in exactly one split."""
    df_train, df_val = engine_based_split(synthetic_cmapss, val_fraction=0.33, random_seed=42)

    train_engines = set(df_train['unit_number'].unique())
    val_engines = set(df_val['unit_number'].unique())
    all_input_engines = set(synthetic_cmapss['unit_number'].unique())

    assert (train_engines | val_engines) == all_input_engines, (
        f"Engines lost during split. Input: {all_input_engines}, "
        f"Train+Val: {train_engines | val_engines}"
    )


def test_engine_based_split_is_deterministic(synthetic_cmapss):
    """Same seed should produce same split."""
    df_train_a, df_val_a = engine_based_split(synthetic_cmapss, random_seed=42)
    df_train_b, df_val_b = engine_based_split(synthetic_cmapss, random_seed=42)

    train_a_engines = set(df_train_a['unit_number'].unique())
    train_b_engines = set(df_train_b['unit_number'].unique())

    assert train_a_engines == train_b_engines, "Split is non-deterministic with same seed"


# ----------------------------------------------------------------------
# TEST 3 — Sequence creation has correct shape
# ----------------------------------------------------------------------

def test_create_sequences_shape(synthetic_cmapss):
    """X output must be 3D: (n_sequences, window, n_features)."""
    df = compute_rul(synthetic_cmapss)
    df = piecewise_rul(df)

    window = 30
    feature_cols = get_feature_columns(df)
    X, y = create_sequences(df, window=window, feature_cols=feature_cols)

    assert X.ndim == 3, f"X should be 3D, got shape {X.shape}"
    assert X.shape[1] == window, f"Window dim should be {window}, got {X.shape[1]}"
    assert X.shape[2] == len(feature_cols), (
        f"Feature dim should be {len(feature_cols)}, got {X.shape[2]}"
    )
    assert y.ndim == 1, f"y should be 1D, got shape {y.shape}"
    assert X.shape[0] == y.shape[0], "X and y sample counts must match"


def test_create_sequences_skips_short_engines(synthetic_cmapss):
    """Engines with fewer than `window` cycles should be skipped."""
    df = compute_rul(synthetic_cmapss)

    # Engine 3 has 40 cycles, so window=50 should exclude it
    feature_cols = get_feature_columns(df)
    X, y = create_sequences(df, window=50, feature_cols=feature_cols)

    # Only engines 1 (100 cycles) and 2 (50 cycles) qualify; engine 3 is too short
    # Engine 1: 100 - 50 + 1 = 51 sequences
    # Engine 2: 50 - 50 + 1 = 1 sequence
    # Engine 3: 40 cycles < 50 window → skipped
    expected_count = 51 + 1
    assert X.shape[0] == expected_count, (
        f"Expected {expected_count} sequences (skipping short engine), got {X.shape[0]}"
    )


def test_create_sequences_y_is_rul_at_end_of_window(synthetic_cmapss):
    """For each sequence, y should equal the RUL at the LAST cycle of the window."""
    df = compute_rul(synthetic_cmapss)
    df = piecewise_rul(df, cap=200)  # high cap so no clipping

    window = 10
    feature_cols = get_feature_columns(df)
    X, y = create_sequences(df, window=window, feature_cols=feature_cols)

    # For engine 1 (100 cycles), first sequence spans cycles 1-10
    # RUL at cycle 10 = max_cycle - 10 = 100 - 10 = 90
    engine_1 = df[df['unit_number'] == 1].sort_values('time_in_cycles')
    first_seq_target = engine_1.iloc[window - 1]['RUL']
    assert y[0] == first_seq_target, (
        f"y[0] should equal RUL at cycle {window} of engine 1, "
        f"expected {first_seq_target}, got {y[0]}"
    )


# ----------------------------------------------------------------------
# TEST 4 — Scaler is fit on train only (no data leakage in normalization)
# ----------------------------------------------------------------------

def test_scaler_fitted_on_train_only(synthetic_cmapss):
    """
    A scaler fit on train data should NOT have seen val data.
    Reapplying it should keep train in [0, 1] and produce val values
    that may go outside [0, 1] (because val was unseen).
    """
    df = compute_rul(synthetic_cmapss)
    df_train, df_val = engine_based_split(df, val_fraction=0.33, random_seed=42)

    scaler = fit_scaler(df_train)
    df_train_norm = apply_scaler(df_train, scaler)

    feature_cols = get_feature_columns(df_train)
    train_min = df_train_norm[feature_cols].min().min()
    train_max = df_train_norm[feature_cols].max().max()

    # Train data must be in [0, 1] after Min-Max
    assert train_min >= 0.0 - 1e-6, f"Train min should be >= 0, got {train_min}"
    assert train_max <= 1.0 + 1e-6, f"Train max should be <= 1, got {train_max}"
