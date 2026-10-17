program test_svg_currentcolor;

{ Inline <svg> resolves fill/stroke="currentColor" to its inherited CSS color,
  as browsers do (icon sets like Tabler/Lucide rely on it); an explicit color
  attribute on the <svg> still wins. Renders on the raster canvas and samples
  pixels.
    fpc -Mdelphi -Fu../src -Fu../3d test_svg_currentcolor.pas && ./test_svg_currentcolor }

{$mode delphi}{$H+}

uses
  SysUtils, Tina4RenderBackend, Tina4RasterCanvas, Tina4Interact;

const
  VW = 120; VH = 160;
  PAGE =
    '<body style="margin:0;background:#ffffff">' +
    '<div style="color:#ff0000;height:40px"><svg width="40" height="40" viewBox="0 0 10 10">' +
      '<rect width="10" height="10" fill="currentColor"/></svg></div>' +
    '<div style="color:#0000ff;height:40px"><svg width="40" height="40" viewBox="0 0 10 10" color="#00ff00">' +
      '<rect width="10" height="10" fill="currentColor"/></svg></div>' +
    '<div style="color:#0000ff;height:40px"><svg width="40" height="40" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="4">' +
      '<line x1="0" y1="5" x2="10" y2="5"/></svg></div>' +
    '</body>';

var
  Total, Fails: Integer;
  Canvas: TTina4RasterCanvas;

procedure Check(Ok: Boolean; const What: string);
begin
  Inc(Total);
  if Ok then WriteLn('  ok   ', What) else begin Inc(Fails); WriteLn('  FAIL ', What); end;
end;

function Px(X, Y: Integer): Cardinal;
begin
  Result := PCardinal(Canvas.Bits)[Y * Canvas.PixWidth + X] and $00FFFFFF;
end;

begin
  Total := 0; Fails := 0;
  WriteLn('=== inline svg currentColor ===');
  Canvas := TTina4RasterCanvas.Create(VW, VH);
  try
    TinaInit(Canvas);
    TinaSetHtml(PAGE);
    TinaFrame(VW, VH, 1);
    Check(Px(20, 20) = $FF0000, Format('fill=currentColor inherits CSS color:#ff0000 (got #%.6x)', [Px(20, 20)]));
    Check(Px(20, 60) = $00FF00, Format('an explicit color attribute on <svg> wins (got #%.6x)', [Px(20, 60)]));
    Check(Px(20, 100) = $0000FF, Format('stroke=currentColor inherits CSS color:#0000ff (got #%.6x)', [Px(20, 100)]));
  finally
    Canvas.Free;
  end;
  WriteLn(Total - Fails, '/', Total, ' assertions passed.');
  if Fails = 0 then WriteLn('ALL TESTS PASS')
  else begin WriteLn('FAILURES: ', Fails); Halt(1); end;
end.
