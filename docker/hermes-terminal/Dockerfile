# Hermes terminal sandbox: debian:bookworm-slim + Node 24 + CPython 3.12.
# Toolchains are copied from official slim images; final base stays stock Debian.
#
# Build (inside the VM as hermes, rootless Docker):
#   ./scripts/hermes-terminal-image.sh build

ARG NODE_VERSION=24
ARG PYTHON_VERSION=3.12
ARG DEBIAN_SUITE=bookworm

# --- Toolchain donors (not shipped as the final base) ---
FROM node:${NODE_VERSION}-${DEBIAN_SUITE}-slim AS node
FROM python:${PYTHON_VERSION}-slim-${DEBIAN_SUITE} AS python

# --- Final runtime: slim Debian ---
FROM debian:${DEBIAN_SUITE}-slim

ARG PYTHON_VERSION=3.12

# Runtime libs for the copied Node/CPython installs, plus common terminal tools.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    git \
    libatomic1 \
    libbz2-1.0 \
    libffi8 \
    libgcc-s1 \
    liblzma5 \
    libncursesw6 \
    libreadline8 \
    libsqlite3-0 \
    libssl3 \
    libstdc++6 \
    libuuid1 \
    procps \
    tini \
    xz-utils \
    zlib1g \
  && rm -rf /var/lib/apt/lists/*

# Merge /usr/local from both donors (bin/lib names do not collide).
COPY --from=node /usr/local /usr/local
COPY --from=python /usr/local /usr/local

ENV PATH="/usr/local/bin:${PATH}" \
  PIP_DISABLE_PIP_VERSION_CHECK=1 \
  PYTHONDONTWRITEBYTECODE=1 \
  PYTHONUNBUFFERED=1

RUN ldconfig \
  && ln -sf /usr/local/bin/python${PYTHON_VERSION} /usr/local/bin/python3 \
  && ln -sf /usr/local/bin/python3 /usr/local/bin/python \
  && python3 -m pip install --no-cache-dir --upgrade pip setuptools wheel \
  && node --version \
  && npm --version \
  && python3 --version \
  && pip3 --version

WORKDIR /workspace

ENTRYPOINT ["tini", "--"]
CMD ["bash"]
