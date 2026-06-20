# Verification

Never call a launcher done until the installed app path has been checked. Use
three buckets: programmatic checks, human checks, and deferred checks when the
environment is hostile.

## Pre-Flight Smoke

Before clicking the app, separate project-broken from launcher-broken:

```bash
( cd "$PROJECT_ROOT_BAKED" && PORT=$SMOKE_PORT timeout 30 bash -c "$START_COMMAND" ) &
SMOKE_PID=$!
# poll HTTP, then kill the smoke process tree
```

If this fails, report "launcher built, project command failed" with the log
tail.

## Programmatic Checks

Prefer `./scripts/desktop-verify.sh --json <slug>` for the headless lane. It
checks the built/installed bundle status, runs the real bundle through
`APP_IT_SMOKE=1`, confirms the recorded runtime port and HTTP response, and
summarizes `desktop-doctor --json`. It labels GUI-only checks as manual instead
of pretending they passed.

For fixed-port apps, verify that `ports.mode` is `fixed` and the recorded
runtime port equals the configured preferred port. A busy preferred port should
fail launch with an explanation; fallback is deliberately disabled.

For Strategy E URL-only apps, rows 3-9 are `n/a - no local server`.
Programmatic verification is: `APP_IT_SMOKE=1 desktop/<App>.app/Contents/MacOS/run`
prints the configured URL, no `server.port` is written, `run.sh` contains the
URL and `allow-external-hosts` in Swift mode, and rows 1-2 still pass. GUI
verification is opening the installed app, signing into Claude if needed, and
confirming the hosted artifact runs in-window. Do not `curl` private Artifact
URLs as proof; auth-protected Artifacts may correctly redirect.

| # | Check | Idiom |
| ---: | --- | --- |
| 1 | Build succeeded | `.app` exists; `file Contents/MacOS/run` reports Mach-O; `run.sh` executable; wrapper Mach-O; icon file valid |
| 2 | Bundle metadata | `PlistBuddy` prints bundle id/name; no unresolved template-placeholder leakage |
| 3 | Runtime port | read `~/Library/Application Support/app-it/<slug>/server.port` first |
| 4 | Server responding | `curl` runtime port; any non-`000` response means the launcher reached the project |
| 5 | Process identity | prefer `desktop:doctor`; hand `pgrep` is diagnostic only |
| 6 | LaunchServices identity | `lsappinfo` bundle id matches config |
| 7 | Cmd+Q cleanup | `osascript -e 'tell application id "<bundle-id>" to quit'`, then runtime port is free |
| 8 | Red-X warm state | close windows via Apple Event; runtime port remains listening |
| 9 | Warm relaunch | reopen installed app; HTTP responds quickly on recorded runtime port |
| 10 | Installed path opens | `open "$HOME/Applications/App It/<App>.app"` exits `0` |
| 11 | Single LS registration | `lsregister -dump` shows one active installed entry |
| 12 | Shortcut binary marker | `grep -qboa "reloadPageIgnoringCache" .../wrapper` when checking menu shortcut support |

For A3 multi-server apps, Cmd+Q must also free the backend runtime port read
from `backend.port`.

## The verify JSON contract

`desktop-verify.sh --json` (and `desktop-doctor.sh --json`) emit a **stable,
versioned public contract**. This is the thing an external "app-it compatible"
badge or CI gate keys off, so it is treated as an API, not an internal dump.

```jsonc
{
  "schema_version": 1,                 // contract version of THIS JSON output
  "tool": "app-it.desktop-verify",     // or "app-it.desktop-doctor"
  "status": "pass",                    // verify only: pass | warn | fail
  "manifest": {                        // provenance stamped into app-it.config.json
    "schema_version": 1,               //   manifest shape version (int, or null if unstamped)
    "generator_version": "0.2.0",      //   app-it release that generated the manifest
    "template_version": "2026.06"      //   vendored-template vintage (calendar version)
  },
  "app":     { "name", "slug", "bundle_id", "version" },
  "ports":   { "mode", "preferred", "runtime", "backend_preferred", "backend_runtime" },
  "counts":  { "ok", "warn", "fail", "info", "manual", "skip" },
  "checks":  [ { "section", "status", "message" }, ... ]
  // ...plus tool-specific blocks: verify adds subject/artifacts/doctor; doctor adds state/recommended_action
}
```

### Field meanings

| Field | Meaning |
| --- | --- |
| `schema_version` (top level) | Version of the JSON **output contract** itself. `1` today. A consumer asserts on this before trusting the rest. |
| `tool` | Which tool emitted it: `app-it.desktop-verify` or `app-it.desktop-doctor`. |
| `status` | verify only. `pass` (no warn/fail), `warn`, or `fail`. A passing `--strict` run is the "done" signal. |
| `manifest.schema_version` | Shape version of the `app-it.config.json` manifest. Integer, or `null` for an older config generated before stamping existed. |
| `manifest.generator_version` | The app-it release (semver) that generated the manifest. Provenance only. |
| `manifest.template_version` | Calendar version (e.g. `2026.06`) of the templates the app was vendored from. `doctor`'s drift check and `upgrade` compare it against the current templates. `null` if unstamped. |
| `counts` | Tally of check outcomes. `status: pass` ⇔ `counts.fail == 0 && counts.warn == 0`. |
| `checks` | Ordered list; each has a `section`, a `status` (`ok`/`warn`/`fail`/`info`/`manual`/`skip`), and a human `message`. |

### Versioning the two `schema_version` fields

There are deliberately two, at different levels, and they version different things:

- **Top-level `schema_version`** versions the *output contract* — the JSON
  shape above. **Additive changes are safe and do NOT bump it**: adding a new
  field, a new `manifest.*` key, or a new check section is backward-compatible,
  so a consumer pinned to `schema_version: 1` keeps working. **A breaking change
  — renaming/removing a field, changing a type or the meaning of `status` —
  bumps it to `2`.** Consumers should assert `schema_version` is a version they
  understand and otherwise read fields defensively.
- **`manifest.schema_version`** versions the *config file* shape and follows the
  same additive-safe / breaking-bumps rule, independently.

### Stability promise (what "app-it compatible" relies on)

1. For a given top-level `schema_version`, the fields in the table above are
   present and keep their types and meaning.
2. `status`, `tool`, `manifest`, `counts`, and `checks[].status` are the load-
   bearing keys. A passing gate is `tool == "app-it.desktop-verify"`,
   `schema_version` understood, and `status == "pass"` under `--strict`.
3. New keys may appear at any level without a version bump — ignore unknown keys.
4. Removing or repurposing any key in the table is a breaking change and bumps
   the relevant `schema_version`.

## Human Checks

Mark as needs human unless the environment has a usable display:

- Window shows the app content, not an error page.
- Dock icon is the app icon, not Chrome/Safari.
- Autoplay works when the app needs media autoplay.
- FSA reconnect works when a polyfill is installed.
- Standard shortcuts respond in the actual app window.

## Deferred Checks

If verification would damage the user's current environment, do not spawn a
competing process. Examples: a same-project dev server already owns caches, or a
fixed different-project listener blocks an unmovable proxy port. Mark
`deferred - env hostile` and write the exact one-line user action to retry.

## Cmd+Q Semantics

Do not test Cmd+Q by sending `kill -TERM` to the wrapper. Signals bypass
AppKit's `applicationShouldTerminate`. Use an Apple Event through `osascript`.

## Cleanup

Before ending the session, stop every process this run started. For generated
apps, prefer `desktop:quit`; otherwise terminate recorded PID trees and sweep
runtime ports. Do not kill unrelated listeners.
