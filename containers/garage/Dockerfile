# hadolint global ignore=DL3008
ARG GARAGE_VERSION=2.2.0
FROM docker.io/dxflrs/garage:v${GARAGE_VERSION} AS garage-binary

FROM docker.io/library/debian:bookworm-slim@sha256:f06537653ac770703bc45b4b113475bd402f451e85223f0f2837acbf89ab020a

SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]

# Debian revisions move over time, so exact apt pins make main-branch publish builds brittle.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        awscli \
        bash \
        ca-certificates \
        curl \
        jq \
    && rm -rf /var/lib/apt/lists/*

COPY --from=garage-binary /garage /usr/local/bin/garage
COPY --chmod=755 entrypoint.sh /usr/local/bin/garage-entrypoint

ENTRYPOINT ["/usr/local/bin/garage-entrypoint"]
