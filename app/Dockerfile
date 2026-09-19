# Two stages. The runtime image carries the app and its dependencies and nothing
# else: no pip, no setuptools, no compiler. (Trivy flagged HIGH CVEs in the copies of
# msgpack/setuptools that pip vendors inside itself — a package manager the running
# service never uses is attack surface for free.)
FROM python:3.12-slim AS build
WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim
WORKDIR /app
COPY --from=build /install /usr/local
COPY main.py .
# Remove the package manager from the runtime image (and its vendored deps).
RUN python -m pip uninstall -y pip setuptools wheel >/dev/null 2>&1 || true \
 && rm -rf /usr/local/lib/python3.12/site-packages/pip* /usr/local/lib/python3.12/site-packages/setuptools* \
           /usr/local/lib/python3.12/site-packages/_distutils_hack /usr/local/lib/python3.12/site-packages/distutils-precedence.pth \
           /usr/local/lib/python3.12/ensurepip /usr/local/bin/pip* /root/.cache
# Run as an unprivileged user (defense in depth; pairs with the pod securityContext).
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin appuser
USER 10001
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
EXPOSE 8080
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080", "--no-server-header"]
