# Contributing

## Windows maintainer wanted

The Windows lane (`plugins/app-it-windows/`) is a **beta scaffold** — built from macOS and gated by a required `windows-latest` CI job, but never run on real Windows hardware, because the author runs only macOS. If you're a Windows user, this is the highest-leverage contribution in the repo: verifying the seams a Mac can't. Fast review, full credit in the changelog, co-maintainer status if you stick around. Start at **[docs/WINDOWS.md](docs/WINDOWS.md)** — it lays out what works in theory, what a first PR looks like, and how to claim a check.

## macOS contributions

This repo is intentionally narrow: make local web projects launchable from the macOS Dock.

Good contributions improve one of these:

- macOS launcher reliability.
- Project inspection accuracy.
- Reversibility and cleanup.
- Clearer docs for edge cases.
- Safer verification.

Please avoid broadening the macOS plugin into general desktop-app distribution, signed customer releases, or Electron migration. Those are different products. Windows support is welcome — but as the sibling `plugins/app-it-windows/` plugin (see above), never as a cross-platform flag bolted onto the macOS one.

Before opening a PR:

```bash
./scripts/validate.sh
```

If your change updates user-visible behavior, add a short note to `CHANGELOG.md`.

## Recognition

Contributors show up in GitHub's own contributors list — and not just for code. Testing on real hardware, packaging, bug reports, and ideas all earn a mention in the README's community thanks. If a contribution doesn't already credit you, say so in your PR (or open an issue) and the maintainer will add you.
