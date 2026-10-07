program test_sparkpaint;
{ Pin down WHY the hero's sparks don't show. Replicates the real spark exactly —
  a node added at runtime (AppendChild → _dyn) into a position:fixed #sparks
  container, with the clip-path star shape and the opacity animation — then
  samples the painted pixel. Builds up in layers so a FAIL localises the cause:
    A plain absolute spark (baseline, known good)
    + inside position:fixed #sparks
    + with clip-path:polygon star
  If a stage stops painting here (raster backend), the fault is in the shared
  engine; if all stages paint here but the desktop app shows nothing, it is the
  Windows shell. }
{$mode delphi}{$H+}

uses SysUtils,
     Tina4RenderBackend, Tina4RasterCanvas, Tina4Interact, Tina4Events,
     Tina4Canvas2D, Tina4Builtins, Tina4HTMLDom;

const VW = 320; VH = 240;
var Canvas: TTina4RasterCanvas; Fails: Integer = 0;

type PCardinal32 = ^Cardinal;
function PixelPink(px, py: Integer): Boolean;
var c: Cardinal; R, G, B: Integer;
begin
  c := PCardinal32(PByte(Canvas.Bits) + (py * Canvas.PixWidth + px) * 4)^;
  R := (c shr 16) and $FF; G := (c shr 8) and $FF; B := c and $FF;
  Result := (R > 180) and (G < 190) and (R > G + 40);
end;

procedure Check(Cond: Boolean; const Msg: string);
begin
  if Cond then WriteLn('  ok   ', Msg)
  else begin WriteLn('  FAIL ', Msg); Inc(Fails); end;
end;

{ Add a spark <i> at (left,top) size 40 into the element id=containerId. }
procedure AddSpark(const containerId: string);
var box, s: THTMLTag;
begin
  box := FindById(BuiltinsRoot, containerId);
  if box = nil then begin WriteLn('  (no container ', containerId, ')'); Exit; end;
  s := CreateElement('i');
  SetAttr(s, 'class', 'spark');
  SetStyleProp(s, 'left', '40px'); SetStyleProp(s, 'top', '40px');
  SetStyleProp(s, 'width', '40px'); SetStyleProp(s, 'height', '40px');
  AppendChild(box, s);
end;

procedure Stage(const name, css, bodyInner, containerId: string);
begin
  WriteLn('-- ', name);
  TinaSetHtml('<head><style>' +
    '@keyframes sparkle-fly{0%{opacity:1}70%{opacity:1}100%{opacity:0}}' + css +
    '</style></head><body style="margin:0">' + bodyInner + '</body>');
  TinaFrame(VW, VH, 1);
  AddSpark(containerId);
  TinaInvalidateLayout;                      // real app does this via TinaHover's BuiltinsDirty->GLayoutDirty
  TinaFrame(VW, VH, 1);                     // clock 0 → opacity 1
  WriteLn('     boxtree: ', Copy(TinaBoxTree, 1, 300));
  Check(PixelPink(60, 60), name + ': spark paints at t=0');
end;

const
  STAR = 'clip-path:polygon(50% 0,61% 39%,100% 50%,61% 61%,50% 100%,39% 61%,0 50%,39% 39%);';
  ANIM = 'opacity:0;animation:sparkle-fly .62s ease-out forwards;';
begin
  WriteLn('=== spark paint localisation ===');
  Canvas := TTina4RasterCanvas.Create(VW, VH);
  try
    TinaInit(Canvas);

    Stage('0 dynamic node, NO animation (plain pink square)',
      '#box{position:relative;width:100vw;height:100vh}' +
      '.spark{position:absolute;background:#ff78bb}',
      '<div id="box"></div>', 'box');

    Stage('A absolute spark in a plain div (baseline)',
      '#box{position:relative;width:100vw;height:100vh}' +
      '.spark{position:absolute;background:#ff78bb;' + ANIM + '}',
      '<div id="box"></div>', 'box');

    Stage('B inside position:fixed #sparks',
      '#sparks{position:fixed;left:0;top:0;width:100vw;height:100vh}' +
      '.spark{position:absolute;background:#ff78bb;' + ANIM + '}',
      '<div id="sparks"></div>', 'sparks');

    Stage('C fixed #sparks + clip-path star',
      '#sparks{position:fixed;left:0;top:0;width:100vw;height:100vh}' +
      '.spark{position:absolute;background:#ff78bb;' + STAR + ANIM + '}',
      '<div id="sparks"></div>', 'sparks');

    WriteLn;
    if Fails = 0 then WriteLn('ALL STAGES PAINT (engine fine → fault is the Windows shell)')
    else WriteLn(Fails, ' stage(s) FAILED to paint (engine-level fault localised above)');
  finally
    Canvas.Free;
  end;
  if Fails <> 0 then Halt(1);
end.
