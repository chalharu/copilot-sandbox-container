---
name: git-commit
description: Execute Git commits end-to-end. Use when the user asks to commit changes, requests a commit message, or wants commit support from current diffs. Inspect git diff/status, understand changed files in detail, generate a Conventional Commit message based on CONTRIBUTING.md, then stage and run commit.
---

# Git Commit

Execute commits with a strict and repeatable workflow.

## Host Execution Rule

All Git commands run directly on the host environment, not inside Docker.
Docker is used only for build, test, lint, and coverage commands.

## Workflow

1. Check repository state.
2. Extract current changes with git diff.
3. Understand each changed file in detail.
4. Generate commit message from CONTRIBUTING.md rules.
5. Stage intended files.
6. Run commit.
7. Verify result.

If GitHub operations are needed alongside commit work (PR/issue/comment/search), use GitHub MCP tools (`mcp_io_github_*`) and do not use `gh` CLI.

Do not skip change understanding before message generation.

## 1) Check Repository State

Run:

- `git status --short`
- `git branch --show-current`

If there are no changes, report that commit is unnecessary and stop.

## 2) Extract Current Changes

Run both staged and unstaged inspections:

- `git diff --stat`
- `git diff`
- `git diff --cached --stat`
- `git diff --cached`

Summarize:

- changed files
- major behavioral/config/doc/test changes
- staged vs unstaged status

## 3) Understand Changes in Detail

For each changed file, identify:

- what changed
- why it changed
- impact (user-facing/internal)

If unrelated changes are mixed, propose split commits.
If suspicious or unintended changes exist, ask user before commit.

## 4) Generate Commit Message from CONTRIBUTING.md

Read `CONTRIBUTING.md` and follow Conventional Commits format exactly:

`<type>(<scope>): <subject>`

Use only:

- `feat`
- `fix`
- `docs`
- `refactor`
- `test`
- `chore`

Rules:

- choose type from primary intent
- choose scope from dominant module/directory
- keep subject concise and specific
- prefer multiple commits over one mixed message

## 5) Stage Intended Files

Prefer explicit staging:

- `git add <path1> <path2> ...`

Then verify staged content:

- `git diff --cached --stat`

## 6) Run Commit

Run:

- `git commit -m "<type>(<scope>): <subject>"`

If commit fails, inspect error, resolve only relevant issue, retry.

## 7) Verify and Report

Run:

- `git log -1 --oneline`
- `git status --short`

Report:

1. created commit hash and subject
2. included files count/summary
3. key changes overview
4. working tree clean/dirty
