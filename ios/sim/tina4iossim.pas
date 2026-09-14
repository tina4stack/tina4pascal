library tina4iossim;

{ Tina4 iOS *Simulator* engine library (C ABI).

  FPC 3.2.2 has no simulator target, so the device build (ios/tina4ios.pas, the
  native UIKit / Core Graphics / Core Text shell) can't target the Simulator.
  The PATCHED trunk compiler (~/fpc-watchos/bin/ppca64) DOES have the upstream
  `iphonesim` target (arm64 LP64), so we build the engine for the iOS Simulator
  here — and render through the pure-Pascal software rasterizer, the same path
  the Apple Watch uses. Same engine, same DOM, same layout, same events as every
  other platform; only the final blit is the portable raster one rather than the
  native Core Graphics canvas.

  Why raster and not the native CG/CT shell: Tina4ShellIOS pulls the `univint`
  framework bindings, which aren't built for the `aarch64-iphonesim` RTL yet
  (docs/OUTSTANDING.md, category F). Raster needs only the RTL, so the Simulator
  runs the engine today; the native-CG-on-sim upgrade is a follow-up.

  Built for -Tiphonesim -Paarch64 by ios/build-sim.sh into libtina4iossim.a; the
  Simulator app (ios/sim/App) links it and calls these four entry points.

  Contract (mirrors watch/tina4watch.pas):
    tina4sim_init(w,h)              create the raster canvas at w×h px
    tina4sim_set_html(utf8)        load a document
    tina4sim_render(w,h,density)   paint a frame, returns a pointer to the
                                   w*h*4 RGBA (premultiplied) pixel buffer
    tina4sim_touch(action,x,y)     dispatch a touch (see Tina4Interact);
                                   returns non-zero if the frame changed }

{$mode delphi}{$H+}

uses
  SysUtils,
  Tina4RenderBackend,
  Tina4RasterCanvas,
  Tina4Interact
  { A project's own action units (tina4.json "appUnits") splice in here, exactly
    like the iOS/Android/watch shells; each registers its named onclick actions
    in its own initialization so the app's Pascal logic ships inside the lib. }
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

procedure tina4sim_init(W, H: Integer); cdecl;
begin
  EnsureCanvas(W, H);
end;

procedure tina4sim_set_html(Html: PAnsiChar); cdecl;
begin
  if Html <> nil then
    TinaSetHtml(string(AnsiString(Html)));
end;

{ paint a frame and return the RGBA buffer (w*h*4 bytes). The pointer stays
  valid until the next init/render at a different size. }
function tina4sim_render(W, H: Integer; Density: Single): Pointer; cdecl;
begin
  EnsureCanvas(W, H);
  TinaFrame(W, H, Density);
  Result := GCanvas.Bits;
end;

function tina4sim_touch(Action: Integer; X, Y: Single): Integer; cdecl;
begin
  Result := TinaTouch(Action, X, Y);
end;

exports
  tina4sim_init,
  tina4sim_set_html,
  tina4sim_render,
  tina4sim_touch;

begin
end.
