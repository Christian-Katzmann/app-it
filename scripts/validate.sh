#!/usr/bin/env bash
# Validate the standalone app-it plugin repo.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
  echo "error: $*" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "missing required file: $1"
}

# --- macOS plugin files -------------------------------------------------------
require_file ".claude-plugin/marketplace.json"
require_file "plugins/app-it/.claude-plugin/plugin.json"
require_file "plugins/app-it/.codex-plugin/plugin.json"
require_file ".agents/plugins/marketplace.json"
require_file "plugins/app-it/skills/app-it/SKILL.md"
require_file "plugins/app-it/skills/app-it/templates/wrapper.swift"
require_file "plugins/app-it/skills/app-it/templates/desktop-build.sh"
require_file "plugins/app-it/skills/app-it/templates/desktop-doctor.sh"
require_file "README.md"
require_file "LICENSE"

# --- app-it-static plugin files (companion: serve a finished build) -----------
require_file "plugins/app-it-static/.claude-plugin/plugin.json"
require_file "plugins/app-it-static/.codex-plugin/plugin.json"
require_file "plugins/app-it-static/skills/app-it-static/SKILL.md"
require_file "plugins/app-it-static/skills/app-it-static/templates/wrapper.swift"
require_file "plugins/app-it-static/skills/app-it-static/templates/static-server.py"
require_file "plugins/app-it-static/skills/app-it-static/templates/run-template-static-server.sh"
require_file "plugins/app-it-static/skills/app-it-static/templates/run-template-static-file.sh"
require_file "plugins/app-it-static/skills/app-it-static/templates/desktop-build.sh"

# --- Windows plugin files (beta) ---------------------------------------------
require_file "plugins/app-it-windows/.claude-plugin/plugin.json"
require_file "plugins/app-it-windows/.codex-plugin/plugin.json"
require_file "plugins/app-it-windows/skills/app-it-windows/SKILL.md"

python3 - <<'PY'
import json
from pathlib import Path

plugin       = json.loads(Path("plugins/app-it/.claude-plugin/plugin.json").read_text())
market       = json.loads(Path(".claude-plugin/marketplace.json").read_text())
codex_plugin = json.loads(Path("plugins/app-it/.codex-plugin/plugin.json").read_text())
codex_market = json.loads(Path(".agents/plugins/marketplace.json").read_text())
win_plugin   = json.loads(Path("plugins/app-it-windows/.claude-plugin/plugin.json").read_text())
win_codex    = json.loads(Path("plugins/app-it-windows/.codex-plugin/plugin.json").read_text())
static_plugin = json.loads(Path("plugins/app-it-static/.claude-plugin/plugin.json").read_text())
static_codex  = json.loads(Path("plugins/app-it-static/.codex-plugin/plugin.json").read_text())

# app-it plugin assertions
assert plugin["name"] == "app-it"
assert plugin["version"]
assert plugin["skills"] == "./skills/"

# Marketplace assertions — look up by name so adding more plugins doesn't break this
market_by_name = {e["name"]: e for e in market["plugins"]}
assert "app-it" in market_by_name, "marketplace.json missing app-it entry"
assert "app-it-windows" in market_by_name, "marketplace.json missing app-it-windows entry"
assert "app-it-static" in market_by_name, "marketplace.json missing app-it-static entry"
entry = market_by_name["app-it"]
assert entry["source"] == "./plugins/app-it"
assert entry["version"] == plugin["version"]
win_entry = market_by_name["app-it-windows"]
assert win_entry["source"] == "./plugins/app-it-windows"
assert win_entry["version"] == win_plugin["version"]
static_entry = market_by_name["app-it-static"]
assert static_entry["source"] == "./plugins/app-it-static"
assert static_entry["version"] == static_plugin["version"]

# Codex marketplace assertions
codex_by_name = {e["name"]: e for e in codex_market["plugins"]}
assert "app-it" in codex_by_name, ".agents/plugins/marketplace.json missing app-it entry"
assert "app-it-windows" in codex_by_name, ".agents/plugins/marketplace.json missing app-it-windows entry"
assert "app-it-static" in codex_by_name, ".agents/plugins/marketplace.json missing app-it-static entry"

assert codex_plugin["name"] == plugin["name"]
assert codex_plugin["version"] == plugin["version"]
assert codex_plugin["skills"] == "./skills/"
assert codex_market["name"] == "app-it"
assert codex_by_name["app-it"]["source"]["path"] == "./plugins/app-it"
assert codex_by_name["app-it-windows"]["source"]["path"] == "./plugins/app-it-windows"
assert codex_by_name["app-it-static"]["source"]["path"] == "./plugins/app-it-static"

# app-it-windows manifest assertions
assert win_plugin["name"] == "app-it-windows"
assert win_plugin["version"]
assert win_plugin["skills"] == "./skills/"
assert win_codex["name"] == "app-it-windows"
assert win_codex["version"] == win_plugin["version"]
assert win_codex["skills"] == "./skills/"

# app-it-static manifest assertions
assert static_plugin["name"] == "app-it-static"
assert static_plugin["version"]
assert static_plugin["skills"] == "./skills/"
assert static_codex["name"] == "app-it-static"
assert static_codex["version"] == static_plugin["version"]
assert static_codex["skills"] == "./skills/"
PY

if command -v claude >/dev/null 2>&1; then
  claude plugin validate .
  claude plugin validate plugins/app-it/.claude-plugin/plugin.json
else
  echo "note: claude CLI not found; skipping claude plugin validate"
fi

for file in install.sh \
  plugins/app-it/skills/app-it/templates/*.sh \
  plugins/app-it-static/skills/app-it-static/templates/*.sh; do
  bash -n "$file"
done

# Python static server (app-it-static): syntax-check, then clean the bytecode
# cache py_compile leaves behind so it never shows up as an untracked artifact.
python3 -m py_compile plugins/app-it-static/skills/app-it-static/templates/static-server.py
rm -rf plugins/app-it-static/skills/app-it-static/templates/__pycache__

plutil -lint plugins/app-it/skills/app-it/templates/info-plist-template.xml >/dev/null
plutil -lint plugins/app-it-static/skills/app-it-static/templates/info-plist-template.xml >/dev/null

if command -v swiftc >/dev/null 2>&1; then
  swiftc -typecheck plugins/app-it/skills/app-it/templates/wrapper.swift -framework Cocoa -framework WebKit
else
  echo "note: swiftc not found; skipping wrapper.swift typecheck"
fi

# --- Shared-template drift guard --------------------------------------------
# app-it-static reuses five app-it templates byte-for-byte. Each plugin must be
# self-contained for marketplace install, so the files are duplicated — but they
# must never diverge. Diff them here so drift fails the build instead of shipping
# two subtly different launchers.
APP_IT_TPL="plugins/app-it/skills/app-it/templates"
STATIC_TPL="plugins/app-it-static/skills/app-it-static/templates"
for shared in wrapper.swift desktop-icons.sh desktop-install.sh info-plist-template.xml placeholder-icon-gen.sh; do
  if ! diff -q "$APP_IT_TPL/$shared" "$STATIC_TPL/$shared" >/dev/null; then
    fail "shared template drift: $shared differs between app-it and app-it-static (keep them byte-identical; edit app-it's copy and re-sync)"
  fi
done

LOCAL_PATH_PATTERN="/"
LOCAL_PATH_PATTERN="${LOCAL_PATH_PATTERN}Users/christiankatzmann"
# campaigns/ is excluded: campaign markdown legitimately contains absolute paths
# (the working-directory field in step prompts).
if grep -R "$LOCAL_PATH_PATTERN" . \
  --exclude-dir=.git \
  --exclude-dir=.tmp \
  --exclude-dir=campaigns \
  --exclude='validate.sh' \
  --exclude='*.png' >/dev/null; then
  fail "found local absolute path"
fi

if grep -R "__APP_NAME__" README.md docs .claude-plugin .agents scripts \
  --exclude-dir=.git \
  --exclude='validate.sh' >/dev/null 2>&1; then
  fail "found unresolved app template placeholder outside templates"
fi

# --- SKILL.md frontmatter name must match each plugin's name -----------------
grep -qx 'name: app-it' plugins/app-it/skills/app-it/SKILL.md \
  || fail "app-it SKILL.md frontmatter 'name' is not 'app-it'"
grep -qx 'name: app-it-static' plugins/app-it-static/skills/app-it-static/SKILL.md \
  || fail "app-it-static SKILL.md frontmatter 'name' is not 'app-it-static'"
grep -qx 'name: app-it-windows' plugins/app-it-windows/skills/app-it-windows/SKILL.md \
  || fail "app-it-windows SKILL.md frontmatter 'name' is not 'app-it-windows'"

# --- Windows plugin notice ---------------------------------------------------
# The Windows plugin (.ps1 / .cs) cannot be validated on macOS. CI validates
# it via the windows-latest job in .github/workflows/ci.yml — that job is
# required for merge, so the scaffold cannot silently bit-rot.
echo ""
echo "Windows plugin present (beta) — validated in CI, not on macOS — see docs/WINDOWS.md"

echo "app-it validation passed"
