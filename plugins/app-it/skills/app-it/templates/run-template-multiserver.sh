#!/bin/bash
# app-it launcher (multi-server cohabiting variant). Used for A3.2 — when
# the project has a separate frontend + backend that must run together,
# AND the project does NOT already have a multi-process orchestrator.
#
# When the project DOES have an orchestrator (`concurrently`, `npm-run-all -p`,
# `turbo run dev`, `pnpm -r dev`), prefer A3.1: use the orchestrator as a
# single START_COMMAND in run-template.sh. Strictly simpler.
#
# This template allocates two ports (frontend + backend), exports them
# distinctly (PORT and API_PORT), boots both via setsid, waits for the
# frontend port, hands off to the wrapper. Records both ports in
# ~/Library/Application Support/app-it/<slug>/{server,backend}.port for cleanup.
#
# Required source edits (carve-out from "don't touch app source"):
#   • Frontend config: server.port reads process.env.PORT
#   • Frontend config: strictPort: true (Vite specifically)
#   • Frontend config: proxy target reads process.env.API_PORT
#   • Backend entrypoint: reads process.env.API_PORT BEFORE process.env.PORT
#     (cohabiting projects often have .env with PORT=, which the backend
#     would pick up and ignore the launcher's API_PORT)
#
# Substituted by desktop-build.sh:
#   __APP_NAME__, __APP_SLUG__, __PROJECT_ROOT__,
#   __PORT__                    preferred frontend port
#   __START_COMMAND__            frontend dev command (honors PORT)
#   __BACKEND_PORT__             preferred backend port
#   __BACKEND_START_COMMAND__    backend command (honors API_PORT)
#   __POLYFILL_PATH__

set -e

APP_NAME="__APP_NAME__"
APP_SLUG="__APP_SLUG__"
PROJECT_ROOT="__PROJECT_ROOT__"
PREFERRED_FE_PORT=__PORT__
PREFERRED_BE_PORT=__BACKEND_PORT__
POLYFILL_PATH="__POLYFILL_PATH__"

# Keep `$PORT` / `$API_PORT` and other shell syntax literal until the daemon
# spawns below. A plain double-quoted assignment here would expand those values
# before the launcher has selected its runtime ports.
START_COMMAND="$(cat <<'APP_IT_START_COMMAND'
__START_COMMAND__
APP_IT_START_COMMAND
)"
BACKEND_START_COMMAND="$(cat <<'APP_IT_BACKEND_START_COMMAND'
__BACKEND_START_COMMAND__
APP_IT_BACKEND_START_COMMAND
)"

STATE_DIR="$HOME/Library/Application Support/app-it/$APP_SLUG"
LOG_DIR="$HOME/Library/Logs/app-it/$APP_SLUG"
mkdir -p "$STATE_DIR" "$LOG_DIR"
SERVER_LOG="$LOG_DIR/server.log"
BACKEND_LOG="$LOG_DIR/backend.log"
PID_FILE="$STATE_DIR/server.pid"
PORT_FILE="$STATE_DIR/server.port"
BACKEND_PID_FILE="$STATE_DIR/backend.pid"
BACKEND_PORT_FILE="$STATE_DIR/backend.port"

HERE="$(cd "$(dirname "$0")" && pwd)"

# --- PATH augmentation -------------------------------------------------
NVM_BIN=""
if [ -d "$HOME/.nvm/versions/node" ]; then
    LATEST_NVM_NODE="$(ls -1 "$HOME/.nvm/versions/node" 2>/dev/null | sort -V | tail -1)"
    [ -n "$LATEST_NVM_NODE" ] && NVM_BIN="$HOME/.nvm/versions/node/$LATEST_NVM_NODE/bin"
fi
export PATH="$HOME/.bun/bin:$HOME/.deno/bin:$HOME/.volta/bin:$HOME/.local/share/mise/shims:$HOME/.asdf/shims:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:${NVM_BIN}:$HOME/Library/pnpm:$PATH"

# --- Project-root sanity ------------------------------------------------
if [ ! -d "$PROJECT_ROOT" ]; then
    /usr/bin/osascript -e "display alert \"$APP_NAME failed to launch\" message \"Project repo not found at:\n$PROJECT_ROOT\""
    exit 1
fi

# --- Pre-flight binary checks ------------------------------------------
for cmd_str in "$START_COMMAND" "$BACKEND_START_COMMAND"; do
    BIN="$(echo "$cmd_str" | awk '{print $1}')"
    if [ -n "$BIN" ] && ! command -v "$BIN" >/dev/null 2>&1; then
        /usr/bin/osascript -e "display alert \"$APP_NAME can't start\" message \"Required binary not found on PATH:\n$BIN\""
        exit 1
    fi
done

case "$START_COMMAND$BACKEND_START_COMMAND" in
    *npm\ *|*pnpm\ *|*yarn\ *|*bun\ run*|*bunx*|*npx*)
        if [ ! -d "$PROJECT_ROOT/node_modules" ]; then
            /usr/bin/osascript -e "display alert \"$APP_NAME can't start\" message \"node_modules is missing in:\n$PROJECT_ROOT\""
            exit 1
        fi
        ;;
esac

# --- Stale-state cleanup ----------------------------------------------
for pf in "$PID_FILE" "$BACKEND_PID_FILE"; do
    if [ -f "$pf" ]; then
        EXPECTED_PID="$(cat "$pf" 2>/dev/null || true)"
        if [ -z "$EXPECTED_PID" ] || ! kill -0 "$EXPECTED_PID" 2>/dev/null; then
            rm -f "$pf"
            case "$pf" in
                *server.pid) rm -f "$PORT_FILE" ;;
                *backend.pid) rm -f "$BACKEND_PORT_FILE" ;;
            esac
        fi
    fi
done

# --- Reattach if both servers are still ours and responding -----------
# Same descendant-walk gate as run-template.sh, applied to both processes.
descendant_holds_port() {
    local supervisor=$1
    local port=$2
    local listeners
    listeners="$(lsof -ti tcp:"$port" 2>/dev/null || true)"
    [ -z "$listeners" ] && return 1
    local descendants="$supervisor"
    local current="$supervisor"
    for _ in 1 2 3 4; do
        local next_gen
        next_gen="$(pgrep -P "$current" 2>/dev/null | tr '\n' ' ')"
        [ -z "$next_gen" ] && break
        descendants="$descendants $next_gen"
        current="$next_gen"
    done
    for pid in $listeners; do
        if echo " $descendants " | grep -q " $pid "; then
            return 0
        fi
    done
    return 1
}

CHOSEN_FE_PORT=""
CHOSEN_BE_PORT=""
if [ -f "$PID_FILE" ] && [ -f "$PORT_FILE" ] && [ -f "$BACKEND_PID_FILE" ] && [ -f "$BACKEND_PORT_FILE" ]; then
    FE_PID="$(cat "$PID_FILE")"
    FE_PORT="$(cat "$PORT_FILE")"
    BE_PID="$(cat "$BACKEND_PID_FILE")"
    BE_PORT="$(cat "$BACKEND_PORT_FILE")"

    if kill -0 "$FE_PID" 2>/dev/null && kill -0 "$BE_PID" 2>/dev/null \
        && descendant_holds_port "$FE_PID" "$FE_PORT" \
        && descendant_holds_port "$BE_PID" "$BE_PORT"; then
        FE_STATUS="$(curl -sS -o /dev/null --max-time 1 -w "%{http_code}" "http://localhost:$FE_PORT" 2>/dev/null || true)"
        if [ -n "$FE_STATUS" ] && [ "$FE_STATUS" != "000" ]; then
            CHOSEN_FE_PORT="$FE_PORT"
            CHOSEN_BE_PORT="$BE_PORT"
        fi
    fi

    if [ -z "$CHOSEN_FE_PORT" ]; then
        rm -f "$PID_FILE" "$PORT_FILE" "$BACKEND_PID_FILE" "$BACKEND_PORT_FILE"
    fi
fi

# --- Allocate fresh ports + start both servers -------------------------
if [ -z "$CHOSEN_FE_PORT" ]; then
    # Frontend port
    for p in $(seq "$PREFERRED_FE_PORT" "$((PREFERRED_FE_PORT + 50))"); do
        if ! lsof -i tcp:"$p" >/dev/null 2>&1; then
            CHOSEN_FE_PORT="$p"
            break
        fi
    done
    # Backend port (skip the FE port if ranges overlap)
    for p in $(seq "$PREFERRED_BE_PORT" "$((PREFERRED_BE_PORT + 50))"); do
        if [ "$p" = "$CHOSEN_FE_PORT" ]; then
            continue
        fi
        if ! lsof -i tcp:"$p" >/dev/null 2>&1; then
            CHOSEN_BE_PORT="$p"
            break
        fi
    done

    if [ -z "$CHOSEN_FE_PORT" ] || [ -z "$CHOSEN_BE_PORT" ]; then
        /usr/bin/osascript -e "display alert \"$APP_NAME couldn't find free ports\" message \"Searched FE [$PREFERRED_FE_PORT–$((PREFERRED_FE_PORT + 50))] and BE [$PREFERRED_BE_PORT–$((PREFERRED_BE_PORT + 50))].\""
        exit 1
    fi

    cd "$PROJECT_ROOT"

    # Start backend first so the frontend's proxy target is ready when
    # the frontend boots.
    if command -v setsid >/dev/null 2>&1; then
        API_PORT="$CHOSEN_BE_PORT" PORT="$CHOSEN_BE_PORT" setsid bash -c "$BACKEND_START_COMMAND" > "$BACKEND_LOG" 2>&1 < /dev/null &
    else
        API_PORT="$CHOSEN_BE_PORT" PORT="$CHOSEN_BE_PORT" nohup bash -c "trap '' HUP; $BACKEND_START_COMMAND" > "$BACKEND_LOG" 2>&1 < /dev/null &
    fi
    BE_PID=$!
    echo "$BE_PID" > "$BACKEND_PID_FILE"
    echo "$CHOSEN_BE_PORT" > "$BACKEND_PORT_FILE"
    disown "$BE_PID" 2>/dev/null || true

    # Wait for the backend port to bind (don't curl — backends may not
    # serve a 200 on /).
    for _ in $(seq 1 60); do
        lsof -i tcp:"$CHOSEN_BE_PORT" >/dev/null 2>&1 && break
        sleep 0.5
    done

    # Start frontend with both PORT and API_PORT exported.
    if command -v setsid >/dev/null 2>&1; then
        PORT="$CHOSEN_FE_PORT" API_PORT="$CHOSEN_BE_PORT" setsid bash -c "$START_COMMAND" > "$SERVER_LOG" 2>&1 < /dev/null &
    else
        PORT="$CHOSEN_FE_PORT" API_PORT="$CHOSEN_BE_PORT" nohup bash -c "trap '' HUP; $START_COMMAND" > "$SERVER_LOG" 2>&1 < /dev/null &
    fi
    FE_PID=$!
    echo "$FE_PID" > "$PID_FILE"
    echo "$CHOSEN_FE_PORT" > "$PORT_FILE"
    disown "$FE_PID" 2>/dev/null || true

    URL="http://localhost:$CHOSEN_FE_PORT"

    # Two-stage probe on the frontend.
    READY=0
    for _ in $(seq 1 120); do
        if lsof -i tcp:"$CHOSEN_FE_PORT" >/dev/null 2>&1; then
            READY=1
            break
        fi
        sleep 0.5
    done
    if [ "$READY" = "1" ]; then
        READY=0
        for _ in $(seq 1 120); do
            STATUS="$(curl -sS -o /dev/null --max-time 1 -w "%{http_code}" "$URL" 2>/dev/null || true)"
            if [ -n "$STATUS" ] && [ "$STATUS" != "000" ]; then
                READY=1
                break
            fi
            sleep 0.5
        done
    fi

    if [ "$READY" != "1" ]; then
        FE_TAIL="$(tail -20 "$SERVER_LOG" 2>/dev/null | sed 's/"/\\"/g' | tr '\n' ' ' | head -c 400)"
        BE_TAIL="$(tail -20 "$BACKEND_LOG" 2>/dev/null | sed 's/"/\\"/g' | tr '\n' ' ' | head -c 400)"
        rm -f "$PID_FILE" "$PORT_FILE" "$BACKEND_PID_FILE" "$BACKEND_PORT_FILE"
        /usr/bin/osascript -e "display alert \"$APP_NAME failed to start\" message \"Frontend did not bind to $URL within 60s.\n\nFrontend log:\n$FE_TAIL\n\nBackend log:\n$BE_TAIL\""
        exit 1
    fi
fi

URL="http://localhost:$CHOSEN_FE_PORT"

# --- Hand off to the native WebKit wrapper -----------------------------
WRAPPER="$HERE/wrapper"
if [ ! -x "$WRAPPER" ]; then
    /usr/bin/osascript -e "display alert \"$APP_NAME failed to launch\" message \"Native wrapper missing at:\n$WRAPPER\""
    exit 1
fi

# Pass the frontend PID to the wrapper for Cmd+Q kill semantics.
# wrapper.swift's killServer() also discovers backend.pid / backend.port
# as siblings of $PID_FILE in the same log dir, so Cmd+Q tears down both
# servers without further argv plumbing. desktop-quit.sh remains the
# defensive sweep for whatever Cmd+Q didn't catch (re-parented children).
exec "$WRAPPER" "$URL" "$APP_NAME" "$CHOSEN_FE_PORT" "$PID_FILE" "$POLYFILL_PATH"
