---
name: pr-fix-workflow
description: Repository-specific delivery supplement for the copilot-sandbox-container repository. Use with a generic repo-change-delivery workflow when working here and you need the exact Docker, kubectl, skill-packaging, and GitHub Actions commands for this repository.
---

# PR Fix Workflow

Use this repo-local skill as the repository-specific companion to the bundled `repo-change-delivery` skill.

## Repository workflow anchors

1. Read `references/validation-and-delivery.md` before choosing commands.
2. Keep repository-specific validation here:
   - baseline lint and build/test commands
   - Kubernetes and current-cluster verification paths
   - skill validation for both repo-local and bundled skills
   - authoritative CI workflow names and job expectations
3. Let the generic `repo-change-delivery` skill handle the reusable delivery loop:
   - planning and progress tracking
   - sub-agent delegation
   - regression coverage expectations
   - critical review and revalidation
   - commit, rebase, push, PR, and wait-for-CI flow

## Repository anchors

- Use `./scripts/lint.sh` and `./scripts/build-test.sh` for the standard validation baseline in this repository.
- When the change touches `.github/skills/` or `containers/control-plane/skills/`, validate every changed skill and the control-plane runtime surfaces that expose bundled skills.
- Use `./scripts/test-k8s-job.sh` or the current-cluster checks when runtime or Kubernetes behavior changes.
- Read `references/validation-and-delivery.md` for the exact commands and CI surfaces in this repository.
