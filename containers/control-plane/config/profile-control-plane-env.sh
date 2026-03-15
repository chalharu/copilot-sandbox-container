#!/bin/sh

runtime_config_file="${CONTROL_PLANE_RUNTIME_ENV_FILE:-${HOME:-/home/${USER:-copilot}}/.config/control-plane/runtime.env}"
if [ -f "${runtime_config_file}" ]; then
  set -a
  # shellcheck disable=SC1090
  . "${runtime_config_file}"
  set +a
fi

: "${EDITOR:=vim}"
: "${VISUAL:=${EDITOR}}"
: "${BUILDAH_ISOLATION:=chroot}"
: "${GH_PAGER:=cat}"
export EDITOR VISUAL BUILDAH_ISOLATION GH_PAGER
