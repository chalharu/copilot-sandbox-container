# Built-in skill reference

## Discovery model

- The control-plane image seeds every bundled skill from `containers/control-plane/skills/` into `~/.copilot/skills/` at container start.
- Because the target directory lives under the writable Copilot home, the skill stays visible even when `/workspace` points at a different repository.
- Repository-specific skills can still live under `.github/skills/` in the mounted repository.

## Bundled skill catalog

- `containerized-yamllint-ops`: reusable YAML lint helper that runs through the bundled control-plane `yamllint`
- `control-plane-operations`: control-plane runtime, SSH, and Kubernetes Job execution guidance
- `containerized-rust-ops`: reusable Rust validation helpers that keep large temp files and caches off `/tmp` and out of `.git`
- `audit-log-analysis`: audit-log anomaly review and automation-candidate triage backed by a persistent SQLite analysis DB
- `doc-coauthoring`: bundled from the external skill manifest in `containers/control-plane/config/external-skills.yaml`
- `repo-change-delivery`: generic end-to-end repository delivery loop
- `git-commit`: generic commit workflow with repository-convention message generation
- `pull-request-workflow`: generic pull request creation, update, and hosted-check handling workflow
- `skill-creator`: bundled from the external skill manifest in `containers/control-plane/config/external-skills.yaml`

## Update a bundled skill

1. Edit `containers/control-plane/skills/<skill-name>/` when the bundled skill is maintained in this repository.
2. For manifest-defined external skills such as `doc-coauthoring` and `skill-creator`, update `containers/control-plane/config/external-skills.yaml` instead of editing a checked-in skill copy.
3. Keep `SKILL.md` concise and move detailed material into `references/` when needed.
4. Ensure `containers/control-plane/Dockerfile` still copies `containers/control-plane/skills/` into `/usr/local/share/control-plane/skills/` and overlays the manifest-defined external skills into the same directory.
5. Ensure `containers/control-plane/bin/control-plane-entrypoint` still syncs each bundled skill directory into `~/.copilot/skills/`.
6. Validate structure with:

   ```bash
   workdir="$(mktemp -d)"
   scripts/install-git-skills-from-manifest.sh containers/control-plane/config/external-skills.yaml "${workdir}/external-skills"
   (
     cd "${workdir}/external-skills/skill-creator"
     python3 -m scripts.package_skill containers/control-plane/skills/<skill-name>
   )
   ```

## Combine with repo-local skills

- Put repo-specific skills in the repository's `.github/skills/` directory.
- Keep image-wide reusable workflows in bundled skills and keep repository-specific conventions in repo-local skills.
- Prefer repo-local overrides only when behavior truly depends on the mounted repository.
