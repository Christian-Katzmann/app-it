#!/bin/bash
# app-it-static launcher (tiny static-server variant — the robust default).
#
# Serves a FINISHED build directory (dist/ build/ out/ ...) over
# http://localhost:PORT using the bundled zero-dependency static-server.py, then
# hands the window to the native Swift WebKit wrapper that lives next to this
# script. No dev server, no bundler, no file-watcher — ~15 MB of RAM for a
# finished app instead of the 300-700 MB a dev server holds.
#
# Prefer the file:// variant (run-template-static-file.sh) when the build is
# confirmed file://-safe (relative asset paths, no client-side routing, no
# fetch of local files, no service worker) — that needs zero server at all.
#
# This file is a TEMPLATE. desktop-build.sh substitutes:
#   __APP_NAME__       human display name (e.g. "Momó Studio")
#   __APP_SLUG__       file-safe slug (e.g. "momo-studio")
#   __PROJECT_ROOT__   absolute path to the repo (baked at build time)
#   __PORT__           PREFERRED port — tried first; the launcher scans upward
#                      [PORT..PORT+50] for a free one if it's taken.
#   __STATIC_DIR__     build output dir, relative to PROJECT_ROOT (holds index.html)
#
# The served bytes are a SNAPSHOT. After changing source, run desktop:rebuild
# (build → bundle → install) to refresh — a static launcher does NOT live-reload.

set -e

APP_NAME="__APP_NAME__"
APP_SLUG="__APP_SLUG__"
PROJECT_ROOT="__PROJECT_ROOT__"
PREFERRED_PORT=__PORT__
STATIC_DIR="__STATIC_DIR__"

STATIC_PATH="$PROJECT_ROOT/$STATIC_DIR"

STATE_DIR="$HOME/Library/Application Support/app-it/$APP_SLUG"
LOG_DIR="$HOME/Library/Logs/app-it/$APP_SLUG"
mkdir -p "$STATE_DIR" "$LOG_DIR"
SERVER_LOG="$LOG_DIR/server.log"
PID_FILE="$STATE_DIR/server.pid"
PORT_FILE="$STATE_DIR/server.port"

HERE="$(cd "$(dirname "$0")" && pwd)"
PYTHON="$(command -v python3 || echo /usr/bin/python3)"

# --- Built-output + python sanity --------------------------------------
if [ ! -d "$STATIC_PATH" ]; then
    /usr/bin/osascript -e "display alert \"$APP_NAME failed to launch\" message \"Built output not found at:\n$STATIC_PATH\n\nThis app serves a finished build. Re-run desktop:rebuild from the repo to regenerate it.\""
    exit 1
fi
if [ ! -f "$STATIC_PATH/index.html" ]; then
    /usr/bin/osascript -e "display alert \"$APP_NAME failed to launch\" message \"No index.html in:\n$STATIC_PATH\n\nThe configured static_dir doesn't look like a built site. Check scripts/app-it.config.json.\""
    exit 1
fi
if [ ! -x "$PYTHON" ] && ! command -v python3 >/dev/null 2>&1; then
    /usr/bin/osascript -e "display alert \"$APP_NAME can't start\" message \"python3 was not found. Install the Xcode Command Line Tools:\nxcode-select --install\""
    exit 1
fi

# --- Stale-state cleanup ----------------------------------------------
if [ -f "$PID_FILE" ]; then
    EXPECTED_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -z "$EXPECTED_PID" ] || ! kill -0 "$EXPECTED_PID" 2>/dev/null; then
        rm -f "$PID_FILE" "$PORT_FILE"
    fi
fi

# --- Reattach to our own running server (descendant-walk gate) ---------
# Same anti-passive-attach gate as app-it: only reattach when the recorded
# supervisor PID is alive, the listener on the recorded port is in its
# descendant tree, and it answers HTTP. Otherwise start our own.
CHOSEN_PORT=""
if [ -f "$PID_FILE" ] && [ -f "$PORT_FILE" ]; then
    EXPECTED_PID="$(cat "$PID_FILE")"
    EXPECTED_PORT="$(cat "$PORT_FILE")"
    REATTACH_OK=0
    if kill -0 "$EXPECTED_PID" 2>/dev/null; then
        LISTENERS="$(lsof -ti tcp:"$EXPECTED_PORT" 2>/dev/null || true)"
        if [ -n "$LISTENERS" ]; then
            DESCENDANTS="$EXPECTED_PID"
            CURRENT="$EXPECTED_PID"
            for _ in 1 2 3 4; do
                # Expand one PID per pgrep call. macOS `pgrep -P` returns nothing
                # for a space-joined / trailing-space argument, so passing the
                # whole generation at once would silently halt the walk at the
                # first level and miss deeper listeners. Walk per-pid so each
                # call is clean.
                NEXT_GEN=""
                for _pid in $CURRENT; do
                    NEXT_GEN="$NEXT_GEN $(pgrep -P "$_pid" 2>/dev/null | tr '\n' ' ')"
                done
                [ -z "${NEXT_GEN// /}" ] && break
                DESCENDANTS="$DESCENDANTS $NEXT_GEN"
                CURRENT="$NEXT_GEN"
            done
            for pid in $LISTENERS; do
                if echo " $DESCENDANTS " | grep -q " $pid "; then
                    REATTACH_OK=1
                    break
                fi
            done
            if [ "$REATTACH_OK" = "1" ]; then
                STATUS="$(curl -sS -o /dev/null --max-time 1 -w "%{http_code}" "http://localhost:$EXPECTED_PORT" 2>/dev/null || true)"
                [ -z "$STATUS" ] || [ "$STATUS" = "000" ] && REATTACH_OK=0
            fi
        fi
    fi
    if [ "$REATTACH_OK" = "1" ]; then
        CHOSEN_PORT="$EXPECTED_PORT"
    else
        rm -f "$PID_FILE" "$PORT_FILE"
    fi
fi

# --- Allocate a free port + start the static server --------------------
if [ -z "$CHOSEN_PORT" ]; then
    for p in $(seq "$PREFERRED_PORT" "$((PREFERRED_PORT + 50))"); do
        if ! lsof -i tcp:"$p" >/dev/null 2>&1; then
            CHOSEN_PORT="$p"
            break
        fi
    done
    if [ -z "$CHOSEN_PORT" ]; then
        /usr/bin/osascript -e "display alert \"$APP_NAME couldn't find a free port\" message \"Searched $PREFERRED_PORT–$((PREFERRED_PORT + 50)). Quit something using one of those ports and try again.\""
        exit 1
    fi

    # setsid detaches the server from the wrapper's process group so the wrapper
    # exiting can't SIGHUP it (matches app-it's daemon discipline).
    if command -v setsid >/dev/null 2>&1; then
        STATIC_DIR="$STATIC_PATH" PORT="$CHOSEN_PORT" setsid "$PYTHON" "$HERE/static-server.py" > "$SERVER_LOG" 2>&1 < /dev/null &
    else
        STATIC_DIR="$STATIC_PATH" PORT="$CHOSEN_PORT" nohup "$PYTHON" "$HERE/static-server.py" > "$SERVER_LOG" 2>&1 < /dev/null &
    fi
    SERVER_PID=$!
    echo "$SERVER_PID" > "$PID_FILE"
    echo "$CHOSEN_PORT" > "$PORT_FILE"
    disown "$SERVER_PID" 2>/dev/null || true

    URL="http://localhost:$CHOSEN_PORT"

    # Static server cold-starts in milliseconds — a short HTTP poll is plenty.
    READY=0
    for _ in $(seq 1 40); do
        STATUS="$(curl -sS -o /dev/null --max-time 1 -w "%{http_code}" "$URL" 2>/dev/null || true)"
        if [ -n "$STATUS" ] && [ "$STATUS" != "000" ]; then
            READY=1
            break
        fi
        sleep 0.25
    done
    if [ "$READY" != "1" ]; then
        TAIL="$(tail -20 "$SERVER_LOG" 2>/dev/null | sed 's/"/\\"/g' | tr '\n' ' ' | head -c 600)"
        rm -f "$PID_FILE" "$PORT_FILE"
        /usr/bin/osascript -e "display alert \"$APP_NAME failed to start\" message \"The static server did not respond on $URL.\n\nLast log lines:\n$TAIL\""
        exit 1
    fi
fi

URL="http://localhost:$CHOSEN_PORT"

# --- Headless smoke seam (CI / SSH / --check) --------------------------
# The static server is up, daemonized, reachable, and its pid/port are
# recorded. With APP_IT_SMOKE set, print the runtime URL and exit 0 instead
# of opening the GUI window, so a headless caller can probe it (curl,
# desktop:doctor) and then stop it (desktop:quit). Zero effect on a normal
# Dock launch (APP_IT_SMOKE unset).
if [ -n "${APP_IT_SMOKE:-}" ]; then
    echo "app-it smoke: $APP_NAME ready at $URL (server pid $(cat "$PID_FILE" 2>/dev/null))"
    exit 0
fi

# --- Hand off to the native WebKit wrapper -----------------------------
# exec replaces this bash process with the Swift binary so the .app keeps its
# own Dock icon and single-instance activation. No polyfill for finished apps.
WRAPPER="$HERE/wrapper"
if [ ! -x "$WRAPPER" ]; then
    /usr/bin/osascript -e "display alert \"$APP_NAME failed to launch\" message \"Native wrapper missing at:\n$WRAPPER\n\nRun desktop:build to rebuild the bundle.\""
    exit 1
fi

exec "$WRAPPER" "$URL" "$APP_NAME" "$CHOSEN_PORT" "$PID_FILE" ""
