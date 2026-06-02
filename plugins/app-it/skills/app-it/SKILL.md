---
name: app-it
description: >-
  Turn a project into one or more real macOS Dock-launchable `.app` bundles.
  Use when the user asks to make something clickable from the Dock, package it
  as an app, give it an icon, or put it in MyApps. Chooses sensible
  packaging defaults, creates repeatable scripts, installs to
  `~/Applications/App It/`, and verifies click-to-open behavior, port handling,
  warm reattach, window-close vs Cmd+Q behavior, and cleanup. Generated apps
  ship with a full standard macOS menu bar (Cmd+Q quit, Cmd+W close window,
  Cmd+M minimize, Cmd+H hide, Cmd+- / Cmd+= / Cmd+0 page zoom, Cmd+R reload,
  Cmd+Ctrl+F toggle full screen, plus standard Edit-menu shortcuts) — these
  are wired into `wrapper.swift`'s menu bar, not relied on as AppKit defaults
  (the defaults only cover Cmd+Q). Generated apps also ship a `desktop:doctor`
  command that self-diagnoses one launcher (config, install, signature, ports,
  stale PID, server ownership, template drift) read-only, with a narrow
  `--fix-safe` that only cleans up app-it's own generated state.
---

# app-it — Make any project launchable from the Dock

## Core principles

1. **Minimum work for the user. Maximum repeatability. No over-engineering.**
2. **Decide. Don't ask.** When this skill prescribes a default, use it. Building a `.app` is reversible — pick the best option, ship it, document tradeoffs in the report. Only ask if the project is genuinely ambiguous *and* the default would do something destructive. Treat explicit `/app-it` invocation as the user's plan approval; project CLAUDE.md "check in first" notes do not require a second prompt.
3. **Click → it works.** No second terminal, no manual `npm install`, no manual server starts, no "first run setup". Double-click → window appears showing the app → red-X leaves the dev server warm for fast re-launch → Cmd+Q kills everything.
4. **One folder, one Dock Stack.** Install destination is `~/Applications/App It/` by default. Users can drag that folder to the right side of the Dock once as a Stack. Use `~/Desktop/MyApps/` or `/Applications/` only when explicitly requested.
5. **One project may produce multiple apps.** Detect this; create one `.app` per user-facing app; do not bundle them.
6. **The `.app` keeps its own Dock icon.** This means the foreground process must be ours, not Chrome's. Default launcher is a small Swift `WKWebView` shell that the skill ships and compiles. Chrome `--app=` is a documented fallback only.
7. **Trust disk over docs.** `CLAUDE.md`, `AGENTS.md`, `README.md` may be stale, template-copied from another project, or describe an intended state not yet implemented. Always verify project type from `package.json` + config files. If docs and disk disagree, trust disk and note the discrepancy in the report.
8. **Runtime truth beats build-time guess.** The launcher's port may not be the configured port. The recorded supervisor PID may not be the listener. The verification target is the runtime artifact, not the build-time intent. The templates encode this; the agent must respect it during verification.

The user almost never wants:
- A full Electron migration of their existing app.
- A new bundler in their dependency tree.
- Hand-edited absolute paths.
- A workflow that opens stray Terminal windows on launch.
- To be asked a question that has a defensible default.

## When to use this skill

Trigger on any of: "launch from Dock", "give this an icon", "make this an app", "app-it", "appify", "dockify", ".app for this", "in /Applications", "in MyApps", "clickable launcher", "desktop shortcut for this project", "package as a desktop app".

Do **not** use this skill for:
- Distributing the app to other users (signing, notarization, App Store, auto-update). Mention as a known limitation.
- Native rewrites or feature additions.
- Generic "build" or "deploy" requests unrelated to a desktop launcher.

---

## Templates folder

This skill ships working templates next to `SKILL.md`. The agent's job is to **copy them into the project and customize via `app-it.config.json`** — not rewrite them from scratch. They encode hard-won lessons (autoplay handling, NFC/NFD-safe pgrep, daemon-mode dev server, two-stage cleanup, runtime port-fallback, descendant-walk reattach, expanded PATH for Bun/Volta/mise/asdf/Deno) that took 12 real-project sessions to get right.

```
templates/
  wrapper.swift                    # Swift WKWebView shell (~230 lines)
  info-plist-template.xml          # Info.plist with placeholders
  run-template.sh                  # bash launcher → execs wrapper (Swift mode)
  run-template-chrome.sh           # bash launcher → Chrome --app (fallback / FSA real-I/O)
  run-template-multiserver.sh      # bash launcher for cohabiting FE+BE
  desktop-build.sh                 # builds the bundles, compiles wrapper (universal)
  desktop-icons.sh                 # generates AppIcon.icns from a source PNG/SVG
  desktop-install.sh               # copies bundles to ~/Applications/App It/, refreshes Dock
  desktop-quit.sh                  # stops daemonized servers + wrapper windows
  desktop-doctor.sh                # self-diagnoses one launcher (read-only; --fix-safe for generated-state cleanup)
  inspect.sh                       # Phase-1 inspection helper (one-shot project probe)
  placeholder-icon-gen.sh          # last-resort icon generator (SVG via brand tokens)
  fsa-polyfill-template.js         # File System Access shim (only if needed)
  app-it.config.example.json       # single source of truth — copy + customize
  desktop-launcher.md.template     # user-facing doc
```

**Do not re-derive the patterns.** The comments inside templates document traps that will silently bite a fresh implementation.

---

## Workflow

Phases run in order. Don't skip ahead.

### Phase 1 — Inspect (read-only)

**Run `templates/inspect.sh` first.** It emits a one-page report covering worktree status, project type, dev scripts with hardcoded `-p` flags, framework port literals, FSA usage, sibling-app port collisions, runtime-binary availability, and gitignored data paths the launcher will need at runtime. Read its output before answering anything below.

Then answer all of these. Do not modify files.

1. **Worktree?** Check via `inspect.sh`. If yes, pick a strategy:
   - **(a) Bypass worktree, write to main checkout** — preferred when app-it is dev-tooling unrelated to the worktree's WIP branch. Cleanest baked path; mixes branch hygiene only if the user is mid-commit on main.
   - **(b) `APP_IT_PROJECT_ROOT` env override** — when app-it scripts should ship as a reviewable diff on the worktree's feature branch. Build from worktree, point baked path at main checkout via env.
   - **(c) Bake worktree + document rebuild** — only when the user explicitly opts in. The baked path will go away when the worktree is pruned; user must re-run `desktop:build` from main afterward. Do not let agents fall into this by default.
2. **Project type** (verify from disk, not from `CLAUDE.md`/`README.md`). Look for: `package.json` (with `dependencies`/`scripts`), `next.config.*`, `vite.config.*`, `tauri.conf.json`/`src-tauri/`, `electron.*`/`main.js`/`electron-builder.*`, `pyproject.toml`/`requirements.txt`, `index.html` at root, `Cargo.toml`, `Gemfile`, `manifest.json` + service worker.
3. **Runtime shape per app.** Static / single-server / multi-server cohabiting / one-shot script / already-a-desktop-binary.
4. **Dev-script choice.** Inventory all `dev:*` and `start:*` scripts (`inspect.sh` does this). Default to `dev` (canonical full-fidelity). Prefer a `dev:bypass` / `dev:no-db` / `dev:offline` variant when the canonical `dev` requires external services that won't be reachable from a Dock click. Surface alternatives in the final report so the user can flip without rebuilding from scratch.
5. **Hardcoded port literals.** If a dev script contains `-p 3002` or `--port 5173`, the framework will ignore the launcher's `PORT` env. Either swap for a clean direct-binary call (`pnpm exec next dev`) or add a new `dev:app-it` script without the literal. For Vite specifically, prefer `START_COMMAND="npm run dev -- --port \$PORT"` over editing `vite.config.ts` (CLI flag wins over config literal in vanilla single-server projects).
6. **Existing desktop config.** If `electron`, `electron-builder`, `tauri`, `nw.js`, `pkg`, or `nativefier` is already present — strong signal, use it (Strategy B).
7. **Multi-app detection.** See [Multi-app detection](#multi-app-detection).
8. **Cohabiting frontend+backend?** Strong signals: `concurrently`/`npm-run-all`/`turbo run dev`/`pnpm -r dev` in `scripts.dev`; a `proxy` block in `vite.config.*`/`next.config.*` targeting a different `localhost:` port; a separate `server/` directory with its own start script. → A3 multi-server. See [Strategy A3](#a3--multi-server-cohabiting-app).
9. **Browser-API gotchas.** Two-stage FSA grep:
   - Stage 1: `grep -RnIE "showDirectoryPicker|FileSystemDirectoryHandle|FileSystemFileHandle" --include='*.{ts,tsx,js,jsx}' src/` — any usage at all → polyfill candidate.
   - Stage 2: `grep -RnIE "\.createWritable\(|\.getFile\(\)|writable\.write\(" --include='*.{ts,tsx,js,jsx}' src/ services/` — real-I/O usage → polyfill *cannot* satisfy this; route to A1 chrome-fallback (Chrome supports FSA natively) or Strategy D.
10. **Toolchain availability.** `command -v swiftc`. If absent, A1 chrome-fallback; document the warts. The build script auto-detects and falls back.
11. **Asset inventory per app.** Find candidate icon sources (see [Asset discovery](#asset-discovery)). Parse `manifest.json` first when present. Reject icons whose filenames mirror `src/features/<name>/` — those are content, not the app's own mark.
12. **Project-name resolution.** When folder name, `package.json` `name`, `metadata.json` `name`, in-app titles, and recent commit subjects disagree, score by priority: recent commit subjects (user's actual vocabulary) → `displayName` → human-looking `metadata.json` `name` → folder humanized → `package.json` `name` last and only if not slug-shaped. **Reject** `package.json` names containing `---` or matching scaffold patterns (`vite-project`, `next-app`). Surface conflicts in the report so the user can override.
13. **Bundle-ID prefix.** Mandate `com.user.<slug>` as the default. **Reject** `com.$(id -un).*` — LaunchServices treats it as a personal-team developer prefix and refuses unsigned bundles with `_LSOpenURLs… error -600 / procNotFound`. Country-coded reverse-DNS (`dk.example.app`) is also a clean choice for projects with a real domain.
14. **Install destination.** `~/Applications/App It/` (auto-create if missing) unless the user explicitly requested `~/Desktop/MyApps/`, `/Applications/`, or another path.
15. **Project root path.** Resolve to a *persistent* absolute path (post-worktree-strategy from step 1). The build script bakes this; it cannot be re-derived from `$0` after install.

### Phase 2 — Decide

For **each app** detected, pick **one** strategy:

```
Existing Electron/Tauri/NW.js config for this app?
├── YES → Strategy B
└── NO →
    Hard requirement for native menu bar / tray / file associations / shipping signed?
    ├── YES → Strategy D (Tauri wrapper)
    └── NO →
        FSA real-I/O usage? (createWritable / getFile-then-blob)
        ├── YES → A1 chrome-fallback (Chrome supports FSA natively, zero rewrite)
        └── NO →
            Other Chromium-only Web APIs needed? (Web USB/Bluetooth/HID/MIDI)
            ├── YES → A1 chrome-fallback
            └── NO →
                Static built bundle, no server?
                ├── YES → A2
                └── NO →
                    Cohabiting frontend + backend?
                    ├── YES → A3 (one .app starts both)
                    └── NO → A1 native (DEFAULT)
```

Within Strategy A1, choose:
- **A1 Native WebKit shell (Swift)** — DEFAULT for any web app. Required if the user values the Dock icon staying ours, single-instance activation, fast re-launches, or daily-use polish. Requires `swiftc`.
- **A1 Chrome fallback** — also the right choice (not just degraded) when the app needs FSA real-I/O or other Chromium-only Web APIs. Use when `swiftc` unavailable AND user can't run `xcode-select --install`. Documented warts.
- **A2 Static** — built site with `index.html`, no server.
- **A3 Multi-server** — one user-facing app with cohabiting backend + frontend.
- **A4 CLI script** — script with no UI; produces a `.app` that spawns Terminal. Flag loudly in the report.

PWA install (formerly Strategy C) is no longer a primary path — when the project has a manifest, **also** ship a Strategy A `.app` and mention the PWA install option in the doc.

### Phase 3 — Build

Touch as few project files as possible. Allowed additions:

- `assets/<slug>-icon.{png,svg}` per app (or `assets/app-icon.{png,svg}` if single-app).
- `assets/icons/` — generated icon artifacts (gitignore the contents).
- `assets/icons/build/wrapper` — compiled Swift binary (gitignore).
- `scripts/wrapper.swift`, `scripts/run-template*.sh`, `scripts/info-plist-template.xml`, `scripts/desktop-*.sh`, `scripts/inspect.sh`, `scripts/placeholder-icon-gen.sh` — copied verbatim from `templates/`. (`scripts/desktop-doctor.sh` is among the `desktop-*.sh` set — see [Diagnosing a generated app](#diagnosing-a-generated-app).)
- `scripts/app-it.config.json` — single source of truth for the APPS list (see below).
- `assets/<slug>-polyfill.js` — only when FSA usage is detected.
- `desktop/<AppName>.app/` per app (gitignore — regenerated by build).
- `docs/desktop-launcher.md`.
- `docs/desktop-launcher.app-it-report.md` — agent decision provenance (see Phase 5).
- `package.json` `scripts` entries: `desktop:build`, `desktop:icons`, `desktop:install`, `desktop:quit`, `desktop:doctor`.

**Single source of truth: `scripts/app-it.config.json`**

```json
{
  "apps": [
    {
      "name": "Momó Studio",
      "slug": "momo-studio",
      "port": 5173,
      "start_command": "npm run dev -- --port $PORT",
      "bundle_id": "com.user.momo-studio",
      "version": "0.1.0",
      "polyfill_path": ""
    }
  ]
}
```

For A3 multi-server, add `"backend_port"` and `"backend_start_command"`. The build script reads this file; `desktop-quit.sh` reads it too — no APPS-table drift between scripts. (For backward compat, the build script also accepts a bash `APPS=(...)` array if no JSON is present.)

**Substitution placeholders** baked into the run-script at build time:
- `__APP_NAME__`, `__APP_SLUG__` — display name (may be non-ASCII), file-safe slug.
- `__PROJECT_ROOT__` — absolute path to repo, baked at build time.
- `__PORT__` — *preferred* port. Launcher tries first, scans upward for free port if taken, records actual runtime port to `~/Library/Application Support/app-it/<slug>/server.port`.
- `__START_COMMAND__` — must honor `PORT` env. See [Framework PORT cheat sheet](#framework-port-cheat-sheet).
- `__BUNDLE_ID__`, `__VERSION__` — reverse-DNS bundle id, marketing version.
- `__POLYFILL_PATH__` — absolute path to a JS polyfill file (empty if none).

**Config-file edits to make ports env-driven are expected and necessary** (not a violation of "don't touch app source"). You MAY (and often MUST) edit:
- Frontend dev-server config (`vite.config.*`, `next.config.*`, `webpack.config.*`) to read `process.env.PORT` and route proxy targets through `process.env.API_PORT` (multi-server case).
- Server entrypoints (`server/index.{ts,js,py}`, `app.py`) to read `API_PORT` *before* falling back to `PORT` — needed for cohabiting projects where `--env-file=.env` injection of `PORT=...` would otherwise override the launcher.
- Add `strictPort: true` to Vite configs so the launcher's port allocation isn't silently overridden by Vite's own bump-on-collision.

Edits should be minimal and additive (env-var reads with sensible defaults), so existing developer workflows (`npm run dev` from terminal without env vars set) keep working unchanged.

### Framework dev recipes

Use these when disk signals are unambiguous. Examples use `npm`; translate to
the package manager actually present in the project while preserving the same
script arguments.

| Framework | Reliable detection signals | Preferred port | `START_COMMAND` | Notes |
|---|---|---:|---|---|
| Vite + React | `vite.config.*`; `package.json` has `vite`, `react`, `react-dom`, and `@vitejs/plugin-react` or `@vitejs/plugin-react-swc`; fresh apps usually have `src/main.jsx` or `src/main.tsx` | 5173 | `npm run dev -- --host 127.0.0.1 --port "$PORT" --strictPort` | Vanilla single-server path. The CLI flags beat `vite.config.*` port literals without source edits. If a proxy target or backend port is hardcoded, route to A3.2 and make the ports env-driven. |
| SvelteKit | `svelte.config.*`; `package.json` has `@sveltejs/kit`, `@sveltejs/vite-plugin-svelte`, `svelte`, and `vite` | 5173 | `npm run dev -- --host 127.0.0.1 --port "$PORT" --strictPort` | SvelteKit runs through Vite, so use Vite CLI port flags instead of relying on `PORT` alone. First launch must happen after dependencies are installed. |
| Astro | `astro.config.*`; `package.json` has `astro`; `scripts.dev` is usually `astro dev` | 4321 | `npm run dev -- --host 127.0.0.1 --port "$PORT"` | Astro's dev server accepts `--port`, and the explicit flag works across current Astro releases. Keep the host loopback-only; do not use `--host 0.0.0.0`. |

Never:
- Modify app business-logic source code.
- Add runtime dependencies for Strategy A.
- Hardcode user-home paths anywhere except as defaults with override.
- Spawn a Terminal window the user has to keep open (A4 only, flagged).
- Write a launcher that requires the dev server to already be running.
- Leave server processes alive after the user Cmd+Q's the app.

### Phase 4 — Verify (mandatory)

For each `.app`, run the checks below. **Three buckets** — never claim success in a bucket the agent can't actually verify.

| # | Check | Programmatic | Idiom |
|---|---|---|---|
| 1 | Build succeeded | `[x]` | `.app` exists; `file <wrapper>` reports `Mach-O … executable`; `file <AppIcon.icns>` reports `Mac OS X icon` |
| 2 | Bundle metadata | `[x]` | `/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' .../Info.plist`; `… CFBundleName`; substituted, no `__PLACEHOLDER__` left |
| 3 | Runtime port discovery | `[x]` | `RUNTIME_PORT=$(cat "$HOME/Library/Application Support/app-it/<slug>/server.port")` — *always read this first*, never hardcode `PREFERRED_PORT` |
| 4 | Server responding | `[x]` | `curl -sS -o /dev/null -w "%{http_code}" http://localhost:$RUNTIME_PORT` — any non-`000` counts (5xx is a project-state issue, not a launcher issue) |
| 5 | Wrapper alive, single instance | `[x]` | `pgrep -af "<App>.app/Contents/MacOS/wrapper"` exactly 1 row (use bundle-name path, not bare `wrapper`, to avoid cross-app noise) |
| 6 | Bundle identity registered | `[x]` | `lsappinfo info -only bundleid <ASN>` matches `<bundle-id>` from config |
| 7 | Cmd+Q kills server tree | `[x]` | `osascript -e 'tell application id "<bundle-id>" to quit'`, then `lsof -ti tcp:$RUNTIME_PORT` is empty within 2s. **Multi-server (A3.2):** also assert `lsof -ti tcp:$BACKEND_RUNTIME_PORT` is empty (read from `~/Library/Application Support/app-it/<slug>/backend.port`). `wrapper.swift` discovers `backend.pid`/`backend.port` as siblings of `server.pid`; if the backend leaks, the sibling-discovery code path is broken or the multiserver template stopped writing those files. **Never use `kill -TERM` to wrapper PID** — bypasses `applicationShouldTerminate` and gives a false-fail. |
| 8 | Red-X leaves server warm | `[x]` | `osascript -e 'tell application id "<bundle-id>" to close every window'`; `lsof -ti tcp:$RUNTIME_PORT` is non-empty 1s later |
| 9 | Warm re-launch fast | `[x]` | re-`open`; HTTP 200 within ~250ms (cold-start would be 3s+); confirms F38 reattach gate works for this `START_COMMAND` shape |
| 10 | Install path opens cleanly | `[x]` | `open "$HOME/Applications/App It/<App>.app"; echo "exit=$?"` — must be `0`. **Never substitute `open <build-path>`** — different LS paths, different failure modes. |
| 11 | Install path matches build | `[x]` | `lsregister -dump 2>/dev/null \| grep -B1 "<bundle-id>" \| head` — exactly one entry; if two, run `lsregister -u <build-path>` |
| 12 | Window shows app content (not error page) | `[ ] needs human` | unless display available |
| 13 | Dock icon is OUR icon (not Chrome's, not Safari's) | `[ ] needs human` | unless display available |
| 14 | Autoplay video plays without user click *(if media)* | `[ ] needs human` | |
| 15 | FSA reconnect-on-load works *(if FSA polyfill)* | `[ ] needs human` | |
| 16 | Standard keyboard shortcuts respond | `[ ] needs human` | Cmd+Q kills app+server; Cmd+W closes window leaving server warm; Cmd+R reloads; Cmd+Shift+R force-reloads; Cmd+-/=/0 zoom out/in/reset; Cmd+M minimizes; Cmd+Ctrl+F fullscreen; Edit menu (Cmd+X/C/V/Z/A). All wired in `wrapper.swift`'s `buildMenu()`. **Programmatic check:** `grep -qboa "reloadPageIgnoringCache" app.app/Contents/MacOS/wrapper` — exits 0 if shortcuts are present. Do NOT use `strings \| grep "Force Reload"` — Swift -O inlines string literals in a format `strings` misses. **If absent: the installed wrapper is a pre-menu-bar binary — run `desktop:build && desktop:install` in that project.** |

**Defer-and-document bucket**: when the agent's environment makes verification hostile — same-project dev server already running on the preferred port (would corrupt `.next/` cache via competing Turbopack), or different-project holding a port that this project's launcher can't fall back from (hardcoded proxy target) — do **not** spawn a competing instance. Mark these `[ ] deferred — env hostile`, write the user-action one-liner in the report (e.g., `pkill -f "next dev.*$PROJECT_ROOT" && open "$HOME/Applications/App It/<App>.app"`).

**Pre-flight smoke test before clicking the `.app`** (separates project-broken from launcher-broken):
```bash
( cd "$PROJECT_ROOT_BAKED" && PORT=$SMOKE_PORT timeout 30 bash -c "$START_COMMAND" ) &
SMOKE_PID=$!
# poll for HTTP, then kill
```
If smoke fails, report launcher-built-but-project-broken — not launcher-broken.

If GUI verification is impossible (sandboxed environment, no display), say so explicitly under Known limitations — don't claim success.

### Phase 5 — Report

Two outputs:

1. **Inline chat report** — same 12-section format as before (see [Final report format](#final-report-format)).
2. **`docs/desktop-launcher.app-it-report.md` written to disk** — same content plus a `## Decision history` section that future agent sessions append to. Cost is zero (the agent already produced the content). Future sessions skim this before re-deriving anything.

Stage new files with `git add`; do **not** create a commit unless the user explicitly asks.

---

## Gatekeeper & signing

`desktop-build.sh` ends with an ad-hoc codesign step that satisfies macOS 15+ (Sequoia / Tahoe) Gatekeeper without needing an Apple Developer account:

```bash
/usr/bin/xattr -cr "$APP_DIR"                           # strip iCloud/Finder metadata first
/usr/bin/codesign --force --deep --sign - "$APP_DIR"    # ad-hoc (self) signature
```

This is automatic — no action needed at build time. The verification table row 10 (`open` exits 0) is the practical Gatekeeper test. `spctl --assess` will say "rejected" for ad-hoc bundles — that is normal and expected; ignore it.

**Rescue: app shows ⊘ prohibition symbol after a macOS update**

Apps built before the codesign step was added show ⊘ in Finder and refuse to open. Preferred fix is to rebuild each project (`desktop:build && desktop:install`), which re-compiles the wrapper and re-signs. If rebuilding is impractical, sign in place:

```bash
cd "$HOME/Applications/App It"
for app in *.app; do
    /usr/bin/xattr -cr "$app" 2>/dev/null || true
    /usr/bin/codesign --force --deep --sign - "$app" 2>/dev/null && echo "OK: $app"
done
```

**iCloud-synced apps (Desktop / Documents with iCloud Drive enabled):** macOS adds `com.apple.fileprovider.fpfs#P` to directories in iCloud-synced folders. This xattr is system-protected — `xattr -cr` doesn't remove it, and `codesign` refuses to sign bundles that have it. Fix: copy without metadata, sign clean, replace:

```bash
app="Broken App.app"
ditto --noextattr --norsrc "$app" /tmp/clean.app
/usr/bin/codesign --force --deep --sign - /tmp/clean.app
mv -f "$app" "${app}.bak" && mv /tmp/clean.app "$app" && rm -rf "${app}.bak"
```

After signing, clear the Launch Services cached verdict and restart Finder:

```bash
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREG" -f "$PWD/$app"
killall Finder
```

**Keyboard shortcuts — old wrapper binaries:** `wrapper.swift`'s `buildMenu()` ships the full standard macOS menu bar. If a user reports missing shortcuts (Cmd+R, Cmd+-, Cmd+=, etc.), their installed wrapper was compiled before `buildMenu()` was added. Running `desktop:build && desktop:install` in the project directory recompiles and reinstalls the wrapper with the current template.

---

## Multi-app detection

**Strong signals (treat as multi-app):**
- Monorepo: `apps/*/package.json`, `packages/*/package.json` with `dev`/`start` scripts; `turbo.json`, `nx.json`, `pnpm-workspace.yaml`, `lerna.json` listing multiple apps.
- Multiple `dev:*` or `start:*` scripts in root `package.json` running on different ports.
- Sanity studio embedded as a separate dev server (`sanity dev`) alongside a main web app.
- README naming distinct end-user apps.

**Weak/false signals (treat as single-app):**
- Multiple routes inside one Next.js / Vite app (`/admin`, `/studio` on the same dev server).
- Storybook, docs sites, e2e test runners — dev tools, not user apps. Skip unless explicitly requested.
- `apps/api` (server only, no UI) — bundle with the frontend that consumes it (A3 cohabiting).
- **Per-feature icon directories.** Files like `public/app-icons/{ToolA,ToolB}_Icon.png` typically denote in-app feature branding, NOT separate apps. Cross-check against `src/features/`. If every icon's filename maps to a feature, they're content — build one `.app` for the parent project.

**Naming:** Single app — name after the project. Multi-app — prefix or suffix consistently (`Momo.app`, `Momo Studio.app`).

---

## Strategy A1 — Native WebKit shell (Swift) — DEFAULT

Why this is the default and not Chrome `--app=`:

| Issue | Chrome `--app=` | Native WebKit shell |
|---|---|---|
| Dock icon while window open | Chrome's icon, not ours | Ours |
| Re-click while window open | Opens a duplicate window | Activates existing window |
| Window-startup latency | Multi-second profile init | ~200 ms |
| Cmd+Q vs red-X | Indistinguishable | Distinguishable |
| Single-instance | Manual AppleScript hack | Native via NSApplication |

Issues 1–3 are structural to Chrome — not patchable. They surface within minutes of daily use.

**Bundle layout:**

```
desktop/<AppName>.app/
  Contents/
    Info.plist                       # CFBundleExecutable = "run"
    MacOS/
      run                            # bash launcher (server boot + exec)
      wrapper                        # compiled Swift WKWebView shell (universal)
    Resources/
      AppIcon.icns                   # generated by desktop-icons.sh
```

**Shipped runtime defenses (don't reimplement, don't drop):**
- **Runtime port-fallback.** Scans `[PREFERRED..PREFERRED+50]` at click time, picks first free port, records actual port to `~/Library/Application Support/app-it/<slug>/server.port`. Sibling appified apps coexist without coordination.
- **Two-stage readiness probe.** Port-bound first (any process listening), then any HTTP response (5xx counts — the wrapper shows the user the real error in-window).
- **Permissive descendant-walk reattach.** Recorded supervisor PID (e.g. `pnpm dev`) is treated as the root of an ownership tree — actual listener (`next-server`) can be a great-grandchild. Warm re-launch reattaches in ~250ms even for `pnpm`/`npm`/`yarn`/`bun`/`concurrently` supervisor chains.
- **`setsid` daemonization.** Detaches the dev server from the wrapper's process group so SIGHUP propagation can't kill it on wrapper exit.
- **Pre-flight runtime checks.** Confirms `PROJECT_ROOT` exists, `command -v <START_COMMAND-bin>` resolves under augmented PATH, `node_modules/.bin/<framework>` exists when applicable. Surfaces actionable alert in <1s instead of 60s misdirected timeout.
- **Expanded PATH.** Bun, Deno, Volta, mise, asdf, cargo, plus the v1 set (Homebrew, nvm-latest, pnpm-store).
- **Two-stage cleanup in `desktop-quit.sh`.** TERM the recorded PID tree → port-sweep stragglers → SIGKILL holdouts. Catches reparented children that single-stage cleanup misses.
- **Sibling-discovery cleanup in `wrapper.swift::killServer()`.** Cmd+Q on a multi-server (A3.2) `.app` would otherwise leak the backend — the wrapper only knows the FE pid/port via argv. The wrapper looks for `backend.pid` and `backend.port` as siblings of the FE pid file and tears them down on quit. No-op for single-server. Discovered 2026-04-29 on Music Videolizer (FE :5173 freed in <1s, BE :3002 kept listening).

**`PROJECT_ROOT` is baked at build time.** Honors `APP_IT_PROJECT_ROOT` env override. Never derive from `$0`'s parent — the `.app` is copied to `~/Applications/App It/` on install.

## Strategy A1 fallback — Chrome `--app=`

Use when:
- `swiftc` unavailable AND `xcode-select --install` not feasible, OR
- App needs FSA real-I/O (`handle.createWritable()` returns WritableStream, `handle.getFile()` returns blob), OR
- App needs other Chromium-only Web APIs (Web USB/Bluetooth/HID/MIDI).

The Chrome template ships **with feature parity** to the Swift template: runtime port-fallback, `server.port` recording, two-stage readiness probe, expanded PATH. Documented warts that remain:
- Dock icon may show Chrome's while window is open.
- Re-clicking the Dock icon may open a duplicate Chrome window.
- Window startup is slower (Chrome profile init).
- Cmd+Q vs red-X are not distinguished. Closing the window leaves the dev server running until `desktop-quit.sh`. Mark Cmd+Q-kills-daemon `[ ] needs desktop:quit` in Phase 4, document `desktop:quit` as the primary shutdown command in `docs/desktop-launcher.md`.

Opt-in `APP_IT_CHROME_KEEP_WARM=0` makes Chrome exit also tear down the daemon (loses the warm-server benefit).

## A2 — Static site / built bundle (no server)

Adapt `run-template.sh`: drop the daemon-server block, point the URL at `file://$PROJECT_ROOT/<dist>/index.html`, hand off to `wrapper`. Pass empty string for the port argv.

> For a *finished/buildable* app whose whole point is to skip the dev server, the **`app-it-static`** companion skill is the better tool: it detects the build command and output dir, builds once, and serves the result from a tiny static server or `file://` — with a proper snapshot/`desktop:rebuild` model. Use it when static serving is the goal, not just an A2 corner case.

## A3 — Multi-server cohabiting app

Three sub-strategies — pick by project context:

### A3.1 — Reuse existing orchestrator (preferred when it exists)

If the project already has multi-process orchestration (`concurrently`, `npm-run-all -p`, `turbo run dev`, `pnpm -r dev`, custom `scripts/dev.sh`), use it as a single `START_COMMAND` in the standard A1 template. Strictly simpler than reimplementing parallel-spawn. The orchestrator's signal-forwarding tears down both children on TERM; `desktop-quit.sh`'s port-sweep catches stragglers. ~30 lines instead of ~120.

### A3.2 — `run-template-multiserver.sh` with env-driven ports

When no orchestrator exists or the orchestrator misbehaves on signals. The shipped `run-template-multiserver.sh` allocates two ports (FE + BE), exports them as distinct env vars (`PORT`, `API_PORT`), boots both via sequential `setsid` spawn, waits for the frontend port, records both ports. `wrapper.swift`'s `killServer()` discovers `backend.pid` / `backend.port` as siblings of the FE pid file in `~/Library/Application Support/app-it/<slug>/`, so Cmd+Q tears down both servers without further argv plumbing — `desktop-quit.sh` is the defensive fallback for re-parented children, not the primary path.

**Required edits** (carve-out from "don't touch app source"):
- Frontend config: `server.port` reads `process.env.PORT`; `strictPort: true` (Vite); proxy target reads `process.env.API_PORT`.
- Backend entrypoint: reads `process.env.API_PORT` *before* `process.env.PORT` so `--env-file=.env` injection of `PORT=...` doesn't override the launcher.

For Vite + Express specifically, this means three edits to `vite.config.ts` (server.port, strictPort, proxy.target) and one to `server/index.ts` (API_PORT first). The skill's anti-pattern *"don't touch app source"* explicitly carves these out — they make ports env-driven, which is what the launcher needs. They're additive and don't break terminal `npm run dev`.

### A3.3 — Refuse-to-start when proxy/port literals are unmovable

When the project's `.env` and tooling depend on the literal port (e.g. proxy target at `localhost:3001` is referenced from many places, user explicitly didn't ask for source edits), the launcher refuses to start with a clear alert if either fixed port is busy. No source edits. The behavioral contract is "your project's daily-development setup, made clickable" — not refactored. Document the trade in §12 of the report so the user can flip if they want fallback later.

## A4 — CLI script with no UI

Builds anyway, flags loudly. Spawns Terminal because there's no other way to show output.

```bash
exec /usr/bin/osascript -e "tell application \"Terminal\" to do script \"cd '$PROJECT_ROOT' && $START_COMMAND\""
```

---

## Strategy B — Existing Electron / Tauri / NW.js config

Repo already has it — use it. Do not stack Strategy A on top.

- **Electron + electron-builder:** `desktop:build` → `electron-builder --mac`. Wire icons via `build.icon` in `package.json`, pointed at `assets/app-icon.png`. `desktop-install.sh` copies from `dist/`/`out/`.
- **Tauri:** `desktop:build` → `tauri build`. Regenerate icons with `tauri icon assets/app-icon.png`. Output `.app` at `src-tauri/target/release/bundle/macos/`.
- **NW.js:** `nw-builder`.

Point each build to `assets/app-icon.png` — one file for the user to replace later.

## Strategy D — Lightweight wrapper (Tauri, only when justified)

Reach for D only when Strategy A genuinely can't deliver:
- Native menu bar entries
- Status bar / tray icon
- Custom URL protocol handlers
- System notifications with native UI
- File-association handling
- Shipping signed bundles to other users

(FSA real-I/O *no longer routes here* — A1 chrome-fallback is the lower-effort answer.)

Default to Tauri. Minimum config wrapping the existing app (devPath at the running port, distDir at the built output, beforeDevCommand and beforeBuildCommand pointing at the existing scripts).

---

## Asset discovery

Per app, search in this order before considering a placeholder:

1. **`manifest.json`** (or `app/manifest.{json,ts}`, `static/manifest.json`) — parse it and prefer the largest declared icon with `purpose` containing `any` or `maskable`. The project already curated this; don't re-derive.
2. **Dedicated app icons** in or near the app's directory: `app-icon.*`, `app_icon.*`, `appicon.*`, `icon.png`, `icon.svg`, `icon@*.png`, `*.icns`, `*.ico` in `./`, `assets/`, `public/`, `static/`, `src/assets/`, `app/`, `resources/`, `images/`.
3. **High-resolution square logos:** `logo.*`, `brand.*`, `mark.*`, `logo-square.*`, `logo-mark.*`. Prefer ≥ 512×512.
4. **SVG logos** that rasterize cleanly to a square.
5. **Existing favicons:** `favicon.svg`, `favicon-512.png`, `apple-touch-icon.png`, `apple-icon.png`, `app/icon.png` (Next.js convention). Ignore 32×32 favicons when anything larger exists.
6. **Brand-token-derived SVG** (`templates/placeholder-icon-gen.sh`): parses `globals.css` `--color-*` custom properties and emits a 30-line SVG keyed to the project's palette. Preferred over a single-letter monogram on a flat color.
7. **Last-resort placeholder:** first letter of the app name on a brand-colored background. Only when no usable mark exists anywhere.

For each candidate:
- Resolution: ≥ 1024×1024 ideal, 512×512 acceptable, < 256×256 only if nothing better exists.
- Aspect: square required. Pad non-square sources to square; never crop the brand mark.
- Background: transparent or solid. Wordmarks usually look bad in the Dock — prefer the mark variant.
- Format: SVG > PNG > JPG/WebP > ICO.
- **Reject zero-byte placeholders.** Filter via `find ... -size +10k` or `file` MIME type to avoid `.gitkeep` artifacts.
- **Reject content-icons disguised as app-icons.** When per-feature icons (`public/app-icons/<Tool>_Icon.png`) outrank the master mark by resolution, cross-check against `src/features/<name>/`. If filenames map 1:1 to features, they're content — pick the lower-res project-named master instead.

**Decision rule:** pick the single best source per app, copy to `assets/<slug>-icon.png` (or `assets/app-icon.png` for single-app). The user must have **one** file per app to replace later.

---

## FSA polyfill recipe

WebKit does not implement File System Access. Apps that gate on `'showDirectoryPicker' in window` will show "Browser not supported" inside the Swift wrapper unless polyfilled.

**When to use the polyfill (A1 native):**
- App calls `showDirectoryPicker()` to pick a workspace folder.
- Stores handle in IndexedDB to remember it across sessions.
- All real file I/O goes through a server-side API — the JS handle is just a "remembered folder" reference.

**When NOT to use it (route to A1 chrome-fallback or D):**
- App reads file contents via `handle.getFile()` → blob.
- App writes via `handle.createWritable()` → WritableStream from JS.
Synthetic handles can't satisfy this contract.

**How to apply:**
1. Phase 1 grep already identified candidate. Confirm with stage-2 grep (`createWritable`, `getFile`).
2. If stage-2 hits, switch strategy to A1 chrome-fallback. Don't fight WebKit.
3. Otherwise, find the IDB conventions: `indexedDB.open(`, `createObjectStore(`, the workspace-handle key.
4. Copy `templates/fsa-polyfill-template.js` to `assets/<slug>-polyfill.js`.
5. Substitute placeholders: `__WORKSPACE_PATH__`, `__WORKSPACE_NAME__`, `__APP_DB_NAME__`, `__APP_STORE_NAME__`, `__APP_KEY_NAME__`.
6. Set `polyfill_path` in `app-it.config.json` to `@ROOT@/assets/<slug>-polyfill.js`.
7. Build, install, click — the polyfill is injected at `documentStart`.

If `handle.getDirectoryHandle('subdir', {create: true})` is expected to land real files: pre-create directories in `desktop-build.sh` or `run-template.sh`.

---

## Anti-patterns

Hard-won from real-project iteration. Do not rediscover these:

- **Don't use Chrome `--app=` as the default for vanilla web apps** — it steals the Dock icon, breaks single-instance, is slower. Use Swift. Exception: chrome-fallback IS the right answer when the app needs Chromium-only APIs (FSA real-I/O, Web USB/Bluetooth/HID/MIDI).
- **Don't passive-attach to externally-running servers.** If something is already on `$PREFERRED_PORT`, scan upward and start your own. Even when the existing server *seems* like it must be ours (matching path, matching framework), the cost of being wrong is showing the user another project's UI inside your app's window. The descendant-walk reattach gate enforces this; don't replace it with a bare `curl 200 → attach`.
- **Don't use AppleScript / `osascript` to dedup Chrome `--app=` windows.** Fragile, requires Accessibility permission.
- **Don't touch `WKPreferences` private SPI for autoplay.** Keys throw `NSUnknownKeyException`, crash happens in `applicationDidFinishLaunching` before the WebView is constructed. The fix in `wrapper.swift` is a synthetic `NSEvent` mouseDown/mouseUp pair after first navigation — that counts as a real platform gesture.
- **Don't path-match `pgrep -f` on paths with non-ASCII characters.** macOS stores command lines in NFD; shell strings are typically NFC. The templates key on URL/port (ASCII). When matching wrappers, use `<App>.app/Contents/MacOS/wrapper` (bundle-name path) — the bundle name is uniquely identifying and `.app/` is ASCII even when the bundle name itself contains accented characters.
- **Don't trust `curl HTTP 200` as page-works verification.** Several "should work" theories pass curl and still show a blank window in the wrapper. Verification requires opening the actual `.app` and seeing the actual content. Read `server.port` *first*, then curl that port, never the configured port.
- **Don't use `kill -TERM` against the wrapper PID to verify Cmd+Q semantics.** Signals bypass AppKit's lifecycle. Use `osascript -e 'tell application id "<bundle-id>" to quit'` — that sends a Quit Apple Event, routing through `applicationShouldTerminate`, which is the real Cmd+Q code path.
- **Don't derive `PROJECT_ROOT` from `$0`'s parent.** The `.app` is copied to `~/Applications/App It/` on install. Bake the absolute repo path at build time via the build script's `ROOT="$(cd "$(dirname "$0")/.." && pwd)"`, honoring `APP_IT_PROJECT_ROOT` env override for worktree workflows. The launcher refuses to start if the path no longer exists.
- **Don't symlink `node_modules` from main into a worktree.** Turbopack and several other bundlers reject it (`Symlink node_modules is invalid, it points out of the filesystem root`). The only correct answer is baking the canonical path.
- **Don't use single-stage cleanup.** pnpm/vite/esbuild re-parent grandchildren to `launchd` before the trap fires. Use the two-stage pattern in `desktop-quit.sh`: TERM the recorded PID tree → sweep `lsof -ti tcp:$PORT` with TERM → wait 1.5s → SIGKILL stragglers.
- **Don't omit PATH augmentation.** Finder/Dock launches start with bare `PATH=/usr/bin:/bin`. The shipped template covers Homebrew, nvm-latest, pnpm-store, Bun (`$HOME/.bun/bin`), Deno (`$HOME/.deno/bin`), Volta (`$HOME/.volta/bin`), mise/asdf shims, cargo. Don't strip entries when adapting.
- **Don't kill the dev server on every window close.** Daemon-mode is the default. Window-close = leave warm. Cmd+Q = full kill. The Swift wrapper distinguishes via `windowShouldClose` setting a flag that `applicationShouldTerminate` checks.
- **Don't migrate to Electron/Tauri "while you're at it".** Add only what the launcher needs.
- **Don't pick `npm run dev` blindly.** If a dev script wraps the dev-server binary in a TTY-assuming launcher (ASCII-art mascot, ANSI cursor escapes, interactive prompt), Finder/Dock launches have no TTY and the wrapper hangs. Read the script. Prefer `dev:server`/`dev:vite`/the bare command. If `npm run start` (production build) makes more sense for daily use, prefer it.
- **Don't pick a dev script with a hardcoded `-p`/`--port` literal.** The launcher's chosen port is silently ignored. Either swap for a clean direct-binary call (`pnpm exec next dev`) or add a `dev:app-it` script without the literal.
- **Don't use `com.$(id -un).*` as the bundle ID prefix.** LaunchServices may reject unsigned bundles claiming that personal-team identity with `_LSOpenURLs… error -600 / procNotFound`. The build script warns; you should reject. Default to `com.user.<slug>` or country-coded reverse-DNS.
- **Don't spawn unlimited servers.** Always check the port for an existing listener before starting a new one.
- **Don't hardcode a port literal in `START_COMMAND` if you want auto-fallback.** Write the command so `PORT` env flows through. Vite needs `--port "$PORT"` (not just `PORT=` env); see [Framework PORT cheat sheet](#framework-port-cheat-sheet).
- **Don't touch app business-logic source files.** Stay in `assets/`, `desktop/`, `scripts/`, `docs/`, `package.json` scripts. **Carve-out:** edits to `vite.config.*` / `next.config.*` / `server/index.{ts,js,py}` to make ports env-driven are expected and necessary — see [Phase 3](#phase-3--build).
- **Don't bundle multiple user-facing apps into one `.app`.** One `.app` per user-facing app.
- **Don't ask the user a question that has a defensible default.** Pick, ship, document.
- **Don't rely on AppKit menu key-equivalents alone for browser-type shortcuts.** WKWebView's multi-process architecture lets it intercept `Cmd+=`, `Cmd+R`, and similar shortcuts before `NSApplication.performKeyEquivalent:` runs. The template's `installKeyboardShortcutMonitor()` fixes this by catching those events first via `NSEvent.addLocalMonitorForEvents`. Do not remove the monitor or move these shortcuts back to menu-only.
- **Don't assume signatures survive iCloud or a macOS update.** Apps in iCloud-synced folders (Desktop, Documents when iCloud Drive is on) accumulate system-protected xattrs that codesign refuses. The `ditto --noextattr` rescue in the Gatekeeper section handles this without rebuilding. Re-sign after every major macOS upgrade if apps show ⊘.
- **Don't claim keyboard shortcuts work without verifying the installed wrapper version.** `wrapper.swift` has had `buildMenu()` since early 2026; apps built before that only get AppKit's default Cmd+Q stub. Any report of missing Cmd+R / zoom / Cmd+W means the installed wrapper is stale — rebuild, don't patch.

---

## Framework PORT cheat sheet

| Framework | Default behavior | What `START_COMMAND` should do |
|---|---|---|
| Next.js (`next dev`) | reads `PORT` env, exits if busy | nothing — works out of the box. **But** check `package.json` `"dev"` for hardcoded `-p N`; if present, replace with `pnpm exec next dev` (or add `dev:app-it`). |
| Vite + React / vanilla Vite (no proxy) | reads config's `server.port` literal; `strictPort: false` silently bumps | `npm run dev -- --host 127.0.0.1 --port "$PORT" --strictPort` — CLI flags win over config literals. No source edits. |
| Vite (cohabiting w/ proxy) | as above, plus proxy target hardcoded | edit `vite.config.ts`: `server.port` reads `process.env.PORT`; `strictPort: true`; `server.proxy.<route>.target` reads `process.env.API_PORT`. |
| SvelteKit | Vite-backed; `PORT` alone is not the reliable contract | `npm run dev -- --host 127.0.0.1 --port "$PORT" --strictPort`. |
| Express (typical) | `process.env.PORT \|\| 3001` | none — works. For cohabiting, rename to `API_PORT` in the entrypoint. |
| Flask | reads `PORT`/`FLASK_RUN_PORT` env | none. |
| CRA (`react-scripts start`) | reads `PORT` env | none. |
| Astro | current releases accept `--port`; older Astro needed the flag | `npm run dev -- --host 127.0.0.1 --port "$PORT"`. |
| Docusaurus | needs `--port` flag | embed `--port "$PORT"`. |

**Recommended PORT-respecting invocations per package manager:**
- pnpm: `pnpm exec <bin>` (bypasses package.json wrapper script)
- npm: `npx <bin>` or `npm exec -- <bin>`
- yarn: `yarn <bin>` or `yarn exec <bin>`
- bun: `bunx <bin>` or `bun x <bin>`
- python: `python -m <module>`

---

## `package.json` script naming

Single-app:
```json
{
  "scripts": {
    "desktop:icons":   "APP_NAME='MyApp' APP_SLUG='myapp' ./scripts/desktop-icons.sh",
    "desktop:build":   "./scripts/desktop-build.sh",
    "desktop:install": "./scripts/desktop-install.sh",
    "desktop:quit":    "./scripts/desktop-quit.sh",
    "desktop:doctor":  "./scripts/desktop-doctor.sh"
  }
}
```

Multi-app (per-app icon variants, aggregate build/install/quit):
```json
{
  "scripts": {
    "desktop:icons:main":    "APP_NAME='Momo' APP_SLUG='momo' ./scripts/desktop-icons.sh",
    "desktop:icons:studio":  "APP_NAME='Momo Studio' APP_SLUG='momo-studio' ./scripts/desktop-icons.sh",
    "desktop:build":         "./scripts/desktop-build.sh",
    "desktop:install":       "./scripts/desktop-install.sh",
    "desktop:quit":          "./scripts/desktop-quit.sh",
    "desktop:doctor":        "./scripts/desktop-doctor.sh"
  }
}
```

For multi-app projects `desktop:doctor` diagnoses one launcher at a time: `npm run desktop:doctor -- <slug>` (it lists the roster and defaults to the first app when no slug is given).

If the project doesn't have `package.json`, expose the same commands via `Makefile` or a top-level shell script.

---

## Documentation (`docs/desktop-launcher.md`)

Always write this file from `templates/desktop-launcher.md.template`. Keep under one screen. The **first** post-title section must be **First launch**:

> ## First launch
> 1. Right-click the app icon and choose **Open**, then click **Open** in the dialog. macOS will remember and skip this on subsequent launches (Gatekeeper, unsigned bundle).
> 2. The first cold start takes 5–15 s while the dev server compiles.
> 3. If a "couldn't be opened" alert appears citing the dev server, open `~/Library/Logs/app-it/<slug>/server.log`. The alert quotes the tail; the full log usually shows the cause.

For chrome-fallback launchers, document `desktop:quit` as the **primary** shutdown command (Cmd+Q does not kill the daemon).

---

## Diagnosing a generated app

`scripts/desktop-doctor.sh` (wired as `desktop:doctor`) lets a user self-diagnose **one** generated launcher long after the build session ended — no agent required. It is the user-facing embodiment of Core principle #8 (*runtime truth beats build-time guess*): the same `server.port`-first, descendant-walk-ownership, read-the-runtime checks the agent runs in Phase 4, packaged as a command the user can run on their own machine and paste straight into a bug report.

**It is a diagnostic, not a fixer.** Read-only by default. Every check is deterministic and local — no network, no installs, no new dependencies — and when a check can't be certain it says "probably" rather than asserting. It reads `scripts/app-it.config.json` the same way `desktop-build.sh`/`desktop-quit.sh` do, so there is no APPS-table drift.

What it checks: config present + no placeholder leakage; bundle id shape (rejects `com.$(id -un).*`); installed/build `.app` present; Info.plist identity; `run` + Mach-O `wrapper` present; `AppIcon.icns` present; ad-hoc signature; quarantine / iCloud signature-breaking xattrs; preferred-vs-runtime port; stale PID; **whether the process on the runtime port is actually in the recorded supervisor's descendant tree** (reuses the launcher's reattach gate); start-command binary resolves on the launcher's augmented PATH; log/state paths; and **template drift** — it feature-probes the installed `wrapper`/`run` against the current `scripts/wrapper.swift`/`run-template.sh` using the `grep -qboa <marker>` idiom (no version stamp needed). `--tail[=N]` appends the last N lines of `server.log`.

**`--fix-safe`** is the only mutating mode, and it is deliberately narrow — it touches **only app-it's own generated state**, never the user's product code, dependencies, framework config, or anything outside app-it's artifacts:
1. stale PID/port files — removed only when the recorded process is dead;
2. this bundle's stale LaunchServices registration — `lsregister -u` the build-path copy, `-f` the install copy (the same operation `desktop-install.sh` performs);
3. the generated `AppIcon.icns` — rebuilt from the user's source image via `desktop-icons.sh` (mtime-aware), then refreshed into the installed bundle and re-signed;
4. `com.apple.quarantine` on the generated `.app` — cleared with a targeted `xattr -dr` that preserves the signature.

It will never kill a running server (that's `desktop:quit`), never run a package install, and never edit config. Scope it to the `app-it` plugin — the `app-it-static` companion has a different runtime model (no dev-server daemon, no PID/port) and would need its own tailored checks.

---

## Cross-platform notes (only if asked)

**Linux** — `~/.local/share/applications/<slug>.desktop` Desktop Entry; `update-desktop-database`.

**Windows** — `.lnk` shortcut via PowerShell pointing at `launcher.bat` mirroring `run-template.sh`. ImageMagick for `.ico`. NSIS or Inno Setup if installer needed.

The Swift WebKit shell is macOS-only. On Windows/Linux, the equivalent is Tauri (Strategy D).

---

## Final report format

End every app-it session with **exactly** this report. No section omitted; "n/a" if truly inapplicable. Inline in chat **and** written to `docs/desktop-launcher.app-it-report.md`.

```markdown
## App-it report

**1. Project type detected:**
<e.g. pnpm monorepo, Vite + React on :5173, Next.js 16 on :3000, no existing desktop config, swiftc available, worktree at .claude/worktrees/<name>/>

**1.5. Name resolution** *(if multiple naming sources disagreed)*
Picked: "<chosen>". Sources surveyed: <folder>, <package.json name>, <metadata.json>, <recent commits>. Reason: <one line>. To override: edit `scripts/app-it.config.json`, then desktop:build && desktop:install.

**2. Apps detected:** <N>
- **<AppName 1>** — <runtime shape, port, start command>

**3. Strategy chosen per app:**
- <AppName 1>: <A1 native | A1 chrome-fallback | A2 static | A3.1 reuse-orchestrator | A3.2 multi-server-template | A3.3 refuse-on-collision | A4 CLI | B | D> — <one-line name>

**4. Why these are the lowest-effort robust approaches:**
<2–4 sentences. What was ruled out and why. Mention if Chrome was ruled out due to Dock-icon/single-instance issues, or chosen because of FSA real-I/O / Chromium-only APIs.>

**5. Files added/changed:**
- `assets/<slug>-icon.png` per app (sources listed in §6)
- `assets/<slug>-polyfill.js` per app *(if FSA polyfill needed)*
- `desktop/<AppName>.app/...`
- `scripts/wrapper.swift`, `scripts/run-template*.sh`, `scripts/info-plist-template.xml`
- `scripts/desktop-build.sh`, `scripts/desktop-icons.sh`, `scripts/desktop-install.sh`, `scripts/desktop-quit.sh`, `scripts/desktop-doctor.sh`
- `scripts/inspect.sh`, `scripts/placeholder-icon-gen.sh` *(if used)*
- `scripts/app-it.config.json`
- *(if A3.2)* `vite.config.ts` / `server/index.ts` edits — env-driven ports
- `package.json` — added scripts
- `docs/desktop-launcher.md`, `docs/desktop-launcher.app-it-report.md`
- `.gitignore` — added: `desktop/`, `assets/icons/build/`, `assets/icons/<slug>/`

**6. Icon source per app:**
- <AppName 1>: `<path>` — <resolution>, <why this beat alternatives>. Considered: <list>.

**7. To change an app icon later:**
Replace `assets/<slug>-icon.png`, then `pnpm desktop:icons:<app> && pnpm desktop:build && pnpm desktop:install`. The install step refreshes the Dock and Finder icon caches automatically.

**8. Build / install / quit commands:**
- Build: `pnpm desktop:build`
- Install: `pnpm desktop:install` (→ ~/Applications/App It/)
- Quit: `pnpm desktop:quit` (stops daemonized servers)
- Diagnose: `pnpm desktop:doctor` (read-only health check; `-- --fix-safe` for generated-state cleanup, `-- <slug>` to pick an app)

**9. Generated launcher locations:**
- Repo: `desktop/<AppName>.app`
- Installed: `~/Applications/App It/<AppName>.app`
- Runtime port (after first click): `~/Library/Application Support/app-it/<slug>/server.port`

**10. Verification (per app):**
- [x] Build succeeded; `.app` exists; wrapper is universal Mach-O; `.icns` is multi-resolution
- [x] Bundle metadata correct (no `__PLACEHOLDER__` leakage)
- [x] Cold launch: `server.port` recorded; HTTP responds on runtime port
- [x] Single instance; `lsappinfo` confirms bundle id
- [x] Cmd+Q (via osascript) kills server tree
- [x] Red-X leaves server warm
- [x] Warm re-launch responds in ~250ms (descendant-walk reattach works)
- [x] Install-path open exits 0; `lsregister` shows exactly one entry
- [ ] needs human: window content, Dock icon identity, autoplay (if media), FSA reconnect (if polyfill)
- [ ] deferred — env hostile: <reason, with user-action one-liner> *(if applicable)*

**11. Dock Stack:**
- [x] `~/Applications/App It/` exists
- [ ] User has dragged `~/Applications/App It/` to the right side of the Dock (one-time setup; mention if not done)

**12. Known limitations:**
- <e.g. unsigned bundle — Gatekeeper warns on first launch>
- <e.g. WebKit, not Chromium — open in regular Chrome for Chromium devtools>
- <e.g. baked PROJECT_ROOT — re-run desktop:build if repo moves>
- <e.g. Chrome fallback used for FSA real-I/O — Dock icon may show Chrome's, re-clicks open duplicates, Cmd+Q does not kill daemon (use desktop:quit)>
- <e.g. worktree — rebuild from main checkout after merge>
- <e.g. arm64+x86_64 universal binary>

## Decision history
- <YYYY-MM-DD>: Initial build (Strategy <X>, bundle-id <Y>, port <P> → fallback to <P'>, icon: <source>).
- <next session appends here>
```

---

## Quick reference — common project signals

| Signal | Strategy | Notes |
|---|---|---|
| `next.config.*`, dev on `:3000` | A1 native | Check `dev` script for `-p N` literal; bypass via `pnpm exec next dev` if found. |
| `vite.config.*` + React deps (`react`, `react-dom`, `@vitejs/plugin-react*`) | A1 native | Vite + React recipe: `START_COMMAND="npm run dev -- --host 127.0.0.1 --port \"\$PORT\" --strictPort"`. |
| `vite.config.*` + existing `dist/` | A2 | Static — `file://` URL, no server. |
| `vite.config.*` no build (vanilla) | A1 native | `START_COMMAND="npm run dev -- --host 127.0.0.1 --port \"\$PORT\" --strictPort"` — CLI flags win over config literals. |
| `vite.config.*` + proxy block | A3.2 | Make ports env-driven (3 vite-config edits + 1 server-entry edit). |
| `svelte.config.*` + `@sveltejs/kit` | A1 native | SvelteKit recipe: Vite-backed dev server, use `--port "$PORT" --strictPort`; do not treat adapter choice as static unless using app-it-static. |
| `astro.config.*` + `astro` dependency | A1 native | Astro recipe: default preferred port 4321, `START_COMMAND="npm run dev -- --host 127.0.0.1 --port \"\$PORT\""`. |
| `concurrently` / `npm-run-all -p` / `turbo run dev` in `dev` | A3.1 | Reuse orchestrator as single START_COMMAND. |
| `apps/web` + `apps/api` (cohabiting, no orchestrator) | A3.2 | Multi-server template. |
| `apps/web` + `apps/studio` (separate) | A1 native × 2 | Two `.app`s. |
| Sanity `sanity.config.*` alongside web | A1 native × 2 | One for web, one for `sanity dev`. |
| `package.json` with `electron` | B | Use `electron-builder`. |
| `src-tauri/` | B | `tauri build`. |
| `index.html` at root, no build | A2 | `file://` URL. |
| `manifest.json` + service worker | A1 native | Build the `.app`; mention PWA install in the doc. |
| Flask / FastAPI | A1 native | Activate venv inside `run` if present; `python -m foo` as `START_COMMAND`. |
| Pure Python CLI (no UI) | A4 | Spawns Terminal — flag in limitations. |
| Existing `electron-builder.yml` | B | Don't add A on top. |
| App uses `showDirectoryPicker` (no real I/O) | A1 native + FSA polyfill | Grep IDB names; customize `fsa-polyfill-template.js`. |
| App reads/writes via `getFile`/`createWritable` | A1 chrome-fallback | Chrome supports FSA natively. Document Cmd+Q-needs-`desktop:quit`. |
| App needs Web USB/Bluetooth/HID/MIDI | A1 chrome-fallback | Chromium-only APIs. |
| `swiftc` not available | A1 chrome-fallback | Suggest `xcode-select --install`; fall back if user can't. |
| Bun (`bun run dev`) | A1 native | Shipped PATH includes `$HOME/.bun/bin`. |
| Worktree (`.claude/worktrees/<name>/`) | strategy depends | See Phase 1 step 1 — bypass / env-override / bake-and-document. |
