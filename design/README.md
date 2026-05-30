# Design assets

The visual system for `app-it`. One brand color, a calm low-contrast palette, realistic Nordic demo data, and screenshots that are *real generated output* — never mockups.

## Assets

| File | What it is | Size |
| --- | --- | --- |
| `screenshots/01-hero.png` | README hero — a real app-it build on a brand canvas | 2000×1125 |
| `screenshots/02-native-window.png` | The same window, clean, for reuse | 1600×1071 |
| `social/social-preview.png` | GitHub social preview poster | 2560×1280 (2:1) |
| `motion/app-it-lifecycle.gif` | Looping lifecycle: launch → window → ⌘Q | 920×518 |

## Brand

- **Accent:** `#2F6FED` (the plugin's `brandColor`). Used semantically — one accent, not decoration.
- **Palette:** warm-cool paper (`#f4f6f8`), ink (`#1b2430`), hairlines (`#e7eaee`). Calm, hierarchical, public-sector-credible — not dashboard-noisy.
- **Type:** the native macOS stack (`-apple-system` / SF). app-it lives on macOS; leaning into the system face is honest, not generic.
- **Wordmark:** `app` in ink, `-it` in accent.

## How the hero was made (it's real)

The hero is not a render of an imagined product. It is `app-it` run on itself:

1. A tiny real web project — `Fjord`, a calm local "today" board (`node server.js`) — was built in a throwaway folder.
2. The actual skill templates (`desktop-build.sh`, `wrapper.swift`, …) turned it into a real `.app`, ad-hoc-signed, installed to `~/Applications/App It/`.
3. The running native window was captured by its window id (clean, shadowed, no desktop clutter) with `screencapture -l`.
4. That real window was composed onto a brand canvas with the real generated Dock icon.

So the existence *is* the proof: the product had to run to produce the picture. To regenerate, re-run the steps above and re-export the composition.

## The motion artifact

`motion/app-it-lifecycle.gif` choreographs the launch → native-window → ⌘Q lifecycle using that *same* real window capture and generated icon — so it and the hero are the same provenance, just still vs. moving. It's built deterministically: `motion/lifecycle.source.html` renders frame `?f=<i>&n=<total>`, the frames are screenshotted headless, and ImageMagick assembles the optimized loop. Re-render the frames and re-run `magick -delay 6 -loop 0 frame_*.png -layers optimize` to regenerate.

