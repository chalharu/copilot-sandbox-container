#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

assert_file_contains() {
  local path="$1"
  local expected="$2"

  grep -Fq -- "${expected}" "${path}" || {
    printf 'Expected %s to contain: %s\n' "${path}" "${expected}" >&2
    exit 1
  }
}

assert_file_not_matches() {
  local path="$1"
  local unexpected_pattern="$2"

  if grep -Eq -- "${unexpected_pattern}" "${path}"; then
    printf 'Did not expect %s to match: %s\n' "${path}" "${unexpected_pattern}" >&2
    exit 1
  fi
}

assert_exact_following_lines() {
  local path="$1"
  local anchor="$2"
  local first_expected="$3"
  local second_expected="$4"
  local third_expected="$5"

  awk \
    -v anchor="${anchor}" \
    -v first_expected="${first_expected}" \
    -v second_expected="${second_expected}" \
    -v third_expected="${third_expected}" '
      $0 == anchor {
        if (getline <= 0) {
          next
        }
        first_line = $0
        if (getline <= 0) {
          next
        }
        second_line = $0
        if (getline <= 0) {
          next
        }
        third_line = $0
        if (first_line == first_expected && second_line == second_expected && third_line == third_expected) {
          found = 1
          exit 0
        }
      }
      END {
        exit(found ? 0 : 1)
      }
    ' "${path}" || {
      printf 'Expected %s to contain %s, %s, and %s immediately after %s\n' \
        "${path}" \
        "${first_expected}" \
        "${second_expected}" \
        "${third_expected}" \
        "${anchor}" >&2
      exit 1
    }
}

assert_path_absent() {
  local path="$1"

  if [[ -e "${path}" ]]; then
    printf 'Did not expect %s to exist\n' "${path}" >&2
    exit 1
  fi
}

assert_healthcheck_cmd() {
  local path="$1"
  local expected_cmd_line="$2"
  local healthcheck_line=""
  local cmd_line=""

  healthcheck_line="$(grep -nF "HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \\" "${path}" | head -n 1 | cut -d: -f1 || true)"
  cmd_line="$(grep -nF -- "${expected_cmd_line}" "${path}" | head -n 1 | cut -d: -f1 || true)"

  if [[ -z "${healthcheck_line}" ]] || [[ -z "${cmd_line}" ]] || [[ "${cmd_line}" -ne $((healthcheck_line + 1)) ]]; then
    printf 'Expected %s to contain HEALTHCHECK followed by: %s\n' "${path}" "${expected_cmd_line}" >&2
    exit 1
  fi
}

printf '%s\n' 'dockerfile-hardening-test: verifying non-root defaults and healthchecks' >&2

control_plane_dockerfile="${repo_root}/containers/control-plane/Dockerfile"
exec_pod_dockerfile="${repo_root}/containers/exec-pod/Dockerfile"
execution_plane_smoke_dir="${repo_root}/containers/execution-plane-smoke"
legacy_yamllint_installer="${repo_root}/containers/control-plane/build/install-yamllint-wheel.py"
legacy_execution_plane_go_dockerfile="${repo_root}/containers/execution-plane-go/Dockerfile"
legacy_execution_plane_node_dockerfile="${repo_root}/containers/execution-plane-node/Dockerfile"
legacy_execution_plane_python_dockerfile="${repo_root}/containers/execution-plane-python/Dockerfile"
legacy_execution_plane_rust_dockerfile="${repo_root}/containers/execution-plane-rust/Dockerfile"
legacy_yamllint_dockerfile="${repo_root}/containers/yamllint/Dockerfile"

assert_file_contains "${control_plane_dockerfile}" "USER \${CONTROL_PLANE_USER}"
assert_file_not_matches "${control_plane_dockerfile}" '^USER root$'
assert_healthcheck_cmd "${control_plane_dockerfile}" '    CMD ["bash", "-lc", "pgrep -x sshd >/dev/null"]'
assert_file_contains "${control_plane_dockerfile}" 'YAMLLINT_VIRTUAL_ENV=/opt/yamllint'
assert_file_contains "${control_plane_dockerfile}" 'python3-venv'
assert_file_contains "${control_plane_dockerfile}" "python3 -m venv \"\${YAMLLINT_VIRTUAL_ENV}\""
assert_file_contains "${control_plane_dockerfile}" "        git \\"
assert_file_contains "${control_plane_dockerfile}" '/tmp/yamllint-requirements.txt'
assert_file_contains "${control_plane_dockerfile}" '--only-binary=:all: --require-hashes -r /tmp/yamllint-requirements.txt'
assert_file_contains "${control_plane_dockerfile}" 'LANG=C.UTF-8'
assert_file_contains "${control_plane_dockerfile}" 'LC_CTYPE=C.UTF-8'
assert_file_contains "${control_plane_dockerfile}" "cargo_chef_download_root=\"https://github.com/LukeMathWalker/cargo-chef/releases/download/v\${CARGO_CHEF_VERSION}\""
assert_file_contains "${control_plane_dockerfile}" 'ARG CARGO_CHEF_X86_64_UNKNOWN_LINUX_GNU_SHA256='
assert_file_contains "${control_plane_dockerfile}" 'ARG CARGO_CHEF_AARCH64_UNKNOWN_LINUX_GNU_SHA256='
assert_file_contains "${control_plane_dockerfile}" "cargo_chef_sha256=\"\${CARGO_CHEF_X86_64_UNKNOWN_LINUX_GNU_SHA256}\""
assert_file_contains "${control_plane_dockerfile}" "cargo_chef_sha256=\"\${CARGO_CHEF_AARCH64_UNKNOWN_LINUX_GNU_SHA256}\""
assert_file_contains "${control_plane_dockerfile}" 'cargo-chef-x86_64-unknown-linux-gnu.tar.xz'
assert_file_contains "${control_plane_dockerfile}" 'cargo-chef-aarch64-unknown-linux-gnu.tar.xz'
assert_file_not_matches "${control_plane_dockerfile}" 'cargo install cargo-chef'
assert_file_contains "${control_plane_dockerfile}" "        locales \\"
assert_file_contains "${control_plane_dockerfile}" "        vim \\"
assert_file_contains "${control_plane_dockerfile}" 'locale-gen'
assert_file_contains "${control_plane_dockerfile}" 'localedef -i ja_JP -f UTF-8 ja_JP.UTF8'
assert_file_not_matches "${control_plane_dockerfile}" 'install-yamllint-wheel\.py|python3-pathspec|python3-yaml|YAMLLINT_WHEEL_SHA256'
assert_file_not_matches "${control_plane_dockerfile}" 'cpulimit|gcc|libc6-dev|libssl-dev|ncurses-term|pkg-config'
# shellcheck disable=SC2016
assert_file_contains "${exec_pod_dockerfile}" 'FROM ${RUST_BASE_IMAGE}'
assert_file_contains "${exec_pod_dockerfile}" "        build-essential \\"
assert_file_contains "${exec_pod_dockerfile}" "        binaryen \\"
assert_file_contains "${exec_pod_dockerfile}" "        cmake \\"
assert_file_contains "${exec_pod_dockerfile}" "        docker.io \\"
assert_file_contains "${exec_pod_dockerfile}" "        jq \\"
assert_file_contains "${exec_pod_dockerfile}" "        libgtk-3-dev \\"
assert_file_contains "${exec_pod_dockerfile}" "        libgtk-4-dev \\"
assert_file_contains "${exec_pod_dockerfile}" "        libpango1.0-dev \\"
assert_file_contains "${exec_pod_dockerfile}" "        libssl-dev \\"
assert_file_contains "${exec_pod_dockerfile}" "        mold \\"
assert_file_contains "${exec_pod_dockerfile}" "        nodejs \\"
assert_file_contains "${exec_pod_dockerfile}" "        npm \\"
assert_file_contains "${exec_pod_dockerfile}" "        pkg-config \\"
assert_file_contains "${exec_pod_dockerfile}" "        pkgconf \\"
assert_file_contains "${exec_pod_dockerfile}" "        python3 \\"
assert_file_contains "${exec_pod_dockerfile}" "        python3-pathspec \\"
assert_file_contains "${exec_pod_dockerfile}" "        python3-pygments \\"
assert_file_contains "${exec_pod_dockerfile}" "        python3-venv \\"
assert_file_contains "${exec_pod_dockerfile}" "        ripgrep \\"
assert_file_contains "${exec_pod_dockerfile}" "        sccache \\"
assert_file_contains "${exec_pod_dockerfile}" "        sudo \\"
assert_file_contains "${exec_pod_dockerfile}" "        xz-utils \\"
assert_file_contains "${exec_pod_dockerfile}" "        yamllint \\"
assert_file_contains "${exec_pod_dockerfile}" "cargo_chef_download_root=\"https://github.com/LukeMathWalker/cargo-chef/releases/download/v\${CARGO_CHEF_VERSION}\""
assert_file_contains "${exec_pod_dockerfile}" 'ARG CARGO_CHEF_X86_64_UNKNOWN_LINUX_GNU_SHA256='
assert_file_contains "${exec_pod_dockerfile}" 'ARG CARGO_CHEF_AARCH64_UNKNOWN_LINUX_GNU_SHA256='
assert_file_contains "${exec_pod_dockerfile}" "cargo_chef_sha256=\"\${CARGO_CHEF_X86_64_UNKNOWN_LINUX_GNU_SHA256}\""
assert_file_contains "${exec_pod_dockerfile}" "cargo_chef_sha256=\"\${CARGO_CHEF_AARCH64_UNKNOWN_LINUX_GNU_SHA256}\""
assert_file_contains "${exec_pod_dockerfile}" "trunk_download_root=\"https://github.com/trunk-rs/trunk/releases/download/v\${TRUNK_VERSION}\""
assert_file_contains "${exec_pod_dockerfile}" 'ARG TRUNK_X86_64_UNKNOWN_LINUX_GNU_SHA256='
assert_file_contains "${exec_pod_dockerfile}" 'ARG TRUNK_AARCH64_UNKNOWN_LINUX_GNU_SHA256='
assert_file_contains "${exec_pod_dockerfile}" "trunk_sha256=\"\${TRUNK_X86_64_UNKNOWN_LINUX_GNU_SHA256}\""
assert_file_contains "${exec_pod_dockerfile}" "trunk_sha256=\"\${TRUNK_AARCH64_UNKNOWN_LINUX_GNU_SHA256}\""
assert_file_contains "${exec_pod_dockerfile}" "wasm_bindgen_download_root=\"https://github.com/rustwasm/wasm-bindgen/releases/download/\${WASM_BINDGEN_CLI_VERSION}\""
assert_file_contains "${exec_pod_dockerfile}" 'ARG WASM_BINDGEN_X86_64_UNKNOWN_LINUX_MUSL_SHA256='
assert_file_contains "${exec_pod_dockerfile}" 'ARG WASM_BINDGEN_AARCH64_UNKNOWN_LINUX_GNU_SHA256='
assert_file_contains "${exec_pod_dockerfile}" "wasm_bindgen_sha256=\"\${WASM_BINDGEN_X86_64_UNKNOWN_LINUX_MUSL_SHA256}\""
assert_file_contains "${exec_pod_dockerfile}" "wasm_bindgen_sha256=\"\${WASM_BINDGEN_AARCH64_UNKNOWN_LINUX_GNU_SHA256}\""
assert_file_contains "${exec_pod_dockerfile}" "cargo_deny_download_root=\"https://github.com/EmbarkStudios/cargo-deny/releases/download/\${CARGO_DENY_VERSION}\""
assert_file_contains "${exec_pod_dockerfile}" 'ARG CARGO_DENY_X86_64_UNKNOWN_LINUX_MUSL_SHA256='
assert_file_contains "${exec_pod_dockerfile}" 'ARG CARGO_DENY_AARCH64_UNKNOWN_LINUX_MUSL_SHA256='
assert_file_contains "${exec_pod_dockerfile}" "cargo_deny_sha256=\"\${CARGO_DENY_X86_64_UNKNOWN_LINUX_MUSL_SHA256}\""
assert_file_contains "${exec_pod_dockerfile}" "cargo_deny_sha256=\"\${CARGO_DENY_AARCH64_UNKNOWN_LINUX_MUSL_SHA256}\""
assert_file_contains "${exec_pod_dockerfile}" 'ARG CARGO_AUDIT_X86_64_UNKNOWN_LINUX_MUSL_SHA256='
assert_file_contains "${exec_pod_dockerfile}" 'ARG CARGO_AUDIT_AARCH64_UNKNOWN_LINUX_GNU_SHA256='
assert_file_contains "${exec_pod_dockerfile}" 'ARG CARGO_LLVM_COV_X86_64_UNKNOWN_LINUX_GNU_SHA256='
assert_file_contains "${exec_pod_dockerfile}" 'ARG CARGO_LLVM_COV_AARCH64_UNKNOWN_LINUX_GNU_SHA256='
assert_file_contains "${exec_pod_dockerfile}" "cargo_audit_download_root=\"https://github.com/rustsec/rustsec/releases/download/cargo-audit/v\${CARGO_AUDIT_VERSION}\""
assert_file_contains "${exec_pod_dockerfile}" "cargo_llvm_cov_download_root=\"https://github.com/taiki-e/cargo-llvm-cov/releases/download/v\${CARGO_LLVM_COV_VERSION}\""
assert_file_not_matches "${exec_pod_dockerfile}" "cargo install --locked --root /opt/control-plane-tools --version \"\${TRUNK_VERSION}\" trunk|cargo install --locked --root /opt/control-plane-tools --version \"\${WASM_BINDGEN_CLI_VERSION}\" wasm-bindgen-cli|cargo install --locked --root /opt/control-plane-tools --version \"\${CARGO_DENY_VERSION}\" cargo-deny|cargo install --locked --root /opt/control-plane-tools --version \"\${CARGO_AUDIT_VERSION}\" cargo-audit|cargo install --locked --root /opt/control-plane-tools --version \"\${CARGO_LLVM_COV_VERSION}\" cargo-llvm-cov|cargo install --locked --root /opt/control-plane-tools --version \"\${TAPLO_CLI_VERSION}\" taplo-cli"
assert_file_contains "${exec_pod_dockerfile}" 'ARG TAPLO_LINUX_X86_64_SHA256='
assert_file_contains "${exec_pod_dockerfile}" 'ARG TAPLO_LINUX_AARCH64_SHA256='
assert_file_contains "${exec_pod_dockerfile}" "taplo_download_root=\"https://github.com/tamasfe/taplo/releases/download/\${TAPLO_CLI_VERSION}\""
assert_file_contains "${exec_pod_dockerfile}" 'taplo_asset="taplo-linux-x86_64.gz"'
assert_file_contains "${exec_pod_dockerfile}" 'taplo_asset="taplo-linux-aarch64.gz"'
assert_file_contains "${exec_pod_dockerfile}" "gzip -dc \"/tmp/\${taplo_asset}\" > /opt/control-plane-tools/bin/taplo"
assert_file_contains "${exec_pod_dockerfile}" 'ARG NODE_VERSION='
assert_file_contains "${exec_pod_dockerfile}" 'ARG NODE_LINUX_X64_SHA256='
assert_file_contains "${exec_pod_dockerfile}" 'ARG NODE_LINUX_ARM64_SHA256='
assert_file_contains "${exec_pod_dockerfile}" "node_download_root=\"https://nodejs.org/dist/v\${NODE_VERSION}\""
assert_file_contains "${exec_pod_dockerfile}" "node_asset=\"node-v\${NODE_VERSION}-linux-\${node_arch}.tar.xz\""
assert_file_contains "${exec_pod_dockerfile}" 'install -d /opt/control-plane-pnpm-node/bin'
assert_file_contains "${exec_pod_dockerfile}" "tar -xJf \"/tmp/\${node_asset}\" -C /opt/control-plane-pnpm-node/bin --strip-components=2 \\"
assert_file_contains "${exec_pod_dockerfile}" "\"node-v\${NODE_VERSION}-linux-\${node_arch}/bin/node\""
assert_file_contains "${exec_pod_dockerfile}" "rm -f \"/tmp/\${node_asset}\""
assert_file_contains "${exec_pod_dockerfile}" 'ln -sfn /opt/control-plane-pnpm-node/bin/node /usr/local/bin/node'
assert_file_contains "${exec_pod_dockerfile}" 'ln -sfn /opt/control-plane-pnpm-node/bin/node /usr/local/bin/nodejs'
assert_file_contains "${exec_pod_dockerfile}" 'ln -sfn /opt/control-plane-pnpm-node/bin/node /usr/bin/node'
assert_file_contains "${exec_pod_dockerfile}" 'ln -sfn /opt/control-plane-pnpm-node/bin/node /usr/bin/nodejs'
assert_file_contains "${exec_pod_dockerfile}" "npm_entry=\"\$(readlink -f \"\$(command -v npm)\")\""
assert_file_contains "${exec_pod_dockerfile}" 'rm -f /usr/local/bin/npm'
assert_file_contains "${exec_pod_dockerfile}" "/opt/control-plane-pnpm-node/bin/node \\\"\${npm_entry}\\\" \\\"\\\$@\\\""
assert_file_contains "${exec_pod_dockerfile}" 'node --version >/dev/null'
assert_file_contains "${exec_pod_dockerfile}" 'npm --version >/dev/null'
assert_file_not_matches "${exec_pod_dockerfile}" 'apt-get purge -y --auto-remove xz-utils'
assert_file_contains "${exec_pod_dockerfile}" "pnpm_package_root=\"\$(npm root --global)/pnpm\""
assert_file_contains "${exec_pod_dockerfile}" "pnpm_entry=\"\${pnpm_package_root}/\$(jq -er '.bin.pnpm' \"\${pnpm_package_root}/package.json\")\""
assert_file_contains "${exec_pod_dockerfile}" 'rm -f /usr/local/bin/pnpm'
assert_file_contains "${exec_pod_dockerfile}" "export PATH=\\\"/opt/control-plane-pnpm-node/bin:\\\${PATH}\\\""
assert_file_contains "${exec_pod_dockerfile}" "/opt/control-plane-pnpm-node/bin/node \\\"\${pnpm_entry}\\\" \\\"\\\$@\\\""
assert_file_contains "${exec_pod_dockerfile}" "pnpx_relative=\"\$(jq -er '.bin.pnpx // empty' \"\${pnpm_package_root}/package.json\")\""
assert_file_contains "${exec_pod_dockerfile}" "pnpx_entry=\"\${pnpm_package_root}/\${pnpx_relative}\""
assert_file_contains "${exec_pod_dockerfile}" "rm -f /usr/local/bin/pnpx; \\"
assert_file_contains "${exec_pod_dockerfile}" "/opt/control-plane-pnpm-node/bin/node \\\"\${pnpx_entry}\\\" \\\"\\\$@\\\""
assert_exact_following_lines \
  "${exec_pod_dockerfile}" \
  "FROM \${RUST_BASE_IMAGE}" \
  'ARG NODE_VERSION' \
  'ARG NODE_LINUX_X64_SHA256' \
  'ARG NODE_LINUX_ARM64_SHA256'
assert_file_contains "${exec_pod_dockerfile}" 'LIZARD_VIRTUAL_ENV=/opt/lizard'
assert_file_contains "${exec_pod_dockerfile}" 'rustup target add wasm32-unknown-unknown'
assert_file_contains "${exec_pod_dockerfile}" 'rustup component add clippy llvm-tools-preview rustfmt'
assert_file_contains "${exec_pod_dockerfile}" '/tmp/lizard-pypi.json'
assert_file_contains "${exec_pod_dockerfile}" "\"/tmp/\${lizard_wheel}\""
assert_file_contains "${exec_pod_dockerfile}" 'sha256sum -c -'
assert_file_contains "${exec_pod_dockerfile}" "python3 -m venv --system-site-packages \"\${LIZARD_VIRTUAL_ENV}\""
assert_file_contains "${exec_pod_dockerfile}" "\"\${LIZARD_VIRTUAL_ENV}/bin/pip\" install --no-cache-dir --no-deps \"/tmp/\${lizard_wheel}\""
assert_file_contains "${exec_pod_dockerfile}" '/tmp/pnpm-metadata.json'
assert_file_contains "${exec_pod_dockerfile}" "pnpm_integrity=\"\$(jq -er '.dist.integrity' /tmp/pnpm-metadata.json)\""
assert_file_contains "${exec_pod_dockerfile}" 'pnpm integrity mismatch'
assert_file_contains "${exec_pod_dockerfile}" 'npm install --global "/tmp/pnpm.tgz"'
assert_file_contains "${exec_pod_dockerfile}" 'ARG CARGO_LLVM_COV_VERSION='
assert_file_contains "${exec_pod_dockerfile}" 'ARG CARGO_AUDIT_X86_64_UNKNOWN_LINUX_MUSL_SHA256='
assert_file_contains "${exec_pod_dockerfile}" 'ARG CARGO_AUDIT_AARCH64_UNKNOWN_LINUX_GNU_SHA256='
assert_file_contains "${exec_pod_dockerfile}" 'ARG CARGO_LLVM_COV_X86_64_UNKNOWN_LINUX_GNU_SHA256='
assert_file_contains "${exec_pod_dockerfile}" 'ARG CARGO_LLVM_COV_AARCH64_UNKNOWN_LINUX_GNU_SHA256='
assert_file_contains "${exec_pod_dockerfile}" 'ARG TAPLO_CLI_VERSION='
assert_file_contains "${exec_pod_dockerfile}" 'ARG TRUNK_X86_64_UNKNOWN_LINUX_GNU_SHA256='
assert_file_contains "${exec_pod_dockerfile}" 'ARG TRUNK_AARCH64_UNKNOWN_LINUX_GNU_SHA256='
assert_file_contains "${exec_pod_dockerfile}" 'ARG WASM_BINDGEN_X86_64_UNKNOWN_LINUX_MUSL_SHA256='
assert_file_contains "${exec_pod_dockerfile}" 'ARG WASM_BINDGEN_AARCH64_UNKNOWN_LINUX_GNU_SHA256='
assert_file_contains "${exec_pod_dockerfile}" 'ARG CARGO_DENY_X86_64_UNKNOWN_LINUX_MUSL_SHA256='
assert_file_contains "${exec_pod_dockerfile}" 'ARG CARGO_DENY_AARCH64_UNKNOWN_LINUX_MUSL_SHA256='
assert_file_contains "${exec_pod_dockerfile}" 'ARG TAPLO_LINUX_X86_64_SHA256='
assert_file_contains "${exec_pod_dockerfile}" 'ARG TAPLO_LINUX_AARCH64_SHA256='
assert_file_contains "${exec_pod_dockerfile}" 'ARG CHROME_FOR_TESTING_VERSION='
assert_file_contains "${exec_pod_dockerfile}" 'ARG CHROME_FOR_TESTING_CHROME_LINUX64_SHA256='
assert_file_contains "${exec_pod_dockerfile}" 'ARG CHROME_FOR_TESTING_CHROMEDRIVER_LINUX64_SHA256='
assert_file_contains "${exec_pod_dockerfile}" 'browser_apt_packages=()'
assert_file_contains "${exec_pod_dockerfile}" "        amd64) \\"
assert_file_contains "${exec_pod_dockerfile}" "          node_arch=x64; \\"
assert_file_contains "${exec_pod_dockerfile}" "          node_sha256=\"\${NODE_LINUX_X64_SHA256}\"; \\"
assert_file_contains "${exec_pod_dockerfile}" "          chrome_for_testing_platform=linux64; \\"
assert_file_contains "${exec_pod_dockerfile}" "        arm64) \\"
assert_file_contains "${exec_pod_dockerfile}" "          node_arch=arm64; \\"
assert_file_contains "${exec_pod_dockerfile}" "          node_sha256=\"\${NODE_LINUX_ARM64_SHA256}\"; \\"
assert_file_contains "${exec_pod_dockerfile}" "          browser_apt_packages=(chromium chromium-driver); \\"
assert_file_contains "${exec_pod_dockerfile}" "        unzip \\"
assert_file_contains "${exec_pod_dockerfile}" "        xdg-utils \\"
assert_file_contains "${exec_pod_dockerfile}" "        fonts-liberation \\"
assert_file_contains "${exec_pod_dockerfile}" "        libgtk-3-0 \\"
assert_file_contains "${exec_pod_dockerfile}" "        libnss3 \\"
assert_file_contains "${exec_pod_dockerfile}" "        \"\${browser_apt_packages[@]}\" \\"
assert_file_contains "${exec_pod_dockerfile}" '/tmp/chrome-for-testing.json'
assert_file_contains "${exec_pod_dockerfile}" "jq -er --arg version \"\${CHROME_FOR_TESTING_VERSION}\" 'select(.version == \$version) | .version' /tmp/chrome-for-testing.json >/dev/null"
assert_file_contains "${exec_pod_dockerfile}" "chrome_download_url=\"\$(jq -er --arg platform \"\${chrome_for_testing_platform}\" 'first(.downloads.chrome[] | select(.platform == \$platform) | .url)' /tmp/chrome-for-testing.json)\""
assert_file_contains "${exec_pod_dockerfile}" "chromedriver_download_url=\"\$(jq -er --arg platform \"\${chrome_for_testing_platform}\" 'first(.downloads.chromedriver[] | select(.platform == \$platform) | .url)' /tmp/chrome-for-testing.json)\""
assert_file_contains "${exec_pod_dockerfile}" "curl -fsSLo /tmp/chrome-linux64.zip \"\${chrome_download_url}\""
assert_file_contains "${exec_pod_dockerfile}" "printf '%s  %s\\n' \"\${CHROME_FOR_TESTING_CHROME_LINUX64_SHA256}\" /tmp/chrome-linux64.zip | sha256sum -c -"
assert_file_contains "${exec_pod_dockerfile}" "curl -fsSLo /tmp/chromedriver-linux64.zip \"\${chromedriver_download_url}\""
assert_file_contains "${exec_pod_dockerfile}" "printf '%s  %s\\n' \"\${CHROME_FOR_TESTING_CHROMEDRIVER_LINUX64_SHA256}\" /tmp/chromedriver-linux64.zip | sha256sum -c -"
assert_file_contains "${exec_pod_dockerfile}" 'unzip -q /tmp/chrome-linux64.zip -d /opt'
assert_file_contains "${exec_pod_dockerfile}" 'unzip -q /tmp/chromedriver-linux64.zip -d /opt'
assert_file_contains "${exec_pod_dockerfile}" 'ln -sf /opt/chrome-linux64/chrome /usr/local/bin/google-chrome'
assert_file_contains "${exec_pod_dockerfile}" 'ln -sf /usr/local/bin/google-chrome /usr/local/bin/google-chrome-stable'
assert_file_contains "${exec_pod_dockerfile}" 'ln -sf /usr/local/bin/google-chrome /usr/local/bin/chrome'
assert_file_contains "${exec_pod_dockerfile}" 'ln -sf /opt/chromedriver-linux64/chromedriver /usr/local/bin/chromedriver'
assert_file_contains "${exec_pod_dockerfile}" 'ln -sf /usr/bin/chromium /usr/local/bin/google-chrome'
assert_file_contains "${exec_pod_dockerfile}" 'ln -sf /usr/bin/chromedriver /usr/local/bin/chromedriver'
assert_file_contains "${exec_pod_dockerfile}" 'unset LD_PRELOAD CONTROL_PLANE_EXEC_POLICY_RULES_FILE'
assert_file_contains "${exec_pod_dockerfile}" 'exec /usr/bin/mold "$@"'
assert_file_contains "${exec_pod_dockerfile}" 'exec /usr/bin/ld.mold "$@"'
assert_file_contains "${exec_pod_dockerfile}" 'ln -sf /usr/local/cargo/bin/cargo /usr/local/bin/cargo'
assert_file_contains "${exec_pod_dockerfile}" 'ln -sf /usr/local/cargo/bin/rustc /usr/local/bin/rustc'
assert_file_contains "${exec_pod_dockerfile}" 'ln -sf /usr/local/cargo/bin/rustup /usr/local/bin/rustup'
assert_file_contains "${exec_pod_dockerfile}" '/usr/libexec/docker/cli-plugins/docker-buildx'
assert_file_contains "${exec_pod_dockerfile}" 'chmod 1770 /root'
assert_file_contains "${exec_pod_dockerfile}" 'COPY containers/control-plane/hooks/ /usr/local/share/control-plane/hooks/'
assert_file_contains "${exec_pod_dockerfile}" 'COPY --from=cargo-tools-builder /opt/control-plane-tools/bin/ /usr/local/bin/'
assert_file_contains "${exec_pod_dockerfile}" 'COPY --from=exec-api-builder /var/tmp/control-plane/cargo-target/release/control-plane-exec-api /usr/local/bin/control-plane-exec-api'
assert_healthcheck_cmd "${exec_pod_dockerfile}" "    CMD [\"bash\", \"-lc\", \"control-plane-exec-api health --addr \\\"http://127.0.0.1:\${CONTROL_PLANE_FAST_EXECUTION_PORT:-8080}\\\" --timeout-sec 2\"]"
# shellcheck disable=SC2016
assert_file_contains "${exec_pod_dockerfile}" 'USER ${CONTROL_PLANE_USER}'
assert_file_not_matches "${exec_pod_dockerfile}" '^USER root$'
assert_file_contains "${exec_pod_dockerfile}" 'CMD ["/usr/local/bin/control-plane-exec-api", "serve"]'

assert_path_absent "${execution_plane_smoke_dir}"
assert_path_absent "${legacy_yamllint_installer}"
assert_path_absent "${legacy_execution_plane_go_dockerfile}"
assert_path_absent "${legacy_execution_plane_node_dockerfile}"
assert_path_absent "${legacy_execution_plane_python_dockerfile}"
assert_path_absent "${legacy_execution_plane_rust_dockerfile}"
assert_path_absent "${legacy_yamllint_dockerfile}"

printf '%s\n' 'dockerfile-hardening-test: dockerfile hardening ok' >&2
