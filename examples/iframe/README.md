# iframe — a live web page inside a native page

A tina4pascal page with an `<iframe>` showing a page from a local server. The
native page is drawn by the engine. Only the frame is a web view, and it is the
operating system's own (WKWebView on macOS). Nothing is bundled with the app.
See [ADR-0016](../../plan/adr/0016-iframe-hosts-the-os-web-view.md).

## Run it (macOS)

Serve the page the frame shows:

```bash
python3 -m http.server 8765 --bind 127.0.0.1 -d examples/iframe/site
```

Build and open the app:

```bash
sh examples/iframe/build.sh --run
```

## What to try

- **Click inside the frame.** The button counts clicks with real JavaScript.
- **Scroll inside the frame.** The web page scrolls on its own.
- **Scroll the native page.** The frame moves with it and stays in its box.
- **Second page.** The native button changes the iframe's `src`, and the same
  web view loads the new page in place.
- **Hide / show.** `display:none` takes the iframe out of the layout, so the
  shell removes the web view. Showing it again creates a fresh one.

## How it works

The engine lays `<iframe>` out as a sized box: HTML's default 300×150, the
`width`/`height` attributes, or CSS. It reports the box to the shell as an
embed (`TinaEmbedKind = 5`, with `TinaEmbedRect`, `TinaEmbedSrc` and
`TinaEmbedKey`). Each frame, the Cocoa shell puts a `WKWebView` over that box,
the same way it overlays `AVPlayerView` on a `<video>`.

`build.sh` sets `NSAllowsLocalNetworking` in the app's `Info.plist`, so the web
view can load plain `http://` from `127.0.0.1` without opening App Transport
Security to the internet.

`--autoscroll N` scrolls the native page down N px after about a second, which
is handy for checking the frame's position.
