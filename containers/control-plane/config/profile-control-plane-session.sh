#!/bin/sh

[ -n "${SSH_TTY:-}" ] || return 0
[ -z "${STY:-}" ] || return 0
[ -z "${CONTROL_PLANE_DISABLE_SESSION_PICKER:-}" ] || return 0
[ -t 0 ] || return 0
[ -t 1 ] || return 0

# Some SSH login shells inside containerized PTY sessions do not expose "i" in
# $- early enough for /etc/profile.d hooks, even though the SSH TTY is live and
# the user expects the session picker. Use the actual TTY checks above instead
# of Bash's interactive flag so SSH logins keep the Screen auto-attach flow.

if command -v control-plane-session >/dev/null 2>&1; then
  if control-plane-session --select; then
    exit 0
  else
    printf '%s\n' \
      'control-plane: session picker failed; continuing with the login shell. Set CONTROL_PLANE_DISABLE_SESSION_PICKER=1 to skip it entirely.' \
      >&2
  fi
fi
