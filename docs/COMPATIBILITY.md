# Compatibility

## Supported

`app-it` supports macOS local developer workflows.

| Area | Support |
| --- | --- |
| OS | macOS |
| Primary shell | Swift `WKWebView` wrapper |
| Fallback shell | Chrome `--app` mode |
| Common targets | Vite, Next.js, static sites, local multi-server apps |
| Install destination | `~/Applications/App It/` by default |
| Signing | Ad-hoc local code signing only |

## Beta · maintainer wanted

| Area | Support |
| --- | --- |
| OS | Windows — **beta · scaffolded · untested on real hardware** |
| Plugin | `plugins/app-it-windows/` (sibling of the macOS plugin) |
| Primary shell | C# WPF + WebView2 host → self-contained single-file `.exe` |
| Fallback shell | Edge `--app=` mode |
| Install destination | `app-it\` Start Menu group via `.lnk` |
| Status | Builds and lints in CI on `windows-latest`; **nobody has run it on Windows yet** |

The author runs only macOS and will not dogfood the Windows build, so it ships as an honest beta looking for a maintainer rather than a finished feature. Everything a Mac can produce is built and CI-guarded; everything that needs real hardware to confirm is marked as deferred. See **[docs/WINDOWS.md](WINDOWS.md)** for what works in theory, what a first PR looks like, and how to claim a check.

## Not Supported

- Linux desktop launchers.
- App Store packaging.
- Notarized distribution to other users.
- Auto-update.
- Installer generation.
- Production Electron or Tauri migrations.

## Why Windows Should Be Separate

Windows is not just macOS with different paths. A serious Windows version needs:

- WebView2 or Edge app mode instead of `WKWebView`.
- `.lnk` shortcuts and Start Menu behavior instead of `.app` bundles and LaunchServices.
- `.ico` asset generation instead of `.icns`.
- PowerShell/process-job handling instead of `osascript`, `lsof`, and macOS app lifecycle hooks.
- SmartScreen and signing guidance instead of Gatekeeper/ad-hoc signing guidance.

That work now lives in [`plugins/app-it-windows/`](../plugins/app-it-windows/) — a sibling plugin, not a flag on the macOS one, because the hard parts don't share an honest abstraction. It is a **beta scaffold**: the contract is written and CI-guarded, but it has never run on Windows hardware. The macOS plugin (`plugins/app-it/`) stays macOS-only so its "working, in daily use" promise remains honest; the Windows lane is labeled beta everywhere a user can see it. See [docs/WINDOWS.md](WINDOWS.md) and [ADR 0005](decisions/0005-windows-beta-scope.md).
