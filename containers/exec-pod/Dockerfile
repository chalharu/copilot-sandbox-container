ARG RUST_BASE_IMAGE=docker.io/library/rust:1.97.1-bookworm@sha256:77fac8b98f9f46062bb680b6d25d5bcaabfc400143952ebc572e924bcbedc3fa
# renovate: datasource=crate depName=cargo-chef
ARG CARGO_CHEF_VERSION=0.1.77
ARG CARGO_CHEF_X86_64_UNKNOWN_LINUX_GNU_SHA256=ff390181459f53c787a496c4ee9a52d8c9c7975ab8d02c8dbd1a0fa1626171f4
ARG CARGO_CHEF_AARCH64_UNKNOWN_LINUX_GNU_SHA256=64cd1b405894f587a461a0dd0f60127330b1ebd204fd46b1a36fb0ff6da157e0
# renovate: datasource=crate depName=trunk
ARG TRUNK_VERSION=0.21.14
ARG TRUNK_X86_64_UNKNOWN_LINUX_GNU_SHA256=f2b4680cd239693a646a2795e4633c625328d7b2a044fbe749fa3a2fe9e7036b
ARG TRUNK_AARCH64_UNKNOWN_LINUX_GNU_SHA256=b1d8e60e454f7fc182d9a4d95d1506ffbae947d8ba90f8f6f02da93b60f980f9
# renovate: datasource=crate depName=wasm-bindgen-cli
ARG WASM_BINDGEN_CLI_VERSION=0.2.120
ARG WASM_BINDGEN_X86_64_UNKNOWN_LINUX_MUSL_SHA256=ceb6f0b9fea9d2868f258215a1d7f86a4c28330a0d64432cc7d53674618772d6
ARG WASM_BINDGEN_AARCH64_UNKNOWN_LINUX_GNU_SHA256=430abb4d1f2b68ba266bac223542747fcb994df2a300ed5edffc7dbaa219ff9d
# renovate: datasource=crate depName=cargo-deny
ARG CARGO_DENY_VERSION=0.19.4
ARG CARGO_DENY_X86_64_UNKNOWN_LINUX_MUSL_SHA256=3bd58b784e83715b86ddbc9deac591890372ec77fda5741bb0826970b958506f
ARG CARGO_DENY_AARCH64_UNKNOWN_LINUX_MUSL_SHA256=c32ded194b38b48e0b44a838a0d85c856120801e1253fc7febf6f2e48ccb84d8
# renovate: datasource=crate depName=cargo-audit
ARG CARGO_AUDIT_VERSION=0.22.1
ARG CARGO_AUDIT_X86_64_UNKNOWN_LINUX_MUSL_SHA256=c32506f338bdcdaef5a17fb9f33abb6ecf9561324cfd34237fd335f9283a1eab
ARG CARGO_AUDIT_AARCH64_UNKNOWN_LINUX_GNU_SHA256=4c8df835ee484441bd2c8c6bcac28c4ce4b4058ba9e7477cb9e0012fe7769f66
# renovate: datasource=crate depName=cargo-llvm-cov
ARG CARGO_LLVM_COV_VERSION=0.8.5
ARG CARGO_LLVM_COV_X86_64_UNKNOWN_LINUX_GNU_SHA256=7e62d664f5133d43d33a3b11138c93feff98bd71e953ddc260ea8ddf360a37c6
ARG CARGO_LLVM_COV_AARCH64_UNKNOWN_LINUX_GNU_SHA256=8248a6d5dcb47307c2ef6d5815f90bca07d04a6f1acd06b658f689cb2d8247d9
# renovate: datasource=crate depName=taplo-cli
ARG TAPLO_CLI_VERSION=0.10.0
ARG TAPLO_LINUX_X86_64_SHA256=8fe196b894ccf9072f98d4e1013a180306e17d244830b03986ee5e8eabeb6156
ARG TAPLO_LINUX_AARCH64_SHA256=033681d01eec8376c3fd38fa3703c79316f5e14bb013d859943b60a07bccdcc3
# renovate: datasource=node-version depName=node
ARG NODE_VERSION=24.18.0
# renovate: datasource=npm depName=pnpm
ARG PNPM_VERSION=11.17.0
# renovate: datasource=pypi depName=lizard
ARG LIZARD_VERSION=1.23.0
# Keep the Chrome for Testing version and Linux64 digests in sync when updating them.
ARG CHROME_FOR_TESTING_VERSION=148.0.7778.97
ARG CHROME_FOR_TESTING_CHROME_LINUX64_SHA256=8a760543807c67d3836d530cc4bc2e39c93e217f1629ec6ea311415fdfa21a75
ARG CHROME_FOR_TESTING_CHROMEDRIVER_LINUX64_SHA256=ad324679086572b638a0388a96f21185615482c55aafc45f3f01adf134fafbf5
# renovate: datasource=github-releases depName=kubernetes/kubernetes
ARG KUBECTL_VERSION=v1.36.2
# renovate: datasource=github-releases depName=docker/buildx
ARG DOCKER_BUILDX_VERSION=v0.35.0

FROM ${RUST_BASE_IMAGE} AS cargo-chef

ARG CARGO_CHEF_VERSION
ARG CARGO_CHEF_X86_64_UNKNOWN_LINUX_GNU_SHA256
ARG CARGO_CHEF_AARCH64_UNKNOWN_LINUX_GNU_SHA256
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# hadolint ignore=DL3008
RUN apt-get update -o Acquire::Retries=3 \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        xz-utils \
    && cargo_home="${CARGO_HOME:-${HOME}/.cargo}" \
    && mkdir -p "${cargo_home}" /var/tmp/control-plane/cargo-target /build/control-plane \
    && ln -sfn /var/tmp/control-plane/cargo-target /build/control-plane/target \
    && printf '[build]\ntarget-dir = "/var/tmp/control-plane/cargo-target"\n' > "${cargo_home}/config.toml" \
    && mkdir -p "${cargo_home}/bin" \
    && case "$(dpkg --print-architecture)" in \
        amd64) cargo_chef_asset="cargo-chef-x86_64-unknown-linux-gnu.tar.xz"; cargo_chef_sha256="${CARGO_CHEF_X86_64_UNKNOWN_LINUX_GNU_SHA256}" ;; \
        arm64) cargo_chef_asset="cargo-chef-aarch64-unknown-linux-gnu.tar.xz"; cargo_chef_sha256="${CARGO_CHEF_AARCH64_UNKNOWN_LINUX_GNU_SHA256}" ;; \
        *) printf 'Unsupported architecture for cargo-chef: %s\n' "$(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac \
    && cargo_chef_download_root="https://github.com/LukeMathWalker/cargo-chef/releases/download/v${CARGO_CHEF_VERSION}" \
    && curl -fsSLo "/tmp/${cargo_chef_asset}" "${cargo_chef_download_root}/${cargo_chef_asset}" \
    && printf '%s  %s\n' "${cargo_chef_sha256}" "/tmp/${cargo_chef_asset}" | sha256sum -c - \
    && cargo_chef_dir="$(tar -tf "/tmp/${cargo_chef_asset}" | awk -F/ 'NF > 1 && $NF == "cargo-chef" { print $1; found=1; exit } END { exit(found ? 0 : 1) }')" \
    && tar -xJf "/tmp/${cargo_chef_asset}" -C /tmp \
    && install -m 0755 "/tmp/${cargo_chef_dir}/cargo-chef" "${cargo_home}/bin/cargo-chef" \
    && rm -rf /var/lib/apt/lists/* /tmp/*

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

FROM cargo-chef AS cargo-tools-builder

ARG TRUNK_VERSION
ARG TRUNK_X86_64_UNKNOWN_LINUX_GNU_SHA256
ARG TRUNK_AARCH64_UNKNOWN_LINUX_GNU_SHA256
ARG WASM_BINDGEN_CLI_VERSION
ARG WASM_BINDGEN_X86_64_UNKNOWN_LINUX_MUSL_SHA256
ARG WASM_BINDGEN_AARCH64_UNKNOWN_LINUX_GNU_SHA256
ARG CARGO_DENY_VERSION
ARG CARGO_DENY_X86_64_UNKNOWN_LINUX_MUSL_SHA256
ARG CARGO_DENY_AARCH64_UNKNOWN_LINUX_MUSL_SHA256
ARG CARGO_AUDIT_VERSION
ARG CARGO_AUDIT_X86_64_UNKNOWN_LINUX_MUSL_SHA256
ARG CARGO_AUDIT_AARCH64_UNKNOWN_LINUX_GNU_SHA256
ARG CARGO_LLVM_COV_VERSION
ARG CARGO_LLVM_COV_X86_64_UNKNOWN_LINUX_GNU_SHA256
ARG CARGO_LLVM_COV_AARCH64_UNKNOWN_LINUX_GNU_SHA256
ARG TAPLO_CLI_VERSION
ARG TAPLO_LINUX_X86_64_SHA256
ARG TAPLO_LINUX_AARCH64_SHA256

# hadolint ignore=DL3008
RUN apt-get update -o Acquire::Retries=3 \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gzip \
    && rm -rf /var/lib/apt/lists/*

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN mkdir -p /opt/control-plane-tools/bin \
    && case "$(dpkg --print-architecture)" in \
        amd64) \
            trunk_asset="trunk-x86_64-unknown-linux-gnu.tar.gz"; \
            trunk_sha256="${TRUNK_X86_64_UNKNOWN_LINUX_GNU_SHA256}"; \
            wasm_bindgen_asset="wasm-bindgen-${WASM_BINDGEN_CLI_VERSION}-x86_64-unknown-linux-musl.tar.gz"; \
            wasm_bindgen_sha256="${WASM_BINDGEN_X86_64_UNKNOWN_LINUX_MUSL_SHA256}"; \
            cargo_deny_asset="cargo-deny-${CARGO_DENY_VERSION}-x86_64-unknown-linux-musl.tar.gz"; \
            cargo_deny_sha256="${CARGO_DENY_X86_64_UNKNOWN_LINUX_MUSL_SHA256}"; \
            cargo_audit_asset="cargo-audit-x86_64-unknown-linux-musl-v${CARGO_AUDIT_VERSION}.tgz"; \
            cargo_audit_sha256="${CARGO_AUDIT_X86_64_UNKNOWN_LINUX_MUSL_SHA256}"; \
            cargo_llvm_cov_asset="cargo-llvm-cov-x86_64-unknown-linux-gnu.tar.gz"; \
            cargo_llvm_cov_sha256="${CARGO_LLVM_COV_X86_64_UNKNOWN_LINUX_GNU_SHA256}"; \
            taplo_asset="taplo-linux-x86_64.gz"; \
            taplo_sha256="${TAPLO_LINUX_X86_64_SHA256}"; \
            ;; \
        arm64) \
            trunk_asset="trunk-aarch64-unknown-linux-gnu.tar.gz"; \
            trunk_sha256="${TRUNK_AARCH64_UNKNOWN_LINUX_GNU_SHA256}"; \
            wasm_bindgen_asset="wasm-bindgen-${WASM_BINDGEN_CLI_VERSION}-aarch64-unknown-linux-gnu.tar.gz"; \
            wasm_bindgen_sha256="${WASM_BINDGEN_AARCH64_UNKNOWN_LINUX_GNU_SHA256}"; \
            cargo_deny_asset="cargo-deny-${CARGO_DENY_VERSION}-aarch64-unknown-linux-musl.tar.gz"; \
            cargo_deny_sha256="${CARGO_DENY_AARCH64_UNKNOWN_LINUX_MUSL_SHA256}"; \
            cargo_audit_asset="cargo-audit-aarch64-unknown-linux-gnu-v${CARGO_AUDIT_VERSION}.tgz"; \
            cargo_audit_sha256="${CARGO_AUDIT_AARCH64_UNKNOWN_LINUX_GNU_SHA256}"; \
            cargo_llvm_cov_asset="cargo-llvm-cov-aarch64-unknown-linux-gnu.tar.gz"; \
            cargo_llvm_cov_sha256="${CARGO_LLVM_COV_AARCH64_UNKNOWN_LINUX_GNU_SHA256}"; \
            taplo_asset="taplo-linux-aarch64.gz"; \
            taplo_sha256="${TAPLO_LINUX_AARCH64_SHA256}"; \
            ;; \
        *) printf 'Unsupported architecture for cargo tools: %s\n' "$(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac \
    && trunk_download_root="https://github.com/trunk-rs/trunk/releases/download/v${TRUNK_VERSION}" \
    && curl -fsSLo "/tmp/${trunk_asset}" "${trunk_download_root}/${trunk_asset}" \
    && printf '%s  %s\n' "${trunk_sha256}" "/tmp/${trunk_asset}" | sha256sum -c - \
    && tar -xzf "/tmp/${trunk_asset}" -C /tmp \
    && install -m 0755 /tmp/trunk /opt/control-plane-tools/bin/trunk \
    && wasm_bindgen_download_root="https://github.com/rustwasm/wasm-bindgen/releases/download/${WASM_BINDGEN_CLI_VERSION}" \
    && curl -fsSLo "/tmp/${wasm_bindgen_asset}" "${wasm_bindgen_download_root}/${wasm_bindgen_asset}" \
    && printf '%s  %s\n' "${wasm_bindgen_sha256}" "/tmp/${wasm_bindgen_asset}" | sha256sum -c - \
    && wasm_bindgen_dir="$(tar -tf "/tmp/${wasm_bindgen_asset}" | awk -F/ 'NF > 1 && $2 == "wasm-bindgen" { print $1; found=1; exit } END { exit(found ? 0 : 1) }')" \
    && tar -xzf "/tmp/${wasm_bindgen_asset}" -C /tmp \
    && install -m 0755 "/tmp/${wasm_bindgen_dir}/wasm-bindgen" /opt/control-plane-tools/bin/wasm-bindgen \
    && install -m 0755 "/tmp/${wasm_bindgen_dir}/wasm-bindgen-test-runner" /opt/control-plane-tools/bin/wasm-bindgen-test-runner \
    && install -m 0755 "/tmp/${wasm_bindgen_dir}/wasm2es6js" /opt/control-plane-tools/bin/wasm2es6js \
    && cargo_deny_download_root="https://github.com/EmbarkStudios/cargo-deny/releases/download/${CARGO_DENY_VERSION}" \
    && curl -fsSLo "/tmp/${cargo_deny_asset}" "${cargo_deny_download_root}/${cargo_deny_asset}" \
    && printf '%s  %s\n' "${cargo_deny_sha256}" "/tmp/${cargo_deny_asset}" | sha256sum -c - \
    && cargo_deny_dir="$(tar -tf "/tmp/${cargo_deny_asset}" | awk -F/ 'NF > 1 && $2 == "cargo-deny" { print $1; found=1; exit } END { exit(found ? 0 : 1) }')" \
    && tar -xzf "/tmp/${cargo_deny_asset}" -C /tmp \
    && install -m 0755 "/tmp/${cargo_deny_dir}/cargo-deny" /opt/control-plane-tools/bin/cargo-deny \
    && cargo_audit_download_root="https://github.com/rustsec/rustsec/releases/download/cargo-audit/v${CARGO_AUDIT_VERSION}" \
    && curl -fsSLo "/tmp/${cargo_audit_asset}" "${cargo_audit_download_root}/${cargo_audit_asset}" \
    && printf '%s  %s\n' "${cargo_audit_sha256}" "/tmp/${cargo_audit_asset}" | sha256sum -c - \
    && cargo_audit_dir="$(tar -tf "/tmp/${cargo_audit_asset}" | awk -F/ 'NF > 1 && $2 == "cargo-audit" { print $1; found=1; exit } END { exit(found ? 0 : 1) }')" \
    && tar -xzf "/tmp/${cargo_audit_asset}" -C /tmp \
    && install -m 0755 "/tmp/${cargo_audit_dir}/cargo-audit" /opt/control-plane-tools/bin/cargo-audit \
    && cargo_llvm_cov_download_root="https://github.com/taiki-e/cargo-llvm-cov/releases/download/v${CARGO_LLVM_COV_VERSION}" \
    && curl -fsSLo "/tmp/${cargo_llvm_cov_asset}" "${cargo_llvm_cov_download_root}/${cargo_llvm_cov_asset}" \
    && printf '%s  %s\n' "${cargo_llvm_cov_sha256}" "/tmp/${cargo_llvm_cov_asset}" | sha256sum -c - \
    && tar -xzf "/tmp/${cargo_llvm_cov_asset}" -C /tmp \
    && install -m 0755 /tmp/cargo-llvm-cov /opt/control-plane-tools/bin/cargo-llvm-cov \
    && taplo_download_root="https://github.com/tamasfe/taplo/releases/download/${TAPLO_CLI_VERSION}" \
    && curl -fsSLo "/tmp/${taplo_asset}" "${taplo_download_root}/${taplo_asset}" \
    && printf '%s  %s\n' "${taplo_sha256}" "/tmp/${taplo_asset}" | sha256sum -c - \
    && gzip -dc "/tmp/${taplo_asset}" > /opt/control-plane-tools/bin/taplo \
    && chmod 0755 /opt/control-plane-tools/bin/taplo

FROM ${RUST_BASE_IMAGE}
ARG NODE_VERSION
ARG KUBECTL_VERSION
ARG DOCKER_BUILDX_VERSION
ARG PNPM_VERSION
ARG LIZARD_VERSION
ARG CHROME_FOR_TESTING_VERSION
ARG CHROME_FOR_TESTING_CHROME_LINUX64_SHA256
ARG CHROME_FOR_TESTING_CHROMEDRIVER_LINUX64_SHA256
ARG CONTROL_PLANE_UID=1000
ARG CONTROL_PLANE_GID=1000
ARG CONTROL_PLANE_USER=copilot

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_CTYPE=C.UTF-8 \
    HOME=/home/${CONTROL_PLANE_USER} \
    CONTROL_PLANE_FAST_EXECUTION_HOME=/home/${CONTROL_PLANE_USER} \
    CARGO_TARGET_DIR=/var/tmp/control-plane/cargo-target \
    SCCACHE_DIR=/var/tmp/control-plane/sccache \
    RUSTC_WRAPPER=/usr/bin/sccache \
    LIZARD_VIRTUAL_ENV=/opt/lizard

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# hadolint ignore=DL3008
RUN apt-get update -o Acquire::Retries=3 \
    && browser_apt_packages=() \
    && arch="$(dpkg --print-architecture)" \
    && case "${arch}" in \
        amd64) \
          kubectl_arch=amd64; \
          buildx_arch=amd64; \
          node_arch=x64; \
          chrome_install_mode=chrome-for-testing; \
          chrome_for_testing_platform=linux64; \
          ;; \
        arm64) \
          kubectl_arch=arm64; \
          buildx_arch=arm64; \
          node_arch=arm64; \
          chrome_install_mode=debian-chromium; \
          browser_apt_packages=(chromium chromium-driver); \
          ;; \
        *) printf 'Unsupported architecture for exec-pod tools: %s\n' "${arch}" >&2; exit 1 ;; \
    esac \
    && apt-get install -y --no-install-recommends \
        bash \
        binaryen \
        build-essential \
        ca-certificates \
        cmake \
        curl \
        docker.io \
        gh \
        git \
        jq \
        libgtk-3-dev \
        libgtk-4-dev \
        libpango1.0-dev \
        libssl-dev \
        mold \
        nodejs \
        npm \
        openssh-client \
        pkg-config \
        pkgconf \
        python3 \
        python3-pathspec \
        python3-pygments \
        python3-venv \
        ripgrep \
        sccache \
        sudo \
        unzip \
        xz-utils \
        xdg-utils \
        yamllint \
        fonts-liberation \
        libasound2 \
        libatk-bridge2.0-0 \
        libatk1.0-0 \
        libcups2 \
        libdbus-1-3 \
        libdrm2 \
        libgbm1 \
        libgtk-3-0 \
        libnspr4 \
        libnss3 \
        libu2f-udev \
        libvulkan1 \
        libx11-6 \
        libx11-xcb1 \
        libxcb1 \
        libxcomposite1 \
        libxdamage1 \
        libxext6 \
        libxfixes3 \
        libxkbcommon0 \
        libxrandr2 \
        "${browser_apt_packages[@]}" \
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
    && node_download_root="https://nodejs.org/dist/v${NODE_VERSION}" \
    && node_asset="node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" \
    && curl -fsSLo "/tmp/${node_asset}" "${node_download_root}/${node_asset}" \
    && curl -fsSLo /tmp/node-SHASUMS256.txt "${node_download_root}/SHASUMS256.txt" \
    && awk -v asset="${node_asset}" '$2 == asset { print $1 "  /tmp/" asset; found=1 } END { exit(found ? 0 : 1) }' /tmp/node-SHASUMS256.txt | sha256sum -c - \
    && install -d /opt/control-plane-pnpm-node/bin \
    && tar -xJf "/tmp/${node_asset}" -C /opt/control-plane-pnpm-node/bin --strip-components=2 \
        "node-v${NODE_VERSION}-linux-${node_arch}/bin/node" \
    && chmod 0755 /opt/control-plane-pnpm-node/bin/node \
    && rm -f "/tmp/${node_asset}" /tmp/node-SHASUMS256.txt \
    && ln -sfn /opt/control-plane-pnpm-node/bin/node /usr/local/bin/node \
    && ln -sfn /opt/control-plane-pnpm-node/bin/node /usr/local/bin/nodejs \
    && ln -sfn /opt/control-plane-pnpm-node/bin/node /usr/bin/node \
    && ln -sfn /opt/control-plane-pnpm-node/bin/node /usr/bin/nodejs \
    && npm_entry="$(readlink -f "$(command -v npm)")" \
    && rm -f /usr/local/bin/npm \
    && printf '%s\n' '#!/usr/bin/env bash' \
        "export PATH=\"/opt/control-plane-pnpm-node/bin:\${PATH}\"" \
        "exec /opt/control-plane-pnpm-node/bin/node \"${npm_entry}\" \"\$@\"" \
        > /usr/local/bin/npm \
    && chmod 0755 /usr/local/bin/npm \
    && node --version >/dev/null \
    && npm --version >/dev/null \
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
    && mkdir -p /root/.cargo "/home/${CONTROL_PLANE_USER}/.cargo" /root/.config /root/.copilot /var/tmp/control-plane/cargo-target /var/tmp/control-plane/sccache /workspace \
    && printf '[build]\ntarget-dir = "/var/tmp/control-plane/cargo-target"\nrustc-wrapper = "/usr/bin/sccache"\n' > /root/.cargo/config.toml \
    && cp /root/.cargo/config.toml "/home/${CONTROL_PLANE_USER}/.cargo/config.toml" \
    && rustup target add wasm32-unknown-unknown \
    && rustup component add clippy llvm-tools-preview rustfmt \
    && curl -fsSLo /tmp/lizard-pypi.json "https://pypi.org/pypi/lizard/${LIZARD_VERSION}/json" \
    && lizard_wheel="$(jq -er 'first(.urls[] | select(.packagetype == "bdist_wheel" and (.filename | endswith("-none-any.whl"))) | .filename)' /tmp/lizard-pypi.json)" \
    && lizard_url="$(jq -er --arg filename "${lizard_wheel}" 'first(.urls[] | select(.filename == $filename) | .url)' /tmp/lizard-pypi.json)" \
    && lizard_sha256="$(jq -er --arg filename "${lizard_wheel}" 'first(.urls[] | select(.filename == $filename) | .digests.sha256)' /tmp/lizard-pypi.json)" \
    && curl -fsSLo "/tmp/${lizard_wheel}" "${lizard_url}" \
    && printf '%s  %s\n' "${lizard_sha256}" "/tmp/${lizard_wheel}" | sha256sum -c - \
    && python3 -m venv --system-site-packages "${LIZARD_VIRTUAL_ENV}" \
    && "${LIZARD_VIRTUAL_ENV}/bin/pip" install --no-cache-dir --no-deps "/tmp/${lizard_wheel}" \
    && ln -sf "${LIZARD_VIRTUAL_ENV}/bin/lizard" /usr/local/bin/lizard \
    && curl -fsSLo /tmp/pnpm-metadata.json "https://registry.npmjs.org/pnpm/${PNPM_VERSION}" \
    && pnpm_tarball_url="$(jq -er '.dist.tarball' /tmp/pnpm-metadata.json)" \
    && pnpm_integrity="$(jq -er '.dist.integrity' /tmp/pnpm-metadata.json)" \
    && curl -fsSLo /tmp/pnpm.tgz "${pnpm_tarball_url}" \
    && python3 -c 'import base64, hashlib, pathlib, sys; algorithm, expected = sys.argv[1].split("-", 1); actual = base64.b64encode(hashlib.new(algorithm, pathlib.Path(sys.argv[2]).read_bytes()).digest()).decode(); sys.exit(0 if actual == expected else f"pnpm integrity mismatch: expected {expected}, got {actual}")' "${pnpm_integrity}" /tmp/pnpm.tgz \
    && npm install --global "/tmp/pnpm.tgz" \
    && npm cache clean --force \
    && pnpm_package_root="$(npm root --global)/pnpm" \
    && pnpm_entry="${pnpm_package_root}/$(jq -er '.bin.pnpm' "${pnpm_package_root}/package.json")" \
    && rm -f /usr/local/bin/pnpm \
    && printf '%s\n' '#!/usr/bin/env bash' \
        "export PATH=\"/opt/control-plane-pnpm-node/bin:\${PATH}\"" \
        "exec /opt/control-plane-pnpm-node/bin/node \"${pnpm_entry}\" \"\$@\"" \
        > /usr/local/bin/pnpm \
    && chmod 0755 /usr/local/bin/pnpm \
    && pnpx_relative="$(jq -er '.bin.pnpx // empty' "${pnpm_package_root}/package.json")" \
    && if [ -n "${pnpx_relative}" ]; then \
         pnpx_entry="${pnpm_package_root}/${pnpx_relative}"; \
         rm -f /usr/local/bin/pnpx; \
         printf '%s\n' '#!/usr/bin/env bash' \
           "export PATH=\"/opt/control-plane-pnpm-node/bin:\${PATH}\"" \
           "exec /opt/control-plane-pnpm-node/bin/node \"${pnpx_entry}\" \"\$@\"" \
           > /usr/local/bin/pnpx; \
         chmod 0755 /usr/local/bin/pnpx; \
       fi \
    && pnpm --version >/dev/null \
    && case "${chrome_install_mode}" in \
        chrome-for-testing) \
          curl -fsSLo /tmp/chrome-for-testing.json "https://googlechromelabs.github.io/chrome-for-testing/${CHROME_FOR_TESTING_VERSION}.json" \
          && jq -er --arg version "${CHROME_FOR_TESTING_VERSION}" 'select(.version == $version) | .version' /tmp/chrome-for-testing.json >/dev/null \
          && chrome_download_url="$(jq -er --arg platform "${chrome_for_testing_platform}" 'first(.downloads.chrome[] | select(.platform == $platform) | .url)' /tmp/chrome-for-testing.json)" \
          && chromedriver_download_url="$(jq -er --arg platform "${chrome_for_testing_platform}" 'first(.downloads.chromedriver[] | select(.platform == $platform) | .url)' /tmp/chrome-for-testing.json)" \
          && curl -fsSLo /tmp/chrome-linux64.zip "${chrome_download_url}" \
          && printf '%s  %s\n' "${CHROME_FOR_TESTING_CHROME_LINUX64_SHA256}" /tmp/chrome-linux64.zip | sha256sum -c - \
          && curl -fsSLo /tmp/chromedriver-linux64.zip "${chromedriver_download_url}" \
          && printf '%s  %s\n' "${CHROME_FOR_TESTING_CHROMEDRIVER_LINUX64_SHA256}" /tmp/chromedriver-linux64.zip | sha256sum -c - \
          && unzip -q /tmp/chrome-linux64.zip -d /opt \
          && unzip -q /tmp/chromedriver-linux64.zip -d /opt \
          && ln -sf /opt/chrome-linux64/chrome /usr/local/bin/google-chrome \
          && ln -sf /usr/local/bin/google-chrome /usr/local/bin/google-chrome-stable \
          && ln -sf /usr/local/bin/google-chrome /usr/local/bin/chrome \
          && ln -sf /opt/chromedriver-linux64/chromedriver /usr/local/bin/chromedriver \
          ;; \
        debian-chromium) \
          ln -sf /usr/bin/chromium /usr/local/bin/google-chrome \
          && ln -sf /usr/local/bin/google-chrome /usr/local/bin/google-chrome-stable \
          && ln -sf /usr/local/bin/google-chrome /usr/local/bin/chrome \
          && ln -sf /usr/bin/chromedriver /usr/local/bin/chromedriver \
          ;; \
      esac \
    && printf '%s\n' '#!/usr/bin/env bash' 'unset LD_PRELOAD CONTROL_PLANE_EXEC_POLICY_RULES_FILE' 'exec /usr/bin/mold "$@"' > /usr/local/bin/mold \
    && chmod 755 /usr/local/bin/mold \
    && if [ -x /usr/bin/ld.mold ]; then \
         printf '%s\n' '#!/usr/bin/env bash' 'unset LD_PRELOAD CONTROL_PLANE_EXEC_POLICY_RULES_FILE' 'exec /usr/bin/ld.mold "$@"' > /usr/local/bin/ld.mold; \
         chmod 755 /usr/local/bin/ld.mold; \
       fi \
    && ln -sf /usr/local/cargo/bin/cargo /usr/local/bin/cargo \
    && ln -sf /usr/local/cargo/bin/rustc /usr/local/bin/rustc \
    && ln -sf /usr/local/cargo/bin/rustdoc /usr/local/bin/rustdoc \
    && ln -sf /usr/local/cargo/bin/rustfmt /usr/local/bin/rustfmt \
    && ln -sf /usr/local/cargo/bin/rustup /usr/local/bin/rustup \
    && if [ -x /usr/local/cargo/bin/cargo-clippy ]; then ln -sf /usr/local/cargo/bin/cargo-clippy /usr/local/bin/cargo-clippy; fi \
    && if [ -x /usr/local/cargo/bin/cargo-fmt ]; then ln -sf /usr/local/cargo/bin/cargo-fmt /usr/local/bin/cargo-fmt; fi \
    && if [ -x /usr/local/cargo/bin/clippy-driver ]; then ln -sf /usr/local/cargo/bin/clippy-driver /usr/local/bin/clippy-driver; fi \
    && chgrp -R "${CONTROL_PLANE_GID}" /root \
    && chmod 1770 /root \
    && chown -R "${CONTROL_PLANE_UID}:${CONTROL_PLANE_GID}" "/home/${CONTROL_PLANE_USER}" /var/tmp/control-plane /workspace \
    && rm -rf /var/lib/apt/lists/* /tmp/*

COPY containers/control-plane/hooks/ /usr/local/share/control-plane/hooks/
COPY --from=cargo-tools-builder /opt/control-plane-tools/bin/ /usr/local/bin/
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
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["bash", "-lc", "control-plane-exec-api health --addr \"http://127.0.0.1:${CONTROL_PLANE_FAST_EXECUTION_PORT:-8080}\" --timeout-sec 2"]
USER ${CONTROL_PLANE_USER}
CMD ["/usr/local/bin/control-plane-exec-api", "serve"]
