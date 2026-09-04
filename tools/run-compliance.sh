#!/bin/sh
# W3C-style reftest runner for the Tina4Pascal renderer.
#
# Methodology (same as Web Platform Tests reftests): each test is a pair
#   examples/compliance/<id>-test.html   — uses the feature under test
#   examples/compliance/<id>-ref.html    — same visual from known-good primitives
# The renderer snapshots BOTH; if they match (mean pixel delta below
# threshold) the feature PASSES. Chrome renders the -test file too, so a
# human can confirm the test itself is correct (the reference is trusted).
#
# Usage: tools/run-compliance.sh [id-glob]     (default: all)
# Output: /tmp/tina4-compliance/*.png and a printed PASS/FAIL table;
#         report.html stacks every failing pair for inspection.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$REPO/examples/compliance"
VIEW="$REPO/examples/htmlviewer"
OUT=/tmp/tina4-compliance; mkdir -p "$OUT"
GLOB="${1:-*}"
THRESH="${TINA4_REFTEST_THRESH:-0.5}"   # max %% of pixels allowed to differ
export PPC_CONFIG_PATH="$HOME/fpc/etc"

( cd "$VIEW" && "$HOME/fpc/bin/fpc" -Mdelphi -Fu../../src htmlviewer.pas >/dev/null 2>&1 ) \
  || { echo "viewer build failed"; exit 1; }

snap() { # <html-file> <out-png>
  # headless off-screen render: no window, no focus steal, exits on its own
  ( cd "$VIEW" && ./htmlviewer "$1" --snapshot "$2" >/dev/null 2>&1 )
}

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
pass=0; fail=0; results=""
for testf in "$DIR"/$GLOB-test.html; do
  [ -f "$testf" ] || continue
  id="$(basename "$testf" -test.html)"
  reff="$DIR/$id-ref.html"
  [ -f "$reff" ] || { echo "SKIP  $id (no -ref)"; continue; }
  snap "$testf" "$OUT/$id.test.png"
  snap "$reff"  "$OUT/$id.ref.png"
  "$CHROME" --headless --disable-gpu --hide-scrollbars \
    --screenshot="$OUT/$id.chrome.png" --window-size=1024,800 \
    "file://$testf" >/dev/null 2>&1
  verdict="$(python3 - "$OUT/$id.test.png" "$OUT/$id.ref.png" "$THRESH" <<'PY'
import sys
from PIL import Image, ImageChops
try:
    t = Image.open(sys.argv[1]).convert("RGB")
    r = Image.open(sys.argv[2]).convert("RGB")
except Exception as e:
    print("ERR 0"); sys.exit()
w = min(t.width, r.width); h = min(t.height, r.height)
t = t.crop((0,0,w,h)); r = r.crop((0,0,w,h))
# per-pixel max channel delta; count pixels that differ beyond a small epsilon
d = ImageChops.difference(t, r).convert("L")  # luminance of the diff
hist = d.histogram()
EPS = 16
diff_px = sum(hist[EPS+1:])
total = w*h
frac = 100.0 * diff_px / total if total else 0.0
# PASS when < THRESH % of pixels differ meaningfully
print(("PASS" if frac <= float(sys.argv[3]) else "FAIL") + " %.2f%%" % frac)
PY
)"
  v="$(echo "$verdict" | awk '{print $1}')"
  m="$(echo "$verdict" | awk '{print $2}')"
  if [ "$v" = "PASS" ]; then pass=$((pass+1)); else fail=$((fail+1)); fi
  printf '%-5s %-28s delta=%s\n' "$v" "$id" "$m"
  results="$results$v|$id|$m\n"
done
echo "----------------------------------------"
echo "PASS $pass   FAIL $fail"

# report.html: stack test/ref/chrome for every FAIL
python3 - "$OUT" <<PY
import os,glob
out="$OUT"
rows=[]
for tp in sorted(glob.glob(os.path.join(out,"*.test.png"))):
    idv=os.path.basename(tp)[:-9]
    rows.append(idv)
html=["<!doctype html><meta charset=utf8><style>body{font:14px system-ui;background:#eee}",
".t{display:flex;gap:8px;margin:16px;background:#fff;padding:8px;border-radius:8px}",
".t img{max-width:32%;border:1px solid #ccc}.lbl{width:120px}</style>"]
for idv in rows:
    html.append(f'<div class=t><div class=lbl><b>{idv}</b><br>ours / ref / chrome</div>')
    for suf in ("test","ref","chrome"):
        p=f"{idv}.{suf}.png"
        if os.path.exists(os.path.join(out,p)): html.append(f'<img src="{p}">')
    html.append('</div>')
open(os.path.join(out,"report.html"),"w").write("".join(html))
print("report:", os.path.join(out,"report.html"))
PY
