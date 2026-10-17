program test_canvas_text;

{ Canvas-2D text baselines land where the HTML canvas spec puts them, using the
  backend's measured metrics: 'middle' centres the glyphs on Y (the bug was a
  fixed 0.35em lift from a TOP-anchored draw, which left centred text low),
  'alphabetic' puts the baseline on Y, 'top' hangs the box from Y.

    fpc -Mdelphi -Fu../src test_canvas_text.pas && ./test_canvas_text }

{$mode delphi}{$H+}

uses
  SysUtils, Tina4RenderBackend, Tina4RasterCanvas, Tina4Canvas2D;

const
  W = 200; H = 200; FS = 40; INK = $FF000000; BG = $FFFFFFFF;

var
  Total, Fails: Integer;

procedure Check(Ok: Boolean; const What: string);
begin
  Inc(Total);
  if Ok then WriteLn('  ok   ', What) else begin Inc(Fails); WriteLn('  FAIL ', What); end;
end;

{ Rows [top, bottom] that contain ink. }
procedure InkRows(C: TTina4RasterCanvas; out Top, Bottom: Integer);
var px: PCardinal; x, y: Integer;
begin
  Top := -1; Bottom := -1;
  px := C.Bits;
  for y := 0 to C.PixHeight - 1 do
    for x := 0 to C.PixWidth - 1 do
      if (px[y * C.PixWidth + x] and $00FFFFFF) < $00808080 then
      begin
        if Top < 0 then Top := y;
        Bottom := y;
        Break;
      end;
end;

function Draw(const Baseline: string; Y: Single; out Top, Bottom: Integer): Boolean;
var c: TTina4RasterCanvas; ctx: TTina4Canvas2D;
begin
  c := TTina4RasterCanvas.Create(W, H);
  try
    c.FillRect(0, 0, W, H, BG);
    ctx := TTina4Canvas2D.Create(c, W, H, BG);
    try
      ctx.SetFont(FS, True, False);
      ctx.SetTextAlign('center');
      ctx.SetTextBaseline(Baseline);
      ctx.SetFillColor(INK);
      ctx.FillText('8', W / 2, Y);
    finally ctx.Free; end;
    InkRows(c, Top, Bottom);
    Result := Top >= 0;
  finally c.Free; end;
end;

var
  t, b: Integer; mid: Single; m: TTina4TextMetrics; rc: TTina4RasterCanvas;
begin
  Total := 0; Fails := 0;
  WriteLn('=== canvas text baselines (raster backend, ', FS, 'px) ===');
  rc := TTina4RasterCanvas.Create(10, 10);
  try m := rc.MeasureText('8', FS, []); finally rc.Free; end;

  Check(Draw('middle', 100, t, b), 'middle: glyph drawn');
  mid := (t + b) / 2;
  Check(Abs(mid - 100) <= FS * 0.06,
    Format('middle: ink centred on Y=100 (ink rows %d..%d, centre %.1f)', [t, b, mid]));

  Check(Draw('alphabetic', 100, t, b), 'alphabetic: glyph drawn');
  Check(Abs(b - 100) <= FS * 0.06,
    Format('alphabetic: digit bottom sits on the baseline Y=100 (bottom row %d)', [b]));

  Check(Draw('top', 100, t, b), 'top: glyph drawn');
  Check(t >= 100, Format('top: nothing drawn above Y=100 (top row %d)', [t]));

  Check(Draw('bottom', 100, t, b), 'bottom: glyph drawn');
  Check(b <= 100 + 1, Format('bottom: nothing drawn below Y=100 (bottom row %d)', [b]));

  WriteLn(Total - Fails, '/', Total, ' assertions passed.');
  if Fails = 0 then WriteLn('ALL TESTS PASS')
  else begin WriteLn('FAILURES: ', Fails); Halt(1); end;
end.
