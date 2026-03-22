---
name: containerized-yamllint-ops
description: Run this repository's YAML lint checks through the pinned `containers/yamllint` image instead of relying on host Python or a manually remembered `podman run` command. Use when checking changed `.yml` or `.yaml` files locally, rerunning hook failures, or validating YAML edits with the same image this repository ships.
---

# Containerized Yamllint Ops

Use the bundled helper instead of reconstructing the container command by hand.

Run from the repository root:

- `bash .github/skills/containerized-yamllint-ops/scripts/podman-yamllint.sh`
- `bash .github/skills/containerized-yamllint-ops/scripts/podman-yamllint.sh .github/workflows/control-plane-ci.yml`
- `bash .github/skills/containerized-yamllint-ops/scripts/podman-yamllint.sh deploy/kubernetes/control-plane.example.yaml`

The helper reuses `localhost/yamllint:test` when the `containers/yamllint/` build context is unchanged, so repeated runs do not rebuild the image unnecessarily.
