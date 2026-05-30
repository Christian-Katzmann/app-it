# 0001 — Native WebKit shell as the default launcher

**Status:** Accepted

## Context

The launcher has four jobs that decide whether an appified project feels like a real app or a hack: keep the app's *own* Dock icon, activate the existing window on a re-click (don't spawn duplicates), start fast, and tell a window-close (red-X) apart from a real quit (⌘Q).

## Decision

Default to a small (~230-line) Swift `WKWebView` shell that app-it compiles per build (universal arm64 + x86_64). It becomes the `.app`'s foreground process, so the Dock icon and single-instance activation are handled natively by `NSApplication`.

## Alternatives considered

- **Chrome `--app=`** — steals the Dock icon while a window is open, opens a duplicate window on re-click, has multi-second profile-init latency, and can't distinguish red-X from ⌘Q. These are *structural* to Chrome, not patchable. Kept as a deliberate fallback only for Chromium-only Web APIs (File System Access real-I/O, WebUSB/Bluetooth/HID/MIDI) — see [REJECTED/electron-or-tauri-by-default](REJECTED/electron-or-tauri-by-default.md) for the heavyweight options and [SKILL.md](../../plugins/app-it/skills/app-it/SKILL.md) Strategy A1 for the comparison table.
- **AppleScript / Automator wrapper** — no real window or lifecycle control; can't own the Dock identity.

## Consequences

- Requires `swiftc` (Xcode Command Line Tools). When absent, the build auto-falls back to the Chrome launcher and says so.
- The wrapper, not Chrome, is what makes the daily-use polish (own icon, fast re-launch, ⌘Q vs red-X) possible — which is the whole point of the tool.
