---
name: repo-change-delivery
description: "Drive end-to-end repository change delivery across repositories. Use when a user expects the full implementation loop, not just a local patch: investigate with sub-agents, add regression coverage, run the repository's existing validation, perform critical review, commit on a non-main branch, push, update the PR, and wait for CI."
---

# Repo Change Delivery

Execute repository changes through a full delivery loop instead of stopping at a local patch.

## Workflow

1. Capture execution state.
   - Create or update `plan.md` when the task is non-trivial and the environment provides session planning.
   - Keep SQL todos or the closest available task tracker current when the environment supports them.
   - Confirm whether you should branch from `origin/main` or continue on the active feature branch, but never deliver work directly on `main`.

2. Delegate with sub-agents when they help.
   - Use exploration agents to map files, prior art, and constraints.
   - Use implementation or task agents for command-heavy edits and validation loops.
   - Use a critical review agent after local validation.
   - Ask agents to do the work, not only to advise, and batch related questions into one prompt.

3. Implement the requested change and add regression coverage.
   - Modify the repository directly.
   - Add or update focused regression checks near the repository's existing test entry points.
   - Update nearby documentation only when behavior, workflows, or user-visible outputs changed.

4. Run the repository's existing validation.
   - Use the repository's normal lint, build, test, packaging, and deployment checks instead of inventing new ones.
   - If the repository depends on containerized, infrastructure, or cluster-backed verification, run those paths too.
   - When repo-local supplemental skills exist, read them before choosing exact commands.

5. Treat review as a blocking loop.
   - Run a critical review after local validation.
   - Fix every actionable issue, including small but real ones.
   - After fixes, rerun the affected validation and fall back to the full baseline when the blast radius is unclear.

6. Deliver through Git and PR workflow.
   - Prefer a dedicated `git-commit` skill when one is available. Otherwise inspect status and diff carefully, stage only intended files, and commit using the repository's conventions.
   - Keep work on a non-main branch.
   - After each commit, fetch and rebase onto `origin/main` when the requested workflow expects the branch to stay current.
   - Push before creating or updating the PR, and use the available GitHub tooling in the environment.

7. Wait for hosted validation to finish.
   - Monitor CI until the relevant checks complete.
   - Treat failing hosted checks as blocking work: inspect logs, fix the issue, rerun local validation, push again, and wait again.

## Combining with repo-local skills

- If the repository provides a repo-local delivery or validation skill, use it for exact commands, repository-specific CI expectations, and cluster verification paths.
- Keep this bundled skill generic. Move repository-specific commands and file paths into the repo-local supplement.
