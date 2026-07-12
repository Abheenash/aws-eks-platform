# Small, non-root image. Built for linux/amd64 in CI (EKS nodes are amd64) —
# see the arm64->amd64 lesson carried over from secure-container-pipeline.
FROM python:3.12-slim

WORKDIR /app

RUN pip install --no-cache-dir --upgrade pip
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

# Run as an unprivileged user (defense in depth; pairs with the pod securityContext).
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin appuser
USER 10001

EXPOSE 8080
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
