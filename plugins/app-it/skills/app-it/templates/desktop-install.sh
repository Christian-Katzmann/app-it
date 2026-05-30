#!/bin/bash
# Copies every desktop/*.app into ~/Applications/App It/ (or APP_IT_INSTALL_DIR).
# That folder can live as a Dock Stack — drag it to the right side of the Dock
# once and every appified app appears there automatically.
#
# v2 behavior:
#   1. Honors APP_IT_PROJECT_ROOT (worktree workflow).
#   2. After install, deregisters the build-location bundle from
#      LaunchServices and re-registers the install copy. Without this,
#      both bundles would claim the same CFBundleIdentifier and `open`
#      may resolve to the wrong copy after rebuilds.
#   3. Conditionally invokes `killall Dock` only when the AppIcon.icns
#      hash changed — Dock auto-respawns in <1s and the user only
#      notices a Dock flicker on no-icon-change rebuilds, so we gate.
#      This fixes "user replaced icon, Dock still shows old one."

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${APP_IT_PROJECT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

TARGET="${APP_IT_INSTALL_DIR:-$HOME/Applications/App It}"

if [ ! -d "$TARGET" ]; then
    if [ "$TARGET" = "$HOME/Applications/App It" ]; then
        mkdir -p "$TARGET"
        echo "Created $TARGET."
        echo "Drag this folder to the right side of your Dock once,"
        echo "and every future appified app will appear in its Dock Stack automatically."
    else
        echo "Install target $TARGET does not exist." >&2
        exit 1
    fi
fi

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

shopt -s nullglob
count=0
icon_changed=0
for app in "$ROOT/desktop"/*.app; do
    name="$(basename "$app")"
    INSTALL_PATH="$TARGET/$name"

    # Capture old icon hash (if any) so we can decide whether to kill Dock.
    OLD_HASH=""
    if [ -f "$INSTALL_PATH/Contents/Resources/AppIcon.icns" ]; then
        OLD_HASH="$(shasum -a 256 "$INSTALL_PATH/Contents/Resources/AppIcon.icns" 2>/dev/null | awk '{print $1}')"
    fi

    rm -rf "$INSTALL_PATH"
    cp -R "$app" "$INSTALL_PATH"
    # Re-bless modification time so Finder refreshes its icon cache.
    touch "$INSTALL_PATH"

    # iCloud-synced folders (Desktop/Documents, or custom install targets)
    # can write com.apple.FinderInfo into bundle subdirs — that taints any
    # code signature ("resource fork, Finder information, or similar
    # detritus") and trips Gatekeeper on
    # macOS 15+ ("X can't be opened"). Strip xattrs and re-apply the
    # ad-hoc signature at the install location.
    /usr/bin/xattr -cr "$INSTALL_PATH" 2>/dev/null || true
    /usr/bin/codesign --force --deep --sign - "$INSTALL_PATH" >/dev/null 2>&1 || true

    # Compare new icon hash.
    NEW_HASH="$(shasum -a 256 "$INSTALL_PATH/Contents/Resources/AppIcon.icns" 2>/dev/null | awk '{print $1}')"
    if [ -n "$NEW_HASH" ] && [ "$OLD_HASH" != "$NEW_HASH" ]; then
        icon_changed=1
    fi

    # Deregister build-location bundle (avoid duplicate registration), then
    # re-register the install copy.
    if [ -x "$LSREGISTER" ]; then
        "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true
        "$LSREGISTER" -f "$INSTALL_PATH" >/dev/null 2>&1 || true
    fi

    echo "Installed: $INSTALL_PATH"
    count=$((count + 1))
done

if [ "$count" -eq 0 ]; then
    echo "No .app bundles found under $ROOT/desktop/. Run desktop-build.sh first." >&2
    exit 1
fi

# Force Finder + Dock to re-read the bundle's icon ONLY when the icon
# actually changed. cp + touch alone is not enough on macOS — Finder
# caches icon thumbnails per-bundle and Dock caches its render targets
# independently. killall Dock is harmless (Dock auto-respawns in <1s)
# but we gate to avoid Dock flicker on routine non-icon rebuilds.
if [ "$icon_changed" = "1" ]; then
    killall Dock 2>/dev/null || true
    echo "(Refreshed Dock — icon bytes changed.)"
fi
