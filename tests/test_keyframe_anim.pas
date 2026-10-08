program test_keyframe_anim;
{ Regression test for the CSS `animation` SHORTHAND parser (ADR: @keyframes).

  The app-driven hero spawns sparkle stars styled with
      animation: sparkle-fly .62s ease-out forwards;
  The base rule sets opacity:0 and only the @keyframes lifts it, so if the
  shorthand parser mis-reads a token the element stays invisible.

  The bug this guards: `forwards` (animation-fill-mode) fell through every
  branch of the shorthand tokeniser to `else AnimName := token`, OVERWRITING
  the real name (`sparkle-fly`) with `forwards`. KeyframeStops('forwards')
  then finds nothing, ApplyKeyframeAnim bails, and opacity is stuck at 0 —
  no stars on any platform. Here we read the element's computed opacity back
  through TinaHitTestInfo and assert the animation actually drives it. }
{$mode delphi}{$H+}

uses SysUtils,
     Tina4RenderBackend, Tina4RasterCanvas, Tina4Interact, Tina4Events, Tina4Canvas2D;

const
  VW = 320; VH = 240;

var
  Canvas: TTina4RasterCanvas;
  Fails: Integer = 0; Total: Integer = 0;

procedure Check(Cond: Boolean; const Msg: string);
begin
  Inc(Total);
  if Cond then WriteLn('  ok   ', Msg)
  else begin WriteLn('  FAIL ', Msg); Inc(Fails); end;
end;

{ Read the painted pixel at (px,py) from the raster buffer ($AARRGGBB). This is
  the REAL paint path — ApplyKeyframeAnim mutates opacity during the frame, so a
  pixel sample sees the animated result (a hit-test only sees static style). }
type PCardinal32 = ^Cardinal;
procedure PixelAt(px, py: Integer; out R, G, B: Integer);
var c: Cardinal;
begin
  c := PCardinal32(PByte(Canvas.Bits) + (py * Canvas.PixWidth + px) * 4)^;
  R := (c shr 16) and $FF; G := (c shr 8) and $FF; B := c and $FF;
end;

{ Is the pixel the pink spark (#ff78bb) rather than the background? }
function IsPink(px, py: Integer): Boolean;
var R, G, B: Integer;
begin
  PixelAt(px, py, R, G, B);
  Result := (R > 180) and (G < 190) and (B < 220) and (R > G + 40);
end;

const
  PAGE =
    '<head><style>' +
    '@keyframes sparkle-fly {' +
    '  0%   { opacity:1; }' +
    '  70%  { opacity:1; }' +
    '  100% { opacity:0; }' +
    '}' +
    '.spark { position:absolute; left:40px; top:40px; width:40px; height:40px;' +
    '         background:#ff78bb; opacity:0;' +
    '         animation:sparkle-fly .62s ease-out forwards; }' +
    '</style></head>' +
    '<body style="margin:0">' +
    '<i class="spark"></i></body>';

var
  litT0, litMid, faded: Boolean;
begin
  WriteLn('=== CSS animation shorthand (fill-mode) test ===');
  Canvas := TTina4RasterCanvas.Create(VW, VH);
  try
    TinaInit(Canvas);
    TinaSetHtml(PAGE);

    { Clock at 0: keyframe 0% is opacity:1, so the pink star paints.
      Pre-fix (AnimName clobbered to 'forwards') it stays at the base 0 → nothing. }
    TinaFrame(VW, VH, 1);
    litT0 := IsPink(60, 60);
    Check(litT0, 'at t=0 the spark paints pink (animation lifts opacity off 0)');

    { ~0.3s in — still on the opacity:1 plateau (0%..70%). }
    AnimAdvance(0.30); TinaFrame(VW, VH, 1);
    litMid := IsPink(60, 60);
    Check(litMid, 'mid-flight the spark is still painted');

    { Past the end (>0.62s) — faded out. }
    AnimAdvance(0.50); TinaFrame(VW, VH, 1);
    faded := not IsPink(60, 60);
    Check(faded, 'after the animation the spark has faded away');

    Check(litT0 and faded, 'the @keyframes animation actually DRIVES the paint (lit -> faded)');

    WriteLn;
    if Fails = 0 then WriteLn('ALL TESTS PASS')
    else WriteLn(Fails, ' of ', Total, ' FAILED');
  finally
    Canvas.Free;
  end;
  if Fails <> 0 then Halt(1);
end.
