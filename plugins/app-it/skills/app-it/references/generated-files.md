# Generated Files

Keep the target-project surface small and repeatable.

## Template Roster

Copy from `templates/`:

- `wrapper.swift`
- `info-plist-template.xml`
- `run-template.sh`
- `run-template-chrome.sh`
- `run-template-multiserver.sh`
- `run-template-url.sh`
- `run-template-url-chrome.sh`
- `native-run-stub.c`
- `desktop-build.sh`
- `desktop-icons.sh`
- `desktop-icons-preview.sh`
- `desktop-install.sh`
- `desktop-quit.sh`
- `desktop-doctor.sh`
- `desktop-verify.sh`
- `desktop-upgrade.sh`
- `inspect.sh`
- `app-it` (thin dispatcher: `inspect | apply | verify | upgrade`)
- `placeholder-icon-gen.sh`
- `fsa-polyfill-template.js`
- `app-it.config.example.json`
- `desktop-launcher.md.template`

Do not rewrite these patterns from scratch.

## Allowed Target-Project Additions

- `assets/<slug>-icon.{png,svg}` or `assets/app-icon.{png,svg}`.
- `assets/icons/` generated icon artifacts.
- `assets/icons/build/wrapper` compiled Swift binary.
- copied scripts/templates under `scripts/`.
- `scripts/app-it.config.json` as the single source of truth.
- `assets/<slug>-polyfill.js` only for FSA polyfill.
- `desktop/<AppName>.app/` generated bundles.
- `docs/desktop-launcher.md`.
- `docs/desktop-launcher.app-it-report.md`.
- `package.json` scripts for desktop commands.
- `.gitignore` entries for generated `desktop/` and icon build outputs.

Avoid app business-logic edits. The carve-out is env-driven port wiring in
framework/server config for A3 or hardcoded-port fixes.

## Config JSON

Use `scripts/app-it.config.json`:

```json
{
  "schema_version": 1,
  "generator_version": "0.2.0",
  "template_version": "2026.06",
  "apps": [
    {
      "name": "My App",
      "slug": "my-app",
      "port": 5173,
      "port_mode": "fallback",
      "start_command": "npm run dev -- --host 127.0.0.1 --port $PORT --strictPort",
      "bundle_id": "com.user.my-app",
      "version": "0.1.0",
      "polyfill_path": "",
      "external_url": ""
    }
  ]
}
```

The three top-level fields stamp the manifest's provenance and are written at
generation time (the per-app `version` is unrelated — it's the marketing
version):

- `schema_version` (int) — shape version of this manifest. `1` today; additive
  changes keep it, breaking changes bump it.
- `generator_version` (semver) — the app-it release that generated the config.
- `template_version` (calendar, e.g. `"2026.06"`) — the vendored-template
  vintage. `desktop-doctor`'s drift check and `upgrade` compare it against the
  current templates to decide whether a re-vendor is due.

These same stamps are surfaced under `manifest` in `desktop-verify`/`desktop-doctor`
`--json` output — see `references/verification.md` for the versioned contract.

For A3, add `backend_port` and `backend_start_command`. For Strategy E
URL-only apps, set `external_url` (or alias `artifact_url` / `url`) and leave
local-server fields empty or `null`; URL-only mode wins if both are present.

Use `port_mode: "fixed"` only when the frontend origin must stay exact. The
default `fallback` mode is friendlier for sibling local apps because it scans
upward when the preferred port is already busy.

## Placeholders

Build-time substitution writes:

- `__APP_NAME__`
- `__APP_SLUG__`
- `__PROJECT_ROOT__`
- `__PORT__`
- `__PORT_MODE__`
- `__START_COMMAND__`
- `__APP_URL__`
- `__BUNDLE_ID__`
- `__VERSION__`
- `__POLYFILL_PATH__`

No unresolved double-underscore template placeholders may remain in generated
bundles or docs.

## Package Scripts

Single-app projects:

```json
{
  "scripts": {
    "desktop:icons": "APP_NAME='My App' APP_SLUG='my-app' ./scripts/desktop-icons.sh",
    "desktop:icons:preview": "APP_NAME='My App' APP_SLUG='my-app' ./scripts/desktop-icons-preview.sh",
    "desktop:build": "./scripts/desktop-build.sh",
    "desktop:install": "./scripts/desktop-install.sh",
    "desktop:quit": "./scripts/desktop-quit.sh",
    "desktop:doctor": "./scripts/desktop-doctor.sh",
    "desktop:verify": "./scripts/desktop-verify.sh",
    "desktop:upgrade": "./scripts/desktop-upgrade.sh"
  }
}
```

## Command surface (`app-it` dispatcher)

`scripts/app-it` is a thin router over the scripts above — no binary, no runtime
dependency. It exposes the four lifecycle verbs and forwards flags verbatim:

| Verb | Routes to | Notes |
| --- | --- | --- |
| `app-it inspect` | `inspect.sh` | read-only project inspection |
| `app-it apply` | `desktop-build.sh` + `desktop-install.sh` | build then install (all apps in the config) |
| `app-it verify` | `desktop-verify.sh` | e.g. `app-it verify --strict --json <slug>` |
| `app-it upgrade` | `desktop-upgrade.sh` | re-vendor newer templates when the manifest is behind |

The underlying `desktop-*.sh` scripts stay runnable directly; the dispatcher just
unifies the common path. `APP_IT_PROJECT_ROOT` is honored by every routed script.

## Upgrade (template re-vendor)

`desktop-upgrade.sh` keeps a generated app current. It compares the manifest's
`template_version` against the current templates' vintage (read from the template
source's `app-it.config.example.json`) and, when the manifest is behind:

1. Re-vendors the roster above into `scripts/` — and **only** that roster. It
   never touches the user's product code, dependencies, `package.json`, icon
   sources, or the per-app entries in `app-it.config.json` (the same ownership
   boundary `desktop-doctor.sh --fix-safe` respects).
2. Re-stamps just the three top-level provenance fields
   (`schema_version`/`generator_version`/`template_version`).
3. Rebuilds and re-runs `desktop-verify.sh`. If verify fails an
   ownership/identity check, the upgrade is **refused** and the vendored scripts
   + manifest are rolled back to their pre-upgrade state.

The "newer templates" come from the directory the script lives in, or
`APP_IT_TEMPLATE_SRC`. Run the plugin's copy (like `inspect.sh`) against a
project to pull templates newer than what the project currently vendors:
`/path/to/plugins/app-it/skills/app-it/templates/desktop-upgrade.sh`. Use
`--check` for a read-only drift report (exit 3 when an upgrade is due) and
`--force` to re-vendor even when already current.

For multi-app projects, add per-app icon and preview scripts while keeping
aggregate `desktop:build`, `desktop:install`, `desktop:quit`, and
`desktop:doctor` / `desktop:verify`. Both diagnose one app at a time:
`npm run desktop:doctor -- <slug>` and `npm run desktop:verify -- <slug>`.

If the project has no `package.json`, expose equivalent commands through a
Makefile or top-level shell script.

## User Documentation

Write `docs/desktop-launcher.md` from the template. Keep it short. The first
post-title section must be `First launch` and should mention Gatekeeper's
right-click Open flow, cold-start compile time, and where server logs live.
