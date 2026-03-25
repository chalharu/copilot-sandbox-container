#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'sccache-dist-entrypoint: %s\n' "$*" >&2
  exit 64
}

read_secret() {
  local path="$1"

  [[ -n "${path}" ]] || die 'missing secret file path'
  [[ -f "${path}" ]] || die "secret file not found: ${path}"
  tr -d '\r\n' < "${path}"
}

write_scheduler_config() {
  local config_path="$1"
  local bind_addr="${SCCACHE_DIST_SCHEDULER_BIND_ADDR:-0.0.0.0:10600}"
  local client_token
  local server_token

  client_token="$(read_secret "${SCCACHE_DIST_CLIENT_TOKEN_FILE:-}")"
  server_token="$(read_secret "${SCCACHE_DIST_SERVER_TOKEN_FILE:-}")"

  cat > "${config_path}" <<EOF
public_addr = "${bind_addr}"

[client_auth]
type = "token"
token = "${client_token}"

[server_auth]
type = "token"
token = "${server_token}"
EOF
}

write_server_config() {
  local config_path="$1"
  local scheduler_url="${SCCACHE_DIST_SCHEDULER_URL:-http://127.0.0.1:10600}"
  local bind_addr="${SCCACHE_DIST_SERVER_BIND_ADDR:-0.0.0.0:10501}"
  local public_addr="${SCCACHE_DIST_SERVER_PUBLIC_ADDR:-}"
  local cache_dir="${SCCACHE_DIST_SERVER_CACHE_DIR:-/var/cache/sccache-dist/toolchains}"
  local build_dir="${SCCACHE_DIST_SERVER_BUILD_DIR:-/var/tmp/sccache-dist/build}"
  local cache_size="${SCCACHE_DIST_TOOLCHAIN_CACHE_SIZE:-4294967296}"
  local server_token

  [[ -n "${public_addr}" ]] || die 'SCCACHE_DIST_SERVER_PUBLIC_ADDR is required for server mode'

  server_token="$(read_secret "${SCCACHE_DIST_SERVER_TOKEN_FILE:-}")"
  mkdir -p "${cache_dir}" "${build_dir}"

  cat > "${config_path}" <<EOF
cache_dir = "${cache_dir}"
public_addr = "${public_addr}"
bind_address = "${bind_addr}"
scheduler_url = "${scheduler_url}"
toolchain_cache_size = "${cache_size}"

[builder]
type = "overlay"
build_dir = "${build_dir}"
bwrap_path = "/usr/bin/bwrap"

[scheduler_auth]
type = "token"
token = "${server_token}"
EOF
}

main() {
  local mode="${1:-}"
  local config_dir="${TMPDIR:-/tmp}/sccache-dist"
  local config_path

  [[ -n "${mode}" ]] || die 'usage: sccache-dist-entrypoint <scheduler|server>'

  mkdir -p "${config_dir}"
  config_path="${config_dir}/${mode}.toml"

  case "${mode}" in
    scheduler)
      write_scheduler_config "${config_path}"
      SCCACHE_NO_DAEMON=1 exec /usr/local/bin/sccache-dist scheduler --config "${config_path}"
      ;;
    server)
      write_server_config "${config_path}"
      SCCACHE_NO_DAEMON=1 exec /usr/local/bin/sccache-dist server --config "${config_path}"
      ;;
    *)
      die "unsupported mode: ${mode}"
      ;;
  esac
}

main "$@"
