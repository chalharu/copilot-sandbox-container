FROM python:3.12.13-bookworm

ARG EXECUTION_PLANE_UID=1000
ARG EXECUTION_PLANE_GID=1000
ARG EXECUTION_PLANE_USER=runner

ENV DEBIAN_FRONTEND=noninteractive \
    VIRTUAL_ENV=/workspace/.venv

# hadolint ignore=DL3008
RUN apt-get update -o Acquire::Retries=3 \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        python3-venv \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid "${EXECUTION_PLANE_GID}" "${EXECUTION_PLANE_USER}" \
    && useradd --uid "${EXECUTION_PLANE_UID}" \
        --gid "${EXECUTION_PLANE_GID}" \
        --create-home \
        --shell /bin/bash \
        "${EXECUTION_PLANE_USER}" \
    && mkdir -p /workspace \
    && chown -R "${EXECUTION_PLANE_USER}:${EXECUTION_PLANE_USER}" /workspace

WORKDIR /workspace
USER ${EXECUTION_PLANE_USER}
CMD ["bash"]
