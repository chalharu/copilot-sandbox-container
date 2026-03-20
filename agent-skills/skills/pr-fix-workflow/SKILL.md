---
name: pr-fix-workflow
description: "Drive end-to-end repository change delivery for this repo. Use when a user wants code or documentation changes here and expects the full loop: investigate and implement with sub-agents, add or update a test script, run podman and kubectl validation, perform critical review, commit on a non-main branch, rebase onto origin/main, push, create or update a PR, and wait for GitHub Actions."
---

# PR Fix Workflow

Execute repository changes through a full delivery loop instead of stopping at a local patch.

## Workflow

1. Capture execution state.
   - Create or update `plan.md` for non-trivial work.
   - Reflect execution in SQL todos so progress and dependencies stay explicit.
   - Confirm you are not working on `main`. Branch from the latest `origin/main` before making the change.

2. Delegate with sub-agents.
   - Use `explore` to map relevant files, prior art, and repo-specific constraints.
   - Use `general-purpose` or `task` agents for implementation or command-heavy validation work.
   - Use `code-review` for a critical review after local validation.
   - Ask agents to do the work, not just provide advice, and batch related questions into one prompt.

3. Implement the requested change and add regression coverage.
   - Modify the repository directly.
   - Add or update a focused `scripts/test-*.sh` check for the behavior you changed.
   - Wire that script into `scripts/build-test.sh` when it is cheap, deterministic, and worth running in the standard regression path.
   - Update nearby docs only when operator behavior or repository workflow changed.

4. Run local validation.
   - Read `references/validation-and-delivery.md` before running repo validation.
   - Always run lint and build/test with `CONTROL_PLANE_TOOLCHAIN=podman`.
   - Run targeted `kubectl` verification when the change affects Kubernetes manifests, control-plane runtime, or cluster behavior.
   - Run skill validation and packaging too when the change touches `.github/skills/`.

5. Treat review as a blocking loop.
   - Run a critical `code-review` agent after local validation.
   - Fix every actionable finding, including small ones.
   - After fixes, return to the commit step and repeat validation from lint onward unless you can prove a narrower rerun is sufficient for the user request.

6. Deliver through Git and PR workflow.
   - Invoke the `git-commit` skill for each commit cycle instead of restating commit rules here.
   - Commit only on a non-main branch.
   - After each commit, `git fetch origin main` and `git rebase origin/main`.
   - Resolve rebase fallout carefully, rerun validation, then push.
   - Create or update the PR with GitHub tooling after the branch is pushed.

7. Wait for hosted validation to finish.
   - Monitor GitHub Actions until completion.
   - Treat failing checks as blocking work, inspect the logs, fix the issue, recommit, rebase, rerun local validation, push again, and wait again.

## Repository anchors

- Read `references/validation-and-delivery.md` for the exact repo commands, CI behavior, and current-cluster verification path.
- Reuse the `git-commit` skill for commit message generation and staging workflow.
