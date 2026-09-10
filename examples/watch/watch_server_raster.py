#!/usr/bin/env python3
"""Raster watch mirror — the Mac renders the watch face with the SAME pure-Pascal
software rasterizer the native watch uses (examples/watch/watchrender, which
drives Tina4RasterCanvas), and serves the frames so a thin display app on a
PHYSICAL Apple Watch can show them. The physical watch is arm64_32 and can't run
the engine yet (FPC phase 2), so this bridges until then — the frames are pixel-
identical to the native watchOS-sim render (same fonts, shapes, WebP images).

  GET /frame?w=&h=   -> PNG of the current clock face (engine-rendered)
  GET /tap?...       -> toggle accent, returns "ok"

Run:  python3 examples/watch/watch_server_raster.py
"""
import http.server, subprocess, tempfile, os, base64, datetime, urllib.parse
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
RENDER = os.path.join(HERE, "watchrender")
LOGO = base64.b64encode(open(os.path.join(HERE, "logo.webp"), "rb").read()).decode()
PORT = 8723
state = {"pink": False}

def clock_html(w, h):
    now = datetime.datetime.now()
    days = ["MON","TUE","WED","THU","FRI","SAT","SUN"]
    dow = days[now.weekday()]
    hhmm = now.strftime("%H:%M"); ss = now.strftime("%S")
    date = f"{dow} {now.strftime('%m-%d')}"
    accent = "#ff5aa0" if state["pink"] else "#ffd23c"
    logoSz = int(h*0.17); logoLeft=(w-logoSz)//2; logoTop=int(h*0.03)
    bigFS=int(h*0.24); bigTop=int(h*0.35)
    secFS=int(h*0.12); secTop=bigTop+bigFS+int(h*0.03)
    topFS=int(h*0.085); topTop=int(h*0.22)
    brandFS=int(h*0.09); brandTop=h-int(h*0.05)-brandFS
    def line(txt, top, fs, col):
        return (f'<div style="position:absolute;left:0px;top:{top}px;width:{w}px;'
                f'text-align:center;font-size:{fs}px;font-weight:bold;color:{col}">{txt}</div>')
    logo = (f'<img src="data:image/webp;base64,{LOGO}" style="position:absolute;'
            f'left:{logoLeft}px;top:{logoTop}px;width:{logoSz}px;height:{logoSz}px">')
    return (f'<body style="margin:0;width:{w}px;height:{h}px;background:#0e0f1f">'
            f'{logo}{line(date,topTop,topFS,"#9698b4")}{line(hhmm,bigTop,bigFS,accent)}'
            f'{line(ss,secTop,secFS,"#7d8cff")}{line("tina watch",brandTop,brandFS,"#2b41e6")}</body>')

def render_png(w, h):
    d = tempfile.mkdtemp()
    hp, rp = os.path.join(d,"c.html"), os.path.join(d,"c.rgba")
    open(hp,"w").write(clock_html(w,h))
    subprocess.run([RENDER, hp, str(w), str(h), rp], capture_output=True)
    if not os.path.exists(rp): return b""
    raw = open(rp,"rb").read()
    img = Image.frombytes("RGBA",(w,h),raw,"raw","BGRA")   # engine buffer is AARRGGBB LE
    pp = os.path.join(d,"c.png"); img.convert("RGB").save(pp)
    return open(pp,"rb").read()

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a):
        import sys; sys.stderr.write("hit %s from %s\n" % (self.path, self.client_address[0]))
    def do_GET(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        w=int(q.get("w",["198"])[0]); h=int(q.get("h",["242"])[0])
        if self.path.startswith("/tap"):
            state["pink"]=not state["pink"]
            self.send_response(200); self.send_header("Content-Length","2")
            self.end_headers(); self.wfile.write(b"ok"); return
        png=render_png(w,h)
        self.send_response(200); self.send_header("Content-Type","image/png")
        self.send_header("Content-Length",str(len(png))); self.end_headers(); self.wfile.write(png)

if __name__=="__main__":
    print(f"raster watch mirror on http://0.0.0.0:{PORT}  (renders via {RENDER})")
    http.server.HTTPServer(("0.0.0.0",PORT),Handler).serve_forever()
