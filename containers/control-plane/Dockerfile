ARG RUST_BASE_IMAGE=docker.io/library/rust:1.95.0-bookworm@sha256:adab7941580c74513aa3347f2d2a1f975498280743d29ec62978ba12e3540d3a
# renovate: datasource=crate depName=cargo-chef
ARG CARGO_CHEF_VERSION=0.1.77

FROM ${RUST_BASE_IMAGE} AS cargo-chef

ARG CARGO_CHEF_VERSION
RUN cargo_home="${CARGO_HOME:-${HOME}/.cargo}" \
    && mkdir -p "${cargo_home}" /var/tmp/control-plane/cargo-target /build/control-plane \
    && ln -sfn /var/tmp/control-plane/cargo-target /build/control-plane/target \
    && printf '[build]\ntarget-dir = "/var/tmp/control-plane/cargo-target"\n' > "${cargo_home}/config.toml" \
    && cargo install cargo-chef --locked --version "${CARGO_CHEF_VERSION}"

FROM cargo-chef AS workspace-planner

WORKDIR /build/control-plane
COPY Cargo.toml Cargo.lock ./
COPY exec-api/ ./exec-api/
COPY exec-policy-preload/ ./exec-policy-preload/
COPY runtime-tools/ ./runtime-tools/
RUN cargo chef prepare --recipe-path recipe.json

FROM cargo-chef AS exec-policy-builder

WORKDIR /build/control-plane
COPY --from=workspace-planner /build/control-plane/recipe.json ./recipe.json
RUN cargo chef cook --locked --release --recipe-path recipe.json -p control-plane-exec-policy-preload
COPY Cargo.toml Cargo.lock ./
COPY exec-api/ ./exec-api/
COPY exec-policy-preload/ ./exec-policy-preload/
COPY runtime-tools/ ./runtime-tools/
COPY hooks/preToolUse/deny-rules.yaml ./hooks/preToolUse/deny-rules.yaml
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
COPY Cargo.toml Cargo.lock ./
COPY exec-api/ ./exec-api/
COPY exec-policy-preload/ ./exec-policy-preload/
COPY runtime-tools/ ./runtime-tools/
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
COPY Cargo.toml Cargo.lock ./
COPY exec-api/ ./exec-api/
COPY exec-policy-preload/ ./exec-policy-preload/
COPY runtime-tools/ ./runtime-tools/
COPY hooks/postToolUse/linters.json ./hooks/postToolUse/linters.json
RUN cargo test --locked --release -p control-plane-runtime-tools \
    && cargo build --locked --release -p control-plane-runtime-tools

FROM cargo-chef AS rust-toolchain

RUN rustup component add clippy rustfmt

FROM ${RUST_BASE_IMAGE} AS skills-builder

# hadolint ignore=DL3008
RUN apt-get update -o Acquire::Retries=3 \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=runtime-tools-builder /var/tmp/control-plane/cargo-target/release/control-plane-runtime-tool /usr/local/bin/install-git-skills-from-manifest
COPY --chmod=644 config/external-skills.yaml /tmp/external-skills.yaml

RUN /usr/local/bin/install-git-skills-from-manifest /tmp/external-skills.yaml /opt/control-plane/external-skills

FROM node:24.15.0-bookworm-slim@sha256:03eae3ef7e88a9de535496fb488d67e02b9d96a063a8967bae657744ecd513f2

# renovate: datasource=npm depName=@github/copilot
ARG COPILOT_CLI_VERSION=1.0.36
# renovate: datasource=github-releases depName=kubernetes-sigs/kind
ARG KIND_VERSION=v0.31.0
# renovate: datasource=github-releases depName=jqlang/jq
ARG JQ_VERSION=jq-1.8.1
# renovate: datasource=github-releases depName=kubernetes/kubernetes
ARG KUBECTL_VERSION=v1.36.0
# renovate: datasource=github-releases depName=rclone/rclone
ARG RCLONE_VERSION=v1.73.5
# renovate: datasource=github-releases depName=astral-sh/ruff
ARG RUFF_VERSION=0.15.12
# renovate: datasource=github-releases depName=hadolint/hadolint
ARG HADOLINT_VERSION=v2.14.0
# renovate: datasource=pypi depName=yamllint
ARG YAMLLINT_VERSION=1.38.0
# renovate: datasource=pypi depName=pathspec
ARG PATHSPEC_VERSION=1.1.1
# renovate: datasource=pypi depName=PyYAML
ARG PYYAML_VERSION=6.0.3
ARG CONTROL_PLANE_UID=1000
ARG CONTROL_PLANE_GID=1000
ARG CONTROL_PLANE_USER=copilot

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    CONTROL_PLANE_USER=${CONTROL_PLANE_USER} \
    CONTROL_PLANE_HOME=/home/${CONTROL_PLANE_USER} \
    CONTROL_PLANE_WORKSPACE=/workspace \
    YAMLLINT_VIRTUAL_ENV=/opt/yamllint
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/home/${CONTROL_PLANE_USER}/.cargo \
    CARGO_TARGET_DIR=/var/tmp/control-plane/cargo-target \
    PATH=${YAMLLINT_VIRTUAL_ENV}/bin:/usr/local/cargo/bin:${PATH} \
    LANG=C.UTF-8 \
    LC_CTYPE=C.UTF-8

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# hadolint ignore=DL3008
RUN apt-get update -o Acquire::Retries=3 \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        git \
        locales \
        openssh-client \
        openssh-server \
        python3 \
        python3-venv \
        procps \
        screen \
        tini \
        unzip \
        vim \
    && arch="$(dpkg --print-architecture)" \
    && case "${arch}" in \
        amd64) \
            kind_arch=amd64; \
            jq_asset=jq-linux-amd64; \
            kubectl_arch=amd64; \
            rclone_arch=amd64; \
            ruff_arch=x86_64; \
            hadolint_asset=hadolint-linux-x86_64; \
            pyyaml_arch=x86_64; \
            ;; \
        arm64) \
            kind_arch=arm64; \
            jq_asset=jq-linux-arm64; \
            kubectl_arch=arm64; \
            rclone_arch=arm64; \
            ruff_arch=aarch64; \
            hadolint_asset=hadolint-linux-arm64; \
            pyyaml_arch=aarch64; \
            ;; \
        *) printf 'Unsupported architecture for control-plane tools: %s\n' "${arch}" >&2; exit 1 ;; \
    esac \
    && kind_download_root="https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}" \
    && curl -fsSLo "/tmp/kind-linux-${kind_arch}" "${kind_download_root}/kind-linux-${kind_arch}" \
    && curl -fsSLo "/tmp/kind-linux-${kind_arch}.sha256sum" "${kind_download_root}/kind-linux-${kind_arch}.sha256sum" \
    && awk -v asset="kind-linux-${kind_arch}" '$2 == asset { print $1 "  /tmp/" asset; found=1 } END { exit(found ? 0 : 1) }' "/tmp/kind-linux-${kind_arch}.sha256sum" | sha256sum -c - \
    && install -m 0755 "/tmp/kind-linux-${kind_arch}" /usr/local/bin/kind \
    && jq_download_root="https://github.com/jqlang/jq/releases/download/${JQ_VERSION}" \
    && curl -fsSLo "/tmp/${jq_asset}" "${jq_download_root}/${jq_asset}" \
    && curl -fsSLo /tmp/jq-sha256sum.txt "${jq_download_root}/sha256sum.txt" \
    && awk -v asset="${jq_asset}" '$2 == asset { print $1 "  /tmp/" asset; found=1 } END { exit(found ? 0 : 1) }' /tmp/jq-sha256sum.txt | sha256sum -c - \
    && install -m 0755 "/tmp/${jq_asset}" /usr/local/bin/jq \
    && kubectl_download_root="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${kubectl_arch}" \
    && curl -fsSLo /tmp/kubectl "${kubectl_download_root}/kubectl" \
    && curl -fsSLo /tmp/kubectl.sha256 "${kubectl_download_root}/kubectl.sha256" \
    && awk '{ print $1 "  /tmp/kubectl"; found=1 } END { exit(found ? 0 : 1) }' /tmp/kubectl.sha256 | sha256sum -c - \
    && install -m 0755 /tmp/kubectl /usr/local/bin/kubectl \
    && rclone_asset="rclone-${RCLONE_VERSION}-linux-${rclone_arch}.zip" \
    && rclone_download_root="https://downloads.rclone.org/${RCLONE_VERSION}" \
    && curl -fsSLo "/tmp/${rclone_asset}" "${rclone_download_root}/${rclone_asset}" \
    && curl -fsSLo /tmp/rclone-SHA256SUMS "${rclone_download_root}/SHA256SUMS" \
    && awk -v asset="${rclone_asset}" '$2 == asset { print $1 "  /tmp/" asset; found=1 } END { exit(found ? 0 : 1) }' /tmp/rclone-SHA256SUMS | sha256sum -c - \
    && unzip -q "/tmp/${rclone_asset}" -d /tmp \
    && install -m 0755 "/tmp/rclone-${RCLONE_VERSION}-linux-${rclone_arch}/rclone" /usr/local/bin/rclone \
    && ruff_asset="ruff-${ruff_arch}-unknown-linux-gnu.tar.gz" \
    && ruff_download_root="https://github.com/astral-sh/ruff/releases/download/${RUFF_VERSION}" \
    && curl -fsSLo "/tmp/${ruff_asset}" "${ruff_download_root}/${ruff_asset}" \
    && curl -fsSLo "/tmp/${ruff_asset}.sha256" "${ruff_download_root}/${ruff_asset}.sha256" \
    && awk -v asset="${ruff_asset}" '$2 == asset { print $1 "  /tmp/" asset; found=1 } END { exit(found ? 0 : 1) }' "/tmp/${ruff_asset}.sha256" | sha256sum -c - \
    && tar -xzf "/tmp/${ruff_asset}" -C /tmp \
    && install -m 0755 "/tmp/ruff-${ruff_arch}-unknown-linux-gnu/ruff" /usr/local/bin/ruff \
    && hadolint_download_root="https://github.com/hadolint/hadolint/releases/download/${HADOLINT_VERSION}" \
    && curl -fsSLo "/tmp/${hadolint_asset}" "${hadolint_download_root}/${hadolint_asset}" \
    && curl -fsSLo "/tmp/${hadolint_asset}.sha256" "${hadolint_download_root}/${hadolint_asset}.sha256" \
    && awk -v asset="${hadolint_asset}" '{ gsub(/^[*]/, "", $2); if ($2 == asset) { print $1 "  /tmp/" asset; found=1 } } END { exit(found ? 0 : 1) }' "/tmp/${hadolint_asset}.sha256" | sha256sum -c - \
    && install -m 0755 "/tmp/${hadolint_asset}" /usr/local/bin/hadolint \
    && pathspec_wheel="pathspec-${PATHSPEC_VERSION}-py3-none-any.whl" \
    && yamllint_wheel="yamllint-${YAMLLINT_VERSION}-py3-none-any.whl" \
    && python_tag="$(python3 -c 'import sys; print(f"cp{sys.version_info[0]}{sys.version_info[1]}")')" \
    && curl -fsSLo /tmp/pathspec-pypi.json "https://pypi.org/pypi/pathspec/${PATHSPEC_VERSION}/json" \
    && curl -fsSLo /tmp/pyyaml-pypi.json "https://pypi.org/pypi/PyYAML/${PYYAML_VERSION}/json" \
    && curl -fsSLo /tmp/yamllint-pypi.json "https://pypi.org/pypi/yamllint/${YAMLLINT_VERSION}/json" \
    && pathspec_sha256="$(jq -er --arg filename "${pathspec_wheel}" 'first(.urls[] | select(.filename == $filename) | .digests.sha256)' /tmp/pathspec-pypi.json)" \
    && pyyaml_wheel="$(jq -er --arg python_tag "${python_tag}" --arg pyyaml_arch "${pyyaml_arch}" 'first(.urls[] | select(.packagetype == "bdist_wheel" and (.filename | ascii_downcase | startswith("pyyaml-") and contains("-" + $python_tag + "-" + $python_tag + "-") and contains("manylinux") and contains($pyyaml_arch) and endswith(".whl"))) | .filename)' /tmp/pyyaml-pypi.json)" \
    && pyyaml_sha256="$(jq -er --arg filename "${pyyaml_wheel}" 'first(.urls[] | select(.filename == $filename) | .digests.sha256)' /tmp/pyyaml-pypi.json)" \
    && yamllint_sha256="$(jq -er --arg filename "${yamllint_wheel}" 'first(.urls[] | select(.filename == $filename) | .digests.sha256)' /tmp/yamllint-pypi.json)" \
    && printf '%s\n' \
        "pathspec==${PATHSPEC_VERSION} --hash=sha256:${pathspec_sha256}" \
        "PyYAML==${PYYAML_VERSION} --hash=sha256:${pyyaml_sha256}" \
        "yamllint==${YAMLLINT_VERSION} --hash=sha256:${yamllint_sha256}" \
        > /tmp/yamllint-requirements.txt \
    && python3 -m venv "${YAMLLINT_VIRTUAL_ENV}" \
    && "${YAMLLINT_VIRTUAL_ENV}/bin/pip" install --no-cache-dir --only-binary=:all: --require-hashes -r /tmp/yamllint-requirements.txt \
    && apt-get purge -y --auto-remove curl unzip \
    && printf '%s\n' \
        'en_US.UTF-8 UTF-8' \
        'ja_JP.UTF-8 UTF-8' \
        > /etc/locale.gen \
    && locale-gen \
    && localedef -i en_US -f UTF-8 en_US.UTF8 \
    && localedef -i ja_JP -f UTF-8 ja_JP.UTF8 \
    && rm -rf /var/lib/apt/lists/* /root/.cache /tmp/*

RUN npm install --global "@github/copilot@${COPILOT_CLI_VERSION}" \
    && npm cache clean --force

RUN existing_group="$(getent group "${CONTROL_PLANE_GID}" | cut -d: -f1 || true)" \
    && if [ -n "${existing_group}" ] && [ "${existing_group}" != "${CONTROL_PLANE_USER}" ]; then \
        groupmod --new-name "${CONTROL_PLANE_USER}" "${existing_group}"; \
    elif [ -z "${existing_group}" ] && ! getent group "${CONTROL_PLANE_USER}" >/dev/null; then \
        groupadd --gid "${CONTROL_PLANE_GID}" "${CONTROL_PLANE_USER}"; \
    fi \
    && if getent group "${CONTROL_PLANE_USER}" >/dev/null; then \
        groupmod --gid "${CONTROL_PLANE_GID}" "${CONTROL_PLANE_USER}"; \
    fi \
    && existing_user="$(getent passwd "${CONTROL_PLANE_UID}" | cut -d: -f1 || true)" \
    && if [ -n "${existing_user}" ] && [ "${existing_user}" != "${CONTROL_PLANE_USER}" ]; then \
        usermod --login "${CONTROL_PLANE_USER}" \
            --home "/home/${CONTROL_PLANE_USER}" \
            --move-home \
            --shell /bin/bash \
            --gid "${CONTROL_PLANE_USER}" \
            "${existing_user}"; \
    elif ! getent passwd "${CONTROL_PLANE_USER}" >/dev/null; then \
        useradd --uid "${CONTROL_PLANE_UID}" \
            --gid "${CONTROL_PLANE_USER}" \
            --create-home \
            --home-dir "/home/${CONTROL_PLANE_USER}" \
            --shell /bin/bash \
            "${CONTROL_PLANE_USER}"; \
    fi \
    && usermod --uid "${CONTROL_PLANE_UID}" \
        --gid "${CONTROL_PLANE_USER}" \
        --home "/home/${CONTROL_PLANE_USER}" \
        --shell /bin/bash \
        "${CONTROL_PLANE_USER}" \
    && passwd -d "${CONTROL_PLANE_USER}" \
    && mkdir -p \
        "/home/${CONTROL_PLANE_USER}/.copilot" \
        "/home/${CONTROL_PLANE_USER}/.cargo" \
        "/home/${CONTROL_PLANE_USER}/.config/control-plane" \
        "/home/${CONTROL_PLANE_USER}/.config/gh" \
        "/home/${CONTROL_PLANE_USER}/.ssh" \
        /var/tmp/control-plane/cargo-target \
        /run/sshd \
        /workspace \
    && printf '[build]\ntarget-dir = "/var/tmp/control-plane/cargo-target"\n' > "/home/${CONTROL_PLANE_USER}/.cargo/config.toml" \
    && chown -R "${CONTROL_PLANE_USER}:${CONTROL_PLANE_USER}" \
        "/home/${CONTROL_PLANE_USER}" \
        /var/tmp/control-plane \
        /workspace \
    && chmod 700 "/home/${CONTROL_PLANE_USER}/.ssh" \
    && ln -sf /usr/sbin/sshd /usr/local/bin/sshd

COPY --chmod=644 config/sshd_config /etc/ssh/sshd_config
COPY --chmod=644 config/screenrc /etc/screenrc
COPY --chmod=644 config/profile-control-plane-env.sh /etc/profile.d/control-plane-env.sh
COPY --chmod=644 config/profile-control-plane-session.sh /etc/profile.d/control-plane-session.sh
COPY skills/ /usr/local/share/control-plane/skills/
COPY agents/ /usr/local/share/control-plane/agents/
COPY --from=skills-builder /opt/control-plane/external-skills/ /usr/local/share/control-plane/skills/
COPY hooks/ /usr/local/share/control-plane/hooks/
COPY --from=rust-toolchain /usr/local/cargo/bin /usr/local/cargo/bin
COPY --from=rust-toolchain /usr/local/rustup /usr/local/rustup
COPY --from=runtime-tools-builder /var/tmp/control-plane/cargo-target/release/control-plane-runtime-tool /usr/local/bin/control-plane-runtime-tool
COPY --from=exec-policy-builder /var/tmp/control-plane/cargo-target/release/libcontrol_plane_exec_policy.so /usr/local/lib/libcontrol_plane_exec_policy.so
COPY --from=exec-policy-builder /var/tmp/control-plane/cargo-target/release/control-plane-pre-tool-use-hook /usr/local/share/control-plane/hooks/preToolUse/main
COPY --chmod=755 bin/control-plane-screen /usr/local/bin/control-plane-screen
COPY --chmod=755 bin/control-plane-entrypoint /usr/local/bin/control-plane-entrypoint
COPY --chmod=755 bin/control-plane-exec-api-launcher /usr/local/bin/control-plane-exec-api-launcher
COPY --chmod=755 bin/control-plane-session-exec /usr/local/bin/control-plane-session-exec
COPY --chmod=755 bin/control-plane-copilot /usr/local/bin/control-plane-copilot
COPY --chmod=755 bin/control-plane-biome /usr/local/bin/control-plane-biome
COPY --from=exec-api-builder /var/tmp/control-plane/cargo-target/release/control-plane-exec-api /usr/local/bin/control-plane-exec-api
COPY --chmod=755 bin/control-plane-job-transfer /usr/local/bin/control-plane-job-transfer
COPY --chmod=755 bin/control-plane-run /usr/local/bin/control-plane-run
COPY --chmod=755 bin/control-plane-session /usr/local/bin/control-plane-session
COPY --chmod=755 bin/control-plane-ssh-shell /usr/local/bin/control-plane-ssh-shell
COPY --chmod=755 bin/k8s-job-start /usr/local/bin/k8s-job-start
COPY --chmod=755 bin/k8s-job-run /usr/local/bin/k8s-job-run

RUN mkdir -p /usr/local/share/control-plane/hooks/sessionEnd \
    && ln -sf /usr/local/bin/control-plane-screen /usr/local/bin/screen \
    && ln -sf /usr/local/bin/control-plane-runtime-tool /usr/local/share/control-plane/hooks/audit/main \
    && ln -sf /usr/local/bin/control-plane-runtime-tool /usr/local/share/control-plane/hooks/preToolUse/exec-forward \
    && ln -sf /usr/local/bin/control-plane-runtime-tool /usr/local/share/control-plane/hooks/postToolUse/main \
    && ln -sf /usr/local/bin/control-plane-runtime-tool /usr/local/share/control-plane/hooks/sessionEnd/cleanup \
    && ln -sf /usr/local/bin/control-plane-runtime-tool /usr/local/bin/k8s-job-wait \
    && ln -sf /usr/local/bin/control-plane-runtime-tool /usr/local/bin/k8s-job-pod \
    && ln -sf /usr/local/bin/control-plane-runtime-tool /usr/local/bin/k8s-job-logs \
    && usermod --shell /usr/local/bin/control-plane-ssh-shell "${CONTROL_PLANE_USER}" \
    && find /usr/local/share/control-plane/skills -type d -exec chmod 755 {} + \
    && find /usr/local/share/control-plane/skills -type f -exec chmod 644 {} + \
    && find /usr/local/share/control-plane/agents -type d -exec chmod 755 {} + \
    && find /usr/local/share/control-plane/agents -type f -exec chmod 644 {} + \
    && find /usr/local/share/control-plane/hooks -type d -exec chmod 755 {} + \
    && find /usr/local/share/control-plane/hooks -type f -exec chmod 644 {} + \
    && chmod 755 /usr/local/share/control-plane/hooks/audit/main \
    && chmod 755 /usr/local/share/control-plane/hooks/preToolUse/main \
    && chmod 755 /usr/local/share/control-plane/hooks/preToolUse/exec-forward \
    && chmod 755 /usr/local/share/control-plane/hooks/postToolUse/control-plane-rust.sh \
    && chmod 755 /usr/local/share/control-plane/hooks/sessionEnd/cleanup \
    && for git_hook in pre-commit pre-push; do \
         if [ -f "/usr/local/share/control-plane/hooks/git/${git_hook}" ]; then chmod 755 "/usr/local/share/control-plane/hooks/git/${git_hook}"; fi; \
       done \
    && chmod 644 /usr/local/lib/libcontrol_plane_exec_policy.so \
    && chown -R "${CONTROL_PLANE_USER}:${CONTROL_PLANE_USER}" "/home/${CONTROL_PLANE_USER}/.config"

WORKDIR /workspace
# Supported runtimes still have to override this to root because the entrypoint
# provisions mounted state and SSH host keys.
USER ${CONTROL_PLANE_USER}
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["bash", "-lc", "node --version >/dev/null && cargo --version >/dev/null && git --version >/dev/null && yamllint --version >/dev/null && control-plane-exec-api --help >/dev/null && test -x /usr/local/bin/control-plane-entrypoint && test -r /etc/ssh/sshd_config"]
EXPOSE 2222
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/control-plane-entrypoint"]
CMD ["/usr/sbin/sshd", "-D", "-e", "-f", "/etc/ssh/sshd_config"]
