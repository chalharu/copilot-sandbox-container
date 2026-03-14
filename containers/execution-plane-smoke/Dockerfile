FROM debian:bookworm-slim@sha256:74d56e3931e0d5a1dd51f8c8a2466d21de84a271cd3b5a733b803aa91abf4421

ARG EXECUTION_PLANE_UID=1000
ARG EXECUTION_PLANE_GID=1000
ARG EXECUTION_PLANE_USER=runner

ENV DEBIAN_FRONTEND=noninteractive

# hadolint ignore=DL3008
RUN apt-get update -o Acquire::Retries=3 \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        coreutils \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid "${EXECUTION_PLANE_GID}" "${EXECUTION_PLANE_USER}" \
    && useradd --uid "${EXECUTION_PLANE_UID}" \
        --gid "${EXECUTION_PLANE_GID}" \
        --create-home \
        --shell /bin/bash \
        "${EXECUTION_PLANE_USER}"

COPY --chmod=755 execution-plane-smoke /usr/local/bin/execution-plane-smoke

RUN mkdir -p /workspace \
    && chown -R "${EXECUTION_PLANE_USER}:${EXECUTION_PLANE_USER}" /workspace

WORKDIR /workspace
USER ${EXECUTION_PLANE_USER}
CMD ["bash"]
