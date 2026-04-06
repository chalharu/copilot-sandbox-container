# Agent Guidelines

<!-- Do not restructure or delete sections. Update individual values in-place when they change. -->

## Core Principles

- **Do NOT maintain backward compatibility** unless explicitly requested. Break things boldly.
- **Keep this file under 20-30 lines of instructions.** Every line competes for the agent's limited context budget (~150-200 total).

---

## Project Overview

<!-- Update this section as the project takes shape -->

**Project type:** Container image and shell-script repository for a Copilot Control Plane and reference Execution Planes
**Primary language:** Bash with Dockerfiles and Kubernetes manifests
**Key dependencies:** Docker Buildx, kubectl, Kind, gh, GNU Screen

---

## Commands

<!-- Update these as your workflow evolves - commands change frequently -->

```bash
# Development
# No dev server. Edit the container images and shell scripts directly.

# Testing
./scripts/lint.sh
./scripts/build-test.sh

# Build
CONTROL_PLANE_TOOLCHAIN=docker ./scripts/build-test.sh
```

---

## Code Conventions

<!-- Keep this minimal - let tools like linters handle formatting -->

- Follow the existing patterns in the codebase
- Prefer explicit over clever
- Delete dead code immediately

---

## Architecture

<!-- Major architecture changes MUST trigger a rewrite of this section -->

```text
/containers/control-plane         Control Plane image, entrypoints, bundled skills, fast-exec helpers
/containers/execution-plane-smoke Smoke-test Execution Plane image
/deploy/kubernetes                Sample deployment manifests
/scripts                          Supported lint/build/test entry points
```

---

## Maintenance Notes

<!-- This section is permanent. Do not delete. -->

**Keep this file lean and current:**

1. **Remove placeholder sections** (sections still containing `[To be determined]` or `[Add your ... here]`) once you fill them in
2. **Review regularly** - stale instructions poison the agent's context
3. **CRITICAL: Keep total under 20-30 lines** - move detailed docs to separate files and reference them
4. **Update commands immediately** when workflows change
5. **Rewrite Architecture section** when major architectural changes occur
6. **Delete anything the agent can infer** from your code

**Remember:** Coding agents learn from your actual code. Only document what's truly non-obvious or critically important.
