FROM rust:1.94.0-bookworm@sha256:365468470075493dc4583f47387001854321c5a8583ea9604b297e67f01c5a4f

ARG EXECUTION_PLANE_UID=1000
ARG EXECUTION_PLANE_GID=1000
ARG EXECUTION_PLANE_USER=runner

ENV DEBIAN_FRONTEND=noninteractive \
    SCCACHE_DIR=/workspace/.cache/sccache

# hadolint ignore=DL3008
RUN apt-get update -o Acquire::Retries=3 \
    && apt-get install -y --no-install-recommends \
        bash \
        build-essential \
        ca-certificates \
        libssl-dev \
        pkg-config \
    && rm -rf /var/lib/apt/lists/* \
    && cargo install --locked sccache \
    && groupadd --gid "${EXECUTION_PLANE_GID}" "${EXECUTION_PLANE_USER}" \
    && useradd --uid "${EXECUTION_PLANE_UID}" \
        --gid "${EXECUTION_PLANE_GID}" \
        --create-home \
        --shell /bin/bash \
        "${EXECUTION_PLANE_USER}" \
    && mkdir -p /workspace \
    && chown -R "${EXECUTION_PLANE_USER}:${EXECUTION_PLANE_USER}" /workspace \
    && chown -R "${EXECUTION_PLANE_USER}:${EXECUTION_PLANE_USER}" "/usr/local/cargo"

WORKDIR /workspace
USER ${EXECUTION_PLANE_USER}
CMD ["bash"]
