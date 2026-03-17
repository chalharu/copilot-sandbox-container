#!/bin/sh

case $- in
  *i*) ;;
  *) return 0 ;;
esac

[ -n "${SSH_TTY:-}" ] || return 0
[ -z "${STY:-}" ] || return 0
[ -z "${CONTROL_PLANE_DISABLE_SESSION_PICKER:-}" ] || return 0
[ -t 0 ] || return 0
[ -t 1 ] || return 0

if command -v control-plane-session >/dev/null 2>&1; then
  if control-plane-session --select; then
    exit 0
  else
    printf '%s\n' \
      'control-plane: session picker failed; continuing with the login shell. Set CONTROL_PLANE_DISABLE_SESSION_PICKER=1 to skip it entirely.' \
      >&2
  fi
fi
