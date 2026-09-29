# Strategies

Choose exactly one strategy per user-facing app.

```text
Published/shared Claude Artifact URL?
  yes -> Strategy E
  no  -> raw Artifact source uses window.claude/window.storage/MCP/auth?
           yes -> blocked until user provides/publishes a Claude Artifact URL
           no  -> Existing Electron/Tauri/NW.js config?
                    yes -> Strategy B
                    no  -> native desktop requirements beyond web shell?
                             yes -> Strategy D
                             no  -> FSA real-I/O or Chromium-only API?
                                      yes -> A1 Chrome fallback
                                      no  -> static built bundle, no server?
                                               yes -> A2
                                               no  -> cohabiting frontend + backend?
                                                        yes -> A3
                                                        no  -> A1 native WebKit
```

## A1 Native WebKit - Default

Use the Swift `WKWebView` shell for ordinary web apps. It keeps the app's own
Dock icon, activates an existing window instead of duplicating, starts quickly,
distinguishes red-X from Cmd+Q, and owns the single-instance lifecycle.

Bundle layout:

```text
desktop/<AppName>.app/
  Contents/
    Info.plist
    MacOS/
      run        # tiny native Mach-O stub
      run.sh     # bash launcher
      wrapper    # compiled Swift shell
    Resources/
      AppIcon.icns
```

Do not remove the shipped runtime defenses: runtime port fallback, two-stage
readiness probe, descendant-walk reattach, `setsid` daemonization, pre-flight
runtime checks, expanded Finder/Dock `PATH`, two-stage cleanup, and
multi-server sibling cleanup in `wrapper.swift`.

## A1 Chrome Fallback

Use Chrome fallback when:

- `swiftc` is unavailable and installing command line tools is not feasible.
- The app needs File System Access real I/O.
- The app needs Chromium-only APIs such as Web USB, Bluetooth, HID, or MIDI.

Document the tradeoffs: Chrome's Dock icon may appear while open, relaunch can
duplicate windows, startup is slower, and Cmd+Q/window-close do not map to the
Swift lifecycle. For Chrome fallback, document `desktop:quit` as the primary
full cleanup command. `APP_IT_CHROME_KEEP_WARM=0` can make Chrome exit tear down
the daemon, at the cost of warm relaunch.

## A2 Static

Use when the app is a built static bundle with no dev server. The runtime points
at `file://.../index.html` or the static companion skill's server model. If the
user's goal is a finished build with rebuild snapshots, prefer the
`app-it-static` companion skill if it is already available. That is a separate
plugin and is not bundled or required for App It. Do not assume it is installed
or fetch it without authorization. Without it, reuse an existing authorized
static-serving command with App It's normal launcher templates, or explain the
missing prerequisite instead of promising a finished-build workflow.

## A3 Multi-Server Cohabiting App

Use for one user-facing app backed by multiple local processes.

- A3.1: reuse an existing orchestrator such as `concurrently`, `npm-run-all`,
  `turbo run dev`, or `pnpm -r dev`. This is preferred when signal forwarding
  works.
- A3.2: use `run-template-multiserver.sh` when frontend and backend need
  separate managed ports. The template writes frontend and backend pid/port
  files so Cmd+Q can clean up both.
- A3.3: refuse to start on fixed-port collision when proxy/port literals are
  intentionally unmovable. Explain the trade in the report.

For A3.2, make only env-port source edits: frontend config reads `PORT`,
proxy targets read `API_PORT`, and backend entrypoints read `API_PORT` before
`PORT`.

## A4 CLI Script

Only for scripts with no UI. It spawns Terminal and should be flagged clearly in
the report. Do not choose this for web apps.

## Strategy E URL-Only Hosted App

Use when the app already lives at a hosted URL and the host must own auth and
runtime behavior. The primary case is a published/shared Claude Artifact:
Claude provides the artifact sandbox, AI bridge, storage, login, and plan usage.
App It wraps the URL; it does not recreate Claude's runtime locally.

Set `external_url`, `artifact_url`, or `url` in `scripts/app-it.config.json`.
The generated launcher starts no local daemon, writes no `server.port`, and
passes `allow-external-hosts` to the Swift wrapper so Claude auth redirects,
hosted iframe traffic, and API bridge navigation remain in-window.

Raw JSX/TSX exported from a Claude Artifact is only normal local web app source
when it does not depend on Claude's hosted runtime APIs. If it calls
`window.claude`, `window.storage`, MCP prompts, or Claude-provided auth, do not
shim local credentials, cookies, sessions, or API keys. Publish/share the
artifact in Claude and package that hosted URL so each recipient signs in with
their own Claude account and plan.

## Strategy B Existing Desktop Config

If the repo already has Electron, Tauri, or NW.js, use it instead of stacking
Strategy A on top.

- Electron/electron-builder: wire icon, build with existing macOS target, copy
  the produced `.app`.
- Tauri: regenerate icons if needed, run `tauri build`, install from the Tauri
  bundle output.
- NW.js: use the existing NW build path.

## Strategy D Lightweight Native Wrapper

Use Tauri only when Strategy A cannot deliver a real requirement: tray/status
bar, protocol handlers, file associations, signed distribution, native
notifications, or other OS integration. File System Access real I/O routes to
Chrome fallback first, not Tauri, unless the user truly needs native shipping.

## Cross-Platform Notes

This skill is macOS-first. If asked about Linux, point to a `.desktop` entry
under `~/.local/share/applications`. If asked about Windows, point to a
PowerShell-created `.lnk` or the `app-it-windows` sibling. The Swift shell is
not cross-platform.
