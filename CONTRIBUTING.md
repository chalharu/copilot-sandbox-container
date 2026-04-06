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
  container images, validates `renovate.json5` with `ghcr.io/biomejs/biome`,
  runs a local Renovate dry-run for scope validation, and uses the bundled
  control-plane image to run `yamllint` v1.38.0.
- `scripts/build-test.sh` is the supported local build/test entry point.
- `scripts/build-test.sh` expects a working Docker Buildx toolchain.
- Use `CONTROL_PLANE_TOOLCHAIN=docker` to force Docker / BuildKit explicitly.
- Use trusted upstream images when they already satisfy the contract; if only a
  third-party image exists, build a thin repository-managed image and publish it
  to GHCR for reuse.
- GitHub Actions needs `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` for the DHI
  registry access used by the Renovate dry-run validation.
- `scripts/test-standalone.sh` and `scripts/test-kind.sh` remain the lower-level
  smoke / integration scripts used by `scripts/build-test.sh`.
- When this repository is developed from inside a containerized tooling
  environment, keep these scripts unchanged and provide the required toolchain:
  `docker`, together with `kind`, `kubectl`, `ssh`, and `ssh-keygen`.
- When behavior or operator guidance changes, keep `README.md`,
  `docs/README.md`, `docs/how-to-guides/cookbook.md`,
  `docs/explanation/knowledge.md`, `docs/reference/control-plane-runtime.md`,
  and `docs/reference/debug-log.md` aligned in the same PR.
