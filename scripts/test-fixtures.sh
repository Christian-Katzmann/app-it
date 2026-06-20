#!/usr/bin/env bash
# Behavioral fixture suite for app-it.
#
# validate.sh is the fast, portable, STATIC gate (lint, syntax, plist, manifests).
# THIS script is the BEHAVIORAL gate: it drives app-it's real scripts against the
# project shapes under scripts/fixtures/ and asserts the headless-automatable rows
# of SKILL.md's Phase-4 verification checklist — build, bundle metadata, no
# placeholder leak, runtime port, server responding, "server belongs to the
# launcher" — then tears everything down. The GUI rows (window content, Dock
# icon, Cmd+Q/red-X, lsregister) stay in the manual release smoke.
#
# Safety: everything runs under a sandboxed HOME and a throwaway temp tree, so the
# real ~/Applications/App It and ~/Library/.../app-it state is never touched. A
# trap tears down servers and the temp tree even on failure.
#
# Usage:
#   ./scripts/test-fixtures.sh              # hermetic suite (no network, no installs)
#   APP_IT_RUN_REAL=1 ./scripts/test-fixtures.sh   # also run the real-Vite lane
#
# macOS only (compiles the Swift wrapper, uses sips/iconutil/plutil/codesign).

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$REPO/scripts/fixtures"
ARCH="$(uname -m)"                       # build the host arch only — faster, no x86_64 SDK flakiness
# Fixture port range, far from common dev ports. PORT_HI covers the highest
# fixture's full [preferred..preferred+50] launcher scan window, so the cleanup
# sweep below can always reach a server that fell back to a higher port.
PORT_LO=41000; PORT_HI=41199

# --- Sandbox: never touch the user's real launcher state ---------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/app-it-fixtures.XXXXXX")"
export HOME="$WORK/home"; mkdir -p "$HOME"
EXTRA_CLEANUP_PIDS=""

cleanup() {
    [ -n "$EXTRA_CLEANUP_PIDS" ] && kill -TERM $EXTRA_CLEANUP_PIDS 2>/dev/null || true
    # Stop anything still bound in the fixture port range (belt-and-suspenders;
    # each fixture also runs desktop:quit inline as part of its test). One ranged
    # lsof covers the whole window in a single call.
    local pids
    pids="$(lsof -ti tcp:"$PORT_LO"-"$PORT_HI" 2>/dev/null || true)"
    [ -n "$pids" ] && kill -TERM $pids 2>/dev/null || true
    rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

assert_fixture_ports_clear() {
    local pids
    pids="$(lsof -ti tcp:"$PORT_LO"-"$PORT_HI" 2>/dev/null || true)"
    if [ -z "$pids" ]; then
        ok "no fixture ports remain bound ($PORT_LO-$PORT_HI)"
    else
        bad "fixture ports still have listeners: $pids"
        lsof -nP -i tcp:"$PORT_LO"-"$PORT_HI" 2>/dev/null | sed 's/^/       /' || true
    fi
}

# --- Output vocabulary -------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; D=$'\033[2m'; O=$'\033[0m'
else G=""; R=""; Y=""; B=""; D=""; O=""; fi
PASS=0; FAIL=0
ok()      { printf '  %sok%s   %s\n'   "$G" "$O" "$1"; PASS=$((PASS+1)); }
bad()     { printf '  %sFAIL%s %s\n'   "$R" "$O" "$1"; FAIL=$((FAIL+1)); }
section() { printf '\n%s== %s ==%s\n'  "$B" "$1" "$O"; }
note()    { printf '       %s%s%s\n'   "$D" "$1" "$O"; }

# haystack/needle assertions (line-based; needles are single-line)
has()    { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1 — missing: $3"; fi; }
has_re() { if grep -qE -- "$3" <<<"$2"; then ok "$1"; else bad "$1 — no match: $3"; fi; }
lacks()  { if grep -qF -- "$3" <<<"$2"; then bad "$1 — unexpected: $3"; else ok "$1"; fi; }
is_file(){ if [ -f "$2" ]; then ok "$1"; else bad "$1 — no file: $2"; fi; }
no_path(){ if [ -e "$2" ]; then bad "$1 — exists: $2"; else ok "$1"; fi; }

# Unresolved-placeholder regex, assembled in pieces so validate.sh's own
# literal-placeholder grep over scripts/ does not false-trip on this file.
PH_RE="__[A-Z_]$(printf '%s' '+__')"

# --- Per-fixture setup: assemble a throwaway project, as a user would ---------
# setup_proj <fixture-dir> <plugin> <slug>  → sets global PROJ
setup_proj() {
    local name="$1" plugin="$2" slug="$3"
    PROJ="$WORK/proj-$name"
    rm -rf "$PROJ"; mkdir -p "$PROJ/scripts" "$PROJ/assets"
    cp -R "$FIX/$name/." "$PROJ/"                                   # the project shape
    cp -R "$REPO/plugins/$plugin/skills/$plugin/templates/." "$PROJ/scripts/"  # real templates
    mv "$PROJ/app-it.config.json" "$PROJ/scripts/app-it.config.json"           # config lives in scripts/
    cp "$REPO/scripts/lib/"*.js "$PROJ/"                                       # $PORT-honoring stand-ins (incl. nested)
    cp "$FIX/_shared/icon.png" "$PROJ/assets/$slug-icon.png"                   # icon round-trip source
}

# desktop-build.sh in the project, host-arch wrapper, captured to build.log.
build() {  # build <extra-env...>
    local proj="$PROJ"
    if ( cd "$proj" && env APP_IT_PROJECT_ROOT="$proj" APP_IT_SWIFT_ARCHS="$ARCH" "$@" \
            bash scripts/desktop-build.sh ) >"$proj/build.log" 2>&1; then
        ok "desktop-build.sh succeeded"
    else
        bad "desktop-build.sh failed"; sed 's/^/       /' "$proj/build.log"
    fi
}

# Run a command with a wall-clock cap (macOS has no coreutils `timeout`).
# Poll-based, NOT a background sleep watchdog: a backgrounded `sleep` can be
# orphaned if the child exits before the watchdog forks it, leaving a stray
# process. Here every `sleep 1` is a foreground child, fully reaped each tick.
run_capped() {  # run_capped <secs> <logfile> <cmd...>
    local secs="$1" log="$2"; shift 2
    "$@" >"$log" 2>&1 &
    local pid=$! waited=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1; waited=$((waited + 1))
        if [ "$waited" -ge "$secs" ]; then kill -TERM "$pid" 2>/dev/null; break; fi
    done
    local rc=0; wait "$pid" 2>/dev/null || rc=$?
    return "$rc"
}

state_dir() { printf '%s/Library/Application Support/app-it/%s' "$HOME" "$1"; }

# Does a listener on <port> belong to <supervisor-pid>'s descendant tree?
# This is an INDEPENDENT ownership oracle, so it must walk correctly: macOS
# `pgrep -P` rejects a space-joined / trailing-space argument, so we expand each
# generation one pid at a time (feeding pgrep a single clean pid). Walks up to
# 4 generations (e.g. bash → npm → node-vite → esbuild).
listener_owned_by() {  # listener_owned_by <pid> <port>
    local sup="$1" port="$2" listeners desc cur gen pid p kids
    listeners="$(lsof -ti tcp:"$port" 2>/dev/null || true)"
    [ -z "$listeners" ] && return 1
    desc="$sup"; cur="$sup"
    for _ in 1 2 3 4; do
        gen=""
        for p in $cur; do
            kids="$(pgrep -P "$p" 2>/dev/null || true)"
            [ -n "$kids" ] && gen="$gen $kids"
        done
        [ -z "$gen" ] && break
        desc="$desc $gen"; cur="$gen"
    done
    for pid in $listeners; do case " $desc " in *" $pid "*) return 0 ;; esac; done
    return 1
}

# Launch the built bundle in the headless smoke seam; assert server up + owned.
# Echoes the chosen runtime port on success.
seam_up() {  # seam_up <app-name> <slug> ; sets RUNTIME_PORT
    local app="$1" slug="$2" sd port pid
    sd="$(state_dir "$slug")"
    # `env APP_IT_SMOKE=1 …` (not a bare prefix) so the var is exported to the
    # launcher's child processes, not just set in this function's scope.
    if run_capped 60 "$PROJ/seam.log" \
            env APP_IT_SMOKE=1 "$PROJ/desktop/$app.app/Contents/MacOS/run"; then
        ok "launcher ran in smoke mode (server up, no GUI)"
    else
        bad "launcher smoke run failed"; sed 's/^/       /' "$PROJ/seam.log"; RUNTIME_PORT=""; return
    fi
    port="$(cat "$sd/server.port" 2>/dev/null || true)"
    pid="$(cat "$sd/server.pid" 2>/dev/null || true)"
    RUNTIME_PORT="$port"
    if [ -n "$port" ]; then ok "runtime port recorded (:$port)"; else bad "no server.port recorded"; return; fi
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then ok "supervisor pid $pid is alive"; else bad "supervisor pid dead/missing"; fi
    if listener_owned_by "$pid" "$port"; then ok "server on :$port belongs to this launcher"; else bad "server on :$port not in launcher's process tree"; fi
    local code; code="$(curl -sS -o /dev/null --max-time 2 -w '%{http_code}' "http://localhost:$port" 2>/dev/null || true)"
    if [ -n "$code" ] && [ "$code" != "000" ]; then ok "server responds (HTTP $code)"; else bad "server not responding on :$port"; fi
}

quit_clean() {  # quit_clean <slug> <port> [more-ports...]
    local slug="$1"; shift
    APP_IT_PROJECT_ROOT="$PROJ" bash "$PROJ/scripts/desktop-quit.sh" >"$PROJ/quit.log" 2>&1 || true
    lacks "desktop-quit.sh emits no killed-job noise" "$(cat "$PROJ/quit.log" 2>/dev/null || true)" "Killed:"
    sleep 1
    local p still=""
    for p in "$@"; do [ -n "$(lsof -ti tcp:"$p" 2>/dev/null || true)" ] && still="$still $p"; done
    if [ -z "$still" ]; then ok "desktop-quit.sh freed all ports ($*)"; else bad "ports still held after quit:$still"; fi

    APP_IT_PROJECT_ROOT="$PROJ" bash "$PROJ/scripts/desktop-quit.sh" >"$PROJ/quit-already-clean.log" 2>&1 || true
    has "desktop-quit.sh reports already clean on repeat quit" "$(cat "$PROJ/quit-already-clean.log" 2>/dev/null || true)" "Already clean"
    lacks "repeat desktop-quit.sh emits no killed-job noise" "$(cat "$PROJ/quit-already-clean.log" 2>/dev/null || true)" "Killed:"
}

# A 2nd smoke launch must REATTACH to the warm server (same pid + port), not
# cold-start a duplicate. The 2nd run must actually succeed first — otherwise a
# crashed run would leave the recorded pid/port unchanged and read back equal,
# falsely reporting a reattach that never happened.
warm_reattach() {  # warm_reattach <app> <slug> <first-pid> <first-port>
    local app="$1" slug="$2" p1="$3" port1="$4" sd p2 port2
    sd="$(state_dir "$slug")"
    if ! run_capped 60 "$PROJ/seam2.log" env APP_IT_SMOKE=1 "$PROJ/desktop/$app.app/Contents/MacOS/run"; then
        bad "warm re-launch failed to run"; sed 's/^/       /' "$PROJ/seam2.log"; return
    fi
    p2="$(cat "$sd/server.pid" 2>/dev/null || true)"
    port2="$(cat "$sd/server.port" 2>/dev/null || true)"
    if [ -n "$p1" ] && [ "$p1" = "$p2" ] && [ "$port1" = "$port2" ]; then
        ok "warm re-launch reattached to the same server (pid $p1, :$port1)"
    else
        bad "warm re-launch did NOT reattach (pid $p1→$p2, port $port1→$port2) — descendant walk stops too early"
    fi
}

# Assert a freshly built bundle's structure (SKILL.md rows 1–2). $1=app $2=slug $3=bundle-id $4=swift|chrome
assert_bundle() {
    local app="$1" slug="$2" bid="$3" mode="$4"
    local appdir="$PROJ/desktop/$app.app" plist="$PROJ/desktop/$app.app/Contents/Info.plist"
    local run="$appdir/Contents/MacOS/run" run_sh="$appdir/Contents/MacOS/run.sh" wrap="$appdir/Contents/MacOS/wrapper" icns="$appdir/Contents/Resources/AppIcon.icns"
    is_file "$app.app exists" "$appdir/Contents/Info.plist"
    is_file "native run stub present (MacOS/run)" "$run"
    if [ -f "$run" ] && file "$run" 2>/dev/null | grep -q 'Mach-O'; then ok "CFBundleExecutable run is a Mach-O executable"; else bad "CFBundleExecutable run missing/not Mach-O"; fi
    is_file "launcher script present (MacOS/run.sh)" "$run_sh"
    if plutil -lint "$plist" >/dev/null 2>&1; then ok "Info.plist passes plutil -lint"; else bad "Info.plist fails plutil -lint"; fi
    local got; got="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$plist" 2>/dev/null || true)"
    if [ "$got" = "$bid" ]; then ok "Info.plist bundle id matches config ($got)"; else bad "bundle id '$got' != '$bid'"; fi
    if [ -f "$plist" ] && [ -f "$run_sh" ]; then
        if grep -Eq "$PH_RE" "$plist" "$run_sh"; then bad "unresolved placeholder leaked into built artifacts"; else ok "no placeholder leak in built artifacts"; fi
    else
        bad "cannot check placeholder leak — built plist/run.sh missing"
    fi
    if [ -f "$icns" ] && file "$icns" 2>/dev/null | grep -qi 'icon'; then ok "AppIcon.icns is a real icon file"; else bad "AppIcon.icns missing or not an icon"; fi
    if [ "$mode" = "swift" ]; then
        if [ -f "$wrap" ] && file "$wrap" 2>/dev/null | grep -q 'Mach-O'; then ok "Swift wrapper is a Mach-O executable"; else bad "Swift wrapper missing/not Mach-O"; fi
    else
        no_path "no Swift wrapper in chrome-fallback bundle" "$wrap"
        if grep -q -- '--app=' "$run_sh" 2>/dev/null; then ok "run.sh uses Chrome --app= launcher"; else bad "chrome run.sh missing --app="; fi
    fi
}

printf '%sapp-it behavioral fixture suite%s  (HOME sandboxed at %s)\n' "$B" "$O" "$HOME"
note "arch=$ARCH  ports=$PORT_LO-$PORT_HI  real-lane=${APP_IT_RUN_REAL:-0}"

# =============================================================================
section "vite-basic — Vite detection + full single-server launch lifecycle"
setup_proj vite-basic app-it vite-basic
INSPECT="$(APP_IT_PROJECT_ROOT="$PROJ" bash "$PROJ/scripts/inspect.sh" 2>&1 || true)"
has  "inspect detects vite.config.ts" "$INSPECT" "vite.config.ts"
has  "inspect lists the dev script"   "$INSPECT" "dev"
lacks "inspect emits no hardcoded-port warning" "$INSPECT" "hardcoded port literal"
build
assert_bundle "Vite Basic" vite-basic com.user.vite-basic swift
seam_up "Vite Basic" vite-basic
FIRST_PORT="$RUNTIME_PORT"
FIRST_PID="$(cat "$(state_dir vite-basic)/server.pid" 2>/dev/null || true)"
# desktop-doctor.sh — gives that (currently untested) script its first CI coverage.
APP_IT_PROJECT_ROOT="$PROJ" bash "$PROJ/scripts/desktop-doctor.sh" vite-basic >"$PROJ/doctor.log" 2>&1 || true
has "desktop-doctor confirms launcher owns the server" "$(cat "$PROJ/doctor.log")" "belongs to this launcher"
APP_IT_PROJECT_ROOT="$PROJ" bash "$PROJ/scripts/desktop-doctor.sh" --json vite-basic >"$PROJ/doctor.json" 2>"$PROJ/doctor-json.err" || true
if python3 - "$PROJ/doctor.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text())
assert payload["schema_version"] == 1
assert payload["tool"] == "app-it.desktop-doctor"
assert payload["app"]["slug"] == "vite-basic"
assert isinstance(payload["counts"]["ok"], int)
assert isinstance(payload["checks"], list) and payload["checks"]
assert any("belongs to this launcher" in row["message"] for row in payload["checks"])
PY
then
    ok "desktop-doctor --json emits parseable ownership checks"
else
    bad "desktop-doctor --json did not emit parseable ownership checks"
    sed 's/^/       /' "$PROJ/doctor.json" 2>/dev/null || true
    sed 's/^/       /' "$PROJ/doctor-json.err" 2>/dev/null || true
fi
APP_IT_PROJECT_ROOT="$PROJ" bash "$PROJ/scripts/desktop-verify.sh" --json vite-basic >"$PROJ/verify.json" 2>"$PROJ/verify-json.err" || true
if python3 - "$PROJ/verify.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text())
assert payload["schema_version"] == 1
assert payload["tool"] == "app-it.desktop-verify"
assert payload["app"]["slug"] == "vite-basic"
assert payload["ports"]["runtime"]
assert payload["doctor"]["counts"]["ok"] >= 1
assert any(row["section"] == "Runtime smoke" and row["status"] == "ok" for row in payload["checks"])
assert any(row["section"] == "GUI checks" and row["status"] == "manual" for row in payload["checks"])
PY
then
    ok "desktop-verify --json emits parseable headless runtime summary"
else
    bad "desktop-verify --json did not emit parseable headless runtime summary"
    sed 's/^/       /' "$PROJ/verify.json" 2>/dev/null || true
    sed 's/^/       /' "$PROJ/verify-json.err" 2>/dev/null || true
fi
warm_reattach "Vite Basic" vite-basic "$FIRST_PID" "$FIRST_PORT"
quit_clean vite-basic "$FIRST_PORT"

# =============================================================================
section "fixed-port — exact-origin launch + busy-port refusal"
setup_proj fixed-port app-it fixed-port
build
assert_bundle "Fixed Port" fixed-port com.user.fixed-port swift
seam_up "Fixed Port" fixed-port
if [ "$RUNTIME_PORT" = "41090" ]; then ok "fixed-port launch used the required origin (:41090)"; else bad "fixed-port launch used :$RUNTIME_PORT instead of :41090"; fi
APP_IT_PROJECT_ROOT="$PROJ" bash "$PROJ/scripts/desktop-doctor.sh" --json fixed-port >"$PROJ/doctor-fixed.json" 2>"$PROJ/doctor-fixed.err" || true
if python3 - "$PROJ/doctor-fixed.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text())
assert payload["ports"]["mode"] == "fixed"
assert payload["ports"]["preferred"] == "41090"
assert payload["ports"]["runtime"] == "41090"
assert any("fixed-port runtime" in row["message"] for row in payload["checks"])
PY
then
    ok "desktop-doctor --json reports fixed-port mode"
else
    bad "desktop-doctor --json did not report fixed-port mode"
    sed 's/^/       /' "$PROJ/doctor-fixed.json" 2>/dev/null || true
    sed 's/^/       /' "$PROJ/doctor-fixed.err" 2>/dev/null || true
fi
APP_IT_PROJECT_ROOT="$PROJ" bash "$PROJ/scripts/desktop-verify.sh" --json fixed-port >"$PROJ/verify-fixed.json" 2>"$PROJ/verify-fixed.err" || true
if python3 - "$PROJ/verify-fixed.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text())
assert payload["ports"]["mode"] == "fixed"
assert payload["ports"]["preferred"] == "41090"
assert payload["ports"]["runtime"] == "41090"
assert any("fixed-port runtime" in row["message"] for row in payload["checks"])
PY
then
    ok "desktop-verify --json reports fixed-port mode"
else
    bad "desktop-verify --json did not report fixed-port mode"
    sed 's/^/       /' "$PROJ/verify-fixed.json" 2>/dev/null || true
    sed 's/^/       /' "$PROJ/verify-fixed.err" 2>/dev/null || true
fi
quit_clean fixed-port "$RUNTIME_PORT"

PORT=41090 STUB_LABEL="fixed-port foreign listener" node "$PROJ/stub-server.js" >"$PROJ/fixed-foreign.log" 2>&1 &
FOREIGN_PID=$!
EXTRA_CLEANUP_PIDS="$EXTRA_CLEANUP_PIDS $FOREIGN_PID"
FOREIGN_READY=0
for _ in $(seq 1 40); do
    if lsof -i tcp:41090 >/dev/null 2>&1; then
        FOREIGN_READY=1
        break
    fi
    sleep 0.25
done
if [ "$FOREIGN_READY" = "1" ]; then ok "foreign listener owns the fixed port before launch"; else bad "foreign listener did not bind :41090"; fi
if run_capped 15 "$PROJ/fixed-busy.log" env APP_IT_SMOKE=1 "$PROJ/desktop/Fixed Port.app/Contents/MacOS/run"; then
    bad "fixed-port busy launch unexpectedly fell back or succeeded"
else
    ok "fixed-port busy launch refused fallback"
fi
has "busy-port refusal explains fixed mode" "$(cat "$PROJ/fixed-busy.log" 2>/dev/null || true)" "port_mode fixed"
no_path "fixed-port busy refusal leaves no server.port" "$(state_dir fixed-port)/server.port"
APP_IT_PROJECT_ROOT="$PROJ" bash "$PROJ/scripts/desktop-doctor.sh" fixed-port >"$PROJ/doctor-foreign.log" 2>&1 || true
has "desktop-doctor reports unknown/probably foreign preferred-port listener" "$(cat "$PROJ/doctor-foreign.log" 2>/dev/null || true)" "unknown/probably foreign listener"
if kill -0 "$FOREIGN_PID" 2>/dev/null; then
    ok "desktop-doctor leaves foreign listener alone"
else
    bad "desktop-doctor killed a foreign listener"
fi
INSPECT="$(APP_IT_PROJECT_ROOT="$PROJ" bash "$PROJ/scripts/inspect.sh" 2>&1 || true)"
has "inspect reports config-port listener as unknown/probably foreign" "$INSPECT" ":41090"
has "inspect says it will not stop foreign listeners" "$INSPECT" "inspect will not stop it"
STALE_DIR="$(state_dir fixed-port)"
mkdir -p "$STALE_DIR"
printf '999999\n' >"$STALE_DIR/server.pid"
printf '41090\n' >"$STALE_DIR/server.port"
APP_IT_PROJECT_ROOT="$PROJ" bash "$PROJ/scripts/desktop-quit.sh" >"$PROJ/quit-stale-foreign.log" 2>&1 || true
FOREIGN_LISTENER="$(lsof -ti tcp:41090 2>/dev/null || true)"
if kill -0 "$FOREIGN_PID" 2>/dev/null && [ -n "$FOREIGN_LISTENER" ]; then
    ok "desktop-quit.sh leaves stale-state foreign listener alone"
else
    bad "desktop-quit.sh killed a foreign listener from stale state"
fi
has "desktop-quit.sh reports stale state calmly" "$(cat "$PROJ/quit-stale-foreign.log" 2>/dev/null || true)" "Cleaned stale App It state"
lacks "stale-state quit emits no killed-job noise" "$(cat "$PROJ/quit-stale-foreign.log" 2>/dev/null || true)" "Killed:"

/bin/sleep 300 &
REUSED_PID=$!
EXTRA_CLEANUP_PIDS="$EXTRA_CLEANUP_PIDS $REUSED_PID"
printf '%s\n' "$REUSED_PID" >"$STALE_DIR/server.pid"
printf '41090\n' >"$STALE_DIR/server.port"
rm -f "$STALE_DIR/server.identity"
APP_IT_PROJECT_ROOT="$PROJ" bash "$PROJ/scripts/desktop-quit.sh" >"$PROJ/quit-reused-pid.log" 2>&1 || true
if kill -0 "$REUSED_PID" 2>/dev/null; then
    ok "desktop-quit.sh leaves reused live PID alone"
else
    bad "desktop-quit.sh killed a reused live PID from stale state"
fi
no_path "reused-PID stale quit removes server.pid" "$STALE_DIR/server.pid"
no_path "reused-PID stale quit removes server.port" "$STALE_DIR/server.port"
has "reused-PID stale quit reports stale state calmly" "$(cat "$PROJ/quit-reused-pid.log" 2>/dev/null || true)" "Cleaned stale App It state"
lacks "reused-PID stale quit emits no killed-job noise" "$(cat "$PROJ/quit-reused-pid.log" 2>/dev/null || true)" "Killed:"
kill -TERM "$REUSED_PID" 2>/dev/null || true
wait "$REUSED_PID" 2>/dev/null || true

kill -TERM "$FOREIGN_PID" 2>/dev/null || true
wait "$FOREIGN_PID" 2>/dev/null || true
EXTRA_CLEANUP_PIDS=""

# =============================================================================
section "next-basic — Next detection + bundle assembly"
setup_proj next-basic app-it next-basic
INSPECT="$(APP_IT_PROJECT_ROOT="$PROJ" bash "$PROJ/scripts/inspect.sh" 2>&1 || true)"
has  "inspect detects next.config.js" "$INSPECT" "next.config.js"
has  "inspect lists the dev script"   "$INSPECT" "next dev"
has  "inspect recommends the direct Next binary option" "$INSPECT" 'Next direct-binary recommendation'
lacks "inspect emits no hardcoded-port warning" "$INSPECT" "hardcoded port literal"
build
assert_bundle "Next Basic" next-basic com.user.next-basic swift

# =============================================================================
section "claude-artifact-url — URL-only hosted Artifact bundle"
setup_proj claude-artifact-url app-it claude-artifact
build
assert_bundle "Claude Artifact" claude-artifact com.user.claude-artifact swift
RUN_SCRIPT="$(cat "$PROJ/desktop/Claude Artifact.app/Contents/MacOS/run.sh")"
has "URL-only template selected" "$RUN_SCRIPT" "claude.ai/public/artifacts"
has "URL-only wrapper keeps hosted navigation in-window" "$RUN_SCRIPT" "allow-external-hosts"
if run_capped 10 "$PROJ/url-smoke.log" env APP_IT_SMOKE=1 "$PROJ/desktop/Claude Artifact.app/Contents/MacOS/run"; then
    ok "URL-only launcher smoke run succeeds without starting a server"
else
    bad "URL-only launcher smoke run failed"; sed 's/^/       /' "$PROJ/url-smoke.log"
fi
no_path "URL-only launcher records no server.port" "$(state_dir claude-artifact)/server.port"
APP_IT_PROJECT_ROOT="$PROJ" bash "$PROJ/scripts/desktop-doctor.sh" claude-artifact >"$PROJ/doctor-artifact.log" 2>&1 || true
has "desktop-doctor reports URL-only mode" "$(cat "$PROJ/doctor-artifact.log")" "URL-only app; no local daemon"

# =============================================================================
section "next-hardcoded-port — inspect recommends direct Next binary"
setup_proj next-hardcoded-port app-it next-hardcoded-port
INSPECT="$(APP_IT_PROJECT_ROOT="$PROJ" bash "$PROJ/scripts/inspect.sh" 2>&1 || true)"
has "inspect detects pnpm package manager" "$INSPECT" "package manager:          pnpm"
has "inspect warns about the Next script's hardcoded port" "$INSPECT" "hardcoded port literal"
has "inspect recommends pnpm exec next dev" "$INSPECT" 'pnpm exec next dev --hostname 127.0.0.1 --port "$PORT"'
has "inspect flags the risky Next script shape" "$INSPECT" "Risky Next script shape in: dev"

# =============================================================================
section "static-export — app-it-static export detection + real static-server serve"
setup_proj static-export app-it-static static-export
INSPECT="$(APP_IT_PROJECT_ROOT="$PROJ" bash "$PROJ/scripts/inspect-static.sh" 2>&1 || true)"
has "inspect-static detects Next static export" "$INSPECT" "Next.js (static export)"
has "inspect-static finds the prebuilt out/"    "$INSPECT" "out/"
build
assert_bundle "Static Export" static-export com.user.static-export swift
is_file "static-server.py copied into the bundle" "$PROJ/desktop/Static Export.app/Contents/MacOS/static-server.py"
seam_up "Static Export" static-export
quit_clean static-export "$RUNTIME_PORT"

# Reused-PID safety for the STATIC quit (parity with the app-it lane above): a
# live, unrelated PID recorded in identity-less stale state must SURVIVE
# desktop-quit.sh. The static launcher now writes server.identity, so state with
# no identity file falls to the listener-ownership proof — which a bare sleep,
# owning no listener on the recorded port, can never satisfy.
STATIC_STALE_DIR="$(state_dir static-export)"
mkdir -p "$STATIC_STALE_DIR"
/bin/sleep 300 &
STATIC_REUSED_PID=$!
EXTRA_CLEANUP_PIDS="$EXTRA_CLEANUP_PIDS $STATIC_REUSED_PID"
printf '%s\n' "$STATIC_REUSED_PID" >"$STATIC_STALE_DIR/server.pid"
printf '%s\n' "$RUNTIME_PORT" >"$STATIC_STALE_DIR/server.port"
rm -f "$STATIC_STALE_DIR/server.identity"
APP_IT_PROJECT_ROOT="$PROJ" bash "$PROJ/scripts/desktop-quit.sh" >"$PROJ/static-quit-reused.log" 2>&1 || true
if kill -0 "$STATIC_REUSED_PID" 2>/dev/null; then
    ok "app-it-static desktop-quit.sh leaves reused live PID alone"
else
    bad "app-it-static desktop-quit.sh killed a reused live PID from stale state"
fi
no_path "static reused-PID quit removes server.pid" "$STATIC_STALE_DIR/server.pid"
no_path "static reused-PID quit removes server.port" "$STATIC_STALE_DIR/server.port"
has "static reused-PID quit reports stale state calmly" "$(cat "$PROJ/static-quit-reused.log" 2>/dev/null || true)" "Cleaned stale App It static state"
lacks "static reused-PID quit emits no killed-job noise" "$(cat "$PROJ/static-quit-reused.log" 2>/dev/null || true)" "Killed:"
kill -TERM "$STATIC_REUSED_PID" 2>/dev/null || true
wait "$STATIC_REUSED_PID" 2>/dev/null || true
EXTRA_CLEANUP_PIDS=""

# =============================================================================
section "vite-express — A3.2 multiserver: dual-port launch + ownership"
setup_proj vite-express app-it vite-express
INSPECT="$(APP_IT_PROJECT_ROOT="$PROJ" bash "$PROJ/scripts/inspect.sh" 2>&1 || true)"
has "inspect flags a multi-server (A3) proxy target" "$INSPECT" "Multi-server cohabiting (A3) likely"
build
assert_bundle "Vite Express" vite-express com.user.vite-express swift
has "multiserver template selected (run.sh exports API_PORT)" "$(cat "$PROJ/desktop/Vite Express.app/Contents/MacOS/run.sh")" "API_PORT"
seam_up "Vite Express" vite-express
FE_PORT="$RUNTIME_PORT"; BE_PORT="$(cat "$(state_dir vite-express)/backend.port" 2>/dev/null || true)"
if [ -n "$BE_PORT" ] && [ -n "$(lsof -ti tcp:"$BE_PORT" 2>/dev/null || true)" ]; then ok "backend listening on :$BE_PORT"; else bad "backend not listening (backend.port=$BE_PORT)"; fi
if python3 - "$(state_dir vite-express)/runtime.json" "$FE_PORT" "$BE_PORT" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text())
assert payload["schema_version"] == 1
assert payload["tool"] == "app-it.runtime"
assert payload["mode"] == "multi-server"
assert payload["ports"]["frontend"]["preferred"] == 41010
assert payload["ports"]["frontend"]["runtime"] == int(sys.argv[2])
assert payload["ports"]["backend"]["preferred"] == 41020
assert payload["ports"]["backend"]["runtime"] == int(sys.argv[3])
PY
then
    ok "multiserver runtime.json records preferred and runtime FE/BE ports"
else
    bad "multiserver runtime.json did not record preferred/runtime FE/BE ports"
    sed 's/^/       /' "$(state_dir vite-express)/runtime.json" 2>/dev/null || true
fi
APP_IT_PROJECT_ROOT="$PROJ" bash "$PROJ/scripts/desktop-doctor.sh" --json vite-express >"$PROJ/doctor-vite-express.json" 2>"$PROJ/doctor-vite-express.err" || true
if python3 - "$PROJ/doctor-vite-express.json" "$FE_PORT" "$BE_PORT" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text())
messages = [row["message"] for row in payload["checks"]]
assert payload["ports"]["preferred"] == "41010"
assert payload["ports"]["runtime"] == sys.argv[2]
assert payload["ports"]["backend_preferred"] == "41020"
assert payload["ports"]["backend_runtime"] == sys.argv[3]
assert any("frontend runtime port" in message for message in messages)
assert any("backend runtime port" in message for message in messages)
PY
then
    ok "desktop-doctor --json reports multiserver preferred/runtime FE/BE ports"
else
    bad "desktop-doctor --json did not report multiserver preferred/runtime FE/BE ports"
    sed 's/^/       /' "$PROJ/doctor-vite-express.json" 2>/dev/null || true
    sed 's/^/       /' "$PROJ/doctor-vite-express.err" 2>/dev/null || true
fi
APP_IT_PROJECT_ROOT="$PROJ" bash "$PROJ/scripts/desktop-verify.sh" --json vite-express >"$PROJ/verify-vite-express.json" 2>"$PROJ/verify-vite-express.err" || true
if python3 - "$PROJ/verify-vite-express.json" "$FE_PORT" "$BE_PORT" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text())
messages = [row["message"] for row in payload["checks"]]
assert payload["ports"]["preferred"] == "41010"
assert payload["ports"]["runtime"] == sys.argv[2]
assert payload["ports"]["backend_preferred"] == "41020"
assert payload["ports"]["backend_runtime"] == sys.argv[3]
assert payload["artifacts"]["runtime_summary_present"] is True
assert any("frontend runtime port" in message for message in messages)
assert any("backend runtime port" in message for message in messages)
PY
then
    ok "desktop-verify --json reports multiserver preferred/runtime FE/BE ports"
else
    bad "desktop-verify --json did not report multiserver preferred/runtime FE/BE ports"
    sed 's/^/       /' "$PROJ/verify-vite-express.json" 2>/dev/null || true
    sed 's/^/       /' "$PROJ/verify-vite-express.err" 2>/dev/null || true
fi
quit_clean vite-express "$FE_PORT" "$BE_PORT"

# =============================================================================
section "deep-tree — descendant-walk: ownership + warm-reattach across a gen-2 tree"
setup_proj deep-tree app-it deep-tree
build
assert_bundle "Deep Tree" deep-tree com.user.deep-tree swift
seam_up "Deep Tree" deep-tree   # the oracle confirms the gen-2 listener is genuinely owned
DT_PID="$(cat "$(state_dir deep-tree)/server.pid" 2>/dev/null || true)"; DT_PORT="$RUNTIME_PORT"
# desktop-doctor must confirm ownership ACROSS the gen-2 tree (guards its walk).
APP_IT_PROJECT_ROOT="$PROJ" bash "$PROJ/scripts/desktop-doctor.sh" deep-tree >"$PROJ/doctor-dt.log" 2>&1 || true
has "desktop-doctor confirms ownership across a gen-2 process tree" "$(cat "$PROJ/doctor-dt.log")" "belongs to this launcher"
# Warm re-launch must reattach across the gen-2 tree — not cold-start a 2nd
# server on a new port. THIS is the assertion that fails if the descendant walk
# regresses to generation 1 (the macOS pgrep -P trap this fixture guards).
warm_reattach "Deep Tree" deep-tree "$DT_PID" "$DT_PORT"
DT_PORT2="$(cat "$(state_dir deep-tree)/server.port" 2>/dev/null || true)"
quit_clean deep-tree "$DT_PORT" "$DT_PORT2"

# =============================================================================
section "hardcoded-port — inspect must keep warning about port literals"
setup_proj hardcoded-port app-it hardcoded-port
INSPECT="$(APP_IT_PROJECT_ROOT="$PROJ" bash "$PROJ/scripts/inspect.sh" 2>&1 || true)"
has "inspect warns about the dev script's --port literal" "$INSPECT" "hardcoded port literal"
has "inspect warns about the vite.config server.port literal" "$INSPECT" "hardcoded server.port literal"

# =============================================================================
section "chrome-fallback — APP_IT_LAUNCHER_MODE=chrome build shape"
setup_proj chrome-fallback app-it chrome-fallback
build APP_IT_LAUNCHER_MODE=chrome
assert_bundle "Chrome Fallback" chrome-fallback com.user.chrome-fallback chrome

# =============================================================================
section "cleanup ownership source guards — Cmd+Q avoids raw port sweeps"
WRAPPER_SRC="$(cat "$REPO/plugins/app-it/skills/app-it/templates/wrapper.swift")"
has "Cmd+Q wrapper checks PID identity" "$WRAPPER_SRC" "pidIdentityMatches"
has "Cmd+Q wrapper limits listener cleanup to descendant tree" "$WRAPPER_SRC" "ownedListenerPids"
has "Cmd+Q wrapper keeps legacy listener proof explicit" "$WRAPPER_SRC" "Legacy state has no identity file"
lacks "Cmd+Q wrapper has no raw shell port sweep" "$WRAPPER_SRC" 'for q in $('

# =============================================================================
section "windows cleanup ownership source guards (beta — static, runs on macOS)"
# The .ps1 / .cs can't execute on macOS; the windows-latest CI lane runs the
# behavioral Pester suite (plugins/app-it-windows/tests/desktop-quit.Tests.ps1).
# These static guards run HERE so a macOS-only change can't silently regress the
# Windows quit back to the ownership-blind port sweep this hardening removed.
WIN_QUIT_SRC="$(cat "$REPO/plugins/app-it-windows/skills/app-it-windows/templates/desktop-quit.ps1")"
WIN_DEVSERVER_SRC="$(cat "$REPO/plugins/app-it-windows/skills/app-it-windows/templates/wrapper-windows/DevServer.cs")"
WIN_EDGE_SRC="$(cat "$REPO/plugins/app-it-windows/skills/app-it-windows/templates/run-template-edge.ps1")"
has "Windows quit proves PID identity before stopping" "$WIN_QUIT_SRC" "Test-ProcessIdentityMatch"
has "Windows quit limits listener cleanup to the recorded tree" "$WIN_QUIT_SRC" "Get-OwnedListener"
has "Windows quit keeps the legacy listener proof explicit" "$WIN_QUIT_SRC" "Legacy state (no identity file)"
lacks "Windows quit has no ownership-blind port sweep (Invoke-PortSweep)" "$WIN_QUIT_SRC" "Invoke-PortSweep"
lacks "Windows quit has no ownership-blind port sweep (Get-PortOwner)" "$WIN_QUIT_SRC" "Get-PortOwner"
has "Windows host records server.identity at spawn" "$WIN_DEVSERVER_SRC" "server.identity"
has "Windows host identity is an invariant FILETIME" "$WIN_DEVSERVER_SRC" "ToFileTimeUtc"
has "Windows Edge fallback records server.identity at spawn" "$WIN_EDGE_SRC" "server.identity"

# =============================================================================
section "placeholder-icon-gen.sh emits a valid SVG (no rasterizer needed)"
ICONTMP="$WORK/iconcheck"; mkdir -p "$ICONTMP"
APP_NAME="Probe App" APP_SLUG="probe-app" APP_IT_PROJECT_ROOT="$ICONTMP" \
    bash "$REPO/plugins/app-it/skills/app-it/templates/placeholder-icon-gen.sh" >/dev/null 2>&1 || true
if [ -f "$ICONTMP/assets/probe-app-icon.svg" ] && grep -q '<svg' "$ICONTMP/assets/probe-app-icon.svg"; then
    ok "placeholder-icon-gen.sh wrote a valid SVG"
else
    bad "placeholder-icon-gen.sh did not produce an SVG"
fi

# =============================================================================
if [ "${APP_IT_RUN_REAL:-}" = "1" ]; then
    section "vite-real — real npm install + real Vite launch (scheduled/release lane)"
    setup_proj vite-real app-it vite-real
    if ( cd "$PROJ" && npm install --no-audit --no-fund --loglevel=error ) >"$PROJ/npm.log" 2>&1; then
        ok "npm install succeeded"
        build
        assert_bundle "Vite Real" vite-real com.user.vite-real swift
        seam_up "Vite Real" vite-real
        quit_clean vite-real "$RUNTIME_PORT"
    else
        bad "npm install failed"; tail -20 "$PROJ/npm.log" | sed 's/^/       /'
    fi
else
    section "vite-real — SKIPPED (set APP_IT_RUN_REAL=1 to run the real-framework lane)"
    note "covered weekly by the fixtures-real CI job and at release"
fi

# =============================================================================
section "fixture port cleanup"
assert_fixture_ports_clear

# =============================================================================
section "Summary"
printf '  %s%d passed%s · %s%d failed%s\n' "$G" "$PASS" "$O" "$R" "$FAIL" "$O"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
echo "app-it fixture suite passed"
