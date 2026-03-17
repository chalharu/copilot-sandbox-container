#!/bin/sh

runtime_config_file="${CONTROL_PLANE_RUNTIME_ENV_FILE:-${HOME:-/home/${USER:-copilot}}/.config/control-plane/runtime.env}"
if [ -f "${runtime_config_file}" ]; then
  set -a
  # shellcheck disable=SC1090
  . "${runtime_config_file}"
  set +a
fi

ensure_compatible_term() {
  current_term="${TERM:-}"
  current_colors=0

  if [ -n "${current_term}" ] && TERM="${current_term}" tput clear >/dev/null 2>&1; then
    current_colors="$(TERM="${current_term}" tput colors 2>/dev/null || printf '0')"
    case "${current_colors}" in
      ''|*[!0-9]*) current_colors=0 ;;
    esac
    if [ "${current_colors}" -ge 256 ]; then
      return 0
    fi
  fi

  for candidate in xterm-256color xterm; do
    if TERM="${candidate}" tput clear >/dev/null 2>&1; then
      candidate_colors="$(TERM="${candidate}" tput colors 2>/dev/null || printf '0')"
      case "${candidate_colors}" in
        ''|*[!0-9]*) candidate_colors=0 ;;
      esac
      if [ "${candidate}" != "xterm" ] && [ "${candidate_colors}" -lt 256 ]; then
        continue
      fi
      TERM="${candidate}"
      export TERM
      return 0
    fi
  done

  TERM=xterm
  export TERM
}

ensure_compatible_term

: "${LANG:=C.UTF-8}"
: "${EDITOR:=vim}"
: "${VISUAL:=${EDITOR}}"
: "${GH_PAGER:=cat}"
export LANG EDITOR VISUAL GH_PAGER
