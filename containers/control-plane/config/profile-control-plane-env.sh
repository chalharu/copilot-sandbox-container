#!/bin/sh

runtime_config_file="${CONTROL_PLANE_RUNTIME_ENV_FILE:-${HOME:-/home/${USER:-copilot}}/.config/control-plane/runtime.env}"
if [ -f "${runtime_config_file}" ]; then
  set -a
  # shellcheck disable=SC1090
  . "${runtime_config_file}"
  set +a
fi

: "${LANG:=C.UTF-8}"
: "${EDITOR:=vim}"
: "${VISUAL:=${EDITOR}}"
: "${GH_PAGER:=cat}"
export LANG EDITOR VISUAL GH_PAGER
