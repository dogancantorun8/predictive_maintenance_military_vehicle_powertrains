# files/fastapi/Dockerfile
# Multi-stage build for the C-MAPSS RUL inference service.
# Final image is ~200 MB (python:3.12-slim base + deps).

FROM python:3.12-slim AS builder

WORKDIR /build

# Install pip wheels into a venv for clean copy in the final stage
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY app/requirements.txt .
RUN pip install --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

# ---------------- Runtime stage ----------------
FROM python:3.12-slim

# Run as non-root for safety
RUN useradd --create-home --shell /bin/bash app
USER app
WORKDIR /home/app

# Copy the prebuilt venv from the builder stage
COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Copy the app code
COPY --chown=app:app app/ ./app/

# Default env (overridden by Kubernetes manifest)
ENV PYTHONUNBUFFERED=1 \
    MLFLOW_TRACKING_URI=http://mlflow.mlops.svc.cluster.local:5000 \
    MODEL_NAME=cmapss-rul \
    MODEL_STAGE=Production \
    STUB_RUL=125.0 \
    MLFLOW_S3_ENDPOINT_URL=http://minio.minio.svc.cluster.local:9000

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
