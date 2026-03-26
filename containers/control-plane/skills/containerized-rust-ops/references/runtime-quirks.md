# Runtime quirks

## Local Podman workflow

- Mount the repository root with an absolute host path. Relative binds can resolve to the wrong worktree in this control-plane environment.
- In this control-plane environment, `CONTAINER_HOST` or `DOCKER_HOST` can point at a stale rootful Podman socket. Use local Podman by clearing both variables for repo-local runs.
- For local rootless Podman here, do not force `--user 1000:1000`; container root already maps back to the host user and explicit IDs break writes into bind-mounted cache paths.
- Use `sh -c` inside `docker.io/rust:1.94.0-bookworm`. `bash -lc` in that image drops the Rust toolchain from `PATH`.
- Keep local toolchain state and temp files under `${CONTROL_PLANE_TMP_ROOT:-/var/tmp/control-plane}/tmp-<uid>` unless the caller explicitly overrides `CONTAINERIZED_RUST_*`, keep `sccache` in its own sibling cache directory, and keep `target` ephemeral instead of writing large caches into `.git` or `~/.copilot/session-state`.
- The local helper builds or reuses the shared `containers/sccache/` image context and refreshes the copied `/usr/local/bin/sccache` in the shared cargo cache only when that image context changes, so repeated runs do not re-bootstrap `sccache` from source.

## Control-plane Kubernetes workflow

- `control-plane-run --workspace <host-path>` does not mount the requested host worktree into Kubernetes jobs in this environment.
- `CONTROL_PLANE_JOB_NAMESPACE` lacks the PVC-backed `/workspace` mount that long-running jobs need.
- `CONTROL_PLANE_K8S_NAMESPACE` does expose the `/workspace` PVC, but the default runtime env points to a missing `control-plane-job` service account there. Clear `CONTROL_PLANE_JOB_SERVICE_ACCOUNT` before starting the job.
- Clone the pushed branch into `/var/tmp/containerized-rust/<repo>/<branch>/src` so `.git`, temp files, and `target` stay ephemeral. Unpushed local changes are not visible to the job.
- Keep reusable `cargo` and `rustup` caches in `/workspace/cache/<repo>/<branch>`, but keep the clone, temp files, `target`, and `sccache` under `/var/tmp/containerized-rust/<repo>/<branch>`.
- When `SCCACHE_BUCKET`, `SCCACHE_ENDPOINT`, and S3 credentials are available, keep only ephemeral client state under `/var/tmp/containerized-rust/<repo>/<branch>/sccache` and send reusable cache objects through the in-cluster Garage S3 Service. Without object-store mode, keep the same ephemeral `sccache` path and cap it with `SCCACHE_CACHE_SIZE`.
- The local helper still reuses `containers/sccache/` for the `sccache` client binary, while the sample manifest runs Garage from the official `dxflrs/garage:v2.2.0` image and renders `garage.toml` in an initContainer.
- The sample bootstrap logic now lives in `containers/control-plane/bin/garage-bootstrap.mjs` and runs from the existing published `control-plane` image in a one-shot bootstrap Job instead of a sidecar on every Garage pod start.
- That Job waits for the Garage admin/S3 endpoints, assigns the single-node layout, imports the cache key, upserts the bucket quota, and applies the S3 lifecycle rule.
- The sample Garage deployment keeps the shared cache bucket on the dedicated RWO PVC, applies a 4 GiB bucket quota, and relies on S3 lifecycle expiration to trim stale cache objects automatically.
- `k8s-rust.sh` injects its local installer scripts into the job so bootstrap changes can be validated before push, but the Rust source build/test still runs against the pushed branch clone.
- The default `control-plane-run` job limit is `2Gi` memory here. First-time `cargo install --locked sccache` can be OOM-killed unless it is serialized with `CARGO_BUILD_JOBS=1` (or `SCCACHE_BOOTSTRAP_JOBS=1` when using `k8s-rust.sh`).
- The helper scripts prefer prebuilt `sccache` release tarballs from `https://github.com/mozilla/sccache/releases/`. `SCCACHE_VERSION` and `SCCACHE_RELEASE_BASE_URL` can override the download source, and unsupported architectures still fall back to serialized `cargo install --locked sccache`.
- For `cargo llvm-cov`, do not use `cargo install`. Use `install-cargo-llvm-cov.sh`, which downloads the prebuilt binary from `https://github.com/taiki-e/cargo-llvm-cov/releases/`. `CARGO_LLVM_COV_VERSION`, `CARGO_LLVM_COV_RELEASE_BASE_URL`, and `CARGO_LLVM_COV_ARCHIVE_URL` can override the source, but non-default archives or versions must also set `CARGO_LLVM_COV_ARCHIVE_SHA256`.

## Cache layout

- Local Podman caches:
  - `${CONTAINERIZED_RUST_TMP_ROOT:-${CONTROL_PLANE_TMP_ROOT:-/var/tmp/control-plane}/tmp-<uid>}/containerized-rust/<repo>/toolchain/rustup`
  - `${CONTAINERIZED_RUST_TMP_ROOT:-${CONTROL_PLANE_TMP_ROOT:-/var/tmp/control-plane}/tmp-<uid>}/containerized-rust/<repo>/toolchain/cargo`
  - `${CONTAINERIZED_RUST_TMP_ROOT:-${CONTROL_PLANE_TMP_ROOT:-/var/tmp/control-plane}/tmp-<uid>}/containerized-rust/<repo>/target`
  - `${CONTROL_PLANE_TMP_ROOT:-/var/tmp/control-plane}/sccache/<repo>`
- Kubernetes job caches:
  - `/workspace/cache/<repo>/<branch>/rustup`
  - `/workspace/cache/<repo>/<branch>/cargo`
  - `/var/tmp/containerized-rust/<repo>/<branch>/sccache` (local fallback and S3 client state)
  - `/var/tmp/containerized-rust/<repo>/<branch>/target`
- The standalone Garage Deployment keeps the shared cache bucket under `/var/lib/garage` on the dedicated RWO PVC and mounts `/etc/garage/garage.toml` from the init-generated config volume, while the one-shot bootstrap Job talks to the `garage-s3` Service on both the S3 and admin ports.
- Set `RUSTC_WRAPPER=sccache`, `CARGO_TARGET_DIR` to the ephemeral target directory, and `CARGO_INCREMENTAL=0` so repeated runs favor reusable cache hits over per-run incremental artifacts.
- When invoking `cargo llvm-cov`, also ensure the toolchain has `llvm-tools-preview` installed before running coverage.

## Choose the right path

- Prefer Podman for current-worktree formatting, linting, checking, and debugging.
- Prefer control-plane Kubernetes jobs for long-running `cargo build` and `cargo test` commands after the branch has been pushed.
