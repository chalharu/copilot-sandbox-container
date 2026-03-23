#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_url="${1:?usage: scripts/install-git-skill.sh <repository-url> <git-ref> <skill-path> <destination-dir>}"
git_ref="${2:?usage: scripts/install-git-skill.sh <repository-url> <git-ref> <skill-path> <destination-dir>}"
skill_path="${3:?usage: scripts/install-git-skill.sh <repository-url> <git-ref> <skill-path> <destination-dir>}"
destination_dir="${4:?usage: scripts/install-git-skill.sh <repository-url> <git-ref> <skill-path> <destination-dir>}"
checkout_dir="$(mktemp -d)"

# shellcheck source=scripts/lib-container-toolchain.sh
source "${script_dir}/lib-container-toolchain.sh"

cleanup() {
  rm -rf "${checkout_dir}"
}
trap cleanup EXIT

require_command git

git clone "${repository_url}" "${checkout_dir}/repo" >&2
git -C "${checkout_dir}/repo" checkout --detach "${git_ref}" >&2

source_skill_dir="${checkout_dir}/repo/${skill_path}"
test -f "${source_skill_dir}/SKILL.md"

install -d -m 0755 "$(dirname "${destination_dir}")"
rm -rf "${destination_dir}"
cp -a "${source_skill_dir}" "${destination_dir}"
