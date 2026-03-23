# Built-in skill reference

## Discovery model

- The control-plane image seeds every bundled skill from `containers/control-plane/skills/` into `~/.copilot/skills/` at container start.
- Because the target directory lives under the writable Copilot home, the skill stays visible even when `/workspace` points at a different repository.
- Repository-specific skills can still live under `.github/skills/` in the mounted repository.

## Bundled skill catalog

- `containerized-yamllint-ops`: reusable YAML lint helper that runs through the pinned `containers/yamllint` image
- `control-plane-operations`: control-plane runtime, Podman, SSH, and Kubernetes Job execution guidance
- `containerized-rust-ops`: reusable Rust validation helpers that keep large temp files and caches off `/tmp` and out of `.git`
- `repo-change-delivery`: generic end-to-end repository delivery loop
- `git-commit`: generic commit workflow with repository-convention message generation
- `pull-request-workflow`: generic pull request creation, update, and hosted-check handling workflow

## Update a bundled skill

1. Edit `containers/control-plane/skills/<skill-name>/`.
2. Keep `SKILL.md` concise and move detailed material into `references/` when needed.
3. Ensure `containers/control-plane/Dockerfile` still copies `containers/control-plane/skills/` into `/usr/local/share/control-plane/skills/`.
4. Ensure `containers/control-plane/bin/control-plane-entrypoint` still syncs each bundled skill directory into `~/.copilot/skills/`.
5. Validate structure with:

   ```bash
   python3 .github/skills/skill-creator/scripts/package_skill.py containers/control-plane/skills/<skill-name>
   ```

## Combine with repo-local skills

- Put repo-specific skills in the repository's `.github/skills/` directory.
- Keep image-wide reusable workflows in bundled skills and keep repository-specific conventions in repo-local skills.
- Prefer repo-local overrides only when behavior truly depends on the mounted repository.
