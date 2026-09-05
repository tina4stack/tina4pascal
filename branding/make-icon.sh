#!/usr/bin/env bash
# Build the Tina4Pascal app icon (the Tina4 robot on a pink gradient with a
# blue border) for every platform from branding/tina4-robot-avatar.svg.
#   macOS   → branding/AppIcon.icns  (+ branding/icon.png master)
#   iOS     → ios/app/Assets.xcassets/AppIcon.appiconset/icon_1024.png (square-fill)
#   Android → res/mipmap-*/ic_launcher.png (squircle) + ic_launcher_round.png (circle)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"; OUT="$ROOT/branding"
ROBOT="$OUT/tina4-robot-avatar.svg"
command -v rsvg-convert >/dev/null || { echo "need rsvg-convert (brew install librsvg)"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# robot avatar (viewBox 131 102 389x466) → transparent PNG
RH=760; RW=$(( RH * 389 / 466 ))
rsvg-convert -w "$RW" -h "$RH" "$ROBOT" -o "$TMP/robot.png"
B64="$(base64 < "$TMP/robot.png" | tr -d '\n')"
RX=$(( (1024 - RW) / 2 )); RY=$(( (1024 - RH) / 2 - 10 ))

DEFS='<linearGradient id="bg" x1="0" y1="0" x2="0.35" y2="1">
      <stop offset="0%" stop-color="#ff7ab4"/><stop offset="55%" stop-color="#ff5aa0"/>
      <stop offset="100%" stop-color="#d63884"/></linearGradient>
    <radialGradient id="glow" cx="50%" cy="34%" r="62%">
      <stop offset="0%" stop-color="#ffffff" stop-opacity="0.35"/>
      <stop offset="100%" stop-color="#ffffff" stop-opacity="0"/></radialGradient>
    <filter id="sh" x="-30%" y="-30%" width="160%" height="160%">
      <feDropShadow dx="0" dy="16" stdDeviation="24" flood-color="#7a1247" flood-opacity="0.45"/></filter>'
ROBOT_IMG="<image x=\"$RX\" y=\"$RY\" width=\"$RW\" height=\"$RH\" filter=\"url(#sh)\" xlink:href=\"data:image/png;base64,$B64\"/>"

# a shape variant: $1 = the background/border shape SVG fragment
emit() { # $1 shape-fragment  $2 out.png
  cat > "$TMP/i.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="1024" height="1024" viewBox="0 0 1024 1024"><defs>$DEFS</defs>$1$ROBOT_IMG</svg>
SVG
  rsvg-convert -w 1024 -h 1024 "$TMP/i.svg" -o "$2"
}

# 1) squircle (macOS / branding / Android legacy) — border at the edge
SQUIRCLE='<rect width="1024" height="1024" rx="229" ry="229" fill="url(#bg)"/>
  <rect width="1024" height="1024" rx="229" ry="229" fill="url(#glow)"/>
  <rect x="5" y="5" width="1014" height="1014" rx="225" ry="225" fill="none" stroke="#2b41e6" stroke-width="10"/>'
emit "$SQUIRCLE" "$OUT/icon.png"

# 2) circle (Android round)
CIRCLE='<circle cx="512" cy="512" r="512" fill="url(#bg)"/>
  <circle cx="512" cy="512" r="512" fill="url(#glow)"/>
  <circle cx="512" cy="512" r="506" fill="none" stroke="#2b41e6" stroke-width="10"/>'
emit "$CIRCLE" "$TMP/round.png"

# ---- macOS .icns ----
if command -v iconutil >/dev/null; then
  IS="$TMP/icon.iconset"; mkdir -p "$IS"
  for s in 16 32 64 128 256 512; do
    sips -z "$s" "$s" "$OUT/icon.png" --out "$IS/icon_${s}x${s}.png" >/dev/null
    d=$(( s*2 )); sips -z "$d" "$d" "$OUT/icon.png" --out "$IS/icon_${s}x${s}@2x.png" >/dev/null
  done
  cp "$OUT/icon.png" "$IS/icon_512x512@2x.png"
  iconutil -c icns "$IS" -o "$OUT/AppIcon.icns"
  echo "✓ macOS  branding/AppIcon.icns"
fi

# ---- iOS ----  (squircle: the blue border IS the edge; rx≈Apple's mask so the
# transparent corners fall outside iOS's superellipse mask)
cp "$OUT/icon.png" "$ROOT/ios/app/Assets.xcassets/AppIcon.appiconset/icon_1024.png"
echo "✓ iOS    icon_1024.png (squircle, border-at-edge)"

# ---- Android mipmaps ----
declare -a D=(mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192)
for e in "${D[@]}"; do
  dir="${e%%:*}"; px="${e##*:}"; base="$ROOT/android/app/src/main/res/mipmap-$dir"
  [ -d "$base" ] || continue
  sips -z "$px" "$px" "$OUT/icon.png"  --out "$base/ic_launcher.png"       >/dev/null
  sips -z "$px" "$px" "$TMP/round.png" --out "$base/ic_launcher_round.png" >/dev/null
done
echo "✓ Android mipmap-*/ic_launcher(.png/_round.png)"
echo "done."
