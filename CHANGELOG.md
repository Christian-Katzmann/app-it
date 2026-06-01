# Changelog

## [Unreleased]

- Added: explicit `app-it` dev-server recipes for Vite + React, SvelteKit, and Astro, including disk detection signals, port behavior, and loopback-only start commands.
- Fixed: generated run scripts now preserve `$PORT`/`$API_PORT` inside configured start commands until the launcher has selected the runtime ports.
- Changed: hardened the shared Swift `WKWebView` shell against unusable restored window frames by clamping saved frames to the visible display and enforcing a minimum first-launch size.
- Added: `app-it-static` companion plugin (`plugins/app-it-static/`) — a macOS sibling of `app-it` for **finished or buildable** apps. Builds once, then serves the built output (`dist/`/`build/`/`out/`/…) from a tiny zero-dependency static server (~15 MB) or directly via `file://` (~0 MB) — **no dev server**, instead of the 300–700 MB a dev server holds. Reuses `app-it`'s native Swift WebKit window, icon pipeline, and one-folder Dock install (the five shared templates are byte-identical and CI guards them against drift). The served output is a snapshot; `desktop:rebuild` refreshes it. Inspired by r/ClaudeAI launch feedback (see README → Community nudge) and recorded in [ADR 0006](docs/decisions/0006-static-companion-snapshot-model.md).
- Added: Windows beta scaffold (`plugins/app-it-windows/`) — a sibling plugin mirroring the macOS contract with Windows primitives (WPF + WebView2 host, PowerShell lifecycle scripts, multi-resolution `.ico`, Start Menu `.lnk`). Build + lint gated by a required `windows-latest` CI job; **untested on real hardware, looking for a maintainer.** See [docs/WINDOWS.md](docs/WINDOWS.md).

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
