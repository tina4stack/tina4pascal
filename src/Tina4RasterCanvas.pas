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
  (winding + even-odd), rectangles and lines. DrawText is a no-op (the Lottie
  subset has no text layers), but MeasureText returns a proportional advance-width
  APPROXIMATION — it is the canvas the headless unit tests lay out on, and a real
  width there keeps inline-block / shrink-to-fit sizing meaningful (a shell canvas
  with real font metrics is used for on-screen rendering and the reftest suite).
  Points arrive already in device pixels — TTina4Canvas2D bakes its matrix via
  Dev() before calling — so this canvas keeps no transform.

  AA: 4× vertical supersampling with exact horizontal span coverage; source-over
  compositing of straight (non-premultiplied) ARGB. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, Math, Tina4RenderBackend, Tina4Compositor;

type
  { one active clip region (device px). Rad = 0 is a plain rect; Rad > 0 rounds
    the corners (overflow:hidden + border-radius). A pixel is drawn only if it is
    inside EVERY region currently on the stack (nested overflow intersects). }
  TRasterClip = record X0, Y0, X1, Y1, Rad: Single; end;

  TTina4RasterCanvas = class(TTina4Canvas)
  private
    FW, FH: Integer;
    FPix: array of Cardinal;     // straight $AARRGGBB, row-major, top-left origin
    FCov: array of Single;       // per-scanline coverage scratch (length FW)
    FEdgeX0, FEdgeY0, FEdgeX1, FEdgeY1: array of Single;   // edge scratch
    FEdgeN: Integer;
    FClip: array of TRasterClip;   // active clip regions (the intersection to test)
    FClipSave: array of Integer;   // saved stack depths for ClearClip/RestoreState
    FTgtOX, FTgtOY: Integer;       // doc-space origin of the current draw target (0 = main buffer)
    FLayers: array of record       // offscreen layer stack (CSS filter / mix-blend-mode)
      Pix: array of Cardinal; W, H, OX, OY: Integer;
      Clip: array of TRasterClip; ClipSave: array of Integer;
    end;
    function  InClip(px, py: Integer): Boolean;
    procedure PushClipSave;
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
    { rounded rects: the base falls back to square FillRect/StrokeRect, so
      border-radius came out square on the raster path (watch + Android). Round
      it via the shared RoundRectPolygon + the AA polygon rasterizer. }
    procedure FillRoundRect(X, Y, W, H, Radius: Single; Color: TTina4Color); override;
    procedure StrokeRoundRect(X, Y, W, H, Radius, Thickness: Single; Color: TTina4Color); override;
    procedure DrawLine(X1, Y1, X2, Y2, Thickness: Single; Color: TTina4Color); override;
    { unused by the time-driven subset — safe no-ops/zeros } // keeps the class concrete
    procedure DrawText(X, Y: Single; const Text: string; FontSize: Single;
      Styles: TTina4FontStyles; Color: TTina4Color); override;
    function MeasureText(const Text: string; FontSize: Single;
      Styles: TTina4FontStyles): TTina4TextMetrics; override;
    procedure SetClip(X, Y, W, H: Single); override;
    { real rounded clip on the raster path (was a rectangular degrade), so
      overflow:hidden + border-radius clips round on watch/Android. }
    procedure ClipRoundRect(X, Y, W, H, Radius: Single); override;
    procedure ClearClip; override;
    procedure SaveState; override;
    procedure RestoreState; override;
    { mix-blend-mode: render the subtree into an offscreen buffer, then composite
      it back with the CSS blend mode. (CSS `filter`/`mask` on the layer are not
      applied here yet — a safe degrade; see docs/OUTSTANDING.md A.) }
    function  BeginLayer(X, Y, W, H, Pad: Single): Integer; override;
    procedure EndLayerFiltered(Handle: Integer; const FilterSpec, BlendMode, MaskSpec: string); override;
    function  SupportsRGBA: Boolean; override;
    procedure DrawRGBA(Buf: Pointer; BW, BH: Integer; DX, DY, DW, DH: Single); override;
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
  SetLength(FClip, 0);        // fresh frame: drop any clip/layer a prior frame left
  SetLength(FClipSave, 0);
  SetLength(FLayers, 0);
  FTgtOX := 0; FTgtOY := 0;
end;

function TTina4RasterCanvas.Bits: Pointer;
begin
  if Length(FPix) = 0 then Result := nil else Result := @FPix[0];
end;

{ ---- compositing ------------------------------------------------------- }

procedure TTina4RasterCanvas.BlendPixel(px, py: Integer; R, G, B: Byte; A: Single);
var
  idx, sa, inv, dstAi, bx, by: Integer; dst: Cardinal;
  dA, dR, dG, dB, outA, invF, sAf: Single;
  resR, resG, resB, resA: Integer;
begin
  // px,py are DOC coords; the current target may be an offscreen layer whose
  // buffer starts at (FTgtOX,FTgtOY). Clip tests stay in doc space.
  if A <= 0 then Exit;
  if (Length(FClip) > 0) and not InClip(px, py) then Exit;   // overflow:hidden / rounded clip
  bx := px - FTgtOX; by := py - FTgtOY;
  if (bx < 0) or (bx >= FW) or (by < 0) or (by >= FH) then Exit;
  if A > 1 then A := 1;
  idx := by * FW + bx;
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
  wind, ixa, ixb, px, ox: Integer;
  tmpX: Single; tmpD: Integer;
  inside: Boolean;
begin
  baseA := ((Color shr 24) and $FF) / 255;
  if baseA <= 0 then Exit;
  R := (Color shr 16) and $FF; G := (Color shr 8) and $FF; B := Color and $FF;
  // minX..maxX are DOC coords; the draw target (an offscreen layer) may start at
  // (FTgtOX,FTgtOY), so clamp to its doc extent and index FCov by the buffer x.
  ox := FTgtOX;
  if minX < FTgtOX then minX := FTgtOX; if minY < FTgtOY then minY := FTgtOY;
  if maxX >= FTgtOX + FW then maxX := FTgtOX + FW - 1;
  if maxY >= FTgtOY + FH then maxY := FTgtOY + FH - 1;
  if (minX > maxX) or (minY > maxY) then Exit;
  SetLength(xs, FEdgeN + 1); SetLength(dirs, FEdgeN + 1);
  for py := minY to maxY do
  begin
    for i := minX to maxX do FCov[i - ox] := 0;
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
          FCov[ixa - ox] := FCov[ixa - ox] + (xb - xa) / SS
        else
        begin
          FCov[ixa - ox] := FCov[ixa - ox] + (ixa + 1 - xa) / SS;
          for px := ixa + 1 to ixb - 1 do FCov[px - ox] := FCov[px - ox] + 1 / SS;
          if ixb <= maxX then FCov[ixb - ox] := FCov[ixb - ox] + (xb - ixb) / SS;
        end;
      end;
    end;
    for px := minX to maxX do
    begin
      cov := FCov[px - ox];
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

procedure TTina4RasterCanvas.FillRoundRect(X, Y, W, H, Radius: Single; Color: TTina4Color);
var poly: array[0..0] of TTina4PointArray;
begin
  if Radius <= 0 then begin FillRect(X, Y, W, H, Color); Exit; end;
  poly[0] := RoundRectPolygon(X, Y, W, H, Radius);   // shared corner-arc builder
  FillPolygon(poly, Color, False);
end;

procedure TTina4RasterCanvas.StrokeRoundRect(X, Y, W, H, Radius, Thickness: Single; Color: TTina4Color);
var pts: TTina4PointArray;
begin
  if Radius <= 0 then begin StrokeRect(X, Y, W, H, Thickness, Color); Exit; end;
  pts := RoundRectPolygon(X, Y, W, H, Radius);
  StrokePolyline(pts, Thickness, Color, True);   // closed
end;

{ Per-character advance in em (fraction of the font size), for the proportional
  text approximation below. Not a real font metric — a sane spread of narrow /
  normal / wide glyphs so shrink-to-fit widths are believable headless. }
function AsciiEm(c: Char): Single;
begin
  if c = ' ' then Result := 0.28
  else if c in ['i', 'j', 'l', '.', ',', ':', ';', '|', '!', '''', '`'] then Result := 0.28
  else if c in ['f', 't', 'r', 'I', '(', ')', '[', ']', '{', '}', '/', '\'] then Result := 0.34
  else if c in ['m', 'w', 'M', 'W', '@'] then Result := 0.90
  else if c in ['A'..'Z'] then Result := 0.70
  else Result := 0.5;
end;

function TTina4RasterCanvas.MeasureText(const Text: string; FontSize: Single;
  Styles: TTina4FontStyles): TTina4TextMetrics;
var
  i, n: Integer; em, boldf: Single; b: Integer;
begin
  { This canvas has no font engine (it exists for the Lottie vector subset), so
    it estimates advance widths proportionally — like the Linux shell's own
    no-font fallback, but per-character rather than a flat 0.5em, so a headless
    <button>/inline-block shrink-wraps to a realistic width instead of collapsing
    to its padding. The reftest/compliance suite renders through the shell
    canvases (Cocoa/X11) with real metrics and is unaffected. }
  em := 0; i := 1; n := Length(Text);
  while i <= n do
  begin
    b := Ord(Text[i]);
    if b < $80 then
    begin
      em := em + AsciiEm(Text[i]);
      Inc(i);
    end
    else
    begin
      // one multibyte codepoint ≈ 0.6em; skip its UTF-8 continuation bytes
      em := em + 0.6;
      Inc(i);
      while (i <= n) and ((Ord(Text[i]) and $C0) = $80) do Inc(i);
    end;
  end;
  boldf := 1.0;
  if tfsBold in Styles then boldf := 1.05;
  Result.Width := em * FontSize * boldf;
  Result.Ascent := FontSize * 0.8;
  Result.Descent := FontSize * 0.2;
  Result.LineHeight := FontSize;
end;

{ Native raster text. Digits + ':' '.' '-' use a 7-segment font (AA-filled
  segments — the clean look for a clock/numeric display); letters A-Z and common
  punctuation use a stroke (vector) font drawn with the AA polyline stroker, so
  both stay smooth at any size. (X,Y) is the text box top-left and advances come
  from AsciiEm, so it lines up with MeasureText and the layout. Lowercase renders
  as small-caps (mapped to A-Z); a distinct lowercase set is a later refinement. }
procedure TTina4RasterCanvas.DrawText(X, Y: Single; const Text: string;
  FontSize: Single; Styles: TTina4FontStyles; Color: TTina4Color);
const
  // segment bits: a=1 b=2 c=4 d=8 e=16 f=32 g=64 (a top, g middle, d bottom;
  // f/b upper sides, e/c lower sides)
  DIG: array[0..9] of Byte = (63, 6, 91, 79, 102, 109, 125, 7, 127, 111);
var
  fs, pen, adv, boldf, th, L, R, T, B, M, dot, cx, inset: Single;
  i, n, bcode: Integer; ch: Char;

  procedure HSeg(yc: Single);   // horizontal segment centred on yc
  begin FillRect(L + inset, yc - th / 2, (R - L) - 2 * inset, th, Color); end;
  procedure VSeg(xc, y0, y1: Single);   // vertical segment centred on xc
  begin FillRect(xc - th / 2, y0 + inset, th, (y1 - y0) - 2 * inset, Color); end;
  procedure Digit(mask: Integer);
  begin
    if (mask and 1)  <> 0 then HSeg(T);
    if (mask and 64) <> 0 then HSeg(M);
    if (mask and 8)  <> 0 then HSeg(B);
    if (mask and 32) <> 0 then VSeg(L, T, M);
    if (mask and 2)  <> 0 then VSeg(R, T, M);
    if (mask and 16) <> 0 then VSeg(L, M, B);
    if (mask and 4)  <> 0 then VSeg(R, M, B);
  end;

  { --- stroke (vector) font: letters + punctuation, normalised [0..1] within the
    glyph box, drawn with the AA polyline stroker so it stays smooth at any size.
    x→right, y→down (0 = cap top, 1 = baseline). --- }
  procedure Stroke(const P: array of Single);
  var pl: TTina4PointArray; k, m: Integer;
  begin
    m := Length(P) div 2;
    if m < 2 then Exit;
    SetLength(pl, m);
    for k := 0 to m - 1 do
    begin
      pl[k].X := L + P[2 * k]     * (R - L);
      pl[k].Y := T + P[2 * k + 1] * (B - T);
    end;
    StrokePolyline(pl, th, Color, False);
  end;
  procedure PDot(nx, ny: Single);
  var r: Single;
  begin
    r := th * 0.62;
    FillRect(L + nx * (R - L) - r, T + ny * (B - T) - r, 2 * r, 2 * r, Color);
  end;
  procedure Letter(c: Char);
  begin
    case c of
      'A': begin Stroke([0.0,1.0, 0.5,0.0, 1.0,1.0]); Stroke([0.2,0.62, 0.8,0.62]); end;
      'B': begin Stroke([0.0,0.0, 0.0,1.0]);
             Stroke([0.0,0.0, 0.6,0.0, 0.85,0.16, 0.85,0.34, 0.6,0.5, 0.0,0.5]);
             Stroke([0.0,0.5, 0.65,0.5, 0.9,0.67, 0.9,0.83, 0.65,1.0, 0.0,1.0]); end;
      'C': Stroke([0.95,0.22, 0.7,0.03, 0.35,0.03, 0.1,0.2, 0.0,0.5, 0.1,0.8, 0.35,0.97, 0.7,0.97, 0.95,0.78]);
      'D': begin Stroke([0.0,0.0, 0.0,1.0]);
             Stroke([0.0,0.0, 0.5,0.0, 0.88,0.25, 0.88,0.75, 0.5,1.0, 0.0,1.0]); end;
      'E': begin Stroke([1.0,0.0, 0.0,0.0, 0.0,1.0, 1.0,1.0]); Stroke([0.0,0.5, 0.75,0.5]); end;
      'F': begin Stroke([1.0,0.0, 0.0,0.0, 0.0,1.0]); Stroke([0.0,0.5, 0.7,0.5]); end;
      'G': Stroke([0.95,0.22, 0.7,0.03, 0.35,0.03, 0.1,0.2, 0.0,0.5, 0.1,0.8, 0.35,0.97, 0.7,0.97, 0.95,0.78, 0.95,0.55, 0.6,0.55]);
      'H': begin Stroke([0.0,0.0, 0.0,1.0]); Stroke([1.0,0.0, 1.0,1.0]); Stroke([0.0,0.5, 1.0,0.5]); end;
      'I': begin Stroke([0.5,0.0, 0.5,1.0]); Stroke([0.22,0.0, 0.78,0.0]); Stroke([0.22,1.0, 0.78,1.0]); end;
      'J': Stroke([0.85,0.0, 0.85,0.75, 0.68,0.97, 0.4,0.97, 0.18,0.78]);
      'K': begin Stroke([0.0,0.0, 0.0,1.0]); Stroke([0.95,0.0, 0.05,0.55]); Stroke([0.35,0.42, 0.95,1.0]); end;
      'L': Stroke([0.0,0.0, 0.0,1.0, 0.9,1.0]);
      'M': Stroke([0.0,1.0, 0.0,0.0, 0.5,0.55, 1.0,0.0, 1.0,1.0]);
      'N': Stroke([0.0,1.0, 0.0,0.0, 1.0,1.0, 1.0,0.0]);
      'O': Stroke([0.5,0.02, 0.83,0.18, 0.97,0.5, 0.83,0.82, 0.5,0.98, 0.17,0.82, 0.03,0.5, 0.17,0.18, 0.5,0.02]);
      'P': Stroke([0.0,1.0, 0.0,0.0, 0.6,0.0, 0.88,0.18, 0.88,0.36, 0.6,0.54, 0.0,0.54]);
      'Q': begin Stroke([0.5,0.02, 0.83,0.18, 0.97,0.5, 0.83,0.82, 0.5,0.98, 0.17,0.82, 0.03,0.5, 0.17,0.18, 0.5,0.02]);
             Stroke([0.6,0.68, 0.98,1.05]); end;
      'R': begin Stroke([0.0,1.0, 0.0,0.0, 0.6,0.0, 0.88,0.18, 0.88,0.36, 0.6,0.54, 0.0,0.54]);
             Stroke([0.45,0.54, 0.95,1.0]); end;
      'S': Stroke([0.92,0.2, 0.68,0.03, 0.32,0.03, 0.1,0.2, 0.12,0.4, 0.45,0.5, 0.75,0.58, 0.9,0.76, 0.68,0.97, 0.3,0.97, 0.08,0.8]);
      'T': begin Stroke([0.0,0.0, 1.0,0.0]); Stroke([0.5,0.0, 0.5,1.0]); end;
      'U': Stroke([0.0,0.0, 0.0,0.68, 0.2,0.93, 0.5,0.99, 0.8,0.93, 1.0,0.68, 1.0,0.0]);
      'V': Stroke([0.0,0.0, 0.5,1.0, 1.0,0.0]);
      'W': Stroke([0.0,0.0, 0.25,1.0, 0.5,0.45, 0.75,1.0, 1.0,0.0]);
      'X': begin Stroke([0.0,0.0, 1.0,1.0]); Stroke([1.0,0.0, 0.0,1.0]); end;
      'Y': begin Stroke([0.0,0.0, 0.5,0.5, 1.0,0.0]); Stroke([0.5,0.5, 0.5,1.0]); end;
      'Z': Stroke([0.0,0.0, 1.0,0.0, 0.0,1.0, 1.0,1.0]);
      ',': Stroke([0.55,0.86, 0.38,1.06]);
      '!': begin Stroke([0.5,0.0, 0.5,0.66]); PDot(0.5, 0.92); end;
      '?': begin Stroke([0.08,0.22, 0.5,0.02, 0.9,0.22, 0.5,0.5, 0.5,0.66]); PDot(0.5, 0.92); end;
      '''': Stroke([0.5,0.0, 0.4,0.24]);
      '"': begin Stroke([0.35,0.0, 0.27,0.22]); Stroke([0.62,0.0, 0.54,0.22]); end;
      '/': Stroke([0.9,0.0, 0.1,1.0]);
      '\': Stroke([0.1,0.0, 0.9,1.0]);
      '(': Stroke([0.68,0.0, 0.32,0.3, 0.32,0.7, 0.68,1.0]);
      ')': Stroke([0.32,0.0, 0.68,0.3, 0.68,0.7, 0.32,1.0]);
      '+': begin Stroke([0.5,0.26, 0.5,0.74]); Stroke([0.2,0.5, 0.8,0.5]); end;
      '=': begin Stroke([0.15,0.4, 0.85,0.4]); Stroke([0.15,0.62, 0.85,0.62]); end;
      '%': begin Stroke([0.9,0.08, 0.1,0.92]); PDot(0.24, 0.24); PDot(0.76, 0.78); end;
      '*': begin Stroke([0.5,0.1, 0.5,0.6]); Stroke([0.24,0.2, 0.76,0.5]); Stroke([0.76,0.2, 0.24,0.5]); end;
    end;
  end;
  { lowercase a-z, drawn to the x-height / ascender / descender lines (y: cap
    top 0, x-height ~0.42, baseline 1.0, descenders to ~1.26). Distinct shapes,
    not small-caps. }
  procedure Lower(c: Char);
  begin
    case c of
      'a': begin Stroke([0.8,0.5, 0.8,1.0]);
             Stroke([0.8,0.58, 0.5,0.44, 0.2,0.52, 0.1,0.72, 0.2,0.92, 0.5,1.0, 0.8,0.9]); end;
      'b': begin Stroke([0.08,0.03, 0.08,1.0]);
             Stroke([0.08,0.56, 0.38,0.44, 0.66,0.5, 0.8,0.72, 0.66,0.94, 0.38,1.0, 0.08,0.88]); end;
      'c': Stroke([0.8,0.56, 0.55,0.43, 0.25,0.48, 0.1,0.72, 0.25,0.95, 0.55,1.0, 0.8,0.88]);
      'd': begin Stroke([0.82,0.03, 0.82,1.0]);
             Stroke([0.82,0.56, 0.5,0.44, 0.2,0.5, 0.08,0.72, 0.2,0.94, 0.5,1.0, 0.82,0.88]); end;
      'e': Stroke([0.1,0.73, 0.84,0.73, 0.82,0.53, 0.55,0.43, 0.25,0.47, 0.1,0.7, 0.22,0.93, 0.52,1.0, 0.8,0.9]);
      'f': begin Stroke([0.72,0.13, 0.52,0.02, 0.38,0.12, 0.38,1.0]); Stroke([0.12,0.5, 0.68,0.5]); end;
      'g': begin Stroke([0.8,0.44, 0.8,1.06, 0.66,1.22, 0.38,1.26, 0.16,1.15]);
             Stroke([0.8,0.56, 0.5,0.44, 0.22,0.5, 0.1,0.7, 0.22,0.9, 0.5,0.97, 0.8,0.85]); end;
      'h': begin Stroke([0.1,0.03, 0.1,1.0]); Stroke([0.1,0.58, 0.4,0.44, 0.7,0.5, 0.82,0.68, 0.82,1.0]); end;
      'i': begin Stroke([0.5,0.44, 0.5,1.0]); PDot(0.5, 0.26); end;
      'j': begin Stroke([0.6,0.44, 0.6,1.08, 0.48,1.24, 0.28,1.26, 0.12,1.16]); PDot(0.6, 0.26); end;
      'k': begin Stroke([0.12,0.03, 0.12,1.0]); Stroke([0.75,0.44, 0.15,0.76]); Stroke([0.36,0.66, 0.78,1.0]); end;
      'l': Stroke([0.42,0.03, 0.42,0.88, 0.6,1.0]);
      'm': begin Stroke([0.05,0.44, 0.05,1.0]);
             Stroke([0.05,0.56, 0.28,0.44, 0.45,0.52, 0.5,0.68, 0.5,1.0]);
             Stroke([0.5,0.56, 0.72,0.44, 0.9,0.52, 0.95,0.68, 0.95,1.0]); end;
      'n': begin Stroke([0.1,0.44, 0.1,1.0]); Stroke([0.1,0.58, 0.4,0.44, 0.7,0.5, 0.82,0.68, 0.82,1.0]); end;
      'o': Stroke([0.5,0.43, 0.75,0.52, 0.85,0.72, 0.75,0.92, 0.5,1.0, 0.25,0.92, 0.15,0.72, 0.25,0.52, 0.5,0.43]);
      'p': begin Stroke([0.1,0.44, 0.1,1.26]);
             Stroke([0.1,0.56, 0.4,0.44, 0.68,0.5, 0.82,0.72, 0.68,0.94, 0.4,1.0, 0.1,0.88]); end;
      'q': begin Stroke([0.8,0.44, 0.8,1.26]);
             Stroke([0.8,0.56, 0.5,0.44, 0.22,0.5, 0.1,0.72, 0.22,0.94, 0.5,1.0, 0.8,0.88]); end;
      'r': begin Stroke([0.18,0.44, 0.18,1.0]); Stroke([0.18,0.58, 0.42,0.46, 0.68,0.46, 0.82,0.56]); end;
      's': Stroke([0.78,0.52, 0.55,0.43, 0.3,0.46, 0.22,0.6, 0.35,0.7, 0.62,0.75, 0.75,0.85, 0.62,0.98, 0.35,1.0, 0.16,0.9]);
      't': begin Stroke([0.42,0.15, 0.42,0.9, 0.56,1.0, 0.72,0.94]); Stroke([0.14,0.44, 0.7,0.44]); end;
      'u': begin Stroke([0.12,0.44, 0.12,0.85, 0.26,0.98, 0.52,1.0, 0.74,0.9, 0.82,0.75]);
             Stroke([0.82,0.44, 0.82,1.0]); end;
      'v': Stroke([0.1,0.44, 0.5,1.0, 0.9,0.44]);
      'w': Stroke([0.05,0.44, 0.25,1.0, 0.5,0.6, 0.75,1.0, 0.95,0.44]);
      'x': begin Stroke([0.12,0.44, 0.85,1.0]); Stroke([0.85,0.44, 0.12,1.0]); end;
      'y': begin Stroke([0.1,0.44, 0.52,0.98]); Stroke([0.9,0.44, 0.5,0.98, 0.3,1.24, 0.12,1.26]); end;
      'z': Stroke([0.15,0.44, 0.82,0.44, 0.15,1.0, 0.82,1.0]);
    end;
  end;
begin
  if Text = '' then Exit;
  fs := FontSize;
  boldf := 1.0; if tfsBold in Styles then boldf := 1.15;
  th := fs * 0.095 * boldf; if th < 1.2 then th := 1.2;   // stroke thickness
  inset := th * 0.85;                                      // corner gap between segments
  pen := X;
  i := 1; n := Length(Text);
  while i <= n do
  begin
    bcode := Ord(Text[i]);
    if bcode >= $80 then   // multibyte codepoint: advance only (matches MeasureText)
    begin
      pen := pen + 0.6 * fs * boldf; Inc(i);
      while (i <= n) and ((Ord(Text[i]) and $C0) = $80) do Inc(i);
      Continue;
    end;
    ch := Text[i]; Inc(i);
    adv := AsciiEm(ch) * fs * boldf;
    L := pen + fs * 0.11; R := pen + adv - fs * 0.09;   // digit body ~0.30em wide
    T := Y + fs * 0.14; B := Y + fs * 0.80; M := (T + B) / 2;
    cx := pen + adv / 2; dot := th;
    if (ch >= '0') and (ch <= '9') then
      Digit(DIG[Ord(ch) - Ord('0')])
    else if ch = ':' then
    begin
      FillRect(cx - dot / 2, T + (B - T) * 0.30 - dot / 2, dot, dot, Color);
      FillRect(cx - dot / 2, T + (B - T) * 0.70 - dot / 2, dot, dot, Color);
    end
    else if ch = '.' then
      FillRect(cx - dot / 2, B - dot, dot, dot, Color)
    else if ch = '-' then
      HSeg(M)
    else if (ch >= 'a') and (ch <= 'z') then
      Lower(ch)             // distinct lowercase glyphs (x-height / ascenders / descenders)
    else
      Letter(ch);           // A-Z + punctuation; space/unknown: nothing
    pen := pen + adv;
  end;
end;

{ A pixel (tested at its centre) passes only if it is inside every active clip
  region — the rect bounds, and the rounded corners when Rad > 0. Hard-edged
  (0/1) at the boundary; the content inside is still fully anti-aliased. }
function TTina4RasterCanvas.InClip(px, py: Integer): Boolean;
var
  i: Integer;
  cx, cy, r, dx, dy: Single;
begin
  cx := px + 0.5; cy := py + 0.5;
  for i := 0 to High(FClip) do
    with FClip[i] do
    begin
      if (cx < X0) or (cx >= X1) or (cy < Y0) or (cy >= Y1) then Exit(False);
      if Rad > 0 then
      begin
        r := Rad;
        if r > (X1 - X0) * 0.5 then r := (X1 - X0) * 0.5;
        if r > (Y1 - Y0) * 0.5 then r := (Y1 - Y0) * 0.5;
        dx := 0; dy := 0;
        if cx < X0 + r then dx := (X0 + r) - cx
        else if cx > X1 - r then dx := cx - (X1 - r);
        if cy < Y0 + r then dy := (Y0 + r) - cy
        else if cy > Y1 - r then dy := cy - (Y1 - r);
        if (dx > 0) and (dy > 0) and (dx * dx + dy * dy > r * r) then Exit(False);
      end;
    end;
  Result := True;
end;

{ Record the current clip depth so a later ClearClip/RestoreState pops back to
  it — mirrors CGContextSaveGState (SetClip = save + clip, ClearClip = restore). }
procedure TTina4RasterCanvas.PushClipSave;
begin
  SetLength(FClipSave, Length(FClipSave) + 1);
  FClipSave[High(FClipSave)] := Length(FClip);
end;

procedure TTina4RasterCanvas.SetClip(X, Y, W, H: Single);
begin
  ClipRoundRect(X, Y, W, H, 0);
end;

procedure TTina4RasterCanvas.ClipRoundRect(X, Y, W, H, Radius: Single);
var n: Integer;
begin
  PushClipSave;                                  // self-saves, balanced by ClearClip
  n := Length(FClip); SetLength(FClip, n + 1);
  FClip[n].X0 := X;     FClip[n].Y0 := Y;
  FClip[n].X1 := X + W; FClip[n].Y1 := Y + H;
  FClip[n].Rad := Radius;
end;

procedure TTina4RasterCanvas.ClearClip;
begin
  if Length(FClipSave) = 0 then Exit;
  SetLength(FClip, FClipSave[High(FClipSave)]);
  SetLength(FClipSave, Length(FClipSave) - 1);
end;

procedure TTina4RasterCanvas.SaveState;
begin
  PushClipSave;                                  // snapshot depth; RestoreState pops it
end;

procedure TTina4RasterCanvas.RestoreState;
begin
  ClearClip;
end;

function TTina4RasterCanvas.BeginLayer(X, Y, W, H, Pad: Single): Integer;
var ox, oy, bw, bh, n: Integer;
begin
  ox := Floor(X - Pad); oy := Floor(Y - Pad);
  bw := Ceil(X + W + Pad) - ox; bh := Ceil(Y + H + Pad) - oy;
  if (bw <= 0) or (bh <= 0) then Exit(-1);
  n := Length(FLayers); SetLength(FLayers, n + 1);
  // stash the current target (parent) so End can restore it
  FLayers[n].Pix := FPix; FLayers[n].W := FW; FLayers[n].H := FH;
  FLayers[n].OX := FTgtOX; FLayers[n].OY := FTgtOY;
  FLayers[n].Clip := Copy(FClip); FLayers[n].ClipSave := Copy(FClipSave);
  // redirect drawing into a fresh transparent buffer covering the padded rect
  FPix := nil; SetLength(FPix, bw * bh);   // zero-filled = fully transparent
  FW := bw; FH := bh; FTgtOX := ox; FTgtOY := oy;
  SetLength(FCov, FW);
  SetLength(FClip, 0); SetLength(FClipSave, 0);   // layer draws unclipped; parent clip applies on composite
  Result := n;
end;

procedure TTina4RasterCanvas.EndLayerFiltered(Handle: Integer;
  const FilterSpec, BlendMode, MaskSpec: string);
var
  layPix: array of Cardinal;
  lw, lh, lox, loy, n, bx, by, dpx, dpy, dbx, dby: Integer;
  c, dst: Cardinal; srcA: Single; blended: TTina4Color; useBlend: Boolean;
  fbuf: array of Single; i, rr, gg, bb: Integer; fa: Single;
begin
  n := Length(FLayers);
  if n = 0 then Exit;
  // capture the just-drawn layer buffer
  layPix := FPix; lw := FW; lh := FH; lox := FTgtOX; loy := FTgtOY;
  // restore the parent target
  Dec(n);
  FPix := FLayers[n].Pix; FW := FLayers[n].W; FH := FLayers[n].H;
  FTgtOX := FLayers[n].OX; FTgtOY := FLayers[n].OY;
  FClip := FLayers[n].Clip; FClipSave := FLayers[n].ClipSave;
  SetLength(FLayers, n);
  SetLength(FCov, FW);
  // CSS filter / mask: run the shared compositor filter chain (blur, brightness,
  // contrast, grayscale, sepia, invert, saturate, hue-rotate, opacity, drop-shadow)
  // over the layer's PREMULTIPLIED float pixels, then unpremultiply back.
  if (FilterSpec <> '') or (MaskSpec <> '') then
  begin
    SetLength(fbuf, lw * lh * 4);
    for i := 0 to lw * lh - 1 do
    begin
      c := layPix[i]; fa := ((c shr 24) and $FF) / 255;
      fbuf[i*4]   := ((c shr 16) and $FF) / 255 * fa;   // premultiplied RGBA
      fbuf[i*4+1] := ((c shr 8)  and $FF) / 255 * fa;
      fbuf[i*4+2] := ( c         and $FF) / 255 * fa;
      fbuf[i*4+3] := fa;
    end;
    ApplyFilterChainF(PSingleBuf(@fbuf[0]), lw, lh, FilterSpec, MaskSpec, 1);
    for i := 0 to lw * lh - 1 do
    begin
      fa := fbuf[i*4+3];
      if fa > 0 then
      begin
        rr := Round(Min(1, fbuf[i*4]   / fa) * 255);
        gg := Round(Min(1, fbuf[i*4+1] / fa) * 255);
        bb := Round(Min(1, fbuf[i*4+2] / fa) * 255);
      end
      else begin rr := 0; gg := 0; bb := 0; end;
      layPix[i] := (Cardinal(Round(Min(1, fa) * 255)) shl 24)
                or (Cardinal(rr) shl 16) or (Cardinal(gg) shl 8) or Cardinal(bb);
    end;
  end;
  useBlend := (BlendMode <> '') and (BlendMode <> 'normal');
  // composite the layer back onto the parent at (lox,loy), doc coords
  for by := 0 to lh - 1 do
    for bx := 0 to lw - 1 do
    begin
      c := layPix[by * lw + bx];
      srcA := ((c shr 24) and $FF) / 255;
      if srcA <= 0 then Continue;
      dpx := lox + bx; dpy := loy + by;
      if useBlend then
      begin
        dbx := dpx - FTgtOX; dby := dpy - FTgtOY;   // parent-buffer index for the backdrop
        if (dbx < 0) or (dbx >= FW) or (dby < 0) or (dby >= FH) then dst := 0
        else dst := FPix[dby * FW + dbx];
        // blend the layer colour against the backdrop, then source-over at aS
        blended := BlendRGB((c and $00FFFFFF) or $FF000000, dst or $FF000000, LowerCase(BlendMode));
        BlendPixel(dpx, dpy, (blended shr 16) and $FF, (blended shr 8) and $FF, blended and $FF, srcA);
      end
      else
        BlendPixel(dpx, dpy, (c shr 16) and $FF, (c shr 8) and $FF, c and $FF, srcA);
    end;
end;

function TTina4RasterCanvas.SupportsRGBA: Boolean;
begin
  Result := True;
end;

{ Composite a straight-$AARRGGBB buffer onto the canvas (alpha-blended), nearest-
  sampled when scaled. Used for the base soft-shadow blit and image blits. }
procedure TTina4RasterCanvas.DrawRGBA(Buf: Pointer; BW, BH: Integer; DX, DY, DW, DH: Single);
var src: PCardinal; dxi, dyi, dwi, dhi, ox, oy, sx, sy: Integer; c: Cardinal; a: Single;
begin
  if (Buf = nil) or (BW <= 0) or (BH <= 0) then Exit;
  src := PCardinal(Buf);
  dxi := Round(DX); dyi := Round(DY);
  dwi := Round(DW); dhi := Round(DH);
  if dwi < 1 then dwi := 1; if dhi < 1 then dhi := 1;
  for oy := 0 to dhi - 1 do
    for ox := 0 to dwi - 1 do
    begin
      sx := (ox * BW) div dwi; sy := (oy * BH) div dhi;
      if (sx < 0) or (sx >= BW) or (sy < 0) or (sy >= BH) then Continue;
      c := src[sy * BW + sx];
      a := ((c shr 24) and $FF) / 255;
      if a <= 0 then Continue;
      BlendPixel(dxi + ox, dyi + oy, (c shr 16) and $FF, (c shr 8) and $FF, c and $FF, a);
    end;
end;

end.
