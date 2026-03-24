---
name: audit-log-analysis
description: Analyze the control-plane audit log and the accumulated audit-analysis DB when wrapping up a task, after repeated retries or errors, or during periodic operations reviews. Use this skill whenever the user asks about audit logs, anomalous patterns, repeated processing, troubleshooting trends, or whether recurring work should become an Agent, Command, or Skill, even if they do not explicitly mention automation design.
---

# Audit Log Analysis

Use the bundled helper to refresh and read the persistent audit-analysis database before you reason about patterns.

## Runtime files

Prefer the bundled helper script over raw SQL first.

- Bundled runtime helper: `~/.copilot/skills/audit-log-analysis/scripts/audit-analysis.mjs`
- Repository source helper: `containers/control-plane/skills/audit-log-analysis/scripts/audit-analysis.mjs`
- Raw audit log DB: `~/.copilot/session-state/audit/audit-log.db`
- Analysis DB: `~/.copilot/session-state/audit/audit-analysis.db`
- Optional config overlay: `~/.copilot/config.json`

The helper merges defaults with `controlPlane.auditAnalysis` from `~/.copilot/config.json`. `CONTROL_PLANE_AUDIT_ANALYSIS_*` env vars override the file when they are set. If no target repository is configured, treat the current repository as the default target.

## Default workflow

1. Refresh and inspect the stored analysis first.
2. Scope the findings into these buckets:
   - user feedback or user corrections
   - error-resolution patterns
   - repeated processing
3. Summarize whether the evidence is only observational, worth considering, or strong enough to create automation.
4. Decide the best artifact type:
   - `Command`: one stable repeated command or short tool sequence
   - `Skill`: a reusable workflow or troubleshooting playbook with multiple steps
   - `Agent`: a recurring investigation that spans multiple tools or requires adaptive judgment
5. If creation is justified, use `repo-change-delivery` and any repo-local validation skill before editing the target repository.

## Commands to run

Refresh and print JSON status:

```bash
node ~/.copilot/skills/audit-log-analysis/scripts/audit-analysis.mjs status --json
```

If you only need to update the DB without printing a report:

```bash
node ~/.copilot/skills/audit-log-analysis/scripts/audit-analysis.mjs refresh --quiet
```

## Interpreting readiness

- `consider`: there is recurring evidence, but the pattern still needs human judgment
- `create`: the evidence is strong enough that you should prepare or directly implement an Agent, Command, or Skill in the configured target repository

When `create` appears for a `skill` candidate, treat that as permission to move into repository delivery work. Keep the repository choice aligned with `controlPlane.auditAnalysis.targetRepository.url` or its env override when present. If that setting is missing, operate on the current repository.

## Report structure

Use this structure in your response:

```markdown
## Audit analysis review
- Scope: ...
- Stored findings: ...
- Candidate artifacts: ...
- Recommendation: ...
- Next action: ...
```

If no candidate has `create`, say so plainly and keep the recommendation focused on continuing observation.
