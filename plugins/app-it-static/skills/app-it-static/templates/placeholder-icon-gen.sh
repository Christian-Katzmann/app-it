#!/bin/bash
# Last-resort placeholder icon generator. Produces assets/<slug>-icon.svg when no
# usable square brand mark exists in the project. The output is a real macOS-shaped
# app icon — a superellipse "squircle" body (the continuous-corner shape Apple uses,
# not a plain rounded rect), inset into the icon safe area, top-lit for depth, with
# a palette-keyed mark on top.
#
# Strategy menu (in priority order):
#   1. Brand-token-derived mark: parse globals.css / tailwind.config / *.css for
#      --color-* (and Tailwind) tokens, pick the DEEPEST background and the most
#      SATURATED accent, and draw a geometric mark keyed to that palette. Brand-
#      aligned by construction.
#   2. Monogram: a refined two-tone lettermark (first letter of APP_NAME) with an
#      accent keyline — used when no palette tokens are found, or on request.
#
# Everything is deterministic and local: no network, no fonts installed, no AI.
# The SVG deliberately uses only paths + linear gradients (no <filter>/<clipPath>)
# so it rasterizes identically through rsvg-convert, ImageMagick, or sips.
#
# Usage:
#   APP_NAME="My App" APP_SLUG="my-app" ./placeholder-icon-gen.sh
#   APP_NAME="My App" APP_SLUG="my-app" MOTIF="monogram" ./placeholder-icon-gen.sh
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

# --- Color utilities ---------------------------------------------------------
# Normalize #rgb / #rrggbb / #rrggbbaa to #rrggbb (lowercase). Empty in → empty out.
norm_hex() {
    awk -v h="$1" 'BEGIN{
        gsub(/[^0-9a-fA-F]/,"",h); h=tolower(h);
        if(length(h)==3){ print "#" substr(h,1,1) substr(h,1,1) substr(h,2,1) substr(h,2,1) substr(h,3,1) substr(h,3,1); }
        else if(length(h)>=6){ print "#" substr(h,1,6); }
        else { print ""; }
    }'
}

# Portable hex->int for awk (macOS ships BWK awk, which lacks gawk's strtonum).
# Prepended to every awk program below as a digit-map lookup.
AWK_HEX='function hv(c){return index("0123456789abcdef",c)-1}
function h2(s){return hv(substr(s,1,1))*16+hv(substr(s,2,1))}'

# Mix hex toward a target hex by amount (0..1). Deterministic; used for the
# top-lit gradient (lift the top, deepen the bottom) without any blur filter.
mix_hex() {
    awk -v a="$1" -v b="$2" -v t="$3" "$AWK_HEX"'
    BEGIN{
        ar=h2(substr(a,2,2)); ag=h2(substr(a,4,2)); ab=h2(substr(a,6,2));
        br=h2(substr(b,2,2)); bg=h2(substr(b,4,2)); bb=h2(substr(b,6,2));
        printf "#%02x%02x%02x", ar+(br-ar)*t, ag+(bg-ag)*t, ab+(bb-ab)*t;
    }'
}

# Relative luminance (0..1) of a hex — for picking the darkest background.
luma_of() {
    awk -v h="$1" "$AWK_HEX"'
    BEGIN{
        r=h2(substr(h,2,2))/255; g=h2(substr(h,4,2))/255; b=h2(substr(h,6,2))/255;
        printf "%.5f", 0.2126*r+0.7152*g+0.0722*b;
    }'
}

# From a newline-separated hex list on stdin, print the darkest (lowest luma).
pick_darkest() {
    awk "$AWK_HEX"'
        BEGIN{best="";bl=2}
        { h=$0; if(length(h)<7) next;
          r=h2(substr(h,2,2))/255; g=h2(substr(h,4,2))/255; b=h2(substr(h,6,2))/255;
          l=0.2126*r+0.7152*g+0.0722*b; if(l<bl){bl=l;best=h} }
        END{print best}'
}

# From a newline-separated hex list on stdin, print the most saturated/vivid
# (HSV chroma, tie-broken toward mid lightness so we avoid near-white/near-black).
pick_vivid() {
    awk "$AWK_HEX"'
        BEGIN{best="";bs=-1}
        { h=$0; if(length(h)<7) next;
          r=h2(substr(h,2,2))/255; g=h2(substr(h,4,2))/255; b=h2(substr(h,6,2))/255;
          mx=r; if(g>mx)mx=g; if(b>mx)mx=b; mn=r; if(g<mn)mn=g; if(b<mn)mn=b;
          chroma=mx-mn; mid=1-((mx+mn)/2-0.5)*((mx+mn)/2-0.5)*4; score=chroma*0.8+mid*0.2;
          if(score>bs){bs=score;best=h} }
        END{print best}'
}

# Grep a property pattern across the usual style locations and emit every hex
# color found on matching lines, normalized to #rrggbb, one per line.
collect_colors() {
    local pattern="$1"
    # -e guards a pattern that starts with '-' (our CSS-var patterns begin with
    # '--?'), which BSD grep would otherwise parse as an option.
    grep -hREi -e "$pattern" \
        "$ROOT/src" "$ROOT/app" "$ROOT/styles" "$ROOT/components" "$ROOT/public" \
        "$ROOT/globals.css" "$ROOT/tailwind.config.js" "$ROOT/tailwind.config.ts" \
        "$ROOT/tailwind.config.cjs" "$ROOT/theme.css" "$ROOT/app.css" 2>/dev/null \
        | grep -oE "#[0-9a-fA-F]{3,8}" \
        | while IFS= read -r c; do norm_hex "$c"; done \
        | grep -E '^#[0-9a-f]{6}$' || true
}

# --- Resolve the palette -----------------------------------------------------
if [ -z "${ACCENT:-}" ]; then
    ACCENT="$(collect_colors '--?color-?(accent|primary|brand|action|highlight)|(^|[^a-z])(accent|primary|brand)[^a-z].*#' | pick_vivid)"
    [ -z "$ACCENT" ] && ACCENT="#c8a44e"
fi
if [ -z "${VOID:-}" ]; then
    VOID="$(collect_colors '--?color-?(bg|background|surface|base|void|ink|canvas|panel)' | pick_darkest)"
    [ -z "$VOID" ] && VOID="#0b0b10"
fi
ACCENT="$(norm_hex "$ACCENT")"; [ -n "$ACCENT" ] || ACCENT="#c8a44e"
VOID="$(norm_hex "$VOID")";     [ -n "$VOID" ]   || VOID="#0b0b10"

# Derived tones. Top-lit gradient: lift the top toward white, deepen the bottom.
BG_TOP="$(mix_hex "$VOID" "#ffffff" 0.10)"
BG_BOT="$(mix_hex "$VOID" "#000000" 0.18)"
# A light tone for the lettermark, tinted by the background so it never reads as
# pure #fff slapped on a fill (the generic-monogram tell we want to avoid).
INK="$(mix_hex "$VOID" "#ffffff" 0.93)"
# Decide whether the accent reads on the void; if too dark, lift it for the mark.
ACCENT_LUMA="$(luma_of "$ACCENT")"
MARK_ACCENT="$ACCENT"
awk "BEGIN{exit !($ACCENT_LUMA < 0.10)}" && MARK_ACCENT="$(mix_hex "$ACCENT" "#ffffff" 0.35)"

# --- macOS squircle body -----------------------------------------------------
# A superellipse (|x|^n+|y|^n=1, n≈5) sampled as a smooth polygon — visually the
# Apple icon shape, and universally rasterizable (no <clipPath>/<filter> needed).
# Inset to the icon safe area (body ≈ 824/1024) so the margin reads as macOS.
squircle_path() { # cx cy r n points
    awk -v cx="$1" -v cy="$2" -v r="$3" -v n="$4" -v pts="$5" 'BEGIN{
        pi=3.141592653589793; out="";
        for(i=0;i<pts;i++){
            t=2*pi*i/pts; ct=cos(t); st=sin(t);
            sx=(ct<0?-1:1); sy=(st<0?-1:1); ac=(ct<0?-ct:ct); as=(st<0?-st:st);
            x=cx + r*sx*(ac^(2.0/n)); y=cy + r*sy*(as^(2.0/n));
            out=out (i==0?"M":"L") sprintf("%.1f %.1f ", x, y);
        }
        print out "Z";
    }'
}
BODY="$(squircle_path 512 512 412 5 144)"

# --- Mark layer (motif-specific), drawn within the squircle ------------------
case "$MOTIF" in
    rings)
        MARK=$(cat <<MARK
  <circle cx="512" cy="512" r="300" fill="none" stroke="$MARK_ACCENT" stroke-width="12" opacity="0.30"/>
  <circle cx="512" cy="512" r="226" fill="none" stroke="$MARK_ACCENT" stroke-width="16" opacity="0.52"/>
  <circle cx="512" cy="512" r="152" fill="none" stroke="$MARK_ACCENT" stroke-width="20" opacity="0.78"/>
  <circle cx="512" cy="512" r="78" fill="$MARK_ACCENT"/>
MARK
)
        ;;
    grid)
        MARK=$(cat <<MARK
  <g fill="$MARK_ACCENT">
    <rect x="300" y="300" width="128" height="128" rx="26" opacity="0.40"/>
    <rect x="448" y="300" width="128" height="128" rx="26" opacity="0.62"/>
    <rect x="596" y="300" width="128" height="128" rx="26" opacity="0.84"/>
    <rect x="300" y="448" width="128" height="128" rx="26" opacity="0.62"/>
    <rect x="448" y="448" width="128" height="128" rx="26" opacity="1.0"/>
    <rect x="596" y="448" width="128" height="128" rx="26" opacity="0.62"/>
    <rect x="300" y="596" width="128" height="128" rx="26" opacity="0.84"/>
    <rect x="448" y="596" width="128" height="128" rx="26" opacity="0.62"/>
    <rect x="596" y="596" width="128" height="128" rx="26" opacity="0.40"/>
  </g>
MARK
)
        ;;
    monogram)
        FIRST_LETTER="$(printf '%s' "$APP_NAME" | head -c 1 | tr '[:lower:]' '[:upper:]')"
        # A refined lettermark: tinted ink (not pure white), optically raised,
        # with an accent keyline beneath it so it reads as a designed mark.
        MARK=$(cat <<MARK
  <text x="512" y="648" font-family="'SF Pro Display', ui-sans-serif, system-ui, -apple-system, 'Helvetica Neue', Arial, sans-serif"
        font-size="540" font-weight="600" letter-spacing="-12" fill="$INK" text-anchor="middle">$FIRST_LETTER</text>
  <rect x="396" y="712" width="232" height="20" rx="10" fill="$MARK_ACCENT"/>
MARK
)
        ;;
    *)
        echo "Unknown MOTIF '$MOTIF'. Pick: rings | monogram | grid." >&2
        exit 1
        ;;
esac

# --- Assemble ----------------------------------------------------------------
cat > "$OUT_SVG" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="body" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="$BG_TOP"/>
      <stop offset="1" stop-color="$BG_BOT"/>
    </linearGradient>
    <linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#ffffff" stop-opacity="0.10"/>
      <stop offset="0.45" stop-color="#ffffff" stop-opacity="0"/>
    </linearGradient>
  </defs>
  <path d="$BODY" fill="url(#body)"/>
  <path d="$BODY" fill="url(#sheen)"/>
$MARK
</svg>
SVG

echo "Generated: $OUT_SVG"
echo "  motif: $MOTIF · accent: $ACCENT · background: $VOID · shape: macOS squircle"
echo "Preview it at real Dock sizes:"
echo "  APP_NAME='$APP_NAME' APP_SLUG='$APP_SLUG' ./scripts/desktop-icons-preview.sh --open"
echo "Apply it:"
echo "  pnpm desktop:icons:$APP_SLUG && pnpm desktop:build && pnpm desktop:install"
echo "Replace assets/${APP_SLUG}-icon.svg with a real brand mark when one is available."
