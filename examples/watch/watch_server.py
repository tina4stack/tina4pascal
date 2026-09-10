#!/usr/bin/env python3
"""Watch render server — the Mac runs the Tina4 engine and streams frames.

The Apple Watch can't run the engine (FPC has no watchOS target), so we render
the watch HTML HERE with the real engine (examples/htmlviewer/htmlviewer, which
uses the native Cocoa/Core Text canvas) at the watch's exact pixel resolution,
and serve it:

  GET /frame            -> a PNG of the current watch UI (engine-rendered)
  GET /tap?x=..&y=..    -> dispatch a tap (toggles the wink), returns "ok"

The watchOS app polls /frame and draws it 1:1, and posts taps to /tap. Fill and
resolution are correct by construction because the frame IS the watch screen.

Run:  python3 examples/watch/watch_server.py
"""
import http.server, subprocess, tempfile, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
HTMLVIEWER = os.path.join(HERE, "..", "htmlviewer", "htmlviewer")
CSS_W, CSS_H = 208, 248          # watch points; the engine renders at 2x -> 416x496 px
PORT = 8723

state = {"wink": False}

def build_html():
    # left eye: a closed line when winked, an open circle otherwise
    le = "top:63px;height:6px" if state["wink"] else "top:53px;height:26px"
    return f"""<!doctype html><html><head><style>
      html,body{{margin:0;width:{CSS_W}px;height:{CSS_H}px;background:#0e0f1f}}
      .face{{position:absolute;top:49px;left:29px;width:150px;height:150px;border-radius:50%;background:#ffd23c}}
      .eye{{position:absolute;width:26px;height:26px;top:53px;border-radius:50%;background:#15162e}}
      .r{{left:90px}}
      #le{{left:38px;{le};border-radius:50%;position:absolute;width:26px;background:#15162e}}
      .mouth{{position:absolute;left:37px;top:92px;width:76px;height:42px;background:#15162e;border-radius:6px 6px 52px 52px}}
      .lip{{position:absolute;left:37px;top:92px;width:76px;height:21px;background:#ffd23c}}
    </style></head><body>
      <div class="face"><div class="eye" id="le"></div><div class="eye r"></div>
      <div class="mouth"></div><div class="lip"></div></div>
    </body></html>"""

def render_png():
    d = tempfile.mkdtemp()
    hp, pp = os.path.join(d, "w.html"), os.path.join(d, "w.png")
    open(hp, "w").write(build_html())
    subprocess.run([HTMLVIEWER, hp, "--snapshot", pp, "--width", str(CSS_W),
                    "--height", str(CSS_H)], capture_output=True)
    return open(pp, "rb").read() if os.path.exists(pp) else b""

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path.startswith("/tap"):
            state["wink"] = not state["wink"]
            self.send_response(200); self.send_header("Content-Length", "2")
            self.end_headers(); self.wfile.write(b"ok"); return
        png = render_png()
        self.send_response(200)
        self.send_header("Content-Type", "image/png")
        self.send_header("Content-Length", str(len(png)))
        self.end_headers(); self.wfile.write(png)

if __name__ == "__main__":
    print(f"watch render server on http://127.0.0.1:{PORT}  (frame={CSS_W*2}x{CSS_H*2}px)")
    http.server.HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
