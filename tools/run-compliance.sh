#!/bin/sh
# W3C-style reftest runner for the Tina4Pascal renderer.
#
# Methodology (same as Web Platform Tests reftests): each test is a pair
#   examples/compliance/<id>-test.html   — uses the feature under test
#   examples/compliance/<id>-ref.html    — same visual from known-good primitives
# The renderer snapshots BOTH; if they match (mean pixel delta below
# threshold) the feature PASSES.
#
# Usage: tools/run-compliance.sh [id-glob]     (default: all)
# Speed: snapshots fan out across all CPU cores; the verdict needs only our
#   own test/ref PNGs, so Chrome is OFF by default. Set TINA4_REFTEST_CHROME=1
#   to also capture Chrome shots for the human report (much slower: one cold
#   Chrome start per test). TINA4_REFTEST_JOBS overrides the parallelism.
# Output: /tmp/tina4-compliance/*.png and a printed PASS/FAIL table;
#         report.html stacks every failing pair for inspection.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$REPO/examples/compliance"
VIEW="$REPO/examples/htmlviewer"
OUT=/tmp/tina4-compliance; mkdir -p "$OUT"
export PPC_CONFIG_PATH="$HOME/fpc/etc"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# --- internal worker: render one id's test+ref (+ chrome if asked) ---------
# Invoked in parallel via xargs (portable: re-exec self, no `export -f`).
if [ "${1:-}" = "__snap" ]; then
  id="$2"
  ( cd "$VIEW" && ./htmlviewer "$DIR/$id-test.html" --snapshot "$OUT/$id.test.png" >/dev/null 2>&1 )
  ( cd "$VIEW" && ./htmlviewer "$DIR/$id-ref.html"  --snapshot "$OUT/$id.ref.png"  >/dev/null 2>&1 )
  if [ "${TINA4_REFTEST_CHROME:-0}" = "1" ]; then
    "$CHROME" --headless --disable-gpu --hide-scrollbars \
      --screenshot="$OUT/$id.chrome.png" --window-size=1024,800 \
      "file://$DIR/$id-test.html" >/dev/null 2>&1
  fi
  exit 0
fi

GLOB="${1:-*}"
THRESH="${TINA4_REFTEST_THRESH:-0.5}"   # max %% of pixels allowed to differ
JOBS="${TINA4_REFTEST_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

( cd "$VIEW" && "$HOME/fpc/bin/fpc" -Mdelphi -Fu../../src htmlviewer.pas >/dev/null 2>&1 ) \
  || { echo "viewer build failed"; exit 1; }

# collect ids that have both -test and -ref
ids=""
for testf in "$DIR"/$GLOB-test.html; do
  [ -f "$testf" ] || continue
  id="$(basename "$testf" -test.html)"
  [ -f "$DIR/$id-ref.html" ] || { echo "SKIP  $id (no -ref)"; continue; }
  ids="$ids $id"
done

# fan the snapshots out across cores (the renderer runs are independent)
printf '%s\n' $ids | xargs -P "$JOBS" -I{} "$0" __snap {}

# one Python pass compares every pair, prints the table, builds the report
python3 - "$OUT" "$THRESH" $ids <<'PY'
import sys, os, glob
from PIL import Image, ImageChops
out, thresh = sys.argv[1], float(sys.argv[2])
ids = sys.argv[3:]
def delta(a, b):
    try:
        t = Image.open(a).convert("RGB"); r = Image.open(b).convert("RGB")
    except Exception:
        return None
    w = min(t.width, r.width); h = min(t.height, r.height)
    t = t.crop((0,0,w,h)); r = r.crop((0,0,w,h))
    d = ImageChops.difference(t, r).convert("L")
    diff_px = sum(d.histogram()[17:])   # channels differing beyond EPS=16
    total = w*h
    return 100.0*diff_px/total if total else 0.0
pass_n = fail_n = 0
for idv in ids:
    frac = delta(os.path.join(out, idv+".test.png"), os.path.join(out, idv+".ref.png"))
    if frac is None:
        v, m = "ERR", "n/a"
    else:
        v = "PASS" if frac <= thresh else "FAIL"; m = "%.2f%%" % frac
    if v == "PASS": pass_n += 1
    else: fail_n += 1
    print("%-5s %-28s delta=%s" % (v, idv, m))
print("----------------------------------------")
print("PASS %d   FAIL %d" % (pass_n, fail_n))
# report.html: stack test/ref/chrome for inspection
rows = sorted(os.path.basename(tp)[:-9] for tp in glob.glob(os.path.join(out,"*.test.png")))
html = ["<!doctype html><meta charset=utf8><style>body{font:14px system-ui;background:#eee}",
        ".t{display:flex;gap:8px;margin:16px;background:#fff;padding:8px;border-radius:8px}",
        ".t img{max-width:32%;border:1px solid #ccc}.lbl{width:120px}</style>"]
for idv in rows:
    html.append('<div class=t><div class=lbl><b>%s</b><br>ours / ref / chrome</div>' % idv)
    for suf in ("test","ref","chrome"):
        p = "%s.%s.png" % (idv, suf)
        if os.path.exists(os.path.join(out, p)): html.append('<img src="%s">' % p)
    html.append('</div>')
open(os.path.join(out,"report.html"),"w").write("".join(html))
print("report:", os.path.join(out,"report.html"))
PY
