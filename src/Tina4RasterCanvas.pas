unit Tina4RasterCanvas;

{ A pure-Pascal, anti-aliased software canvas that fills polygons/strokes into an
  in-memory $AARRGGBB buffer — zero OS calls, zero per-shape JNI/Core-Graphics
  overhead. Its reason to exist is performance: content that issues MANY small
  vector ops per frame (a <lottie> is dozens–hundreds of filled bezier paths)
  costs one draw call per shape when proxied to a shell canvas. On Android each of
  those is a JNI round-trip, so a rich animation saturates the main thread. Render
  it HERE instead — into a byte buffer, in native code, with no marshalling — then
  the shell blits the whole buffer ONCE (Canvas.DrawRGBA). Cost becomes O(pixels)
  in-process + a single blit, independent of shape count.

  It implements only what time-driven canvas content uses: filled/stroked paths
  (winding + even-odd), rectangles and lines. Text/images are no-ops (the Lottie
  subset has neither). Points arrive already in device pixels — TTina4Canvas2D
  bakes its matrix via Dev() before calling — so this canvas keeps no transform.

  AA: 4× vertical supersampling with exact horizontal span coverage; source-over
  compositing of straight (non-premultiplied) ARGB. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, Math, Tina4RenderBackend;

type
  TTina4RasterCanvas = class(TTina4Canvas)
  private
    FW, FH: Integer;
    FPix: array of Cardinal;     // straight $AARRGGBB, row-major, top-left origin
    FCov: array of Single;       // per-scanline coverage scratch (length FW)
    FEdgeX0, FEdgeY0, FEdgeX1, FEdgeY1: array of Single;   // edge scratch
    FEdgeN: Integer;
    procedure AddEdge(x0, y0, x1, y1: Single);
    procedure RasterFill(Color: TTina4Color; EvenOdd: Boolean;
      minX, minY, maxX, maxY: Integer);
    procedure BlendPixel(px, py: Integer; R, G, B: Byte; A: Single);
  public
    constructor Create(AW, AH: Integer);
    procedure Resize(AW, AH: Integer);
    procedure Clear(Color: TTina4Color);              // fill the whole buffer
    function  Bits: Pointer;                          // -> first pixel ($AARRGGBB[])
    property  PixWidth: Integer read FW;
    property  PixHeight: Integer read FH;
    { TTina4Canvas contract — the vector subset Lottie/canvas2d exercises }
    procedure FillPolygon(const Contours: array of TTina4PointArray;
      Color: TTina4Color; EvenOdd: Boolean = False); override;
    procedure StrokePolyline(const Pts: TTina4PointArray; Width: Single;
      Color: TTina4Color; Closed: Boolean); override;
    procedure FillRect(X, Y, W, H: Single; Color: TTina4Color); override;
    procedure StrokeRect(X, Y, W, H, Thickness: Single; Color: TTina4Color); override;
    procedure DrawLine(X1, Y1, X2, Y2, Thickness: Single; Color: TTina4Color); override;
    { unused by the time-driven subset — safe no-ops/zeros } // keeps the class concrete
    procedure DrawText(X, Y: Single; const Text: string; FontSize: Single;
      Styles: TTina4FontStyles; Color: TTina4Color); override;
    function MeasureText(const Text: string; FontSize: Single;
      Styles: TTina4FontStyles): TTina4TextMetrics; override;
    procedure SetClip(X, Y, W, H: Single); override;
    procedure ClearClip; override;
  end;

implementation

const
  SS = 2;                       // vertical supersamples per output row (× exact
                                // horizontal coverage → good AA at half the row cost)

constructor TTina4RasterCanvas.Create(AW, AH: Integer);
begin
  inherited Create;
  Resize(AW, AH);
end;

procedure TTina4RasterCanvas.Resize(AW, AH: Integer);
begin
  if AW < 1 then AW := 1;
  if AH < 1 then AH := 1;
  if (AW = FW) and (AH = FH) then Exit;
  FW := AW; FH := AH;
  SetLength(FPix, FW * FH);
  SetLength(FCov, FW);
end;

procedure TTina4RasterCanvas.Clear(Color: TTina4Color);
var i: Integer;
begin
  for i := 0 to High(FPix) do FPix[i] := Color;
end;

function TTina4RasterCanvas.Bits: Pointer;
begin
  if Length(FPix) = 0 then Result := nil else Result := @FPix[0];
end;

{ ---- compositing ------------------------------------------------------- }

procedure TTina4RasterCanvas.BlendPixel(px, py: Integer; R, G, B: Byte; A: Single);
var
  idx, sa, inv, dstAi: Integer; dst: Cardinal;
  dA, dR, dG, dB, outA, invF, sAf: Single;
  resR, resG, resB, resA: Integer;
begin
  if (px < 0) or (px >= FW) or (py < 0) or (py >= FH) then Exit;
  if A <= 0 then Exit;
  if A > 1 then A := 1;
  idx := py * FW + px;
  dst := FPix[idx];
  dstAi := (dst shr 24) and $FF;
  sa := Round(A * 255);                          // source alpha 0..255
  if dstAi = 0 then
  begin
    // straight over transparent: store source at its coverage alpha
    FPix[idx] := (Cardinal(sa) shl 24) or (Cardinal(R) shl 16)
               or (Cardinal(G) shl 8) or Cardinal(B);
    Exit;
  end;
  if dstAi = 255 then
  begin
    // FAST PATH — opaque destination (the common case: shapes over a filled box):
    // out = src*sa + dst*(255-sa), outA stays 255. Integer, no divide.
    inv := 255 - sa;
    resR := (R * sa + ((dst shr 16) and $FF) * inv + 127) div 255;
    resG := (G * sa + ((dst shr 8)  and $FF) * inv + 127) div 255;
    resB := (B * sa + (dst and $FF)         * inv + 127) div 255;
    FPix[idx] := $FF000000 or (Cardinal(resR) shl 16)
               or (Cardinal(resG) shl 8) or Cardinal(resB);
    Exit;
  end;
  // general case: both partially transparent (rare for Lottie) — float over
  sAf := A; dA := dstAi / 255;
  dR := ((dst shr 16) and $FF); dG := ((dst shr 8) and $FF); dB := (dst and $FF);
  invF := 1 - sAf;
  outA := sAf + dA * invF;
  if outA <= 0 then begin FPix[idx] := 0; Exit; end;
  resR := Round((R * sAf + dR * dA * invF) / outA);
  resG := Round((G * sAf + dG * dA * invF) / outA);
  resB := Round((B * sAf + dB * dA * invF) / outA);
  resA := Round(outA * 255);
  if resR > 255 then resR := 255; if resG > 255 then resG := 255;
  if resB > 255 then resB := 255; if resA > 255 then resA := 255;
  FPix[idx] := (Cardinal(resA) shl 24) or (Cardinal(resR) shl 16)
             or (Cardinal(resG) shl 8) or Cardinal(resB);
end;

{ ---- scanline rasterizer ---------------------------------------------- }

procedure TTina4RasterCanvas.AddEdge(x0, y0, x1, y1: Single);
begin
  if y0 = y1 then Exit;                    // horizontal edges never cross a scanline
  if FEdgeN >= Length(FEdgeX0) then
  begin
    SetLength(FEdgeX0, (FEdgeN + 16) * 2);
    SetLength(FEdgeY0, Length(FEdgeX0));
    SetLength(FEdgeX1, Length(FEdgeX0));
    SetLength(FEdgeY1, Length(FEdgeX0));
  end;
  FEdgeX0[FEdgeN] := x0; FEdgeY0[FEdgeN] := y0;
  FEdgeX1[FEdgeN] := x1; FEdgeY1[FEdgeN] := y1;
  Inc(FEdgeN);
end;

{ Fill the accumulated edge set with source-over AA into [minX..maxX,minY..maxY]. }
procedure TTina4RasterCanvas.RasterFill(Color: TTina4Color; EvenOdd: Boolean;
  minX, minY, maxX, maxY: Integer);
var
  R, G, B: Byte; baseA: Single;
  py, s, e, i, j, cnt: Integer;
  sy, x, xa, xb, cov: Single;
  xs: array of Single; dirs: array of Integer;
  wind, ixa, ixb, px: Integer;
  tmpX: Single; tmpD: Integer;
  inside: Boolean;
begin
  baseA := ((Color shr 24) and $FF) / 255;
  if baseA <= 0 then Exit;
  R := (Color shr 16) and $FF; G := (Color shr 8) and $FF; B := Color and $FF;
  if minX < 0 then minX := 0; if minY < 0 then minY := 0;
  if maxX >= FW then maxX := FW - 1; if maxY >= FH then maxY := FH - 1;
  if (minX > maxX) or (minY > maxY) then Exit;
  SetLength(xs, FEdgeN + 1); SetLength(dirs, FEdgeN + 1);
  for py := minY to maxY do
  begin
    for i := minX to maxX do FCov[i] := 0;
    for s := 0 to SS - 1 do
    begin
      sy := py + (s + 0.5) / SS;
      cnt := 0;
      for e := 0 to FEdgeN - 1 do
      begin
        if ((FEdgeY0[e] <= sy) and (FEdgeY1[e] > sy)) or
           ((FEdgeY1[e] <= sy) and (FEdgeY0[e] > sy)) then
        begin
          x := FEdgeX0[e] + (sy - FEdgeY0[e]) / (FEdgeY1[e] - FEdgeY0[e])
                 * (FEdgeX1[e] - FEdgeX0[e]);
          xs[cnt] := x;
          if FEdgeY1[e] > FEdgeY0[e] then dirs[cnt] := 1 else dirs[cnt] := -1;
          Inc(cnt);
        end;
      end;
      if cnt < 2 then Continue;
      // insertion sort crossings by x (cnt is small)
      for i := 1 to cnt - 1 do
      begin
        tmpX := xs[i]; tmpD := dirs[i]; j := i - 1;
        while (j >= 0) and (xs[j] > tmpX) do
        begin xs[j+1] := xs[j]; dirs[j+1] := dirs[j]; Dec(j); end;
        xs[j+1] := tmpX; dirs[j+1] := tmpD;
      end;
      wind := 0;
      for i := 0 to cnt - 2 do
      begin
        wind := wind + dirs[i];
        if EvenOdd then inside := ((i + 1) and 1) = 1
        else inside := wind <> 0;
        if not inside then Continue;
        xa := xs[i]; xb := xs[i + 1];
        if xb <= xa then Continue;
        if xa < minX then xa := minX;
        if xb > maxX + 1 then xb := maxX + 1;
        if xb <= xa then Continue;
        // add horizontal coverage (1/SS per sub-row), fractional at the ends
        ixa := Floor(xa); ixb := Floor(xb);
        if ixa = ixb then
          FCov[ixa] := FCov[ixa] + (xb - xa) / SS
        else
        begin
          FCov[ixa] := FCov[ixa] + (ixa + 1 - xa) / SS;
          for px := ixa + 1 to ixb - 1 do FCov[px] := FCov[px] + 1 / SS;
          if ixb <= maxX then FCov[ixb] := FCov[ixb] + (xb - ixb) / SS;
        end;
      end;
    end;
    for px := minX to maxX do
    begin
      cov := FCov[px];
      if cov > 0 then BlendPixel(px, py, R, G, B, baseA * cov);
    end;
  end;
end;

{ ---- contract ---------------------------------------------------------- }

procedure TTina4RasterCanvas.FillPolygon(const Contours: array of TTina4PointArray;
  Color: TTina4Color; EvenOdd: Boolean);
var
  i, j, n: Integer;
  minx, miny, maxx, maxy, x, y: Single;
  have: Boolean;
begin
  FEdgeN := 0;
  have := False;
  minx := 0; miny := 0; maxx := 0; maxy := 0;
  for i := 0 to High(Contours) do
  begin
    n := Length(Contours[i]);
    if n < 2 then Continue;
    for j := 0 to n - 1 do
    begin
      x := Contours[i][j].X; y := Contours[i][j].Y;
      if not have then begin minx := x; maxx := x; miny := y; maxy := y; have := True; end
      else begin
        if x < minx then minx := x; if x > maxx then maxx := x;
        if y < miny then miny := y; if y > maxy then maxy := y;
      end;
      // edge to the next vertex (wrap last→first to close the contour)
      if j < n - 1 then
        AddEdge(x, y, Contours[i][j+1].X, Contours[i][j+1].Y)
      else
        AddEdge(x, y, Contours[i][0].X, Contours[i][0].Y);
    end;
  end;
  if (not have) or (FEdgeN = 0) then Exit;
  RasterFill(Color, EvenOdd, Floor(minx), Floor(miny), Ceil(maxx), Ceil(maxy));
end;

{ Stroke a polyline by filling a quad per segment (butt caps, no fancy joins —
  Lottie strokes are thin outlines where this is visually indistinguishable). }
procedure TTina4RasterCanvas.StrokePolyline(const Pts: TTina4PointArray;
  Width: Single; Color: TTina4Color; Closed: Boolean);
var
  i, last: Integer; hw, dx, dy, len, nx, ny: Single;
  quad: array[0..0] of TTina4PointArray;
begin
  if Length(Pts) < 2 then Exit;
  hw := Width / 2; if hw < 0.35 then hw := 0.35;
  SetLength(quad[0], 4);
  if Closed then last := Length(Pts) - 1 else last := Length(Pts) - 2;
  for i := 0 to last do
  begin
    dx := Pts[(i+1) mod Length(Pts)].X - Pts[i].X;
    dy := Pts[(i+1) mod Length(Pts)].Y - Pts[i].Y;
    len := Sqrt(dx*dx + dy*dy);
    if len < 1e-4 then Continue;
    nx := -dy / len * hw; ny := dx / len * hw;      // perpendicular offset
    quad[0][0].X := Pts[i].X + nx;                   quad[0][0].Y := Pts[i].Y + ny;
    quad[0][1].X := Pts[(i+1) mod Length(Pts)].X + nx; quad[0][1].Y := Pts[(i+1) mod Length(Pts)].Y + ny;
    quad[0][2].X := Pts[(i+1) mod Length(Pts)].X - nx; quad[0][2].Y := Pts[(i+1) mod Length(Pts)].Y - ny;
    quad[0][3].X := Pts[i].X - nx;                   quad[0][3].Y := Pts[i].Y - ny;
    FillPolygon(quad, Color, False);
  end;
end;

procedure TTina4RasterCanvas.FillRect(X, Y, W, H: Single; Color: TTina4Color);
var poly: array[0..0] of TTina4PointArray;
begin
  SetLength(poly[0], 4);
  poly[0][0].X := X;     poly[0][0].Y := Y;
  poly[0][1].X := X + W; poly[0][1].Y := Y;
  poly[0][2].X := X + W; poly[0][2].Y := Y + H;
  poly[0][3].X := X;     poly[0][3].Y := Y + H;
  FillPolygon(poly, Color, False);
end;

procedure TTina4RasterCanvas.StrokeRect(X, Y, W, H, Thickness: Single; Color: TTina4Color);
var pts: TTina4PointArray;
begin
  SetLength(pts, 4);
  pts[0].X := X;     pts[0].Y := Y;
  pts[1].X := X + W; pts[1].Y := Y;
  pts[2].X := X + W; pts[2].Y := Y + H;
  pts[3].X := X;     pts[3].Y := Y + H;
  StrokePolyline(pts, Thickness, Color, True);
end;

procedure TTina4RasterCanvas.DrawLine(X1, Y1, X2, Y2, Thickness: Single; Color: TTina4Color);
var pts: TTina4PointArray;
begin
  SetLength(pts, 2);
  pts[0].X := X1; pts[0].Y := Y1; pts[1].X := X2; pts[1].Y := Y2;
  StrokePolyline(pts, Thickness, Color, False);
end;

procedure TTina4RasterCanvas.DrawText(X, Y: Single; const Text: string;
  FontSize: Single; Styles: TTina4FontStyles; Color: TTina4Color);
begin
  // no-op: the time-driven canvas subset (Lottie) has no text layers
end;

function TTina4RasterCanvas.MeasureText(const Text: string; FontSize: Single;
  Styles: TTina4FontStyles): TTina4TextMetrics;
begin
  Result.Width := 0; Result.Ascent := 0; Result.Descent := 0; Result.LineHeight := 0;
end;

procedure TTina4RasterCanvas.SetClip(X, Y, W, H: Single);
begin
  // the raster buffer is exactly the content box; nothing to clip
end;

procedure TTina4RasterCanvas.ClearClip;
begin
end;

end.
