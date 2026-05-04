ARG RUST_BASE_IMAGE=docker.io/library/rust:1.95.0-bookworm@sha256:adab7941580c74513aa3347f2d2a1f975498280743d29ec62978ba12e3540d3a
# renovate: datasource=crate depName=cargo-chef
ARG CARGO_CHEF_VERSION=0.1.77
# renovate: datasource=crate depName=trunk
ARG TRUNK_VERSION=0.21.14
# renovate: datasource=crate depName=wasm-bindgen-cli
ARG WASM_BINDGEN_CLI_VERSION=0.2.120
# renovate: datasource=crate depName=cargo-deny
ARG CARGO_DENY_VERSION=0.19.4
# renovate: datasource=crate depName=cargo-audit
ARG CARGO_AUDIT_VERSION=0.22.1
# renovate: datasource=crate depName=cargo-llvm-cov
ARG CARGO_LLVM_COV_VERSION=0.8.5
# renovate: datasource=npm depName=pnpm
ARG PNPM_VERSION=10.33.2
# renovate: datasource=pypi depName=lizard
ARG LIZARD_VERSION=1.22.1
# Keep the Chrome for Testing version and Linux64 digests in sync when updating them.
ARG CHROME_FOR_TESTING_VERSION=148.0.7778.97
ARG CHROME_FOR_TESTING_CHROME_LINUX64_SHA256=8a760543807c67d3836d530cc4bc2e39c93e217f1629ec6ea311415fdfa21a75
ARG CHROME_FOR_TESTING_CHROMEDRIVER_LINUX64_SHA256=ad324679086572b638a0388a96f21185615482c55aafc45f3f01adf134fafbf5
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

FROM cargo-chef AS cargo-tools-builder

ARG TRUNK_VERSION
ARG WASM_BINDGEN_CLI_VERSION
ARG CARGO_DENY_VERSION
ARG CARGO_AUDIT_VERSION
ARG CARGO_LLVM_COV_VERSION

# hadolint ignore=DL3008
RUN apt-get update -o Acquire::Retries=3 \
    && apt-get install -y --no-install-recommends \
        cmake \
        libssl-dev \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

RUN cargo install --locked --root /opt/control-plane-tools --version "${TRUNK_VERSION}" trunk \
    && cargo install --locked --root /opt/control-plane-tools --version "${WASM_BINDGEN_CLI_VERSION}" wasm-bindgen-cli \
    && cargo install --locked --root /opt/control-plane-tools --version "${CARGO_DENY_VERSION}" cargo-deny \
    && cargo install --locked --root /opt/control-plane-tools --version "${CARGO_AUDIT_VERSION}" cargo-audit \
    && cargo install --locked --root /opt/control-plane-tools --version "${CARGO_LLVM_COV_VERSION}" cargo-llvm-cov

FROM ${RUST_BASE_IMAGE}

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
        amd64) kubectl_arch=amd64; buildx_arch=amd64; chrome_install_mode=chrome-for-testing; chrome_for_testing_platform=linux64 ;; \
        arm64) kubectl_arch=arm64; buildx_arch=arm64; chrome_install_mode=debian-chromium; browser_apt_packages=(chromium chromium-driver) ;; \
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
    && rustup component add llvm-tools-preview \
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
    CMD ["bash", "-lc", "control-plane-exec-api --help >/dev/null && bash --version >/dev/null && sh -c true && rg --version >/dev/null && python3 --version >/dev/null && curl --version >/dev/null && docker --version >/dev/null && docker buildx version >/dev/null && cc --version >/dev/null && git --version >/dev/null && jq --version >/dev/null && cmake --version >/dev/null && pkgconf --version >/dev/null && pkg-config --version >/dev/null && test -e /usr/include/openssl/ssl.h && yamllint --version >/dev/null && kubectl version --client=true >/dev/null && rustup --version >/dev/null && rustup target list --installed | grep -qx wasm32-unknown-unknown && rustup component list --installed | grep -Eq '^llvm-tools-.*-unknown-linux-gnu$' && rustc --version >/dev/null && cargo --version >/dev/null && cargo deny --version >/dev/null && cargo audit --version >/dev/null && cargo llvm-cov --version >/dev/null && sccache --version >/dev/null && node --version >/dev/null && npm --version >/dev/null && pnpm --version >/dev/null && wasm-opt --version >/dev/null && wasm-bindgen --version >/dev/null && trunk --version >/dev/null && lizard --version >/dev/null && google-chrome --version >/dev/null && chromedriver --version >/dev/null && mold --version >/dev/null && sudo -V >/dev/null && test -x /usr/local/bin/control-plane-runtime-tool && test -x /usr/local/bin/trunk && test -x /usr/local/bin/wasm-bindgen && test -x /usr/local/bin/google-chrome && test -x /usr/local/bin/chromedriver && test -r /usr/local/lib/libcontrol_plane_exec_policy.so"]
USER ${CONTROL_PLANE_USER}
CMD ["/usr/local/bin/control-plane-exec-api", "serve"]
