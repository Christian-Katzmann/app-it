# 0002 — macOS only, on purpose

**Status:** Accepted

## Context

"Make my web project a desktop app" is a cross-platform demand, and it's tempting to promise it everywhere to widen the audience.

## Decision

app-it is macOS-only. A Windows (or Linux) launcher, if it ever exists, is a *separate* plugin — not a flag on this one.

## Alternatives considered

- **One cross-platform plugin.** Rejected: the hard parts don't transfer. macOS uses `WKWebView`, `.app` bundles + LaunchServices, `.icns`, `osascript`/`lsof` process control, and Gatekeeper/ad-hoc signing. Windows needs WebView2 or Edge app mode, `.lnk`/Start-Menu integration, `.ico` assets, PowerShell job control, and SmartScreen/signing guidance. A single plugin spanning both would make lowest-common-denominator promises and hide platform-specific failure modes.

## Consequences

- The README and skill can make concrete, testable macOS promises (own Dock icon, `~250 ms` warm re-launch, ⌘Q frees the port) instead of vague portable ones.
- Windows users get an honest "not yet, and here's why it's a different project" — see [docs/COMPATIBILITY.md](../COMPATIBILITY.md) — rather than a half-working launcher.
