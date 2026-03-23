FROM node:24.14.0-bookworm-slim@sha256:d8e448a56fc63242f70026718378bd4b00f8c82e78d20eefb199224a4d8e33d8

# renovate: datasource=npm depName=@github/copilot
ARG COPILOT_CLI_VERSION=1.0.10
# renovate: datasource=github-releases depName=kubernetes-sigs/kind
ARG KIND_VERSION=v0.31.0
ARG CONTROL_PLANE_UID=1000
ARG CONTROL_PLANE_GID=1000
ARG CONTROL_PLANE_USER=copilot

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    CONTROL_PLANE_USER=${CONTROL_PLANE_USER} \
    CONTROL_PLANE_HOME=/home/${CONTROL_PLANE_USER} \
    CONTROL_PLANE_WORKSPACE=/workspace

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# hadolint ignore=DL3008
RUN apt-get update -o Acquire::Retries=3 \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        cpulimit \
        curl \
        fuse-overlayfs \
        gh \
        git \
        jq \
        kubernetes-client \
        locales \
        ncurses-term \
        openssh-client \
        openssh-server \
        podman \
        procps \
        rclone \
        screen \
        slirp4netns \
        tini \
        uidmap \
        vim \
    && printf '%s\n' \
        'en_US.UTF-8 UTF-8' \
        'ja_JP.UTF-8 UTF-8' \
        > /etc/locale.gen \
    && locale-gen \
    && localedef -i en_US -f UTF-8 en_US.UTF8 \
    && localedef -i ja_JP -f UTF-8 ja_JP.UTF8 \
    && rm -rf /var/lib/apt/lists/*

RUN arch="$(dpkg --print-architecture)" \
    && case "${arch}" in \
        amd64) kind_arch=amd64 ;; \
        arm64) kind_arch=arm64 ;; \
        *) printf 'Unsupported architecture for kind: %s\n' "${arch}" >&2; exit 1 ;; \
    esac \
    && curl -fsSLo "/tmp/kind-linux-${kind_arch}" "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${kind_arch}" \
    && curl -fsSLo "/tmp/kind-linux-${kind_arch}.sha256sum" "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-${kind_arch}.sha256sum" \
    && kind_sha256="$(cut -d' ' -f1 "/tmp/kind-linux-${kind_arch}.sha256sum")" \
    && printf '%s  %s\n' "${kind_sha256}" "/tmp/kind-linux-${kind_arch}" | sha256sum -c - \
    && install -m 0755 "/tmp/kind-linux-${kind_arch}" /usr/local/bin/kind \
    && rm -f "/tmp/kind-linux-${kind_arch}" "/tmp/kind-linux-${kind_arch}.sha256sum"

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
        "/home/${CONTROL_PLANE_USER}/.config/containers" \
        "/home/${CONTROL_PLANE_USER}/.config/gh" \
        "/home/${CONTROL_PLANE_USER}/.ssh" \
        /run/sshd \
        /workspace \
    && if ! grep -q "^${CONTROL_PLANE_USER}:" /etc/subuid; then printf '%s:%s:65536\n' "${CONTROL_PLANE_USER}" 100000 >> /etc/subuid; fi \
    && if ! grep -q "^${CONTROL_PLANE_USER}:" /etc/subgid; then printf '%s:%s:65536\n' "${CONTROL_PLANE_USER}" 100000 >> /etc/subgid; fi \
    && chown -R "${CONTROL_PLANE_USER}:${CONTROL_PLANE_USER}" \
        "/home/${CONTROL_PLANE_USER}" \
        /workspace \
    && chmod 700 "/home/${CONTROL_PLANE_USER}/.ssh" \
    && ln -sf /usr/sbin/sshd /usr/local/bin/sshd

COPY --chmod=644 config/sshd_config /etc/ssh/sshd_config
COPY --chmod=644 config/screenrc /etc/screenrc
COPY --chmod=644 config/storage.conf /home/${CONTROL_PLANE_USER}/.config/containers/storage.conf
COPY --chmod=644 config/profile-control-plane-env.sh /etc/profile.d/control-plane-env.sh
COPY --chmod=644 config/profile-control-plane-session.sh /etc/profile.d/control-plane-session.sh
COPY skills/ /usr/local/share/control-plane/skills/
COPY hooks/ /usr/local/share/control-plane/hooks/
COPY --chmod=755 bin/control-plane-podman /usr/local/bin/control-plane-podman
COPY --chmod=755 bin/control-plane-screen /usr/local/bin/control-plane-screen
COPY --chmod=755 bin/control-plane-entrypoint /usr/local/bin/control-plane-entrypoint
COPY --chmod=755 bin/control-plane-copilot /usr/local/bin/control-plane-copilot
COPY --chmod=755 bin/control-plane-job-transfer /usr/local/bin/control-plane-job-transfer
COPY --chmod=755 bin/control-plane-run /usr/local/bin/control-plane-run
COPY --chmod=755 bin/control-plane-session /usr/local/bin/control-plane-session
COPY --chmod=755 bin/control-plane-ssh-shell /usr/local/bin/control-plane-ssh-shell
COPY --chmod=755 bin/k8s-job-start /usr/local/bin/k8s-job-start
COPY --chmod=755 bin/k8s-job-wait /usr/local/bin/k8s-job-wait
COPY --chmod=755 bin/k8s-job-pod /usr/local/bin/k8s-job-pod
COPY --chmod=755 bin/k8s-job-logs /usr/local/bin/k8s-job-logs
COPY --chmod=755 bin/k8s-job-run /usr/local/bin/k8s-job-run

RUN ln -sf /usr/local/bin/control-plane-podman /usr/local/bin/podman \
    && ln -sf /usr/local/bin/control-plane-podman /usr/local/bin/docker \
    && ln -sf /usr/local/bin/control-plane-screen /usr/local/bin/screen \
    && usermod --shell /usr/local/bin/control-plane-ssh-shell "${CONTROL_PLANE_USER}" \
    && find /usr/local/share/control-plane/skills -type d -exec chmod 755 {} + \
    && find /usr/local/share/control-plane/skills -type f -exec chmod 644 {} + \
    && find /usr/local/share/control-plane/hooks -type d -exec chmod 755 {} + \
    && find /usr/local/share/control-plane/hooks -type f -exec chmod 644 {} + \
    && chown -R "${CONTROL_PLANE_USER}:${CONTROL_PLANE_USER}" "/home/${CONTROL_PLANE_USER}/.config"

WORKDIR /workspace
EXPOSE 2222
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/control-plane-entrypoint"]
CMD ["/usr/sbin/sshd", "-D", "-e", "-f", "/etc/ssh/sshd_config"]
