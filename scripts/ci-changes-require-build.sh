#!/usr/bin/env bash
set -euo pipefail

collect_paths() {
  if [[ "$#" -gt 0 ]]; then
    printf '%s\n' "$@"
    return
  fi

  if [[ -t 0 ]]; then
    return
  fi

  cat
}

path_requires_build() {
  local path="$1"

  case "${path}" in
    containers/control-plane/skills/*/SKILL.md)
      return 0
      ;;
    *.md)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

main() {
  local path=''
  local saw_path=0

  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    saw_path=1

    if path_requires_build "${path}"; then
      printf 'true\n'
      return 0
    fi
  done < <(collect_paths "$@")

  if [[ "${saw_path}" -eq 0 ]]; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

main "$@"
