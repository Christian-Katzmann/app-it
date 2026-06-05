# Compatibility

## Supported

`app-it` supports macOS local developer workflows.

| Area | Support |
| --- | --- |
| OS | macOS |
| Primary shell | Swift `WKWebView` wrapper |
| Fallback shell | Chrome `--app` mode |
| Common targets | Vite + React, SvelteKit, Astro, Next.js, static sites, local multi-server apps, hosted web app URLs (e.g. a published Claude Artifact) |
| Install destination | `~/Applications/App It/` by default |
| Signing | Ad-hoc local code signing only |

## Hosted web app (URL-only) wrappers

`app-it` can build a URL-only `.app` around a hosted web app — a deployed
dashboard, an internal tool, or a published/shared Claude Artifact. The path
intentionally keeps the host in charge of authentication and runtime: the bundle
loads the hosted URL, the user signs in inside the app window, and usage belongs
to that user's own account. For a Claude Artifact, the host is `claude.ai` and
the artifact's runtime APIs stay with Claude.

Raw JSX/TSX exported from an artifact is only a normal local web app source
file. If it calls Claude's hosted artifact APIs (`window.claude`,
`window.storage`, MCP prompts, or Claude-provided auth), do not shim credentials,
cookies, or API keys into the local bundle. Publish/share the artifact in Claude
and set `external_url` or `artifact_url` in `scripts/app-it.config.json`.

## Companion · `app-it-static`

For **finished or buildable** apps, the `app-it-static` sibling plugin serves the
built output instead of booting a dev server — a tiny static server (~15 MB) or
`file://` (~0 MB), versus the 300–700 MB a dev server holds.

| Area | Support |
| --- | --- |
| OS | macOS |
| Shell | Swift `WKWebView` wrapper (shared with `app-it`, byte-identical) |
| Serve modes | tiny `static-server.py` (default) · `file://` (zero-server, when build is flat) |
| Common targets | Vite, CRA, Astro, SvelteKit (static adapter), Next (`output: 'export'`), hand-written static sites |
| Extra requirement | `python3` (server mode) — ships with the Xcode Command Line Tools |
| Model | serves a **snapshot**; `desktop:rebuild` refreshes it |

Use `app-it` when the project is still live/in-progress; use `app-it-static` once
it's finished. See [ADR 0006](decisions/0006-static-companion-snapshot-model.md).

## Beta · maintainer wanted

| Area | Support |
| --- | --- |
| OS | Windows — **beta · scaffolded · untested on real hardware** |
| Plugin | `plugins/app-it-windows/` (sibling of the macOS plugin) |
| Primary shell | C# WPF + WebView2 host → self-contained single-file `.exe` |
| Fallback shell | Edge `--app=` mode |
| Install destination | `app-it\` Start Menu group via `.lnk` |
| Status | Build + lint gated by a required `windows-latest` CI job; **nobody has run it on Windows yet** |

The author runs only macOS and will not dogfood the Windows build, so it ships as an honest beta looking for a maintainer rather than a finished feature. Everything a Mac can produce is built and CI-guarded; everything that needs real hardware to confirm is marked as deferred. See **[docs/WINDOWS.md](WINDOWS.md)** for what works in theory, what a first PR looks like, and how to claim a check.

## Not Supported

- Linux desktop launchers.
- App Store packaging.
- Notarized distribution to other users.
- Auto-update.
- Installer generation.
- Local redistribution of Claude Artifact auth, session cookies, or API keys.
- Production Electron or Tauri migrations.

## Why Windows Should Be Separate

Windows is not just macOS with different paths. A serious Windows version needs:

- WebView2 or Edge app mode instead of `WKWebView`.
- `.lnk` shortcuts and Start Menu behavior instead of `.app` bundles and LaunchServices.
- `.ico` asset generation instead of `.icns`.
- PowerShell/process-job handling instead of `osascript`, `lsof`, and macOS app lifecycle hooks.
- SmartScreen and signing guidance instead of Gatekeeper/ad-hoc signing guidance.

That work now lives in [`plugins/app-it-windows/`](../plugins/app-it-windows/) — a sibling plugin, not a flag on the macOS one, because the hard parts don't share an honest abstraction. It is a **beta scaffold**: the contract is written and CI-guarded, but it has never run on Windows hardware. The macOS plugin (`plugins/app-it/`) stays macOS-only so its "working, in daily use" promise remains honest; the Windows lane is labeled beta everywhere a user can see it. See [docs/WINDOWS.md](WINDOWS.md) and [ADR 0005](decisions/0005-windows-beta-scope.md).
