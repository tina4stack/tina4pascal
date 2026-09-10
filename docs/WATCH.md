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

## Apple Watch (Simulator) — native engine (`build watchsim`)

Stock FPC 3.2.2 has no watchOS slice, but we **added one**: a patched FPC with the
`aarch64-watchossim` target (built + tested — a Pascal program runs on the watch
sim; see [fpc-watchos-patch.md](fpc-watchos-patch.md)). With it, the engine
compiles for the watchOS **Simulator** and renders HTML on the watch itself — no
phone in the loop:

```sh
tools/tina4pascal build watchsim    # → watch/app/libtina4watch.a (arm64 watchOS-sim)
tools/tina4pascal deploy watchsim   # + build the host app and run it on a watch Simulator
```

Because the watch has no UIKit/Core Text canvas, this path uses the **pure-Pascal
software rasterizer** (`Tina4RasterCanvas`): the shared `Tina4Interact` engine
paints the DOM to an RGBA buffer and the WatchKit host wraps it in a `UIImage`.
Same HTML, same events, same engine as every other platform — "the watch renders
HTML, Pascal is the language." The C entry points the Swift app links are
`tina4watch_init`, `tina4watch_set_html`, `tina4watch_render` (returns the RGBA
buffer) and `tina4watch_touch` (see [watch/tina4watch.pas](../watch/tina4watch.pas)).
The SwiftUI host is [watch/Tina4Watch](../watch/Tina4Watch) — `EngineModel.swift`
calls `PASCALMAIN()` once, then drives render/touch and shows the engine's frames.

`deploy watchsim` needs a booted (or available) Apple Watch Simulator and builds
**arm64-only** (FPC watchossim = arm64), signing off. The raster path renders
shapes, backgrounds and border-radius, and now **numeric text**: the demo is a
live clock — `Tina4RasterCanvas.DrawText` draws digits, `:`, `.` and `-` with a
7-segment font (AA-filled segments, scales crisply), so the engine lays out and
rasterizes `HH:MM`/date/seconds on the watch every second. Letters advance but
don't draw yet — a full vector/bitmap glyph set is the follow-up; until then the
raster path (watch, headless) renders numbers and shapes, not prose.

Requires the patched toolchain at `~/fpc-watchos` (or `TINA4_WATCHOS_FPC`); build
it from [fpc-watchossim.diff](fpc-watchossim.diff). `tools/tina4pascal doctor`
reports whether it's installed. The **physical** Apple Watch is `arm64_32` (ILP32)
— a separate FPC backend (phase 2, [FPC-WATCHOS-PLAN.md](FPC-WATCHOS-PLAN.md)); for
the physical watch today, use the phone-renders mirror below.

## Apple Watch (physical) — phone renders, watch displays (the "iOS watch stream")

The physical watch has no FPC slice yet (`arm64_32`, phase 2), so the pipeline
keeps HTML as the single source and runs the engine on the **paired iPhone**:

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
