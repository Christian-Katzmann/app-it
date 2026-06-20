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

require_text() {
  local file="$1" text="$2"
  grep -qF "$text" "$file" || fail "$file missing required text: $text"
}

# --- macOS plugin files -------------------------------------------------------
require_file ".claude-plugin/marketplace.json"
require_file "plugins/app-it/.claude-plugin/plugin.json"
require_file "plugins/app-it/.codex-plugin/plugin.json"
require_file ".agents/plugins/marketplace.json"
require_file "plugins/app-it/skills/app-it/SKILL.md"
require_file "plugins/app-it/skills/app-it/templates/wrapper.swift"
require_file "plugins/app-it/skills/app-it/templates/native-run-stub.c"
require_file "plugins/app-it/skills/app-it/templates/desktop-build.sh"
require_file "plugins/app-it/skills/app-it/templates/desktop-doctor.sh"
require_file "plugins/app-it/skills/app-it/templates/desktop-verify.sh"
require_file "plugins/app-it/skills/app-it/templates/desktop-icons-preview.sh"
require_file "plugins/app-it/skills/app-it/templates/placeholder-icon-gen.sh"
require_file "plugins/app-it/skills/app-it/templates/run-template-url.sh"
require_file "plugins/app-it/skills/app-it/templates/run-template-url-chrome.sh"
require_file "plugins/app-it/skills/app-it/templates/desktop-upgrade.sh"
require_file "plugins/app-it/skills/app-it/templates/app-it"
require_file "scripts/coverage.sh"
require_file "scripts/plugin-eval-score.sh"
require_file "scripts/assemble-fixture-launcher.sh"
require_file "README.md"

# --- "app-it compatible" standard: gate Action, self-test workflow, contract --
require_file ".github/actions/app-it-verify/action.yml"
require_file ".github/actions/app-it-verify/assert_contract.py"
require_file ".github/workflows/app-it-compatible.yml"
require_file "docs/APP-IT-COMPATIBLE.md"
require_file "PRIVACY.md"
require_file "TERMS.md"
require_file "LICENSE"

# --- app-it-static plugin files (companion: serve a finished build) -----------
require_file "plugins/app-it-static/.claude-plugin/plugin.json"
require_file "plugins/app-it-static/.codex-plugin/plugin.json"
require_file "plugins/app-it-static/skills/app-it-static/SKILL.md"
require_file "plugins/app-it-static/skills/app-it-static/templates/wrapper.swift"
require_file "plugins/app-it-static/skills/app-it-static/templates/native-run-stub.c"
require_file "plugins/app-it-static/skills/app-it-static/templates/static-server.py"
require_file "plugins/app-it-static/skills/app-it-static/tests/test_static_server.py"
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

ROOT_URL = "https://github.com/Christian-Katzmann/app-it"
PRIVACY_URL = f"{ROOT_URL}/blob/main/PRIVACY.md"
TERMS_URL = f"{ROOT_URL}/blob/main/TERMS.md"
WINDOWS_URL = f"{ROOT_URL}/blob/main/docs/WINDOWS.md"

def assert_trust_fields(manifest, website_url=ROOT_URL):
    interface = manifest.get("interface")
    assert isinstance(interface, dict), f"{manifest['name']} missing interface object"
    assert interface.get("websiteURL") == website_url, f"{manifest['name']} missing interface.websiteURL"
    assert interface.get("privacyPolicyURL") == PRIVACY_URL, f"{manifest['name']} missing interface.privacyPolicyURL"
    assert interface.get("termsOfServiceURL") == TERMS_URL, f"{manifest['name']} missing interface.termsOfServiceURL"

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
assert_trust_fields(codex_plugin)
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
assert_trust_fields(win_codex, WINDOWS_URL)

# app-it-static manifest assertions
assert static_plugin["name"] == "app-it-static"
assert static_plugin["version"]
assert static_plugin["skills"] == "./skills/"
assert static_codex["name"] == "app-it-static"
assert static_codex["version"] == static_plugin["version"]
assert static_codex["skills"] == "./skills/"
assert_trust_fields(static_codex)
PY

if command -v claude >/dev/null 2>&1; then
  claude plugin validate .
  claude plugin validate plugins/app-it/.claude-plugin/plugin.json
else
  echo "note: claude CLI not found; skipping claude plugin validate"
fi

for file in install.sh \
  scripts/test-fixtures.sh \
  scripts/coverage.sh \
  scripts/plugin-eval-score.sh \
  scripts/assemble-fixture-launcher.sh \
  plugins/app-it/skills/app-it/templates/*.sh \
  plugins/app-it/skills/app-it/templates/app-it \
  plugins/app-it-static/skills/app-it-static/templates/*.sh; do
  bash -n "$file"
done

# Fixture-suite stand-in servers (JS) — syntax-check when node is available.
if command -v node >/dev/null 2>&1; then
  for js in scripts/lib/*.js; do
    node --check "$js"
  done
else
  echo "note: node not found; skipping scripts/lib/*.js syntax check"
fi

# Python static server (app-it-static): syntax-check, then clean the bytecode
# cache py_compile leaves behind so it never shows up as an untracked artifact.
python3 -m py_compile plugins/app-it-static/skills/app-it-static/templates/static-server.py
rm -rf plugins/app-it-static/skills/app-it-static/templates/__pycache__

# Contract-assertion helper for the "app-it compatible" gate Action.
python3 -m py_compile .github/actions/app-it-verify/assert_contract.py
rm -rf .github/actions/app-it-verify/__pycache__

# Score-visible coverage evidence. This runs quick fixture inspections plus
# static-server.py unit tests, then refreshes coverage-summary.json artifacts
# under the plugin roots so plugin-eval can discover them.
./scripts/coverage.sh

plutil -lint plugins/app-it/skills/app-it/templates/info-plist-template.xml >/dev/null
plutil -lint plugins/app-it-static/skills/app-it-static/templates/info-plist-template.xml >/dev/null

if command -v swiftc >/dev/null 2>&1; then
  swiftc -typecheck plugins/app-it/skills/app-it/templates/wrapper.swift -framework Cocoa -framework WebKit
else
  echo "note: swiftc not found; skipping wrapper.swift typecheck"
fi

if command -v cc >/dev/null 2>&1; then
  cc -fsyntax-only plugins/app-it/skills/app-it/templates/native-run-stub.c
else
  echo "note: cc not found; skipping native-run-stub.c syntax check"
fi

# --- Shared-template drift guard --------------------------------------------
# app-it-static reuses five app-it templates byte-for-byte. Each plugin must be
# self-contained for marketplace install, so the files are duplicated — but they
# must never diverge. Diff them here so drift fails the build instead of shipping
# two subtly different launchers.
APP_IT_TPL="plugins/app-it/skills/app-it/templates"
STATIC_TPL="plugins/app-it-static/skills/app-it-static/templates"
for shared in wrapper.swift native-run-stub.c desktop-icons.sh desktop-icons-preview.sh desktop-install.sh info-plist-template.xml placeholder-icon-gen.sh; do
  if ! diff -q "$APP_IT_TPL/$shared" "$STATIC_TPL/$shared" >/dev/null; then
    fail "shared template drift: $shared differs between app-it and app-it-static (keep them byte-identical; edit app-it's copy and re-sync)"
  fi
done

# --- Cleanup ownership-gate invariant ---------------------------------------
# Both quit scripts must gate every kill behind an ownership proof, so a stale or
# reused server.pid can never TERM/KILL an unrelated process. The two quit
# scripts are NOT byte-identical (single- vs multi-server), so the drift guard
# above can't cover them — assert the ownership-gate markers are present in each.
for quit in \
  "$APP_IT_TPL/desktop-quit.sh" \
  "$STATIC_TPL/desktop-quit.sh"; do
  require_text "$quit" 'pid_identity_matches'
  require_text "$quit" 'ownership_ok'
done

LOCAL_PATH_PATTERN="/"
LOCAL_PATH_PATTERN="${LOCAL_PATH_PATTERN}Users/christiankatzmann"
# campaigns/ and reports/ are excluded: campaign prompts/state legitimately
# contain absolute paths for unattended local automation.
if grep -R "$LOCAL_PATH_PATTERN" . \
  --exclude-dir=.git \
  --exclude-dir=.tmp \
  --exclude-dir=campaigns \
  --exclude-dir=reports \
  --exclude='validate.sh' \
  --exclude='*.png' >/dev/null; then
  fail "found local absolute path"
fi

if grep -R "__APP_NAME__" README.md docs .claude-plugin .agents scripts \
  --exclude-dir=.git \
  --exclude='validate.sh' >/dev/null 2>&1; then
  fail "found unresolved app template placeholder outside templates"
fi

# Public docs must keep the runtime-verification surface discoverable. The
# behavior lives in templates and fixtures; these guards catch accidental doc
# drift without making the prose long.
require_text README.md 'desktop:doctor'
require_text README.md 'desktop:verify'
require_text README.md 'port_mode: "fixed"'
require_text README.md 'app-it compatible'
require_text docs/APP-IT-COMPATIBLE.md 'app-it verify --strict'
require_text plugins/app-it/skills/app-it/templates/desktop-launcher.md.template './scripts/desktop-doctor.sh --json'
require_text plugins/app-it/skills/app-it/templates/desktop-launcher.md.template './scripts/desktop-verify.sh --json'
require_text plugins/app-it/skills/app-it/templates/desktop-launcher.md.template 'runtime.json'

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

# This script is the fast, static gate. The behavioral gate — which drives the
# real launcher scripts against tiny project fixtures (build, runtime port,
# server ownership, teardown) — is scripts/test-fixtures.sh (run by CI; run it
# locally for launcher/recipe changes).
echo "app-it validation passed (behavioral suite: ./scripts/test-fixtures.sh)"
