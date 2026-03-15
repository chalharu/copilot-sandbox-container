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
  exec control-plane-session --select
fi
