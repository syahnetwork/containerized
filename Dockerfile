# syntax=docker/dockerfile:1

# --- Stage 1: Build ---
FROM python:3.12-slim AS builder

WORKDIR /app

# Install dependencies into a virtual environment
COPY app/requirements.txt .
RUN python -m venv /opt/venv && \
    /opt/venv/bin/pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY app/ /app

# --- Stage 2: Runtime ---
FROM gcr.io/distroless/python3-debian12:nonroot

WORKDIR /app

# Copy only the necessary artifacts from the builder
COPY --from=builder /opt/venv /opt/venv
COPY --from=builder /app /app

# Set environment path to use the venv
ENV PATH="/opt/venv/bin:$PATH"
ENV PYTHONUNBUFFERED=1

# Distroless nonroot image already uses a non-root user (UID 65532)
USER nonroot

EXPOSE 8080

ENTRYPOINT ["python", "main.py"]