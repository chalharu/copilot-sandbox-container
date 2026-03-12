FROM node:20-bookworm-slim

ARG COPILOT_CLI_VERSION=latest
ARG CONTROL_PLANE_UID=1000
ARG CONTROL_PLANE_GID=1000
ARG CONTROL_PLANE_USER=copilot

ENV DEBIAN_FRONTEND=noninteractive \
    CONTROL_PLANE_USER=${CONTROL_PLANE_USER} \
    CONTROL_PLANE_HOME=/home/${CONTROL_PLANE_USER} \
    CONTROL_PLANE_WORKSPACE=/workspace

# hadolint ignore=DL3008
RUN apt-get update \
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

RUN npm install --global "@github/copilot-cli@${COPILOT_CLI_VERSION}" \
    && npm cache clean --force

RUN groupadd --gid "${CONTROL_PLANE_GID}" "${CONTROL_PLANE_USER}" \
    && useradd --uid "${CONTROL_PLANE_UID}" \
        --gid "${CONTROL_PLANE_GID}" \
        --create-home \
        --shell /bin/bash \
        "${CONTROL_PLANE_USER}" \
    && mkdir -p \
        "/home/${CONTROL_PLANE_USER}/.copilot" \
        "/home/${CONTROL_PLANE_USER}/.config/containers" \
        "/home/${CONTROL_PLANE_USER}/.config/gh" \
        "/home/${CONTROL_PLANE_USER}/.ssh" \
        /run/sshd \
        /workspace \
    && printf '%s:%s:65536\n' "${CONTROL_PLANE_USER}" 100000 >> /etc/subuid \
    && printf '%s:%s:65536\n' "${CONTROL_PLANE_USER}" 100000 >> /etc/subgid \
    && chown -R "${CONTROL_PLANE_USER}:${CONTROL_PLANE_USER}" \
        "/home/${CONTROL_PLANE_USER}" \
        /workspace \
    && chmod 700 "/home/${CONTROL_PLANE_USER}/.ssh" \
    && ln -sf /usr/bin/podman /usr/local/bin/docker

COPY --chmod=644 config/sshd_config /etc/ssh/sshd_config
COPY --chmod=644 config/storage.conf /home/${CONTROL_PLANE_USER}/.config/containers/storage.conf
COPY --chmod=755 bin/control-plane-entrypoint /usr/local/bin/control-plane-entrypoint
COPY --chmod=755 bin/control-plane-run /usr/local/bin/control-plane-run
COPY --chmod=755 bin/control-plane-session /usr/local/bin/control-plane-session
COPY --chmod=755 bin/k8s-job-start /usr/local/bin/k8s-job-start
COPY --chmod=755 bin/k8s-job-wait /usr/local/bin/k8s-job-wait
COPY --chmod=755 bin/k8s-job-pod /usr/local/bin/k8s-job-pod
COPY --chmod=755 bin/k8s-job-logs /usr/local/bin/k8s-job-logs
COPY --chmod=755 bin/k8s-job-run /usr/local/bin/k8s-job-run

RUN chown -R "${CONTROL_PLANE_USER}:${CONTROL_PLANE_USER}" "/home/${CONTROL_PLANE_USER}/.config"

WORKDIR /workspace
EXPOSE 2222
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/control-plane-entrypoint"]
CMD ["/usr/sbin/sshd", "-D", "-e", "-f", "/etc/ssh/sshd_config"]
