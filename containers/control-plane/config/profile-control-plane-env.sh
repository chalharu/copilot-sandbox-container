#!/bin/sh

runtime_config_file="${CONTROL_PLANE_RUNTIME_ENV_FILE:-${HOME:-/home/${USER:-copilot}}/.config/control-plane/runtime.env}"
if [ -f "${runtime_config_file}" ]; then
  # shellcheck disable=SC1090
  . "${runtime_config_file}"
  export XDG_RUNTIME_DIR TMPDIR SCREENDIR
fi
