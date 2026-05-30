# AGENTS.md

Operating notes for AI agents (and humans) working **on the app-it repo itself** — not on a project that app-it is packaging. If you're here to *use* the skill, read the [README](README.md) and [SKILL.md](plugins/app-it/skills/app-it/SKILL.md) instead.

## Safe first command

```bash
git status --short        # see what's dirty before touching anything
```

## Verify — the one command

```bash
./scripts/validate.sh
```

It checks manifest shape, shell syntax (`bash -n`), plist lint, a Swift typecheck of `wrapper.swift`, `claude plugin validate` (when the CLI is present), and guards against leaked local paths and unresolved template placeholders. CI runs the same script on `macos-latest`. **Green here is the bar for every change.**

## What this repo is

One skill, packaged as a plugin for **two** assistants. That's why some files look duplicated — they aren't:

- The skill: `plugins/app-it/skills/app-it/SKILL.md` (+ `templates/`).
- Claude packaging: `.claude-plugin/marketplace.json`, `plugins/app-it/.claude-plugin/plugin.json`.
- Codex packaging: `.agents/plugins/marketplace.json`, `plugins/app-it/.codex-plugin/plugin.json`.

The four manifests carry the **same version**. `validate.sh` asserts it; releases bump them together (see [docs/RELEASE_CHECKLIST.md](docs/RELEASE_CHECKLIST.md)).

## Conventions that will surprise you

- **`templates/` are canonical and battle-tested — don't rewrite them from scratch.** `wrapper.swift`, `run-template*.sh`, and the `desktop-*.sh` scripts encode traps that took 12 real-project sessions to get right: NFC/NFD-safe `pgrep`, daemon-mode servers, two-stage cleanup, runtime port-fallback, descendant-walk reattach, Finder/Dock `PATH` augmentation. The **Anti-patterns** section of `SKILL.md` is the law — read it before changing launcher behavior.
- **`SKILL.md` is the product.** Editing it changes how the tool behaves in *every* project an agent later runs it in. Treat prose changes there as behavior changes, not doc edits.
- **Trust disk over docs** — the skill's own first principle. In a *target* project, `CLAUDE.md` / `README.md` may be stale; verify project type from `package.json` + config files.
- **Generated artifacts never get committed here.** `desktop/` and `assets/icons/` are app-it's *output* inside target projects — gitignored, and they should never appear in this repo.

## Do not

- **Do not broaden scope.** macOS-only is a deliberate boundary, not a gap — see [decision 0002](docs/decisions/0002-macos-only-scope.md). Windows/Linux launchers, notarization, signed distribution, and Electron/Tauri migration are out of scope on purpose (CONTRIBUTING.md). New launcher *reliability* is welcome; new *surface area* is not.
- **Do not hardcode a local absolute path** (`/Users/<name>/…`). `validate.sh` greps for it and fails the build.
- **Do not leave `__PLACEHOLDER__` tokens outside `templates/`.** `validate.sh` fails on unresolved placeholders in README / docs / manifests.
- **Do not bump one manifest without the others.** Version drift across the four manifests fails validation and breaks installs.
- **Do not add runtime dependencies to the launcher path.** Strategy A is bash + `swiftc` + the system. Keep it that way.

## Decisions

The non-obvious calls — and the alternatives deliberately rejected — live in [docs/decisions/](docs/decisions/). If you're about to re-propose Electron-by-default or auto-attaching to a running dev server, the autopsy is already written.

## Working style

The maintainer optimizes for **minimum work for the user, maximum repeatability, no over-engineering**, and prefers a decisive default with a documented trade-off over a question. Match the existing voice: terse, specific, trap-aware. Keep changes additive and reversible. When a template comment warns about something, it's because it bit someone in a real session — understand *why* it's there before "cleaning it up."
