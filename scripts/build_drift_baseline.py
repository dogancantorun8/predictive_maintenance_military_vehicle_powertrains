#!/usr/bin/env python3
"""
Build a training-set prediction baseline for drift detection.

Runs the production model over the training set and saves summary
statistics of the prediction distribution as JSON. The output is later
mounted as a Kubernetes ConfigMap and read by the Evidently CronJob to
compare against live prediction distribution from Prometheus.

Environment variables required (typically injected by Ansible Playbook 12):
    MLFLOW_TRACKING_URI
    MLFLOW_S3_ENDPOINT_URL
    AWS_ACCESS_KEY_ID
    AWS_SECRET_ACCESS_KEY
    AWS_DEFAULT_REGION
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

import mlflow
import numpy as np

# Buckets must match the FastAPI Histogram definition in main.py
HISTOGRAM_BUCKETS = [0, 25, 50, 75, 100, 125, 150, 175, 200, 250, 300, 400, 500]


def load_training_data(data_dir: Path) -> np.ndarray:
    """Load preprocessed training tensor produced by Notebook 02."""
    x_train_path = data_dir / "X_train.npy"
    if not x_train_path.exists():
        print(f"ERROR: {x_train_path} not found", file=sys.stderr)
        print("Run Notebook 02 first to generate preprocessed tensors.", file=sys.stderr)
        sys.exit(1)
    x_train = np.load(x_train_path)
    print(f"Loaded X_train: shape={x_train.shape}, dtype={x_train.dtype}")
    return x_train


def load_production_model(model_uri: str):
    """Load production model from MLflow Registry via alias URI."""
    print(f"Loading model from: {model_uri}")
    try:
        model = mlflow.pyfunc.load_model(model_uri)
        print("Model loaded successfully")
        return model
    except Exception as e:
        print(f"ERROR: Could not load model: {e}", file=sys.stderr)
        sys.exit(1)


def get_model_version(model_name: str, alias: str) -> str:
    try:
        client = mlflow.tracking.MlflowClient()
        return client.get_model_version_by_alias(model_name, alias).version
    except Exception as e:
        print(f"WARNING: Could not determine version: {e}", file=sys.stderr)
        return "unknown"


def predict_in_batches(model, x: np.ndarray, batch_size: int = 256) -> np.ndarray:
    """Run inference in batches to avoid OOM on large training sets."""
    n_samples = x.shape[0]
    predictions = np.zeros(n_samples, dtype=np.float32)
    for i in range(0, n_samples, batch_size):
        end = min(i + batch_size, n_samples)
        preds = model.predict(x[i:end])
        predictions[i:end] = np.asarray(preds).flatten()
        if (i // batch_size) % 20 == 0:
            print(f"  Processed {end}/{n_samples} ({100 * end / n_samples:.1f}%)")
    return predictions


def compute_baseline_stats(predictions: np.ndarray) -> dict:
    """Compute summary statistics and bucket counts."""
    counts, _ = np.histogram(predictions, bins=HISTOGRAM_BUCKETS + [float("inf")])
    return {
        "prediction_stats": {
            "mean": float(np.mean(predictions)),
            "std": float(np.std(predictions)),
            "min": float(np.min(predictions)),
            "max": float(np.max(predictions)),
            "median": float(np.median(predictions)),
            "q25": float(np.percentile(predictions, 25)),
            "q75": float(np.percentile(predictions, 75)),
        },
        "histogram": {
            "buckets": HISTOGRAM_BUCKETS,
            "counts": [int(c) for c in counts[:-1]],
        },
    }


def main():
    parser = argparse.ArgumentParser(description="Build drift detection baseline.")
    parser.add_argument("--data-dir", default="data/processed")
    parser.add_argument("--output", default="data/drift/baseline.json")
    parser.add_argument("--model-name", default="cmapss-rul")
    parser.add_argument("--model-alias", default="production")
    args = parser.parse_args()

    # Read MLflow tracking URI from environment (set by Ansible)
    tracking_uri = os.environ.get("MLFLOW_TRACKING_URI", "http://localhost:5000")
    mlflow.set_tracking_uri(tracking_uri)
    print(f"MLflow tracking URI: {tracking_uri}")

    # Sanity-check required environment variables
    for var in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "MLFLOW_S3_ENDPOINT_URL"):
        if not os.environ.get(var):
            print(f"ERROR: ${var} is not set. Run via Playbook 12.", file=sys.stderr)
            sys.exit(1)

    # Load data and model
    x_train = load_training_data(Path(args.data_dir))
    model_uri = f"models:/{args.model_name}@{args.model_alias}"
    model = load_production_model(model_uri)
    model_version = get_model_version(args.model_name, args.model_alias)
    print(f"Production version: {model_version}")

    # Inference + stats
    print(f"\nRunning inference on {x_train.shape[0]} training samples...")
    predictions = predict_in_batches(model, x_train)
    stats = compute_baseline_stats(predictions)

    # Assemble output document
    baseline = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "model_version": model_version,
        "model_uri": model_uri,
        "training_set_size": int(x_train.shape[0]),
        **stats,
    }

    # Pretty summary
    print("\n" + "=" * 60)
    print("Baseline summary")
    print("=" * 60)
    s = baseline["prediction_stats"]
    print(f"  Mean RUL:   {s['mean']:.2f} cycles")
    print(f"  Std RUL:    {s['std']:.2f} cycles")
    print(f"  Min RUL:    {s['min']:.2f}")
    print(f"  Median:     {s['median']:.2f}")
    print(f"  Max RUL:    {s['max']:.2f}")
    print(f"  Q25-Q75:    [{s['q25']:.2f}, {s['q75']:.2f}]")
    print()
    print("Histogram:")
    max_count = max(baseline["histogram"]["counts"])
    for bucket, count in zip(baseline["histogram"]["buckets"], baseline["histogram"]["counts"]):
        bar = "#" * int(50 * count / max(max_count, 1))
        print(f"  [{bucket:>4}, ...) | {count:>5} {bar}")

    # Save
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w") as f:
        json.dump(baseline, f, indent=2)
    print(f"\n✓ Baseline saved to {output_path}")


if __name__ == "__main__":
    main()
