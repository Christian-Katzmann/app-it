#!/usr/bin/env bash
# install.sh - manually install app-it as a plain skill into Claude Code and/or Codex.
#
# Marketplace install is preferred. This script is for local development or users
# who want to copy the skill folder directly.
#
# Usage:
#   ./install.sh               # auto-detect tools, ask before overwrite
#   ./install.sh --force       # overwrite without asking
#   ./install.sh --claude      # install only into Claude Code
#   ./install.sh --codex       # install only into Codex
#   ./install.sh --dry-run     # show what would happen, write nothing

set -euo pipefail

if ((BASH_VERSINFO[0] < 4)); then
  echo "note: bash ${BASH_VERSION} detected (macOS default is 3.2)." >&2
  echo "      If you hit issues, upgrade: brew install bash" >&2
fi

SKILL_NAME="app-it"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$ROOT_DIR/plugins/$SKILL_NAME/skills/$SKILL_NAME"

CLAUDE_TARGET="$HOME/.claude/skills/$SKILL_NAME"
CODEX_TARGET="$HOME/.codex/skills/$SKILL_NAME"

force=0
dry_run=0
claude_only=0
codex_only=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) force=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --claude) claude_only=1; shift ;;
    --codex) codex_only=1; shift ;;
    -h|--help)
      awk 'NR>1{if(/^#/){sub(/^# ?/,""); print} else exit}' "$0"
      exit 0
      ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -f "$SRC_DIR/SKILL.md" ]]; then
  echo "error: missing skill at $SRC_DIR/SKILL.md" >&2
  exit 1
fi

install_to() {
  local target="$1"
  local label="$2"

  if [[ -e "$target" && $force -eq 0 ]]; then
    read -r -p "  $label install exists at $target - overwrite? [y/N] " yn
    if [[ ! "$yn" =~ ^[Yy]$ ]]; then
      echo "  skipped $label"
      return
    fi
  fi

  if [[ $dry_run -eq 1 ]]; then
    echo "  [dry-run] would copy $SRC_DIR to $target"
    return
  fi

  rm -rf "$target"
  mkdir -p "$(dirname "$target")"
  rsync -a "$SRC_DIR/" "$target/"
  echo "  installed $label -> $target"
}

detected=0

if [[ $codex_only -eq 0 ]]; then
  if [[ -d "$HOME/.claude" ]]; then
    echo "Claude Code detected."
    install_to "$CLAUDE_TARGET" "Claude Code"
    detected=1
  elif [[ $claude_only -eq 1 ]]; then
    echo "warn: --claude specified but ~/.claude not found" >&2
  fi
fi

if [[ $claude_only -eq 0 ]]; then
  if [[ -d "$HOME/.codex" ]]; then
    echo "Codex detected."
    install_to "$CODEX_TARGET" "Codex"
    detected=1
  elif [[ $codex_only -eq 1 ]]; then
    echo "warn: --codex specified but ~/.codex not found" >&2
  fi
fi

if [[ $detected -eq 0 ]]; then
  echo "error: neither ~/.claude nor ~/.codex found." >&2
  echo "Install Claude Code or Codex first, then re-run." >&2
  exit 1
fi

echo
echo "Done. Reload your tool and try: /app-it"
