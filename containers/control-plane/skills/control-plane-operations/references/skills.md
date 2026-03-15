# Built-in skill reference

## Discovery model

- The control-plane image seeds this skill into `~/.copilot/skills/control-plane-operations` at container start.
- Because the target directory lives under the writable Copilot home, the skill stays visible even when `/workspace` points at a different repository.
- Repository-specific skills can still live under `.github/skills/` in the mounted repository.

## Update the bundled skill

1. Edit `containers/control-plane/skills/control-plane-operations/`.
2. Keep `SKILL.md` concise and move detailed material into `references/` when needed.
3. Ensure `containers/control-plane/Dockerfile` still copies the skill into `/usr/local/share/control-plane/skills/`.
4. Ensure `containers/control-plane/bin/control-plane-entrypoint` still syncs the bundled copy into `~/.copilot/skills/`.
5. Validate structure with:

   ```bash
   python3 .github/skills/skill-creator/scripts/package_skill.py containers/control-plane/skills/control-plane-operations
   ```

## Combine with repo-local skills

- Put repo-specific skills in the repository's `.github/skills/` directory.
- Keep image-wide operational guidance in this bundled skill and keep repository conventions in repo-local skills.
- Prefer repo-local overrides only when behavior truly depends on the mounted repository.
