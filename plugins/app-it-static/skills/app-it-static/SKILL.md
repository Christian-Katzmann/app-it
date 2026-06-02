---
name: app-it-static
description: >-
  Turn a finished or buildable web app into a macOS Dock-launchable `.app` that
  serves the built output — with no dev server. Use when the user asks to make a
  built site, a finished app, or a `dist/`/`build/`/`out/` bundle clickable from
  the Dock, or wants a lighter launcher for an app that no longer needs live
  editing. Detects the build command and output directory, builds once, then
  serves the result from a tiny static server (~15 MB) or directly via `file://`
  (~0 MB) — instead of the 300-700 MB a dev server holds. Reuses app-it's native
  Swift WebKit window, icon pipeline, and one-folder Dock install. The served
  output is a snapshot — `desktop:rebuild` refreshes it. macOS only. For apps
  that still need a live dev server (half-built, reading local files, no build
  step), use the **app-it** skill instead.
---

# app-it-static — Make a finished build launchable from the Dock (no dev server)

> **The companion to app-it.** `app-it` makes a *live, in-progress* project
> clickable by booting its dev server. `app-it-static` makes a *finished or
> buildable* app clickable by serving its **built output** — no dev server, no
> bundler in memory. Same native window, same Dock Stack, a fraction of the RAM.
> If the project is half-built, reads local files at dev time, or has no build
> step, that's app-it's job, not this one.

## Why this exists

A dev server (Vite/Next dev) keeps a bundler, file-watcher, and transpiler
resident — typically **300–700 MB per app**. A finished build is just files.
Serving them costs **~15 MB** (a tiny static server) or **~0 MB** (`file://`,
no server at all). For someone with a dozen finished little apps on their Dock,
that's the difference between a few hundred megabytes and several gigabytes.

This is the **local** answer to "finished apps shouldn't need a full dev server."
No cloud, no Vercel, no PWA step — which also means it works in corporate
environments where external hosting isn't approved.

## Core principles

1. **Minimum work for the user. Maximum repeatability. No over-engineering.** Same bar as app-it.
2. **Decide. Don't ask** — except before the one genuinely expensive/destructive step (running the project's build). Building a `.app` is reversible; a project build writes files and takes time. Confirm before the first build; everything else, pick the default and ship it.
3. **No dev server. Ever.** This skill never runs `npm run dev`. It runs `npm run build` **once**, then serves the result. If a project can't be served without a live dev server, it's the wrong skill — route to app-it.
4. **Serve a snapshot, and say so.** The launcher serves the build as it was at build time. Source changes don't appear until `desktop:rebuild`. This honesty is the defining difference from app-it — lead with it, never hide it.
5. **Lightest correct serve mode.** Prefer `file://` (zero server) when the build is confirmed file://-safe; otherwise a tiny static server (~15 MB). Never heavier than it needs to be.
6. **The `.app` keeps its own Dock icon.** Same native Swift `WKWebView` shell as app-it — the foreground process is ours, so the Dock icon, single-instance activation, and menu bar are ours.
7. **One folder, one Dock Stack.** Installs to `~/Applications/App It/` — the *same* Stack app-it uses, so static and live apps live side by side. Override with `APP_IT_INSTALL_DIR`.
8. **Trust disk over docs.** Verify the build tool and output dir from `package.json` + config files, not from `README.md`. If docs and disk disagree, trust disk and note it.

The user almost never wants:
- A dev server for a finished app (the whole point is to avoid it).
- A new bundler, runtime dependency, or framework migration.
- A Vercel/PWA/deployment pipeline — this is local-only by design.
- To be asked a question that has a defensible default.

## When to use this skill

Trigger on any of: "make this built site an app", "serve the build from the Dock",
"finished app launcher", "lighter app-it", "this doesn't need a dev server",
"app-it-static", "static .app", "serve dist/ as an app", "make this `out/`/`build/` clickable".

Use **app-it** instead when:
- The project is half-built or still being edited live.
- It reads local files / a local DB at dev time that only the dev server wires up.
- It has no build step and only runs via `npm run dev`.
- A live, auto-reloading window is the actual goal.

Do **not** use this skill for:
- Deploying to Vercel/Netlify or generating a PWA — out of scope on purpose.
- Distribution to other users (signing, notarization, App Store, auto-update).
- Native rewrites or feature additions.

---

## Templates folder

This skill ships working templates next to `SKILL.md`. Copy them into the project
and customize via `app-it.config.json` — don't rewrite them.

```
templates/
  wrapper.swift                    # native WKWebView shell — SHARED, identical to app-it's
  info-plist-template.xml          # Info.plist with placeholders — SHARED, identical to app-it's
  desktop-icons.sh                 # AppIcon.icns generator — SHARED, identical to app-it's
  desktop-icons-preview.sh         # preview a source icon at Dock sizes + warnings — SHARED, identical to app-it's
  desktop-install.sh               # install to ~/Applications/App It/ — SHARED, identical to app-it's
  placeholder-icon-gen.sh          # last-resort icon generator — SHARED, identical to app-it's
  static-server.py                 # tiny zero-dependency static server (SPA fallback)
  run-template-static-server.sh    # launcher → static-server.py → wrapper  (server mode, default)
  run-template-static-file.sh      # launcher → wrapper at file://           (file mode, zero server)
  desktop-build.sh                 # assembles the .app around a built output
  desktop-quit.sh                  # stops warm static servers + wrapper windows
  desktop-rebuild.sh               # re-runs build_command, then build + install
  inspect-static.sh                # Phase-1 read-only probe (build tool, output dir, serve mode)
  app-it.config.example.json       # single source of truth — copy + customize
  desktop-launcher.md.template     # user-facing doc
```

The six **SHARED** templates are byte-identical to app-it's and CI guards them
against drift. Don't edit them here — if launcher internals need changing, change
app-it's copy and re-sync, so both skills stay in step.

---

## Workflow

Phases run in order.

### Phase 1 — Inspect (read-only)

**Run `templates/inspect-static.sh` first.** It reports the package manager,
the framework → build-command → output-dir mapping, any existing built output,
a `serve_mode` hint, and toolchain availability. Read it before deciding.

Then confirm:

1. **Is this actually a static-servable app?** It is if it has a build step that
   emits a self-contained directory with `index.html` (`dist/`, `build/`, `out/`),
   or it's a hand-written static site (`index.html` at root). It is **not** if it
   needs a live dev server to function (server-rendered Next without `output:
   'export'`, an app whose only entry is `npm run dev`, a project that reads local
   files through dev-server middleware). If not → **route to app-it** and say why.
2. **Build command + output dir.** See [Build-output detection](#build-output-detection). Verify from config files, not docs.
3. **Already built?** If a fresh `dist/`/`build/`/`out/` with `index.html` already exists and the user just wants it served, you may skip the build (note it). Otherwise a build is needed.
4. **Serve mode.** Default `server`. Choose `file` only when the build is confirmed file://-safe — see [Serve mode](#serve-mode-server-vs-file).
5. **Multi-app?** A monorepo can produce several finished apps. Build one `.app` per user-facing app, each with its own `static_dir`. Don't bundle them.
6. **Name, bundle-id, icon, install path.** Same rules as app-it: human name from the user's vocabulary; bundle-id `com.user.<slug>` (**never** `com.$(id -un).*`); best square icon source (see app-it's asset-discovery rules, or `placeholder-icon-gen.sh`); install to `~/Applications/App It/`.
7. **Toolchain.** `swiftc` (for the native window) and `python3` (for server mode) must be present. Both come with the Xcode Command Line Tools; if missing, stop and say `xcode-select --install`.

### Phase 2 — Decide

For each app:
- **serve_mode = `server`** (default) — serves the build via `static-server.py`. Always correct. Handles absolute asset paths, client-side routing, local `fetch`, and service workers. ~15 MB.
- **serve_mode = `file`** — loads the build directly via `file://`. Zero server, ~0 MB. Use **only** when confirmed file://-safe.

```
Build needs an http origin?  (absolute asset paths / client-side routing /
fetch() of local files / service worker)
├── YES → serve_mode = server   (default, safe)
└── NO  → serve_mode = file      (zero-server, only when all four are absent)
```

When unsure, pick `server`. It is never wrong; `file` is an optimization.

### Phase 3 — Build

This is the only phase with an expensive step. **Confirm the build with the user
before running it** (it writes files and can take a while). Then:

1. **Run the project's build once** (`build_command`, e.g. `npm run build`) from the project root. Confirm the output dir now contains `index.html`.
2. **Copy templates** into `scripts/` and write `scripts/app-it.config.json` (see below).
3. **Assemble** the `.app` with `desktop:build`, then `desktop:install`.

Allowed additions (all additive, reversible):
- `scripts/wrapper.swift`, `scripts/info-plist-template.xml`, `scripts/static-server.py`, `scripts/run-template-static-*.sh`, `scripts/desktop-*.sh`, `scripts/inspect-static.sh`, `scripts/placeholder-icon-gen.sh`.
- `scripts/app-it.config.json` — single source of truth.
- `assets/<slug>-icon.{png,svg}`; `assets/icons/` (gitignore).
- `desktop/<AppName>.app/` (gitignore — regenerated by build).
- `docs/desktop-launcher.md`, `docs/desktop-launcher.app-it-static-report.md`.
- `package.json` scripts: `desktop:build`, `desktop:icons`, `desktop:install`, `desktop:quit`, `desktop:rebuild`.

**Never:**
- Run `npm run dev` or add a dev-server path.
- Modify app business-logic source. (Unlike app-it, there are **no** port/proxy carve-out edits — a static build doesn't need them. If a project would need source edits to serve statically, it's an app-it project.)
- Add runtime dependencies. `static-server.py` is Python stdlib only.
- Hardcode home paths except as overridable defaults.

**Single source of truth: `scripts/app-it.config.json`**

```json
{
  "apps": [
    {
      "name": "Fjord",
      "slug": "fjord",
      "serve_mode": "server",
      "static_dir": "dist",
      "port": 4100,
      "bundle_id": "com.user.fjord",
      "version": "0.1.0",
      "build_command": "npm run build"
    }
  ]
}
```

`desktop-build.sh`, `desktop-quit.sh`, and `desktop-rebuild.sh` all read this file.
`build_command` is used only by `desktop:rebuild`.

### Phase 4 — Verify (mandatory)

Per app. Two buckets — never claim success in a bucket you can't verify.

| # | Check | Programmatic | Idiom |
|---|---|---|---|
| 1 | Build output exists | `[x]` | `test -f "$PROJECT_ROOT/<static_dir>/index.html"` |
| 2 | `.app` built | `[x]` | `.app` exists; `file <wrapper>` reports `Mach-O … executable`; `.icns` is `Mac OS X icon` |
| 3 | Bundle metadata | `[x]` | `PlistBuddy -c 'Print CFBundleIdentifier'`; no `__PLACEHOLDER__` left |
| 4 | **(server mode)** Runtime port recorded | `[x]` | after first open, `cat ~/Library/Application Support/app-it/<slug>/server.port` |
| 5 | **(server mode)** Server responds | `[x]` | `curl -sS -o /dev/null -w "%{http_code}" http://localhost:$RUNTIME_PORT` is non-`000` |
| 6 | **(server mode)** Cmd+Q frees the port | `[x]` | `osascript -e 'tell application id "<bundle-id>" to quit'`; `lsof -ti tcp:$RUNTIME_PORT` empty within 2s |
| 7 | Install-path opens cleanly | `[x]` | `open "$HOME/Applications/App It/<App>.app"; echo "exit=$?"` is `0` |
| 8 | Window shows the built app (not a 404 / blank) | `[ ] needs human` | unless a display is available |
| 9 | Dock icon is OUR icon | `[ ] needs human` | unless a display is available |

**Pre-flight smoke test** (separates project-broken from launcher-broken): for
server mode, run `STATIC_DIR="$PROJECT_ROOT/<static_dir>" PORT=$SMOKE python3 scripts/static-server.py`,
`curl` it, then kill. For file mode, confirm `index.html` exists and its asset
paths are relative. If the smoke test fails, report build-broken, not launcher-broken.

If GUI verification is impossible (no display), say so under Known limitations —
don't claim the window renders.

### Phase 5 — Report

Two outputs: an inline chat report (format below) and the same content written to
`docs/desktop-launcher.app-it-static-report.md` with a `## Decision history`
section future sessions append to. Stage new files with `git add`; don't commit
unless asked.

---

## Build-output detection

Verify from disk. Default package-manager-aware `build` command; default output dir:

| Signal | Build command | Output dir | serve_mode default |
|---|---|---|---|
| `vite.config.*` | `<pm> build` | `dist/` | server (Vite uses absolute `/assets/` paths) |
| `astro.config.*` (static, the default) | `<pm> build` | `dist/` | server |
| `astro.config.*` **with** `output: 'server'`/`'hybrid'` | — | — | **route to app-it** (SSR, not static) |
| `react-scripts` in `package.json` (CRA) | `<pm> build` | `build/` | server (CRA uses absolute `/static/`) |
| `svelte.config.js` with `adapter-static` | `<pm> build` | `build/` | server |
| `svelte.config.js` **without** `adapter-static` | — | — | **route to app-it** (SSR by default) |
| `next.config.*` **with** `output: 'export'` | `<pm> build` | `out/` | server |
| `next.config.*` **without** export | — | — | **route to app-it** (needs a server) |
| `vue.config.js` | `<pm> build` | `dist/` | server |
| `angular.json` | `<pm> build` | `dist/<project>/browser/` (v17+) | server (absolute base href) |
| `nuxt.config.*` via `nuxi generate` | `<pm> generate` | `.output/public/` | server |
| `nuxt.config.*` plain `nuxt build` | — | — | **route to app-it** (SSR / Nitro) |
| `index.html` at root, no build tool | none (`build_command: ""`) | `.` | file if relative paths, else server |
| existing `dist/`/`build/`/`out/` + `index.html` | optional (serve as-is) | that dir | inspect `index.html` |

`<pm>` resolves from the lockfile: `pnpm-lock.yaml`→`pnpm build`, `yarn.lock`→`yarn build`,
`bun.lockb`→`bun run build`, `package-lock.json`/none→`npm run build`.

**Next.js caveat (important):** a standard Next app server-renders and **cannot**
be served as static files. Only with `output: 'export'` in `next.config.*` does it
emit a static `out/`. Without it, this is an app-it (dev-server) project — say so
plainly rather than producing a broken static `.app`.

---

## Serve mode: server vs file

`file://` is the lightest possible launcher (no process at all), but it breaks for
most framework builds. Use it only when **all four** hold:

- **Relative asset paths.** `./assets/...`, not `/assets/...`. `file://` resolves
  absolute paths against the filesystem root → 404. (Vite/CRA default to absolute;
  Vite needs `base: './'`, CRA needs `"homepage": "."` to go relative — note this
  in the report rather than editing their config.)
- **No client-side routing** that needs deep-link rewrites — `file://` has no
  server to fall back to `index.html`.
- **No `fetch()` of local files** — `file://` origin is `null`, so CORS blocks it.
- **No service worker** — won't register on `file://`.

If any fail, use `server`. The bundled `static-server.py` handles all four
(SPA-fallback to `index.html`, correct MIME types, a real http origin) for ~15 MB.

**Don't fight `file://`.** If a build wants an http origin, give it the tiny
server — don't rewrite the app to make `file://` work.

---

## Anti-patterns

- **Don't run `npm run dev`.** That's app-it. This skill builds once and serves the result.
- **Don't claim live reload.** A static `.app` serves a snapshot. Say it plainly; point at `desktop:rebuild`.
- **Don't default to `file://` for framework builds.** Most use absolute asset paths or client routing and will show a blank/404 window. Default to `server`; use `file` only when confirmed safe.
- **Don't try to statically serve a server-rendered Next app.** Without `output: 'export'` there's no static output. Route to app-it.
- **Don't add runtime dependencies.** `static-server.py` is stdlib only; `python3` already ships with the Xcode CLT this skill requires.
- **Don't edit app source to force static serving.** app-it edits `vite.config`/`server` for env-driven ports; this skill does **not** — a static build that needs source edits is an app-it project.
- **Don't bind the static server to `0.0.0.0`.** `127.0.0.1` only. This is a personal launcher, not a host. (`static-server.py` enforces this.)
- **Don't run the project build inside `desktop-build.sh`.** Build once (Phase 3 / `desktop:rebuild`); `desktop:build` only assembles the bundle, so routine rebuilds stay fast and side-effect-free.
- **Don't use `com.$(id -un).*` as the bundle-id prefix.** LaunchServices may reject it (error -600). Use `com.user.<slug>`.
- **Don't derive `PROJECT_ROOT` from `$0`.** The `.app` is copied to `~/Applications/App It/` on install — bake the absolute path at build time.

---

## `package.json` script naming

```json
{
  "scripts": {
    "desktop:icons":         "APP_NAME='Fjord' APP_SLUG='fjord' ./scripts/desktop-icons.sh",
    "desktop:icons:preview": "APP_NAME='Fjord' APP_SLUG='fjord' ./scripts/desktop-icons-preview.sh",
    "desktop:build":         "./scripts/desktop-build.sh",
    "desktop:install":       "./scripts/desktop-install.sh",
    "desktop:quit":          "./scripts/desktop-quit.sh",
    "desktop:rebuild":       "./scripts/desktop-rebuild.sh"
  }
}
```

If the project has no `package.json` (hand-written static site), expose the same
commands via a `Makefile` or top-level shell script.

---

## Final report format

End every session with this report. No section omitted; "n/a" if truly inapplicable.
Inline in chat **and** written to `docs/desktop-launcher.app-it-static-report.md`.

```markdown
## App-it-static report

**1. Project type detected:**
<e.g. Vite + React, build → dist/, pnpm; or hand-written static site at root; swiftc + python3 available>

**2. Static-servable?** <yes / no — if no, why, and "use app-it instead">

**3. Apps detected:** <N>
- **<AppName>** — serves `<static_dir>/`, serve_mode <server|file>, build `<build_command>`

**4. Serve mode per app + why:**
- <AppName>: <server|file> — <one line: e.g. "absolute /assets/ paths need an http origin" or "relative paths, no routing → file://, zero server">

**5. Build:**
- Command run: `<build_command>` <(skipped — fresh output already present)>
- Output confirmed: `<static_dir>/index.html`

**6. Files added/changed:** <scripts/*, assets/<slug>-icon.png, desktop/<App>.app, docs/*, package.json scripts, .gitignore>

**7. Icon source:** <path — resolution, why it beat alternatives>

**8. Commands:**
- Build: `<pm> desktop:build`   Install: `<pm> desktop:install` (→ ~/Applications/App It/)
- Refresh snapshot: `<pm> desktop:rebuild`   Stop server: `<pm> desktop:quit`

**9. Verification (per app):**
- [x] Build output exists; `.app` built; wrapper universal Mach-O; `.icns` multi-resolution
- [x] Bundle metadata correct (no `__PLACEHOLDER__`)
- [x] (server) server responds on runtime port; Cmd+Q frees it
- [x] Install-path open exits 0
- [ ] needs human: window renders the app, Dock icon identity

**10. Known limitations:**
- Snapshot, not live — re-run `desktop:rebuild` after source changes.
- Unsigned bundle — Gatekeeper warns on first launch (right-click → Open once).
- Baked PROJECT_ROOT — rebuild if the repo moves.
- WebKit, not Chromium.
- <serve_mode=file: relative-path requirement; serve_mode=server: ~15 MB resident while warm>

## Decision history
- <YYYY-MM-DD>: Initial build (serve_mode <X>, static_dir <Y>, build `<cmd>`, port <P>, icon: <source>).
```

---

## Quick reference

| Signal | Decision |
|---|---|
| `vite.config.*`, no special base | server, `dist/` |
| `vite.config.*` with `base: './'` + no routing/fetch | file candidate, `dist/` |
| CRA (`react-scripts`) | server, `build/` |
| Astro (static, default) | server, `dist/` |
| Astro with `output: 'server'`/`'hybrid'` | **app-it** (SSR) |
| SvelteKit + `adapter-static` | server, `build/` |
| SvelteKit without `adapter-static` | **app-it** (SSR) |
| Next with `output: 'export'` | server, `out/` |
| Next without export | **app-it** (dev server) |
| Angular (`angular.json`) | server, `dist/<project>/browser/` |
| Nuxt via `nuxi generate` | server, `.output/public/` |
| Nuxt plain `nuxt build` | **app-it** (SSR) |
| hand-written `index.html`, relative assets | file, `.` |
| existing `dist/` the user just wants served | inspect `index.html`, usually server, skip build |
| project only runs via `npm run dev` | **app-it** |
| needs source edits to serve statically | **app-it** |
| `swiftc` missing | stop — `xcode-select --install` |
