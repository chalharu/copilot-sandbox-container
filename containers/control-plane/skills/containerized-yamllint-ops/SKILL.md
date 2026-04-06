---
name: containerized-yamllint-ops
description: Run this repository's YAML lint checks through the bundled control-plane `yamllint` installation instead of reconstructing commands by hand. Use when checking changed `.yml` or `.yaml` files locally, rerunning hook failures, or validating YAML edits with the same config this repository ships.
---

# Containerized Yamllint Ops

Use the bundled helper instead of reconstructing the `yamllint` command by hand.

## Run local validation

- `bash ~/.copilot/skills/containerized-yamllint-ops/scripts/podman-yamllint.sh`
- `bash ~/.copilot/skills/containerized-yamllint-ops/scripts/podman-yamllint.sh .github/workflows/control-plane-ci.yml`
- `bash ~/.copilot/skills/containerized-yamllint-ops/scripts/podman-yamllint.sh deploy/kubernetes/control-plane.example`
- When editing this repository itself, the source-path equivalent is `bash containers/control-plane/skills/containerized-yamllint-ops/scripts/podman-yamllint.sh`.
