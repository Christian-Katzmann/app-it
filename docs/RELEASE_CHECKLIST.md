# Release Checklist

Before publishing a release:

- [ ] `./scripts/validate.sh` passes locally (fast static gate).
- [ ] `./scripts/test-fixtures.sh` passes locally (hermetic behavioral suite).
- [ ] `APP_IT_RUN_REAL=1 ./scripts/test-fixtures.sh` passes (real-Vite lane — confirms the current framework still launches end-to-end).
- [ ] `claude plugin validate .` passes with the current Claude Code CLI.
- [ ] `claude plugin validate plugins/app-it/.claude-plugin/plugin.json` passes with the current Claude Code CLI.
- [ ] Codex install smoke passes in a temp home (both installable plugins):
  `tmp_home="$(mktemp -d)" && HOME="$tmp_home" codex plugin marketplace add . && HOME="$tmp_home" codex plugin add app-it@app-it && HOME="$tmp_home" codex plugin add app-it-static@app-it`.
- [ ] `CHANGELOG.md` has an entry for the release.
- [ ] `plugins/app-it/.claude-plugin/plugin.json` version is bumped.
- [ ] `plugins/app-it/.codex-plugin/plugin.json` version is bumped.
- [ ] `plugins/app-it-static/.claude-plugin/plugin.json` + `.codex-plugin/plugin.json` versions are bumped together (when the static plugin changed).
- [ ] `.claude-plugin/marketplace.json` version and **each** plugin entry version are bumped (app-it, app-it-static, app-it-windows).
- [ ] `.agents/plugins/marketplace.json` lists all three plugins with correct paths.
- [ ] Shared templates are byte-identical across `app-it` and `app-it-static` (validate.sh's drift guard passes).
- [ ] The README install command matches the intended GitHub repo.
- [ ] No local paths, private notes, generated bundles, or test artifacts are tracked.
- [ ] **Manual GUI smoke** (the rows CI can't see — SKILL.md Phase-4 rows 12–16). The headless suite proves build → server → port → ownership → teardown; this proves the window actually works. Appify a real project (the `scripts/fixtures/vite-basic` shape is enough — `npm install` it first, or use any local app), install it, open it from `~/Applications/App It/`, and confirm by eye:
  - the window shows the app (not an error page);
  - the Dock icon is *ours* (not Chrome's / Safari's);
  - Cmd+Q kills the app **and** its dev server (`lsof -ti tcp:<port>` is empty after);
  - closing the window with the red X leaves the server warm (re-open is instant);
  - the standard shortcuts respond (Cmd+R reload, Cmd+W close, zoom, fullscreen).

For the first public GitHub setup:

- [ ] Repo description: `Turn local web projects into macOS Dock-launchable .app bundles with Claude Code and Codex.`
- [ ] Topics: `claude-code`, `claude-plugin`, `claude-skills`, `macos`, `dock`, `webkit`, `developer-tools`, `local-dev`.
- [ ] Issues enabled.
- [ ] Wiki disabled unless intentionally used.
- [ ] Social preview added if desired.
