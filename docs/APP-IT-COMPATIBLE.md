# app-it compatible

**app-it is the verified last mile for AI-built local software.** "app-it
compatible" is the stamp that says that last mile actually holds: a repo carries
an app-it manifest, and the launcher app-it generated for it *passes verification*
— not "the build script ran", but "the app builds, launches, serves on its port,
is owned by its own process, and tears down cleanly".

This page is the contract. It defines the stamp, the one-line norm for agents,
and how to wire the gate into CI.

## What "app-it compatible" means

A repo is **app-it compatible** when both are true:

1. It has an app-it manifest — `scripts/app-it.config.json` — describing the
   app(s) app-it built a launcher for.
2. `app-it verify --strict` **passes**: the generated launcher's
   [`desktop-verify.sh`](../plugins/app-it/skills/app-it/templates/desktop-verify.sh)
   reports `status: pass` with zero `warn` and zero `fail`.

That's the whole definition. It is deliberately tight: the stamp is worth
nothing if it certifies anything looser than "the lifecycle works".

`verify` is behavior-first, not a checkbox. Under the hood a passing run means
the real `.app` bundle was built, run headlessly through the `APP_IT_SMOKE` seam
(server up, port recorded, HTTP answering — no GUI required), and checked by
`desktop:doctor` for process ownership and template drift. GUI-only facts
(window content, Dock icon identity, ⌘Q) are reported as `manual`, never faked.

## The norm for agents (any agent)

> **Don't declare a local app done until `app-it verify --strict` passes.**

This is agent-agnostic on purpose. app-it works with **Claude Code** and
**Codex** today, and the norm holds for *any* coding agent that can run a shell
command. The failure mode it fixes is universal: an agent says "your app is
ready" when all it really proved is that a file was written. `verify --strict`
is the one command that converts "I generated a launcher" into "the launcher
works, and here's the machine-readable proof".

Run it directly:

```bash
./scripts/app-it verify --strict --json     # or: ./scripts/desktop-verify.sh --strict --json
```

`status: pass` under `--strict` is the done signal. Anything else is not done.

## The verify JSON contract

`desktop-verify.sh --json` emits a **stable, versioned public contract** — the
thing this badge and any CI gate key off. It is treated as an API, not an
internal dump. The full field-by-field spec, the two `schema_version` fields,
and the additive-safe / breaking-bumps versioning rules live in
[references/verification.md](../plugins/app-it/skills/app-it/references/verification.md).

The passing gate, in one line:

```
tool == "app-it.desktop-verify"  &&  schema_version understood  &&  status == "pass"
```

- **`tool`** — `"app-it.desktop-verify"`. Assert it before trusting the rest.
- **`schema_version`** (top level) — version of the output contract itself.
  `1` today. New keys may appear without a bump; a rename/removal/meaning change
  bumps it. A consumer asserts the version it understands and reads defensively.
- **`status`** — `pass` ⇔ `counts.fail == 0 && counts.warn == 0`. Only `pass`
  is compatible.

## The GitHub Action

This repo ships a reusable composite action that wraps exactly that gate. It is
**published and referenceable** — point at it directly, no copy-paste:

```yaml
# .github/workflows/app-it.yml in YOUR app-it'd repo
name: app-it compatible
on: [push, pull_request]
permissions:
  contents: read
jobs:
  verify:
    runs-on: macos-latest   # required — the gate builds the real .app bundle
    steps:
      - uses: actions/checkout@v4
      - uses: Christian-Katzmann/app-it/.github/actions/app-it-verify@v0.2.0
```

That runs `./scripts/desktop-verify.sh --build --install --strict --json`,
prints the JSON to the job log and summary, and **fails the job unless
`status == pass`** under the contract above.

Inputs (all optional):

| Input | Default | Purpose |
| --- | --- | --- |
| `working-directory` | `.` | Repo root holding `scripts/desktop-verify.sh` + `scripts/app-it.config.json`. |
| `app` | *(first app)* | Slug or name to verify when the manifest has several. |
| `build` | `true` | Build the bundle first (`--build`). GitHub-hosted runners need it — `desktop/` is gitignored. |
| `install` | `true` | Install first (`--install`). Required for a clean, warning-free strict pass. |
| `schema-version` | `1` | Contract version the gate understands. Bump only after reviewing a breaking change. |

Pin to a release tag (`@v0.2.0`) so a contract change can't silently shift your
gate. macOS-only: the action builds and runs a real macOS `.app`, so it must run
on a `macos-*` runner.

## The badge

Back the badge with the workflow above, then add it to your README:

```markdown
[![app-it compatible](https://github.com/<owner>/<repo>/actions/workflows/app-it.yml/badge.svg)](https://github.com/Christian-Katzmann/app-it/blob/main/docs/APP-IT-COMPATIBLE.md)
```

The image is your own workflow's live status — green only while `verify --strict`
passes — and the link explains what the stamp certifies. A label-only variant
(`https://img.shields.io/badge/app--it-compatible-brightgreen`) reads fine too,
but a status badge backed by a real run is the honest one: a badge with no
backing CI is noise.

## Why formalize this

The stamp isn't aspirational. app-it–generated artifacts already live in
external, unaffiliated public repos — launchers and the per-build decision log
app-it writes. Once a tool's output shows up in other people's repos, "it works
on my machine" stops being good enough; the output needs a portable, checkable
definition of correct. That's what "app-it compatible" is: a one-command,
machine-readable proof that the last mile holds — runnable by a human, by CI, or
by the agent that built the app, on any stack app-it already supports.

The contract comes first. A manager/dashboard layer can sit on top of it later;
it would consume this same `verify --json`, not replace it.
