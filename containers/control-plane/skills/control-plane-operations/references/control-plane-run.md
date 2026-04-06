# `control-plane-run` reference

## Decision table

- Use `--mode k8s-job` for commands that should run in an execution-plane Kubernetes Job.
- Use `--mount-file SRC[:DEST]` for helper files that should appear under `/var/run/control-plane/job-inputs/DEST` in either execution path.

## Common patterns

### Run a Kubernetes Job

```bash
control-plane-run --mode k8s-job \
  --namespace copilot-sandbox-jobs \
  --job-name smoke-job \
  --image ghcr.io/chalharu/copilot-sandbox-container/execution-plane-smoke:replace-me-with-commit-sha \
  -- /usr/local/bin/execution-plane-smoke write-marker /workspace/long.txt long
```

### Run a Kubernetes Job with a helper file

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
  'control-plane-run --mode k8s-job --namespace copilot-sandbox-jobs --job-name smoke-job --image ghcr.io/chalharu/copilot-sandbox-container/execution-plane-smoke:replace-me-with-commit-sha -- /usr/local/bin/execution-plane-smoke write-marker /workspace/long.txt long'
```

## Notes

- `control-plane-run` is now Kubernetes-Job-only; use the control plane shell itself or the session-scoped fast-execution pod path for short local work.
- The sample deployment also sets `CONTROL_PLANE_JOB_NAMESPACE=copilot-sandbox-jobs`, so `--namespace` defaults to the Job namespace rather than the Control Plane namespace.
- In the Kubernetes Job path, `--mount-file` stages files over SSH/SFTP via `rclone` and writes back modified files when the Job completes.
- Write-back is conflict-safe: if the source changed outside the Job while the Job was running, the control plane keeps the conflicting output in the transfer staging area instead of overwriting the source file.
- Prefer explicit image references. Use commit SHA tags for reproducible automation.
