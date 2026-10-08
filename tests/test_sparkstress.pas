program test_sparkstress;
{ Repro harness for the app-driven hero's sparkle crash. Mirrors AppHero.Spawn:
  on each "mouse move" it appends a CSS-animated <i class="spark"> to a #sparks
  container and, past a cap, removes the oldest — while the engine relayouts and
  paints the animating nodes every frame. Drives it headlessly (no Win shell, so
  the GDI+ scale cache is NOT involved) so a crash here proves the fault is in the
  shared engine's node-churn/animation/paint path, not the Windows backend.

  Pass = survives the churn and reports a non-zero live spark count. }
{$mode delphi}{$H+}

uses SysUtils, Math,
     Tina4RenderBackend, Tina4RasterCanvas, Tina4Interact, Tina4Events,
     Tina4Canvas2D, Tina4Builtins, Tina4HTMLDom;

const
  VW = 1600; VH = 1000;   // large viewport, like a maximised window
  MAX_SPARKS = 64;
  MOVES = 400;

var
  Canvas: TTina4RasterCanvas;
  Sparks: THTMLTag = nil;
  FS: TFormatSettings;
  Fails: Integer = 0;

procedure Spawn(x, y: Single);
var s: THTMLTag; ang, dist, sz: Double;
begin
  if Sparks = nil then Exit;
  ang := Random * 2 * Pi; dist := 26 + Random * 36; sz := 6 + Random * 8;
  s := CreateElement('i');
  SetAttr(s, 'class', 'spark');
  SetStyleProp(s, 'left',   Format('%.0fpx', [x], FS));
  SetStyleProp(s, 'top',    Format('%.0fpx', [y], FS));
  SetStyleProp(s, 'width',  Format('%.0fpx', [sz], FS));
  SetStyleProp(s, 'height', Format('%.0fpx', [sz], FS));
  SetStyleProp(s, '--dx',   Format('%.1fpx', [Cos(ang) * dist], FS));
  SetStyleProp(s, '--dy',   Format('%.1fpx', [Sin(ang) * dist], FS));
  AppendChild(Sparks, s);
  while ChildCount(Sparks) > MAX_SPARKS do
    RemoveNode(ChildAt(Sparks, 0));
end;

const
  PAGE =
    '<head><style>' +
    '@keyframes sparkle-fly { 0%{opacity:1} 70%{opacity:1} 100%{opacity:0} }' +
    '#sparks { position:fixed; left:0; top:0; width:100vw; height:100vh; }' +
    '.spark { position:absolute; background:#ff78bb; opacity:0;' +
    '         animation:sparkle-fly .62s ease-out forwards; }' +
    '</style></head><body style="margin:0"><div id="sparks"></div></body>';

var i, live: Integer;
begin
  WriteLn('=== sparkle node-churn stress ===');
  FS := DefaultFormatSettings; FS.DecimalSeparator := '.';
  Randomize;
  Canvas := TTina4RasterCanvas.Create(VW, VH);
  try
    TinaInit(Canvas);
    TinaSetHtml(PAGE);
    TinaFrame(VW, VH, 1);
    Sparks := FindById(BuiltinsRoot, 'sparks');
    if Sparks = nil then begin WriteLn('  FAIL #sparks not found'); Halt(1); end;

    for i := 1 to MOVES do
    begin
      Spawn(Random * VW, Random * VH);
      Spawn(Random * VW, Random * VH);   // two per move, like HeroMove
      BuiltinsDirty := True;
      TinaFrame(VW, VH, 1);              // relayout + paint the animating nodes
      AnimAdvance(0.016);                // ~60fps clock so sparks age + retire
    end;

    live := ChildCount(Sparks);
    WriteLn(Format('  survived %d moves; %d live sparks', [MOVES, live]));
    if (live <= 0) or (live > MAX_SPARKS) then
    begin WriteLn('  FAIL unexpected live spark count'); Inc(Fails); end
    else WriteLn('  ok   spark count stays bounded and non-empty');

    WriteLn;
    if Fails = 0 then WriteLn('ALL TESTS PASS') else WriteLn(Fails, ' FAILED');
  finally
    Canvas.Free;
  end;
  if Fails <> 0 then Halt(1);
end.
