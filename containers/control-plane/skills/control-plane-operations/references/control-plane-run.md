# `control-plane-run` reference

## Decision table

- Use `--mode auto --execution-hint short` for quick commands that should run through the local rootless Podman/Docker wrapper.
- Use `--mode auto --execution-hint long` for commands that should become Kubernetes Jobs.
- Use `--mode podman` when the command must stay local even if it looks long-running.
- Use `--mode k8s-job` when the command must become a Job even if it looks short.

## Common patterns

### Run a short local command

```bash
control-plane-run --mode auto --execution-hint short \
  --workspace /workspace \
  --image ghcr.io/chalharu/copilot-sandbox-container/execution-plane-smoke:latest \
  -- /usr/local/bin/execution-plane-smoke write-marker /workspace/short.txt short
```

### Run a Kubernetes Job

```bash
control-plane-run --mode auto --execution-hint long \
  --namespace copilot-sandbox \
  --job-name smoke-job \
  --image ghcr.io/chalharu/copilot-sandbox-container/execution-plane-smoke:latest \
  -- /usr/local/bin/execution-plane-smoke write-marker /workspace/long.txt long
```

### Start a detached Screen session first

```bash
control-plane-session --command \
  'control-plane-run --mode auto --execution-hint long --namespace copilot-sandbox --job-name smoke-job --image ghcr.io/chalharu/copilot-sandbox-container/execution-plane-smoke:latest -- /usr/local/bin/execution-plane-smoke write-marker /workspace/long.txt long'
```

## Notes

- Pass `--workspace /workspace` when the local execution path must mount the repository workspace.
- Keep Kubernetes-specific flags (`--namespace`, `--job-name`) ready even in `auto` mode when the command may route to a Job.
- Prefer explicit image references. Use commit SHA tags for reproducible automation.
