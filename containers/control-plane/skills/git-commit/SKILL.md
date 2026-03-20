---
name: git-commit
description: Execute Git commits end-to-end. Use when the user asks to commit changes, requests a commit message, or wants commit support from current diffs. Inspect git diff and status, understand the changed files, generate a Conventional Commit message from repository conventions, stage only intended files, and run the commit.
---

# Git Commit

Execute commits with a strict and repeatable workflow.

## Host execution rule

All Git commands run directly on the host environment, not inside Docker.
Docker or container tools are only for build, test, lint, and coverage commands.

## Workflow

1. Check repository state.
2. Extract current changes with git diff.
3. Understand each changed file in detail.
4. Generate the commit message from repository conventions.
5. Stage only the intended files.
6. Run the commit.
7. Verify the result.

If GitHub work is needed alongside commit work, use the environment's GitHub tooling and prefer MCP integrations when they are available.

Do not skip change understanding before message generation.

## 1) Check repository state

Run:

- `git status --short`
- `git branch --show-current`

If there are no changes, report that a commit is unnecessary and stop.

## 2) Extract current changes

Run both staged and unstaged inspections:

- `git diff --stat`
- `git diff`
- `git diff --cached --stat`
- `git diff --cached`

Summarize:

- changed files
- major behavioral, config, doc, and test changes
- staged vs unstaged status

## 3) Understand changes in detail

For each changed file, identify:

- what changed
- why it changed
- impact (user-facing or internal)

If unrelated changes are mixed together, propose split commits.
If suspicious or unintended changes exist, ask before committing.

## 4) Generate the commit message from repository conventions

Read `CONTRIBUTING.md` when it exists and follow the repository's Conventional Commits rules exactly:

`<type>(<scope>): <subject>`

Use only:

- `feat`
- `fix`
- `docs`
- `refactor`
- `test`
- `chore`

Rules:

- choose the type from the primary intent
- choose the scope from the dominant module or directory
- keep the subject concise and specific
- prefer multiple commits over one mixed message

## 5) Stage only the intended files

Prefer explicit staging:

- `git add <path1> <path2> ...`

Then verify staged content:

- `git diff --cached --stat`

## 6) Run the commit

Run:

- `git commit -m "<type>(<scope>): <subject>"`

If commit fails, inspect the error, resolve only the relevant issue, and retry.

## 7) Verify and report

Run:

- `git log -1 --oneline`
- `git status --short`

Report:

1. created commit hash and subject
2. included files count or summary
3. key changes overview
4. whether the working tree is clean or still dirty
