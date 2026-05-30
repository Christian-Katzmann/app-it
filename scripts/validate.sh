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

require_file ".claude-plugin/marketplace.json"
require_file "plugins/app-it/.claude-plugin/plugin.json"
require_file "plugins/app-it/.codex-plugin/plugin.json"
require_file ".agents/plugins/marketplace.json"
require_file "plugins/app-it/skills/app-it/SKILL.md"
require_file "plugins/app-it/skills/app-it/templates/wrapper.swift"
require_file "plugins/app-it/skills/app-it/templates/desktop-build.sh"
require_file "README.md"
require_file "LICENSE"

python3 - <<'PY'
import json
from pathlib import Path

plugin = json.loads(Path("plugins/app-it/.claude-plugin/plugin.json").read_text())
market = json.loads(Path(".claude-plugin/marketplace.json").read_text())
codex_plugin = json.loads(Path("plugins/app-it/.codex-plugin/plugin.json").read_text())
codex_market = json.loads(Path(".agents/plugins/marketplace.json").read_text())

assert plugin["name"] == "app-it"
assert plugin["version"]
assert plugin["skills"] == "./skills/"
assert market["name"] == "app-it"
assert len(market["plugins"]) == 1
entry = market["plugins"][0]
assert entry["name"] == "app-it"
assert entry["source"] == "./plugins/app-it"
assert entry["version"] == plugin["version"]

assert codex_plugin["name"] == plugin["name"]
assert codex_plugin["version"] == plugin["version"]
assert codex_plugin["skills"] == "./skills/"
assert codex_market["name"] == "app-it"
assert codex_market["plugins"][0]["name"] == "app-it"
assert codex_market["plugins"][0]["source"]["path"] == "./plugins/app-it"
PY

if command -v claude >/dev/null 2>&1; then
  claude plugin validate .
  claude plugin validate plugins/app-it/.claude-plugin/plugin.json
else
  echo "note: claude CLI not found; skipping claude plugin validate"
fi

for file in install.sh plugins/app-it/skills/app-it/templates/*.sh; do
  bash -n "$file"
done

plutil -lint plugins/app-it/skills/app-it/templates/info-plist-template.xml >/dev/null

if command -v swiftc >/dev/null 2>&1; then
  swiftc -typecheck plugins/app-it/skills/app-it/templates/wrapper.swift -framework Cocoa -framework WebKit
else
  echo "note: swiftc not found; skipping wrapper.swift typecheck"
fi

LOCAL_PATH_PATTERN="/"
LOCAL_PATH_PATTERN="${LOCAL_PATH_PATTERN}Users/christiankatzmann"
if grep -R "$LOCAL_PATH_PATTERN" . \
  --exclude-dir=.git \
  --exclude-dir=.tmp \
  --exclude='validate.sh' \
  --exclude='*.png' >/dev/null; then
  fail "found local absolute path"
fi

if grep -R "__APP_NAME__" README.md docs .claude-plugin .agents scripts \
  --exclude-dir=.git \
  --exclude='validate.sh' >/dev/null 2>&1; then
  fail "found unresolved app template placeholder outside templates"
fi

echo "app-it validation passed"
