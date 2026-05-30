#!/bin/bash
# Generates AppIcon.icns from assets/<slug>-icon.{png,svg} for one app.
#
# v2 behavior:
#   1. Normalizes any source via `sips -s format png` first — JPEG bytes in
#      a .png-extension file would otherwise pass `sips -z` with warnings
#      and fail at `iconutil -c icns` with a cryptic "Failed to generate
#      ICNS." This forces real PNG bytes regardless of the source's claim.
#   2. Mtime-aware: skip regen when $ICNS is newer than the source file.
#      When the source is newer, also clear the resize-tree at $OUT_DIR
#      because `desktop-icons.sh` short-circuits the iconset regen when
#      resized PNGs already exist there.
#   3. Honors APP_IT_PROJECT_ROOT (worktree workflow); helper script lives
#      next to desktop-build.sh, project artifacts go to APP_IT_PROJECT_ROOT.
#
# Required env: APP_NAME, APP_SLUG. APP_NAME may include non-ASCII.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${APP_IT_PROJECT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

APP_NAME="${APP_NAME:?must set APP_NAME (e.g. 'Momó Studio')}"
APP_SLUG="${APP_SLUG:?must set APP_SLUG (e.g. 'momo-studio')}"

# Per-app icon, falling back to repo-wide app-icon.*
SRC_PNG=""
for candidate in "$ROOT/assets/${APP_SLUG}-icon.png" "$ROOT/assets/app-icon.png"; do
    [ -f "$candidate" ] && SRC_PNG="$candidate" && break
done
SRC_SVG=""
for candidate in "$ROOT/assets/${APP_SLUG}-icon.svg" "$ROOT/assets/app-icon.svg"; do
    [ -f "$candidate" ] && SRC_SVG="$candidate" && break
done

if [ -z "$SRC_PNG" ] && [ -z "$SRC_SVG" ]; then
    echo "No source icon for $APP_SLUG" >&2
    echo "  Looked at: assets/${APP_SLUG}-icon.{png,svg}, assets/app-icon.{png,svg}" >&2
    echo "  Run scripts/placeholder-icon-gen.sh to create one, or drop a 1024×1024 PNG/SVG at one of those paths." >&2
    exit 1
fi

OUT_DIR="$ROOT/assets/icons/$APP_SLUG"
ICONSET="$OUT_DIR/AppIcon.iconset"
ICNS="$ROOT/desktop/${APP_NAME}.app/Contents/Resources/AppIcon.icns"

# Identify the canonical source for mtime comparison.
SOURCE_REF=""
if [ -n "$SRC_PNG" ]; then
    SOURCE_REF="$SRC_PNG"
elif [ -n "$SRC_SVG" ]; then
    SOURCE_REF="$SRC_SVG"
fi

# --- Mtime-aware short-circuit ----------------------------------------
# If the .icns is newer than the source, the icon already reflects the
# current source — skip the work. The desktop-build.sh wrapper invokes
# us unconditionally; we decide whether anything actually needs doing.
if [ -f "$ICNS" ] && [ "$ICNS" -nt "$SOURCE_REF" ]; then
    echo "Icon up-to-date: $ICNS"
    exit 0
fi

# Source changed — clear the resize-tree so the iconset regen actually
# runs. `cp` does not overwrite directory entries based on mtime alone,
# so leftover icon_<size>.png files would short-circuit the rebuild.
mkdir -p "$OUT_DIR" "$(dirname "$ICNS")"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# --- Normalize source to real PNG bytes -------------------------------
# JPEG-in-PNG-extension files would otherwise pass `sips -z` with warnings
# and break iconutil. `sips -s format png` re-encodes regardless of input.
if [ -n "$SRC_PNG" ]; then
    NORMALIZED="$OUT_DIR/source-normalized.png"
    if ! sips -s format png "$SRC_PNG" --out "$NORMALIZED" >/dev/null 2>&1; then
        echo "Source is not a recognizable image: $SRC_PNG" >&2
        echo "  file says: $(file -b "$SRC_PNG")" >&2
        exit 1
    fi
    SOURCE="$NORMALIZED"
elif [ -n "$SRC_SVG" ]; then
    SOURCE="$OUT_DIR/source-1024.png"
    if command -v rsvg-convert >/dev/null; then
        rsvg-convert -w 1024 -h 1024 "$SRC_SVG" -o "$SOURCE"
    elif command -v magick >/dev/null; then
        magick -background none -density 300 "$SRC_SVG" -resize 1024x1024 "$SOURCE"
    else
        sips -s format png -Z 1024 "$SRC_SVG" --out "$SOURCE" >/dev/null
    fi
fi

# Pre-scale to a clean 1024 master so iconset entries up-/down-sample identically.
MASTER="$OUT_DIR/icon_1024.png"
sips -z 1024 1024 "$SOURCE" --out "$MASTER" >/dev/null

for size in 16 32 64 128 256 512; do
    sips -z "$size" "$size" "$MASTER" --out "$OUT_DIR/icon_${size}.png" >/dev/null
done

cp "$OUT_DIR/icon_16.png"   "$ICONSET/icon_16x16.png"
cp "$OUT_DIR/icon_32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$OUT_DIR/icon_32.png"   "$ICONSET/icon_32x32.png"
cp "$OUT_DIR/icon_64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$OUT_DIR/icon_128.png"  "$ICONSET/icon_128x128.png"
cp "$OUT_DIR/icon_256.png"  "$ICONSET/icon_128x128@2x.png"
cp "$OUT_DIR/icon_256.png"  "$ICONSET/icon_256x256.png"
cp "$OUT_DIR/icon_512.png"  "$ICONSET/icon_256x256@2x.png"
cp "$OUT_DIR/icon_512.png"  "$ICONSET/icon_512x512.png"
cp "$OUT_DIR/icon_1024.png" "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$ICNS"
echo "Generated: $ICNS"
