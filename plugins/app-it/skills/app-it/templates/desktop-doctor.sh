#!/bin/bash
# app-it doctor — self-diagnose ONE generated launcher and print a short,
# readable, issue-ready report. Read-only by default.
#
# This is a verbatim-copied helper (like desktop-build.sh / desktop-quit.sh) —
# it reads scripts/app-it.config.json at runtime, so it carries no __PLACEHOLDER__
# substitution. desktop-build.sh does NOT touch it.
#
# Usage:
#   ./scripts/desktop-doctor.sh [slug-or-name]   # diagnose one app
#   ./scripts/desktop-doctor.sh --tail[=N]        # also tail N launcher-log lines (default 20)
#   ./scripts/desktop-doctor.sh --fix-safe        # apply the narrow generated-state fixes below
#   ./scripts/desktop-doctor.sh --help
#
# Selection: zero args + one app in config → that app. Zero args + multiple
# apps → the roster is listed and the FIRST app is diagnosed; pass a slug to
# pick another.
#
# DESIGN CONTRACT — this is a diagnostic, not a fixer.
#   * Every check is deterministic and local. No network. No installs. No new
#     dependencies. The whole run finishes in well under a second.
#   * When a check cannot be certain, the message says "probably" rather than
#     asserting. A diagnostic that lies is worse than none.
#   * It NEVER mutates your project. The only state it can touch — and only
#     with --fix-safe — is app-it's OWN generated artifacts:
#       1. stale PID/port files (only when the recorded process is dead),
#       2. this bundle's stale LaunchServices registration,
#       3. the generated AppIcon.icns (rebuilt from your source image),
#       4. com.apple.quarantine on the generated .app.
#     It will not touch your source, dependencies, framework config, or
#     anything outside app-it's generated state — by construction.
#
# Exit status: 0 for any successful diagnosis, regardless of findings (this is
# a report you can paste into a bug report, not a test that should make `npm`
# spew red). Non-zero only when it genuinely can't run (bad flag, no config,
# unknown app).

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

ok()   { printf '  %s[ ok ]%s  %s\n' "$C_OK"   "$C_OFF" "$1"; OK_N=$((OK_N+1)); }
warn() { printf '  %s[warn]%s  %s\n' "$C_WARN" "$C_OFF" "$1"; WARN_N=$((WARN_N+1)); }
fail() { printf '  %s[fail]%s  %s\n' "$C_FAIL" "$C_OFF" "$1"; FAIL_N=$((FAIL_N+1)); }
info() { printf '  %s[info]%s  %s\n' "$C_INFO" "$C_OFF" "$1"; INFO_N=$((INFO_N+1)); }
note() { printf '          %s%s%s\n' "$C_DIM" "$1" "$C_OFF"; }
section() { printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_OFF"; }
die() { printf '%sdesktop-doctor: %s%s\n' "$C_FAIL" "$1" "$C_OFF" >&2; exit "${2:-2}"; }

lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

usage() {
    cat <<'EOF'
app-it doctor — diagnose one generated launcher.

  ./scripts/desktop-doctor.sh [slug-or-name]   diagnose one app (default: the sole/first app)
  ./scripts/desktop-doctor.sh --tail[=N]        also tail N launcher-log lines (default 20)
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
        --tail)      DO_TAIL=1 ;;
        --tail=*)    DO_TAIL=1; TAIL_N="${arg#--tail=}" ;;
        --*)         usage >&2; die "unknown flag: $arg" ;;
        *)           [ -z "$SELECTOR" ] && SELECTOR="$arg" || die "unexpected extra argument: $arg" ;;
    esac
done
case "$TAIL_N" in ''|*[!0-9]*) die "--tail expects a number, got: $TAIL_N" ;; esac

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
for a in cfg.get("apps", []):
    name = a.get("name", "")
    slug = a.get("slug") or re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    fields = [
        name, slug, str(a.get("port", "")), a.get("start_command", ""),
        a.get("bundle_id", ""), a.get("version", "0.1.0"), a.get("polyfill_path", ""),
        str(a.get("backend_port") or ""), a.get("backend_start_command") or "",
    ]
    print("|".join(f.replace("|", " ") for f in fields))
PY
) || die "failed to read app-it.config.json (see message above)" 3

[ "${#APPS[@]}" -gt 0 ] || die "no apps configured in scripts/app-it.config.json." 2

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

IFS='|' read -r APP_NAME APP_SLUG PORT START_COMMAND BUNDLE_ID VERSION POLYFILL_PATH BACKEND_PORT BACKEND_START <<<"$SELECTED"

# --- Paths (mirror run-template.sh / desktop-quit.sh conventions) ------------
STATE_DIR="$HOME/Library/Application Support/app-it/$APP_SLUG"
LOG_DIR="$HOME/Library/Logs/app-it/$APP_SLUG"
PID_FILE="$STATE_DIR/server.pid";    PORT_FILE="$STATE_DIR/server.port"
BPID_FILE="$STATE_DIR/backend.pid";  BPORT_FILE="$STATE_DIR/backend.port"
SERVER_LOG="$LOG_DIR/server.log";    BACKEND_LOG="$LOG_DIR/backend.log"
INSTALL_APP="$INSTALL_DIR/$APP_NAME.app"
BUILD_APP="$ROOT/desktop/$APP_NAME.app"

# The user double-clicks the INSTALLED bundle; that's the primary subject. Fall
# back to the build copy (with a note) so a not-yet-installed app still reports.
if   [ -d "$INSTALL_APP" ]; then APP_UNDER_TEST="$INSTALL_APP"; APP_LOC="installed"
elif [ -d "$BUILD_APP" ];   then APP_UNDER_TEST="$BUILD_APP";   APP_LOC="build"
else APP_UNDER_TEST=""; APP_LOC="none"; fi

# PATH augmentation identical to run-template.sh, so `command -v` sees exactly
# what the launcher sees when started from Finder/Dock (bare PATH=/usr/bin:/bin).
NVM_BIN=""
if [ -d "$HOME/.nvm/versions/node" ]; then
    LATEST_NVM_NODE="$(ls -1 "$HOME/.nvm/versions/node" 2>/dev/null | sort -V | tail -1)"
    [ -n "$LATEST_NVM_NODE" ] && NVM_BIN="$HOME/.nvm/versions/node/$LATEST_NVM_NODE/bin"
fi
LAUNCHER_PATH="$HOME/.bun/bin:$HOME/.deno/bin:$HOME/.volta/bin:$HOME/.local/share/mise/shims:$HOME/.asdf/shims:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:${NVM_BIN}:$HOME/Library/pnpm:$PATH"

# walk_descendants PID — echo the PID and up to 4 generations of children,
# space-separated. Mirrors run-template.sh's reattach gate so "does the running
# server belong to this launcher" uses the SAME ownership test the launcher does.
walk_descendants() {
    local root="$1" current="$1" tree="$1" gen
    for _ in 1 2 3 4; do
        gen="$(pgrep -P "$current" 2>/dev/null | tr '\n' ' ')"
        [ -z "$gen" ] && break
        tree="$tree $gen"; current="$gen"
    done
    printf '%s' "$tree"
}

plist_get() { /usr/libexec/PlistBuddy -c "Print $2" "$1" 2>/dev/null; }
has_xattr() { /usr/bin/xattr -p "$2" "$1" >/dev/null 2>&1; }

# --- Header ------------------------------------------------------------------
printf '%sapp-it doctor%s — %s%s%s\n' "$C_BOLD" "$C_OFF" "$C_BOLD" "$APP_NAME" "$C_OFF"
printf '  %sslug%s        %s\n' "$C_DIM" "$C_OFF" "$APP_SLUG"
printf '  %sbundle id%s   %s\n' "$C_DIM" "$C_OFF" "${BUNDLE_ID:-(unset)}"
printf '  %sproject%s     %s\n' "$C_DIM" "$C_OFF" "$ROOT"
printf '  %ssubject%s     %s\n' "$C_DIM" "$C_OFF" "${APP_UNDER_TEST:-<no .app built yet>}"
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
for v in "$APP_NAME" "$APP_SLUG" "$PORT" "$BUNDLE_ID" "$START_COMMAND"; do
    case "$v" in *__*__*) leaked="$leaked $v" ;; esac
done
if [ -n "$leaked" ]; then
    fail "unresolved placeholder(s) in config:$leaked — the app was never fully customized"
else
    ok "no placeholder leakage in config values"
fi

# Bundle id shape. The build script's own rule: never com.<mac-username>.* and
# it should be reverse-DNS shaped.
USER_PREFIX="com.$(id -un | tr 'A-Z' 'a-z')."
bid_lc="$(lc "$BUNDLE_ID")"
case "$bid_lc" in
    "$USER_PREFIX"*) warn "bundle id starts with com.\$(id -un). — LaunchServices may reject it (error -600). Prefer com.user.$APP_SLUG." ;;
    *.*.*)           ok "bundle id is reverse-DNS shaped" ;;
    "")              fail "bundle id is empty" ;;
    *)               warn "bundle id '$BUNDLE_ID' is not reverse-DNS shaped (expected something like com.user.$APP_SLUG)" ;;
esac

# Preferred port sanity.
case "$PORT" in
    ''|*[!0-9]*) warn "preferred port '$PORT' is not a plain number" ;;
    *)           ok "preferred port :$PORT" ;;
esac

# =============================================================================
section "Installed bundle"
case "$APP_LOC" in
    installed) ok "installed at $INSTALL_APP" ;;
    build)     warn "built but NOT installed — run desktop:install to copy it into $INSTALL_DIR" ;;
    none)      fail "no .app found (neither installed nor under desktop/). Run desktop:build && desktop:install." ;;
esac
[ -d "$BUILD_APP" ] && info "build copy present at desktop/$APP_NAME.app"

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
    WRAPPER="$APP_UNDER_TEST/Contents/MacOS/wrapper"
    if [ -x "$RUN" ]; then ok "launcher script present (Contents/MacOS/run)"; else fail "Contents/MacOS/run missing or not executable"; fi
    if [ -f "$WRAPPER" ]; then
        if file "$WRAPPER" 2>/dev/null | grep -q "Mach-O"; then ok "native Swift wrapper present (Mach-O executable)"
        else warn "Contents/MacOS/wrapper exists but is not a Mach-O binary"; fi
    elif [ -x "$RUN" ] && grep -q -- "--app=" "$RUN" 2>/dev/null; then
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

    # Quarantine + the iCloud xattrs the skill documents as signature-breaking.
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

# Preferred vs runtime port.
if [ -z "$RUNTIME_PORT" ]; then
    info "not currently running (no recorded runtime port). Preferred is :$PORT."
elif [ "$RUNTIME_PORT" = "$PORT" ]; then
    ok "runtime port :$RUNTIME_PORT matches the preferred port"
else
    info "running on :$RUNTIME_PORT, preferred :$PORT — fell back (a sibling app or another process probably held :$PORT at launch)"
fi

# Stale PID — low severity, because the launcher self-heals on the next click.
PID_ALIVE=0
if [ -n "$REC_PID" ]; then
    if kill -0 "$REC_PID" 2>/dev/null; then
        PID_ALIVE=1
        ok "recorded supervisor PID $REC_PID is alive"
    else
        warn "stale server.pid: recorded PID $REC_PID is dead. Low severity — the launcher clears this on next click. Clear now with --fix-safe."
    fi
fi

# Does the running server actually belong to THIS launcher? Same descendant-walk
# the launcher uses to decide whether to reattach. Honest "probably" when the
# ownership tree can't confirm it.
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

# Backend (A3.2 multi-server) — only when the config declares one.
if [ -n "$BACKEND_PORT" ]; then
    BRUNTIME=""; [ -f "$BPORT_FILE" ] && BRUNTIME="$(cat "$BPORT_FILE" 2>/dev/null || true)"
    if [ -n "$BRUNTIME" ] && lsof -ti tcp:"$BRUNTIME" >/dev/null 2>&1; then ok "backend listening on :$BRUNTIME"
    elif [ -n "$BACKEND_PORT" ]; then info "multi-server app; backend not currently listening (preferred :$BACKEND_PORT)"; fi
fi

# Launch-time binary preflight — catches "works in my terminal, dead from Dock"
# because Finder launches with a bare PATH. Uses the launcher's augmented PATH.
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

# =============================================================================
section "State & logs"
if [ -d "$STATE_DIR" ]; then info "state dir: $STATE_DIR"; else info "no state dir yet (app hasn't been launched)"; fi
if [ -f "$SERVER_LOG" ]; then
    sz="$(wc -c < "$SERVER_LOG" 2>/dev/null | tr -d ' ')"
    info "server log: $SERVER_LOG (${sz:-0} bytes)"
else
    info "no server log yet: $SERVER_LOG"
fi
[ -n "$BACKEND_PORT" ] && { [ -f "$BACKEND_LOG" ] && info "backend log: $BACKEND_LOG" || info "no backend log yet: $BACKEND_LOG"; }

if [ "$DO_TAIL" = "1" ]; then
    if [ -f "$SERVER_LOG" ]; then
        printf '\n  %slast %s lines of server.log:%s\n' "$C_DIM" "$TAIL_N" "$C_OFF"
        tail -n "$TAIL_N" "$SERVER_LOG" 2>/dev/null | sed 's/^/    /'
    else
        note "(--tail) no server log to tail yet"
    fi
fi

# =============================================================================
section "Template drift"
# No version stamp exists in generated apps, so we feature-probe the installed
# artifacts against the CURRENT templates next to this script — reusing the
# skill's documented `grep -qboa <marker> wrapper` idiom (string literals get
# inlined by swiftc -O in a way `strings` misses). A feature the template has
# but the installed app lacks ⇒ the app predates it ⇒ rebuild to refresh.
WRAPPER_SRC="$SCRIPT_DIR/wrapper.swift"
RUN_SRC="$SCRIPT_DIR/run-template.sh"
INSTALLED_WRAPPER="${APP_UNDER_TEST:+$APP_UNDER_TEST/Contents/MacOS/wrapper}"
INSTALLED_RUN="${APP_UNDER_TEST:+$APP_UNDER_TEST/Contents/MacOS/run}"
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

if [ -n "$APP_UNDER_TEST" ] && [ -f "$RUN_SRC" ] && [ -f "${INSTALLED_RUN:-/nonexistent}" ] && grep -q "MacOS/wrapper" "$INSTALLED_RUN" 2>/dev/null; then
    for probe in \
        "Reattach to our own existing server|fast warm-relaunch (descendant-walk reattach)" \
        "Two-stage readiness probe|the two-stage readiness probe"; do
        marker="${probe%%|*}"; human="${probe##*|}"
        if grep -qF "$marker" "$RUN_SRC" 2>/dev/null && ! grep -qF "$marker" "$INSTALLED_RUN" 2>/dev/null; then
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
    didfix() { printf '  %s[fix ]%s  %s\n' "$C_OK" "$C_OFF" "$1"; }
    skipfix(){ printf '  %s[skip]%s  %s\n' "$C_DIM" "$C_OFF" "$1"; }

    # 1. Stale pid/port files (only when the recorded process is dead).
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

    # 2. Stale LaunchServices registration for THIS bundle's known paths only.
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    if [ -x "$LSREGISTER" ] && [ -d "$INSTALL_APP" ]; then
        [ -d "$BUILD_APP" ] && "$LSREGISTER" -u "$BUILD_APP" >/dev/null 2>&1 || true
        "$LSREGISTER" -f "$INSTALL_APP" >/dev/null 2>&1 || true
        didfix "re-registered the installed bundle with LaunchServices (and deregistered the build-path copy)"
    else
        skipfix "LaunchServices: nothing to do (no installed bundle, or lsregister unavailable)"
    fi

    # 3. Rebuilt icon — regenerate from your source image (mtime-aware), then
    #    refresh the installed bundle's icon if it changed.
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

exit 0
