# app-it on Windows (beta)

**Windows beta · scaffolded · untested on real hardware · maintainer wanted.**

## I'm a Mac user. Here's why this exists.

The macOS `app-it` is in daily use and proven across a dozen real projects. I only run macOS, so I will never honestly be able to say "the Windows build works" — and quietly shipping an untested Windows launcher dressed up as "working" would be a lie. So instead of saying "no" forever, I built the Windows version as far as a Mac can take it: a complete, CI-guarded scaffold that mirrors the macOS contract using Windows-native primitives, with every decision that needs real hardware to confirm marked out loud. What's left is the part only a Windows user can finish. If that's you, this page is the doorway.

## The Windows contract

The Windows lane mirrors the macOS one, primitive for primitive. The full reasoning lives in [ADR 0005](decisions/0005-windows-beta-scope.md); the shape of it:

- **Native shell — WPF + WebView2.** A C# WPF host embeds the Evergreen WebView2 runtime, so the host window owns its title bar and `.ico` and the **taskbar entry is the app, not Edge** — the same reason macOS uses a native Swift `WKWebView` shell over Chrome `--app=`. Built with `dotnet publish` to a self-contained, single-file `.exe`: one file, no .NET install, double-click runs. Edge `--app=` is the documented fallback, never the default.
- **Packaging — one folder, one Start Menu group.** Per app: a folder with the `.exe` and its `.ico`, plus a `.lnk` shortcut in `%APPDATA%\Microsoft\Windows\Start Menu\Programs\app-it\`. That folder is the Windows reading of macOS's `~/Applications/App It/` Dock Stack. No MSIX, no installer. Honors `APP_IT_INSTALL_DIR`.
- **Lifecycle — soft-close vs quit, manufactured.** Windows doesn't hand you the close-vs-quit distinction the way AppKit does on macOS, so the scaffold builds it: `ShutdownMode = OnExplicitShutdown`, `Window.Closing` cancels and hides to the tray (the dev server stays warm), and a tray **Quit** disposes a Win32 Job Object that reaps the whole dev-server tree and frees the port. The server lives inside that Job Object — orphan-safe, so a crash can't leak it.
- **Signing — unsigned, SmartScreen click-through.** Like the macOS plugin's ad-hoc signing, the `.exe` is unsigned. On first run Windows SmartScreen shows "Windows protected your PC"; you click **More info → Run anyway** once and Windows remembers. Self-signed certs are more friction than benefit for a personal local launcher; real code signing is out of scope, exactly as notarized distribution is on macOS.
- **Icons — multi-resolution `.ico`.** `desktop-icons.ps1` turns a PNG or SVG into a multi-resolution `.ico` (16/32/48/64/128/256), the Windows `.icns`. ImageMagick when present, a `System.Drawing` fallback so it still works on a stock Windows box. A placeholder generator means the build never fails on a missing icon.
- **Config — the same schema.** The Windows plugin reads the same `app-it.config.json` as macOS, with an optional `platform.windows` block for Windows-only fields. A config authored on one platform stays legible on the other.

## What works (in theory)

"In theory" is doing real work in that sentence. Everything below is **authored and exercised in CI on `windows-latest`, but never run on a real Windows desktop.** Build-time success is not runtime success.

- The WPF + WebView2 host **compiles and publishes** to a self-contained single-file `win-x64` `.exe` (CI runs `dotnet build`).
- The PowerShell lifecycle scripts (`run-template.ps1`, `desktop-build.ps1`, `desktop-install.ps1`, `desktop-quit.ps1`, `inspect.ps1`, `desktop-icons.ps1`, the Edge fallback) **lint clean** under `Invoke-ScriptAnalyzer -Severity Error,Warning`.
- The plugin manifests and `app-it.config.json` **parse**.
- `placeholder-icon-gen.ps1` **round-trips** to a readable multi-resolution `.ico`.

What no one has confirmed yet — because it needs a Windows session in the loop — is everything that matters at runtime: does the window actually open and render the URL, is the taskbar identity ours and not Edge's, does X-to-tray keep the server warm, does tray-Quit free the port, does the Job Object reap vite/esbuild grandchildren without leaking, does the `.lnk` land with its icon, does SmartScreen behave as documented, does it look right at high DPI. Those are the open seams, and they're the whole reason this page exists.

## What a first PR looks like

In rough priority order — each is a self-contained, claimable check:

1. **Verify the WPF host launches a window and renders a URL.** Clone the repo, `dotnet publish` the `wrapper-windows` project, run the `.exe` against a local dev server, and confirm a real window opens showing the app — with our icon in the taskbar, not Edge's. This is check #1; everything else builds on it.
2. **Verify the Start Menu `.lnk` lands and the icon shows up.** Run `desktop:build` then `desktop:install`, confirm the shortcut appears under the `app-it\` Start Menu group, and that the `.ico` renders crisply in both the Start Menu and the taskbar (Windows icon-cache quirks are real — note what you see).
3. **Fix the first round of PowerShell scope/quoting bugs.** Code that lints clean still meets reality the first time it runs on a real shell: PATH augmentation for the version managers you actually use (nvm-windows, fnm, Volta, Scoop, pnpm), free-port probing under the live TCP stack, Job-Object teardown. Expect a handful of small, honest fixes here — that's exactly the contribution this beta is asking for.

The complete list of seams a Mac can't validate is the "Deferred to a Windows maintainer" section of [ADR 0005](decisions/0005-windows-beta-scope.md). Every item there is a check waiting to be claimed.

## What we'll do for you

This is a real invitation, not a "PRs welcome" shrug:

- **Fast review.** Windows PRs jump the queue. You shouldn't have to wait on a Mac user to look at Windows work.
- **Full credit.** Your name lands in `CHANGELOG.md` for every check you turn green, by name.
- **Co-maintainer status if you stick around.** Verify a few of the deferred seams and you're the Windows maintainer — the person who decides the conventions a Mac user honestly can't (X-to-tray vs X-quits, the warm-keep model, taskbar-pin guidance). The contract is written; you own the judgment calls.

## First contact

**Open an issue and add the `windows-maintainer` label** (or ask me to — say you're picking up the Windows beta). That's the entry point. GitHub Discussions are intentionally **off** for this repo: a single labeled issue thread keeps the conversation in one searchable place next to the code, with no second surface to watch. Tell me which check from "What a first PR looks like" you want to start with, and I'll point you at the exact files.
