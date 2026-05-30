# app-it

Turn a local web project into a macOS Dock-launchable `.app` bundle.

`app-it` is an assistant-agnostic plugin/skill for local developer workflows. It works with Claude Code and Codex, and creates a small, repeatable launcher around an existing local project so double-clicking an app starts the dev server, opens a native window, keeps the Dock icon as your app, and cleans up when you quit.

It is not Electron, Tauri, notarization, auto-update, App Store packaging, or a way to distribute finished apps to customers.

## What It Does

- Inspects a project before touching files.
- Chooses a launcher strategy for Vite, Next.js, static sites, and multi-server local apps.
- Copies proven launcher templates into the target project.
- Builds a macOS `.app` bundle with a Swift `WKWebView` shell by default.
- Falls back to Chrome app mode when the project needs Chromium-only browser APIs.
- Installs generated apps into `~/Applications/App It/` by default.
- Writes a report explaining what changed and how to undo it.

## Requirements

- macOS.
- Claude Code or Codex for marketplace installation.
- `swiftc` from Xcode Command Line Tools for the native WebKit shell.
- Chrome only when the project needs the Chrome fallback path.

Install Xcode Command Line Tools if needed:

```bash
xcode-select --install
```

## Install

After this repo is public on GitHub, install it in the assistant you use.

Claude Code:

```text
claude plugin marketplace add Christian-Katzmann/app-it
claude plugin install app-it@app-it
```

Codex:

```text
codex plugin marketplace add Christian-Katzmann/app-it
codex plugin add app-it@app-it
```

For local development before publication:

```text
claude plugin marketplace add /path/to/app-it
claude plugin install app-it@app-it

codex plugin marketplace add /path/to/app-it
codex plugin add app-it@app-it
```

## Manual Skill Install

Marketplace install is preferred. If you only want the skill folder:

```bash
cp -R plugins/app-it/skills/app-it ~/.claude/skills/app-it
cp -R plugins/app-it/skills/app-it ~/.codex/skills/app-it
```

Reload your tool, then ask:

```text
/app-it
```

Natural triggers also work: "make this clickable from the Dock", "give this an icon", "dockify this", or "package this as a local app".

## What It Adds To A Target Project

Typical additions:

- `scripts/app-it.config.json`
- `scripts/desktop-build.sh`
- `scripts/desktop-install.sh`
- `scripts/desktop-quit.sh`
- `scripts/wrapper.swift`
- `assets/<slug>-icon.png` or `assets/<slug>-icon.svg`
- `desktop/<App Name>.app/`
- `docs/desktop-launcher.md`
- `docs/desktop-launcher.app-it-report.md`
- `package.json` scripts for `desktop:build`, `desktop:install`, and `desktop:quit`

The generated `desktop/` bundle and icon build artifacts should be gitignored in the target project.

By default, installed apps are copied to `~/Applications/App It/`. Users who prefer a Dock Stack can drag that folder to the right side of the Dock once. Advanced users can override the destination with `APP_IT_INSTALL_DIR`.

## Safety Model

`app-it` should only make additive, reversible changes. It should not rewrite product logic, add runtime dependencies, require a terminal window to stay open, or assume an already-running dev server.

It may start and stop local dev-server processes during verification. It should never collect telemetry, send project data to a service, or handle secrets.

## Platform Scope

This plugin is macOS-only by design. Windows is not a small variation of the same thing: it needs WebView2 or Edge app mode, `.lnk` or Start Menu integration, `.ico` assets, PowerShell process control, and SmartScreen/signing guidance. That should be a separate plugin rather than a blurred cross-platform promise.

See [Compatibility](docs/COMPATIBILITY.md).

## Validate This Repo

```bash
./scripts/validate.sh
```

The validation script checks manifest shape, shell syntax, template presence, plist syntax, Swift typechecking, and Claude plugin validation when the `claude` CLI is available.

## Troubleshooting

See [Troubleshooting](docs/TROUBLESHOOTING.md).

## License

MIT.
