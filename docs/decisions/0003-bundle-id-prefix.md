# 0003 — `com.user.<slug>` bundle-id prefix

**Status:** Accepted

## Context

Every generated `.app` needs a `CFBundleIdentifier`. The obvious "personalized" choice is `com.<your-unix-username>.<slug>` — and it silently breaks.

## Decision

Default the prefix to `com.user.<slug>`. For projects with a real domain, country-coded reverse-DNS (e.g. `dk.example.<slug>`) is also clean. **Reject** any `com.$(id -un).*` prefix.

## Why

LaunchServices treats `com.<your-unix-username>.*` as a *personal-team developer* identity and may refuse to launch an unsigned bundle that claims it, failing with `_LSOpenURLs… error -600 / procNotFound`. The failure is non-deterministic across macOS versions and iCloud xattr state, so the only safe answer is to never use the prefix at all. `desktop-build.sh` warns when it sees the pattern; the skill rejects it outright.

## Consequences

- Bundle identifiers aren't personalized to the user — which is irrelevant, because these bundles are local-only and never distributed.
- One less class of "it worked on my machine, not after the macOS update" bug.
