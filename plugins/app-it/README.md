# App It

Turn a local web project or hosted web URL into a clickable macOS Dock app.
This is a skills-only plugin. It contains one skill, templates and reference
material. It has no MCP server, OAuth integration, lifecycle hook or paid API.

## Supported host

Use a local macOS coding-agent host with authorized filesystem and shell access
and a graphical login session for window verification. Cloud-only ChatGPT,
iOS, Windows and Linux cannot execute this workflow. A portable manifest does
not make the native macOS toolchain portable.

Required before use: Apple Xcode Command Line Tools (`xcode-select -p`, `swiftc`
and `clang`), `/usr/bin/python3`, macOS shell utilities, and the local project's
runtime and installed dependencies. A typical JavaScript project needs Node.js
and its chosen package manager. Hosted-URL wrappers need network access to the
user-selected site. Chrome fallback requires a separately installed Google
Chrome; SVG icon conversion may need `rsvg-convert` or ImageMagick when the
system converter cannot read the source. PNG icons use macOS utilities only.
Do not install system software or incur charges without user authorization.

## Use

Ask the agent: “Make this local web project launchable from my macOS Dock.”
The skill inspects the selected project, copies its bundled templates, builds
and installs a launcher under `~/Applications/App It/`, and verifies its
runtime. Local server state and logs use `~/Library/Application Support/app-it/`
and `~/Library/Logs/app-it/`. Window close keeps the local server warm;
Cmd+Q stops the launcher's owned runtime. Unrelated servers must remain alive.

The installer refreshes the Dock when icon bytes change. Set
`APP_IT_REFRESH_DOCK=0` to skip that refresh during an unattended install.

The generated app refers to the original project location; it does not bundle
that project's dependencies. Rebuild after moving the project. It is for
personal local use and is not a notarized application distribution system.
Hosted content and login remain with the selected website. Compatibility with
every site, browser API or external login flow is not guaranteed.

See [the skill](skills/app-it/SKILL.md), [privacy draft](PRIVACY.md),
[license](LICENSE), [dependencies and ownership](DEPENDENCIES.md), and
[terms](TERMS.md). Support: [GitHub issues](https://github.com/Christian-Katzmann/app-it/issues).
Do not post secrets, private project content or unredacted logs in public issues.

## Publication status

This is a local review candidate, not an approved public plugin. The publisher
must approve and publish the privacy policy and set its verified public HTTPS
URL before submission. The deterministic bundled listing icon is provisional
and needs publisher approval. No privacy URL is declared while the expanded
policy is only a local draft. Developer identity and public listing eligibility
for this macOS-only workflow must be confirmed in the submission dashboard.
