program test_small_percent;

{ Percentage widths that used to collide with ParseLength's sentinels: 0–1.5%
  read as LEN_AUTO (-1) and ~3% as the old fit-content marker (-3), so a
  progress bar at 1% or 3% painted FULL width. They now resolve like any other
  percentage, and fit-content / auto keep their meaning.
    fpc -Mdelphi -Fu../src -Fu../3d test_small_percent.pas && ./test_small_percent }

{$mode delphi}{$H+}

uses
  SysUtils, Tina4RenderBackend, Tina4RasterCanvas, Tina4Interact;

const
  VW = 440; VH = 200; TRACK = 400;
  PCTS: array[0..4] of string = ('0.5', '1', '1.5', '3', '50');
  WANT: array[0..4] of Integer = (2, 4, 6, 12, 200);

var
  Total, Fails: Integer;
  Canvas: TTina4RasterCanvas;

procedure Check(Ok: Boolean; const What: string);
begin
  Inc(Total);
  if Ok then WriteLn('  ok   ', What) else begin Inc(Fails); WriteLn('  FAIL ', What); end;
end;

{ Black pixels painted on row Y. }
function Ink(Y: Integer): Integer;
var x: Integer;
begin
  Result := 0;
  for x := 0 to Canvas.PixWidth - 1 do
    if (PCardinal(Canvas.Bits)[Y * Canvas.PixWidth + x] and $00FFFFFF) = 0 then Inc(Result);
end;

var
  page: string; i, n: Integer;
begin
  Total := 0; Fails := 0;
  WriteLn('=== small percentage widths ===');
  page := '<body style="margin:0;background:#ffffff">';
  for i := 0 to High(PCTS) do
    page := page + Format('<div style="width:%dpx;height:10px;margin-bottom:10px;background:#eeeeee">' +
      '<div style="height:10px;width:%s%%;background:#000000"></div></div>', [TRACK, PCTS[i]]);
  // fit-content still shrinks to its content; auto still fills
  page := page + '<div style="width:fit-content;height:10px;background:#000000"><span style="display:inline-block;width:30px;height:10px"></span></div>';
  page := page + '<div style="height:10px;margin-top:10px;background:#000000"></div>';
  page := page + '</body>';

  Canvas := TTina4RasterCanvas.Create(VW, VH);
  try
    TinaInit(Canvas);
    TinaSetHtml(page);
    TinaFrame(VW, VH, 1);
    for i := 0 to High(PCTS) do
    begin
      n := Ink(i * 20 + 5);
      Check(Abs(n - WANT[i]) <= 1, Format('width:%s%% of %dpx paints %dpx (got %d)', [PCTS[i], TRACK, WANT[i], n]));
    end;
    n := Ink(Length(PCTS) * 20 + 5);
    Check(Abs(n - 30) <= 1, Format('width:fit-content still shrinks to its 30px content (got %d)', [n]));
    n := Ink(Length(PCTS) * 20 + 25);
    Check(n = VW, Format('width:auto still fills the line (got %d of %d)', [n, VW]));
  finally
    Canvas.Free;
  end;
  WriteLn(Total - Fails, '/', Total, ' assertions passed.');
  if Fails = 0 then WriteLn('ALL TESTS PASS')
  else begin WriteLn('FAILURES: ', Fails); Halt(1); end;
end.
