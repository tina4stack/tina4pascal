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
PORT = 8723

state = {"wink": False}

def build_html(w, h):
    # Everything sized/centred from the watch's own points, so it fits any screen
    # (Series 7 is smaller than Series 11 — a fixed layout got chopped).
    face = int(min(w, h) * 0.74)
    fl, ft = (w - face) // 2, (h - face) // 2
    eye = int(face * 0.15)
    eyeY = ft + int(face * 0.30)
    eL = fl + int(face * 0.24)
    eR = fl + face - int(face * 0.24) - eye
    if state["wink"]:                      # left eye closes to a line
        leH = max(4, int(eye * 0.25)); leY = eyeY + (eye - leH) // 2
    else:
        leH = eye; leY = eyeY
    mW, mH = int(face * 0.50), int(face * 0.30)
    mL, mT = fl + (face - mW) // 2, ft + int(face * 0.54)
    dk = "#15162e"
    return f"""<body style="margin:0;width:{w}px;height:{h}px;background:#0e0f1f">
      <div style="position:absolute;left:{fl}px;top:{ft}px;width:{face}px;height:{face}px;border-radius:50%;background:#ffd23c"></div>
      <div style="position:absolute;left:{eR}px;top:{eyeY}px;width:{eye}px;height:{eye}px;border-radius:50%;background:{dk}"></div>
      <div style="position:absolute;left:{eL}px;top:{leY}px;width:{eye}px;height:{leH}px;border-radius:50%;background:{dk}"></div>
      <div style="position:absolute;left:{mL}px;top:{mT}px;width:{mW}px;height:{mH}px;background:{dk};border-radius:{mH//6}px {mH//6}px {mH}px {mH}px"></div>
      <div style="position:absolute;left:{mL}px;top:{mT}px;width:{mW}px;height:{mH//2}px;background:#ffd23c"></div>
    </body>"""

def render_png(w, h):
    d = tempfile.mkdtemp()
    hp, pp = os.path.join(d, "w.html"), os.path.join(d, "w.png")
    open(hp, "w").write(build_html(w, h))
    subprocess.run([HTMLVIEWER, hp, "--snapshot", pp, "--width", str(w),
                    "--height", str(h)], capture_output=True)
    return open(pp, "rb").read() if os.path.exists(pp) else b""

import urllib.parse

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        w = int(q.get("w", ["208"])[0]); h = int(q.get("h", ["248"])[0])
        if self.path.startswith("/tap"):
            state["wink"] = not state["wink"]
            self.send_response(200); self.send_header("Content-Length", "2")
            self.end_headers(); self.wfile.write(b"ok"); return
        png = render_png(w, h)
        self.send_response(200)
        self.send_header("Content-Type", "image/png")
        self.send_header("Content-Length", str(len(png)))
        self.end_headers(); self.wfile.write(png)

if __name__ == "__main__":
    print(f"watch render server on http://127.0.0.1:{PORT}  (frame={CSS_W*2}x{CSS_H*2}px)")
    http.server.HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
