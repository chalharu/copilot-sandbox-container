#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
checkout_parent="${1:?usage: scripts/fetch-anthropic-skills.sh <checkout-parent-dir>}"
checkout_dir="${checkout_parent%/}/anthropic-skills"
anthropic_skills_ref_file="${repo_root}/containers/control-plane/config/anthropic-skills.ref"
anthropic_skills_repository="${ANTHROPIC_SKILLS_REPOSITORY:-https://github.com/anthropics/skills}"
anthropic_skills_ref="${ANTHROPIC_SKILLS_REF:-$(tr -d '\n' < "${anthropic_skills_ref_file}")}"

# shellcheck source=scripts/lib-container-toolchain.sh
source "${script_dir}/lib-container-toolchain.sh"

require_command git

install -d -m 0755 "${checkout_parent}"
rm -rf "${checkout_dir}"

git clone "${anthropic_skills_repository}" "${checkout_dir}" >&2
git -C "${checkout_dir}" checkout --detach "${anthropic_skills_ref}" >&2

test -f "${checkout_dir}/skills/doc-coauthoring/SKILL.md"
test -f "${checkout_dir}/skills/skill-creator/SKILL.md"

printf '%s\n' "${checkout_dir}"
