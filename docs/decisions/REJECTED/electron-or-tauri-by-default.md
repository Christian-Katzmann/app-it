# REJECTED — Electron or Tauri by default

**Proposal:** Default to Electron (or Tauri) to "do desktop properly" instead of a hand-rolled WebKit shell.

**Why it's attractive:** it's the industry-standard answer. Real native menus, tray icons, system notifications, file associations, and a signed-distribution story all come in the box. Reaching for Electron looks more serious than compiling a 230-line Swift file.

**Why it's wrong for app-it:** app-it's job is to make an *existing local project* clickable for *personal, daily use* — not to ship software to other people. Electron drags in a second runtime (~150–200 MB per app), a bundler in the project's dependency tree, and a migration step. Tauri adds a Rust toolchain and a wrapper sub-project. Both are heavyweight for "I just want this on my Dock," and both violate the skill's contract of *additive, reversible, no-new-runtime-dependencies* changes. The native WebKit shell delivers the actual daily-use wins (own Dock icon, single-instance, `~200 ms` launch) at near-zero cost — see [decision 0001](../0001-native-webkit-shell.md).

**When it might become right:** when a specific project genuinely needs native menus, a tray, custom URL-protocol handlers, file-association handling, or signed bundles for other users. Then a *minimal* Tauri wrapper (Strategy D in [SKILL.md](../../../plugins/app-it/skills/app-it/SKILL.md)) is the documented escape hatch — chosen deliberately for that project, never as the default.
