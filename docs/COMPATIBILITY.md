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

## Not Supported

- Windows.
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

That deserves a focused `app-it-windows` or `desktop-it-windows` plugin later. The current plugin stays macOS-only so its promise remains honest.
