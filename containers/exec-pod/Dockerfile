ARG RUST_BASE_IMAGE=docker.io/library/rust:1.95.0-bookworm@sha256:adab7941580c74513aa3347f2d2a1f975498280743d29ec62978ba12e3540d3a
# renovate: datasource=crate depName=cargo-chef
ARG CARGO_CHEF_VERSION=0.1.77
# renovate: datasource=github-releases depName=kubernetes/kubernetes
ARG KUBECTL_VERSION=v1.36.0
# renovate: datasource=github-releases depName=docker/buildx
ARG DOCKER_BUILDX_VERSION=v0.30.1

FROM ${RUST_BASE_IMAGE} AS cargo-chef

ARG CARGO_CHEF_VERSION
RUN cargo_home="${CARGO_HOME:-${HOME}/.cargo}" \
    && mkdir -p "${cargo_home}" /var/tmp/control-plane/cargo-target /build/control-plane \
    && ln -sfn /var/tmp/control-plane/cargo-target /build/control-plane/target \
    && printf '[build]\ntarget-dir = "/var/tmp/control-plane/cargo-target"\n' > "${cargo_home}/config.toml" \
    && cargo install cargo-chef --locked --version "${CARGO_CHEF_VERSION}"

FROM cargo-chef AS workspace-planner

WORKDIR /build/control-plane
COPY containers/control-plane/Cargo.toml containers/control-plane/Cargo.lock ./
COPY containers/control-plane/exec-api/ ./exec-api/
COPY containers/control-plane/exec-policy-preload/ ./exec-policy-preload/
COPY containers/control-plane/runtime-tools/ ./runtime-tools/
RUN cargo chef prepare --recipe-path recipe.json

FROM cargo-chef AS exec-policy-builder

WORKDIR /build/control-plane
COPY --from=workspace-planner /build/control-plane/recipe.json ./recipe.json
RUN cargo chef cook --locked --release --recipe-path recipe.json -p control-plane-exec-policy-preload
COPY containers/control-plane/Cargo.toml containers/control-plane/Cargo.lock ./
COPY containers/control-plane/exec-api/ ./exec-api/
COPY containers/control-plane/exec-policy-preload/ ./exec-policy-preload/
COPY containers/control-plane/runtime-tools/ ./runtime-tools/
COPY containers/control-plane/hooks/preToolUse/deny-rules.yaml ./hooks/preToolUse/deny-rules.yaml
RUN cargo test --locked --release -p control-plane-exec-policy-preload \
    && cargo build --locked --release -p control-plane-exec-policy-preload

FROM cargo-chef AS exec-api-builder

# hadolint ignore=DL3008
RUN apt-get update -o Acquire::Retries=3 \
    && apt-get install -y --no-install-recommends \
        musl-tools \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build/control-plane
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
COPY --from=workspace-planner /build/control-plane/recipe.json ./recipe.json
RUN target="$(rustc -vV | awk '/^host:/ { print $2 }' | sed 's/-unknown-linux-gnu/-unknown-linux-musl/')" \
    && rustup target add "${target}" \
    && cargo chef cook --locked --release --target "${target}" --recipe-path recipe.json -p control-plane-exec-api
COPY containers/control-plane/Cargo.toml containers/control-plane/Cargo.lock ./
COPY containers/control-plane/exec-api/ ./exec-api/
COPY containers/control-plane/exec-policy-preload/ ./exec-policy-preload/
COPY containers/control-plane/runtime-tools/ ./runtime-tools/
RUN target="$(rustc -vV | awk '/^host:/ { print $2 }' | sed 's/-unknown-linux-gnu/-unknown-linux-musl/')" \
    && rustup target add "${target}" \
    && cargo test --locked --release --target "${target}" -p control-plane-exec-api \
    && cargo build --locked --release --target "${target}" -p control-plane-exec-api \
    && install -D "/var/tmp/control-plane/cargo-target/${target}/release/control-plane-exec-api" \
        /var/tmp/control-plane/cargo-target/release/control-plane-exec-api

FROM cargo-chef AS runtime-tools-builder

WORKDIR /build/control-plane
COPY --from=workspace-planner /build/control-plane/recipe.json ./recipe.json
RUN cargo chef cook --locked --release --recipe-path recipe.json -p control-plane-runtime-tools
COPY containers/control-plane/Cargo.toml containers/control-plane/Cargo.lock ./
COPY containers/control-plane/exec-api/ ./exec-api/
COPY containers/control-plane/exec-policy-preload/ ./exec-policy-preload/
COPY containers/control-plane/runtime-tools/ ./runtime-tools/
COPY containers/control-plane/hooks/postToolUse/linters.json ./hooks/postToolUse/linters.json
RUN cargo test --locked --release -p control-plane-runtime-tools \
    && cargo build --locked --release -p control-plane-runtime-tools

FROM ${RUST_BASE_IMAGE}

ARG KUBECTL_VERSION
ARG DOCKER_BUILDX_VERSION
ARG CONTROL_PLANE_UID=1000
ARG CONTROL_PLANE_GID=1000
ARG CONTROL_PLANE_USER=copilot

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_CTYPE=C.UTF-8 \
    CARGO_TARGET_DIR=/var/tmp/control-plane/cargo-target \
    SCCACHE_DIR=/var/tmp/control-plane/sccache \
    RUSTC_WRAPPER=/usr/bin/sccache

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# hadolint ignore=DL3008
RUN apt-get update -o Acquire::Retries=3 \
    && apt-get install -y --no-install-recommends \
        bash \
        build-essential \
        ca-certificates \
        cmake \
        curl \
        docker.io \
        gh \
        git \
        jq \
        libssl-dev \
        openssh-client \
        pkg-config \
        pkgconf \
        python3 \
        ripgrep \
        sccache \
        sudo \
        yamllint \
    && arch="$(dpkg --print-architecture)" \
    && case "${arch}" in \
        amd64) kubectl_arch=amd64; buildx_arch=amd64 ;; \
        arm64) kubectl_arch=arm64; buildx_arch=arm64 ;; \
        *) printf 'Unsupported architecture for exec-pod tools: %s\n' "${arch}" >&2; exit 1 ;; \
    esac \
    && kubectl_download_root="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${kubectl_arch}" \
    && curl -fsSLo /tmp/kubectl "${kubectl_download_root}/kubectl" \
    && curl -fsSLo /tmp/kubectl.sha256 "${kubectl_download_root}/kubectl.sha256" \
    && awk '{ print $1 "  /tmp/kubectl"; found=1 } END { exit(found ? 0 : 1) }' /tmp/kubectl.sha256 | sha256sum -c - \
    && install -m 0755 /tmp/kubectl /usr/local/bin/kubectl \
    && buildx_download_root="https://github.com/docker/buildx/releases/download/${DOCKER_BUILDX_VERSION}" \
    && buildx_asset="buildx-${DOCKER_BUILDX_VERSION}.linux-${buildx_arch}" \
    && curl -fsSLo "/tmp/${buildx_asset}" "${buildx_download_root}/${buildx_asset}" \
    && curl -fsSLo /tmp/buildx-checksums.txt "${buildx_download_root}/checksums.txt" \
    && awk -v asset="${buildx_asset}" '$2 == asset || $2 == "*" asset { print $1 "  /tmp/" asset; found=1 } END { exit(found ? 0 : 1) }' /tmp/buildx-checksums.txt | sha256sum -c - \
    && install -D -m 0755 "/tmp/${buildx_asset}" /usr/libexec/docker/cli-plugins/docker-buildx \
    && groupadd --gid "${CONTROL_PLANE_GID}" "${CONTROL_PLANE_USER}" \
    && useradd --uid "${CONTROL_PLANE_UID}" \
        --gid "${CONTROL_PLANE_USER}" \
        --create-home \
        --home-dir "/home/${CONTROL_PLANE_USER}" \
        --shell /bin/bash \
        "${CONTROL_PLANE_USER}" \
    && passwd -d "${CONTROL_PLANE_USER}" \
    && printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${CONTROL_PLANE_USER}" > "/etc/sudoers.d/${CONTROL_PLANE_USER}" \
    && chmod 0440 "/etc/sudoers.d/${CONTROL_PLANE_USER}" \
    && mkdir -p /root/.cargo /root/.config /root/.copilot /var/tmp/control-plane/cargo-target /var/tmp/control-plane/sccache /workspace \
    && printf '[build]\ntarget-dir = "/var/tmp/control-plane/cargo-target"\nrustc-wrapper = "/usr/bin/sccache"\n' > /root/.cargo/config.toml \
    && chgrp -R "${CONTROL_PLANE_GID}" /root \
    && chmod 1770 /root \
    && chown -R "${CONTROL_PLANE_UID}:${CONTROL_PLANE_GID}" /var/tmp/control-plane /workspace \
    && rm -rf /var/lib/apt/lists/* /tmp/*

COPY containers/control-plane/hooks/ /usr/local/share/control-plane/hooks/
COPY --from=runtime-tools-builder /var/tmp/control-plane/cargo-target/release/control-plane-runtime-tool /usr/local/bin/control-plane-runtime-tool
COPY --from=exec-policy-builder /var/tmp/control-plane/cargo-target/release/libcontrol_plane_exec_policy.so /usr/local/lib/libcontrol_plane_exec_policy.so
COPY --from=exec-policy-builder /var/tmp/control-plane/cargo-target/release/control-plane-pre-tool-use-hook /usr/local/share/control-plane/hooks/preToolUse/main
COPY --from=exec-api-builder /var/tmp/control-plane/cargo-target/release/control-plane-exec-api /usr/local/bin/control-plane-exec-api

RUN ln -sf /usr/local/bin/control-plane-runtime-tool /usr/local/share/control-plane/hooks/postToolUse/main \
    && find /usr/local/share/control-plane/hooks -type d -exec chmod 755 {} + \
    && find /usr/local/share/control-plane/hooks -type f -exec chmod 644 {} + \
    && chmod 755 /usr/local/share/control-plane/hooks/preToolUse/main \
    && chmod 755 /usr/local/share/control-plane/hooks/postToolUse/control-plane-rust.sh \
    && for git_hook in pre-commit pre-push; do \
         if [ -f "/usr/local/share/control-plane/hooks/git/${git_hook}" ]; then chmod 755 "/usr/local/share/control-plane/hooks/git/${git_hook}"; fi; \
       done \
    && chmod 644 /usr/local/lib/libcontrol_plane_exec_policy.so

WORKDIR /workspace
USER root
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["bash", "-lc", "control-plane-exec-api --help >/dev/null && bash --version >/dev/null && sh -c true && rg --version >/dev/null && python3 --version >/dev/null && curl --version >/dev/null && docker --version >/dev/null && docker buildx version >/dev/null && cc --version >/dev/null && git --version >/dev/null && jq --version >/dev/null && cmake --version >/dev/null && pkgconf --version >/dev/null && pkg-config --version >/dev/null && test -e /usr/include/openssl/ssl.h && yamllint --version >/dev/null && kubectl version --client=true >/dev/null && rustup --version >/dev/null && rustc --version >/dev/null && cargo --version >/dev/null && sccache --version >/dev/null && sudo -V >/dev/null && test -x /usr/local/bin/control-plane-runtime-tool && test -r /usr/local/lib/libcontrol_plane_exec_policy.so"]
CMD ["/usr/local/bin/control-plane-exec-api", "serve"]
