# Validation and Delivery Reference

## Contents

- [Local validation baseline](#local-validation-baseline)
- [Kubernetes and current-cluster verification](#kubernetes-and-current-cluster-verification)
- [Skill-specific validation](#skill-specific-validation)
- [CI surfaces](#ci-surfaces)

## Local validation baseline

Run the repository-managed baseline with Docker:

- `./scripts/build-test.sh`

When the Docker daemon is unavailable but the current cluster allows pod/service
creation in the job namespace, `./scripts/build-test.sh --build-only` can fall
back to an ephemeral Kubernetes Buildkitd. Use
`CONTROL_PLANE_TOOLCHAIN=buildkitd` when you need to force that path.

Hosted lint is provided by the external `linter-service`, including the Renovate
dry-run coverage that used to live in `lint.sh`.

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
- packages each skill through the bundled control-plane image without depending on host Python
- checks that the control-plane image and runtime tests still expose bundled skills correctly

`./scripts/build-test.sh` also includes the same regression script in the standard baseline.

## CI surfaces

The authoritative hosted validation definition lives in `.github/workflows/control-plane-ci.yml`.

- `pull_request` relies on the external `linter-service`; when a change only touches non-runtime Markdown files, the workflow exits after the lightweight change-detection job, otherwise it builds integration images for both x64 and aarch64 and then fans out dual-arch `Integration Smoke` plus x64-only `Integration Regressions`, `Integration Kind Session`, `Integration Kind Jobs Core`, and `Integration Kind Jobs Transfer`
- `push` to `main` uses the same change-detection gate; when build-relevant files changed it additionally gates `Publish Architecture Images`, `publish-manifests`, and `cleanup-packages` on the integration fan-out results
