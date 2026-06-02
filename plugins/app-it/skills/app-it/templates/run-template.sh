#!/bin/bash
# app-it launcher (Swift WebKit shell variant) — ensures the dev server is up,
# then hands the window over to the native Swift WebKit wrapper that lives next
# to this script. The wrapper takes over as the .app's foreground process, so
# the .app's own Dock icon stays visible and macOS handles single-instance
# activation natively.
#
# This file is a TEMPLATE. desktop-build.sh substitutes:
#   __APP_NAME__       human display name (e.g. "Momó Studio")
#   __APP_SLUG__       file-safe slug (e.g. "momo-studio")
#   __PROJECT_ROOT__   absolute path to the repo (baked at build time)
#   __PORT__           PREFERRED port — the launcher tries this first; if it's
#                      already in use, the launcher scans upward [PORT..PORT+50]
#                      for a free port and uses that. Sibling appified apps
#                      coexist without coordination.
#   __START_COMMAND__  the command to start the dev server, run from PROJECT_ROOT.
#                      Must honor the PORT env var. Most dev servers do
#                      (vite, next, express, flask, CRA, …). Vite needs the
#                      port via CLI: `npm run dev -- --port "$PORT"`. If your
#                      command hardcodes a port literal in `package.json`
#                      scripts (`"dev": "next dev -p 3002"`), the launcher's
#                      chosen port will be ignored — bypass via direct binary
#                      (`pnpm exec next dev`) or add a `dev:app-it` script.
#   __POLYFILL_PATH__  optional absolute path to a JS polyfill file (empty if none)
#
# PROJECT_ROOT is baked at build time. Honors APP_IT_PROJECT_ROOT env override
# at build time (for worktree workflows). Re-run desktop:build if the repo moves.

set -e

APP_NAME="__APP_NAME__"
APP_SLUG="__APP_SLUG__"
PROJECT_ROOT="__PROJECT_ROOT__"
PREFERRED_PORT=__PORT__
START_COMMAND="__START_COMMAND__"
POLYFILL_PATH="__POLYFILL_PATH__"

STATE_DIR="$HOME/Library/Application Support/app-it/$APP_SLUG"
LOG_DIR="$HOME/Library/Logs/app-it/$APP_SLUG"
mkdir -p "$STATE_DIR" "$LOG_DIR"
SERVER_LOG="$LOG_DIR/server.log"
PID_FILE="$STATE_DIR/server.pid"
PORT_FILE="$STATE_DIR/server.port"
INSTALL_LOG="$LOG_DIR/install.log"

HERE="$(cd "$(dirname "$0")" && pwd)"

# --- PATH augmentation -------------------------------------------------
# Finder/Dock launches start with bare PATH=/usr/bin:/bin. Cover every
# common version-manager / language-toolchain bin path. Each entry is a
# no-op when the directory doesn't exist (PATH lookups silently skip).
NVM_BIN=""
if [ -d "$HOME/.nvm/versions/node" ]; then
    LATEST_NVM_NODE="$(ls -1 "$HOME/.nvm/versions/node" 2>/dev/null | sort -V | tail -1)"
    [ -n "$LATEST_NVM_NODE" ] && NVM_BIN="$HOME/.nvm/versions/node/$LATEST_NVM_NODE/bin"
fi
export PATH="$HOME/.bun/bin:$HOME/.deno/bin:$HOME/.volta/bin:$HOME/.local/share/mise/shims:$HOME/.asdf/shims:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:${NVM_BIN}:$HOME/Library/pnpm:$PATH"

# --- Project-root sanity ------------------------------------------------
if [ ! -d "$PROJECT_ROOT" ]; then
    /usr/bin/osascript -e "display alert \"$APP_NAME failed to launch\" message \"Project repo not found at:\n$PROJECT_ROOT\n\nThe .app was built against a path that no longer exists (worktree pruned, repo moved). Re-run desktop:build from the canonical repo location.\""
    exit 1
fi

# --- Pre-flight: required binary present? ------------------------------
# Catch missing-binary failures (bun not on PATH, pnpm not installed,
# python missing) in <1s instead of waiting 60s for the readiness probe
# to time out into a misleading "port literal hardcoded?" alert. If the
# command starts with a directory hop (`cd web && npm run dev`), validate
# the actual runner instead of the shell builtin.
COMMAND_ROOT="$PROJECT_ROOT"
COMMAND_TO_RUN="$START_COMMAND"
case "$COMMAND_TO_RUN" in
    cd\ *\ \&\&\ *)
        COMMAND_SUBDIR="${COMMAND_TO_RUN#cd }"
        COMMAND_SUBDIR="${COMMAND_SUBDIR%% &&*}"
        COMMAND_SUBDIR="${COMMAND_SUBDIR%\"}"
        COMMAND_SUBDIR="${COMMAND_SUBDIR#\"}"
        COMMAND_SUBDIR="${COMMAND_SUBDIR%\'}"
        COMMAND_SUBDIR="${COMMAND_SUBDIR#\'}"
        COMMAND_ROOT="$PROJECT_ROOT/$COMMAND_SUBDIR"
        COMMAND_TO_RUN="${COMMAND_TO_RUN#* && }"
        ;;
esac
FIRST_BIN="$(echo "$COMMAND_TO_RUN" | awk '{print $1}')"
if [ -n "$FIRST_BIN" ] && ! command -v "$FIRST_BIN" >/dev/null 2>&1; then
    /usr/bin/osascript -e "display alert \"$APP_NAME can't start\" message \"Required binary not found on PATH:\n$FIRST_BIN\n\nThe launcher's PATH covers Homebrew, nvm, pnpm-store, Bun, Deno, Volta, mise, asdf, cargo. Install the missing tool or adjust START_COMMAND.\""
    exit 1
fi

# --- Pre-flight: node_modules present? ---------------------------------
# Only check if START_COMMAND is a node-package-manager invocation.
case "$COMMAND_TO_RUN" in
    npm\ *|pnpm\ *|yarn\ *|bun\ run*|bunx*|npx*)
        if [ ! -d "$COMMAND_ROOT/node_modules" ]; then
            /usr/bin/osascript -e "display alert \"$APP_NAME can't start\" message \"node_modules is missing in:\n$COMMAND_ROOT\n\nRun 'npm install' (or pnpm/yarn/bun) in that folder, then click again.\""
            exit 1
        fi
        ;;
esac

# --- Stale-state cleanup ----------------------------------------------
# If the recorded server PID is dead, scrap both PID and PORT files.
if [ -f "$PID_FILE" ]; then
    EXPECTED_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -z "$EXPECTED_PID" ] || ! kill -0 "$EXPECTED_PID" 2>/dev/null; then
        rm -f "$PID_FILE" "$PORT_FILE"
    fi
fi

# --- Reattach to our own existing server ------------------------------
# Permissive ownership-tree gate (F38 fix). The recorded PID is treated
# as the ROOT of an ownership tree — the actual TCP listener may be a
# child/grandchild/great-grandchild (e.g. `pnpm dev` → `node` →
# `next-server` worker). Strict PID-equality match (`grep -qx PID`)
# silently failed for the most common JS dev stack.
#
# Reattach only when ALL hold:
#   1. Recorded supervisor PID is alive
#   2. Some process is bound to the recorded port
#   3. That listener is in our supervisor's descendant tree
#      (anti-passive-attach: don't attach to non-our-server)
#   4. The server is responding HTTP (any status)
CHOSEN_PORT=""
if [ -f "$PID_FILE" ] && [ -f "$PORT_FILE" ]; then
    EXPECTED_PID="$(cat "$PID_FILE")"
    EXPECTED_PORT="$(cat "$PORT_FILE")"
    REATTACH_OK=0

    if kill -0 "$EXPECTED_PID" 2>/dev/null; then
        LISTENERS="$(lsof -ti tcp:"$EXPECTED_PORT" 2>/dev/null || true)"
        if [ -n "$LISTENERS" ]; then
            # Walk descendants up to 4 levels (pnpm → node → node → next-server).
            DESCENDANTS="$EXPECTED_PID"
            CURRENT="$EXPECTED_PID"
            for _ in 1 2 3 4; do
                # Expand one PID per pgrep call. macOS `pgrep -P` returns nothing
                # for a space-joined / trailing-space argument, so passing the
                # whole generation at once would silently halt the walk at the
                # first level and miss deeper listeners (npm → node-vite,
                # pnpm → node → next-server). Walk per-pid so each call is clean.
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
            # HTTP responding? (any status counts — wrapper shows the page)
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
    # Scan from PREFERRED_PORT upward for the first free port.
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

    # setsid detaches the dev server from the wrapper's process group so
    # SIGHUP propagation can't kill the daemonized tree when the wrapper
    # exits. macOS 12+ has /usr/bin/setsid; fall back to nohup+disown
    # plus an explicit `trap '' HUP` block on older systems.
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

    # Two-stage readiness probe.
    # Stage 1: port is bound (any process listening counts).
    READY=0
    for _ in $(seq 1 120); do
        if lsof -i tcp:"$CHOSEN_PORT" >/dev/null 2>&1; then
            READY=1
            break
        fi
        sleep 0.5
    done

    # Stage 2: server returns *any* HTTP status (drop -f). 5xx counts —
    # the user sees the real error in the wrapper window, which beats a
    # 60-second timeout into a misleading alert.
    if [ "$READY" = "1" ]; then
        READY=0
        for _ in $(seq 1 120); do
            STATUS="$(curl -sS -o /dev/null --max-time 1 -w "%{http_code}" "$URL" 2>/dev/null || true)"
            if [ -n "$STATUS" ] && [ "$STATUS" != "000" ]; then
                READY=1
                # Soft-note 5xx in the launcher log — server is up, the page may
                # be broken but that's a project-state issue (missing data file,
                # auth failure, etc.). The wrapper still loads it so the user
                # can see the actual error.
                if [ "${STATUS:0:1}" = "5" ]; then
                    echo "$(date) — server up at $URL but returning HTTP $STATUS — see app's log for details" >> "$SERVER_LOG"
                fi
                break
            fi
            sleep 0.5
        done
    fi

    if [ "$READY" != "1" ]; then
        TAIL="$(tail -40 "$SERVER_LOG" 2>/dev/null | sed 's/"/\\"/g' | tr '\n' ' ' | head -c 800)"
        rm -f "$PID_FILE" "$PORT_FILE"
        /usr/bin/osascript -e "display alert \"$APP_NAME failed to start\" message \"The dev server did not bind to $URL within 60 seconds.\n\nCheck $SERVER_LOG for the cause. Common ones:\n• Missing dependencies (run package-manager install in the repo)\n• Port literal hardcoded in START_COMMAND or framework config\n• Server crashed during startup\n\nLast log lines:\n$TAIL\""
        exit 1
    fi
fi

URL="http://localhost:$CHOSEN_PORT"

# --- Headless smoke seam (CI / SSH / --check) --------------------------
# Everything a real Dock click does has now run EXCEPT opening the window:
# the dev server is up, daemonized, reachable, and its pid/port are recorded.
# With APP_IT_SMOKE set, print the runtime URL and exit 0 instead of handing
# off to the GUI wrapper. The server stays warm so the caller can probe it
# (curl, desktop:doctor) and then stop it (desktop:quit). Zero effect on a
# normal Dock launch (APP_IT_SMOKE unset).
if [ -n "${APP_IT_SMOKE:-}" ]; then
    echo "app-it smoke: $APP_NAME ready at $URL (server pid $(cat "$PID_FILE" 2>/dev/null))"
    exit 0
fi

# --- Hand off to the native WebKit wrapper -----------------------------
# exec replaces this bash process with the Swift binary. The .app's identity
# stays intact (CFBundleIdentifier from Info.plist), so the Dock keeps showing
# OUR icon — not Chrome's, not Safari's.
WRAPPER="$HERE/wrapper"
if [ ! -x "$WRAPPER" ]; then
    /usr/bin/osascript -e "display alert \"$APP_NAME failed to launch\" message \"Native wrapper missing at:\n$WRAPPER\n\nRun desktop:build to rebuild the bundle.\""
    exit 1
fi

exec "$WRAPPER" "$URL" "$APP_NAME" "$CHOSEN_PORT" "$PID_FILE" "$POLYFILL_PATH"
