# Changelog

## 0.1.0 - 2026-05-30

- Extracted `app-it` into a standalone assistant plugin repo.
- Packaged the plugin under `plugins/app-it/`, with the skill at `plugins/app-it/skills/app-it/`.
- Added marketplace metadata, validation script, CI, compatibility docs, and release checklist.
- Added Codex plugin metadata and marketplace metadata so the repo can be installed from Claude Code or Codex.
- Changed the default generated-app install location to `~/Applications/App It/`.
- Namespaced generated-app runtime state under `~/Library/Application Support/app-it/` and logs under `~/Library/Logs/app-it/`.
