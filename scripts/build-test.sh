#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-container-toolchain.sh
source "${script_dir}/lib-container-toolchain.sh"

toolchain="$(detect_build_test_toolchain)"
container_bin="$(container_runtime_for_toolchain "${toolchain}")"
build_bin="$(build_command_for_toolchain "${toolchain}")"
control_plane_image="${CONTROL_PLANE_IMAGE_TAG:-localhost/control-plane:test}"
execution_plane_image="${EXECUTION_PLANE_IMAGE_TAG:-localhost/execution-plane-smoke:test}"
cluster_name="${CONTROL_PLANE_KIND_CLUSTER_NAME:-control-plane-ci}"
kind_provider="${KIND_EXPERIMENTAL_PROVIDER:-${container_bin}}"

if [[ -n "${CONTROL_PLANE_CONTAINER_BIN:-}" ]] && [[ "${CONTROL_PLANE_CONTAINER_BIN}" != "${container_bin}" ]]; then
  printf 'CONTROL_PLANE_CONTAINER_BIN=%s conflicts with %s toolchain\n' "${CONTROL_PLANE_CONTAINER_BIN}" "${toolchain}" >&2
  exit 1
fi

require_command "${build_bin}"
require_command "${container_bin}"
require_command kind
require_command kubectl
require_command ssh
require_command ssh-keygen

printf 'Using %s toolchain for build/test\n' "${toolchain}"
build_image_for_toolchain "${toolchain}" "${control_plane_image}" containers/control-plane
build_image_for_toolchain "${toolchain}" "${execution_plane_image}" containers/execution-plane-smoke

CONTROL_PLANE_CONTAINER_BIN="${container_bin}" \
  "${script_dir}/test-standalone.sh" "${control_plane_image}" "${execution_plane_image}"

CONTROL_PLANE_CONTAINER_BIN="${container_bin}" \
  "${script_dir}/test-regressions.sh" "${control_plane_image}"

KIND_EXPERIMENTAL_PROVIDER="${kind_provider}" \
  CONTROL_PLANE_CONTAINER_BIN="${container_bin}" \
  "${script_dir}/test-kind.sh" "${control_plane_image}" "${execution_plane_image}" "${cluster_name}"
