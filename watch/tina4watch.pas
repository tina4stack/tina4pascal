library tina4watch;

{ Tina4 watchOS engine library (C ABI) — the watch renders HTML itself.

  Unlike the iOS/macOS shells (UIKit/Cocoa Core Text), watchOS has no UIKit
  canvas, so this shell drives the pure-Pascal software renderer: the shared
  Tina4Interact engine paints the DOM into a Tina4RasterCanvas, and we hand the
  raw RGBA buffer back to the Swift/WatchKit host to blit. Same engine, same
  HTML, same events as every other platform — only the canvas is the portable
  raster one instead of a native OS canvas.

  Built for -Twatchossim -Paarch64 by watch/build.sh into libtina4watch.a; the
  watchOS app (watch/) links it and calls these four entry points. Because the
  renderer is 100% Pascal (no OS drawing), the SAME .a serves the physical watch
  once FPC gains the arm64_32 slice (docs/FPC-WATCHOS-PLAN.md, phase 2).

  Contract:
    tina4watch_init(w,h)              create the raster canvas at w×h px
    tina4watch_set_html(utf8)         load a document
    tina4watch_render(w,h,density)    paint a frame, returns a pointer to the
                                      w*h*4 RGBA (premultiplied) pixel buffer
    tina4watch_touch(action,x,y)      dispatch a touch (see Tina4Interact);
                                      returns non-zero if the frame changed }

{$mode delphi}{$H+}

uses
  SysUtils,
  Tina4RenderBackend,
  Tina4RasterCanvas,
  Tina4Interact
  { A project's own action units (tina4.json "appUnits") splice in here, exactly
    like the iOS/Android shells; each registers its named onclick actions in its
    own initialization so the app's Pascal logic ships inside libtina4watch.a. }
  {$I app_units.inc} ;

var
  GCanvas: TTina4RasterCanvas = nil;

procedure EnsureCanvas(W, H: Integer);
begin
  if GCanvas = nil then
  begin
    GCanvas := TTina4RasterCanvas.Create(W, H);
    TinaInit(GCanvas);
  end
  else
    GCanvas.Resize(W, H);
end;

procedure tina4watch_init(W, H: Integer); cdecl;
begin
  EnsureCanvas(W, H);
end;

procedure tina4watch_set_html(Html: PAnsiChar); cdecl;
begin
  if Html <> nil then
    TinaSetHtml(string(AnsiString(Html)));
end;

{ paint a frame and return the RGBA buffer (w*h*4 bytes). The pointer stays
  valid until the next init/render at a different size. }
function tina4watch_render(W, H: Integer; Density: Single): Pointer; cdecl;
begin
  EnsureCanvas(W, H);
  TinaFrame(W, H, Density);
  Result := GCanvas.Bits;
end;

function tina4watch_touch(Action: Integer; X, Y: Single): Integer; cdecl;
begin
  Result := TinaTouch(Action, X, Y);
end;

exports
  tina4watch_init,
  tina4watch_set_html,
  tina4watch_render,
  tina4watch_touch;

begin
end.
