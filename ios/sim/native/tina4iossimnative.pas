library tina4iossimnative;

{ Tina4 iOS-Simulator engine, NATIVE canvas (Core Graphics / Core Text).

  The sibling ios/sim/tina4iossim.pas renders through the pure-Pascal raster
  canvas (portable, but the watch's rough 7-segment/stroke fonts). This one uses
  the SAME native shell the physical iPhone uses — Tina4ShellIOS's TIOSCanvas
  paints the DOM into a real CGContext with Core Graphics shapes and Core Text
  glyphs — so the Simulator renders device-identical, with system fonts and
  anti-aliasing. It's unlocked because the `univint` framework bindings now build
  for the aarch64-iphonesim RTL (built with -Mmacpas; see docs/fpc-iphonesim.md).

  Deliberately minimal: no NSURLSession HTTP, no 3D, no notifications — just the
  engine + the CG/CT canvas, so it links against the iphonesim RTL + univint with
  no extra Foundation surface. The host (ios/sim/App) owns a UIView, hands its
  CGContext to tina4sim_native_frame each draw, and forwards touches.

  Built for -Tiphonesim -Paarch64 by ios/build-sim.sh --native. Contract:
    tina4sim_native_set_html(utf8)          load a document
    tina4sim_native_frame(ctx,w,h,density)  paint the DOM into the CGContext
    tina4sim_native_touch(action,x,y)       dispatch a touch; non-zero if changed }

{$mode delphi}{$H+}

uses
  SysUtils, ctypes,
  CGContext,
  Tina4RenderBackend,
  Tina4ShellIOS,
  Tina4Interact
  {$I app_units.inc} ;

var
  GCanvas: TIOSCanvas = nil;

procedure EnsureCanvas;
begin
  if GCanvas = nil then
  begin
    GCanvas := TIOSCanvas.Create;
    TinaInit(GCanvas);
  end;
end;

{ Directory a relative <img src> resolves against (the app bundle). Set it
  before loading HTML so bundled images decode via Core Graphics / ImageIO. }
procedure tina4sim_native_set_asset_base(Dir: PAnsiChar); cdecl;
begin
  EnsureCanvas;
  if Dir <> nil then
    GCanvas.SetAssetBase(string(AnsiString(Dir)));
end;

procedure tina4sim_native_set_html(Html: PAnsiChar); cdecl;
begin
  if Html <> nil then
    TinaSetHtml(string(AnsiString(Html)));
end;

{ Paint the current document into the host's CGContext (already y-flipped to the
  engine's top-left origin by the caller's UIView). }
procedure tina4sim_native_frame(Ctx: Pointer; W, H: cint; Density: single); cdecl;
begin
  EnsureCanvas;
  GCanvas.BeginFrame(CGContextRef(Ctx));
  TinaFrame(W, H, Density);
end;

function tina4sim_native_touch(Action: cint; X, Y: single): cint; cdecl;
begin
  EnsureCanvas;
  Result := TinaTouch(Action, X, Y);
end;

exports
  tina4sim_native_set_asset_base,
  tina4sim_native_set_html,
  tina4sim_native_frame,
  tina4sim_native_touch;

begin
end.
