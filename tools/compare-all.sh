#!/bin/zsh
# compare-all.sh — sweep EVERY compliance page ours-vs-Chrome and build one
# "endless" side-by-side PNG plus a pass/fail summary.
#
# Why this exists: the reftest suite (run-compliance.sh) only compares
# ours-test vs ours-ref, so a ref that reproduces our OWN wrong output hides a
# real divergence from browsers (this is exactly how the flex reverse-packing
# and column-wrap bugs slipped through). This tool renders the same pages in
# headless Chrome and diffs against them.
#
# Two things make the diff trustworthy:
#   * ours snapshots are sRGB (TCocoaShell.Snapshot converts P3->sRGB), so
#     saturated colours compare byte-exact to Chrome's sRGB output;
#   * the viewport is >=520px — old headless Chrome clamps narrower windows to
#     ~500px, which silently changes margin:auto / %-width / flex / wrap layout.
#
# Usage:
#   tools/compare-all.sh [--width W] [--height H] [--font "Family"]
#                        [--filter GLOB] [--threshold PCT] [--open]
#   --font pins a common default font on BOTH sides so text pages (which set no
#          font-family) stop diverging on face selection alone; tests that set
#          their own font-family still win.
#   --filter limits to matching ids (e.g. 'flex*'). --open reveals the PNG.
#
# Output: build/compare-all/endless.png  +  a printed summary (worst first).
# Exit 1 if any non-expected page exceeds the threshold.
set -e
ROOT="${0:A:h:h}"
HV="$ROOT/examples/htmlviewer/htmlviewer"
CHROME="${TINA4_CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
OUT="$ROOT/build/compare-all"; ROWS="$OUT/rows"
W=800; H=520; FONT=""; FILTER="*"; THRESH=6; OPEN=0
while [ $# -gt 0 ]; do case "$1" in
  --width) W=$2; shift 2;; --height) H=$2; shift 2;; --font) FONT=$2; shift 2;;
  --filter) FILTER=$2; shift 2;; --threshold) THRESH=$2; shift 2;; --open) OPEN=1; shift;;
  *) echo "unknown arg $1"; exit 2;; esac; done

# expected divergences (custom elements, synthetic fonts, approximations) — shown
# but never counted as failures. Extend as features are explained.
EXPECT="camera-view|barcode|font-smallcaps|font-stretch|fontface|svg-radial-gradient|text-uppercase|text-lowercase|text-capitalize|bg-blend|css-blend|lottie|qrcode|video|audio|recorder"

setopt NULL_GLOB 2>/dev/null || true    # empty globs expand to nothing, not an error
mkdir -p "$ROWS"; rm -f "$ROWS"/*.png 2>/dev/null || true
[ -x "$HV" ] || { echo "htmlviewer not built — building..."; \
  (cd "$ROOT/examples/htmlviewer" && PPC_CONFIG_PATH=$HOME/fpc/etc PATH=$HOME/fpc/bin:$PATH \
   fpc -Mdelphi -Fu../../src htmlviewer.pas >/dev/null); }

n=0
for f in "$ROOT"/examples/compliance/${~FILTER}-test.html; do
  [ -e "$f" ] || continue
  id=$(basename "$f" -test.html); src="$f"
  if [ -n "$FONT" ]; then    # prepend a default font both engines resolve; tests with their own font-family still win
    src="$OUT/$id.html"
    printf '<style>body{font-family:%s}</style>' "\"$FONT\",sans-serif" > "$src"
    cat "$f" >> "$src"
  fi
  "$HV" "$src" --snapshot "$ROWS/$id-o.png" --width $W --height $H >/dev/null 2>&1 || true
  "$CHROME" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    --screenshot="$ROWS/$id-c.png" --window-size=$W,$H --default-background-color=FFFFFFFF \
    "file://$src" >/dev/null 2>&1 || true
  n=$((n+1))
done
echo "rendered $n pages at ${W}x${H}${FONT:+, font=$FONT}"

TINA4_EXPECT="$EXPECT" TINA4_THRESH="$THRESH" python3 - "$ROWS" "$OUT/endless.png" <<'PY'
import sys, os, glob, re
from PIL import Image, ImageChops, ImageDraw, ImageFont
ROWS, OUTPNG = sys.argv[1], sys.argv[2]
EXPECT = re.compile(os.environ.get("TINA4_EXPECT","(?!)"))
THRESH = float(os.environ.get("TINA4_THRESH","6"))
def diff(a,b):
    if a.size!=b.size: a=a.resize(b.size, Image.LANCZOS)   # ours is 2x retina
    d=ImageChops.difference(a,b).convert("L")
    return 100*sum(d.histogram()[40:])/(b.width*b.height)
rows=[]
for op in sorted(glob.glob(os.path.join(ROWS,"*-o.png"))):
    n=os.path.basename(op)[:-6]; cp=os.path.join(ROWS,f"{n}-c.png")
    if not os.path.exists(cp): continue
    o=Image.open(op).convert("RGB"); c=Image.open(cp).convert("RGB")
    rows.append((n,o,c,diff(o,c)))
# summary
fails=[(n,p) for n,o,c,p in rows if p>THRESH and not EXPECT.search(n)]
worst=sorted(((p,n,bool(EXPECT.search(n))) for n,o,c,p in rows), reverse=True)
print("\n=== worst 15 (diff%, page, expected?) ===")
for p,n,ex in worst[:15]: print(f"  {p:5.1f}%  {n}{'   (expected)' if ex else ''}")
g=sum(1 for *_,p in rows if p<=2); a=sum(1 for *_,p in rows if 2<p<=THRESH)
print(f"\n{len(rows)} pages: {g} green(<=2%)  {a} amber  {len(rows)-g-a} over-threshold; "
      f"{len(fails)} unexpected failure(s)")
# endless PNG
W,H=300,195; pad=14; lblh=26; gap=8; mid=10
try: font=ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Bold.ttf",13); fsm=ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf",11)
except: font=fsm=ImageFont.load_default()
rowh=lblh+H+gap; im=Image.new("RGB",(pad*2+W*2+mid, pad+34+rowh*len(rows)),(248,248,250)); d=ImageDraw.Draw(im)
d.text((pad,pad),f"Tina4Pascal vs Chrome — {len(rows)} pages (ours | chrome)",fill=(20,20,30),font=font)
d.text((pad,pad+18),f"green <=2%  amber <={THRESH:g}%  red over; sRGB snapshots, matched viewport",fill=(90,90,110),font=fsm)
y=pad+34
for n,o,c,p in rows:
    ex=bool(EXPECT.search(n))
    col=(30,150,70) if p<=2 else (200,140,20) if p<=THRESH else ((120,120,140) if ex else (200,50,50))
    d.rectangle([pad,y,pad+6,y+lblh+H],fill=col)
    d.text((pad+12,y+4),n+("  (expected)" if ex else ""),fill=(20,20,30),font=font)
    d.text((pad+12,y+lblh-2),f"{p:.1f}%",fill=col,font=fsm)
    yy=y+lblh
    im.paste(o.resize((W,H)),(pad,yy)); im.paste(c.resize((W,H)),(pad+W+mid,yy))
    for bx in (pad, pad+W+mid): d.rectangle([bx,yy,bx+W,yy+H],outline=(205,205,215))
    d.text((pad+2,yy+2),"ours",fill=(150,150,165),font=fsm); d.text((pad+W+mid+2,yy+2),"chrome",fill=(150,150,165),font=fsm)
    y+=rowh
im.save(OUTPNG); print(f"endless PNG -> {OUTPNG}  ({im.size[0]}x{im.size[1]})")
sys.exit(1 if fails else 0)
PY
rc=$?
[ $OPEN -eq 1 ] && open "$OUT/endless.png" 2>/dev/null || true
exit $rc
