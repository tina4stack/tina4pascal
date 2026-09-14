#!/bin/sh
# Golden-image tests for the pure-Pascal software rasterizer (Tina4RasterCanvas).
#
# The W3C reftest suite (tools/run-compliance.sh) renders through the NATIVE
# Cocoa canvas. This suite renders the SAME engine through the RASTER path - the
# one Android and the Apple Watch actually use - and diffs each page against a
# committed golden PNG. It's the only guard on FillRoundRect, the 7-segment and
# stroke fonts, gradients/shadows and the WebP blit, none of which the Cocoa
# reftests touch.
#
#   tools/run-raster-tests.sh                 # run + diff against goldens
#   TINA4_RASTER_BLESS=1 tools/run-raster-tests.sh   # (re)generate goldens - review the diff before committing
#
# Renderer: examples/watch/watchrender (Tina4RasterCanvas -> raw RGBA). Verdict
# is a mean-pixel delta, same idea and threshold as the reftest suite.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$REPO/tests/raster"
GOLD="$DIR/golden"
OUT=/tmp/tina4-raster; mkdir -p "$OUT" "$GOLD"
export PPC_CONFIG_PATH="$HOME/fpc/etc"
REND="$REPO/examples/watch/watchrender"
W=300; H=220

( cd "$REPO/examples/watch" && "$HOME/fpc/bin/fpc" -Mdelphi -Fu../../src watchrender.pas >/dev/null 2>&1 ) \
  || { echo "raster renderer build failed"; exit 1; }

ids="$(cd "$DIR" && ls *.html 2>/dev/null | sed 's/\.html$//')"
[ -n "$ids" ] || { echo "no test pages in $DIR"; exit 1; }
for id in $ids; do
  "$REND" "$DIR/$id.html" "$W" "$H" "$OUT/$id.rgba" >/dev/null 2>&1
done

python3 - "$OUT" "$GOLD" "$W" "$H" "${TINA4_RASTER_THRESH:-0.5}" "${TINA4_RASTER_BLESS:-0}" $ids <<'PY'
import sys, os
from PIL import Image, ImageChops
out, gold, w, h, thresh, bless = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), float(sys.argv[5]), sys.argv[6] == "1"
ids = sys.argv[7:]
def load(p):
    raw = open(p, "rb").read()                       # engine buffer is $AARRGGBB LE = BGRA bytes
    return Image.frombytes("RGBA", (w, h), raw, "raw", "BGRA").convert("RGB")
pass_n = 0; fail = []
for i in ids:
    rp = os.path.join(out, i + ".rgba")
    if not os.path.exists(rp): print("%-5s %-18s (no render)" % ("FAIL", i)); fail.append(i); continue
    img = load(rp); gp = os.path.join(gold, i + ".png")
    if bless or not os.path.exists(gp):
        img.save(gp); print("%-5s %-18s" % ("BLESS", i)); pass_n += 1; continue
    g = Image.open(gp).convert("RGB")
    d = ImageChops.difference(img, g).convert("L")
    frac = 100.0 * sum(d.histogram()[17:]) / (w * h)   # pixels differing beyond EPS=16
    v = "PASS" if frac <= thresh else "FAIL"
    (fail.append(i), None) if v == "FAIL" else None
    if v == "PASS": pass_n += 1
    print("%-5s %-18s delta=%.2f%%" % (v, i, frac))
print("-" * 32); print("PASS %d   FAIL %d" % (pass_n, len(fail)))
sys.exit(1 if fail else 0)
PY
