# Validation and Delivery Reference

## Contents

- [Local validation baseline](#local-validation-baseline)
- [Current-cluster verification](#current-cluster-verification)
- [Skill-specific validation](#skill-specific-validation)
- [PR and CI loop](#pr-and-ci-loop)

## Local validation baseline

Run the repository baseline with Podman:

- `CONTROL_PLANE_TOOLCHAIN=podman ./scripts/lint.sh`
- `CONTROL_PLANE_TOOLCHAIN=podman ./scripts/build-test.sh`

Add a focused `scripts/test-*.sh` regression check for the behavior you changed and run it directly during iteration. Wire it into `scripts/build-test.sh` when it is deterministic and worth covering in the standard regression path.

## Current-cluster verification

When the change affects Kubernetes manifests, control-plane runtime behavior, or cluster interactions, verify it against a real cluster path instead of relying only on static inspection.

Preferred check:

- `./scripts/test-k8s-job.sh`

Use `kubectl get`, `kubectl describe`, and `kubectl logs` for extra inspection when needed. `scripts/build-test.sh` already assumes `kind`, `kubectl`, `ssh`, and `ssh-keygen` are available.

## Skill-specific validation

When the change touches `.github/skills/`, validate and package the changed skill as part of the delivery loop.

The host may not provide Python directly. Reuse the repository `containers/yamllint` image through the active container toolchain:

```bash
CONTROL_PLANE_TOOLCHAIN=podman ./scripts/lint.sh

SKILL_DIR=/workspace/.github/skills/<skill-name>
TMPDIR="$(mktemp -d)"

podman run --rm --user "$(id -u):$(id -g)" \
  -v /workspace:/workspace \
  -w /workspace/.github/skills/skill-creator/scripts \
  --entrypoint python3 \
  localhost/yamllint:test \
  quick_validate.py "${SKILL_DIR}"

podman run --rm --user "$(id -u):$(id -g)" \
  -v /workspace:/workspace \
  -v "${TMPDIR}:${TMPDIR}" \
  -w /workspace/.github/skills/skill-creator/scripts \
  --entrypoint python3 \
  localhost/yamllint:test \
  package_skill.py "${SKILL_DIR}" "${TMPDIR}"

rm -rf "${TMPDIR}"
```

Use the matching container runtime when the active toolchain is Docker instead of Podman.

## PR and CI loop

Use the `git-commit` skill for each commit cycle. After each commit:

1. `git fetch origin main`
2. `git rebase origin/main`
3. rerun local validation if the rebase introduced changes or conflict resolution
4. push the branch
5. create or update the PR

The authoritative CI definition lives in `.github/workflows/control-plane-ci.yml`.

- `pull_request` runs `lint` and `integration`
- `push` to `main` additionally runs `publish-manifests` and `cleanup-packages`

Wait for the PR checks or workflow run to finish. If any job fails, inspect the failing logs, fix the issue, recommit, rebase, rerun the local validation loop, push again, and wait again.
