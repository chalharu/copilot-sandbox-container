FROM node:24.14.1-bookworm-slim@sha256:b506e7321f176aae77317f99d67a24b272c1f09f1d10f1761f2773447d8da26c

ARG EXECUTION_PLANE_UID=1000
ARG EXECUTION_PLANE_GID=1000
ARG EXECUTION_PLANE_USER=runner

ENV DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# hadolint ignore=DL3008
RUN apt-get update -o Acquire::Retries=3 \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && corepack enable \
    && existing_group="$(getent group "${EXECUTION_PLANE_GID}" | cut -d: -f1 || true)" \
    && if [ -n "${existing_group}" ] && [ "${existing_group}" != "${EXECUTION_PLANE_USER}" ]; then \
        groupmod --new-name "${EXECUTION_PLANE_USER}" "${existing_group}"; \
    elif [ -z "${existing_group}" ] && ! getent group "${EXECUTION_PLANE_USER}" >/dev/null; then \
        groupadd --gid "${EXECUTION_PLANE_GID}" "${EXECUTION_PLANE_USER}"; \
    fi \
    && if getent group "${EXECUTION_PLANE_USER}" >/dev/null; then \
        groupmod --gid "${EXECUTION_PLANE_GID}" "${EXECUTION_PLANE_USER}"; \
    fi \
    && existing_user="$(getent passwd "${EXECUTION_PLANE_UID}" | cut -d: -f1 || true)" \
    && if [ -n "${existing_user}" ] && [ "${existing_user}" != "${EXECUTION_PLANE_USER}" ]; then \
        usermod --login "${EXECUTION_PLANE_USER}" \
            --home "/home/${EXECUTION_PLANE_USER}" \
            --move-home \
            --shell /bin/bash \
            --gid "${EXECUTION_PLANE_USER}" \
            "${existing_user}"; \
    elif ! getent passwd "${EXECUTION_PLANE_USER}" >/dev/null; then \
        useradd --uid "${EXECUTION_PLANE_UID}" \
            --gid "${EXECUTION_PLANE_USER}" \
            --create-home \
            --home-dir "/home/${EXECUTION_PLANE_USER}" \
            --shell /bin/bash \
            "${EXECUTION_PLANE_USER}"; \
    fi \
    && usermod --uid "${EXECUTION_PLANE_UID}" \
        --gid "${EXECUTION_PLANE_USER}" \
        --home "/home/${EXECUTION_PLANE_USER}" \
        --shell /bin/bash \
        "${EXECUTION_PLANE_USER}" \
    && mkdir -p /workspace \
    && chown -R "${EXECUTION_PLANE_USER}:${EXECUTION_PLANE_USER}" /workspace

WORKDIR /workspace
USER ${EXECUTION_PLANE_USER}
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["bash", "-lc", "node --version >/dev/null && npm --version >/dev/null && corepack --version >/dev/null"]
CMD ["bash"]
