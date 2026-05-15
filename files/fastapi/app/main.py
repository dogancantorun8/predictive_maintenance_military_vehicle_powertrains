"""
FastAPI inference service for C-MAPSS turbofan RUL prediction.

Endpoints:
  GET  /              — service info
  GET  /healthz       — liveness check
  GET  /readyz        — readiness check (model loaded?)
  GET  /metrics       — Prometheus metrics
  POST /predict       — RUL prediction

Behavior:
  On startup, attempts to load the Production-stage model from MLflow
  Model Registry (model name: 'cmapss-rul'). If no Production model is
  available, falls back to a stub that returns a constant RUL of 125.0
  (the median of the C-MAPSS training set).

This allows the platform to be deployed and tested before the first
real model exists.
"""

import logging
import os
import time
from contextlib import asynccontextmanager
from typing import List

import mlflow
import numpy as np
from fastapi import FastAPI, HTTPException
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
from pydantic import BaseModel, Field
from starlette.responses import Response

# ----------------------------------------------------------------------
# Config (from environment variables — set by Kubernetes manifest)
# ----------------------------------------------------------------------
MLFLOW_TRACKING_URI = os.getenv(
    "MLFLOW_TRACKING_URI",
    "http://mlflow.mlops.svc.cluster.local:5000",
)
MODEL_NAME = os.getenv("MODEL_NAME", "cmapss-rul")
MODEL_STAGE = os.getenv("MODEL_STAGE", "Production")
STUB_RUL = float(os.getenv("STUB_RUL", "125.0"))

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("fastapi-rul")

# ----------------------------------------------------------------------
# Prometheus metrics (exposed at /metrics)
# ----------------------------------------------------------------------
REQUEST_COUNT = Counter(
    "rul_requests_total",
    "Total RUL prediction requests",
    ["status"],
)
REQUEST_LATENCY = Histogram(
    "rul_request_latency_seconds",
    "RUL prediction request latency in seconds",
)
PREDICTION_VALUE = Histogram(
    "rul_prediction_value",
    "Distribution of predicted RUL values (used by Evidently for drift detection)",
    buckets=(0, 25, 50, 75, 100, 125, 150, 175, 200, 250, 300, 400, 500),
)

# ----------------------------------------------------------------------
# Model holder (loaded once at startup)
# ----------------------------------------------------------------------
class ModelHolder:
    def __init__(self):
        self.model = None
        self.model_version = None
        self.is_stub = False

    def load(self) -> None:
        """Try to load a Production model from MLflow. Fall back to stub."""
        mlflow.set_tracking_uri(MLFLOW_TRACKING_URI)
        try:
            model_uri = f"models:/{MODEL_NAME}/{MODEL_STAGE}"
            self.model = mlflow.pyfunc.load_model(model_uri)
            client = mlflow.tracking.MlflowClient()
            latest = client.get_latest_versions(MODEL_NAME, stages=[MODEL_STAGE])
            self.model_version = latest[0].version if latest else "unknown"
            self.is_stub = False
            log.info(
                "Loaded model '%s' version=%s from MLflow stage=%s",
                MODEL_NAME, self.model_version, MODEL_STAGE,
            )
        except Exception as e:
            log.warning(
                "Could not load Production model '%s' from MLflow (%s). "
                "Falling back to stub returning RUL=%.1f",
                MODEL_NAME, e, STUB_RUL,
            )
            self.model = None
            self.model_version = "stub"
            self.is_stub = True


model_holder = ModelHolder()


# ----------------------------------------------------------------------
# App lifespan: load model at startup
# ----------------------------------------------------------------------
@asynccontextmanager
async def lifespan(app: FastAPI):
    log.info("Starting FastAPI RUL service...")
    model_holder.load()
    yield
    log.info("Shutting down FastAPI RUL service.")


app = FastAPI(
    title="C-MAPSS RUL Inference",
    description="Predicts Remaining Useful Life for turbofan engines.",
    version="0.1.0",
    lifespan=lifespan,
)


# ----------------------------------------------------------------------
# Request/Response schemas
# ----------------------------------------------------------------------
class PredictRequest(BaseModel):
    """A flat list of sensor readings — exact shape depends on the model."""
    features: List[float] = Field(
        ...,
        description="Flat feature vector. For C-MAPSS, typically 21 sensor readings.",
        example=[0.0023, -0.0003, 100.0, 518.67, 641.82, 1589.7, 1400.6, 14.62,
                 21.61, 554.36, 2388.06, 9046.19, 1.3, 47.47, 521.66, 2388.02,
                 8138.62, 8.4195, 0.03, 392, 2388],
    )


class PredictResponse(BaseModel):
    rul: float = Field(..., description="Predicted Remaining Useful Life (cycles).")
    model_version: str = Field(..., description="MLflow model version or 'stub'.")
    is_stub: bool = Field(..., description="True if the stub model was used.")


# ----------------------------------------------------------------------
# Routes
# ----------------------------------------------------------------------
@app.get("/")
def root():
    return {
        "service": "C-MAPSS RUL Inference",
        "model_name": MODEL_NAME,
        "model_stage": MODEL_STAGE,
        "model_version": model_holder.model_version,
        "is_stub": model_holder.is_stub,
        "mlflow_tracking_uri": MLFLOW_TRACKING_URI,
    }


@app.get("/healthz")
def healthz():
    """Liveness: process is alive."""
    return {"status": "ok"}


@app.get("/readyz")
def readyz():
    """Readiness: model loaded (stub counts as ready)."""
    if model_holder.model is None and not model_holder.is_stub:
        raise HTTPException(status_code=503, detail="Model not loaded")
    return {"status": "ready", "is_stub": model_holder.is_stub}


@app.get("/metrics")
def metrics():
    """Prometheus scrape endpoint."""
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/predict", response_model=PredictResponse)
def predict(req: PredictRequest):
    start = time.time()
    try:
        if model_holder.is_stub:
            rul_value = STUB_RUL
        else:
            x = np.array(req.features, dtype=np.float32).reshape(1, -1)
            y = model_holder.model.predict(x)
            rul_value = float(np.asarray(y).ravel()[0])
        REQUEST_COUNT.labels(status="success").inc()
        PREDICTION_VALUE.observe(rul_value)
        return PredictResponse(
            rul=rul_value,
            model_version=model_holder.model_version or "unknown",
            is_stub=model_holder.is_stub,
        )
    except Exception as e:
        REQUEST_COUNT.labels(status="error").inc()
        log.exception("Prediction failed")
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        REQUEST_LATENCY.observe(time.time() - start)
