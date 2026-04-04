FROM docker.io/library/alpine:3.23.3@sha256:25109184c71bdad752c8312a8623239686a9a2071e8825f20acb8f2198c3f659 AS fetcher

# renovate: datasource=github-releases depName=mozilla/sccache versioning=semver
ARG SCCACHE_VERSION=0.14.0
ARG SCCACHE_RELEASE_BASE_URL=https://github.com/mozilla/sccache/releases/download

SHELL ["/bin/ash", "-euxo", "pipefail", "-c"]

# Alpine repositories roll package revisions forward, so exact apk pins make main-branch publish builds brittle.
# hadolint ignore=DL3018
RUN apk add --no-cache \
    ca-certificates \
    curl \
    tar

RUN case "$(apk --print-arch)" in \
      x86_64) asset="sccache-v${SCCACHE_VERSION}-x86_64-unknown-linux-musl.tar.gz" ;; \
      aarch64) asset="sccache-v${SCCACHE_VERSION}-aarch64-unknown-linux-musl.tar.gz" ;; \
      armv7) asset="sccache-v${SCCACHE_VERSION}-armv7-unknown-linux-musleabi.tar.gz" ;; \
      x86) asset="sccache-v${SCCACHE_VERSION}-i686-unknown-linux-musl.tar.gz" ;; \
      riscv64) asset="sccache-v${SCCACHE_VERSION}-riscv64gc-unknown-linux-musl.tar.gz" ;; \
      s390x) asset="sccache-v${SCCACHE_VERSION}-s390x-unknown-linux-gnu.tar.gz" ;; \
      *) printf 'Unsupported architecture for sccache image: %s\n' "$(apk --print-arch)" >&2; exit 1 ;; \
    esac \
    && archive_url="${SCCACHE_RELEASE_BASE_URL}/v${SCCACHE_VERSION}/${asset}" \
    && checksum_url="${archive_url}.sha256" \
    && curl -fsSLo "/tmp/${asset}" "${archive_url}" \
    && curl -fsSLo "/tmp/${asset}.sha256" "${checksum_url}" \
    && checksum="$(awk 'NR == 1 { print $1; exit }' "/tmp/${asset}.sha256" | tr -d '\r\n')" \
    && test -n "${checksum}" \
    && printf '%s  %s\n' "${checksum}" "/tmp/${asset}" | sha256sum -c - \
    && tar -xzf "/tmp/${asset}" -C /tmp \
    && mkdir -p /out/usr/local/bin /out/etc/ssl/certs /out/home/nonroot /out/tmp \
    && install -m 0755 "$(find /tmp -type f -name sccache -print -quit)" /out/usr/local/bin/sccache \
    && cp /etc/ssl/certs/ca-certificates.crt /out/etc/ssl/certs/ca-certificates.crt \
    && chmod 1777 /out/tmp \
    && chown 65532:65532 /out/home/nonroot \
    && rm -rf /tmp/*

FROM scratch

COPY --from=fetcher /out/ /

ENV HOME=/home/nonroot \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
USER 65532:65532
WORKDIR /home/nonroot
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["/usr/local/bin/sccache", "--version"]

ENTRYPOINT ["/usr/local/bin/sccache"]
