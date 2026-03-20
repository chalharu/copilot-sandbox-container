---
name: pull-request-workflow
description: Create or update pull requests safely. Use when work must be pushed, matched to the correct branch PR, updated without duplicates, and followed through hosted checks.
---

# Pull Request Workflow

Handle pull requests with a strict and repeatable workflow.

## Core rules

- Never open a duplicate pull request for the same head branch.
- Never create or update a pull request from `main`; work must live on a feature branch.
- Push local commits before creating or refreshing the PR.
- Prefer non-interactive GitHub operations with explicit base, head, title, and body inputs.

## Workflow

1. Inspect git and branch state.
2. Discover PR state for the current head branch.
3. Sync the branch and push it.
4. Create or update the pull request.
5. Verify metadata and monitor hosted checks.

## 1) Inspect git and branch state

Run:

- `git status --short`
- `git branch --show-current`
- `git remote -v`

If the branch is `main`, detached `HEAD`, or otherwise unsuitable for review work, stop and fix that first.

## 2) Discover PR state for the current head branch

Use the environment's GitHub tooling to find open pull requests whose head matches the current branch.

- If an open PR already exists for the branch, update that PR instead of creating a new one.
- If no PR exists, prepare to create one.
- If multiple matching PRs exist, stop and surface the ambiguity instead of guessing.

## 3) Sync the branch and push it

Before creating or updating the PR:

- confirm local commits are present
- make sure staged vs unstaged state is intentional
- push the branch to the remote

When the repository workflow expects the branch to stay current, rebase or otherwise sync it with the target base branch before pushing.

## 4) Create or update the pull request

When creating a PR:

- set the base branch explicitly
- set the head branch explicitly
- write the title and body from the actual changes
- link issues only when they are genuinely related

When updating an existing PR:

- refresh the title or body when scope changed
- preserve useful discussion context
- add a follow-up comment only when that helps reviewers understand new work

Prefer GitHub MCP tools or other explicit API-style operations over interactive prompts when the environment supports them.

## 5) Verify metadata and monitor hosted checks

After the PR is created or updated, read back and report:

1. PR number and URL
2. title
3. base and head branches
4. current check or review status

Then monitor hosted validation until the relevant checks complete.

If checks fail:

1. inspect the failing job logs
2. fix the issue locally
3. rerun the affected local validation
4. push the follow-up commit
5. monitor the PR checks again
