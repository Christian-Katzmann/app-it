# Troubleshooting

## Diagnose It First

Before anything else, run the doctor on the affected launcher:

```bash
npm run desktop:doctor             # read-only health check for one app
npm run desktop:doctor -- --tail   # …and show the tail of the launcher log
```

It inspects what app-it actually cares about — config, the installed `.app`,
icon, bundle id, ad-hoc signature, quarantine, the preferred-vs-runtime port,
stale processes, whether the running server really belongs to this launcher, the
log paths, and whether the installed launcher predates the current templates —
and prints a short report you can paste straight into a bug report. It is
read-only and, when it can't be certain, it says "probably" rather than
asserting.

For multi-app projects it diagnoses one launcher at a time; it lists the apps and
defaults to the first, or pass a slug: `npm run desktop:doctor -- <slug>`.

To clean up app-it's **own** generated state — stale PID/port files, a stale
LaunchServices registration, a rebuilt icon, or quarantine on the generated
`.app`:

```bash
npm run desktop:doctor -- --fix-safe
```

`--fix-safe` only ever touches app-it's generated artifacts. It never modifies
your product code, dependencies, framework config, or anything outside app-it's
own output, and it never kills a running server — that is what `desktop:quit`
is for.

## The App Will Not Open

Run the target project's build again:

```bash
npm run desktop:build
npm run desktop:install
```

The templates ad-hoc sign generated `.app` bundles. That satisfies normal local launch behavior, but it is not notarization.

## The Window Opens But Shows A Server Error

This usually means the launcher worked but the project itself failed to start.

Run the target app's documented dev command from the terminal and fix that first. Then rebuild the launcher.

## The Wrong Port Opens

`app-it` records the actual runtime port in:

```text
~/Library/Application Support/app-it/<slug>/server.port
```

The launcher may choose a nearby free port if the preferred one is already taken. If a project hardcodes a port in `package.json`, `vite.config.*`, or a proxy target, make that port env-driven before rebuilding.

## The Dock Icon Shows Chrome

That is expected only for the Chrome fallback mode. The default Swift `WKWebView` launcher keeps the app's own Dock icon.

Use the Chrome fallback only when the project needs Chromium-only APIs such as real File System Access writes.

## Cmd+Q Does Not Stop The Server

Rebuild with the current templates:

```bash
npm run desktop:build
npm run desktop:install
```

Then verify that the generated app is opening from the install path under `~/Applications/App It/`, not an older build path.

## The App Needs To Be Removed

In the target project:

```bash
npm run desktop:quit
rm -rf desktop
rm -rf assets/icons
rm -f docs/desktop-launcher.md docs/desktop-launcher.app-it-report.md
```

Then remove the installed app:

```bash
rm -rf ~/Applications/App\ It/<AppName>.app
```
