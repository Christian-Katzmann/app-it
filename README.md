# app-it

Turn a local web project into a macOS Dock-launchable `.app` bundle — a native window, its own Dock icon, and clean start/stop — **without Electron, Tauri, or a rewrite.**

![A real app-it build in motion: double-click the Fjord demo's Dock icon, its native window opens, ⌘Q quits and frees the port](design/motion/app-it-lifecycle.gif)

*A real `app-it` build, in motion. `Fjord` is an ordinary local web project (`node server.js`); app-it turns it into a native macOS app — double-click launches it, the window opens with its own Dock icon, and ⌘Q quits the app **and** frees the dev-server port. The actual generated app, not a mockup.*

**Status** — Working, in daily use. The launcher templates are battle-tested across 12+ real projects; `v0.1.0` is the first standalone, marketplace-installable release. macOS only, by design.

**Windows beta** — macOS is in daily use; Windows is an early beta, now with its first real-hardware validation but still needing more. A complete sibling plugin (`plugins/app-it-windows/`), gated by a required `windows-latest` CI job (build · PowerShell lint · manifest parse · icon round-trip), mirrors the macOS contract with Windows primitives. The author runs only macOS, so for a long time it had never touched real Windows hardware; that changed with [#8](https://github.com/Christian-Katzmann/app-it/pull/8), the first run on an actual Windows machine (fixing a WebView2 window-title bug) — a real first step, not a finish line. If you're on Windows and want to help harden it, the doorway is [docs/WINDOWS.md](docs/WINDOWS.md).

**Local-only** — app-it reads your project *on your machine* to choose a launcher strategy. It uploads nothing, runs no telemetry, adds no runtime dependencies, and never touches your business-logic source. The only thing it produces is an `.app` on your own Dock.

`app-it` is an assistant-agnostic plugin/skill. It works with **Claude Code** and **Codex**, and builds a small, repeatable launcher around an existing local project so that double-clicking starts the dev server, opens a native window, keeps the Dock icon as *your* app, and cleans up when you quit.

## What app-it is not

- **Not Electron, Tauri, or a native rewrite.** It wraps your existing dev setup; it doesn't replace it, migrate it, or add a bundler to your dependency tree.
- **Not a way to ship apps to other people.** No notarization, no App Store, no auto-update, no signed distribution. These are personal, ad-hoc-signed, local-use launchers.
- **Not cross-platform.** macOS only — and on purpose. Windows is a genuinely different problem (WebView2, `.lnk`, `.ico`, SmartScreen), so it belongs in a separate plugin rather than a blurred promise. See [Compatibility](docs/COMPATIBILITY.md).
- **Not a hosted service.** Nothing runs in the cloud and there is no live demo to visit — the proof is the apps on your own Dock (the Stack further down is real).

## How it works

```text
  WHAT YOU HAVE               WHAT APP-IT DOES           WHAT YOU GET
  ───────────────────────     ──────────────────────     ───────────────────────────
  a local web project         inspects it from disk,     YourApp.app on your Dock
  Vite, Next, or a static     picks a strategy, then     · its own icon
  site, run with          ──▶ builds & signs a .app  ──▶ · native window, one click
  `npm run dev` in a tab      around a WebKit shell      · ⌘Q quits & frees the port
```

Under the hood, app-it:

- **Inspects before it touches anything** — project type, dev scripts, ports, browser-API needs, icon sources.
- **Picks a launcher strategy** — a native Swift `WKWebView` shell by default (so the Dock icon stays *yours*), Chrome `--app` mode only when a project needs Chromium-only APIs.
- **Copies proven, hard-won templates** into the project rather than re-deriving fragile launcher logic each time.
- **Builds and ad-hoc-signs a real `.app`** — universal (arm64 + x86_64), Gatekeeper-friendly, with a generated `.icns`.
- **Gets the lifecycle right** — closing the window (⌘W / red-X) leaves the dev server warm for a ~250 ms re-launch; ⌘Q quits the app *and* frees the port.
- **Writes a report** explaining every change and exactly how to undo it.

> **Finished app? There's a lighter companion.** `app-it` runs your project's dev server — perfect while you're still building. Once an app is *done*, it doesn't need one: the **`app-it-static`** companion serves the built output (`dist/`, `build/`, `out/`, …) so a finished app costs ~15 MB instead of a dev server's ~300–700 MB. Same native window, same Dock Stack — reach for it only when an app is done. [How it works →](plugins/app-it-static/skills/app-it-static/SKILL.md)

## Requirements

- macOS.
- Claude Code or Codex for marketplace installation.
- `swiftc` (Xcode Command Line Tools) for the native WebKit shell — `xcode-select --install`.
- `python3` (also from the Xcode Command Line Tools) for `app-it-static`'s server mode.
- Chrome only if a project needs the Chrome fallback path.

## Install

**Claude Code:**

```text
claude plugin marketplace add Christian-Katzmann/app-it
claude plugin install app-it@app-it
```

**Codex:**

```text
codex plugin marketplace add Christian-Katzmann/app-it
codex plugin add app-it@app-it
```

Then, from inside any local web project, ask your assistant:

```text
/app-it
```

Natural triggers work too: *"make this clickable from the Dock"*, *"give this an icon"*, *"dockify this"*, *"package this as a local app"*.

*Optional:* for finished apps, also install the lighter companion — `claude plugin install app-it-static@app-it` (or `codex plugin add app-it-static@app-it`), then run `/app-it-static`.

### Local development (before publication)

```text
claude plugin marketplace add /path/to/app-it
claude plugin install app-it@app-it

codex plugin marketplace add /path/to/app-it
codex plugin add app-it@app-it
```

### Manual skill install

Marketplace install is preferred. To copy just the skill folder:

```bash
./install.sh            # auto-detects Claude Code and/or Codex, asks before overwrite
./install.sh --dry-run  # show what it would do, write nothing
```

## What it adds to a target project

All additions are additive and reversible:

- `scripts/app-it.config.json` — single source of truth for the app(s)
- `scripts/desktop-build.sh`, `desktop-install.sh`, `desktop-quit.sh`, `wrapper.swift`, …
- `assets/<slug>-icon.png` or `.svg`
- `desktop/<App Name>.app/` *(gitignored — regenerated by the build)*
- `docs/desktop-launcher.md` and an `app-it-report.md` decision log
- `package.json` scripts: `desktop:build`, `desktop:install`, `desktop:quit`

Installed apps land in `~/Applications/App It/` by default. Drag that folder to the right side of the Dock once and every future appified app appears in its Stack automatically. Override with `APP_IT_INSTALL_DIR`.

![A real MyApps Dock Stack — Mission Control, Campaigns, monëy, Heartbeat, Repo Hunter and more, each with its own icon](design/screenshots/01-myapps-stack.jpg)

*A real `MyApps` Stack, not a mockup. Every icon is an ordinary local web project app-it turned into a native app — its own icon, its own window, one click to launch. Do this a dozen times and your Dock fills itself.*

## Safety model

`app-it` only makes additive, reversible changes. It will not rewrite product logic, add runtime dependencies, require a terminal window to stay open, or assume an already-running dev server. It may start and stop local dev-server processes during verification. It never collects telemetry, sends project data anywhere, or handles secrets. See [SECURITY.md](SECURITY.md).

## Validate this repo

```bash
./scripts/validate.sh
```

This is the one-command check: it validates manifest shape, shell syntax, template presence, plist syntax, Swift typechecking, and Claude plugin validation (when the `claude` CLI is available). CI runs the same script on `macos-latest`.

## For AI agents

This repo *is* agent tooling, and agents are expected to work in it. Start with [AGENTS.md](AGENTS.md) — it names the non-obvious conventions (templates are canonical, trust disk over docs, the macOS-only boundary) and the safe first commands. Architectural decisions and their rejected alternatives live in [docs/decisions/](docs/decisions/).

## More

- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Compatibility](docs/COMPATIBILITY.md)
- [Changelog](CHANGELOG.md) · [Contributing](CONTRIBUTING.md)

## Community nudge

The `app-it-static` companion was inspired by feedback from the r/ClaudeAI launch thread, and the project keeps growing on community help. Thanks to:

- **`TechExpert2910`** for pointing out that finished apps shouldn't need a full dev server, and that Vercel/PWA-style workflows are far lighter — the nudge that became "serve the build locally, not a dev server."
- **`K_M_A_2k`** for highlighting that deployed/static proof-of-concepts are often the standard workflow and are easier to share.
- **`Vo_Mimbre`** for the corporate-environment caveat: external hosting like Vercel isn't always approved, which is exactly why a *local* static launcher earns its place even for finished projects.
- **`Firnschnee`** for the first real-hardware Windows validation, fixing the WebView2 window-title bug and proving the Windows beta actually runs.

## License

MIT — see [LICENSE](LICENSE).
