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
#   4. Skips unchanged installs unless APP_IT_FORCE_INSTALL=1 is set. Rewriting,
#      touching, signing, and LaunchServices-registering an identical .app wakes
#      macOS security/indexing work for no user-visible gain.

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
FINGERPRINT_DIR="$TARGET/.app-it-fingerprints"

fingerprint_bundle() {
    /usr/bin/python3 - "$1" <<'PY'
import hashlib
import os
import stat
import sys

root = sys.argv[1]
h = hashlib.sha256()

for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
    dirnames.sort()
    filenames.sort()
    rel_dir = os.path.relpath(dirpath, root)
    if rel_dir == ".":
        rel_dir = ""
    for name in filenames:
        path = os.path.join(dirpath, name)
        rel = os.path.join(rel_dir, name) if rel_dir else name
        if rel.startswith("Contents/_CodeSignature/"):
            continue
        st = os.lstat(path)
        mode = stat.S_IMODE(st.st_mode)
        h.update(rel.encode("utf-8", "surrogateescape"))
        h.update(b"\0")
        h.update(str(mode).encode())
        h.update(b"\0")
        if stat.S_ISLNK(st.st_mode):
            h.update(b"symlink\0")
            h.update(os.readlink(path).encode("utf-8", "surrogateescape"))
            h.update(b"\0")
            continue
        if stat.S_ISREG(st.st_mode):
            h.update(b"file\0")
            with open(path, "rb") as f:
                for chunk in iter(lambda: f.read(1024 * 1024), b""):
                    h.update(chunk)
            h.update(b"\0")

print(h.hexdigest())
PY
}

shopt -s nullglob
count=0
icon_changed=0
for app in "$ROOT/desktop"/*.app; do
    name="$(basename "$app")"
    INSTALL_PATH="$TARGET/$name"
    FINGERPRINT_FILE="$FINGERPRINT_DIR/$name.sha256"
    SOURCE_FINGERPRINT="$(fingerprint_bundle "$app" 2>/dev/null || true)"

    # Capture old icon hash (if any) so we can decide whether to kill Dock.
    OLD_HASH=""
    if [ -f "$INSTALL_PATH/Contents/Resources/AppIcon.icns" ]; then
        OLD_HASH="$(shasum -a 256 "$INSTALL_PATH/Contents/Resources/AppIcon.icns" 2>/dev/null | awk '{print $1}')"
    fi

    if [ "${APP_IT_FORCE_INSTALL:-0}" != "1" ] \
        && [ -n "$SOURCE_FINGERPRINT" ] \
        && [ -d "$INSTALL_PATH" ] \
        && [ -f "$FINGERPRINT_FILE" ] \
        && [ "$(cat "$FINGERPRINT_FILE" 2>/dev/null || true)" = "$SOURCE_FINGERPRINT" ]; then
        echo "Already current: $INSTALL_PATH"
        count=$((count + 1))
        continue
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

    if [ -n "$SOURCE_FINGERPRINT" ]; then
        mkdir -p "$FINGERPRINT_DIR"
        printf '%s\n' "$SOURCE_FINGERPRINT" > "$FINGERPRINT_FILE"
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
# Set APP_IT_REFRESH_DOCK=0 during unattended installs or to preserve the Dock.
if [ "$icon_changed" = "1" ] && [ "${APP_IT_REFRESH_DOCK:-1}" = "1" ]; then
    killall Dock 2>/dev/null || true
    echo "(Refreshed Dock — icon bytes changed.)"
fi
