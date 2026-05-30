# REJECTED — Auto-attach to an already-running dev server

**Proposal:** If something is already listening on the preferred port when the app launches, just point the window at it instead of starting our own server.

**Why it's attractive:** it's faster, it sidesteps "port already in use," and when the path and framework match it *feels* obviously correct — surely that's our server already running.

**Why it's wrong:** "matching framework and port" is not proof the listener is *ours*. The cost of being wrong is showing the user **another project's UI inside this app's window** — a confusing, hard-to-diagnose failure. A bare `curl → 200 → attach` will do exactly that the first time two projects share a port range.

**What we do instead:** a permissive *descendant-walk reattach* gate. Reattach only when all hold — the recorded supervisor PID is alive, the listener bound to the recorded port is inside that PID's descendant tree (walked up to 4 levels, since the real listener is often a great-grandchild of `pnpm dev`), and it responds to HTTP. Otherwise, scan upward from the preferred port for a free one and start our own server. Detail in `run-template.sh` and the [SKILL.md](../../../plugins/app-it/skills/app-it/SKILL.md) anti-patterns.

**When it might become right:** never as a bare port-match. The ownership-tree check is the floor, not an optimization to skip.
