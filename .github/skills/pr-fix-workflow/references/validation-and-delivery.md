# Validation and Delivery Reference

## Contents

- [Local validation baseline](#local-validation-baseline)
- [Kubernetes and current-cluster verification](#kubernetes-and-current-cluster-verification)
- [Skill-specific validation](#skill-specific-validation)
- [CI surfaces](#ci-surfaces)

## Local validation baseline

Run the repository baseline with Podman:

- `CONTROL_PLANE_TOOLCHAIN=podman ./scripts/lint.sh`
- `CONTROL_PLANE_TOOLCHAIN=podman ./scripts/build-test.sh`

Add a focused `scripts/test-*.sh` regression check for the behavior you changed and run it directly during iteration. Wire it into `scripts/build-test.sh` when it is deterministic and worth covering in the standard regression path.

## Kubernetes and current-cluster verification

When the change affects Kubernetes manifests, control-plane runtime behavior, or cluster interactions, verify it against a real cluster path instead of relying only on static inspection.

Preferred pre-deploy check:

- `./scripts/test-k8s-job.sh`

When the current cluster already runs the workspace image you are editing, also use:

- `./scripts/test-current-cluster-regressions.sh`

Use `kubectl get`, `kubectl describe`, and `kubectl logs` for extra inspection when needed. `scripts/build-test.sh` already assumes `kind`, `kubectl`, `ssh`, and `ssh-keygen` are available.

## Skill-specific validation

When the change touches repo-local skills under `.github/skills/` or bundled skills under `containers/control-plane/skills/`, validate every changed skill as part of the delivery loop.

Start with the repository regression script:

- `./scripts/test-repo-change-delivery-skills.sh`

That script:

- validates the repo-local `pr-fix-workflow` skill
- validates the bundled `repo-change-delivery`, `git-commit`, and `pull-request-workflow` skills
- packages each skill through the repository `containers/yamllint` image without depending on host Python
- checks that the control-plane image and runtime tests still expose bundled skills correctly

`CONTROL_PLANE_TOOLCHAIN=podman ./scripts/build-test.sh` also includes the same regression script in the standard baseline.

## CI surfaces

The authoritative hosted validation definition lives in `.github/workflows/control-plane-ci.yml`.

- `pull_request` starts `lint` and `Integration Images` in parallel, then fans out `Integration Smoke`, `Integration Regressions`, `Integration Kind Session`, `Integration Kind Jobs Core`, and `Integration Kind Jobs Transfer`
- `push` to `main` additionally gates `Publish Architecture Images`, `publish-manifests`, and `cleanup-packages` on the lint and integration fan-out results
