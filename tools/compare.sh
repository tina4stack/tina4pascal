#!/bin/sh
# Side-by-side conformance check: render a page with the native Tina4Pascal
# viewer and with headless Chrome at the same viewport, then stack the two
# images for visual diffing. This is the harness behind docs/CONFORMANCE.md —
# work through each page, confirm each feature, flip the matrix row.
#
# Usage: tools/compare.sh <page.html> [width] [height]
#   page.html is resolved under examples/pages/ (or an absolute path)
# Output: /tmp/tina4-compare/<page>.{ours,chrome,stacked}.png
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PAGE="$1"; W="${2:-1024}"; H="${3:-800}"
[ -f "$PAGE" ] || PAGE="$REPO/examples/pages/$PAGE"
[ -f "$PAGE" ] || { echo "page not found: $1"; exit 1; }
NAME="$(basename "$PAGE" .html)"
OUT=/tmp/tina4-compare; mkdir -p "$OUT"

VIEW="$REPO/examples/htmlviewer"
export PPC_CONFIG_PATH="$HOME/fpc/etc"
# build viewer if stale
( cd "$VIEW" && "$HOME/fpc/bin/fpc" -Mdelphi -Fu../../src htmlviewer.pas >/dev/null 2>&1 )
# copy the page next to the viewer so relative CSS/cache resolves
cp "$PAGE" "$VIEW/$NAME.html"

# ours (drive one snapshot then quit)
DRV="$OUT/$NAME.drive"; printf 'snap %s/%s.ours.png\nquit\n' "$OUT" "$NAME" > "$DRV"
( cd "$VIEW" && ./htmlviewer "$NAME.html" --script "$DRV" >/dev/null 2>&1 )

# chrome reference
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
"$CHROME" --headless --disable-gpu --hide-scrollbars \
  --screenshot="$OUT/$NAME.chrome.png" --window-size="$W,$H" \
  "file://$VIEW/$NAME.html" >/dev/null 2>&1

# stack them (ours on top) if both exist
if [ -f "$OUT/$NAME.ours.png" ] && [ -f "$OUT/$NAME.chrome.png" ]; then
  python3 - "$OUT/$NAME" <<'PY'
import sys
from PIL import Image, ImageDraw
base = sys.argv[1]
a = Image.open(base + ".ours.png").convert("RGB")
b = Image.open(base + ".chrome.png").convert("RGB")
w = max(a.width, b.width)
gap = 24
canvas = Image.new("RGB", (w, a.height + b.height + gap*2), (230,230,230))
canvas.paste(a, (0, gap))
canvas.paste(b, (0, a.height + gap*2))
d = ImageDraw.Draw(canvas)
d.text((8, 4), "TINA4PASCAL", fill=(200,20,90))
d.text((8, a.height + gap + 4), "CHROME", fill=(20,90,200))
canvas.save(base + ".stacked.png")
print(base + ".stacked.png")
PY
else
  echo "missing render(s); see $OUT"
fi
