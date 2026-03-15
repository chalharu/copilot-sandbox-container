FROM node:24.14.0-bookworm-slim@sha256:e8e2e91b1378f83c5b2dd15f0247f34110e2fe895f6ca7719dbb780f929368eb

# renovate: datasource=npm depName=@github/copilot
ARG COPILOT_CLI_VERSION=1.0.5
ARG CONTROL_PLANE_UID=1000
ARG CONTROL_PLANE_GID=1000
ARG CONTROL_PLANE_USER=copilot

ENV DEBIAN_FRONTEND=noninteractive \
    CONTROL_PLANE_USER=${CONTROL_PLANE_USER} \
    CONTROL_PLANE_HOME=/home/${CONTROL_PLANE_USER} \
    CONTROL_PLANE_WORKSPACE=/workspace

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# hadolint ignore=DL3008
RUN apt-get update -o Acquire::Retries=3 \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        fuse-overlayfs \
        gh \
        git \
        jq \
        kubernetes-client \
        openssh-client \
        openssh-server \
        podman \
        procps \
        screen \
        slirp4netns \
        tini \
        uidmap \
    && rm -rf /var/lib/apt/lists/*

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
COPY --chmod=644 config/storage.conf /home/${CONTROL_PLANE_USER}/.config/containers/storage.conf
COPY --chmod=644 config/profile-control-plane-env.sh /etc/profile.d/control-plane-env.sh
COPY --chmod=644 config/profile-control-plane-session.sh /etc/profile.d/control-plane-session.sh
COPY --chmod=644 skills/control-plane-operations/ /usr/local/share/control-plane/skills/control-plane-operations/
COPY --chmod=755 bin/control-plane-podman /usr/local/bin/control-plane-podman
COPY --chmod=755 bin/control-plane-screen /usr/local/bin/control-plane-screen
COPY --chmod=755 bin/control-plane-entrypoint /usr/local/bin/control-plane-entrypoint
COPY --chmod=755 bin/control-plane-run /usr/local/bin/control-plane-run
COPY --chmod=755 bin/control-plane-session /usr/local/bin/control-plane-session
COPY --chmod=755 bin/k8s-job-start /usr/local/bin/k8s-job-start
COPY --chmod=755 bin/k8s-job-wait /usr/local/bin/k8s-job-wait
COPY --chmod=755 bin/k8s-job-pod /usr/local/bin/k8s-job-pod
COPY --chmod=755 bin/k8s-job-logs /usr/local/bin/k8s-job-logs
COPY --chmod=755 bin/k8s-job-run /usr/local/bin/k8s-job-run

RUN ln -sf /usr/local/bin/control-plane-podman /usr/local/bin/podman \
    && ln -sf /usr/local/bin/control-plane-podman /usr/local/bin/docker \
    && ln -sf /usr/local/bin/control-plane-screen /usr/local/bin/screen \
    && chown -R "${CONTROL_PLANE_USER}:${CONTROL_PLANE_USER}" "/home/${CONTROL_PLANE_USER}/.config"

WORKDIR /workspace
EXPOSE 2222
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/control-plane-entrypoint"]
CMD ["/usr/sbin/sshd", "-D", "-e", "-f", "/etc/ssh/sshd_config"]
