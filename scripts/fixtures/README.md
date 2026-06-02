# app-it fixture suite

Tiny, disposable project *shapes* that prove app-it actually works across the
kinds of project it claims to support. Driven by [`../test-fixtures.sh`](../test-fixtures.sh)
and run on every push by the macOS CI lane.

These fixtures are **not** demo apps. Each one earns its place by guarding a
distinct class of regression in app-it's own machinery — not by showing off a
framework. Keep them minimal.

## How a run works

For each fixture, `test-fixtures.sh`:

1. Copies the fixture's project shape into a throwaway temp dir, drops the
   plugin's `templates/` into `scripts/`, relocates the fixture's
   `app-it.config.json`, and (for runtime fixtures) copies in the `$PORT`-honoring
   stand-ins [`../lib/stub-server.js`](../lib/stub-server.js) (and
   [`../lib/stub-nested.js`](../lib/stub-nested.js), which spawns the stub a level
   deeper for the deep-tree case) and the shared `_shared/icon.png`.
2. Runs the **real** scripts — `inspect.sh`, `desktop-build.sh`, the bundle's
   `run` (with `APP_IT_SMOKE=1`, the headless seam), `desktop-doctor.sh`,
   `desktop-quit.sh` — under a **sandboxed `HOME`**, so the real
   `~/Applications/App It` and `~/Library/.../app-it` state is never touched.
3. Asserts the headless-automatable rows of SKILL.md's Phase-4 checklist
   (build, bundle metadata, no placeholder leak, runtime port, server
   responding, **server belongs to the launcher**) and tears everything down —
   even on failure.

## What each fixture guards

| Fixture | Distinct regression it guards |
|---|---|
| `vite-basic` | Vite detection; single-server build → launch → port → ownership → warm reattach → teardown; PNG → `.icns` icon round-trip |
| `next-basic` | Next detection (PORT-env, no `--port`); bundle assembles for a Next shape |
| `static-export` | app-it-static: static-export detection + serving a prebuilt `out/` with the real stdlib `static-server.py` |
| `vite-express` | A3.2 multiserver template selected; dual-port + `API_PORT`; both ports owned and freed |
| `deep-tree` | the descendant-walk reaches a **gen-2** listener (bash → node → node, like real `npm`/`pnpm` dev) — so warm-reattach and `desktop:doctor` ownership work for real frameworks, not just gen-1 stubs |
| `hardcoded-port` | `inspect.sh` keeps warning about hardcoded port literals (the #1 reason a launcher silently ignores its chosen port) |
| `chrome-fallback` | `APP_IT_LAUNCHER_MODE=chrome` → Chrome `--app=` run script, no Swift wrapper binary |
| `vite-real` | The **real** `npm run dev -- --port $PORT` Vite invocation still launches (scheduled + release only — needs `APP_IT_RUN_REAL=1`) |

## What this suite does NOT prove

Honesty matters more than a green check that lies:

- **Real frameworks** — except `vite-real`, the runtime fixtures launch a tiny
  stand-in server, not the real framework. app-it's launcher is
  framework-agnostic; the framework-specific knowledge it encodes (Vite needs
  `--port`, Next reads `PORT`) is tested via `inspect.sh`'s output, and real
  end-to-end launches live in `vite-real` + the manual release smoke.
- **The GUI lifecycle** — window content, the Dock icon being *ours*, Cmd+Q vs
  red-X, LaunchServices registration (rows 5–16) need a real display. They stay
  in the manual release smoke (see [docs/RELEASE_CHECKLIST.md](../../docs/RELEASE_CHECKLIST.md)).

## Rule for new framework recipes

**No new framework recipe is merged unless it's backed by a fixture here or a
reproducible smoke test.** A recipe is a claim that app-it works for a shape; a
fixture is the proof. Adding one is usually: a tiny shape dir + one row in
`test-fixtures.sh`. See [CONTRIBUTING.md](../../CONTRIBUTING.md).
