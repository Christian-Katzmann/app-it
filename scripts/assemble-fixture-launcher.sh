#!/usr/bin/env bash
# Assemble a throwaway app-it'd launcher from a fixture — exactly the layout a
# user's project has after running app-it: launcher templates vendored into
# scripts/, the manifest at scripts/app-it.config.json, the $PORT-honoring
# stand-in servers at the project root, and an icon source under assets/.
#
# Used by the "app-it compatible" self-test workflow (.github/workflows/
# app-it-compatible.yml) to exercise the published verify Action against a real
# generated launcher — proving the Action that backs the badge actually goes
# green. This repo is the plugin, not a wrapped app, so it has no committed
# launcher of its own; this synthesizes a representative one on demand.
#
# Not shipped with the plugin. Mirrors test-fixtures.sh's setup_proj.
#
# Usage: ./scripts/assemble-fixture-launcher.sh <fixture-name> <dest-dir> [plugin]

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="${1:?usage: assemble-fixture-launcher.sh <fixture-name> <dest-dir> [plugin]}"
DEST="${2:?usage: assemble-fixture-launcher.sh <fixture-name> <dest-dir> [plugin]}"
PLUGIN="${3:-app-it}"

SRC="$REPO/scripts/fixtures/$FIXTURE"
TPL="$REPO/plugins/$PLUGIN/skills/$PLUGIN/templates"
[ -d "$SRC" ] || { echo "no such fixture: $SRC" >&2; exit 2; }
[ -d "$TPL" ] || { echo "no such plugin templates: $TPL" >&2; exit 2; }

slug="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["apps"][0]["slug"])' "$SRC/app-it.config.json")"

rm -rf "$DEST"
mkdir -p "$DEST/scripts" "$DEST/assets"
cp -R "$SRC/." "$DEST/"                                   # the project shape (+ its app-it.config.json)
cp -R "$TPL/." "$DEST/scripts/"                           # the real launcher templates, vendored into scripts/
mv "$DEST/app-it.config.json" "$DEST/scripts/app-it.config.json"   # manifest lives in scripts/
cp "$REPO/scripts/lib/"*.js "$DEST/"                      # $PORT-honoring stand-in servers (no framework install)
cp "$REPO/scripts/fixtures/_shared/icon.png" "$DEST/assets/$slug-icon.png"

echo "assembled '$FIXTURE' launcher at $DEST (slug: $slug, plugin: $PLUGIN)"
