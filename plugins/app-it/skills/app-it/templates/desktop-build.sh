#!/bin/bash
# Builds desktop/<AppName>.app bundle(s) for every entry in scripts/app-it.config.json
# (or, for backward compat, a bash APPS=(...) array below). Idempotent.
#
# This file is a TEMPLATE. The agent customizes app-it.config.json (preferred)
# and chooses the launcher mode (swift|chrome) by editing the file or setting
# APP_IT_LAUNCHER_MODE in the environment.
#
# Worktree-aware: ROOT honors APP_IT_PROJECT_ROOT env (build from worktree,
# bake the canonical persistent path). Without it, ROOT is derived from
# this script's location (the repo it was copied into).
#
# app-it.config.json shape:
# {
#   "apps": [
#     {
#       "name": "Momó Studio",
#       "slug": "momo-studio",
#       "port": 5173,
#       "start_command": "npm run dev -- --port $PORT",
#       "bundle_id": "com.user.momo-studio",
#       "version": "0.1.0",
#       "polyfill_path": "",
#       "backend_port": null,                  // optional, A3.2 multi-server
#       "backend_start_command": null          // optional, A3.2 multi-server
#     }
#   ]
# }
#
# Single source of truth — desktop-quit.sh reads the same file.

set -euo pipefail

# Worktree workflow: APP_IT_PROJECT_ROOT overrides the auto-derived path.
# Helper scripts (icons, install, quit) live next to this script — those
# stay relative to $0. Only PROJECT_ROOT-baked-into-runtime is overridden.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${APP_IT_PROJECT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export APP_IT_PROJECT_ROOT="$ROOT"

CONFIG_FILE="$SCRIPT_DIR/app-it.config.json"

# --- Load apps from JSON (preferred) or bash APPS array (backward compat) ----
APPS=()
if [ -f "$CONFIG_FILE" ]; then
    # Convert each app to pipe-delimited internal record.
    # Format: name|slug|port|start_command|bundle_id|version|polyfill_path|backend_port|backend_start_command
    while IFS= read -r line; do
        [ -n "$line" ] && APPS+=("$line")
    done < <(/usr/bin/python3 - "$CONFIG_FILE" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    cfg = json.load(f)
for a in cfg.get("apps", []):
    fields = [
        a.get("name", ""),
        a.get("slug", ""),
        str(a.get("port", "")),
        a.get("start_command", ""),
        a.get("bundle_id", ""),
        a.get("version", "0.1.0"),
        a.get("polyfill_path", ""),
        str(a.get("backend_port") or ""),
        a.get("backend_start_command") or "",
    ]
    # Reject any field containing pipe — would corrupt parsing.
    if any("|" in f for f in fields):
        print("ERROR: pipe character in field — refusing to build", file=sys.stderr)
        sys.exit(1)
    print("|".join(fields))
PY
)
else
    echo "Note: scripts/app-it.config.json not found — falling back to bash APPS array." >&2
    echo "      Recommended: copy templates/app-it.config.example.json to scripts/." >&2
    APPS=(
      # Replace these with your apps. One line per app.
      # Format: name|slug|port|start_command|bundle_id|version|polyfill_path|backend_port|backend_start_command
      "__APP_NAME__|__APP_SLUG__|__PORT__|__START_COMMAND__|__BUNDLE_ID__|__VERSION__|__POLYFILL_PATH_ENTRY__||"
    )
fi

if [ "${#APPS[@]}" -eq 0 ]; then
    echo "ERROR: no apps configured. Edit scripts/app-it.config.json." >&2
    exit 1
fi

# --- Bundle-ID validation -----------------------------------------------
# Reject com.$(id -un).* — LaunchServices treats this as a personal-team
# developer prefix and may refuse unsigned bundles claiming that team
# identity with `_LSOpenURLs… error -600 / procNotFound`. The failure
# is non-deterministic across macOS versions and iCloud xattr state,
# so the safest answer is to never use the prefix at all.
USER_PREFIX="com.$(id -un | tr 'A-Z' 'a-z')."
for entry in "${APPS[@]}"; do
    IFS='|' read -r _ _ _ _ BID _ _ _ _ <<<"$entry"
    BID_LOWER="$(echo "$BID" | tr 'A-Z' 'a-z')"
    case "$BID_LOWER" in
        "$USER_PREFIX"*)
            echo "WARN: bundle_id '$BID' starts with com.\$(id -un). LaunchServices may reject it (error -600). Prefer com.user.<slug> or country-coded reverse-DNS." >&2
            ;;
    esac
done

# --- Launcher mode -----------------------------------------------------
LAUNCHER_MODE="${APP_IT_LAUNCHER_MODE:-swift}"
if [ "$LAUNCHER_MODE" = "swift" ] && ! command -v swiftc >/dev/null 2>&1; then
    echo "swiftc not found — falling back to Chrome --app launcher." >&2
    echo "(Install Xcode Command Line Tools: xcode-select --install)" >&2
    LAUNCHER_MODE="chrome"
fi

PLIST_TEMPLATE="$SCRIPT_DIR/info-plist-template.xml"
WRAPPER_SRC="$SCRIPT_DIR/wrapper.swift"
WRAPPER_BUILD="$ROOT/assets/icons/build/wrapper"

if [ "$LAUNCHER_MODE" = "swift" ]; then
    RUN_TEMPLATE_SINGLE="$SCRIPT_DIR/run-template.sh"
else
    RUN_TEMPLATE_SINGLE="$SCRIPT_DIR/run-template-chrome.sh"
fi
RUN_TEMPLATE_MULTI="$SCRIPT_DIR/run-template-multiserver.sh"

if [ ! -f "$RUN_TEMPLATE_SINGLE" ] || [ ! -f "$PLIST_TEMPLATE" ]; then
    echo "Missing templates next to this script. Expected:" >&2
    echo "  $RUN_TEMPLATE_SINGLE" >&2
    echo "  $PLIST_TEMPLATE" >&2
    exit 1
fi

# --- Compile the native WebKit wrapper (cached, universal) -------------
# Build arm64 + x86_64 by default and lipo into a universal binary, so the
# wrapper runs on both Apple Silicon and Intel Macs. APP_IT_SWIFT_ARCHS
# overrides ("arm64,x86_64", "arm64", "x86_64").
if [ "$LAUNCHER_MODE" = "swift" ]; then
    if [ ! -f "$WRAPPER_SRC" ]; then
        echo "Missing wrapper source: $WRAPPER_SRC" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$WRAPPER_BUILD")"

    SWIFT_ARCHS="${APP_IT_SWIFT_ARCHS:-arm64,x86_64}"
    NEEDS_REBUILD=0
    if [ ! -x "$WRAPPER_BUILD" ] || [ "$WRAPPER_SRC" -nt "$WRAPPER_BUILD" ]; then
        NEEDS_REBUILD=1
    fi

    if [ "$NEEDS_REBUILD" = "1" ]; then
        echo "Compiling native wrapper: $WRAPPER_BUILD ($SWIFT_ARCHS)"
        IFS=',' read -r -a ARCH_LIST <<<"$SWIFT_ARCHS"
        ARCH_BINS=()
        for arch in "${ARCH_LIST[@]}"; do
            arch_clean="$(echo "$arch" | tr -d ' ')"
            BIN="$WRAPPER_BUILD.$arch_clean"
            if swiftc -O "$WRAPPER_SRC" \
                -o "$BIN" \
                -framework Cocoa -framework WebKit \
                -target "$arch_clean-apple-macosx11" 2>/dev/null; then
                ARCH_BINS+=("$BIN")
            else
                echo "WARN: swiftc target $arch_clean failed — skipping (toolchain may not have SDK)." >&2
            fi
        done

        if [ "${#ARCH_BINS[@]}" -eq 0 ]; then
            # Last resort: build for host arch with no -target.
            echo "All targeted archs failed — building for host arch only." >&2
            swiftc -O "$WRAPPER_SRC" -o "$WRAPPER_BUILD" -framework Cocoa -framework WebKit
        elif [ "${#ARCH_BINS[@]}" -eq 1 ]; then
            mv "${ARCH_BINS[0]}" "$WRAPPER_BUILD"
        else
            lipo -create "${ARCH_BINS[@]}" -output "$WRAPPER_BUILD"
            rm -f "${ARCH_BINS[@]}"
        fi
    fi
fi

# --- Substitution helper -----------------------------------------------
# Strips a TEMPLATE-DOCS block before substitution so placeholder examples
# inside header comments don't leak substituted values into the built
# artifact. Templates may bracket their docs with:
#     ### TEMPLATE-DOCS-START
#     (header comments referencing __APP_NAME__ etc. for human readers)
#     ### TEMPLATE-DOCS-END
substitute() {
    /usr/bin/python3 - "$@" <<'PY'
import sys, pathlib, re
src = pathlib.Path(sys.argv[1]).read_text()
src = re.sub(r"### TEMPLATE-DOCS-START.*?### TEMPLATE-DOCS-END\n?", "", src, flags=re.DOTALL)
for arg in sys.argv[2:]:
    key, _, value = arg.partition("=")
    src = src.replace(key, value)
sys.stdout.write(src)
PY
}

# --- Build each app -----------------------------------------------------
for entry in "${APPS[@]}"; do
    IFS='|' read -r APP_NAME APP_SLUG PORT START_COMMAND BUNDLE_ID VERSION POLYFILL_PATH BACKEND_PORT BACKEND_START_COMMAND <<<"$entry"
    POLYFILL_PATH="${POLYFILL_PATH//@ROOT@/$ROOT}"

    APP_DIR="$ROOT/desktop/${APP_NAME}.app"
    CONTENTS="$APP_DIR/Contents"
    MACOS="$CONTENTS/MacOS"
    RESOURCES="$CONTENTS/Resources"

    echo "Building: $APP_DIR"
    mkdir -p "$MACOS" "$RESOURCES"

    # Pick template — multi-server if backend fields are populated and
    # the multi-server template exists.
    if [ -n "$BACKEND_PORT" ] && [ -n "$BACKEND_START_COMMAND" ] && [ -f "$RUN_TEMPLATE_MULTI" ]; then
        SELECTED_RUN_TEMPLATE="$RUN_TEMPLATE_MULTI"
        IS_MULTI=1
    else
        SELECTED_RUN_TEMPLATE="$RUN_TEMPLATE_SINGLE"
        IS_MULTI=0
    fi

    substitute "$PLIST_TEMPLATE" \
        "__APP_NAME__=$APP_NAME" \
        "__BUNDLE_ID__=$BUNDLE_ID" \
        "__VERSION__=$VERSION" \
        > "$CONTENTS/Info.plist"

    if [ "$IS_MULTI" = "1" ]; then
        substitute "$SELECTED_RUN_TEMPLATE" \
            "__APP_NAME__=$APP_NAME" \
            "__APP_SLUG__=$APP_SLUG" \
            "__PROJECT_ROOT__=$ROOT" \
            "__PORT__=$PORT" \
            "__START_COMMAND__=$START_COMMAND" \
            "__BACKEND_PORT__=$BACKEND_PORT" \
            "__BACKEND_START_COMMAND__=$BACKEND_START_COMMAND" \
            "__POLYFILL_PATH__=$POLYFILL_PATH" \
            > "$MACOS/run"
    else
        substitute "$SELECTED_RUN_TEMPLATE" \
            "__APP_NAME__=$APP_NAME" \
            "__APP_SLUG__=$APP_SLUG" \
            "__PROJECT_ROOT__=$ROOT" \
            "__PORT__=$PORT" \
            "__START_COMMAND__=$START_COMMAND" \
            "__POLYFILL_PATH__=$POLYFILL_PATH" \
            > "$MACOS/run"
    fi
    chmod +x "$MACOS/run"

    if [ "$LAUNCHER_MODE" = "swift" ]; then
        cp "$WRAPPER_BUILD" "$MACOS/wrapper"
        chmod +x "$MACOS/wrapper"
    fi

    # Always invoke desktop-icons.sh — the script itself is mtime-aware
    # and short-circuits when nothing changed. Don't gate on `if [ ! -f .icns ]`
    # here — that gate caused users to see stale icons after replacing
    # the source PNG.
    APP_NAME="$APP_NAME" APP_SLUG="$APP_SLUG" "$SCRIPT_DIR/desktop-icons.sh"

    # Touch the bundle so Finder picks up changes (icon cache).
    touch "$APP_DIR"

    # --- Ad-hoc code signature ----------------------------------------
    # macOS 15+ (Sequoia/Tahoe) Gatekeeper rejects unsigned apps when
    # launched from Finder/Dock with "X can't be opened" — even when
    # there's no quarantine flag. An ad-hoc (self) signature satisfies
    # the "must be signed" check without requiring an Apple Developer
    # ID. Strip xattrs first because synced folders can write
    # com.apple.FinderInfo into bundle dirs, and codesign refuses with
    # "resource fork, Finder information, or similar detritus not allowed".
    /usr/bin/xattr -cr "$APP_DIR" 2>/dev/null || true
    if ! /usr/bin/codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1; then
        echo "  WARN: codesign --sign - failed for $APP_DIR (app may be blocked by Gatekeeper)" >&2
    fi
done

echo
echo "Built ${#APPS[@]} app(s) under $ROOT/desktop/  (mode: $LAUNCHER_MODE)"
echo "  Install:  ./scripts/desktop-install.sh    # copies to ~/Applications/App It/, refreshes Dock"
