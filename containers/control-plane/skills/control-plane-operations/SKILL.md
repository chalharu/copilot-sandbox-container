---
name: control-plane-operations
description: Operate this repository's control-plane environment. Use when working inside the control-plane container or Kubernetes deployment, deciding how to run commands with `control-plane-run`, managing SSH/GNU Screen sessions, or using the built-in control-plane workflow skill across repositories.
---

# Control Plane Operations

## Overview

Use the control plane as the long-lived operator shell for containerized work. Prefer GNU Screen for resumable SSH sessions, route execution with `control-plane-run`, and rely on this bundled skill even when `/workspace` points at a different repository.

Read `references/control-plane-run.md` when you need command-routing guidance. Read `references/skills.md` when you need to update this bundled skill or combine it with repo-specific skills.

## Workflow

1. Confirm whether the task belongs in the current SSH/Screen session or a separate execution plane.
2. Pick the command path:
   - Use plain shell work in the control plane for interactive investigation, editing, or Git work.
   - Use `control-plane-run --mode k8s-job` for explicit execution-plane work that should run as a Kubernetes Job.
   - Short-lived interactive work now stays in the control plane shell or the session-scoped fast-execution pod path; `control-plane-run` no longer routes to local Podman.
3. Keep long-lived or resumable work inside GNU Screen sessions.
4. When the task needs extra repository-specific agent behavior, combine this bundled skill with repo-local skills from the mounted repository.

## Session Management

- Interactive SSH logins enter `control-plane-session --select`, which shows existing GNU Screen sessions, adds a `Copilot` option when no dedicated Copilot session exists, and always offers `New session`.
- Use the default session picker path for normal work. It preserves the "reattach if possible, create if needed" flow without having to remember Screen flags.
- Choose `Copilot` to start `copilot --yolo` from `/workspace` inside its own Screen session.
- Copilot sessions start attached to the current SSH TTY instead of booting detached first, which avoids TUI stalls where the session looks unresponsive right after login.
- Use `control-plane-session --command '<shell command>'` when you need to start a detached session non-interactively.
- Use `CONTROL_PLANE_SESSION_SELECTION=new:<name>` only for scripted or test-only selection overrides.

## Skill Placement

- This skill is sourced from the image at `containers/control-plane/skills/control-plane-operations` and synchronized into `~/.copilot/skills/control-plane-operations` at container start.
- Keep image-wide operational guidance here so it is available even when `/workspace` points at a different repository.
- Use repo-local `.github/skills/` only for repository-specific additions or overrides.
- Package finished changes by installing the manifest-defined external skills with `scripts/install-git-skills-from-manifest.sh containers/control-plane/config/external-skills.yaml <destination-root>`, changing into `<destination-root>/skill-creator`, and running `python3 -m scripts.package_skill <skill-dir>` when you want structure validation.

## Quick Checks

- Confirm `/workspace` points at the expected repository before assuming repo-local skills exist.
- Prefer editing or Git operations in the control plane itself; prefer `control-plane-run` for execution-plane isolation.
- If SSH login behavior looks odd, check whether you are already inside Screen (`$STY`) before debugging the picker.
