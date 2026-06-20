---
name: app-it
description: >-
  Turn a local project or a hosted web app (including a published Claude
  Artifact URL) into a macOS Dock-launchable .app. Use when the user wants a
  clickable Dock app, local app package, icon, App It install, hosted-URL or
  Artifact wrapper, or repeatable desktop launcher. Defaults to native Swift
  WebKit, shipped templates, and verification of build, launch, ports, quit,
  warm relaunch, and cleanup.
---

# app-it - Make a local project or hosted web app launchable from the Dock

App It installs local projects under `~/Applications/App It/` as clickable
macOS apps: click opens, window close stays warm, Cmd+Q cleans up.

## Non-Negotiables

1. Run `templates/inspect.sh` first and read the output before editing.
2. Trust disk over docs. Verify project type from `package.json`, config files,
   and actual scripts when docs disagree.
3. Decide for the user when the default is defensible. Ask only before a
   destructive or genuinely ambiguous choice.
4. Copy the shipped templates into the target project and customize through
   `scripts/app-it.config.json`. Do not re-derive launcher patterns.
5. Keep App It local and reversible. No Electron/Tauri migration unless the
   project already has one or Strategy A cannot satisfy the requirement.
6. Verify the installed app path, runtime port truth, warm relaunch, Cmd+Q
   cleanup, and report honestly when GUI-only checks need a human.
7. When wrapping a hosted app, keep auth with the host. Never copy sessions,
   cookies, API keys, or another user's auth into a local bundle. For a Claude
   Artifact that uses hosted runtime APIs (`window.claude`, `window.storage`,
   MCP prompts, or Claude-provided auth), package the published/shared
   `claude.ai` URL rather than copied source.

## Reference Map

Open these only when the inspection or chosen path needs them:

- `references/project-inspection.md` - inspect output, app naming, bundle IDs,
  multi-app signals, and framework recipes.
- `references/strategies.md` - A1 native, Chrome fallback, A2 static, A3
  multi-server, A4 CLI, existing Electron/Tauri/NW.js, and Strategy D.
- `references/ports-and-worktrees.md` - worktrees, runtime port truth,
  hardcoded/env ports, and framework port cheat sheet.
- `references/generated-files.md` - allowed files, templates, config JSON,
  placeholders, scripts, and generated docs.
- `references/assets-and-icons.md` - icon discovery, rejection, preview,
  placeholders, and replacement.
- `references/fsa-and-chromium.md` - File System Access, polyfill, and
  Chromium-only routing.
- `references/verification.md` - build/install/runtime checks, smoke checks,
  human/deferred buckets, and cleanup semantics.
- `references/troubleshooting.md` - Gatekeeper/iCloud rescue, stale wrappers,
  `desktop:doctor`, and anti-patterns.
- `references/report-template.md` - exact final report format. Use it for the
  chat reply and `docs/desktop-launcher.app-it-report.md`.

## Templates

Copy templates from `templates/`; do not rewrite them. They encode the Mach-O
entrypoint, NFC/NFD-safe matching, daemon servers, two-stage cleanup, runtime
port fallback, descendant reattach, Finder/Dock `PATH`, menu shortcuts, and
doctor checks. See `references/generated-files.md` for the roster.

## Workflow

### 1. Inspect

Run the bundled inspector from the target project root:

```bash
/path/to/plugins/app-it/skills/app-it/templates/inspect.sh
```

Use its output for worktree status, project type, scripts, hardcoded ports,
multi-app/cohabiting-server signals, FSA, port collisions, toolchains, runtime
paths, and assets.

Read `references/project-inspection.md` before resolving app count, names,
bundle IDs, existing desktop configs, or project type. Read
`references/ports-and-worktrees.md` for worktrees, hardcoded ports, proxy
targets, or cohabiting frontend/backend servers.

### 2. Decide

For each user-facing app, choose one strategy:

```text
Existing Electron/Tauri/NW.js config?
  yes -> Strategy B
  no  -> native desktop requirements beyond web shell?
           yes -> Strategy D
           no  -> FSA real-I/O or Chromium-only API?
                    yes -> A1 Chrome fallback
                    no  -> static built bundle, no server?
                             yes -> A2
                             no  -> cohabiting frontend + backend?
                                      yes -> A3
                                      no  -> A1 native WebKit (default)
```

Default to A1 native WebKit. Use Chrome fallback for real File System Access or
other Chromium-only APIs. Use Electron/Tauri/NW.js only when the project already
owns that path. Read `references/strategies.md` before anything beyond simple
A1.

### 3. Build

Touch as few target-project files as possible. Read `generated-files` for the
allowed surface/config, `assets-and-icons` before icon work, and
`fsa-and-chromium` before FSA polyfill or Chrome fallback.

### 4. Verify

Verification is mandatory. Read `references/verification.md` and run applicable
programmatic checks:

Check executable shape, plist/icon validity, installed-path open, runtime port,
HTTP response, process and LaunchServices identity, Cmd+Q cleanup via Apple
Event, red-X warm state, and warm relaunch. Use `desktop:verify` for the
headless loop and `desktop:doctor` for ownership/template drift. Prefer their
`--json` modes for automation. `desktop:verify` uses `APP_IT_SMOKE=1` and marks
GUI-only checks manual unless a visible app window is actually driven.

Never claim GUI-only checks passed unless you can actually see them. Put window
content, Dock icon identity, autoplay, and FSA reconnect into the human bucket
when the environment cannot verify them.

### 5. Report

End with the `references/report-template.md` report inline and in
`docs/desktop-launcher.app-it-report.md`: strategy, changed files, icon source,
build/install/quit commands, installed paths, verification, Dock Stack note,
limitations, and decisions.

Stage new files with `git add` only when that is the repository's local
convention or the user asked for staging. Do not commit unless asked.

## Quick Defaults

- Install destination: `~/Applications/App It/`.
- Bundle ID prefix: `com.user.<slug>`, unless the project has a real domain.
- Preferred single-server ports: Next/CRA `3000`, Vite/SvelteKit `5173`, Astro
  `4321`, Flask/FastAPI project default.
- Port mode: keep `port_mode: "fallback"` unless browser storage, OAuth
  callbacks, or project config must stay on exactly one localhost origin. Use
  `port_mode: "fixed"` for that case; a busy preferred port is then a clear
  launch failure, not an upward scan.
- Framework recipes live in `project-inspection` and `ports-and-worktrees`.
  Translate examples to the package manager present.
- Next: use the direct binary when a script hardcodes flags, wraps `next dev`,
  or needs host/port flags:
  `pnpm exec next dev --hostname 127.0.0.1 --port "$PORT"` (translate `pnpm`
  to npm/yarn/bun as needed). Plain scripts that only run `next dev` are OK
  when they already honor `PORT`.
- Vite/SvelteKit command:
  `npm run dev -- --host 127.0.0.1 --port "$PORT" --strictPort`.
- Astro command: `npm run dev -- --host 127.0.0.1 --port "$PORT"`.
- Chrome fallback shutdown: document `desktop:quit` as primary cleanup because
  Chrome close/Cmd+Q do not map to the Swift wrapper lifecycle.
- Command surface: `scripts/app-it` routes `inspect | apply | verify | upgrade`
  over the vendored scripts (a router, not a binary or runtime dep). `upgrade`
  (`desktop-upgrade.sh`) re-vendors newer templates when the manifest's
  `template_version` is behind, touches only app-it's own artifacts, and rolls
  back if the post-upgrade verify fails. See `references/generated-files.md`.

## Stop Signs

Stop and explain clearly if the project needs blocking setup/auth, the start
command cannot honor the launcher port, a smoke test proves the project is
broken before the launcher, or the environment is hostile to verification.

## What Not To Do

- Do not make App It explicit-only.
- Do not default to Chrome for vanilla web apps.
- Do not attach to an arbitrary externally running server.
- Do not use `kill -TERM` on the wrapper to test Cmd+Q.
- Do not hardcode `com.$(id -un).*` bundle IDs.
- Do not derive `PROJECT_ROOT` from the installed app path.
- Do not remove PATH augmentation, runtime port fallback, daemon-mode warm
  relaunch, two-stage cleanup, native menu shortcuts, or doctor diagnostics.
