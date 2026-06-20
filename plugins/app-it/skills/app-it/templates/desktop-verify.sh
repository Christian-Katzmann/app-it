#!/bin/bash
# app-it verify - behavior-first check for one generated launcher.
#
# Usage:
#   ./scripts/desktop-verify.sh [slug-or-name]          # headless smoke + doctor summary
#   ./scripts/desktop-verify.sh --json [slug-or-name]   # machine-readable summary
#   ./scripts/desktop-verify.sh --build                 # run desktop-build.sh first
#   ./scripts/desktop-verify.sh --install               # run desktop-install.sh first
#   ./scripts/desktop-verify.sh --cleanup               # stop app-it-owned runtime state at the end
#   ./scripts/desktop-verify.sh --strict                # exit non-zero on warnings/failures
#
# Default mode is intentionally conservative: it does not open a GUI window and
# does not quit a user's warm server. It uses the launcher's APP_IT_SMOKE seam to
# verify the real bundle path without WebKit, then asks desktop-doctor for stable
# ownership and drift checks.

set -uo pipefail

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

OK_N=0; WARN_N=0; FAIL_N=0; INFO_N=0; MANUAL_N=0; SKIP_N=0
JSON_MODE=0; STRICT_MODE=0; DO_BUILD=0; DO_INSTALL=0; DO_CLEANUP=0
CURRENT_SECTION="Metadata"
JSON_CHECKS_FILE=""

record_check() {
    [ -n "$JSON_CHECKS_FILE" ] || return 0
    printf '%s\t%s\t%s\n' "$CURRENT_SECTION" "$1" "$2" >> "$JSON_CHECKS_FILE"
}

emit_line() {
    local status="$1" label="$2" color="$3" message="$4"
    [ "$JSON_MODE" = "1" ] || printf '  %s[%s]%s  %s\n' "$color" "$label" "$C_OFF" "$message"
    record_check "$status" "$message"
}

ok()     { OK_N=$((OK_N+1));         emit_line ok     " ok " "$C_OK"   "$1"; }
warn()   { WARN_N=$((WARN_N+1));     emit_line warn   "warn" "$C_WARN" "$1"; }
fail()   { FAIL_N=$((FAIL_N+1));     emit_line fail   "fail" "$C_FAIL" "$1"; }
info()   { INFO_N=$((INFO_N+1));     emit_line info   "info" "$C_INFO" "$1"; }
manual() { MANUAL_N=$((MANUAL_N+1)); emit_line manual "manual" "$C_DIM" "$1"; }
skip()   { SKIP_N=$((SKIP_N+1));     emit_line skip   "skip" "$C_DIM" "$1"; }

section() {
    CURRENT_SECTION="$1"
    [ "$JSON_MODE" = "1" ] || printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_OFF"
}

usage() {
    cat <<'EOF'
app-it verify - behavior-first check for one generated launcher.

  ./scripts/desktop-verify.sh [slug-or-name]          headless smoke + doctor summary
  ./scripts/desktop-verify.sh --json [slug-or-name]   emit machine-readable summary
  ./scripts/desktop-verify.sh --build                 run desktop-build.sh first
  ./scripts/desktop-verify.sh --install               run desktop-install.sh first
  ./scripts/desktop-verify.sh --cleanup               stop app-it-owned runtime state at the end
  ./scripts/desktop-verify.sh --strict                exit non-zero on warnings/failures
  ./scripts/desktop-verify.sh --help

Headless verify uses APP_IT_SMOKE=1 on the built or installed bundle. It does
not claim window content, Dock icon identity, red-X, or Cmd+Q unless a visible
macOS session actually runs those checks.
EOF
}

json_error() {
    /usr/bin/python3 - "$1" "${2:-2}" <<'PY'
import json, sys
print(json.dumps({
    "schema_version": 1,
    "tool": "app-it.desktop-verify",
    "status": "fail",
    "error": {"message": sys.argv[1], "exit_code": int(sys.argv[2])},
}, ensure_ascii=False, indent=2))
PY
}

die() {
    if [ "$JSON_MODE" = "1" ]; then json_error "$1" "${2:-2}"
    else printf '%sdesktop-verify: %s%s\n' "$C_FAIL" "$1" "$C_OFF" >&2
    fi
    exit "${2:-2}"
}

lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

run_capped() {
    local secs="$1" log="$2"; shift 2
    "$@" >"$log" 2>&1 &
    local pid=$! waited=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
        if [ "$waited" -ge "$secs" ]; then
            kill -TERM "$pid" 2>/dev/null || true
            break
        fi
    done
    local rc=0
    wait "$pid" 2>/dev/null || rc=$?
    return "$rc"
}

# --- Parse args --------------------------------------------------------------
SELECTOR=""
for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;;
        --json) JSON_MODE=1 ;;
        --strict) STRICT_MODE=1 ;;
        --build) DO_BUILD=1 ;;
        --install) DO_INSTALL=1 ;;
        --cleanup) DO_CLEANUP=1 ;;
        --*) usage >&2; die "unknown flag: $arg" ;;
        *) [ -z "$SELECTOR" ] && SELECTOR="$arg" || die "unexpected extra argument: $arg" ;;
    esac
done

JSON_CHECKS_FILE="$(mktemp "${TMPDIR:-/tmp}/app-it-verify-checks.XXXXXX")" || die "could not create JSON scratch file" 2
trap 'rm -f "$JSON_CHECKS_FILE"' EXIT

# --- Load apps from config ---------------------------------------------------
[ -f "$CONFIG_FILE" ] || die "scripts/app-it.config.json not found. desktop:verify reads it to know which launcher to verify." 2

APPS=()
while IFS= read -r line; do
    [ -n "$line" ] && APPS+=("$line")
done < <(/usr/bin/python3 - "$CONFIG_FILE" <<'PY'
import json, re, sys
try:
    cfg = json.load(open(sys.argv[1]))
except Exception as e:
    sys.stderr.write(f"could not parse app-it.config.json: {e}\n")
    sys.exit(3)
for a in cfg.get("apps", []):
    name = a.get("name", "")
    slug = a.get("slug") or re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    fields = [
        name, slug, str(a.get("port", "")), a.get("port_mode", "fallback"),
        a.get("start_command", ""),
        a.get("bundle_id", ""), a.get("version", "0.1.0"), a.get("polyfill_path", ""),
        str(a.get("backend_port") or ""), a.get("backend_start_command") or "",
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

SELECTED=""
if [ -n "$SELECTOR" ]; then
    sel="$(lc "$SELECTOR")"
    for entry in "${APPS[@]}"; do
        IFS='|' read -r n s _ <<<"$entry"
        if [ "$(lc "$s")" = "$sel" ] || [ "$(lc "$n")" = "$sel" ]; then SELECTED="$entry"; break; fi
    done
    [ -n "$SELECTED" ] || die "no app named \"$SELECTOR\" in scripts/app-it.config.json" 2
else
    SELECTED="${APPS[0]}"
fi

IFS='|' read -r APP_NAME APP_SLUG PORT PORT_MODE START_COMMAND BUNDLE_ID VERSION POLYFILL_PATH BACKEND_PORT BACKEND_START <<<"$SELECTED"

STATE_DIR="$HOME/Library/Application Support/app-it/$APP_SLUG"
LOG_DIR="$HOME/Library/Logs/app-it/$APP_SLUG"
PID_FILE="$STATE_DIR/server.pid";    PORT_FILE="$STATE_DIR/server.port"
BPID_FILE="$STATE_DIR/backend.pid";  BPORT_FILE="$STATE_DIR/backend.port"
RUNTIME_SUMMARY_FILE="$STATE_DIR/runtime.json"
INSTALL_APP="$INSTALL_DIR/$APP_NAME.app"
BUILD_APP="$ROOT/desktop/$APP_NAME.app"
VERIFY_DIR="$LOG_DIR/verify"
mkdir -p "$VERIFY_DIR"
BUILD_LOG="$VERIFY_DIR/build.log"
INSTALL_LOG="$VERIFY_DIR/install.log"
SMOKE_LOG="$VERIFY_DIR/smoke.log"
DOCTOR_JSON="$VERIFY_DIR/doctor.json"
DOCTOR_ERR="$VERIFY_DIR/doctor.err"

if [ "$JSON_MODE" = "0" ]; then
    printf '%sapp-it verify%s - %s%s%s\n' "$C_BOLD" "$C_OFF" "$C_BOLD" "$APP_NAME" "$C_OFF"
    printf '  %sslug%s        %s\n' "$C_DIM" "$C_OFF" "$APP_SLUG"
    printf '  %sport mode%s   %s\n' "$C_DIM" "$C_OFF" "$PORT_MODE"
    printf '  %sproject%s     %s\n' "$C_DIM" "$C_OFF" "$ROOT"
fi

# =============================================================================
section "Build and install"
if [ "$DO_BUILD" = "1" ]; then
    if [ -x "$SCRIPT_DIR/desktop-build.sh" ]; then
        if run_capped 180 "$BUILD_LOG" env APP_IT_PROJECT_ROOT="$ROOT" "$SCRIPT_DIR/desktop-build.sh"; then
            ok "desktop-build.sh completed"
        else
            fail "desktop-build.sh failed; see $BUILD_LOG"
        fi
    else
        fail "scripts/desktop-build.sh is missing or not executable"
    fi
else
    skip "desktop-build.sh not run (use --build to rebuild before verify)"
fi

if [ -d "$BUILD_APP" ]; then
    ok "build bundle exists at $BUILD_APP"
else
    fail "build bundle missing at $BUILD_APP"
fi

if [ "$DO_INSTALL" = "1" ]; then
    if [ -x "$SCRIPT_DIR/desktop-install.sh" ]; then
        if run_capped 180 "$INSTALL_LOG" env APP_IT_PROJECT_ROOT="$ROOT" "$SCRIPT_DIR/desktop-install.sh"; then
            ok "desktop-install.sh completed"
        else
            fail "desktop-install.sh failed; see $INSTALL_LOG"
        fi
    else
        fail "scripts/desktop-install.sh is missing or not executable"
    fi
else
    skip "desktop-install.sh not run (use --install to refresh the installed app first)"
fi

if [ -d "$INSTALL_APP" ]; then
    ok "installed bundle exists at $INSTALL_APP"
    APP_UNDER_TEST="$INSTALL_APP"
    APP_LOC="installed"
elif [ -d "$BUILD_APP" ]; then
    warn "installed bundle missing; verifying build copy at $BUILD_APP"
    APP_UNDER_TEST="$BUILD_APP"
    APP_LOC="build"
else
    fail "no bundle available to run"
    APP_UNDER_TEST=""
    APP_LOC="none"
fi

# =============================================================================
section "Runtime smoke"
RUNTIME_PORT=""
BACKEND_RUNTIME_PORT=""
BACKEND_PID=""
BACKEND_PID_ALIVE=0
RUNTIME_SUMMARY_PRESENT=0
SMOKE_RC=""
case "$PORT_MODE" in
    fallback) ok "port mode: fallback (scan upward if the preferred port is busy)" ;;
    fixed)    ok "port mode: fixed (requires exactly :$PORT; no collision fallback)" ;;
    *)        fail "port_mode '$PORT_MODE' is invalid — expected fallback or fixed" ;;
esac
if [ -n "$APP_UNDER_TEST" ]; then
    RUN="$APP_UNDER_TEST/Contents/MacOS/run"
    if [ -x "$RUN" ]; then
        if run_capped 90 "$SMOKE_LOG" env APP_IT_SMOKE=1 "$RUN"; then
            ok "bundle runs through APP_IT_SMOKE without opening a GUI"
            SMOKE_RC=0
        else
            SMOKE_RC=$?
            fail "APP_IT_SMOKE run failed; see $SMOKE_LOG"
        fi
    else
        fail "bundle run executable missing at $RUN"
    fi
else
    skip "runtime smoke skipped because no bundle was available"
fi

[ -f "$PORT_FILE" ] && RUNTIME_PORT="$(cat "$PORT_FILE" 2>/dev/null || true)"
if [ -n "$RUNTIME_PORT" ]; then
    ok "frontend runtime port recorded (:$RUNTIME_PORT; preferred :$PORT)"
    if [ "$PORT_MODE" = "fixed" ]; then
        if [ "$RUNTIME_PORT" = "$PORT" ]; then
            ok "fixed-port runtime is using required frontend port :$RUNTIME_PORT"
        else
            fail "fixed-port mode is configured for :$PORT, but runtime state says :$RUNTIME_PORT"
        fi
    elif [ "$RUNTIME_PORT" != "$PORT" ]; then
        info "frontend runtime fell back from preferred :$PORT to :$RUNTIME_PORT"
    else
        ok "frontend runtime port matches preferred frontend port :$PORT"
    fi
    code="$(curl -sS -o /dev/null --max-time 2 -w "%{http_code}" "http://localhost:$RUNTIME_PORT" 2>/dev/null || true)"
    if [ -n "$code" ] && [ "$code" != "000" ]; then
        ok "server responds on http://localhost:$RUNTIME_PORT (HTTP $code)"
    else
        fail "server did not answer HTTP on recorded runtime port :$RUNTIME_PORT"
    fi
else
    [ -n "$APP_UNDER_TEST" ] && fail "runtime port was not recorded at $PORT_FILE"
fi

if [ -f "$RUNTIME_SUMMARY_FILE" ]; then
    RUNTIME_SUMMARY_PRESENT=1
    info "runtime summary recorded at $RUNTIME_SUMMARY_FILE"
fi

if [ -n "$BACKEND_PORT" ]; then
    [ -f "$BPORT_FILE" ] && BACKEND_RUNTIME_PORT="$(cat "$BPORT_FILE" 2>/dev/null || true)"
    [ -f "$BPID_FILE" ] && BACKEND_PID="$(cat "$BPID_FILE" 2>/dev/null || true)"
    if [ -n "$BACKEND_PID" ] && kill -0 "$BACKEND_PID" 2>/dev/null; then
        BACKEND_PID_ALIVE=1
    fi
    if [ -n "$BACKEND_RUNTIME_PORT" ]; then
        if [ "$BACKEND_RUNTIME_PORT" = "$BACKEND_PORT" ]; then
            ok "backend runtime port :$BACKEND_RUNTIME_PORT matches preferred backend port"
        else
            info "backend runtime fell back from preferred :$BACKEND_PORT to :$BACKEND_RUNTIME_PORT"
        fi
        if [ "$BACKEND_PID_ALIVE" = "1" ]; then
            ok "backend supervisor PID $BACKEND_PID is alive"
        fi
        if lsof -ti tcp:"$BACKEND_RUNTIME_PORT" >/dev/null 2>&1; then
            ok "backend runtime port :$BACKEND_RUNTIME_PORT is listening (preferred :$BACKEND_PORT)"
        elif [ "$BACKEND_PID_ALIVE" = "1" ]; then
            warn "backend supervisor PID $BACKEND_PID is alive but backend is not listening yet on :$BACKEND_RUNTIME_PORT"
        else
            warn "backend runtime port not confirmed (:${BACKEND_RUNTIME_PORT}; preferred :$BACKEND_PORT)"
        fi
    elif [ "$BACKEND_PID_ALIVE" = "1" ]; then
        warn "backend supervisor PID $BACKEND_PID is alive but no backend.port was recorded"
    else
        warn "backend runtime port not confirmed (preferred :$BACKEND_PORT)"
    fi
fi

# =============================================================================
section "Doctor"
DOCTOR_OK=""; DOCTOR_WARN=""; DOCTOR_FAIL=""; DOCTOR_INFO=""; DOCTOR_ACTION=""
if [ -x "$SCRIPT_DIR/desktop-doctor.sh" ]; then
    if env APP_IT_PROJECT_ROOT="$ROOT" "$SCRIPT_DIR/desktop-doctor.sh" --json "$APP_SLUG" >"$DOCTOR_JSON" 2>"$DOCTOR_ERR"; then
        DOCTOR_SUMMARY="$(/usr/bin/python3 - "$DOCTOR_JSON" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1]))
counts = payload.get("counts", {})
print("|".join([
    str(counts.get("ok", 0)),
    str(counts.get("warn", 0)),
    str(counts.get("fail", 0)),
    str(counts.get("info", 0)),
    str(payload.get("recommended_action", "")),
]))
PY
)" || DOCTOR_SUMMARY=""
        if [ -n "$DOCTOR_SUMMARY" ]; then
            IFS='|' read -r DOCTOR_OK DOCTOR_WARN DOCTOR_FAIL DOCTOR_INFO DOCTOR_ACTION <<<"$DOCTOR_SUMMARY"
            if [ "${DOCTOR_FAIL:-0}" -gt 0 ]; then
                fail "desktop-doctor found $DOCTOR_FAIL failure(s); see $DOCTOR_JSON"
            elif [ "${DOCTOR_WARN:-0}" -gt 0 ]; then
                warn "desktop-doctor found $DOCTOR_WARN warning(s); see $DOCTOR_JSON"
            else
                ok "desktop-doctor passed with no warnings or failures"
            fi
        else
            fail "desktop-doctor JSON could not be parsed; see $DOCTOR_JSON"
        fi
    else
        fail "desktop-doctor --json failed; see $DOCTOR_ERR"
    fi
else
    fail "scripts/desktop-doctor.sh is missing or not executable"
fi

# =============================================================================
section "GUI checks"
manual "window content and Dock icon identity require a visible macOS session"
manual "red-X warm-window behavior is not exercised headlessly; APP_IT_SMOKE verifies the warm server path"
manual "Cmd+Q cleanup must be tested through Apple Events in a GUI-capable session"

# =============================================================================
section "Cleanup"
CLEANUP_LOG="$VERIFY_DIR/cleanup.log"
if [ "$DO_CLEANUP" = "1" ]; then
    if [ -x "$SCRIPT_DIR/desktop-quit.sh" ]; then
        env APP_IT_PROJECT_ROOT="$ROOT" "$SCRIPT_DIR/desktop-quit.sh" >"$CLEANUP_LOG" 2>&1 || true
        sleep 1
        still=""
        [ -n "$RUNTIME_PORT" ] && [ -n "$(lsof -ti tcp:"$RUNTIME_PORT" 2>/dev/null || true)" ] && still="$still :$RUNTIME_PORT"
        [ -n "$BACKEND_RUNTIME_PORT" ] && [ -n "$(lsof -ti tcp:"$BACKEND_RUNTIME_PORT" 2>/dev/null || true)" ] && still="$still :$BACKEND_RUNTIME_PORT"
        if [ -z "$still" ]; then ok "desktop-quit.sh freed app-it-owned runtime ports"
        else fail "ports still held after desktop-quit.sh:$still"; fi
    else
        fail "scripts/desktop-quit.sh is missing or not executable"
    fi
else
    skip "cleanup not requested; warm server state is left running by design"
fi

if [ "$FAIL_N" -gt 0 ]; then VERIFY_STATUS="fail"
elif [ "$WARN_N" -gt 0 ]; then VERIFY_STATUS="warn"
else VERIFY_STATUS="pass"
fi

if [ "$JSON_MODE" = "1" ]; then
    VERIFY_APP_NAME="$APP_NAME" \
    VERIFY_APP_SLUG="$APP_SLUG" \
    VERIFY_BUNDLE_ID="$BUNDLE_ID" \
    VERIFY_VERSION="$VERSION" \
    VERIFY_MANIFEST_SCHEMA="$CFG_SCHEMA_VERSION" \
    VERIFY_MANIFEST_GENERATOR="$CFG_GENERATOR_VERSION" \
    VERIFY_MANIFEST_TEMPLATE="$CFG_TEMPLATE_VERSION" \
    VERIFY_PROJECT_ROOT="$ROOT" \
    VERIFY_STATUS="$VERIFY_STATUS" \
    VERIFY_SUBJECT="$APP_UNDER_TEST" \
    VERIFY_SUBJECT_LOCATION="$APP_LOC" \
    VERIFY_INSTALL_APP="$INSTALL_APP" \
    VERIFY_BUILD_APP="$BUILD_APP" \
    VERIFY_PREFERRED_PORT="$PORT" \
    VERIFY_PORT_MODE="$PORT_MODE" \
    VERIFY_RUNTIME_PORT="$RUNTIME_PORT" \
    VERIFY_BACKEND_PREFERRED_PORT="$BACKEND_PORT" \
    VERIFY_BACKEND_RUNTIME_PORT="$BACKEND_RUNTIME_PORT" \
    VERIFY_BACKEND_PID="$BACKEND_PID" \
    VERIFY_BACKEND_PID_ALIVE="$BACKEND_PID_ALIVE" \
    VERIFY_RUNTIME_SUMMARY="$RUNTIME_SUMMARY_FILE" \
    VERIFY_RUNTIME_SUMMARY_PRESENT="$RUNTIME_SUMMARY_PRESENT" \
    VERIFY_BUILD_LOG="$BUILD_LOG" \
    VERIFY_INSTALL_LOG="$INSTALL_LOG" \
    VERIFY_SMOKE_LOG="$SMOKE_LOG" \
    VERIFY_DOCTOR_JSON="$DOCTOR_JSON" \
    VERIFY_DOCTOR_OK="$DOCTOR_OK" \
    VERIFY_DOCTOR_WARN="$DOCTOR_WARN" \
    VERIFY_DOCTOR_FAIL="$DOCTOR_FAIL" \
    VERIFY_DOCTOR_INFO="$DOCTOR_INFO" \
    VERIFY_DOCTOR_ACTION="$DOCTOR_ACTION" \
    VERIFY_OK_N="$OK_N" \
    VERIFY_WARN_N="$WARN_N" \
    VERIFY_FAIL_N="$FAIL_N" \
    VERIFY_INFO_N="$INFO_N" \
    VERIFY_MANUAL_N="$MANUAL_N" \
    VERIFY_SKIP_N="$SKIP_N" \
    /usr/bin/python3 - "$JSON_CHECKS_FILE" <<'PY'
import json
import os
import sys

def empty_to_none(value):
    return value if value else None

def manifest_schema_version():
    raw = os.environ.get("VERIFY_MANIFEST_SCHEMA", "")
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
        checks.append({"section": section, "status": status, "message": message})

payload = {
    "schema_version": 1,
    "tool": "app-it.desktop-verify",
    "status": os.environ["VERIFY_STATUS"],
    "manifest": {
        "schema_version": manifest_schema_version(),
        "generator_version": empty_to_none(os.environ["VERIFY_MANIFEST_GENERATOR"]),
        "template_version": empty_to_none(os.environ["VERIFY_MANIFEST_TEMPLATE"]),
    },
    "app": {
        "name": os.environ["VERIFY_APP_NAME"],
        "slug": os.environ["VERIFY_APP_SLUG"],
        "bundle_id": empty_to_none(os.environ["VERIFY_BUNDLE_ID"]),
        "version": empty_to_none(os.environ["VERIFY_VERSION"]),
    },
    "project": {"root": os.environ["VERIFY_PROJECT_ROOT"]},
    "subject": {
        "path": empty_to_none(os.environ["VERIFY_SUBJECT"]),
        "location": os.environ["VERIFY_SUBJECT_LOCATION"],
        "installed_path": os.environ["VERIFY_INSTALL_APP"],
        "build_path": os.environ["VERIFY_BUILD_APP"],
    },
    "ports": {
        "mode": os.environ["VERIFY_PORT_MODE"],
        "preferred": empty_to_none(os.environ["VERIFY_PREFERRED_PORT"]),
        "runtime": empty_to_none(os.environ["VERIFY_RUNTIME_PORT"]),
        "backend_preferred": empty_to_none(os.environ["VERIFY_BACKEND_PREFERRED_PORT"]),
        "backend_runtime": empty_to_none(os.environ["VERIFY_BACKEND_RUNTIME_PORT"]),
    },
    "counts": {
        "ok": int(os.environ["VERIFY_OK_N"]),
        "warn": int(os.environ["VERIFY_WARN_N"]),
        "fail": int(os.environ["VERIFY_FAIL_N"]),
        "info": int(os.environ["VERIFY_INFO_N"]),
        "manual": int(os.environ["VERIFY_MANUAL_N"]),
        "skip": int(os.environ["VERIFY_SKIP_N"]),
    },
    "checks": checks,
    "artifacts": {
        "build_log": os.environ["VERIFY_BUILD_LOG"],
        "install_log": os.environ["VERIFY_INSTALL_LOG"],
        "smoke_log": os.environ["VERIFY_SMOKE_LOG"],
        "doctor_json": os.environ["VERIFY_DOCTOR_JSON"],
        "runtime_summary": os.environ["VERIFY_RUNTIME_SUMMARY"],
        "runtime_summary_present": os.environ["VERIFY_RUNTIME_SUMMARY_PRESENT"] == "1",
    },
    "state": {
        "backend_pid": empty_to_none(os.environ["VERIFY_BACKEND_PID"]),
        "backend_pid_alive": os.environ["VERIFY_BACKEND_PID_ALIVE"] == "1",
    },
    "doctor": {
        "counts": {
            "ok": int(os.environ["VERIFY_DOCTOR_OK"] or 0),
            "warn": int(os.environ["VERIFY_DOCTOR_WARN"] or 0),
            "fail": int(os.environ["VERIFY_DOCTOR_FAIL"] or 0),
            "info": int(os.environ["VERIFY_DOCTOR_INFO"] or 0),
        },
        "recommended_action": empty_to_none(os.environ["VERIFY_DOCTOR_ACTION"]),
    },
}
json.dump(payload, sys.stdout, ensure_ascii=False, indent=2)
sys.stdout.write("\n")
PY
else
    section "Summary"
    printf '  status: %s\n' "$VERIFY_STATUS"
    printf '  %s%d ok%s * %s%d warn%s * %s%d fail%s * %d manual * %d skip * %d info\n' \
        "$C_OK" "$OK_N" "$C_OFF" "$C_WARN" "$WARN_N" "$C_OFF" "$C_FAIL" "$FAIL_N" "$C_OFF" "$MANUAL_N" "$SKIP_N" "$INFO_N"
    [ -n "$RUNTIME_PORT" ] && printf '  runtime: http://localhost:%s\n' "$RUNTIME_PORT"
    [ -n "$BACKEND_RUNTIME_PORT" ] && printf '  backend: http://localhost:%s\n' "$BACKEND_RUNTIME_PORT"
fi

if [ "$FAIL_N" -gt 0 ]; then
    exit 1
fi
if [ "$STRICT_MODE" = "1" ] && [ "$WARN_N" -gt 0 ]; then
    exit 1
fi
exit 0
