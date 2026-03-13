# Contributing

This document is the source of truth for contribution rules.

## 1. Development Flow

1. Create a branch from `main`.
2. Implement changes and add/update tests.
3. Commit using Conventional Commits.

## 2. Branch Rules

- `main`: always releasable.
- Working branches: `feature/<topic>`, `fix/<topic>`, `chore/<topic>`.
- Direct push to `main` is not allowed.

## 3. Commit Message Rules (Conventional Commits)

Format:

`<type>(<scope>): <subject>`

Examples:

- `feat(api): add user profile endpoint`
- `fix(parser): handle empty input`
- `docs(readme): clarify setup steps`
- `chore(ci): update workflow cache key`

Types:

- `feat`: new feature
- `fix`: bug fix
- `docs`: documentation only
- `refactor`: code change without behavior change
- `test`: tests
- `chore`: maintenance/configuration

## 4. Local and Containerized Validation

- `scripts/lint.sh` is the supported lint entry point.
- `scripts/lint.sh` runs `hadolint` and `shellcheck` through their upstream
  container images, and builds the repository's `containers/yamllint/` image to
  run `yamllint` v1.38.0.
- `scripts/build-test.sh` is the supported local build/test entry point.
- `scripts/build-test.sh` auto-detects a working Docker Buildx toolchain first,
  then falls back to a Podman / Buildah toolchain.
- Use `CONTROL_PLANE_TOOLCHAIN=docker` to force Docker / BuildKit, or
  `CONTROL_PLANE_TOOLCHAIN=podman` to force Podman / Buildah.
- Use trusted upstream images when they already satisfy the contract; if only a
  third-party image exists, build a thin repository-managed image and publish it
  to GHCR for reuse.
- `scripts/test-standalone.sh` and `scripts/test-kind.sh` remain the lower-level
  smoke / integration scripts used by `scripts/build-test.sh`.
- When this repository is developed from inside a containerized tooling
  environment, keep these scripts unchanged and provide the required toolchain:
  `docker`, or `podman` (with `buildah` used when available), together with
  `kind`, `kubectl`, `ssh`, and `ssh-keygen`.
