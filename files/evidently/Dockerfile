# files/evidently/Dockerfile
# Drift detection container — runs as a Kubernetes CronJob (hourly).
# Small footprint: numpy + scipy + requests (no pandas, no full evidently package).
# ~150 MB final image.

FROM python:3.12-slim

# Install Python dependencies into a venv
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

WORKDIR /app
COPY app/requirements.txt .
RUN pip install --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

# Copy the drift check script
COPY app/drift_check.py .

# Run as non-root for safety (Kubernetes best practice)
RUN useradd --create-home --shell /bin/bash drift && \
    chown -R drift:drift /app
USER drift

ENV PYTHONUNBUFFERED=1

ENTRYPOINT ["python", "/app/drift_check.py"]
