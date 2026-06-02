#!/bin/bash
# app-it icon preview — render ONE source icon at real Dock/Finder sizes and
# flag, in plain language, the things that quietly ruin an app icon.
#
# This is the "bring your own icon" safety net: see how a mark will actually
# look in the Dock BEFORE you build the .app, instead of discovering a blurry
# wordmark after it is already installed. It is the icon-pipeline sibling of
# desktop-doctor.sh — same ok/warn/fail vocabulary, same "says 'probably' when
# it cannot be certain", same paste-into-a-bug-report output.
#
# Two ways to call it:
#   APP_NAME='My App' APP_SLUG='my-app' ./desktop-icons-preview.sh
#       previews the resolved source for that app
#       (assets/<slug>-icon.{png,svg} -> assets/app-icon.{png,svg}) and writes
#       the report into assets/icons/<slug>/.
#   ./desktop-icons-preview.sh path/to/candidate.png
#       previews ANY image so you can vet a candidate before adopting it;
#       writes into assets/icons/_preview/.
#
# Flags:
#   --open          open the generated HTML when finished
#   --out DIR       write preview.html / preview.png into DIR instead
#   -h | --help
#
# DESIGN CONTRACT (mirrors desktop-doctor.sh):
#   * Deterministic and local. No network, no installs, no new dependencies.
#     Same toolchain the icon pipeline already uses: sips + iconutil, plus an
#     optional `swift` pass (present on app-it's default native path) for the
#     pixel-level checks, with a `magick` fallback for the contact sheet.
#   * The HTML is ALWAYS produced (zero extra dependencies). The pixel-level
#     "deep" checks and the PNG contact sheet degrade with an honest note when
#     `swift`/`magick` are absent — they are never silently skipped.
#   * Read-only with respect to YOUR project. The only thing it writes is its
#     own report under assets/icons/ (already gitignored by the build).
#   * Exit 0 whenever it produced a report, regardless of findings — this is a
#     report, not a test that should make `npm` spew red. Non-zero only when it
#     genuinely cannot run (bad flag, no source image, unreadable file).

set -uo pipefail   # NOT -e: sips/file probes fail by design; each is guarded.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${APP_IT_PROJECT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# --- Output vocabulary (identical to desktop-doctor.sh) ----------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[31m'
    C_INFO=$'\033[36m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
    C_OK=""; C_WARN=""; C_FAIL=""; C_INFO=""; C_DIM=""; C_BOLD=""; C_OFF=""
fi

OK_N=0; WARN_N=0; FAIL_N=0; INFO_N=0
ok()   { printf '  %s[ ok ]%s  %s\n' "$C_OK"   "$C_OFF" "$1"; OK_N=$((OK_N+1)); }
warn() { printf '  %s[warn]%s  %s\n' "$C_WARN" "$C_OFF" "$1"; WARN_N=$((WARN_N+1)); }
fail() { printf '  %s[fail]%s  %s\n' "$C_FAIL" "$C_OFF" "$1"; FAIL_N=$((FAIL_N+1)); }
info() { printf '  %s[info]%s  %s\n' "$C_INFO" "$C_OFF" "$1"; INFO_N=$((INFO_N+1)); }
note() { printf '          %s%s%s\n' "$C_DIM" "$1" "$C_OFF"; }
section() { printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_OFF"; }
die() { printf '%sdesktop-icons-preview: %s%s\n' "$C_FAIL" "$1" "$C_OFF" >&2; exit "${2:-2}"; }

usage() {
    cat <<'EOF'
app-it icon preview — render one source icon at real Dock/Finder sizes and flag
the things that quietly ruin an app icon, in plain language.

  APP_NAME='My App' APP_SLUG='my-app' ./scripts/desktop-icons-preview.sh
        preview the app's resolved source icon (assets/<slug>-icon.{png,svg})

  ./scripts/desktop-icons-preview.sh path/to/candidate.png
        preview any image before you adopt it

  --open        open the generated HTML when finished
  --out DIR     write preview.html / preview.png into DIR
  -h | --help

Deterministic and local. Writes only its own report under assets/icons/.
EOF
}

# --- HTML helpers ------------------------------------------------------------
html_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# Findings are emitted to the terminal AND collected as HTML at the same time,
# so the two reports can never drift.
HTML_FINDINGS=""
find_emit() { # level  message  [why]
    local lvl="$1" msg="$2" why="${3:-}"
    case "$lvl" in
        ok)   ok   "$msg" ;;
        warn) warn "$msg" ;;
        fail) fail "$msg" ;;
        *)    info "$msg"; lvl="info" ;;
    esac
    [ -n "$why" ] && note "$why"
    local why_html=""
    [ -n "$why" ] && why_html="<p class=\"why\">$(html_escape "$why")</p>"
    HTML_FINDINGS="$HTML_FINDINGS
      <li class=\"f-$lvl\"><span class=\"badge b-$lvl\">$lvl</span><div><p class=\"msg\">$(html_escape "$msg")</p>$why_html</div></li>"
}

# Float predicate via awk so we stay bash-3.2 clean (macOS default shell).
# usage: if flt "$x < 0.5"; then ...   — false when the operand is empty.
flt() { [ -n "${1// /}" ] && awk "BEGIN{exit !($1)}" 2>/dev/null; }

# --- Parse args --------------------------------------------------------------
SRC_ARG=""; DO_OPEN=0; OUT_OVERRIDE="${PREVIEW_OUT_DIR:-}"
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --open)    DO_OPEN=1 ;;
        --out)     shift; [ "$#" -gt 0 ] || die "--out needs a directory"; OUT_OVERRIDE="$1" ;;
        --out=*)   OUT_OVERRIDE="${1#--out=}" ;;
        --*)       usage >&2; die "unknown flag: $1" ;;
        *)         [ -z "$SRC_ARG" ] && SRC_ARG="$1" || die "unexpected extra argument: $1" ;;
    esac
    shift
done

# --- Resolve the source image + a human label + where the report goes --------
SOURCE=""; LABEL=""; SLUG=""
if [ -n "$SRC_ARG" ]; then
    [ -f "$SRC_ARG" ] || die "no such file: $SRC_ARG"
    SOURCE="$SRC_ARG"
    LABEL="$(basename "$SRC_ARG")"
    SLUG="_preview"
    OUT_DIR="${OUT_OVERRIDE:-$ROOT/assets/icons/_preview}"
else
    APP_NAME="${APP_NAME:?must set APP_NAME (or pass an image path). e.g. APP_NAME='My App' APP_SLUG='my-app'}"
    APP_SLUG="${APP_SLUG:?must set APP_SLUG (or pass an image path). e.g. APP_SLUG='my-app'}"
    LABEL="$APP_NAME"
    SLUG="$APP_SLUG"
    for c in "$ROOT/assets/${APP_SLUG}-icon.png" "$ROOT/assets/app-icon.png" \
             "$ROOT/assets/${APP_SLUG}-icon.svg" "$ROOT/assets/app-icon.svg"; do
        [ -f "$c" ] && SOURCE="$c" && break
    done
    if [ -z "$SOURCE" ]; then
        printf '%sNo source icon for %s.%s\n' "$C_FAIL" "$APP_SLUG" "$C_OFF" >&2
        printf '  Looked at: assets/%s-icon.{png,svg}, assets/app-icon.{png,svg}\n' "$APP_SLUG" >&2
        printf '  Drop a square PNG/SVG (1024x1024 ideal) at one of those paths, or run\n' >&2
        printf '  placeholder-icon-gen.sh to generate a brand-aligned starter — then re-run this.\n' >&2
        exit 2
    fi
    OUT_DIR="${OUT_OVERRIDE:-$ROOT/assets/icons/$APP_SLUG}"
fi

mkdir -p "$OUT_DIR"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/app-it-preview.XXXXXX")" || die "could not create a temp dir"
trap 'rm -rf "$TMP"' EXIT

SRC_EXT="$(printf '%s' "$SOURCE" | tr '[:upper:]' '[:lower:]')"
case "$SRC_EXT" in *.svg) IS_SVG=1 ;; *) IS_SVG=0 ;; esac

# --- Header ------------------------------------------------------------------
printf '%sapp-it icon preview%s — %s%s%s\n' "$C_BOLD" "$C_OFF" "$C_BOLD" "$LABEL" "$C_OFF"
printf '  %ssource%s   %s\n' "$C_DIM" "$C_OFF" "$SOURCE"
printf '  %sreport%s   %s/preview.html\n' "$C_DIM" "$C_OFF" "$OUT_DIR"

# --- Normalize to a squared 1024 master, exactly like desktop-icons.sh -------
# desktop-icons.sh forces real PNG bytes (JPEG-in-.png would break iconutil) and
# then squares to 1024x1024 with `sips -z` — which DISTORTS a non-square source.
# We reproduce that here so the preview shows the TRUTH of the future .icns, not
# a flattering aspect-preserving render.
MASTER="$TMP/master.png"
if [ "$IS_SVG" = "1" ]; then
    RASTER="$TMP/raster.png"
    if command -v rsvg-convert >/dev/null 2>&1; then
        rsvg-convert -w 1024 -h 1024 "$SOURCE" -o "$RASTER" 2>/dev/null
    elif command -v magick >/dev/null 2>&1; then
        magick -background none -density 300 "$SOURCE" -resize 1024x1024 "$RASTER" 2>/dev/null
    else
        sips -s format png -Z 1024 "$SOURCE" --out "$RASTER" >/dev/null 2>&1
    fi
    [ -f "$RASTER" ] || die "could not rasterize the SVG (install librsvg or imagemagick, or supply a PNG)"
    sips -z 1024 1024 "$RASTER" --out "$MASTER" >/dev/null 2>&1 || die "could not build the 1024 master"
else
    NORM="$TMP/norm.png"
    if ! sips -s format png "$SOURCE" --out "$NORM" >/dev/null 2>&1; then
        die "source is not a recognizable image: $SOURCE ($(file -b "$SOURCE" 2>/dev/null))"
    fi
    sips -z 1024 1024 "$NORM" --out "$MASTER" >/dev/null 2>&1 || die "could not build the 1024 master"
fi

SIZES="16 32 64 128 256 512"
for s in $SIZES; do
    sips -z "$s" "$s" "$MASTER" --out "$TMP/icon_${s}.png" >/dev/null 2>&1
done

# =============================================================================
# Tier 1 — source facts (sips only; always runs)
# =============================================================================
section "Source"

read_g() { sips -g "$1" "$2" 2>/dev/null | awk -v k="$1:" '$1==k{print $2}'; }

SRC_FORMAT="$(read_g format "$SOURCE")"
SRC_SPACE="$(read_g space "$SOURCE")"
SRC_HASALPHA="$(read_g hasAlpha "$SOURCE")"
MASTER_HASALPHA="$(read_g hasAlpha "$MASTER")"

if [ "$IS_SVG" = "1" ]; then
    SRC_W=""; SRC_H=""
    find_emit info "Vector source (SVG) — scales to any size without blur." \
        "A clean SVG is the ideal app-icon source; resolution is never a problem."
else
    SRC_W="$(read_g pixelWidth "$SOURCE")"
    SRC_H="$(read_g pixelHeight "$SOURCE")"
fi

# Dimensions / resolution.
if [ -n "${SRC_W:-}" ] && [ -n "${SRC_H:-}" ]; then
    SMALL="$SRC_W"; [ "$SRC_H" -lt "$SRC_W" ] && SMALL="$SRC_H"
    if   [ "$SMALL" -ge 1024 ]; then
        find_emit ok "Source is ${SRC_W}x${SRC_H} — enough resolution for a crisp icon at every size."
    elif [ "$SMALL" -ge 512 ]; then
        find_emit warn "Source is ${SRC_W}x${SRC_H} — below the 1024x1024 ideal." \
            "macOS renders app icons up to 1024px (512@2x). Below that, the largest sizes are upscaled and soften. Usable, but a 1024+ source is sharper."
    else
        find_emit fail "Source is only ${SRC_W}x${SRC_H} — too small for an app icon." \
            "It will be upscaled to fill the tile and look blurry. Supply a 1024x1024 (512 at the very least) master."
    fi

    # Aspect ratio of the *literal* source — squaring will distort a wide/tall one.
    if [ "$SRC_W" -ne "$SRC_H" ]; then
        if   flt "$SRC_W >= $SRC_H * 1.6"; then
            find_emit warn "Source looks like a horizontal wordmark (${SRC_W}x${SRC_H})." \
                "Wide marks get squished into the square tile and turn into an illegible smudge at 16px in the Dock. Prefer a square symbol over a full logotype."
        elif flt "$SRC_H >= $SRC_W * 1.6"; then
            find_emit warn "Source is a tall/portrait image (${SRC_W}x${SRC_H})." \
                "It will be squished into the square tile. Crop or pad it to square (around the mark, never through it) first."
        elif flt "$SRC_W >= $SRC_H * 1.15 || $SRC_H >= $SRC_W * 1.15"; then
            find_emit warn "Source is not square (${SRC_W}x${SRC_H}) — it will be stretched into the tile." \
                "The icon pipeline squares the source by resampling, which distorts the mark. Pad it to a 1:1 canvas instead."
        else
            find_emit ok "Source is close to square (${SRC_W}x${SRC_H})."
        fi
    else
        find_emit ok "Source is perfectly square (${SRC_W}x${SRC_H})."
    fi
fi

# Alpha / background — only meaningful for raster sources. `sips` reports
# hasAlpha/space/format unreliably for SVG, so we defer to Tier-2 coverage there.
if [ "$IS_SVG" != "1" ]; then
    if [ "$SRC_HASALPHA" = "no" ]; then
        case "$(printf '%s' "$SRC_FORMAT" | tr '[:upper:]' '[:lower:]')" in
            jpeg|jpg)
                find_emit warn "Source is a JPEG with no transparency — it carries a solid rectangular background." \
                    "The icon will be a hard-edged rectangle, not a mark that sits on the Dock. Export a PNG/SVG with a transparent background, or a design that fills the whole tile on purpose." ;;
            *)
                find_emit info "Source has no alpha channel — opaque background." \
                    "Fine if the design is meant to fill the whole tile; not fine if you expected a transparent mark." ;;
        esac
    elif [ "$SRC_HASALPHA" = "yes" ] && [ "$MASTER_HASALPHA" = "no" ]; then
        find_emit warn "Transparency was lost while converting the source." \
            "The source has an alpha channel but the rendered icon does not — a flattening step dropped it. Check the export, or supply a PNG that keeps its alpha."
    elif [ "$SRC_HASALPHA" = "yes" ]; then
        find_emit ok "Transparency preserved through to the rendered icon."
    fi
    [ -n "$SRC_SPACE" ] && note "color space: $SRC_SPACE · format: ${SRC_FORMAT:-unknown}"
fi

# =============================================================================
# Tier 2 — pixel-level checks (swift; honest skip when unavailable)
# =============================================================================
section "At small sizes"

METRICS="$TMP/metrics.txt"
SHEET_BY=""   # which tool drew the contact sheet, for the footer note
HAVE_TIER2=0

if command -v swift >/dev/null 2>&1; then
    cat > "$TMP/analyze.swift" <<'SWIFT'
import AppKit
import Foundation

// args: <master.png> <sheet-out.png> <metrics-out.txt>
let a = CommandLine.arguments
guard a.count >= 4, let img = NSImage(contentsOfFile: a[1]) else { exit(3) }
let masterPath = a[1], outPath = a[2], metricsPath = a[3]

// Draw the icon into an RGBA8 sRGB context at `n`x`n` and return the raw bytes.
func raster(_ image: NSImage, _ n: Int) -> [UInt8]? {
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8,
                              bytesPerRow: n * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.clear(CGRect(x: 0, y: 0, width: n, height: n))
    let g = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = g
    image.draw(in: CGRect(x: 0, y: 0, width: n, height: n),
               from: .zero, operation: .sourceOver, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    guard let d = ctx.data else { return nil }
    let p = d.bindMemory(to: UInt8.self, capacity: n * n * 4)
    return Array(UnsafeBufferPointer(start: p, count: n * n * 4))
}

// Luminance stats + opaque bounding box over a rasterization. Returns
// (coverage, lumaMean, lumaStd, lumaRange, contentW, contentH, marginMin).
// `range` (max-min) separates a clear sparse mark (dark tile + bright glyph =
// low std but high range) from a muddy image that averages to one tone.
func stats(_ px: [UInt8], _ n: Int) -> (Double, Double, Double, Double, Double, Double, Double) {
    let aT = 0.10
    var opaque = 0, minX = n, minY = n, maxX = -1, maxY = -1
    var sL = 0.0, sL2 = 0.0, lmin = 1.0, lmax = 0.0
    for y in 0..<n {
        for x in 0..<n {
            let i = (y * n + x) * 4
            let al = Double(px[i + 3]) / 255.0
            if al <= aT { continue }
            opaque += 1
            if x < minX { minX = x }; if x > maxX { maxX = x }
            if y < minY { minY = y }; if y > maxY { maxY = y }
            let r = Double(px[i])     / 255.0 / al
            let gg = Double(px[i + 1]) / 255.0 / al
            let b = Double(px[i + 2]) / 255.0 / al
            let l = 0.2126 * r + 0.7152 * gg + 0.0722 * b
            sL += l; sL2 += l * l
            if l < lmin { lmin = l }; if l > lmax { lmax = l }
        }
    }
    let cov = Double(opaque) / Double(n * n)
    if opaque == 0 { return (0, 0, 0, 0, 0, 0, 0) }
    let mean = sL / Double(opaque)
    let std = max(0, sL2 / Double(opaque) - mean * mean).squareRoot()
    let cW = Double(maxX - minX + 1) / Double(n)
    let cH = Double(maxY - minY + 1) / Double(n)
    let mL = Double(minX) / Double(n), mR = Double(n - 1 - maxX) / Double(n)
    let mT = Double(minY) / Double(n), mB = Double(n - 1 - maxY) / Double(n)
    return (cov, mean, std, lmax - lmin, cW, cH, min(min(mL, mR), min(mT, mB)))
}

guard let big = raster(img, 256) else { exit(4) }
let (cov, mean, std, range, cW, cH, margin) = stats(big, 256)
var std16 = std, range16 = range
if let small = raster(img, 16) { let s = stats(small, 16); std16 = s.2; range16 = s.3 }
let aspect = cH > 0 ? cW / cH : 1.0

let metrics = """
coverage=\(String(format: "%.4f", cov))
luma_mean=\(String(format: "%.4f", mean))
luma_std=\(String(format: "%.4f", std))
luma_range=\(String(format: "%.4f", range))
luma16_std=\(String(format: "%.4f", std16))
luma16_range=\(String(format: "%.4f", range16))
content_w=\(String(format: "%.4f", cW))
content_h=\(String(format: "%.4f", cH))
content_aspect=\(String(format: "%.4f", aspect))
margin_min=\(String(format: "%.4f", margin))
"""
try? metrics.write(toFile: metricsPath, atomically: true, encoding: .utf8)

// --- Contact sheet: the icon at 16..256 on a light and a dark panel ---------
// Drawn in the CGContext's NATURAL bottom-up space (flipped:false). A flipped
// NSGraphicsContext renders NSAttributedString glyphs mirrored offscreen, so we
// compute every y from the bottom and keep text upright.
let sheetSizes = [16, 32, 64, 128, 256]
let pad = 28.0, gap = 26.0, sizeLabelH = 22.0, panelLabelH = 30.0, innerPad = 16.0
let colW: [Double] = sheetSizes.map { max(Double($0), 64.0) }
let rowW = colW.reduce(0, +) + gap * Double(sheetSizes.count - 1)
let sheetW = pad * 2 + rowW
let tallest = Double(sheetSizes.max() ?? 256)
let panelH = panelLabelH + tallest + sizeLabelH + innerPad
let titleH = 40.0
let sheetH = pad + titleH + gap + panelH + gap + panelH + pad

guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(data: nil, width: Int(sheetW), height: Int(sheetH),
                          bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { exit(5) }
let gctx = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = gctx

func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ c: NSColor) {
    c.setFill(); NSRect(x: x, y: y, width: w, height: h).fill()
}
func label(_ s: String, x: Double, y: Double, _ size: Double, _ c: NSColor, bold: Bool = false) {
    let f = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
    NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c])
        .draw(at: NSPoint(x: x, y: y))
}

box(0, 0, sheetW, sheetH, NSColor.white)
label("Icon preview — 16 to 256 px", x: pad, y: sheetH - pad - 16,
      16, NSColor(white: 0.12, alpha: 1), bold: true)

// Light panel sits on top, dark panel below it (bottom-up coordinates).
let panels: [(String, NSColor, NSColor, Double)] = [
    ("On a light Dock / Finder", NSColor(white: 0.925, alpha: 1), NSColor(white: 0.34, alpha: 1), pad + panelH + gap),
    ("On a dark Dock",           NSColor(white: 0.11,  alpha: 1), NSColor(white: 0.72, alpha: 1), pad),
]
for (title, bg, fg, bottom) in panels {
    box(pad, bottom, sheetW - pad * 2, panelH, bg)
    label(title, x: pad + 14, y: bottom + panelH - 22, 12, fg, bold: true)
    let iconBottom = bottom + innerPad + sizeLabelH
    var x = pad
    for (i, s) in sheetSizes.enumerated() {
        let w = colW[i], ds = Double(s)
        img.draw(in: NSRect(x: x + (w - ds) / 2.0, y: iconBottom, width: ds, height: ds),
                 from: .zero, operation: .sourceOver, fraction: 1.0)
        label("\(s)px", x: x + w / 2.0 - 11, y: bottom + innerPad - 2, 11, fg)
        x += w + gap
    }
}
NSGraphicsContext.restoreGraphicsState()

if let cg = ctx.makeImage() {
    let rep = NSBitmapImageRep(cgImage: cg)
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: outPath))
    }
}
SWIFT
    if swift "$TMP/analyze.swift" "$MASTER" "$OUT_DIR/preview.png" "$METRICS" >/dev/null 2>&1 \
        && [ -f "$METRICS" ]; then
        HAVE_TIER2=1
        [ -f "$OUT_DIR/preview.png" ] && SHEET_BY="swift"
    fi
fi

if [ "$HAVE_TIER2" = "1" ]; then
    COVERAGE="$(awk -F= '/^coverage=/{print $2}' "$METRICS")"
    LUMA_MEAN="$(awk -F= '/^luma_mean=/{print $2}' "$METRICS")"
    LUMA16_RANGE="$(awk -F= '/^luma16_range=/{print $2}' "$METRICS")"
    MARGIN_MIN="$(awk -F= '/^margin_min=/{print $2}' "$METRICS")"
    CONTENT_ASPECT="$(awk -F= '/^content_aspect=/{print $2}' "$METRICS")"

    # Contrast at 16px. Luminance can detect a genuinely near-flat tile, but it
    # cannot tell a busy-but-illegible image from a simple legible one (both can
    # have low spread). So this fires only on a real near-flat tile (high
    # precision); the rendered 16/32px tiles let the human judge the rest.
    if flt "$LUMA16_RANGE < 0.15"; then
        find_emit warn "Almost no contrast at 16px — it flattens into a near-solid tile in the Dock." \
            "Use bolder shapes or a stronger figure-to-background contrast so something still reads at the smallest size."
    else
        find_emit ok "Keeps visible contrast down to 16px — check the rendered tiles to judge legibility."
    fi

    if flt "$COVERAGE >= 0.97"; then
        find_emit ok "Fills the tile with its own background — reads on both light and dark Docks."
    else
        # Transparent padding — how close the mark gets to the safe-area edge.
        if   flt "$MARGIN_MIN > 0.22"; then
            PCT="$(awk "BEGIN{printf \"%d\", $MARGIN_MIN*100}")"
            find_emit warn "Large transparent margin (~${PCT}% empty on the tightest edge) — the mark floats small in the tile." \
                "macOS icons fill roughly 80-90% of the canvas. Scale the mark up so it nearly reaches the rounded-square safe area."
        elif flt "$MARGIN_MIN < 0.03"; then
            find_emit info "The mark runs edge-to-edge." \
                "Fine for a full-bleed design; if it is meant to be a floating symbol, leave a small safe-area margin."
        else
            find_emit ok "Sits in a sensible safe-area margin."
        fi

        # Wide/tall *visible* mark even inside a square canvas (transparent banner).
        if   flt "$CONTENT_ASPECT > 1.7"; then
            find_emit warn "The visible mark is much wider than it is tall — it reads like a banner." \
                "Even centered in a square file, a wide logotype shrinks to a sliver at 16px. Prefer a compact symbol."
        elif flt "$CONTENT_ASPECT < 0.6"; then
            find_emit warn "The visible mark is much taller than it is wide." \
                "A tall sliver is hard to recognize at small sizes. Prefer a compact, roughly-square symbol."
        fi

        # Light/dark visibility matters only for a genuinely FLOATING mark — one
        # with little body of its own. A shaped tile (squircle/circle) that fills
        # most of the canvas carries its own background, so skip the check.
        if flt "$COVERAGE < 0.55"; then
            if   flt "$LUMA_MEAN < 0.20"; then
                find_emit warn "Dark mark on transparency — it can vanish against a dark Dock or menu bar." \
                    "With no background of its own, a dark symbol disappears in dark mode. Add a filled background (the squircle the placeholder generator draws), or lighten the mark."
            elif flt "$LUMA_MEAN > 0.82"; then
                find_emit warn "Light mark on transparency — it can vanish against a light Finder window." \
                    "A near-white symbol with no background washes out in light mode. Give it a filled background tile."
            else
                find_emit ok "Tone reads on both light and dark backgrounds."
            fi
        else
            find_emit ok "Has a solid shaped body — it carries its own background on the Dock."
        fi
    fi
else
    if command -v swift >/dev/null 2>&1; then
        find_emit info "The pixel-level checks could not run on this image." \
            "The source rendered, but the analysis pass failed — the size renders and source checks above are still valid."
    else
        find_emit info "Skipped the pixel-level checks (contrast, padding, light/dark visibility) — \`swift\` is not installed." \
            "Those need the Swift toolchain (Xcode Command Line Tools: xcode-select --install). The size renders and the source checks above ran without it."
    fi
fi

# --- Contact-sheet PNG fallback (no swift) -----------------------------------
if [ ! -f "$OUT_DIR/preview.png" ] && command -v magick >/dev/null 2>&1; then
    LIGHT="$TMP/light.png"; DARK="$TMP/dark.png"
    magick montage "$TMP/icon_16.png" "$TMP/icon_32.png" "$TMP/icon_64.png" \
                   "$TMP/icon_128.png" "$TMP/icon_256.png" \
        -tile x1 -geometry +14+14 -background '#ececf0' "$LIGHT" 2>/dev/null
    magick montage "$TMP/icon_16.png" "$TMP/icon_32.png" "$TMP/icon_64.png" \
                   "$TMP/icon_128.png" "$TMP/icon_256.png" \
        -tile x1 -geometry +14+14 -background '#1c1c1e' "$DARK" 2>/dev/null
    if [ -f "$LIGHT" ] && [ -f "$DARK" ]; then
        magick "$LIGHT" "$DARK" -append "$OUT_DIR/preview.png" 2>/dev/null && SHEET_BY="magick"
    fi
fi

# =============================================================================
# HTML — always written; self-contained (base64-embedded sizes)
# =============================================================================
data_uri() { printf 'data:image/png;base64,%s' "$(base64 < "$1" | tr -d '\n')"; }

SIZE_CELLS=""
for s in $SIZES; do
    [ -f "$TMP/icon_${s}.png" ] || continue
    uri="$(data_uri "$TMP/icon_${s}.png")"
    SIZE_CELLS="$SIZE_CELLS
        <div class=\"col\">
          <div class=\"tile light\"><img src=\"$uri\" style=\"width:${s}px;height:${s}px\" alt=\"${s}px on light\"></div>
          <div class=\"tile dark\"><img src=\"$uri\" style=\"width:${s}px;height:${s}px\" alt=\"${s}px on dark\"></div>
          <div class=\"px\">${s}px</div>
        </div>"
done

DIMS_LINE="vector (SVG)"
[ -n "${SRC_W:-}" ] && DIMS_LINE="${SRC_W}x${SRC_H} · ${SRC_FORMAT:-?}"

PNG_NOTE="The contact-sheet PNG was not generated (needs <code>swift</code> or <code>magick</code>). This page is the complete preview."
[ -n "$SHEET_BY" ] && PNG_NOTE="A shareable contact-sheet PNG was saved next to this page as <code>preview.png</code> (rendered with <code>$SHEET_BY</code>)."

{
cat <<HTMLHEAD
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Icon preview — $(html_escape "$LABEL")</title>
<style>
  :root { color-scheme: light; }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 48px 24px 80px;
    font: 15px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
    color: #1d1d1f; background: #fbfbfd;
  }
  .wrap { max-width: 940px; margin: 0 auto; }
  h1 { font-size: 26px; font-weight: 600; letter-spacing: -0.01em; margin: 0 0 4px; }
  .sub { color: #6e6e73; font-size: 13px; margin: 0 0 36px;
         font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
  h2 { font-size: 12px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.06em;
       color: #6e6e73; margin: 40px 0 16px; }
  .card { background: #fff; border: 1px solid #e4e4e9; border-radius: 14px; }
  ul.findings { list-style: none; margin: 0; padding: 6px; }
  ul.findings li { display: flex; gap: 12px; padding: 12px 14px; align-items: flex-start; }
  ul.findings li + li { border-top: 1px solid #f0f0f3; }
  .badge { flex: none; margin-top: 1px; font-size: 10px; font-weight: 700; text-transform: uppercase;
           letter-spacing: 0.04em; padding: 3px 8px; border-radius: 999px; }
  .b-ok   { background: #e3f4ea; color: #156e3f; }
  .b-warn { background: #fcf0d8; color: #8a5a00; }
  .b-fail { background: #fbe2e4; color: #a3001a; }
  .b-info { background: #e6eefb; color: #064a9e; }
  .msg { margin: 0; font-weight: 500; }
  .why { margin: 4px 0 0; color: #6e6e73; font-size: 13.5px; }
  .grid { display: flex; flex-wrap: wrap; gap: 12px; align-items: flex-start;
          justify-content: center; padding: 28px 20px; }
  .col { display: flex; flex-direction: column; align-items: center; gap: 8px; }
  .tile { display: flex; align-items: center; justify-content: center; width: 140px; height: 140px;
          border-radius: 14px; }
  .tile.light { background: #ececf0; }
  .tile.dark  { background: #1c1c1e; }
  /* Small sizes render at true pixel size (the legibility-critical view);
     256/512 are capped to fit the swatch. */
  .tile img { display: block; max-width: 128px; max-height: 128px; image-rendering: -webkit-optimize-contrast; }
  .px { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 11px; color: #6e6e73; }
  .foot { color: #86868b; font-size: 12.5px; margin-top: 36px; line-height: 1.6; }
  .foot code { background: #f0f0f3; padding: 1px 5px; border-radius: 5px;
               font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 11.5px; }
</style>
</head>
<body>
<div class="wrap">
  <h1>$(html_escape "$LABEL")</h1>
  <p class="sub">$(html_escape "$SOURCE") · $DIMS_LINE</p>

  <h2>What the eye sees</h2>
  <div class="card"><div class="grid">$SIZE_CELLS
  </div></div>
  <p class="foot">Sizes up to 128&nbsp;px are shown at actual size — the small ones are where legibility is won or lost
  (16&nbsp;px is the Finder-list / menu-bar size; 32-128&nbsp;px cover the Dock). 256 and 512&nbsp;px are scaled to fit;
  the contact-sheet PNG renders them at true size. Each appears on a light and a dark background.</p>

  <h2>Findings</h2>
  <div class="card"><ul class="findings">$HTML_FINDINGS
  </ul></div>

  <p class="foot">
    $PNG_NOTE<br>
    Generated deterministically and locally by app-it (<code>sips</code> + <code>swift</code>); no network, no AI, no upload.
    To change the icon, replace the source image and re-run the preview, then <code>desktop:build &amp;&amp; desktop:install</code>.
  </p>
</div>
</body>
</html>
HTMLHEAD
} > "$OUT_DIR/preview.html"

# =============================================================================
section "Report"
ok "wrote $OUT_DIR/preview.html"
if [ -f "$OUT_DIR/preview.png" ]; then
    ok "wrote $OUT_DIR/preview.png (contact sheet via $SHEET_BY)"
else
    info "no contact-sheet PNG (needs swift or magick) — the HTML is the complete preview"
fi

section "Summary"
printf '  %s%d ok%s · %s%d warn%s · %s%d fail%s · %d info\n' \
    "$C_OK" "$OK_N" "$C_OFF" "$C_WARN" "$WARN_N" "$C_OFF" "$C_FAIL" "$FAIL_N" "$C_OFF" "$INFO_N"
if [ "$FAIL_N" -gt 0 ]; then
    printf '  %sThis icon has problems that will show in the Dock — see the [fail] lines.%s\n' "$C_FAIL" "$C_OFF"
elif [ "$WARN_N" -gt 0 ]; then
    printf '  %sUsable, but it could be better — review the [warn] lines.%s\n' "$C_WARN" "$C_OFF"
else
    printf '  %sLooks good at every size.%s\n' "$C_OK" "$C_OFF"
fi
note "Open the HTML to judge it with your own eyes: open \"$OUT_DIR/preview.html\""

[ "$DO_OPEN" = "1" ] && command -v open >/dev/null 2>&1 && open "$OUT_DIR/preview.html"
exit 0
