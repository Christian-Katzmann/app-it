#!/bin/bash
# app-it upgrade — re-vendor newer templates into a generated app, safely.
#
# When a generated app's manifest template_version is behind the current
# templates, this re-copies the template roster into the project's scripts/,
# re-stamps the manifest's provenance, rebuilds, and re-verifies. It refuses
# (and rolls the vendored scripts back) if the post-upgrade verify FAILS an
# ownership/identity check.
#
# Boundary — mirrors desktop-doctor.sh --fix-safe exactly: it touches ONLY
# app-it's own generated artifacts (the template roster in scripts/ + the three
# top-level provenance stamps in the manifest). It NEVER edits the user's
# product code, dependencies, package.json, icon sources, or the per-app entries
# in app-it.config.json.
#
# Usage:
#   ./scripts/desktop-upgrade.sh [slug]        # upgrade if behind, then verify
#   ./scripts/desktop-upgrade.sh --check        # report drift only; change nothing
#   ./scripts/desktop-upgrade.sh --force        # re-vendor even if already current
#   ./scripts/desktop-upgrade.sh --help
#
# Template source (the "newer templates"):
#   The directory this script lives in, OR $APP_IT_TEMPLATE_SRC if set. Run the
#   PLUGIN's copy (plugins/app-it/skills/app-it/templates/desktop-upgrade.sh)
#   against a project — like inspect.sh — to pull templates newer than what the
#   project currently vendors. Target project root: $APP_IT_PROJECT_ROOT or the
#   parent of this script's directory.
#
# Current vintage is read from the template source's app-it.config.example.json
# (its template_version / generator_version / schema_version stamps) — the same
# stamps references/verification.md documents as the verify contract.

set -uo pipefail   # NOT -e: probes and the verify gate are guarded individually.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${APP_IT_PROJECT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
TEMPLATE_SRC="${APP_IT_TEMPLATE_SRC:-$SCRIPT_DIR}"
TARGET_SCRIPTS="$ROOT/scripts"
CONFIG_FILE="$TARGET_SCRIPTS/app-it.config.json"
SRC_EXAMPLE="$TEMPLATE_SRC/app-it.config.example.json"

# --- Output vocabulary -------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[31m'
    C_INFO=$'\033[36m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
    C_OK=""; C_WARN=""; C_FAIL=""; C_INFO=""; C_DIM=""; C_BOLD=""; C_OFF=""
fi
say()  { printf '%s\n' "$1"; }
ok()   { printf '  %s[ ok ]%s  %s\n' "$C_OK" "$C_OFF" "$1"; }
info() { printf '  %s[info]%s  %s\n' "$C_INFO" "$C_OFF" "$1"; }
warn() { printf '  %s[warn]%s  %s\n' "$C_WARN" "$C_OFF" "$1"; }
step() { printf '  %s[ -> ]%s  %s\n' "$C_OK" "$C_OFF" "$1"; }
note() { printf '         %s%s%s\n' "$C_DIM" "$1" "$C_OFF"; }
die()  { printf '%sdesktop-upgrade: %s%s\n' "$C_FAIL" "$1" "$C_OFF" >&2; exit "${2:-2}"; }

# The template roster — the EXACT set of app-it-owned artifacts upgrade may
# re-vendor (references/generated-files.md). Keeping this explicit (rather than a
# blind cp -R) is the ownership boundary: nothing outside this list is touched,
# and app-it.config.json — the user's manifest — is deliberately absent.
ROSTER=(
    wrapper.swift
    info-plist-template.xml
    run-template.sh
    run-template-chrome.sh
    run-template-multiserver.sh
    run-template-url.sh
    run-template-url-chrome.sh
    native-run-stub.c
    desktop-build.sh
    desktop-icons.sh
    desktop-icons-preview.sh
    desktop-install.sh
    desktop-quit.sh
    desktop-doctor.sh
    desktop-verify.sh
    desktop-upgrade.sh
    inspect.sh
    placeholder-icon-gen.sh
    fsa-polyfill-template.js
    app-it.config.example.json
    desktop-launcher.md.template
    app-it
)

# --- Parse args --------------------------------------------------------------
SELECTOR=""; DO_CHECK=0; DO_FORCE=0
for arg in "$@"; do
    case "$arg" in
        -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --check|--dry-run) DO_CHECK=1 ;;
        --force) DO_FORCE=1 ;;
        --*) die "unknown flag: $arg" ;;
        *) [ -z "$SELECTOR" ] && SELECTOR="$arg" || die "unexpected extra argument: $arg" ;;
    esac
done

# --- Read a top-level string field from a config JSON ------------------------
cfg_field() {  # cfg_field <file> <key>
    [ -f "$1" ] || { printf ''; return 0; }
    /usr/bin/python3 - "$1" "$2" <<'PY'
import json, sys
try:
    cfg = json.load(open(sys.argv[1]))
except Exception:
    print(""); sys.exit(0)
v = cfg.get(sys.argv[2])
print("" if v is None else str(v))
PY
}

# Calendar-version comparison: prints behind|current|ahead|unstamped.
# Compares YYYY.MM numerically so "2026.6" and "2026.06" are equal.
version_cmp() {  # version_cmp <target> <source>
    /usr/bin/python3 - "$1" "$2" <<'PY'
import sys
def parts(v):
    out = []
    for chunk in str(v).replace("-", ".").split("."):
        out.append(int(chunk) if chunk.isdigit() else 0)
    return out
tgt, src = sys.argv[1].strip(), sys.argv[2].strip()
if not tgt:
    print("unstamped"); raise SystemExit
t, s = parts(tgt), parts(src)
n = max(len(t), len(s)); t += [0]*(n-len(t)); s += [0]*(n-len(s))
print("behind" if t < s else ("ahead" if t > s else "current"))
PY
}

# =============================================================================
say ""
printf '%sapp-it upgrade%s\n' "$C_BOLD" "$C_OFF"
note "project: $ROOT"
note "template source: $TEMPLATE_SRC"

[ -f "$CONFIG_FILE" ] || die "scripts/app-it.config.json not found at $CONFIG_FILE — nothing to upgrade. Run app-it apply first." 2
[ -f "$SRC_EXAMPLE" ] || die "template source has no app-it.config.example.json at $SRC_EXAMPLE — point APP_IT_TEMPLATE_SRC at the app-it templates." 2

SRC_TEMPLATE_VERSION="$(cfg_field "$SRC_EXAMPLE" template_version)"
SRC_GENERATOR_VERSION="$(cfg_field "$SRC_EXAMPLE" generator_version)"
SRC_SCHEMA_VERSION="$(cfg_field "$SRC_EXAMPLE" schema_version)"
CUR_TEMPLATE_VERSION="$(cfg_field "$CONFIG_FILE" template_version)"
CUR_GENERATOR_VERSION="$(cfg_field "$CONFIG_FILE" generator_version)"

[ -n "$SRC_TEMPLATE_VERSION" ] || die "template source is missing a template_version stamp; cannot determine the current vintage." 2

say ""
printf '%sDrift%s\n' "$C_BOLD" "$C_OFF"
info "manifest template_version: ${CUR_TEMPLATE_VERSION:-(unstamped)}"
info "current  template_version: $SRC_TEMPLATE_VERSION"

# Same-tree degenerate case — the vendored copy is being run against itself.
SRC_REAL="$(cd "$TEMPLATE_SRC" 2>/dev/null && pwd -P || printf '%s' "$TEMPLATE_SRC")"
TGT_REAL="$(cd "$TARGET_SCRIPTS" 2>/dev/null && pwd -P || printf '%s' "$TARGET_SCRIPTS")"
if [ "$SRC_REAL" = "$TGT_REAL" ]; then
    note "source == the project's own vendored templates; this can only re-stamp/re-vendor"
    note "from what is already here. To pull NEWER templates, run the plugin's copy or set"
    note "APP_IT_TEMPLATE_SRC to the updated app-it templates dir."
fi

STATE="$(version_cmp "$CUR_TEMPLATE_VERSION" "$SRC_TEMPLATE_VERSION")"
case "$STATE" in
    current) info "manifest is at the current template vintage" ;;
    ahead)   warn "manifest template_version is AHEAD of these templates ($CUR_TEMPLATE_VERSION > $SRC_TEMPLATE_VERSION) — older templates; not upgrading" ;;
    behind)  warn "manifest is BEHIND ($CUR_TEMPLATE_VERSION < $SRC_TEMPLATE_VERSION) — a re-vendor is due" ;;
    unstamped) warn "manifest is unstamped (legacy build) — treating as behind; a re-vendor is due" ;;
esac

if [ "$DO_CHECK" = "1" ]; then
    say ""
    if [ "$STATE" = "behind" ] || [ "$STATE" = "unstamped" ]; then
        printf '%supgrade available%s: %s -> %s (run without --check to apply)\n' \
            "$C_WARN" "$C_OFF" "${CUR_TEMPLATE_VERSION:-unstamped}" "$SRC_TEMPLATE_VERSION"
        exit 3
    fi
    printf '%sno upgrade needed%s (template_version %s)\n' "$C_OK" "$C_OFF" "${CUR_TEMPLATE_VERSION:-unstamped}"
    exit 0
fi

if { [ "$STATE" = "current" ] || [ "$STATE" = "ahead" ]; } && [ "$DO_FORCE" = "0" ]; then
    say ""
    printf '%sAlready current%s — template_version %s, nothing to re-vendor. (Use --force to re-vendor anyway.)\n' \
        "$C_OK" "$C_OFF" "${CUR_TEMPLATE_VERSION:-unstamped}"
    exit 0
fi

# =============================================================================
say ""
printf '%sRe-vendor%s\n' "$C_BOLD" "$C_OFF"
[ -d "$TARGET_SCRIPTS" ] || die "target scripts dir $TARGET_SCRIPTS does not exist" 2

# Back up the roster + manifest so a failed verify can be rolled back.
BACKUP="$(mktemp -d "${TMPDIR:-/tmp}/app-it-upgrade-backup.XXXXXX")" || die "could not create backup dir" 2
trap 'rm -rf "$BACKUP"' EXIT
for f in "${ROSTER[@]}"; do
    [ -e "$TARGET_SCRIPTS/$f" ] && cp -Rp "$TARGET_SCRIPTS/$f" "$BACKUP/" 2>/dev/null || true
done
cp -p "$CONFIG_FILE" "$BACKUP/app-it.config.json" 2>/dev/null || true

restore_backup() {
    for f in "${ROSTER[@]}"; do
        [ -e "$BACKUP/$f" ] && cp -Rp "$BACKUP/$f" "$TARGET_SCRIPTS/$f" 2>/dev/null || true
    done
    [ -f "$BACKUP/app-it.config.json" ] && cp -p "$BACKUP/app-it.config.json" "$CONFIG_FILE" 2>/dev/null || true
}

# Copy each roster file present in the source (skip the absent ones).
revendored=0
for f in "${ROSTER[@]}"; do
    if [ -e "$TEMPLATE_SRC/$f" ]; then
        cp -Rp "$TEMPLATE_SRC/$f" "$TARGET_SCRIPTS/$f"
        revendored=$((revendored+1))
    fi
done
ok "re-vendored $revendored template file(s) into scripts/"
note "manifest scripts/app-it.config.json and everything outside the roster were left untouched"

# Re-stamp ONLY the three top-level provenance fields; preserve apps[] + comments.
RESTAMP_OUT="$(/usr/bin/python3 - "$CONFIG_FILE" "$SRC_SCHEMA_VERSION" "$SRC_GENERATOR_VERSION" "$SRC_TEMPLATE_VERSION" <<'PY'
import json, sys
from collections import OrderedDict
path, schema, gen, tmpl = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(path) as fh:
    cfg = json.load(fh, object_pairs_hook=OrderedDict)
def set_top(cfg, key, value):
    if key in cfg:
        cfg[key] = value
        return cfg
    # Insert stamps just before "apps" (or at the end) to keep them top-of-file.
    out = OrderedDict()
    inserted = False
    for k, v in cfg.items():
        if k == "apps" and not inserted:
            out[key] = value; inserted = True
        out[k] = v
    if not inserted:
        out[key] = value
    return out
try:
    schema_val = int(schema)
except ValueError:
    schema_val = schema
if schema:
    cfg = set_top(cfg, "schema_version", schema_val)
if gen:
    cfg = set_top(cfg, "generator_version", gen)
if tmpl:
    cfg = set_top(cfg, "template_version", tmpl)
with open(path, "w") as fh:
    json.dump(cfg, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
print("ok")
PY
)" || { restore_backup; die "failed to re-stamp the manifest; rolled back. Manifest unchanged." 1; }
ok "re-stamped manifest provenance: template_version ${CUR_TEMPLATE_VERSION:-unstamped} -> $SRC_TEMPLATE_VERSION, generator_version ${CUR_GENERATOR_VERSION:-unstamped} -> $SRC_GENERATOR_VERSION"

# =============================================================================
say ""
printf '%sRebuild + verify%s\n' "$C_BOLD" "$C_OFF"
VERIFY="$TARGET_SCRIPTS/desktop-verify.sh"
[ -x "$VERIFY" ] || { restore_backup; die "freshly vendored desktop-verify.sh is missing/not executable; rolled back." 1; }

VERIFY_JSON="$(mktemp "${TMPDIR:-/tmp}/app-it-upgrade-verify.XXXXXX")" || { restore_backup; die "could not create verify scratch file; rolled back." 1; }
# --build so the rebuilt bundle reflects the new templates; verify then proves
# the launcher still builds, runs headless, owns its port, and passes doctor.
env APP_IT_PROJECT_ROOT="$ROOT" "$VERIFY" --build --json $SELECTOR >"$VERIFY_JSON" 2>"$VERIFY_JSON.err" || true

VSTATUS="$(/usr/bin/python3 - "$VERIFY_JSON" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("status", ""))
except Exception:
    print("")
PY
)"
VFAIL="$(/usr/bin/python3 - "$VERIFY_JSON" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("counts", {}).get("fail", "?"))
except Exception:
    print("?")
PY
)"

case "$VSTATUS" in
    pass)
        ok "verify passed after upgrade (status: pass)"
        ;;
    warn)
        # Warnings (e.g. "built but not installed") do not break ownership/identity.
        warn "verify passed with warnings after upgrade (status: warn) — review, but ownership/identity hold"
        ;;
    *)
        warn "verify did not pass after upgrade (status: ${VSTATUS:-error}, fail count: $VFAIL)"
        note "verify output: $VERIFY_JSON (stderr: $VERIFY_JSON.err)"
        sed 's/^/         /' "$VERIFY_JSON.err" 2>/dev/null | head -20 || true
        restore_backup
        say ""
        die "Refused: post-upgrade verify failed an ownership/identity check. Rolled the vendored scripts and manifest back to their pre-upgrade state. Your project was not left in a broken state." 1
        ;;
esac
rm -f "$VERIFY_JSON" "$VERIFY_JSON.err" 2>/dev/null || true

# =============================================================================
say ""
printf '%sUpgraded%s — template_version %s -> %s, verified.\n' \
    "$C_OK" "$C_OFF" "${CUR_TEMPLATE_VERSION:-unstamped}" "$SRC_TEMPLATE_VERSION"
note "Next: app-it apply (or desktop:install) to refresh the installed copy in ~/Applications/App It."
exit 0
