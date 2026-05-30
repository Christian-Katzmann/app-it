# app-it Windows beta — ship the scaffold, recruit a maintainer

> Right now, app-it only works on Mac. This plan builds a clear Windows starting point — the basic plumbing, plus a friendly note inviting Windows users to help finish it — and ships it as "beta, looking for a co-builder" so no one is misled about what already works.

## Scope

Ship a `plugins/app-it-windows/` sibling plugin into the existing `app-it` repo, framed honestly as a beta. The scaffold mirrors the macOS plugin's contract (native shell, lifecycle, icon, install path) using Windows-native primitives — C# WPF + WebView2 host, PowerShell lifecycle scripts, multi-resolution `.ico` generation, Start Menu `.lnk` install. Christian is a Mac user and will not dogfood the result. The whole point of the release is to turn that limitation into a public invitation: a credible beta scaffold + a clear contributor doorway (`docs/WINDOWS.md`) + a Windows CI lane that prevents bit-rot. "Done" means the campaign ships as one PR on a `windows-beta` branch, validates green on both `macos-latest` and `windows-latest`, and the GitHub repo's README points at the new beta without diluting the macOS pitch.

## Context (locked decisions)

- **Repo:** `/Users/christiankatzmann/Dev/public-plugins-and-skills/app-it` — single repo, sibling plugins.
- **Branch:** `windows-beta` off `main`. Merge to `main` when Final review is APPROVED. One PR for the whole campaign so the repo never lives in an inconsistent "advertises a beta that isn't there" or "ships untested code under a Working/in-daily-use README" state.
- **Plugin path:** `plugins/app-it-windows/` as a sibling of `plugins/app-it/`. Not a fork, not a subfolder. Discrete plugin, discrete skill, discrete templates.
- **Native shell:** C# WPF + WebView2 (`Microsoft.Web.WebView2` NuGet), built via `dotnet publish` to a self-contained single-file `.exe`. Edge `--app=` as the Chrome-fallback equivalent.
- **Packaging:** folder with `.exe` + `.ico` + a `.lnk` shortcut placed in `%APPDATA%\Microsoft\Windows\Start Menu\Programs\app-it\`. No MSIX (too heavy for personal launchers). Honors `APP_IT_INSTALL_DIR`.
- **Lifecycle contract:** soft close (red X / minimize) keeps the dev server warm for fast relaunch; explicit quit terminates the PowerShell job and frees the port. Same promise as macOS Cmd+W vs Cmd+Q.
- **Signing:** unsigned. Document the SmartScreen "More info → Run anyway" click-through once in `docs/WINDOWS.md`. Self-signed certs are more friction than benefit for personal local launchers.
- **Icons:** `.ico` (multi-resolution: 16/32/48/256) generated from PNG/SVG. ImageMagick when present; `System.Drawing` PowerShell fallback for stock Windows.
- **Config schema:** identical to macOS `app-it.config.json`. An optional `platform.windows` block for Windows-specific fields (e.g., WebView2 user-data folder).
- **CI:** add a `windows-latest` job alongside the existing `macos-latest` job. Required for merge, so a maintainer's PR cannot regress the scaffold.
- **Framing:** every public artifact (README, COMPATIBILITY, CHANGELOG, CONTRIBUTING, the new WINDOWS.md, the SKILL.md `description` field) labels the Windows plugin as "beta · scaffolded · untested on real hardware · maintainer wanted." Never claim Windows works before a real maintainer has dogfooded it.
- **Out of scope:** MSIX packaging, code signing, auto-update, App Store / Microsoft Store distribution, Linux support, cross-platform abstractions across the macOS and Windows plugins.

## Unattended execution contract

This campaign runs fully unattended via `/claude-automate` — a chain of headless `claude --print` sessions, guarded by a watchdog, with no human at the keyboard. Every step MUST honor this contract or the run can stall for hours:

- **No interactive input, ever.** No step may pause for a prompt, confirmation, login, or `[y/N]` — there is no TTY to answer it.
- **Servers bind `127.0.0.1` only — never `0.0.0.0`/LAN.** A non-loopback listener triggers the macOS firewall "accept incoming connections?" dialog, which no flag can suppress and which blocks the whole run until someone clicks it. Use `--host 127.0.0.1` / `HOST=127.0.0.1`.
- **No blocking GUI/OS dialog.** Don't trip first-run macOS permission panels (screen recording, accessibility, Automation, Full Disk Access) or Gatekeeper. Strip quarantine from any downloaded binary (`xattr -dr com.apple.quarantine`); prefer brew/npm/uv over ad-hoc downloads.
- **No interactive auth.** No `gh auth login`, `ghost login`, MitID, or MCP `authenticate` mid-run — any credential a step needs must already be in place before launch.
- **Keep writes under the repo / `~/Dev`.** Avoid `~/Desktop`, `~/Documents`, `~/Downloads` (they trip macOS privacy prompts) unless Full Disk Access is pre-granted to the launcher.
- **A blocker means `fail` loudly, never `wait`.** If a prerequisite is missing, call `claude-automate fail` with a one-line reason so the watchdog escalates — never hang waiting for a human.

## How prompts work in this campaign

Each step activates a skill or runs a command and pastes a short prompt. The prompt provides only what the agent cannot know on its own:

- **Scope** — the specific thing this run is about.
- **Required reading** — file paths the agent must read first.
- **Output target** — where the result goes.
- **Open questions** — what to surface, not assume.

`<UPPERCASE_TOKENS>` are user-fillable placeholders. The Campaigns app shows an editable bar in the prompt card for them; copies use the substituted text.

## Progress checklist

### Phase 1 — Calibrate against the macOS implementation

- [x] Step 1.1 — Lock the Windows lifecycle contract (ADR 0005)

### Phase 2 — Build the runtime scaffold

- [x] Step 2.1 — Stand up the `app-it-windows` plugin shell + Windows `SKILL.md`
- [x] Step 2.2 — C# WPF + WebView2 host (`wrapper-windows`)
- [x] Step 2.3 — PowerShell lifecycle templates
- [x] Step 2.4 — Icon pipeline + Windows config block

### Phase 3 — Validate, frame, and recruit

- [x] Step 3.1 — Windows CI lane + `validate.sh` extension
- [ ] Step 3.2 — Framing docs (`WINDOWS.md`, `COMPATIBILITY` update, `README` beta callout, `CONTRIBUTING`)
- [ ] Final review

Each step heading is followed by a `Model:` line (recommended agent + thinking effort) and a `Parallel:` line (which sibling steps can run alongside it).

## Step 1.1 — Lock the Windows lifecycle contract (ADR 0005)

Model: Opus 4.8 1M · Extra High / GPT-5.5 · Extra High
Parallel: NO

This is the load-bearing thinking step. Read the macOS implementation end-to-end and produce a single decision record (ADR 0005) that names every Windows primitive against its macOS counterpart, plus the open questions only a real Windows user can answer. This document is the spec for steps 2.1–2.4 and the seed for `docs/WINDOWS.md`. No code in this step — just the decision document.

```text
SCOPE: Inventory the macOS app-it implementation and produce the Windows lifecycle contract. Single ADR at docs/decisions/0005-windows-beta-scope.md that supersedes (does not delete or rewrite) 0002 for the Windows lane.

REQUIRED READING:
1. plugins/app-it/skills/app-it/SKILL.md
2. plugins/app-it/skills/app-it/templates/wrapper.swift
3. plugins/app-it/skills/app-it/templates/desktop-build.sh
4. plugins/app-it/skills/app-it/templates/desktop-install.sh
5. plugins/app-it/skills/app-it/templates/desktop-quit.sh
6. plugins/app-it/skills/app-it/templates/run-template.sh
7. plugins/app-it/skills/app-it/templates/inspect.sh
8. plugins/app-it/skills/app-it/templates/info-plist-template.xml
9. plugins/app-it/skills/app-it/templates/app-it.config.example.json
10. docs/decisions/0001-native-webkit-shell.md
11. docs/decisions/0002-macos-only-scope.md
12. docs/decisions/0004-daemon-mode-lifecycle.md
13. docs/COMPATIBILITY.md (the "Why Windows Should Be Separate" section)

OUTPUT: docs/decisions/0005-windows-beta-scope.md. Sections:
- Status: Accepted (beta · maintainer wanted) · Supersedes 0002 for the Windows lane only.
- Native shell: WPF + WebView2. Self-contained single-file dotnet publish. Edge --app fallback.
- Packaging: folder with .exe + .ico + .lnk in %APPDATA%\Microsoft\Windows\Start Menu\Programs\app-it\. No MSIX. Honors APP_IT_INSTALL_DIR.
- Lifecycle primitives table — macOS column / Windows column / open-question column. Cover: launch the dev server, hold the port, soft-close vs hard-quit semantics, port-clean on quit, warm relaunch.
- Signing: unsigned. SmartScreen first-run click-through documented in WINDOWS.md.
- Icons: .ico from PNG/SVG, multi-resolution (16/32/48/256). ImageMagick when present, System.Drawing fallback.
- Config: same app-it.config.json schema as macOS; optional `platform.windows` block for Windows-specifics.
- Deferred-to-maintainer list: every decision a Mac user cannot honestly validate from a Mac. Name them.

OPEN QUESTIONS:
- WPF vs WinUI 3 for the host. Start with WPF for stability, or commit to WinUI 3? Beta default: WPF.
- Self-contained dotnet publish (~80MB) vs framework-dependent (~1MB + .NET runtime install). Beta default: self-contained, no runtime install required.
- Should the .lnk land in Start Menu only, or also offer a Taskbar pin / Desktop shortcut?
- How does WPF distinguish "user closed the window" from "user quit the app" (the macOS Cmd+W vs Cmd+Q distinction)? Document the answer.

FORWARD SWEEP: before checking this step off, do a quick pass over the campaign's remaining step prompts. If your work moved a path, changed a contract or shape, or invalidated an assumption a later step leans on, make a surgical edit there. A quick sweep, not a rewrite — skip it if nothing downstream changed.
```

## Step 2.1 — Stand up the `app-it-windows` plugin shell + Windows `SKILL.md`

Model: Opus 4.8 · Extra High / GPT-5.5 · Extra High
Parallel: NO

Create `plugins/app-it-windows/` as a sibling of `plugins/app-it/` with full `.claude-plugin` and `.codex-plugin` manifests, and write `skills/app-it-windows/SKILL.md` — adapted from the macOS skill but mirroring the contract from ADR 0005. This is the entry point an assistant invokes; it's the highest-leverage file in the new plugin. The `description` field on the skill must state the beta status, so an assistant never accidentally presents this as a finished feature.

```text
/skill-creator

SCOPE: Stand up plugins/app-it-windows/ as a sibling plugin. Mirror the existing plugins/app-it/ structure: .claude-plugin/, .codex-plugin/, skills/app-it-windows/{SKILL.md,templates/}. The SKILL.md invokes the same shape of work as the macOS skill, translated to Windows primitives from ADR 0005.

REQUIRED READING:
1. plugins/app-it/.claude-plugin/
2. plugins/app-it/.codex-plugin/
3. plugins/app-it/skills/app-it/SKILL.md
4. docs/decisions/0005-windows-beta-scope.md (from step 1.1)

OUTPUT:
- plugins/app-it-windows/.claude-plugin/ (manifest, mirroring the macOS one)
- plugins/app-it-windows/.codex-plugin/ (manifest, mirroring the macOS one)
- plugins/app-it-windows/skills/app-it-windows/SKILL.md
- plugins/app-it-windows/skills/app-it-windows/templates/ (empty — populated in 2.2–2.4)

OPEN QUESTIONS:
- Plugin slug: `app-it-windows`, `app-it-win`, or `desktop-it-windows`? Pick one and commit; the framing docs in 3.2 will be updated to match.
- The SKILL.md `description` is the discovery hook for assistants. State the Windows beta status directly: "Windows beta · maintainer wanted · scaffolded but not battle-tested on real hardware." A user-facing skill should never imply more than that.

The SKILL.md must include the same inspect → strategy → build → verify decision logic as the macOS skill, translated to Windows primitives. Where a decision cannot be made without a Windows machine, the skill must fail with a clear "this needs a Windows maintainer — see docs/WINDOWS.md" rather than guess.

FORWARD SWEEP: before checking this step off, do a quick pass over the campaign's remaining step prompts. If your work moved a path, changed a contract or shape, or invalidated an assumption a later step leans on, make a surgical edit there.
```

## Step 2.2 — C# WPF + WebView2 host (`wrapper-windows`)

Model: Opus 4.8 · Extra High / GPT-5.5 · Extra High
Parallel: YES — with Step 2.3 and Step 2.4

The Windows equivalent of `wrapper.swift`. A small `.csproj` + a handful of C# files that compile via `dotnet publish` into a self-contained single-file `.exe`. The window owns the title and icon (so the Taskbar entry is the app, not Edge). The "soft close keeps the dev server warm vs hard quit frees the port" distinction is wired through the window's Closing event and a JobObject around the dev-server process.

```text
SCOPE: Write the C# WPF + WebView2 host that mirrors plugins/app-it/skills/app-it/templates/wrapper.swift. Single-folder, single-file-publish friendly.

REQUIRED READING:
1. plugins/app-it/skills/app-it/templates/wrapper.swift
2. docs/decisions/0005-windows-beta-scope.md (Lifecycle primitives table)

OUTPUT: plugins/app-it-windows/skills/app-it-windows/templates/wrapper-windows/
- wrapper.csproj — net8.0-windows, UseWPF=true, PublishSingleFile=true, SelfContained=true, RuntimeIdentifier=win-x64. Microsoft.Web.WebView2 NuGet dependency.
- MainWindow.xaml — minimal: a single WebView2 fills the window. Title and icon bind to config values passed in.
- MainWindow.xaml.cs — load URL from a runtime argument or env var. Handle the Closing event to distinguish soft-close (hide window, leave dev-server PowerShell job alive) from explicit quit (terminate the job, free the port).
- App.xaml + App.xaml.cs — application bootstrap, command-line argument parsing for URL / title / icon path.
- README.md — three sentences max: "this is the wrapper, dotnet publish builds it, see docs/WINDOWS.md for what's untested." No more.

OPEN QUESTIONS:
- macOS uses an LSUIElement-style daemon trick for warm relaunch (ADR 0004). What is the equivalent on Windows — a hidden tray icon, a named pipe, a kept-alive job? If you can't pick with confidence, default to "minimize to tray" with a TODO comment and a maintainer note in the folder's README.
- WebView2 user-data folder location: pick a path under %LOCALAPPDATA%\app-it\<slug>\ and document it in the README.

This step does NOT need a Windows machine to write — `dotnet build` and `dotnet publish --runtime win-x64` work cross-platform from macOS for compilation. The CI lane in 3.1 is what verifies the build completes on windows-latest.

FORWARD SWEEP: before checking this step off, do a quick pass over the campaign's remaining step prompts. If your work moved a path, changed a contract or shape, or invalidated an assumption a later step leans on, make a surgical edit there.
```

## Step 2.3 — PowerShell lifecycle templates

Model: Opus 4.8 · Extra High / GPT-5.5 · Extra High
Parallel: YES — with Step 2.2 and Step 2.4

Translate the macOS `.sh` templates (`desktop-build`, `desktop-install`, `desktop-quit`, `inspect`, `run-template`, `run-template-chrome`) to `.ps1` counterparts that honor the same lifecycle contract. Each `.ps1` opens with a one-sentence comment naming its macOS sibling, so a reviewer can read them side by side.

```text
SCOPE: Port the macOS shell templates to PowerShell. Honor the contract from ADR 0005. Each .ps1 mirrors a .sh sibling and produces the equivalent side-effect.

REQUIRED READING:
1. plugins/app-it/skills/app-it/templates/desktop-build.sh
2. plugins/app-it/skills/app-it/templates/desktop-install.sh
3. plugins/app-it/skills/app-it/templates/desktop-quit.sh
4. plugins/app-it/skills/app-it/templates/inspect.sh
5. plugins/app-it/skills/app-it/templates/run-template.sh
6. plugins/app-it/skills/app-it/templates/run-template-chrome.sh
7. docs/decisions/0005-windows-beta-scope.md
8. plugins/app-it-windows/skills/app-it-windows/templates/wrapper-windows/README.md (step 2.2 — the host's CLI arg contract + the published `app-it-host.exe` name these scripts must target)

OUTPUT: plugins/app-it-windows/skills/app-it-windows/templates/
- desktop-build.ps1 — runs `dotnet publish` on the wrapper-windows project, copies the .exe + .ico into desktop/<App Name>/.
- desktop-install.ps1 — creates the Start Menu shortcut at %APPDATA%\Microsoft\Windows\Start Menu\Programs\app-it\<App Name>.lnk via WScript.Shell COM. Honors APP_IT_INSTALL_DIR.
- desktop-quit.ps1 — Get-NetTCPConnection to find the port owner, Stop-Process. Matches the lsof+kill behaviour of the macOS version.
- inspect.ps1 — reads scripts/app-it.config.json, prints a Windows-shaped report. Detects WebView2 runtime presence, .NET SDK presence, port collisions.
- run-template.ps1 — the **thin bootstrap** (ADR 0005 seam): augment PATH, pre-flight, scan a free port on 127.0.0.1, then launch the WPF host (`app-it-host.exe`) with the resolved args (`--url --title --icon --slug --port --start-command --working-dir`). The **host** creates the JobObject and spawns the dev server into it — run-template.ps1 must NOT own a job itself (a job created by the short-lived script would close and kill the server when the script returns). Binds 127.0.0.1 only — never 0.0.0.0. (The W-Edge fallback is the one exception — see run-template-edge.ps1.)
- run-template-edge.ps1 — Edge --app=URL fallback (no wrapper, no custom icon). Equivalent of run-template-chrome.sh.

OPEN QUESTIONS:
- The macOS run-template.sh detects the dev script (npm run dev, pnpm dev, etc.) via package.json scripts. Replicate the same heuristic on Windows? Default: yes.
- 127.0.0.1 vs 0.0.0.0 on Windows: confirm the firewall-prompt avoidance is the same shape as macOS. State the choice in run-template.ps1 comments.

Each script's first comment line names what its macOS sibling does, so a reviewer can read them side-by-side.

FORWARD SWEEP: before checking this step off, do a quick pass over the campaign's remaining step prompts. If your work moved a path, changed a contract or shape, or invalidated an assumption a later step leans on, make a surgical edit there.
```

## Step 2.4 — Icon pipeline + Windows config block

Model: Sonnet 4.6 · High / GPT-5.5 · High
Parallel: YES — with Step 2.2 and Step 2.3

Small, contained: PNG/SVG → multi-resolution `.ico`, plus extending the config example to show the optional `platform.windows` block. The placeholder generator means the build never fails on a missing icon.

```text
SCOPE: Add the Windows icon pipeline and a Windows-aware config example. PNG/SVG in, multi-resolution .ico out, plus a placeholder generator.

REQUIRED READING:
1. plugins/app-it/skills/app-it/templates/desktop-icons.sh
2. plugins/app-it/skills/app-it/templates/placeholder-icon-gen.sh
3. plugins/app-it/skills/app-it/templates/app-it.config.example.json
4. docs/decisions/0005-windows-beta-scope.md (icon section)

OUTPUT:
- plugins/app-it-windows/skills/app-it-windows/templates/desktop-icons.ps1 — PNG/SVG → 16/32/48/256 multi-resolution .ico. ImageMagick path when present (faster); System.Drawing fallback so it works on stock Windows. CONTRACT WITH STEP 2.3: desktop-build.ps1 already invokes this script per-app with `$env:APP_NAME`, `$env:APP_SLUG`, and `$env:APP_IT_PROJECT_ROOT` set, then expects the finished icon at `<root>\desktop\<App Name>\<App Name>.ico` (desktop-install.ps1 points the .lnk IconLocation there, and the host's --icon flag reads the same path). Honor exactly that input (the three env vars) and that output path; when no source art exists, fall back to placeholder-icon-gen.ps1 so the build never fails on a missing icon.
- plugins/app-it-windows/skills/app-it-windows/templates/placeholder-icon-gen.ps1 — generates a placeholder .ico the same way placeholder-icon-gen.sh generates an .icns, so the build never fails on a missing icon.
- plugins/app-it-windows/skills/app-it-windows/templates/app-it.config.example.json — same schema as macOS, with a documented optional `platform.windows` block (e.g., webview2_user_data_dir).

OPEN QUESTIONS:
- Worth adding 64 and 128 to the .ico container? Cheap if useful — make the call and document.

FORWARD SWEEP: before checking this step off, do a quick pass over the campaign's remaining step prompts. If your work moved a path, changed a contract or shape, or invalidated an assumption a later step leans on, make a surgical edit there.
```

## Step 3.1 — Windows CI lane + `validate.sh` extension

Model: Sonnet 4.6 · High / GPT-5.5 · High
Parallel: YES — with Step 3.2

A `windows-latest` GitHub Actions job that minimally guarantees the scaffold cannot bit-rot: PowerShell linting, `dotnet build`, manifest validity, placeholder icon round-trip. Plus a small `scripts/validate.sh` update so macOS contributors see "Windows plugin present (beta) — validated in CI" rather than a silent gap.

```text
SCOPE: Add a Windows CI lane that catches the things Christian (Mac-only) cannot. Extend scripts/validate.sh to acknowledge the Windows plugin without pretending to validate it from macOS.

REQUIRED READING:
1. .github/workflows/ci.yml
2. scripts/validate.sh
3. plugins/app-it-windows/ (whole new tree from steps 2.x)
4. .claude-plugin/marketplace.json and .agents/plugins/marketplace.json (both still list only app-it as of step 2.1)

OUTPUT:
- .github/workflows/ci.yml — add a windows-latest job alongside the existing macos-latest job. It must:
  - Lint every .ps1 in plugins/app-it-windows/skills/app-it-windows/templates/ via `Invoke-ScriptAnalyzer -Severity Error,Warning`.
  - `dotnet restore` and `dotnet build` the wrapper-windows project.
  - Parse-validate the plugin manifests (.claude-plugin + .codex-plugin) as JSON/TOML.
  - Run placeholder-icon-gen.ps1 end-to-end and verify it produces a readable .ico.
- .claude-plugin/marketplace.json AND .agents/plugins/marketplace.json — register app-it-windows as a second plugin entry (source ./plugins/app-it-windows), mirroring the existing app-it entry. Step 2.1 deliberately left these untouched (a sibling plugin isn't truly installable until registered, but registering it breaks validate.sh's hardcoded single-plugin assertions — which this step owns). Keep the beta framing in the entry's description/tags.
- scripts/validate.sh — (1) generalize the hardcoded `len(market["plugins"]) == 1` and `plugins[0]`-by-index assertions to look up entries by name and assert BOTH app-it and app-it-windows are present and well-formed; (2) require the new files (both app-it-windows manifests + SKILL.md); (3) print a clear "Windows plugin present (beta) — validated in CI, not on macOS — see docs/WINDOWS.md" notice; do not pretend to validate the .ps1 / .cs from a Mac. NOTE: validate.sh is already red at HEAD — its `grep -R "/Users/..."` local-absolute-path guard now trips on campaigns/windows-beta.md (committed during this campaign). Exclude campaigns/ (or the *.md campaign files) from that guard so macOS CI can go green; the campaign markdown legitimately contains absolute paths.

OPEN QUESTIONS:
- Required for merge, or advisory? Recommendation: required, so a maintainer's PR cannot accidentally regress the scaffold. State that in the workflow's comments.

FORWARD SWEEP: before checking this step off, do a quick pass over the campaign's remaining step prompts. If your work moved a path, changed a contract or shape, or invalidated an assumption a later step leans on, make a surgical edit there.
```

## Step 3.2 — Framing docs (`WINDOWS.md`, `COMPATIBILITY` update, `README` beta callout, `CONTRIBUTING`)

Model: Opus 4.8 · Extra High / GPT-5.5 · Extra High
Parallel: YES — with Step 3.1

The recruitment doorway. The prose that turns a half-built scaffold into a credible "we shipped a beta, looking for a maintainer" signal — without overpromising or diluting the macOS pitch. Voice has to match the existing README's calm, slightly proud, never-overpromising register; read the macOS README once before writing and rewrite if the new prose feels louder or more eager.

```text
SCOPE: Write the framing docs that ship alongside the scaffold. Tone throughout: "honest beta, maintainer wanted, full credit." Never claim Windows works; always say "scaffolded, awaiting a Windows maintainer to dogfood."

REQUIRED READING:
1. README.md
2. docs/COMPATIBILITY.md
3. CONTRIBUTING.md
4. docs/decisions/0005-windows-beta-scope.md
5. plugins/app-it-windows/skills/app-it-windows/SKILL.md (from step 2.1)

OUTPUT:
- docs/WINDOWS.md (new) — the recruitment doorway. Sections:
  - First line / status badge: "Windows beta · scaffolded · untested on real hardware · maintainer wanted"
  - "I'm a Mac user. Here's why this exists." (one paragraph, in the same plain voice as the README)
  - The Windows contract (cribbed from ADR 0005, prose-shaped)
  - "What works (in theory)" — the scaffold's coverage, with honest qualifiers
  - "What a first PR looks like" — three concrete examples in priority order (e.g., "verify the WPF host actually launches a window and renders a URL", "verify the Start Menu .lnk lands and the icon shows up in the taskbar", "fix the first round of PowerShell scope/quoting bugs")
  - "What we'll do for you" — fast review, full credit in CHANGELOG, co-maintainer status if you stick around
  - First-contact path: Issues with a `windows-maintainer` label (or Discussions — pick one and commit).
- docs/COMPATIBILITY.md — move Windows from "Not Supported" to a "Beta · maintainer wanted" row. Update the "Why Windows Should Be Separate" paragraph to point at plugins/app-it-windows/ as the live scaffold instead of a hypothetical future plugin. Keep the section honest about what's not validated.
- README.md — add a small "Windows beta" callout near the Status line. Don't restructure the README. The macOS pitch stays exactly as-is — the callout is one short paragraph and a link to docs/WINDOWS.md. Tone: "macOS is in daily use; Windows is scaffolded as a beta and looking for a maintainer."
- CONTRIBUTING.md — add a "Windows maintainer wanted" section near the top. Point at docs/WINDOWS.md as the entry door.
- CHANGELOG.md — add an `[Unreleased]` entry: "Added: Windows beta scaffold (`plugins/app-it-windows/`) — untested on real hardware, looking for a maintainer."

OPEN QUESTIONS:
- Discussions on or off? If off, the maintainer-wanted entry point is a `windows-maintainer`-labeled Issue. Pick one and make the recommendation explicit in the file.

The voice has to match the existing README's calm, slightly proud, never-overpromising register. If the new prose feels louder or more eager than the macOS README, rewrite.

FORWARD SWEEP: before checking this step off, do a quick pass over the campaign's remaining step prompts. If your work moved a path, changed a contract or shape, or invalidated an assumption a later step leans on, make a surgical edit there.
```

## Final review

A campaign-level final review catches **cross-phase shortcuts** — a primitive set up in one phase silently bypassed by another, intent claimed in one step but not delivered when read across the whole campaign. Run it once every phase is complete. The user copies the prompt below, opens a fresh Codex or Claude Code session in the repo, and pastes:

```text
Run a final review on the app-it Windows beta campaign.

Plan: /Users/christiankatzmann/Dev/public-plugins-and-skills/app-it/campaigns/windows-beta.md
Campaign: campaigns/windows-beta.md

Read every `## Step N.M — name` heading in the campaign markdown. For each, locate the acceptance criteria in its prompt body, and verify against the cumulative git diff (vs main) on the windows-beta branch that the criteria actually landed. Don't trust step receipts — read the diff.

Catch cross-step shortcuts: the lifecycle contract in ADR 0005 silently bypassed by a .ps1 in step 2.3; the SKILL.md from 2.1 promising templates that 2.2–2.4 didn't deliver; the framing in 3.2 claiming more than the scaffold honestly provides; the CI lane in 3.1 not actually exercising what 2.2–2.4 produced. Dead code or orphaned references count.

Be especially honest about the framing: every public artifact (README callout, COMPATIBILITY row, WINDOWS.md, CHANGELOG, SKILL.md description) must label the Windows plugin as beta · maintainer wanted · not battle-tested. Anything that overstates is a NEEDS WORK.

Be honest. Lean. APPROVED if every step's acceptance criteria landed, CI is green on both macos-latest and windows-latest, and the framing is consistent across all public artifacts. NEEDS WORK if any step cut corners or a primitive was bypassed.

Don't pad with future improvements. Just verdict the work.

Run with either:
- Codex: GPT-5.5 with Extra High reasoning effort
- Claude Code: Opus 4.8 with Extra High thinking
(Your call — both are acceptable for this kind of cross-file review.)
```

**Verdict-to-action mapping:**

- **APPROVED** → tick the `Final review` checkbox at the end of the progress checklist (or click "Close campaign"). Merge the `windows-beta` branch to `main`. Open the recruitment thread on Discussions/Issues using the maintainer-wanted template.
- **NEEDS WORK** → reopen the named steps, close the gaps, re-run the final review. Don't tick the checkbox until APPROVED.
