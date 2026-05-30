#!/bin/bash
# Last-resort placeholder icon generator. Produces assets/<slug>-icon.svg
# (or .png) when no usable square brand mark exists in the project.
#
# Strategy menu (in priority order):
#   1. Brand-token-derived SVG: parse globals.css / tailwind.config for
#      --color-* custom properties, pick deepest background + strongest
#      accent, write a 30-line geometric mark. Brand-aligned by construction.
#   2. Monogram fallback: first letter of APP_NAME on a brand-colored
#      background. Used only when no CSS tokens are found.
#
# Usage:
#   APP_NAME="My App" APP_SLUG="my-app" ./placeholder-icon-gen.sh
#   APP_NAME="My App" APP_SLUG="my-app" MOTIF="rings" ./placeholder-icon-gen.sh
#   APP_NAME="My App" APP_SLUG="my-app" ACCENT="#c8a44e" VOID="#08080a" ./placeholder-icon-gen.sh
#
# Optional env:
#   MOTIF   = "rings" | "monogram" | "grid" (default: rings)
#   ACCENT  = override accent color (e.g. "#c8a44e")
#   VOID    = override background color (e.g. "#08080a")

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${APP_IT_PROJECT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

APP_NAME="${APP_NAME:?must set APP_NAME}"
APP_SLUG="${APP_SLUG:?must set APP_SLUG}"
MOTIF="${MOTIF:-rings}"

OUT_SVG="$ROOT/assets/${APP_SLUG}-icon.svg"
mkdir -p "$ROOT/assets"

# --- Sniff brand tokens from common locations -------------------------
detect_color() {
    local pattern="$1"
    grep -hRE "$pattern" \
        "$ROOT/src" "$ROOT/app" "$ROOT/public" "$ROOT/styles" 2>/dev/null \
        | grep -oE "#[0-9a-fA-F]{3,8}" \
        | head -1 || true
}

if [ -z "${ACCENT:-}" ]; then
    ACCENT="$(detect_color '--color-(accent|primary|brand|action)')"
    [ -z "$ACCENT" ] && ACCENT="$(detect_color 'accent.*#')"
    [ -z "$ACCENT" ] && ACCENT="#c8a44e"
fi
if [ -z "${VOID:-}" ]; then
    VOID="$(detect_color '--color-(bg|background|void|surface|base)')"
    [ -z "$VOID" ] && VOID="#08080a"
fi

# Get the first letter for monogram motif (uppercase, ASCII-ish).
FIRST_LETTER="$(echo "$APP_NAME" | head -c 1 | tr 'a-z' 'A-Z')"

# --- Emit SVG by motif -------------------------------------------------
case "$MOTIF" in
    rings)
        cat > "$OUT_SVG" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <rect width="1024" height="1024" rx="180" fill="$VOID"/>
  <circle cx="512" cy="512" r="380" fill="none" stroke="$ACCENT" stroke-width="10" opacity="0.35"/>
  <circle cx="512" cy="512" r="290" fill="none" stroke="$ACCENT" stroke-width="14" opacity="0.55"/>
  <circle cx="512" cy="512" r="200" fill="none" stroke="$ACCENT" stroke-width="18" opacity="0.75"/>
  <circle cx="512" cy="512" r="110" fill="$ACCENT"/>
</svg>
SVG
        ;;
    monogram)
        cat > "$OUT_SVG" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <rect width="1024" height="1024" rx="180" fill="$ACCENT"/>
  <text x="512" y="700" font-family="ui-sans-serif, system-ui, -apple-system, 'SF Pro Display', sans-serif"
        font-size="640" font-weight="700" fill="$VOID" text-anchor="middle">$FIRST_LETTER</text>
</svg>
SVG
        ;;
    grid)
        cat > "$OUT_SVG" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <rect width="1024" height="1024" rx="180" fill="$VOID"/>
  <g fill="$ACCENT">
    <rect x="220" y="220" width="180" height="180" rx="32" opacity="0.4"/>
    <rect x="420" y="220" width="180" height="180" rx="32" opacity="0.6"/>
    <rect x="620" y="220" width="180" height="180" rx="32" opacity="0.8"/>
    <rect x="220" y="420" width="180" height="180" rx="32" opacity="0.6"/>
    <rect x="420" y="420" width="180" height="180" rx="32" opacity="1.0"/>
    <rect x="620" y="420" width="180" height="180" rx="32" opacity="0.6"/>
    <rect x="220" y="620" width="180" height="180" rx="32" opacity="0.8"/>
    <rect x="420" y="620" width="180" height="180" rx="32" opacity="0.6"/>
    <rect x="620" y="620" width="180" height="180" rx="32" opacity="0.4"/>
  </g>
</svg>
SVG
        ;;
    *)
        echo "Unknown MOTIF '$MOTIF'. Pick: rings | monogram | grid." >&2
        exit 1
        ;;
esac

echo "Generated: $OUT_SVG (motif: $MOTIF, accent: $ACCENT, void: $VOID)"
echo "Run 'pnpm desktop:icons:<slug> && pnpm desktop:build && pnpm desktop:install' to apply."
echo "Replace assets/${APP_SLUG}-icon.svg with a real brand mark when one is available."
