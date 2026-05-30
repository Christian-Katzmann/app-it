# Changelog

## [Unreleased]

- Added: Windows beta scaffold (`plugins/app-it-windows/`) — a sibling plugin mirroring the macOS contract with Windows primitives (WPF + WebView2 host, PowerShell lifecycle scripts, multi-resolution `.ico`, Start Menu `.lnk`). Builds and lints in CI on `windows-latest`; **untested on real hardware, looking for a maintainer.** See [docs/WINDOWS.md](docs/WINDOWS.md).

## 0.1.0 - 2026-05-30

- Extracted `app-it` into a standalone assistant plugin repo.
- Packaged the plugin under `plugins/app-it/`, with the skill at `plugins/app-it/skills/app-it/`.
- Added marketplace metadata, validation script, CI, compatibility docs, and release checklist.
- Added Codex plugin metadata and marketplace metadata so the repo can be installed from Claude Code or Codex.
- Changed the default generated-app install location to `~/Applications/App It/`.
- Namespaced generated-app runtime state under `~/Library/Application Support/app-it/` and logs under `~/Library/Logs/app-it/`.
- Rewrote the README as a landing page: a real hero shot (app-it run on itself), a North Star flow diagram, an honest status line, a local-only stance, and a sharp "what app-it is not" section.
- Added a `design/` asset system — hero, native-window crop, and a 2:1 social preview — produced by dogfooding the skill, not mocked up.
- Added a hand-curated `AGENTS.md` and `docs/decisions/` (architecture decisions plus a `REJECTED/` folder of alternatives that were considered and declined).
- Hardened CI: pinned the `actions/checkout` action to a commit SHA and dropped the workflow to read-only permissions.
