program test_canvas_arcto;

{ Canvas-2D arcTo draws a real tangent arc (it was a stub that drew straight
  lines to the corner, so every rounded rect came out square on every shell).
    fpc -Mdelphi -Fu../src test_canvas_arcto.pas && ./test_canvas_arcto }

{$mode delphi}{$H+}

uses
  SysUtils, Math, Tina4RenderBackend, Tina4RasterCanvas, Tina4Canvas2D;

var
  Total, Fails: Integer;
  C: TTina4RasterCanvas;

procedure Check(Ok: Boolean; const What: string);
begin
  Inc(Total);
  if Ok then WriteLn('  ok   ', What) else begin Inc(Fails); WriteLn('  FAIL ', What); end;
end;

function Ink(X, Y: Integer): Boolean;
begin
  Result := (PCardinal(C.Bits)[Y * C.PixWidth + X] and $00FFFFFF) < $00808080;
end;

{ A 100x100 square at (10,10) with all four corners rounded to R via arcTo. }
procedure RoundRect(Ctx: TTina4Canvas2D; X, Y, W, H, R: Single);
begin
  Ctx.BeginPath;
  Ctx.MoveTo(X + R, Y);
  Ctx.ArcTo(X + W, Y, X + W, Y + H, R);
  Ctx.ArcTo(X + W, Y + H, X, Y + H, R);
  Ctx.ArcTo(X, Y + H, X, Y, R);
  Ctx.ArcTo(X, Y, X + W, Y, R);
  Ctx.ClosePath;
  Ctx.Fill;
end;

var ctx: TTina4Canvas2D; k: Integer; ok: Boolean;
begin
  Total := 0; Fails := 0;
  WriteLn('=== canvas arcTo ===');
  C := TTina4RasterCanvas.Create(120, 120);
  try
    C.FillRect(0, 0, 120, 120, $FFFFFFFF);
    ctx := TTina4Canvas2D.Create(C, 120, 120, $FFFFFFFF);
    try
      ctx.SetFillColor($FF000000);
      RoundRect(ctx, 10, 10, 100, 100, 30);
    finally ctx.Free; end;
    Check(not Ink(12, 12) and not Ink(107, 12) and not Ink(107, 107) and not Ink(12, 107),
      'all four corners are cut away (rounded, not square)');
    Check(Ink(60, 60) and Ink(60, 12) and Ink(12, 60), 'the body and the straight edges are filled');
    // the 45° point of the top-left arc: centre (40,40), r 30 → (18.8,18.8); just inside is ink
    Check(Ink(22, 22), 'the arc passes through its 45° point (ink just inside it)');
    Check(not Ink(15, 15), 'outside the arc stays empty');
    // symmetry: every corner cut identically
    ok := True;
    for k := 0 to 15 do
      if Ink(10 + k, 10 + k) <> Ink(109 - k, 109 - k) then ok := False;
    Check(ok, 'opposite corners are rounded identically');
  finally
    C.Free;
  end;
  WriteLn(Total - Fails, '/', Total, ' assertions passed.');
  if Fails = 0 then WriteLn('ALL TESTS PASS')
  else begin WriteLn('FAILURES: ', Fails); Halt(1); end;
end.
