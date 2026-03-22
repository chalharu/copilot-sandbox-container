---
name: containerized-rust-ops
description: Run Rust fmt/check/clippy/build/test through the bundled container helpers instead of relying on a host Rust toolchain. Use when validating Rust worktrees locally with Podman, rerunning long Rust builds on the control plane, or debugging this containerized Rust workflow across repositories.
---

# Containerized Rust Ops

Use the bundled helper scripts instead of rebuilding `podman` or `control-plane-run` commands by hand.

## Choose the workflow

1. Need local lint, check, clippy, build, or test against the current worktree? Run `~/.copilot/skills/containerized-rust-ops/scripts/podman-rust.sh`.
2. Need a long-running build or test on the control plane? Run `~/.copilot/skills/containerized-rust-ops/scripts/k8s-rust.sh`.
3. When editing this repository itself, the source-path equivalents live under `containers/control-plane/skills/containerized-rust-ops/scripts/`.
4. Need to understand why a containerized run is behaving strangely? Read `references/runtime-quirks.md` before changing the commands.
5. Need `cargo llvm-cov`? Use the bundled release-bootstrap path instead of `cargo install`; the helper installs `cargo-llvm-cov` from pinned releases, and custom archives or versions must also provide `CARGO_LLVM_COV_ARCHIVE_SHA256`.

## Run local Podman validation

Examples:

- `bash ~/.copilot/skills/containerized-rust-ops/scripts/podman-rust.sh fmt`
- `bash ~/.copilot/skills/containerized-rust-ops/scripts/podman-rust.sh fmt-check`
- `bash ~/.copilot/skills/containerized-rust-ops/scripts/podman-rust.sh check`
- `bash ~/.copilot/skills/containerized-rust-ops/scripts/podman-rust.sh clippy-fix`
- `bash ~/.copilot/skills/containerized-rust-ops/scripts/podman-rust.sh clippy`
- `bash ~/.copilot/skills/containerized-rust-ops/scripts/podman-rust.sh build`
- `bash ~/.copilot/skills/containerized-rust-ops/scripts/podman-rust.sh test`
- `bash ~/.copilot/skills/containerized-rust-ops/scripts/podman-rust.sh -- cargo test --workspace --all-targets -- --nocapture`
- `bash ~/.copilot/skills/containerized-rust-ops/scripts/podman-rust.sh -- cargo llvm-cov --workspace --all-targets --summary-only`

The helper keeps toolchain state under disk-backed `TMPDIR` / `/var/tmp`, stores `sccache` in a dedicated sibling cache directory, keeps `target` ephemeral, and builds or reuses the bundled `assets/sccache-image/` container instead of bootstrapping `sccache` from source on every run.

## Run control-plane Kubernetes validation

Use this only after the branch state you want is on `origin`, because the job clones from the remote branch instead of reading unpushed local changes.

Examples:

- `bash ~/.copilot/skills/containerized-rust-ops/scripts/k8s-rust.sh build`
- `bash ~/.copilot/skills/containerized-rust-ops/scripts/k8s-rust.sh test`
- `bash ~/.copilot/skills/containerized-rust-ops/scripts/k8s-rust.sh -- cargo test --workspace --all-targets -- --nocapture`
- `bash ~/.copilot/skills/containerized-rust-ops/scripts/k8s-rust.sh -- cargo llvm-cov --workspace --all-targets --summary-only`

The Kubernetes helper keeps the clone, temp files, and `target` under `/var/tmp/containerized-rust/...`, while `cargo`, `rustup`, and `sccache` stay under `/workspace/cache/...` so the reusable caches survive across jobs without filling the PVC with `.git` metadata or transient build artifacts.

## Keep cache-aware workflows aligned

When containerized Rust performance or correctness regresses, keep these surfaces aligned:

- `scripts/podman-rust.sh` for local containerized runs
- `scripts/k8s-rust.sh` for long control-plane jobs
- `scripts/install-cargo-llvm-cov.sh` for release-based `cargo-llvm-cov` bootstrap
- `assets/sccache-image/Dockerfile` for the cached `sccache` container image

Do not reintroduce `.git`-backed caches, memory-backed `/tmp` defaults, or repo-specific `.github/skills/...` paths into these helpers. Those are known-bad in this environment.
