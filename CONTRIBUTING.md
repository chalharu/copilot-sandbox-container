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

- `scripts/test-standalone.sh` and `scripts/test-kind.sh` are the supported local
  validation entry points.
- Use `CONTROL_PLANE_CONTAINER_BIN=docker` for Docker / BuildKit, or
  `CONTROL_PLANE_CONTAINER_BIN=podman` for Podman / Buildah.
- `scripts/test-kind.sh` also honors `KIND_EXPERIMENTAL_PROVIDER`, so Docker and
  Podman based Kind workflows can share the same script.
- When this repository is developed from inside a containerized tooling
  environment, keep these scripts unchanged and provide the required container
  runtime, `kind`, `kubectl`, `ssh`, and `ssh-keygen` in that environment.
