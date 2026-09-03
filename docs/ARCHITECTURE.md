# Tina4 native-pascal HTML renderer — cross-platform architecture

Goal: run the Tina4 HTML renderer with Free Pascal on macOS, Windows, Linux,
Android and iOS — GUI when a display exists, headless (scriptable) when not.

## Layers

1. **Core (pure Pascal, zero OS deps)** — compiles on every FPC target
   - `Tina4HTMLDom.pas` — THTMLTag DOM, THTMLParser, TCSSRule/TCSSStyleSheet
     selector engine, TComputedStyle. Ported from `../Tina4HTMLRender.pas`.
   - `Tina4HTMLLayout.pas` (planned) — block/inline layout producing a tree of
     positioned boxes. Its ONLY outside dependency is a text-measuring
     callback supplied by the backend.

2. **Backend contract** — `Tina4RenderBackend.pas`
   - `TTina4Canvas` (abstract): FillRect, StrokeRect, DrawLine, DrawText,
     MeasureText, SetClip/ClearClip, DrawImage. Colors are $AARRGGBB Cardinals,
     coords are Single in CSS pixels.
   - `TTina4Backend` (abstract): CreateWindow(w,h,title), Invalidate, Run
     (event loop), Quit, plus event callbacks (OnPaint(Canvas), OnMouse*,
     OnKey*, OnResize).
   - The renderer paints by replaying a display list into TTina4Canvas —
     it never touches an OS API.

3. **Software renderer as the primary canvas** — `Tina4SoftCanvas.pas` (planned)
   Android forces this decision, and it is the right one everywhere:
   NativeActivity exposes only a raw ANativeWindow pixel buffer — there is no
   OS text/canvas API at the native layer. So instead of per-OS text APIs:
   - One pure-Pascal rasterizer draws the display list (rects, lines, glyphs)
     into an ARGB32 buffer. Text via a pure-Pascal TTF rasterizer
     (BeRoTTF-style, zlib-licensed, no C deps) with a bundled default font —
     text metrics are IDENTICAL on all OSes, killing per-platform layout drift.
   - Headless = the same renderer writing PNG (golden-image tests in CI) or
     recording the display list + hit-test map (assert on "what would be
     drawn", inject clicks at box coordinates). A GUI that renders this way
     is scriptable by construction.

4. **Platform shells** (one tiny unit each — window + blit + input only)
   - macOS `Tina4ShellCocoa.pas`: Objective-Pascal (CocoaAll), NSView drawRect
     blits the buffer via CGImage. No Lazarus/LCL.
   - Windows `Tina4ShellWin32.pas`: CreateWindowExW + StretchDIBits. FPC's
     internal linker → cross-compiles from any host, zero external tools.
   - Linux `Tina4ShellX11.pas`: Xlib + XPutImage (FPC ships x11 bindings).
   - Android `Tina4ShellAndroid.pas`: APK with a manifest-only NativeActivity
     loading libtina4render.so (FPC -Tandroid builds .so); ANativeWindow_lock
     → memcpy buffer; AInputQueue → events. No Java code.
     First milestone: cross-compiled test_dom run on-device via adb.
   - iOS `Tina4ShellIOS.pas`: UIView + CGImage blit (same pattern as macOS).
   Native-canvas backends (CoreText/DirectWrite quality text) can be added
   later behind the same TTina4Canvas contract if ever needed.

## Application model — HTML drives everything, no components

The public API is deliberately tiny (mirroring TTina4HTMLRender's events on
the Delphi side):

    Render.SetHTML(html);                  // or LoadFile/URL; re-render any time
    Render.OnElementClick(obj, method, params)  // from onclick="obj.method(x)"
    Render.OnFormSubmit(formName, fields)       // name/value pairs
    Render.OnLinkClick(url, var handled)
    Render.SetInnerHTML(id, fragment);     // partial updates without reflowing all

No TButton/TEdit classes exist. Inputs, buttons, selects are DRAWN by the
renderer from the HTML (styled via CSS like everything else) and surface
their state through form events. An app is: event loop + HTML strings —
which a Frond/Twig template or a Tina4 backend can generate. Because state
lives in the DOM and interaction is semantic events, the same app runs under
the headless backend unchanged (this is the "script a GUI headlessly" goal).

Weight budget: FPC static binaries with no toolkit — target a low-single-digit
MB executable per platform (vs LCL ~15-25MB, Electron ~100MB+), one .so for
Android, no runtime dependencies beyond the OS blit call.

## Why this shape

- Text measurement is the only thing layout genuinely needs from a platform;
  isolating it keeps 95% of the code target-independent.
- A display list (not immediate painting) gives: headless testing, damage
  repaint, and later GPU or PDF/PNG output backends.
- Matches the Delphi side conceptually (TTina4HTMLRender draws on FMX canvas),
  so fixes can be ported both directions.

## Build

Toolchain: FPC 3.2.2 at `~/fpc` with cross targets (see ~/fpc-dev/NOTES.md).

    # native macOS
    PPC_CONFIG_PATH=$HOME/fpc/etc $HOME/fpc/bin/fpc -Mdelphi htmlviewer.pas
    # windows / linux / android from the same Mac
    ... fpc -Mdelphi -Twin64   -Px86_64  htmlviewer.pas
    ... fpc -Mdelphi -Tlinux   -Px86_64  htmlviewer.pas
    ... fpc -Mdelphi -Tandroid -Paarch64 test_dom.pas
