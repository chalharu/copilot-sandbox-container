FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        coreutils \
    && rm -rf /var/lib/apt/lists/*

COPY --chmod=755 execution-plane-smoke /usr/local/bin/execution-plane-smoke

RUN mkdir -p /workspace

WORKDIR /workspace
CMD ["bash"]
