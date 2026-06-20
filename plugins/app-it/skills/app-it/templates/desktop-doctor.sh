#!/bin/bash
# app-it doctor — diagnose ONE generated launcher. Read-only by default.
# Verbatim-copied helper; reads scripts/app-it.config.json at runtime.
#
# Usage:
#   ./scripts/desktop-doctor.sh [slug-or-name]   # diagnose one app
#   ./scripts/desktop-doctor.sh --tail[=N]        # also tail N launcher-log lines (default 20)
#   ./scripts/desktop-doctor.sh --json            # machine-readable checks, counts, and selected app metadata
#   ./scripts/desktop-doctor.sh --json --strict   # exit non-zero on warnings/failures
#   ./scripts/desktop-doctor.sh --fix-safe        # apply the narrow generated-state fixes below
#   ./scripts/desktop-doctor.sh --help
#
# Selection: no arg diagnoses the sole/first app; pass a slug/name to pick.
#
# Contract: deterministic, local, no installs. JSON mode emits the same checks
# as the human report. `--fix-safe` only touches app-it-generated state: stale
# pid/port files, this bundle's LaunchServices entry, generated icon, and
# quarantine. Exit 0 for any completed report unless `--strict` is passed.

set -uo pipefail   # NOT -e: probing commands (lsof, codesign, grep) fail by
                   # design; every one is guarded with `|| true` or an `if`.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${APP_IT_PROJECT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CONFIG_FILE="$SCRIPT_DIR/app-it.config.json"
INSTALL_DIR="${APP_IT_INSTALL_DIR:-$HOME/Applications/App It}"

# --- Output vocabulary -------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[31m'
    C_INFO=$'\033[36m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
    C_OK=""; C_WARN=""; C_FAIL=""; C_INFO=""; C_DIM=""; C_BOLD=""; C_OFF=""
fi

OK_N=0; WARN_N=0; FAIL_N=0; INFO_N=0
JSON_MODE=0; STRICT_MODE=0; JSON_CHECKS_FILE=""; CURRENT_SECTION="Metadata"

record_check() {
    [ "$JSON_MODE" = "1" ] || return 0
    [ -n "$JSON_CHECKS_FILE" ] || return 0
    printf '%s\t%s\t%s\n' "$CURRENT_SECTION" "$1" "$2" >> "$JSON_CHECKS_FILE"
}

ok() {
    [ "$JSON_MODE" = "1" ] || printf '  %s[ ok ]%s  %s\n' "$C_OK" "$C_OFF" "$1"
    OK_N=$((OK_N+1)); record_check ok "$1"
}
warn() {
    [ "$JSON_MODE" = "1" ] || printf '  %s[warn]%s  %s\n' "$C_WARN" "$C_OFF" "$1"
    WARN_N=$((WARN_N+1)); record_check warn "$1"
}
fail() {
    [ "$JSON_MODE" = "1" ] || printf '  %s[fail]%s  %s\n' "$C_FAIL" "$C_OFF" "$1"
    FAIL_N=$((FAIL_N+1)); record_check fail "$1"
}
info() {
    [ "$JSON_MODE" = "1" ] || printf '  %s[info]%s  %s\n' "$C_INFO" "$C_OFF" "$1"
    INFO_N=$((INFO_N+1)); record_check info "$1"
}
note() {
    [ "$JSON_MODE" = "1" ] || printf '          %s%s%s\n' "$C_DIM" "$1" "$C_OFF"
}
section() {
    CURRENT_SECTION="$1"
    [ "$JSON_MODE" = "1" ] || printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_OFF"
}
die() {
    if [ "$JSON_MODE" = "1" ]; then
        /usr/bin/python3 - "$1" "${2:-2}" <<'PY'
import json, sys
print(json.dumps({
    "schema_version": 1,
    "tool": "app-it.desktop-doctor",
    "error": {"message": sys.argv[1], "exit_code": int(sys.argv[2])},
}, ensure_ascii=False, indent=2))
PY
    else
        printf '%sdesktop-doctor: %s%s\n' "$C_FAIL" "$1" "$C_OFF" >&2
    fi
    exit "${2:-2}"
}

lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

usage() {
    cat <<'EOF'
app-it doctor — diagnose one generated launcher.

  ./scripts/desktop-doctor.sh [slug-or-name]   diagnose one app (default: the sole/first app)
  ./scripts/desktop-doctor.sh --tail[=N]        also tail N launcher-log lines (default 20)
  ./scripts/desktop-doctor.sh --json            emit machine-readable checks and counts
  ./scripts/desktop-doctor.sh --json --strict   exit non-zero on warnings/failures
  ./scripts/desktop-doctor.sh --fix-safe        apply narrow generated-state fixes (see header)
  ./scripts/desktop-doctor.sh --help

Read-only unless --fix-safe is given. --fix-safe only ever touches app-it's own
generated state (stale pid/port files, this bundle's LaunchServices entry, the
rebuilt icon, and quarantine on the generated .app) — never your project.
EOF
}

# --- Parse args --------------------------------------------------------------
SELECTOR=""; DO_FIX=0; DO_TAIL=0; TAIL_N=20
for arg in "$@"; do
    case "$arg" in
        -h|--help)   usage; exit 0 ;;
        --fix-safe)  DO_FIX=1 ;;
        --json)      JSON_MODE=1 ;;
        --strict)    STRICT_MODE=1 ;;
        --tail)      DO_TAIL=1 ;;
        --tail=*)    DO_TAIL=1; TAIL_N="${arg#--tail=}" ;;
        --*)         usage >&2; die "unknown flag: $arg" ;;
        *)           [ -z "$SELECTOR" ] && SELECTOR="$arg" || die "unexpected extra argument: $arg" ;;
    esac
done
case "$TAIL_N" in ''|*[!0-9]*) die "--tail expects a number, got: $TAIL_N" ;; esac
if [ "$JSON_MODE" = "1" ]; then
    JSON_CHECKS_FILE="$(mktemp "${TMPDIR:-/tmp}/app-it-doctor-checks.XXXXXX")" || die "could not create JSON scratch file" 2
    trap 'rm -f "$JSON_CHECKS_FILE"' EXIT
fi

# --- Load apps from config ---------------------------------------------------
[ -f "$CONFIG_FILE" ] || die "scripts/app-it.config.json not found. desktop:doctor reads it to know which launcher to inspect. Run desktop:build once to create it." 2

APPS=()
while IFS= read -r line; do
    [ -n "$line" ] && APPS+=("$line")
done < <(/usr/bin/python3 - "$CONFIG_FILE" <<'PY'
import json, re, sys
try:
    cfg = json.load(open(sys.argv[1]))
except Exception as e:
    sys.stderr.write(f"could not parse app-it.config.json: {e}\n"); sys.exit(3)
def text(value):
    return "" if value is None else str(value)
for a in cfg.get("apps", []):
    name = a.get("name") or ""
    slug = a.get("slug") or re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    external_url = a.get("external_url") or a.get("artifact_url") or a.get("url") or ""
    fields = [
        text(name), text(slug), text(a.get("port", "")), text(a.get("port_mode", "fallback")),
        text(a.get("start_command", "")),
        text(a.get("bundle_id", "")), text(a.get("version", "0.1.0")), text(a.get("polyfill_path", "")),
        text(a.get("backend_port") or ""), text(a.get("backend_start_command") or ""),
        text(external_url),
    ]
    print("|".join(f.replace("|", " ") for f in fields))
PY
) || die "failed to read app-it.config.json (see message above)" 3

[ "${#APPS[@]}" -gt 0 ] || die "no apps configured in scripts/app-it.config.json." 2

# --- Manifest-level version stamps (config-wide, not per-app) ----------------
# Identify which app-it vintage generated the manifest. The --json output
# surfaces these under "manifest" as part of the documented verify contract
# (references/verification.md). Empty when an older, unstamped config is read.
CFG_SCHEMA_VERSION=""; CFG_GENERATOR_VERSION=""; CFG_TEMPLATE_VERSION=""
IFS=$'\t' read -r CFG_SCHEMA_VERSION CFG_GENERATOR_VERSION CFG_TEMPLATE_VERSION < <(/usr/bin/python3 - "$CONFIG_FILE" <<'PY'
import json, sys
try:
    cfg = json.load(open(sys.argv[1]))
except Exception:
    cfg = {}
def text(v):
    return "" if v is None else str(v)
print("\t".join(text(cfg.get(k)) for k in ("schema_version", "generator_version", "template_version")))
PY
)

# --- Pick the one app to diagnose --------------------------------------------
SELECTED=""
if [ -n "$SELECTOR" ]; then
    sel="$(lc "$SELECTOR")"
    for entry in "${APPS[@]}"; do
        IFS='|' read -r n s _ <<<"$entry"
        if [ "$(lc "$s")" = "$sel" ] || [ "$(lc "$n")" = "$sel" ]; then SELECTED="$entry"; break; fi
    done
    if [ -z "$SELECTED" ]; then
        printf '%sNo app named "%s". Configured apps:%s\n' "$C_FAIL" "$SELECTOR" "$C_OFF" >&2
        for entry in "${APPS[@]}"; do IFS='|' read -r n s _ <<<"$entry"; printf '  • %s (%s)\n' "$s" "$n" >&2; done
        exit 2
    fi
else
    SELECTED="${APPS[0]}"
fi

IFS='|' read -r APP_NAME APP_SLUG PORT PORT_MODE START_COMMAND BUNDLE_ID VERSION POLYFILL_PATH BACKEND_PORT BACKEND_START EXTERNAL_URL <<<"$SELECTED"
IS_URL_ONLY=0
[ -n "$EXTERNAL_URL" ] && IS_URL_ONLY=1

# --- Paths (mirror run-template.sh / desktop-quit.sh conventions) ------------
STATE_DIR="$HOME/Library/Application Support/app-it/$APP_SLUG"
LOG_DIR="$HOME/Library/Logs/app-it/$APP_SLUG"
PID_FILE="$STATE_DIR/server.pid";    PORT_FILE="$STATE_DIR/server.port"
BPID_FILE="$STATE_DIR/backend.pid";  BPORT_FILE="$STATE_DIR/backend.port"
SERVER_LOG="$LOG_DIR/server.log";    BACKEND_LOG="$LOG_DIR/backend.log"
RUNTIME_SUMMARY_FILE="$STATE_DIR/runtime.json"
INSTALL_APP="$INSTALL_DIR/$APP_NAME.app"
BUILD_APP="$ROOT/desktop/$APP_NAME.app"
LEGACY_MYAPPS_APP="$HOME/Desktop/MyApps/$APP_NAME.app"

# Diagnose the installed bundle first, then the build copy.
if   [ -d "$INSTALL_APP" ]; then APP_UNDER_TEST="$INSTALL_APP"; APP_LOC="installed"
elif [ -d "$BUILD_APP" ];   then APP_UNDER_TEST="$BUILD_APP";   APP_LOC="build"
else APP_UNDER_TEST=""; APP_LOC="none"; fi

# Match run-template.sh PATH so Dock-only missing-binary bugs surface here.
NVM_BIN=""
if [ -d "$HOME/.nvm/versions/node" ]; then
    LATEST_NVM_NODE="$(ls -1 "$HOME/.nvm/versions/node" 2>/dev/null | sort -V | tail -1)"
    [ -n "$LATEST_NVM_NODE" ] && NVM_BIN="$HOME/.nvm/versions/node/$LATEST_NVM_NODE/bin"
fi
LAUNCHER_PATH="$HOME/.bun/bin:$HOME/.deno/bin:$HOME/.volta/bin:$HOME/.local/share/mise/shims:$HOME/.asdf/shims:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:${NVM_BIN}:$HOME/Library/pnpm:$PATH"

# Mirror run-template.sh's ownership-tree reattach gate.
walk_descendants() {
    local root="$1" current="$1" tree="$1" gen _pid
    for _ in 1 2 3 4; do
        # One PID per pgrep call; macOS `pgrep -P` rejects generations.
        gen=""
        for _pid in $current; do
            gen="$gen $(pgrep -P "$_pid" 2>/dev/null | tr '\n' ' ')"
        done
        [ -z "${gen// /}" ] && break
        tree="$tree $gen"; current="$gen"
    done
    printf '%s' "$tree"
}

plist_get() { /usr/libexec/PlistBuddy -c "Print $2" "$1" 2>/dev/null; }
has_xattr() { /usr/bin/xattr -p "$2" "$1" >/dev/null 2>&1; }
listener_summary() {
    lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {printf "%s/%s ", $1, $2}' || true
}
report_preferred_port_holder() {
    local label="$1" preferred="$2" runtime="$3" mode="$4" holders
    [ -n "$preferred" ] || return 0
    case "$preferred" in *[!0-9]*) return 0 ;; esac
    [ -n "$runtime" ] && [ "$runtime" = "$preferred" ] && return 0
    holders="$(listener_summary "$preferred")"
    [ -n "$holders" ] || return 0
    if [ -n "$runtime" ]; then
        info "$label preferred port :$preferred is held by another listener ($holders); runtime is :$runtime, so fallback probably avoided it"
    elif [ "$mode" = "fixed" ]; then
        warn "$label preferred port :$preferred is already held by unknown/probably foreign listener ($holders); fixed-port launch will refuse to take it"
    else
        warn "$label preferred port :$preferred is already held by unknown/probably foreign listener ($holders); fallback launch will scan upward"
    fi
}
app_process_snapshot() {
    command -v lsappinfo >/dev/null 2>&1 || return 0
    /usr/bin/lsappinfo 2>/dev/null | awk '
        function flush() {
            if (name != "" && bid != "" && pid != "") {
                print name "\t" bid "\t" pid "\tunknown"
            }
        }
        /^[[:space:]]*[0-9]+\) "/ {
            flush()
            name=$0
            sub(/^[^\"]*\"/, "", name)
            sub(/\".*/, "", name)
            bid=""
            pid=""
        }
        /bundleID="/ {
            bid=$0
            sub(/^.*bundleID="/, "", bid)
            sub(/".*/, "", bid)
        }
        /pid = / {
            pid=$0
            sub(/^.*pid = /, "", pid)
            sub(/ .*/, "", pid)
        }
        END { flush() }
    ' || true
}
report_live_app_windows() {
    local rows matches row name bid pid windows
    if [ -z "$BUNDLE_ID" ]; then
        info "live app window check skipped (bundle id is unset)"
        return 0
    fi
    rows="$(app_process_snapshot)"
    if [ -z "$rows" ]; then
        info "live app window/process check unavailable (LaunchServices did not report visible app processes)"
        return 0
    fi
    matches="$(printf '%s\n' "$rows" | awk -F '\t' -v bid="$BUNDLE_ID" '$2 == bid {print}')"
    if [ -z "$matches" ]; then
        ok "no live app window process found for bundle id $BUNDLE_ID"
        return 0
    fi
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        IFS="$(printf '\t')" read -r name bid pid windows <<EOF
$row
EOF
        if [ "$PID_ALIVE" = "1" ]; then
            info "live app/window process '$name' PID $pid is registered for bundle id $bid; ownership is by bundle id only"
        else
            warn "live app/window process '$name' PID $pid is registered for bundle id $bid, but this launcher has no live recorded server — probably foreign/stale; doctor will not close it"
        fi
    done <<EOF
$matches
EOF
}

# --- Header ------------------------------------------------------------------
if [ "$JSON_MODE" = "0" ]; then
    printf '%sapp-it doctor%s — %s%s%s\n' "$C_BOLD" "$C_OFF" "$C_BOLD" "$APP_NAME" "$C_OFF"
    printf '  %sslug%s        %s\n' "$C_DIM" "$C_OFF" "$APP_SLUG"
    printf '  %sbundle id%s   %s\n' "$C_DIM" "$C_OFF" "${BUNDLE_ID:-(unset)}"
    printf '  %sport mode%s   %s\n' "$C_DIM" "$C_OFF" "$PORT_MODE"
    printf '  %sproject%s     %s\n' "$C_DIM" "$C_OFF" "$ROOT"
    if [ "$IS_URL_ONLY" = "1" ]; then
        printf '  %surl%s         %s\n' "$C_DIM" "$C_OFF" "$EXTERNAL_URL"
    fi
    printf '  %ssubject%s     %s\n' "$C_DIM" "$C_OFF" "${APP_UNDER_TEST:-<no .app built yet>}"
fi
if [ "${#APPS[@]}" -gt 1 ] && [ -z "$SELECTOR" ]; then
    others="$(for e in "${APPS[@]}"; do IFS='|' read -r _ s _ <<<"$e"; printf '%s ' "$s"; done)"
    note "config has ${#APPS[@]} apps; diagnosing the first. Pick another: desktop:doctor <slug>  ($others)"
fi

# =============================================================================
section "Configuration"
# Config parsed (we got here), so the file is present and valid JSON.
ok "scripts/app-it.config.json present and parses"

# Placeholder leakage — an unsubstituted __PLACEHOLDER__ means a broken build.
leaked=""
for v in "$APP_NAME" "$APP_SLUG" "$PORT" "$BUNDLE_ID" "$START_COMMAND" "$EXTERNAL_URL"; do
    case "$v" in *__*__*) leaked="$leaked $v" ;; esac
done
if [ -n "$leaked" ]; then
    fail "unresolved placeholder(s) in config:$leaked — the app was never fully customized"
else
    ok "no placeholder leakage in config values"
fi

# Bundle id shape: reverse-DNS, never com.<mac-username>.*.
USER_PREFIX="com.$(id -un | tr 'A-Z' 'a-z')."
bid_lc="$(lc "$BUNDLE_ID")"
case "$bid_lc" in
    "$USER_PREFIX"*) warn "bundle id starts with com.\$(id -un). — LaunchServices may reject it (error -600). Prefer com.user.$APP_SLUG." ;;
    *.*.*)           ok "bundle id is reverse-DNS shaped" ;;
    "")              fail "bundle id is empty" ;;
    *)               warn "bundle id '$BUNDLE_ID' is not reverse-DNS shaped (expected something like com.user.$APP_SLUG)" ;;
esac

if [ "$IS_URL_ONLY" = "1" ]; then
    case "$EXTERNAL_URL" in
        http://*|https://*) ok "URL-only launcher: $EXTERNAL_URL" ;;
        *)                 fail "URL-only launcher has a non-http(s) URL: $EXTERNAL_URL" ;;
    esac
    if [ -n "$PORT" ] || [ -n "$START_COMMAND" ] || [ -n "$BACKEND_PORT" ] || [ -n "$BACKEND_START" ]; then
        warn "external URL is set alongside local server fields; URL-only mode wins and local server fields are ignored"
    fi
    info "no local dev server configured; this app loads the hosted URL directly"
else
    # Preferred port sanity.
    case "$PORT" in
        ''|*[!0-9]*) warn "preferred port '$PORT' is not a plain number" ;;
        *)           ok "preferred port :$PORT" ;;
    esac
    case "$PORT_MODE" in
        fallback) ok "port mode: fallback (scan upward if the preferred port is busy)" ;;
        fixed)    ok "port mode: fixed (requires exactly :$PORT; no collision fallback)" ;;
        *)        fail "port_mode '$PORT_MODE' is invalid — expected fallback or fixed" ;;
    esac
fi

# =============================================================================
section "Installed bundle"
case "$APP_LOC" in
    installed) ok "installed at $INSTALL_APP" ;;
    build)     warn "built but NOT installed — run desktop:install to copy it into $INSTALL_DIR" ;;
    none)      fail "no .app found (neither installed nor under desktop/). Run desktop:build && desktop:install." ;;
esac
[ -d "$BUILD_APP" ] && info "build copy present at desktop/$APP_NAME.app"
if [ -d "$LEGACY_MYAPPS_APP" ]; then
    warn "legacy duplicate exists at $LEGACY_MYAPPS_APP; prefer the single installed copy under $INSTALL_DIR to avoid duplicate LaunchServices/Gatekeeper work"
fi

if [ -n "$APP_UNDER_TEST" ]; then
    PLIST="$APP_UNDER_TEST/Contents/Info.plist"
    if [ -f "$PLIST" ]; then
        got_id="$(plist_get "$PLIST" CFBundleIdentifier)"
        got_name="$(plist_get "$PLIST" CFBundleName)"
        got_exec="$(plist_get "$PLIST" CFBundleExecutable)"
        if [ "$got_id" = "$BUNDLE_ID" ]; then ok "Info.plist bundle id matches config ($got_id)"
        else warn "Info.plist bundle id '$got_id' != config '$BUNDLE_ID' — probably built before the last config edit; rebuild."; fi
        [ "$got_name" = "$APP_NAME" ] || warn "Info.plist CFBundleName '$got_name' != config '$APP_NAME'"
        [ "$got_exec" = "run" ] || warn "Info.plist CFBundleExecutable is '$got_exec' (expected 'run')"
        case "$got_id$got_name" in *__*__*) fail "Info.plist still contains __PLACEHOLDER__ values — broken build" ;; esac
    else
        fail "Info.plist missing inside the bundle — rebuild"
    fi

    RUN="$APP_UNDER_TEST/Contents/MacOS/run"
    RUN_SH="$APP_UNDER_TEST/Contents/MacOS/run.sh"
    WRAPPER="$APP_UNDER_TEST/Contents/MacOS/wrapper"
    LAUNCHER_SCRIPT="$RUN"
    [ -f "$RUN_SH" ] && LAUNCHER_SCRIPT="$RUN_SH"
    if [ -x "$RUN" ]; then
        if file "$RUN" 2>/dev/null | grep -q "Mach-O"; then
            ok "native run stub present (Contents/MacOS/run)"
        else
            warn "Contents/MacOS/run is a shell launcher, not a native stub — rebuild with current templates for better Launch Services reliability"
        fi
    else
        fail "Contents/MacOS/run missing or not executable"
    fi
    if [ -f "$RUN_SH" ]; then
        if [ -x "$RUN_SH" ]; then ok "launcher script present (Contents/MacOS/run.sh)"
        else fail "Contents/MacOS/run.sh exists but is not executable"; fi
    elif [ -x "$RUN" ] && ! file "$RUN" 2>/dev/null | grep -q "Mach-O"; then
        info "legacy launcher layout: shell script is Contents/MacOS/run"
    elif [ -x "$RUN" ]; then
        fail "native run stub is present but Contents/MacOS/run.sh is missing — rebuild"
    fi
    if [ -f "$WRAPPER" ]; then
        if file "$WRAPPER" 2>/dev/null | grep -q "Mach-O"; then ok "native Swift wrapper present (Mach-O executable)"
        else warn "Contents/MacOS/wrapper exists but is not a Mach-O binary"; fi
    elif [ -x "$LAUNCHER_SCRIPT" ] && grep -q -- "--app=" "$LAUNCHER_SCRIPT" 2>/dev/null; then
        info "Chrome-fallback launcher (no Swift wrapper) — Dock icon/single-instance caveats apply; Cmd+Q does not kill the daemon (use desktop:quit)"
    else
        warn "no Swift wrapper binary in the bundle — if this should be a Swift build, run desktop:build"
    fi

    ICNS="$APP_UNDER_TEST/Contents/Resources/AppIcon.icns"
    if [ -f "$ICNS" ]; then
        if file "$ICNS" 2>/dev/null | grep -qi "icon"; then ok "AppIcon.icns present"
        else warn "AppIcon.icns is not a recognizable icon file"; fi
    else
        warn "AppIcon.icns missing — the app will show a generic icon"
    fi
fi

# =============================================================================
section "Identity & signature"
if [ -n "$APP_UNDER_TEST" ]; then
    cs="$(/usr/bin/codesign -dvv "$APP_UNDER_TEST" 2>&1 || true)"
    if printf '%s' "$cs" | grep -q "Signature=adhoc"; then
        ok "ad-hoc signature present (satisfies macOS 15+ Gatekeeper for local launch)"
    elif printf '%s' "$cs" | grep -q "not signed at all"; then
        fail "bundle is not signed — macOS 15+ may refuse to open it. Rebuild (desktop:build re-signs it); that is the fix."
    elif printf '%s' "$cs" | grep -qi "Authority="; then
        info "signed with a real identity (not ad-hoc) — unusual for app-it but fine"
    else
        warn "could not determine signature state — probably unsigned; rebuild if the app won't open"
    fi

# Quarantine and iCloud xattrs can break Finder/Dock launch or re-signing.
    if has_xattr "$APP_UNDER_TEST" com.apple.quarantine; then
        warn "com.apple.quarantine is set — first launch needs right-click → Open (or run --fix-safe to clear it)"
    else
        ok "no quarantine flag on the bundle"
    fi
    if has_xattr "$APP_UNDER_TEST" "com.apple.fileprovider.fpfs#P"; then
        warn "iCloud fileprovider xattr present — codesign refuses to re-sign bundles with it. If the app shows ⊘, use the ditto rescue in the skill's Gatekeeper section."
    fi
    if has_xattr "$APP_UNDER_TEST" com.apple.FinderInfo; then
        info "com.apple.FinderInfo xattr present — can taint the signature on re-sign; --fix-safe clears quarantine but a full rebuild is the clean fix"
    fi
else
    info "no bundle to check — build & install first"
fi

# =============================================================================
section "Runtime — port, server, ownership"
RUNTIME_PORT=""; [ -f "$PORT_FILE" ] && RUNTIME_PORT="$(cat "$PORT_FILE" 2>/dev/null || true)"
REC_PID="";      [ -f "$PID_FILE" ]  && REC_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
PID_ALIVE=0
BRUNTIME=""
BREC_PID=""
BPID_ALIVE=0

if [ "$IS_URL_ONLY" = "1" ]; then
    ok "URL-only app; no local daemon, runtime port, or server ownership to check"
else
    # Preferred vs runtime port.
    if [ -z "$RUNTIME_PORT" ]; then
        if [ "$PORT_MODE" = "fixed" ]; then
            info "frontend not currently running (no recorded runtime port). Fixed-port mode requires :$PORT."
        else
            info "frontend not currently running (no recorded runtime port). Preferred frontend is :$PORT."
        fi
    elif [ "$RUNTIME_PORT" = "$PORT" ]; then
        if [ "$PORT_MODE" = "fixed" ]; then
            ok "fixed-port runtime is using required frontend port :$RUNTIME_PORT"
        else
            ok "frontend runtime port :$RUNTIME_PORT matches preferred frontend port"
        fi
    else
        if [ "$PORT_MODE" = "fixed" ]; then
            fail "fixed-port mode is configured for :$PORT, but runtime state says :$RUNTIME_PORT — quit/rebuild/relaunch before trusting browser storage"
        else
            info "frontend running on runtime port :$RUNTIME_PORT, preferred frontend :$PORT — fell back (a sibling app or another process probably held :$PORT at launch)"
        fi
    fi
    report_preferred_port_holder "frontend" "$PORT" "$RUNTIME_PORT" "$PORT_MODE"

    # Stale PID — low severity, because the launcher self-heals on the next click.
    if [ -n "$REC_PID" ]; then
        if kill -0 "$REC_PID" 2>/dev/null; then
            PID_ALIVE=1
            ok "recorded supervisor PID $REC_PID is alive"
        else
            warn "stale server.pid: recorded PID $REC_PID is dead. Low severity — the launcher clears this on next click. Clear now with --fix-safe."
        fi
    fi

    # Is the listener in this launcher's descendant tree?
    if [ -n "$RUNTIME_PORT" ]; then
        LISTENERS="$(lsof -ti tcp:"$RUNTIME_PORT" 2>/dev/null || true)"
        if [ -z "$LISTENERS" ]; then
            if [ "$PID_ALIVE" = "1" ]; then
                warn "supervisor PID $REC_PID is alive but nothing is listening on :$RUNTIME_PORT — server is probably still starting, or crashed after spawn (check the log)"
            else
                info "nothing is listening on :$RUNTIME_PORT (app is stopped)"
            fi
        elif [ "$PID_ALIVE" = "1" ]; then
            TREE=" $(walk_descendants "$REC_PID") "
            owned=0
            for p in $LISTENERS; do case "$TREE" in *" $p "*) owned=1; break ;; esac; done
            if [ "$owned" = "1" ]; then
                ok "the process on :$RUNTIME_PORT belongs to this launcher (in PID $REC_PID's tree)"
                code="$(curl -sS -o /dev/null --max-time 1 -w "%{http_code}" "http://localhost:$RUNTIME_PORT" 2>/dev/null || true)"
                if [ -n "$code" ] && [ "$code" != "000" ]; then ok "server responds on http://localhost:$RUNTIME_PORT (HTTP $code)"
                else warn "server is bound to :$RUNTIME_PORT but not answering HTTP yet — probably mid-startup"; fi
            else
                warn "a process holds :$RUNTIME_PORT but it is probably NOT this launcher's server (not in PID $REC_PID's tree) — could be a foreign app or a stale listener"
            fi
        else
            warn "the recorded supervisor is gone yet :$RUNTIME_PORT is held — probably a stale or foreign process; the launcher will scan past it on next click"
        fi
    fi

    # Backend check only when config declares one.
    if [ -n "$BACKEND_PORT" ]; then
        BRUNTIME=""; [ -f "$BPORT_FILE" ] && BRUNTIME="$(cat "$BPORT_FILE" 2>/dev/null || true)"
        BREC_PID=""; [ -f "$BPID_FILE" ] && BREC_PID="$(cat "$BPID_FILE" 2>/dev/null || true)"
        if [ -n "$BREC_PID" ] && kill -0 "$BREC_PID" 2>/dev/null; then
            BPID_ALIVE=1
        fi

        if [ -z "$BRUNTIME" ]; then
            if [ "$BPID_ALIVE" = "1" ]; then
                warn "backend supervisor PID $BREC_PID is alive but no backend.port is recorded — backend may still be starting, or state is incomplete"
            else
                info "multi-server backend not currently running (no recorded runtime port). Preferred backend is :$BACKEND_PORT."
            fi
        else
            if [ "$BRUNTIME" = "$BACKEND_PORT" ]; then
                ok "backend runtime port :$BRUNTIME matches preferred backend port"
            else
                info "backend running on runtime port :$BRUNTIME, preferred backend :$BACKEND_PORT — fell back"
            fi

            if [ -n "$BREC_PID" ]; then
                if [ "$BPID_ALIVE" = "1" ]; then
                    ok "recorded backend supervisor PID $BREC_PID is alive"
                else
                    warn "stale backend.pid: recorded PID $BREC_PID is dead. Low severity — the launcher clears this on next click. Clear now with --fix-safe."
                fi
            fi

            BLISTENERS="$(lsof -ti tcp:"$BRUNTIME" 2>/dev/null || true)"
            if [ -z "$BLISTENERS" ]; then
                if [ "$BPID_ALIVE" = "1" ]; then
                    warn "backend supervisor PID $BREC_PID is alive but nothing is listening on :$BRUNTIME — backend is probably still starting, or crashed after spawn (check backend.log)"
                else
                    warn "backend absent: runtime state says :$BRUNTIME, but no backend listener is present"
                fi
            elif [ "$BPID_ALIVE" = "1" ]; then
                BTREE=" $(walk_descendants "$BREC_PID") "
                bowned=0
                for p in $BLISTENERS; do case "$BTREE" in *" $p "*) bowned=1; break ;; esac; done
                if [ "$bowned" = "1" ]; then
                    ok "backend runtime port :$BRUNTIME is listening (preferred :$BACKEND_PORT) and belongs to this launcher"
                else
                    warn "backend runtime port :$BRUNTIME is held but it is probably NOT this launcher's backend (not in PID $BREC_PID's tree) — could be foreign or stale"
                fi
            else
                warn "backend runtime port :$BRUNTIME is held but the recorded backend PID is dead or missing — probably foreign or stale"
            fi
        fi
        report_preferred_port_holder "backend" "$BACKEND_PORT" "$BRUNTIME" "fallback"
    fi
fi

section "Live windows — diagnostic only"
report_live_app_windows

# Catch "works in terminal, dead from Dock" by using the launcher's PATH.
if [ "$IS_URL_ONLY" = "1" ]; then
    info "URL-only launcher: no start command binary is expected"
else
    CMD="$START_COMMAND"
    case "$CMD" in cd\ *\ \&\&\ *) CMD="${CMD#* && }" ;; esac
    FIRST_BIN="$(printf '%s' "$CMD" | awk '{print $1}')"
    if [ -n "$FIRST_BIN" ]; then
        if PATH="$LAUNCHER_PATH" command -v "$FIRST_BIN" >/dev/null 2>&1; then
            ok "start command's binary '$FIRST_BIN' resolves on the launcher's PATH"
        else
            warn "start command's binary '$FIRST_BIN' is NOT on the launcher's PATH — the app would fail from a Dock click even if it works in your terminal"
        fi
    fi
fi

# =============================================================================
section "State & logs"
if [ -d "$STATE_DIR" ]; then info "state dir: $STATE_DIR"; else info "no state dir yet (app hasn't been launched)"; fi
if [ -f "$RUNTIME_SUMMARY_FILE" ]; then
    info "runtime summary: $RUNTIME_SUMMARY_FILE"
else
    info "no runtime summary yet: $RUNTIME_SUMMARY_FILE"
fi
if [ "$IS_URL_ONLY" = "1" ]; then
    info "URL-only launcher: no server log is expected"
elif [ -f "$SERVER_LOG" ]; then
    sz="$(wc -c < "$SERVER_LOG" 2>/dev/null | tr -d ' ')"
    info "server log: $SERVER_LOG (${sz:-0} bytes)"
else
    info "no server log yet: $SERVER_LOG"
fi
[ -n "$BACKEND_PORT" ] && { [ -f "$BACKEND_LOG" ] && info "backend log: $BACKEND_LOG" || info "no backend log yet: $BACKEND_LOG"; }

if [ "$DO_TAIL" = "1" ] && [ "$JSON_MODE" = "0" ]; then
    if [ -f "$SERVER_LOG" ]; then
        printf '\n  %slast %s lines of server.log:%s\n' "$C_DIM" "$TAIL_N" "$C_OFF"
        tail -n "$TAIL_N" "$SERVER_LOG" 2>/dev/null | sed 's/^/    /'
    else
        note "(--tail) no server log to tail yet"
    fi
fi

# =============================================================================
section "Template drift"
# Feature-probe installed artifacts against the current templates. This stays
# even though the manifest now carries template_version (the verify contract):
# probing still catches legacy, unstamped builds, and an `upgrade` step can layer
# the template_version comparison on top of it.
# Keep `grep -qboa` for wrapper markers because older builds hid them from strings.
WRAPPER_SRC="$SCRIPT_DIR/wrapper.swift"
if [ "$IS_URL_ONLY" = "1" ]; then
    RUN_SRC="$SCRIPT_DIR/run-template-url.sh"
else
    RUN_SRC="$SCRIPT_DIR/run-template.sh"
fi
INSTALLED_WRAPPER="${APP_UNDER_TEST:+$APP_UNDER_TEST/Contents/MacOS/wrapper}"
INSTALLED_RUN="${APP_UNDER_TEST:+$APP_UNDER_TEST/Contents/MacOS/run}"
INSTALLED_RUN_SH="${APP_UNDER_TEST:+$APP_UNDER_TEST/Contents/MacOS/run.sh}"
INSTALLED_LAUNCHER="$INSTALLED_RUN"
[ -f "${INSTALLED_RUN_SH:-/nonexistent}" ] && INSTALLED_LAUNCHER="$INSTALLED_RUN_SH"
drift_found=0

if [ -n "$APP_UNDER_TEST" ] && [ -f "$WRAPPER_SRC" ] && [ -f "${INSTALLED_WRAPPER:-/nonexistent}" ]; then
    # marker|human-name — present in the current source, probed in the binary.
    for probe in \
        "reloadPageIgnoringCache|the full menu bar (Cmd+R/zoom/Cmd+W)" \
        "Find in page|find-in-page (Cmd+F)"; do
        marker="${probe%%|*}"; human="${probe##*|}"
        if grep -q "$marker" "$WRAPPER_SRC" 2>/dev/null && ! grep -qboa "$marker" "$INSTALLED_WRAPPER" 2>/dev/null; then
            warn "installed wrapper is missing $human — built before that template; rebuild (desktop:build && desktop:install)"
            drift_found=1
        fi
    done
fi

if [ -n "$APP_UNDER_TEST" ] && [ -f "$RUN_SRC" ] && [ -f "${INSTALLED_LAUNCHER:-/nonexistent}" ] && grep -q "MacOS/wrapper" "$INSTALLED_LAUNCHER" 2>/dev/null; then
    if [ "$IS_URL_ONLY" = "1" ]; then
        RUN_PROBES=(
            "allow-external-hosts|hosted auth/API navigation stays in-window"
            "APP_IT_SMOKE|URL-only smoke seam"
        )
    else
        RUN_PROBES=(
            "Reattach to our own existing server|fast warm-relaunch (descendant-walk reattach)"
            "Two-stage readiness probe|the two-stage readiness probe"
        )
    fi
    for probe in "${RUN_PROBES[@]}"; do
        marker="${probe%%|*}"; human="${probe##*|}"
        if grep -qF "$marker" "$RUN_SRC" 2>/dev/null && ! grep -qF "$marker" "$INSTALLED_LAUNCHER" 2>/dev/null; then
            warn "installed launcher script is missing $human — predates that template; rebuild"
            drift_found=1
        fi
    done
fi

if [ -z "$APP_UNDER_TEST" ]; then
    info "no bundle to compare against the current templates"
elif [ ! -f "$WRAPPER_SRC" ]; then
    info "scripts/wrapper.swift not found next to this script — skipping wrapper drift check"
elif [ "$drift_found" = "0" ]; then
    ok "installed launcher matches the current templates' probed features"
fi

# =============================================================================
# --- Fix-safe (opt-in) -------------------------------------------------------
if [ "$DO_FIX" = "1" ]; then
    section "Fix-safe actions"
    note "Only app-it's own generated state — never your code, deps, or config."
    didfix() { [ "$JSON_MODE" = "1" ] || printf '  %s[fix ]%s  %s\n' "$C_OK" "$C_OFF" "$1"; }
    skipfix(){ [ "$JSON_MODE" = "1" ] || printf '  %s[skip]%s  %s\n' "$C_DIM" "$C_OFF" "$1"; }

    # 1. Stale pid/port files.
    cleared_state=0
    if [ -n "$REC_PID" ] && ! kill -0 "$REC_PID" 2>/dev/null; then
        rm -f "$PID_FILE" "$PORT_FILE"; cleared_state=1
        didfix "removed stale server.pid/server.port (recorded PID $REC_PID was dead)"
    elif [ "$PID_ALIVE" = "1" ]; then
        skipfix "server.pid is live (PID $REC_PID) — left untouched"
    fi
    if [ -f "$BPID_FILE" ]; then
        BPID="$(cat "$BPID_FILE" 2>/dev/null || true)"
        if [ -n "$BPID" ] && ! kill -0 "$BPID" 2>/dev/null; then
            rm -f "$BPID_FILE" "$BPORT_FILE"; cleared_state=1
            didfix "removed stale backend.pid/backend.port (PID $BPID was dead)"
        fi
    fi
    [ "$cleared_state" = "0" ] && [ -z "$REC_PID" ] && skipfix "no stale pid/port files to clear"

    # 2. Stale LaunchServices registration for known bundle paths only.
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    if [ -x "$LSREGISTER" ] && [ -d "$INSTALL_APP" ]; then
        [ -d "$BUILD_APP" ] && "$LSREGISTER" -u "$BUILD_APP" >/dev/null 2>&1 || true
        "$LSREGISTER" -f "$INSTALL_APP" >/dev/null 2>&1 || true
        didfix "re-registered the installed bundle with LaunchServices (and deregistered the build-path copy)"
    else
        skipfix "LaunchServices: nothing to do (no installed bundle, or lsregister unavailable)"
    fi

    # 3. Rebuild icon from source, then refresh the installed copy if changed.
    ICON_SRC=""
    for c in "$ROOT/assets/${APP_SLUG}-icon.png" "$ROOT/assets/${APP_SLUG}-icon.svg" "$ROOT/assets/app-icon.png" "$ROOT/assets/app-icon.svg"; do
        [ -f "$c" ] && ICON_SRC="$c" && break
    done
    if [ -n "$ICON_SRC" ] && [ -x "$SCRIPT_DIR/desktop-icons.sh" ]; then
        BUILD_ICNS="$BUILD_APP/Contents/Resources/AppIcon.icns"
        before=""; [ -f "$BUILD_ICNS" ] && before="$(shasum -a 256 "$BUILD_ICNS" 2>/dev/null | awk '{print $1}')"
        if APP_NAME="$APP_NAME" APP_SLUG="$APP_SLUG" "$SCRIPT_DIR/desktop-icons.sh" >/dev/null 2>&1; then
            after=""; [ -f "$BUILD_ICNS" ] && after="$(shasum -a 256 "$BUILD_ICNS" 2>/dev/null | awk '{print $1}')"
            if [ "$before" != "$after" ]; then
                didfix "rebuilt AppIcon.icns from $(basename "$ICON_SRC")"
                if [ -d "$INSTALL_APP" ] && [ -f "$BUILD_ICNS" ]; then
                    cp "$BUILD_ICNS" "$INSTALL_APP/Contents/Resources/AppIcon.icns"
                    /usr/bin/xattr -dr com.apple.quarantine "$INSTALL_APP" 2>/dev/null || true
                    /usr/bin/codesign --force --deep --sign - "$INSTALL_APP" >/dev/null 2>&1 || true
                    touch "$INSTALL_APP"; killall Dock 2>/dev/null || true
                    didfix "copied the new icon into the installed bundle, re-signed it, and refreshed the Dock"
                fi
            else
                skipfix "icon already up to date with $(basename "$ICON_SRC")"
            fi
        else
            skipfix "icon rebuild failed (see desktop-icons.sh) — left as-is"
        fi
    else
        skipfix "no source icon at assets/${APP_SLUG}-icon.{png,svg} — nothing to rebuild"
    fi

    # 4. Clear quarantine on the generated .app (targeted, preserves signature).
    cleared_q=0
    for b in "$INSTALL_APP" "$BUILD_APP"; do
        if [ -d "$b" ] && /usr/bin/xattr -p com.apple.quarantine "$b" >/dev/null 2>&1; then
            /usr/bin/xattr -dr com.apple.quarantine "$b" 2>/dev/null || true
            didfix "cleared com.apple.quarantine on $(basename "$b") ($b)"
            cleared_q=1
        fi
    done
    [ "$cleared_q" = "0" ] && skipfix "no quarantine flag to clear"

    note "Re-run desktop:doctor to confirm."
fi

# =============================================================================
if [ "$FAIL_N" -gt 0 ]; then
    RECOMMENDED_ACTION="fix_failures"
elif [ "$WARN_N" -gt 0 ]; then
    RECOMMENDED_ACTION="review_warnings"
else
    RECOMMENDED_ACTION="none"
fi

if [ "$JSON_MODE" = "1" ]; then
    DOCTOR_APP_NAME="$APP_NAME" \
    DOCTOR_APP_SLUG="$APP_SLUG" \
    DOCTOR_BUNDLE_ID="$BUNDLE_ID" \
    DOCTOR_VERSION="$VERSION" \
    DOCTOR_MANIFEST_SCHEMA="$CFG_SCHEMA_VERSION" \
    DOCTOR_MANIFEST_GENERATOR="$CFG_GENERATOR_VERSION" \
    DOCTOR_MANIFEST_TEMPLATE="$CFG_TEMPLATE_VERSION" \
    DOCTOR_PROJECT_ROOT="$ROOT" \
    DOCTOR_EXTERNAL_URL="$EXTERNAL_URL" \
    DOCTOR_IS_URL_ONLY="$IS_URL_ONLY" \
    DOCTOR_SUBJECT="$APP_UNDER_TEST" \
    DOCTOR_SUBJECT_LOCATION="$APP_LOC" \
    DOCTOR_INSTALL_APP="$INSTALL_APP" \
    DOCTOR_BUILD_APP="$BUILD_APP" \
    DOCTOR_STATE_DIR="$STATE_DIR" \
    DOCTOR_LOG_DIR="$LOG_DIR" \
    DOCTOR_SERVER_LOG="$SERVER_LOG" \
    DOCTOR_BACKEND_LOG="$BACKEND_LOG" \
    DOCTOR_RUNTIME_SUMMARY="$RUNTIME_SUMMARY_FILE" \
    DOCTOR_PREFERRED_PORT="$PORT" \
    DOCTOR_PORT_MODE="$PORT_MODE" \
    DOCTOR_RUNTIME_PORT="$RUNTIME_PORT" \
    DOCTOR_BACKEND_PREFERRED_PORT="$BACKEND_PORT" \
    DOCTOR_BACKEND_RUNTIME_PORT="$BRUNTIME" \
    DOCTOR_SERVER_PID="$REC_PID" \
    DOCTOR_PID_ALIVE="$PID_ALIVE" \
    DOCTOR_BACKEND_PID="$BREC_PID" \
    DOCTOR_BACKEND_PID_ALIVE="$BPID_ALIVE" \
    DOCTOR_OK_N="$OK_N" \
    DOCTOR_WARN_N="$WARN_N" \
    DOCTOR_FAIL_N="$FAIL_N" \
    DOCTOR_INFO_N="$INFO_N" \
    DOCTOR_RECOMMENDED_ACTION="$RECOMMENDED_ACTION" \
    /usr/bin/python3 - "$JSON_CHECKS_FILE" <<'PY'
import json
import os
import sys

def empty_to_none(value):
    return value if value else None

def manifest_schema_version():
    raw = os.environ.get("DOCTOR_MANIFEST_SCHEMA", "")
    if raw == "":
        return None
    try:
        return int(raw)
    except ValueError:
        return raw

checks = []
with open(sys.argv[1], encoding="utf-8") as handle:
    for line in handle:
        section, status, message = line.rstrip("\n").split("\t", 2)
        checks.append({
            "section": section,
            "status": status,
            "message": message,
        })

payload = {
    "schema_version": 1,
    "tool": "app-it.desktop-doctor",
    "manifest": {
        "schema_version": manifest_schema_version(),
        "generator_version": empty_to_none(os.environ["DOCTOR_MANIFEST_GENERATOR"]),
        "template_version": empty_to_none(os.environ["DOCTOR_MANIFEST_TEMPLATE"]),
    },
    "app": {
        "name": os.environ["DOCTOR_APP_NAME"],
        "slug": os.environ["DOCTOR_APP_SLUG"],
        "bundle_id": empty_to_none(os.environ["DOCTOR_BUNDLE_ID"]),
        "version": empty_to_none(os.environ["DOCTOR_VERSION"]),
        "url_only": os.environ["DOCTOR_IS_URL_ONLY"] == "1",
        "external_url": empty_to_none(os.environ["DOCTOR_EXTERNAL_URL"]),
    },
    "project": {
        "root": os.environ["DOCTOR_PROJECT_ROOT"],
    },
    "subject": {
        "path": empty_to_none(os.environ["DOCTOR_SUBJECT"]),
        "location": os.environ["DOCTOR_SUBJECT_LOCATION"],
        "installed_path": os.environ["DOCTOR_INSTALL_APP"],
        "build_path": os.environ["DOCTOR_BUILD_APP"],
    },
    "ports": {
        "mode": os.environ["DOCTOR_PORT_MODE"],
        "preferred": empty_to_none(os.environ["DOCTOR_PREFERRED_PORT"]),
        "runtime": empty_to_none(os.environ["DOCTOR_RUNTIME_PORT"]),
        "backend_preferred": empty_to_none(os.environ["DOCTOR_BACKEND_PREFERRED_PORT"]),
        "backend_runtime": empty_to_none(os.environ["DOCTOR_BACKEND_RUNTIME_PORT"]),
    },
    "state": {
        "state_dir": os.environ["DOCTOR_STATE_DIR"],
        "log_dir": os.environ["DOCTOR_LOG_DIR"],
        "server_log": os.environ["DOCTOR_SERVER_LOG"],
        "backend_log": empty_to_none(os.environ["DOCTOR_BACKEND_LOG"]),
        "runtime_summary": os.environ["DOCTOR_RUNTIME_SUMMARY"],
        "server_pid": empty_to_none(os.environ["DOCTOR_SERVER_PID"]),
        "server_pid_alive": os.environ["DOCTOR_PID_ALIVE"] == "1",
        "backend_pid": empty_to_none(os.environ["DOCTOR_BACKEND_PID"]),
        "backend_pid_alive": os.environ["DOCTOR_BACKEND_PID_ALIVE"] == "1",
    },
    "counts": {
        "ok": int(os.environ["DOCTOR_OK_N"]),
        "warn": int(os.environ["DOCTOR_WARN_N"]),
        "fail": int(os.environ["DOCTOR_FAIL_N"]),
        "info": int(os.environ["DOCTOR_INFO_N"]),
    },
    "checks": checks,
    "recommended_action": os.environ["DOCTOR_RECOMMENDED_ACTION"],
}
json.dump(payload, sys.stdout, ensure_ascii=False, indent=2)
sys.stdout.write("\n")
PY
else
    section "Summary"
    printf '  %s%d ok%s · %s%d warn%s · %s%d fail%s · %d info\n' \
        "$C_OK" "$OK_N" "$C_OFF" "$C_WARN" "$WARN_N" "$C_OFF" "$C_FAIL" "$FAIL_N" "$C_OFF" "$INFO_N"
    if [ "$FAIL_N" -gt 0 ]; then
        printf '  %sAction needed — see the [fail] lines above.%s\n' "$C_FAIL" "$C_OFF"
    elif [ "$WARN_N" -gt 0 ]; then
        printf '  %sMostly healthy — review the [warn] lines.%s\n' "$C_WARN" "$C_OFF"
    else
        printf '  %sHealthy — no problems found in app-it'\''s generated artifacts.%s\n' "$C_OK" "$C_OFF"
    fi
    note "This report is read-only and safe to paste into a bug report."
fi

if [ "$STRICT_MODE" = "1" ] && { [ "$FAIL_N" -gt 0 ] || [ "$WARN_N" -gt 0 ]; }; then
    exit 1
fi

exit 0
