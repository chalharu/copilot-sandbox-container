# `control-plane-run` reference

## Decision table

- Use `--mode auto --execution-hint short` for quick commands that should run through the local rootless Podman/Docker wrapper.
- Use `--mode auto --execution-hint long` for commands that should become Kubernetes Jobs.
- Use `--mode podman` when the command must stay local even if it looks long-running.
- Use `--mode k8s-job` when the command must become a Job even if it looks short.
- Use `--mount-file SRC[:DEST]` for small helper files that should appear under `/var/run/control-plane/job-inputs/DEST` in either execution path.

## Common patterns

### Run a short local command

```bash
control-plane-run --mode auto --execution-hint short \
  --workspace /workspace \
  --image ghcr.io/chalharu/copilot-sandbox-container/execution-plane-smoke:replace-me-with-commit-sha \
  -- /usr/local/bin/execution-plane-smoke write-marker /workspace/short.txt short
```

### Run a Kubernetes Job

```bash
control-plane-run --mode auto --execution-hint long \
  --namespace copilot-sandbox-jobs \
  --job-name smoke-job \
  --image ghcr.io/chalharu/copilot-sandbox-container/execution-plane-smoke:replace-me-with-commit-sha \
  -- /usr/local/bin/execution-plane-smoke write-marker /workspace/long.txt long
```

### Run a Kubernetes Job with a small helper file

```bash
control-plane-run --mode k8s-job \
  --namespace copilot-sandbox-jobs \
  --mount-file ./script.sh:scripts/script.sh \
  --image ghcr.io/chalharu/copilot-sandbox-container/execution-plane-smoke:replace-me-with-commit-sha \
  -- /usr/local/bin/execution-plane-smoke exec bash -lc \
     'bash /var/run/control-plane/job-inputs/scripts/script.sh'
```

### Start a detached Screen session first

```bash
control-plane-session --command \
  'control-plane-run --mode auto --execution-hint long --namespace copilot-sandbox-jobs --job-name smoke-job --image ghcr.io/chalharu/copilot-sandbox-container/execution-plane-smoke:replace-me-with-commit-sha -- /usr/local/bin/execution-plane-smoke write-marker /workspace/long.txt long'
```

## Notes

- The sample least-privilege Kubernetes deployment exports `CONTROL_PLANE_RUN_MODE=k8s-job`, so plain `control-plane-run ...` defaults to the Job path unless you override it.
- The sample deployment also sets `CONTROL_PLANE_JOB_NAMESPACE=copilot-sandbox-jobs`, so `--namespace` defaults to the Job namespace rather than the Control Plane namespace.
- Pass `--workspace /workspace` when the local execution path must mount the repository workspace.
- `--mount-file` is for small files only. Large workspaces still need a shared PVC or another artifact handoff path.
- Keep Kubernetes-specific flags (`--namespace`, `--job-name`) ready even in `auto` mode when the command may route to a Job.
- Prefer explicit image references. Use commit SHA tags for reproducible automation.
