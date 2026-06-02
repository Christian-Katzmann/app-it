#!/bin/bash
# app-it launcher (Chrome --app fallback variant). Used when:
#   1. swiftc is unavailable AND xcode-select --install isn't feasible, OR
#   2. The app needs FSA real-I/O (handle.createWritable / handle.getFile),
#      OR other Chromium-only Web APIs (Web USB / Bluetooth / HID / MIDI).
#
# Feature parity with run-template.sh (Swift): runtime port-fallback,
# server.port recording, two-stage readiness probe, expanded PATH,
# pre-flight binary/deps checks, descendant-walk reattach gate.
#
# Documented warts that remain (these are structural to Chrome --app=):
#   • Dock icon may show Chrome's while window is open.
#   • Re-clicking the Dock icon may open a duplicate Chrome window.
#   • Window startup is slower (Chrome profile init).
#   • Cmd+Q vs red-X are not distinguished. Closing the window leaves the
#     dev server daemon running until desktop-quit.sh.
#     Set APP_IT_CHROME_KEEP_WARM=0 for the launcher to tear down the
#     daemon when Chrome exits (loses the warm-server benefit).
#
# Substituted by desktop-build.sh — see run-template.sh for placeholder docs.

set -e

APP_NAME="__APP_NAME__"
APP_SLUG="__APP_SLUG__"
PROJECT_ROOT="__PROJECT_ROOT__"
PREFERRED_PORT=__PORT__
POLYFILL_PATH="__POLYFILL_PATH__"

# Keep `$PORT` and other shell syntax literal until the daemon spawns below.
# A plain double-quoted assignment here would expand `$PORT` before the
# launcher has selected its runtime port, breaking Vite/SvelteKit recipes.
START_COMMAND="$(cat <<'APP_IT_START_COMMAND'
__START_COMMAND__
APP_IT_START_COMMAND
)"

STATE_DIR="$HOME/Library/Application Support/app-it/$APP_SLUG"
LOG_DIR="$HOME/Library/Logs/app-it/$APP_SLUG"
mkdir -p "$STATE_DIR" "$LOG_DIR"
SERVER_LOG="$LOG_DIR/server.log"
PID_FILE="$STATE_DIR/server.pid"
PORT_FILE="$STATE_DIR/server.port"
PROFILE="$STATE_DIR/BrowserProfile"
mkdir -p "$PROFILE"

KEEP_WARM="${APP_IT_CHROME_KEEP_WARM:-1}"

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

# --- Pre-flight: required binary present? ------------------------------
FIRST_BIN="$(echo "$START_COMMAND" | awk '{print $1}')"
if [ -n "$FIRST_BIN" ] && ! command -v "$FIRST_BIN" >/dev/null 2>&1; then
    /usr/bin/osascript -e "display alert \"$APP_NAME can't start\" message \"Required binary not found on PATH:\n$FIRST_BIN\""
    exit 1
fi

# --- Pre-flight: node_modules present? ---------------------------------
case "$START_COMMAND" in
    npm\ *|pnpm\ *|yarn\ *|bun\ run*|bunx*|npx*)
        if [ ! -d "$PROJECT_ROOT/node_modules" ]; then
            /usr/bin/osascript -e "display alert \"$APP_NAME can't start\" message \"node_modules is missing in:\n$PROJECT_ROOT\n\nRun 'npm install' (or pnpm/yarn/bun) in that folder, then click again.\""
            exit 1
        fi
        ;;
esac

# --- Stale-state cleanup ----------------------------------------------
if [ -f "$PID_FILE" ]; then
    EXPECTED_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -z "$EXPECTED_PID" ] || ! kill -0 "$EXPECTED_PID" 2>/dev/null; then
        rm -f "$PID_FILE" "$PORT_FILE"
    fi
fi

# --- Reattach to our own existing server (descendant-walk) -----------
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
                NEXT_GEN="$(pgrep -P "$CURRENT" 2>/dev/null | tr '\n' ' ')"
                [ -z "$NEXT_GEN" ] && break
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

# --- Allocate a free port + start server ------------------------------
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

    cd "$PROJECT_ROOT"

    if command -v setsid >/dev/null 2>&1; then
        PORT="$CHOSEN_PORT" setsid bash -c "$START_COMMAND" > "$SERVER_LOG" 2>&1 < /dev/null &
    else
        PORT="$CHOSEN_PORT" nohup bash -c "trap '' HUP; $START_COMMAND" > "$SERVER_LOG" 2>&1 < /dev/null &
    fi
    SERVER_PID=$!
    echo "$SERVER_PID" > "$PID_FILE"
    echo "$CHOSEN_PORT" > "$PORT_FILE"
    disown "$SERVER_PID" 2>/dev/null || true

    URL="http://localhost:$CHOSEN_PORT"

    # Two-stage readiness probe (port-bound → any HTTP).
    READY=0
    for _ in $(seq 1 120); do
        if lsof -i tcp:"$CHOSEN_PORT" >/dev/null 2>&1; then
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
        TAIL="$(tail -40 "$SERVER_LOG" 2>/dev/null | sed 's/"/\\"/g' | tr '\n' ' ' | head -c 800)"
        rm -f "$PID_FILE" "$PORT_FILE"
        /usr/bin/osascript -e "display alert \"$APP_NAME failed to start\" message \"The dev server did not bind to $URL within 60s.\n\nLast log lines:\n$TAIL\""
        exit 1
    fi
fi

URL="http://localhost:$CHOSEN_PORT"

# --- Open in Chrome / Edge / Brave / Arc app-mode ---------------------
CHROME_BIN=""
for browser in \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
    "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" \
    "/Applications/Arc.app/Contents/MacOS/Arc"; do
    if [ -x "$browser" ]; then
        CHROME_BIN="$browser"
        break
    fi
done

if [ -z "$CHROME_BIN" ]; then
    # Last resort — default browser. No chromeless window, FSA support unverified.
    exec open "$URL"
fi

if [ "$KEEP_WARM" = "0" ]; then
    # Don't exec — wait for Chrome to exit, then tear down the daemon.
    "$CHROME_BIN" --app="$URL" --user-data-dir="$PROFILE"
    if [ -f "$PID_FILE" ]; then
        SUPER_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
        [ -n "$SUPER_PID" ] && kill -TERM "$SUPER_PID" 2>/dev/null || true
        for p in $(lsof -ti tcp:"$CHOSEN_PORT" 2>/dev/null); do
            kill -TERM "$p" 2>/dev/null || true
        done
        rm -f "$PID_FILE" "$PORT_FILE"
    fi
    exit 0
else
    # Default: leave the daemon warm; user runs desktop-quit.sh to stop it.
    exec "$CHROME_BIN" --app="$URL" --user-data-dir="$PROFILE"
fi
