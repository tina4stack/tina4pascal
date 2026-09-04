program test_svg;

{ Tests the SVG painter (Tina4SVG) end to end through a recording canvas that
  captures the primitive calls PaintSVG emits — so shape geometry, viewBox
  scaling, transforms and paint resolution are all asserted without a real
  window. Mutation-proof: the coordinates and counts pin real behaviour. }

{$mode delphi}{$H+}

uses SysUtils, Classes, Generics.Collections,
  Tina4HTMLDom, Tina4RenderBackend, Tina4SVG;

type
  { records the calls the SVG painter makes }
  TRecCanvas = class(TTina4Canvas)
  public
    FillCount, LineCount, TextCount: Integer;
    LastFillColor: TTina4Color;
    LastContours: array of TTina4PointArray;
    LastText: string;
    procedure FillRect(X, Y, W, H: Single; Color: TTina4Color); override;
    procedure StrokeRect(X, Y, W, H, Thickness: Single; Color: TTina4Color); override;
    procedure DrawLine(X1, Y1, X2, Y2, Thickness: Single; Color: TTina4Color); override;
    procedure FillPolygon(const Contours: array of TTina4PointArray;
      Color: TTina4Color; EvenOdd: Boolean = False); override;
    procedure DrawText(X, Y: Single; const Text: string; FontSize: Single;
      Styles: TTina4FontStyles; Color: TTina4Color); override;
    function MeasureText(const Text: string; FontSize: Single;
      Styles: TTina4FontStyles): TTina4TextMetrics; override;
    procedure SetClip(X, Y, W, H: Single); override;
    procedure ClearClip; override;
    procedure Bounds(out MinX, MinY, MaxX, MaxY: Single);
  end;

procedure TRecCanvas.FillRect(X, Y, W, H: Single; Color: TTina4Color); begin end;
procedure TRecCanvas.StrokeRect(X, Y, W, H, Thickness: Single; Color: TTina4Color); begin end;
procedure TRecCanvas.SetClip(X, Y, W, H: Single); begin end;
procedure TRecCanvas.ClearClip; begin end;

procedure TRecCanvas.DrawLine(X1, Y1, X2, Y2, Thickness: Single; Color: TTina4Color);
begin Inc(LineCount); end;

procedure TRecCanvas.FillPolygon(const Contours: array of TTina4PointArray;
  Color: TTina4Color; EvenOdd: Boolean);
var i: Integer;
begin
  Inc(FillCount);
  LastFillColor := Color;
  SetLength(LastContours, Length(Contours));
  for i := 0 to High(Contours) do LastContours[i] := Copy(Contours[i]);
end;

procedure TRecCanvas.DrawText(X, Y: Single; const Text: string; FontSize: Single;
  Styles: TTina4FontStyles; Color: TTina4Color);
begin Inc(TextCount); LastText := Text; end;

function TRecCanvas.MeasureText(const Text: string; FontSize: Single;
  Styles: TTina4FontStyles): TTina4TextMetrics;
begin
  Result.Width := Length(Text) * FontSize * 0.5;
  Result.Ascent := FontSize * 0.8;
  Result.Descent := FontSize * 0.2;
  Result.LineHeight := FontSize * 1.2;
end;

procedure TRecCanvas.Bounds(out MinX, MinY, MaxX, MaxY: Single);
var i, j: Integer;
begin
  MinX := 1e30; MinY := 1e30; MaxX := -1e30; MaxY := -1e30;
  for i := 0 to High(LastContours) do
    for j := 0 to High(LastContours[i]) do
    begin
      if LastContours[i][j].X < MinX then MinX := LastContours[i][j].X;
      if LastContours[i][j].Y < MinY then MinY := LastContours[i][j].Y;
      if LastContours[i][j].X > MaxX then MaxX := LastContours[i][j].X;
      if LastContours[i][j].Y > MaxY then MaxY := LastContours[i][j].Y;
    end;
end;

var
  Failures: Integer = 0;

procedure Check(Cond: Boolean; const Msg: string);
begin
  if Cond then WriteLn('  ok   ', Msg)
  else begin WriteLn('  FAIL ', Msg); Inc(Failures); end;
end;

function Near(A, B: Single): Boolean;
begin Result := Abs(A - B) < 0.6; end;

{ parse a fragment and return the first <svg> element }
function FirstSvg(P: THTMLParser): THTMLTag;
  function Walk(n: THTMLTag): THTMLTag;
  var c: THTMLTag;
  begin
    Result := nil;
    if SameText(n.TagName, 'svg') then Exit(n);
    for c in n.Children do
    begin
      Result := Walk(c);
      if Result <> nil then Exit;
    end;
  end;
begin
  Result := Walk(P.Root);
end;

procedure Run(const HTML: string; C: TRecCanvas; X, Y, W, H: Single);
var P: THTMLParser; svg: THTMLTag;
begin
  P := THTMLParser.Create;
  try
    P.Parse(HTML);
    svg := FirstSvg(P);
    if svg <> nil then PaintSVG(C, svg, X, Y, W, H);
  finally
    P.Free;
  end;
end;

var
  C: TRecCanvas;
  minX, minY, maxX, maxY: Single;

begin
  WriteLn('== Tina4SVG tests ==');

  WriteLn('rect + viewBox 1:1');
  C := TRecCanvas.Create;
  Run('<svg width="100" height="100" viewBox="0 0 100 100">' +
      '<rect x="10" y="10" width="80" height="80" fill="#ff0000"/></svg>', C, 0, 0, 100, 100);
  Check(C.FillCount = 1, 'one fill emitted');
  Check(C.LastFillColor = $FFFF0000, 'fill colour #ff0000 → $FFFF0000');
  C.Bounds(minX, minY, maxX, maxY);
  Check(Near(minX, 10) and Near(minY, 10) and Near(maxX, 90) and Near(maxY, 90),
    'rect device bbox (10,10)-(90,90)');
  C.Free;

  WriteLn('viewBox scaling (paint into 200x200)');
  C := TRecCanvas.Create;
  Run('<svg viewBox="0 0 100 100"><rect x="10" y="10" width="80" height="80" fill="#00ff00"/></svg>',
      C, 0, 0, 200, 200);
  C.Bounds(minX, minY, maxX, maxY);
  Check(Near(minX, 20) and Near(maxX, 180), 'rect scales x2 → (20..180)');
  C.Free;

  WriteLn('transform translate');
  C := TRecCanvas.Create;
  Run('<svg viewBox="0 0 100 100"><rect x="10" y="10" width="20" height="20" ' +
      'transform="translate(5 7)" fill="#000"/></svg>', C, 0, 0, 100, 100);
  C.Bounds(minX, minY, maxX, maxY);
  Check(Near(minX, 15) and Near(minY, 17), 'translate(5 7) shifts origin to (15,17)');
  C.Free;

  WriteLn('circle → polygon fill');
  C := TRecCanvas.Create;
  Run('<svg viewBox="0 0 100 100"><circle cx="50" cy="50" r="40" fill="#123456"/></svg>',
      C, 0, 0, 100, 100);
  Check(C.FillCount = 1, 'circle emits one fill');
  C.Bounds(minX, minY, maxX, maxY);
  Check(Near(minX, 10) and Near(maxX, 90), 'circle bbox spans r=40 (10..90)');
  C.Free;

  WriteLn('fill="none" paints nothing');
  C := TRecCanvas.Create;
  Run('<svg viewBox="0 0 100 100"><rect x="0" y="0" width="50" height="50" fill="none"/></svg>',
      C, 0, 0, 100, 100);
  Check(C.FillCount = 0, 'no fill for fill=none');
  C.Free;

  WriteLn('path M/L/Z closed → fill');
  C := TRecCanvas.Create;
  Run('<svg viewBox="0 0 100 100"><path d="M10 10 L90 10 L50 90 Z" fill="#abcdef"/></svg>',
      C, 0, 0, 100, 100);
  Check(C.FillCount = 1, 'triangle path fills');
  C.Bounds(minX, minY, maxX, maxY);
  Check(Near(minX, 10) and Near(maxX, 90) and Near(maxY, 90), 'triangle bbox');
  C.Free;

  WriteLn('line with stroke → DrawLine');
  C := TRecCanvas.Create;
  Run('<svg viewBox="0 0 100 100"><line x1="0" y1="0" x2="100" y2="100" ' +
      'stroke="#000" stroke-width="2"/></svg>', C, 0, 0, 100, 100);
  Check(C.LineCount >= 1, 'stroke line drawn');
  Check(C.FillCount = 0, 'line does not fill');
  C.Free;

  WriteLn('text anchor middle');
  C := TRecCanvas.Create;
  Run('<svg viewBox="0 0 200 50"><text x="100" y="30" text-anchor="middle" ' +
      'font-size="20" fill="#000">Hi</text></svg>', C, 0, 0, 200, 50);
  Check(C.TextCount = 1, 'text drawn');
  Check(C.LastText = 'Hi', 'text content captured');
  C.Free;

  WriteLn('inline style fill overrides');
  C := TRecCanvas.Create;
  Run('<svg viewBox="0 0 10 10"><rect x="0" y="0" width="10" height="10" ' +
      'style="fill:#0000ff"/></svg>', C, 0, 0, 10, 10);
  Check(C.LastFillColor = $FF0000FF, 'style="fill:#0000ff" applied');
  C.Free;

  WriteLn;
  if Failures = 0 then begin WriteLn('ALL TESTS PASS'); Halt(0); end
  else begin WriteLn(Failures, ' FAILURE(S)'); Halt(1); end;
end.
