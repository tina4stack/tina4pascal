# Tina4Pascal on the watch

Two watch families, two mechanisms — but the same principle: **the watch shows
HTML rendered by the Tina4 engine.** No hand-written native watch UI.

## Samsung / Wear OS — native (done)

Wear OS is Android, and FPC already builds the Android target, so the **same
`libtina4.so` / engine runs on the watch**. Build it with:

```sh
tools/tina4pascal build wear      # Android APK + watch manifest
tools/tina4pascal deploy wear     # install/launch on a Wear OS watch or emulator
```

`TINA4_WEAR` injects `<uses-feature android:name="android.hardware.type.watch">`
+ the `wearable.standalone` flag into the manifest; the APK is `<name>-wear.apk`.
The engine renders your (watch-sized) HTML on the wrist directly. Give it a watch
layout — see `examples/watch/glance.html`.

## Apple Watch — phone renders, watch displays (the "iOS watch stream")

FPC 3.2.2 has **no watchOS slice** (`fpc -i` targets: Android, Darwin, Linux,
iOS), so the Pascal engine can't compile a native watchOS binary. But it doesn't
need to. The pipeline keeps HTML as the single source and runs the engine on the
**paired iPhone**:

```
iPhone (Tina4 engine)                         Apple Watch (thin Swift host)
 ─────────────────────                         ─────────────────────────────
 render watch HTML  ── native Core Text ─┐
   to an offscreen bitmap                 │
 read RGBA, encode JPEG                    │  WCSession.sendMessageData
                          ────────────────┼──────────────────────────►  show UIImage
                                           │
 tina4_touch(x,y) ── re-render ── push ◄──┼──  WCSession.sendMessage(tap x,y)
                                           │      (tap forwarded from the wrist)
```

Why the phone renders: the pure-Pascal `Tina4RasterCanvas` has **no text** (it's
the Lottie vector subset — `DrawText` is a no-op). Text needs a native font
engine — **Core Text on iOS**, Cocoa on macOS. So the frame the watch shows is
rendered by the phone's native canvas, exactly like the on-screen Viewer. This is
already proven on macOS: `examples/htmlviewer/htmlviewer examples/watch/glance.html
--snapshot out.png` renders the glance **with real text** — that PNG is the image
the phone would push to the wrist.

### The two pieces to wire (both native, verify on paired hardware)

**1. iOS export — render the watch HTML to RGBA.** Add to `ios/tina4ios.pas`:

```pascal
{ Render Html into a w×h RGBA8888 buffer (caller-allocated, w*h*4 bytes) at the
  given density, using an offscreen bitmap so it never touches the on-screen
  view. Returns 1 on success. The iOS shell already renders to an offscreen
  CGBitmapContext (see TIOSCanvas.BeginLayer / CGBitmapContextGetData); this
  reuses that path with its own parse+layout+paint, independent of the live
  Viewer document, so the watch shows its own page. }
function tina4_render_rgba(Html: PAnsiChar; W, H: cint; Density: single;
  OutBuf: Pointer): cint; cdecl;
```

**2. WCSession, both sides.** iOS: on a new frame (or on the "Noise detected"
event from the live-capture stack, issue #1) call `tina4_render_rgba`, JPEG the
buffer, `WCSession.sendMessageData`. Watch: receive → `UIImage` → SwiftUI
`Image`; a tap sends `{"x":…,"y":…}` back, the phone calls `tina4_touch` and
pushes the next frame. The watchOS app scaffold is in `watch/` (SwiftUI +
WatchConnectivity); it builds/runs in the watchOS Simulator (a native Swift app,
so unlike FPC there IS a simulator).

### Status

- ✅ **Render proven** (macOS Cocoa, real text) — `examples/watch/glance.html`.
- 🟡 `watch/` watchOS receiver app — scaffolded (SwiftUI + WCSession).
- ⬜ `tina4_render_rgba` (iOS) + the WCSession send — specified above; needs a
  paired iPhone + Apple Watch to verify end to end.
- Note: the glance's vertical centering (`height:100%` + flex in a fixed
  snapshot) needs a small layout tweak; the text/render itself is correct.
