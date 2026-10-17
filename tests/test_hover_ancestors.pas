program test_hover_ancestors;

{ :hover applies to the hovered element's ancestors too (CSS Selectors 4). The
  hit test returns the deepest BOX under the pointer — an <svg> icon, a nested
  block — so pointing at it must still hover its container (`.btn:hover`,
  `.btn:hover + .tip`). Raster render + pixel samples.
    fpc -Mdelphi -Fu../src -Fu../3d test_hover_ancestors.pas && ./test_hover_ancestors }

{$mode delphi}{$H+}

uses
  SysUtils, Tina4RenderBackend, Tina4RasterCanvas, Tina4Interact;

const
  VW = 200; VH = 160;
  PAGE =
    '<html><head><style>' +
    '.btn{width:40px;height:40px;background:#eeeeee}' +
    '.btn:hover{background:#ff0000}' +
    '.tip{display:none;width:40px;height:20px;background:#0000ff}' +
    '.btn:hover + .tip{display:block}' +
    '.card{position:absolute;left:100px;top:0;width:80px;height:80px;background:#eeeeee}' +
    '.card:hover{background:#00ff00}' +
    '.inner{width:40px;height:40px;background:#888888}' +
    '</style></head><body style="margin:0;background:#ffffff">' +
    '<div class="btn"><svg viewBox="0 0 24 24" width="24" height="24"><rect width="24" height="24" fill="#000000"/></svg></div>' +
    '<div class="tip"></div>' +
    '<div class="card"><div class="inner"></div></div>' +
    '</body></html>';

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
  WriteLn('=== :hover reaches ancestors ===');
  Canvas := TTina4RasterCanvas.Create(VW, VH);
  try
    TinaInit(Canvas);
    TinaSetHtml(PAGE);
    TinaFrame(VW, VH, 1);
    Check(Px(35, 35) = $EEEEEE, 'button starts un-hovered');
    TinaHover(10, 10);                       // over the <svg> icon inside the button
    TinaFrame(VW, VH, 1);
    Check(Px(35, 35) = $FF0000, Format('pointer on the svg icon hovers the button (got #%.6x)', [Px(35, 35)]));
    Check(Px(10, 50) = $0000FF, Format('.btn:hover + .tip shows the sibling tip (got #%.6x)', [Px(10, 50)]));
    TinaHover(110, 10);                      // over a nested block inside the card
    TinaFrame(VW, VH, 1);
    Check(Px(170, 70) = $00FF00, Format('pointer on a nested block hovers the card (got #%.6x)', [Px(170, 70)]));
    Check(Px(35, 35) = $EEEEEE, Format('moving away clears the old chain (got #%.6x)', [Px(35, 35)]));
  finally
    Canvas.Free;
  end;
  WriteLn(Total - Fails, '/', Total, ' assertions passed.');
  if Fails = 0 then WriteLn('ALL TESTS PASS')
  else begin WriteLn('FAILURES: ', Fails); Halt(1); end;
end.
