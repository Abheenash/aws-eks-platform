# Two stages. The runtime image carries the app and its dependencies and nothing
# else: no pip, no setuptools, no compiler. (Trivy flagged HIGH CVEs in the copies of
# msgpack/setuptools that pip vendors inside itself — a package manager the running
# service never uses is attack surface for free.)
FROM python:3.13-slim AS build
WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.13-slim
WORKDIR /app
COPY --from=build /install /usr/local
COPY main.py .
# Remove the package manager from the runtime image (and its vendored deps).
#
# The site-packages path is resolved from the interpreter, never written out as
# python3.13. A hardcoded version here fails OPEN on the next base-image bump:
# `rm -rf` on a path that no longer exists succeeds silently, pip survives into
# the runtime image, and its vendored CVEs come back with a green build. The
# `test -z` at the end is the guard that turns that silent failure into a build
# failure.
RUN python -m pip uninstall -y pip setuptools wheel >/dev/null 2>&1 || true \
 && SP="$(python -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')" \
 && STD="$(python -c 'import sysconfig; print(sysconfig.get_paths()["stdlib"])')" \
 && rm -rf "$SP"/pip* "$SP"/setuptools* "$SP"/wheel* \
           "$SP"/_distutils_hack "$SP"/distutils-precedence.pth \
           "$STD"/ensurepip /usr/local/bin/pip* /root/.cache \
 && test -z "$(find /usr/local -maxdepth 6 -name 'pip' -o -maxdepth 6 -name 'setuptools' | head -1)"
# Run as an unprivileged user (defense in depth; pairs with the pod securityContext).
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin appuser
USER 10001
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
EXPOSE 8080
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080", "--no-server-header"]
