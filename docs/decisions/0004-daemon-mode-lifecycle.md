# 0004 — Daemon-mode dev server: warm on close, killed on quit

**Status:** Accepted

## Context

A dev server is slow to cold-start (seconds). People close and re-open app windows constantly. They also expect ⌘Q to *actually* stop everything and free the port — not leak a server in the background.

## Decision

- **Window close (red-X / ⌘W):** leave the dev server running ("warm"). The next launch reattaches in `~250 ms` instead of cold-starting.
- **⌘Q (real quit):** tear down the whole server process tree and free the port.

The Swift wrapper distinguishes the two: `windowShouldClose` sets a flag that `applicationShouldTerminate` checks, so AppKit's lifecycle — not a guessed signal — drives the decision.

## Alternatives considered

- **Kill the server on every window close.** The naive default. Makes every re-open a multi-second cold start. Rejected.
- **Never kill the server.** Leaks servers and held ports across sessions. Rejected.

## Consequences

- Requires disciplined process handling: `setsid` daemonization (so wrapper exit can't SIGHUP the tree), two-stage cleanup (TERM the recorded tree → port-sweep stragglers → SIGKILL holdouts), and descendant-walk reattach. All in [SKILL.md](../../plugins/app-it/skills/app-it/SKILL.md) Strategy A1.
- `desktop-quit.sh` exists as the defensive fallback for re-parented children that escape the wrapper's own cleanup.
