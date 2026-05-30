#!/bin/bash
# Stop the persistent dev servers spawned by the desktop launchers, plus any
# open wrapper windows. Closing the app window with the red X does NOT kill
# these — the launcher daemonizes them so the next click is fast.
#
# v2 reads scripts/app-it.config.json (single source of truth) — falls back
# to a bash APPS array for backward compat. Sweeps both frontend and backend
# ports for multi-server apps.
#
# IMPORTANT: pgrep matches against the kernel's process command line, which on
# macOS stores paths in NFD (decomposed Unicode). Our shell strings are
# typically NFC. Matching paths with non-ASCII characters via `pgrep -f` will
# silently fail on the bundle name — we use the ASCII portion of the path
# (.app/Contents/MacOS/wrapper) as the match anchor and verify with the
# wrapper's URL/port argv (also ASCII).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${APP_IT_PROJECT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CONFIG_FILE="$SCRIPT_DIR/app-it.config.json"

# --- Load apps from JSON (preferred) or bash array (backward compat) -----
# Internal record per app: name|slug|preferred_port|backend_port
APPS=()
if [ -f "$CONFIG_FILE" ]; then
    while IFS= read -r line; do
        [ -n "$line" ] && APPS+=("$line")
    done < <(/usr/bin/python3 - "$CONFIG_FILE" <<'PY'
import json, re, sys
with open(sys.argv[1]) as f:
    cfg = json.load(f)
for a in cfg.get("apps", []):
    name = a.get("name", "")
    slug = a.get("slug") or re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    print(f'{name}|{slug}|{a.get("port","")}|{a.get("backend_port") or ""}')
PY
)
else
    APPS=(
      # Replace these with your apps. Format: name|slug|preferred_port|backend_port
      "__APP_NAME__|__APP_SLUG__|__PORT__|"
    )
fi

if [ "${#APPS[@]}" -eq 0 ]; then
    echo "ERROR: no apps configured. Edit scripts/app-it.config.json." >&2
    exit 1
fi

kill_tree() {
    local pid=$1
    [ -z "$pid" ] && return
    kill -0 "$pid" 2>/dev/null || return
    for child in $(pgrep -P "$pid" 2>/dev/null); do
        kill_tree "$child"
    done
    kill -TERM "$pid" 2>/dev/null || true
}

# Three-stage cleanup for one port:
#   1. TERM the recorded PID's process tree.
#   2. Sweep anyone still bound to the runtime port (re-parented children).
#   3. Wait up to 1.5s, then SIGKILL stragglers.
sweep_port() {
    local app_name="$1"
    local pid_file="$2"
    local port="$3"
    [ -z "$port" ] && return 0

    local closed_local=0

    if [ -f "$pid_file" ]; then
        kill_tree "$(cat "$pid_file")"
        closed_local=1
    fi
    for p in $(lsof -ti tcp:"$port" 2>/dev/null); do
        kill_tree "$p"
        closed_local=1
    done
    if lsof -ti tcp:"$port" >/dev/null 2>&1; then
        for _ in 1 2 3; do
            [ -z "$(lsof -ti tcp:"$port" 2>/dev/null)" ] && break
            sleep 0.5
        done
        for p in $(lsof -ti tcp:"$port" 2>/dev/null); do
            kill -KILL "$p" 2>/dev/null || true
            closed_local=1
        done
    fi
    [ "$closed_local" = "1" ] && CLOSED_ANY=1
    return 0
}

CLOSED_ANY=0
for entry in "${APPS[@]}"; do
    IFS='|' read -r APP_NAME APP_SLUG PREFERRED_PORT BACKEND_PORT <<<"$entry"
    STATE_DIR="$HOME/Library/Application Support/app-it/$APP_SLUG"
    PID_FILE="$STATE_DIR/server.pid"
    PORT_FILE="$STATE_DIR/server.port"
    BACKEND_PID_FILE="$STATE_DIR/backend.pid"
    BACKEND_PORT_FILE="$STATE_DIR/backend.port"

    # Frontend: prefer recorded runtime port, fall back to configured.
    PORT="$(cat "$PORT_FILE" 2>/dev/null || true)"
    [ -z "$PORT" ] && PORT="$PREFERRED_PORT"
    sweep_port "$APP_NAME" "$PID_FILE" "$PORT"

    # Sweep configured port too if runtime differed.
    if [ -n "$PREFERRED_PORT" ] && [ "$PORT" != "$PREFERRED_PORT" ]; then
        sweep_port "$APP_NAME" "" "$PREFERRED_PORT"
    fi

    # Backend (if multi-server).
    if [ -n "$BACKEND_PORT" ]; then
        BPORT="$(cat "$BACKEND_PORT_FILE" 2>/dev/null || true)"
        [ -z "$BPORT" ] && BPORT="$BACKEND_PORT"
        sweep_port "$APP_NAME" "$BACKEND_PID_FILE" "$BPORT"
        if [ "$BPORT" != "$BACKEND_PORT" ]; then
            sweep_port "$APP_NAME" "" "$BACKEND_PORT"
        fi
    fi

    # Next can leave a supervisor process alive after its listening child has
    # already exited. It no longer holds the port, so the port sweep misses it,
    # but it still belongs to this launcher. Match only the ASCII path fragment
    # to avoid macOS Unicode normalization traps in the repo path.
    while read -r pid command; do
        case "$command" in
            *web/node_modules/.bin/next\ dev*)
                kill_tree "$pid"
                CLOSED_ANY=1
                ;;
        esac
    done < <(ps -axo pid=,command=)

    rm -f "$PID_FILE" "$PORT_FILE" "$BACKEND_PID_FILE" "$BACKEND_PORT_FILE"
done

# Native WebKit wrapper windows — match by bundle-name path (.app component
# is ASCII even when bundle name has accents) plus the app name in argv.
for entry in "${APPS[@]}"; do
    IFS='|' read -r APP_NAME APP_SLUG _ _ <<<"$entry"
    for p in $(pgrep -f "MacOS/wrapper http://localhost:" 2>/dev/null); do
        cmdline="$(ps -o command= -p "$p" 2>/dev/null || true)"
        if echo "$cmdline" | grep -qF "$APP_NAME"; then
            kill -TERM "$p" 2>/dev/null || true
            CLOSED_ANY=1
        fi
    done
    # Chrome --user-data-dir windows from chrome-fallback builds.
    PROFILE="$HOME/Library/Application Support/app-it/$APP_SLUG/BrowserProfile"
    for p in $(pgrep -f "user-data-dir=$PROFILE" 2>/dev/null); do
        kill -TERM "$p" 2>/dev/null || true
        CLOSED_ANY=1
    done
done

if [ "$CLOSED_ANY" = "1" ]; then
    echo "Stopped dev servers and open windows."
else
    echo "Nothing to stop — no servers were running."
fi
