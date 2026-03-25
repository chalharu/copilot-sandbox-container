FROM docker.io/library/rust:1.94.0-bookworm@sha256:365468470075493dc4583f47387001854321c5a8583ea9604b297e67f01c5a4f AS builder

# renovate: datasource=github-releases depName=mozilla/sccache versioning=semver
ARG SCCACHE_VERSION=0.14.0

SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]

RUN architecture="$(dpkg --print-architecture)" && \
    [ "${architecture}" = "amd64" ] || { \
      printf 'sccache-dist image only supports linux/amd64, got %s\n' "${architecture}" >&2; \
      exit 1; \
    } && \
    cargo install --locked --version "${SCCACHE_VERSION}" --features "dist-server" --bin sccache-dist --root /out/usr/local sccache

FROM docker.io/library/debian:bookworm-slim@sha256:f06537653ac770703bc45b4b113475bd402f451e85223f0f2837acbf89ab020a

# Bookworm is the smallest Debian base that still gives us bubblewrap for dist-server mode.
# hadolint ignore=DL3008
RUN apt-get update -o Acquire::Retries=3 && \
    apt-get install -y --no-install-recommends \
      bubblewrap \
      ca-certificates && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /out/usr/local/bin/sccache-dist /usr/local/bin/sccache-dist
COPY --chmod=755 entrypoint-dist.sh /usr/local/bin/sccache-dist-entrypoint

RUN useradd --uid 65532 --create-home --home-dir /home/nonroot --shell /usr/sbin/nologin nonroot && \
    mkdir -p /var/cache/sccache-dist /var/tmp/sccache-dist

ENV HOME=/home/nonroot \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

USER 65532:65532
WORKDIR /home/nonroot

ENTRYPOINT ["/usr/local/bin/sccache-dist-entrypoint"]
