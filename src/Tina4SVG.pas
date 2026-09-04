unit Tina4SVG;

{ Pure-Pascal SVG painter for the Tina4 native renderer.

  Walks an inline <svg> subtree (already parsed by THTMLParser into generic
  THTMLTag nodes) and rasterises it through the canvas contract only — shapes
  flatten to polygons filled via TTina4Canvas.FillPolygon, strokes are drawn
  with DrawLine, text with DrawText. Every transform (viewBox + element
  transform=) is baked into device coordinates here, so this unit needs
  nothing but the plain canvas primitives and stays fully portable.

  Supported: <g>, rect (rx/ry), circle, ellipse, line, polyline, polygon,
  path (M L H V C S Q T A Z, absolute + relative), text (x/y, text-anchor,
  font-size), presentation attributes fill/stroke/stroke-width/opacity/
  fill-opacity/stroke-opacity/transform inherited down the tree, and a
  style="" shorthand for those. Not yet: gradients, clip/mask, filters,
  patterns, <use>, <tspan> positioning, dash arrays. }

{$mode delphi}{$H+}

interface

uses
  Tina4HTMLDom, Tina4RenderBackend;

{ Paints the <svg> rooted at Root into the device rectangle (X,Y,W,H),
  scaling its viewBox (or width/height) to fit. }
procedure PaintSVG(Canvas: TTina4Canvas; Root: THTMLTag; X, Y, W, H: Single);

{ Intrinsic pixel size of an <svg> from width/height attrs or viewBox;
  returns False if neither is present (caller picks a default). }
function SVGIntrinsicSize(Root: THTMLTag; out W, H: Single): Boolean;

implementation

uses
  SysUtils, Math;

type
  TSingleArray = array of Single;

{ ---- 2x3 affine matrix ( [a c e] / [b d f] ) -------------------------- }
type
  TMat = record a, b, c, d, e, f: Single; end;

function MatId: TMat;
begin
  Result.a := 1; Result.b := 0; Result.c := 0;
  Result.d := 1; Result.e := 0; Result.f := 0;
end;

{ Result = M * N (apply N first, then M) }
function MatMul(const M, N: TMat): TMat;
begin
  Result.a := M.a * N.a + M.c * N.b;
  Result.b := M.b * N.a + M.d * N.b;
  Result.c := M.a * N.c + M.c * N.d;
  Result.d := M.b * N.c + M.d * N.d;
  Result.e := M.a * N.e + M.c * N.f + M.e;
  Result.f := M.b * N.e + M.d * N.f + M.f;
end;

procedure MatApply(const M: TMat; X, Y: Single; out OX, OY: Single);
begin
  OX := M.a * X + M.c * Y + M.e;
  OY := M.b * X + M.d * Y + M.f;
end;

{ average axis scale of a matrix, for turning user-space stroke-width /
  circle radii into device space }
function MatScale(const M: TMat): Single;
begin
  Result := (Sqrt(M.a * M.a + M.b * M.b) + Sqrt(M.c * M.c + M.d * M.d)) / 2;
end;

{ ---- painting state inherited down the tree --------------------------- }
type
  TSvgState = record
    CTM: TMat;
    HasFill: Boolean;   FillColor: TTina4Color;
    HasStroke: Boolean; StrokeColor: TTina4Color;
    StrokeW: Single;
    Opacity, FillOpacity, StrokeOpacity: Single;
    FontSize: Single;
    TextAnchor: string;
    CurrentColor: TTina4Color;
  end;

function DefaultState(const CTM: TMat): TSvgState;
begin
  Result.CTM := CTM;
  Result.HasFill := True;  Result.FillColor := $FF000000;  // SVG default: black fill
  Result.HasStroke := False; Result.StrokeColor := $FF000000;
  Result.StrokeW := 1;
  Result.Opacity := 1; Result.FillOpacity := 1; Result.StrokeOpacity := 1;
  Result.FontSize := 16;
  Result.TextAnchor := 'start';
  Result.CurrentColor := $FF000000;
end;

{ ---- small parse helpers ---------------------------------------------- }

function ToF(const S: string; Def: Single = 0): Single;
var v: Single; code: Integer;
begin
  Val(Trim(S), v, code);
  if code = 0 then Result := v else Result := Def;
end;

{ splits "a,b c d" style numeric lists into an array of floats }
function NumList(const S: string): TSingleArray;
var
  i, n: Integer;
  cur: string;
  ch: Char;
  procedure Push;
  begin
    if cur <> '' then
    begin
      SetLength(Result, n + 1); Result[n] := ToF(cur); Inc(n); cur := '';
    end;
  end;
begin
  SetLength(Result, 0); n := 0; cur := '';
  for i := 1 to Length(S) do
  begin
    ch := S[i];
    if (ch = ' ') or (ch = ',') or (ch = #9) or (ch = #10) or (ch = #13) then
      Push
    else if ((ch = '-') or (ch = '+')) and (cur <> '') and
            (cur[Length(cur)] <> 'e') and (cur[Length(cur)] <> 'E') then
    begin
      Push; cur := ch;   // a sign starts a new number
    end
    else
      cur := cur + ch;
  end;
  Push;
end;

{ apply opacity multipliers to a colour's alpha }
function WithAlpha(Color: TTina4Color; Mul: Single): TTina4Color;
var a: Integer;
begin
  a := Round(((Color shr 24) and $FF) * Mul);
  if a < 0 then a := 0; if a > 255 then a := 255;
  Result := (Color and $00FFFFFF) or (Cardinal(a) shl 24);
end;

{ ---- transform="translate(..) scale(..) rotate(..) matrix(..)" -------- }
function ParseTransform(const S: string): TMat;
var
  i, j: Integer;
  name, args: string;
  nums: TSingleArray;
  t, m: TMat;
  ca, sa: Single;
begin
  Result := MatId;
  i := 1;
  while i <= Length(S) do
  begin
    // read a function name
    if not (S[i] in ['a'..'z', 'A'..'Z']) then begin Inc(i); Continue; end;
    j := i;
    while (j <= Length(S)) and (S[j] <> '(') do Inc(j);
    name := Trim(Copy(S, i, j - i));
    // read args up to ')'
    Inc(j); i := j;
    while (j <= Length(S)) and (S[j] <> ')') do Inc(j);
    args := Copy(S, i, j - i);
    i := j + 1;
    nums := NumList(args);
    m := MatId;
    if (name = 'translate') and (Length(nums) >= 1) then
    begin
      m.e := nums[0];
      if Length(nums) >= 2 then m.f := nums[1];
    end
    else if (name = 'scale') and (Length(nums) >= 1) then
    begin
      m.a := nums[0];
      if Length(nums) >= 2 then m.d := nums[1] else m.d := nums[0];
    end
    else if (name = 'rotate') and (Length(nums) >= 1) then
    begin
      ca := Cos(nums[0] * Pi / 180); sa := Sin(nums[0] * Pi / 180);
      if Length(nums) >= 3 then
      begin
        // rotate about (cx,cy): T(cx,cy) R T(-cx,-cy)
        t := MatId; t.e := nums[1]; t.f := nums[2];
        m.a := ca; m.b := sa; m.c := -sa; m.d := ca;
        m := MatMul(t, m);
        t := MatId; t.e := -nums[1]; t.f := -nums[2];
        m := MatMul(m, t);
      end
      else
      begin
        m.a := ca; m.b := sa; m.c := -sa; m.d := ca;
      end;
    end
    else if (name = 'matrix') and (Length(nums) >= 6) then
    begin
      m.a := nums[0]; m.b := nums[1]; m.c := nums[2];
      m.d := nums[3]; m.e := nums[4]; m.f := nums[5];
    end;
    Result := MatMul(Result, m);
  end;
end;

{ ---- presentation attributes ------------------------------------------ }

{ reads one presentation value, inline style="" winning over the attribute
  (matching CSS). The parser has already split style="" into Tag.Style. }
function PresAttr(Tag: THTMLTag; const Name: string): string;
begin
  if Tag.Style.TryGetValue(LowerCase(Name), Result) and (Result <> '') then Exit;
  Result := Tag.GetAttribute(Name);
end;

{ resolve a paint value (fill/stroke); returns whether it paints and colour }
procedure ResolvePaint(const Val: string; const St: TSvgState;
  out Has: Boolean; out Color: TTina4Color; InheritHas: Boolean; InheritColor: TTina4Color);
var v: string;
begin
  v := LowerCase(Trim(Val));
  if v = '' then begin Has := InheritHas; Color := InheritColor; Exit; end;
  if v = 'none' then begin Has := False; Color := 0; Exit; end;
  if v = 'currentcolor' then begin Has := True; Color := St.CurrentColor; Exit; end;
  Has := True;
  Color := TComputedStyle.ParseColor(Val);
  if Color = 0 then Color := $FF000000;   // unparsed → opaque black
end;

{ merge this element's presentation attributes onto the inherited state }
function MergeState(Tag: THTMLTag; const Parent: TSvgState): TSvgState;
var s: string;
begin
  Result := Parent;
  s := PresAttr(Tag, 'transform');
  if s <> '' then Result.CTM := MatMul(Parent.CTM, ParseTransform(s));
  s := PresAttr(Tag, 'fill');
  if s <> '' then ResolvePaint(s, Parent, Result.HasFill, Result.FillColor,
    Parent.HasFill, Parent.FillColor);
  s := PresAttr(Tag, 'stroke');
  if s <> '' then ResolvePaint(s, Parent, Result.HasStroke, Result.StrokeColor,
    Parent.HasStroke, Parent.StrokeColor);
  s := PresAttr(Tag, 'stroke-width');
  if s <> '' then Result.StrokeW := ToF(s, Parent.StrokeW);
  s := PresAttr(Tag, 'opacity');
  if s <> '' then Result.Opacity := Parent.Opacity * ToF(s, 1);
  s := PresAttr(Tag, 'fill-opacity');
  if s <> '' then Result.FillOpacity := ToF(s, 1);
  s := PresAttr(Tag, 'stroke-opacity');
  if s <> '' then Result.StrokeOpacity := ToF(s, 1);
  s := PresAttr(Tag, 'font-size');
  if s <> '' then Result.FontSize := ToF(s, Parent.FontSize);
  s := PresAttr(Tag, 'color');
  if s <> '' then Result.CurrentColor := TComputedStyle.ParseColor(s);
  s := PresAttr(Tag, 'text-anchor');
  if s <> '' then Result.TextAnchor := LowerCase(Trim(s));
end;

{ ---- flatten + paint helpers ------------------------------------------ }
const
  CURVE_SEGS = 18;   // subdivisions per bezier / arc quadrant

{ device-space fill of one contour (already transformed) }
procedure FillContour(Canvas: TTina4Canvas; const Pts: TTina4PointArray;
  Color: TTina4Color; EvenOdd: Boolean);
var one: array[0..0] of TTina4PointArray;
begin
  if Length(Pts) < 3 then Exit;
  one[0] := Pts;
  Canvas.FillPolygon(one, Color, EvenOdd);
end;

{ device-space stroke of a polyline (already transformed) }
procedure StrokePath(Canvas: TTina4Canvas; const Pts: TTina4PointArray;
  Color: TTina4Color; Width: Single; Closed: Boolean);
var i, n: Integer;
begin
  n := Length(Pts);
  if n < 2 then Exit;
  if Width <= 0 then Width := 1;
  for i := 0 to n - 2 do
    Canvas.DrawLine(Pts[i].X, Pts[i].Y, Pts[i + 1].X, Pts[i + 1].Y, Width, Color);
  if Closed then
    Canvas.DrawLine(Pts[n - 1].X, Pts[n - 1].Y, Pts[0].X, Pts[0].Y, Width, Color);
end;

{ append a user-space point, transformed by CTM, to a device contour }
procedure AddPt(var Pts: TTina4PointArray; const M: TMat; X, Y: Single);
var n: Integer;
begin
  n := Length(Pts); SetLength(Pts, n + 1);
  MatApply(M, X, Y, Pts[n].X, Pts[n].Y);
end;

{ flatten a cubic Bézier (user space) into line segments, appended via CTM;
  the start point is assumed already present in the contour }
procedure FlattenCubic(var Pts: TTina4PointArray; const M: TMat;
  x0, y0, x1, y1, x2, y2, x3, y3: Single);
var i: Integer; t, mt, a, b, c, d, px, py: Single;
begin
  for i := 1 to CURVE_SEGS do
  begin
    t := i / CURVE_SEGS; mt := 1 - t;
    a := mt * mt * mt; b := 3 * mt * mt * t; c := 3 * mt * t * t; d := t * t * t;
    px := a * x0 + b * x1 + c * x2 + d * x3;
    py := a * y0 + b * y1 + c * y2 + d * y3;
    AddPt(Pts, M, px, py);
  end;
end;

{ flatten a quadratic Bézier (user space) into line segments }
procedure FlattenQuad(var Pts: TTina4PointArray; const M: TMat;
  x0, y0, x1, y1, x2, y2: Single);
var i: Integer; t, mt, a, b, c, px, py: Single;
begin
  for i := 1 to CURVE_SEGS do
  begin
    t := i / CURVE_SEGS; mt := 1 - t;
    a := mt * mt; b := 2 * mt * t; c := t * t;
    px := a * x0 + b * x1 + c * x2;
    py := a * y0 + b * y1 + c * y2;
    AddPt(Pts, M, px, py);
  end;
end;

{ ---- shape painters (each takes a merged state) ----------------------- }

procedure PaintFillStroke(Canvas: TTina4Canvas; const Pts: TTina4PointArray;
  const St: TSvgState; Closed, EvenOdd: Boolean);
begin
  if St.HasFill and Closed then
    FillContour(Canvas, Pts, WithAlpha(St.FillColor, St.Opacity * St.FillOpacity), EvenOdd);
  if St.HasStroke then
    StrokePath(Canvas, Pts, WithAlpha(St.StrokeColor, St.Opacity * St.StrokeOpacity),
      St.StrokeW * MatScale(St.CTM), Closed);
end;

procedure PaintRect(Canvas: TTina4Canvas; Tag: THTMLTag; const St: TSvgState);
var
  x, y, w, h, rx, ry: Single;
  pts: TTina4PointArray;
  i: Integer;
  a: Single;
begin
  x := ToF(PresAttr(Tag, 'x')); y := ToF(PresAttr(Tag, 'y'));
  w := ToF(PresAttr(Tag, 'width')); h := ToF(PresAttr(Tag, 'height'));
  if (w <= 0) or (h <= 0) then Exit;
  rx := ToF(PresAttr(Tag, 'rx'), -1); ry := ToF(PresAttr(Tag, 'ry'), -1);
  if (rx < 0) and (ry >= 0) then rx := ry;
  if (ry < 0) and (rx >= 0) then ry := rx;
  if rx < 0 then rx := 0; if ry < 0 then ry := 0;
  rx := Min(rx, w / 2); ry := Min(ry, h / 2);
  SetLength(pts, 0);
  if (rx <= 0) or (ry <= 0) then
  begin
    AddPt(pts, St.CTM, x, y); AddPt(pts, St.CTM, x + w, y);
    AddPt(pts, St.CTM, x + w, y + h); AddPt(pts, St.CTM, x, y + h);
  end
  else
  begin
    // four rounded corners, clockwise from top-left
    for i := 0 to CURVE_SEGS do begin a := Pi + i / CURVE_SEGS * (Pi / 2);
      AddPt(pts, St.CTM, x + rx + rx * Cos(a), y + ry + ry * Sin(a)); end;
    for i := 0 to CURVE_SEGS do begin a := -Pi / 2 + i / CURVE_SEGS * (Pi / 2);
      AddPt(pts, St.CTM, x + w - rx + rx * Cos(a), y + ry + ry * Sin(a)); end;
    for i := 0 to CURVE_SEGS do begin a := 0 + i / CURVE_SEGS * (Pi / 2);
      AddPt(pts, St.CTM, x + w - rx + rx * Cos(a), y + h - ry + ry * Sin(a)); end;
    for i := 0 to CURVE_SEGS do begin a := Pi / 2 + i / CURVE_SEGS * (Pi / 2);
      AddPt(pts, St.CTM, x + rx + rx * Cos(a), y + h - ry + ry * Sin(a)); end;
  end;
  PaintFillStroke(Canvas, pts, St, True, False);
end;

procedure PaintEllipse(Canvas: TTina4Canvas; Tag: THTMLTag; const St: TSvgState;
  IsCircle: Boolean);
var
  cx, cy, rx, ry, a: Single;
  pts: TTina4PointArray;
  i, segs: Integer;
begin
  cx := ToF(PresAttr(Tag, 'cx')); cy := ToF(PresAttr(Tag, 'cy'));
  if IsCircle then
  begin
    rx := ToF(PresAttr(Tag, 'r')); ry := rx;
  end
  else
  begin
    rx := ToF(PresAttr(Tag, 'rx')); ry := ToF(PresAttr(Tag, 'ry'));
  end;
  if (rx <= 0) or (ry <= 0) then Exit;
  segs := 64;
  SetLength(pts, 0);
  for i := 0 to segs - 1 do
  begin
    a := i / segs * 2 * Pi;
    AddPt(pts, St.CTM, cx + rx * Cos(a), cy + ry * Sin(a));
  end;
  PaintFillStroke(Canvas, pts, St, True, False);
end;

procedure PaintLine(Canvas: TTina4Canvas; Tag: THTMLTag; const St: TSvgState);
var pts: TTina4PointArray;
begin
  if not St.HasStroke then Exit;
  SetLength(pts, 0);
  AddPt(pts, St.CTM, ToF(PresAttr(Tag, 'x1')), ToF(PresAttr(Tag, 'y1')));
  AddPt(pts, St.CTM, ToF(PresAttr(Tag, 'x2')), ToF(PresAttr(Tag, 'y2')));
  StrokePath(Canvas, pts, WithAlpha(St.StrokeColor, St.Opacity * St.StrokeOpacity),
    St.StrokeW * MatScale(St.CTM), False);
end;

procedure PaintPoly(Canvas: TTina4Canvas; Tag: THTMLTag; const St: TSvgState;
  Closed: Boolean);
var
  nums: TSingleArray;
  pts: TTina4PointArray;
  i: Integer;
begin
  nums := NumList(PresAttr(Tag, 'points'));
  if Length(nums) < 4 then Exit;
  SetLength(pts, 0);
  i := 0;
  while i + 1 < Length(nums) do
  begin
    AddPt(pts, St.CTM, nums[i], nums[i + 1]); Inc(i, 2);
  end;
  PaintFillStroke(Canvas, pts, St, Closed, False);
end;

{ concatenate the #text descendants of an element (through one tspan level) }
function SvgText(Tag: THTMLTag): string;
var c, g: THTMLTag;
begin
  Result := '';
  for c in Tag.Children do
    if c.TagName = '#text' then Result := Result + c.Text
    else if SameText(c.TagName, 'tspan') then
      for g in c.Children do
        if g.TagName = '#text' then Result := Result + g.Text;
end;

procedure PaintText(Canvas: TTina4Canvas; Tag: THTMLTag; const St: TSvgState);
var
  x, y, ox, oy, w, scale: Single;
  txt: string;
  m: TTina4TextMetrics;
  styles: TTina4FontStyles;
begin
  x := ToF(PresAttr(Tag, 'x')); y := ToF(PresAttr(Tag, 'y'));
  txt := Trim(SvgText(Tag));
  if txt = '' then Exit;
  scale := MatScale(St.CTM);
  styles := [];
  if LowerCase(PresAttr(Tag, 'font-weight')) = 'bold' then Include(styles, tfsBold);
  m := Canvas.MeasureText(txt, St.FontSize * scale, styles);
  MatApply(St.CTM, x, y, ox, oy);
  w := m.Width;
  if St.TextAnchor = 'middle' then ox := ox - w / 2
  else if St.TextAnchor = 'end' then ox := ox - w;
  // SVG y is the baseline; DrawText wants the top
  Canvas.DrawText(ox, oy - m.Ascent, txt, St.FontSize * scale, styles,
    WithAlpha(St.FillColor, St.Opacity * St.FillOpacity));
end;

{ ---- path data --------------------------------------------------------- }

{ Convert an SVG elliptical arc (endpoint form) to points, appended in
  user space, then caller transforms. Here we emit user-space points into
  the device contour directly via CTM. }
procedure ArcTo(var Pts: TTina4PointArray; const M: TMat;
  x0, y0, rx, ry, xRot, x1, y1: Single; largeArc, sweep: Boolean);
var
  phi, cosf, sinf, dx, dy, x1p, y1p, rxs, rys, num, den, factor: Single;
  cxp, cyp, cx, cy, ux, uy, vx, vy, theta1, dtheta, ang: Single;
  sign, i, n: Integer;
  lam: Single;
begin
  if (rx = 0) or (ry = 0) then begin AddPt(Pts, M, x1, y1); Exit; end;
  rx := Abs(rx); ry := Abs(ry);
  phi := xRot * Pi / 180; cosf := Cos(phi); sinf := Sin(phi);
  dx := (x0 - x1) / 2; dy := (y0 - y1) / 2;
  x1p := cosf * dx + sinf * dy;
  y1p := -sinf * dx + cosf * dy;
  // correct out-of-range radii
  lam := (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
  if lam > 1 then begin rx := rx * Sqrt(lam); ry := ry * Sqrt(lam); end;
  rxs := rx * rx; rys := ry * ry;
  num := rxs * rys - rxs * y1p * y1p - rys * x1p * x1p;
  den := rxs * y1p * y1p + rys * x1p * x1p;
  if den = 0 then factor := 0
  else begin
    factor := num / den; if factor < 0 then factor := 0;
    factor := Sqrt(factor);
  end;
  if largeArc = sweep then sign := -1 else sign := 1;
  cxp := sign * factor * (rx * y1p / ry);
  cyp := sign * factor * (-ry * x1p / rx);
  cx := cosf * cxp - sinf * cyp + (x0 + x1) / 2;
  cy := sinf * cxp + cosf * cyp + (y0 + y1) / 2;
  ux := (x1p - cxp) / rx; uy := (y1p - cyp) / ry;
  vx := (-x1p - cxp) / rx; vy := (-y1p - cyp) / ry;
  // start angle
  theta1 := ArcTan2(uy, ux);
  // sweep angle
  num := ux * vx + uy * vy;
  den := Sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy));
  if den = 0 then dtheta := 0
  else begin
    factor := num / den;
    if factor < -1 then factor := -1; if factor > 1 then factor := 1;
    dtheta := ArcCos(factor);
    if (ux * vy - uy * vx) < 0 then dtheta := -dtheta;
  end;
  if sweep and (dtheta < 0) then dtheta := dtheta + 2 * Pi
  else if (not sweep) and (dtheta > 0) then dtheta := dtheta - 2 * Pi;
  n := Max(2, Round(Abs(dtheta) / (Pi / 2) * CURVE_SEGS));
  for i := 1 to n do
  begin
    ang := theta1 + dtheta * i / n;
    AddPt(Pts, M,
      cx + rx * Cos(ang) * cosf - ry * Sin(ang) * sinf,
      cy + rx * Cos(ang) * sinf + ry * Sin(ang) * cosf);
  end;
end;

{ Parse a path 'd' string into device-space contours (subpaths). }
procedure ParsePath(const D: string; const M: TMat;
  out Contours: array of TTina4PointArray; out NContours: Integer);
var
  i, len: Integer;
  cmd, prev: Char;
  cx, cy, startX, startY, c1x, c1y, c2x, c2y, x, y, rx, ry, xr: Single;
  lastCX, lastCY: Single;    // last cubic control (for S)
  lastQX, lastQY: Single;    // last quad control (for T)
  hadCubic, hadQuad: Boolean;
  cur: TTina4PointArray;
  contourCount: Integer;

  procedure NewSub;
  begin
    if Length(cur) > 0 then
    begin
      if contourCount <= High(Contours) then Contours[contourCount] := cur;
      Inc(contourCount);
    end;
    SetLength(cur, 0);
  end;

  { read the next float from the string starting at i }
  function NextNum: Single;
  var j: Integer; s: string;
  begin
    while (i <= len) and (D[i] in [' ', ',', #9, #10, #13]) do Inc(i);
    j := i;
    if (i <= len) and (D[i] in ['-', '+']) then Inc(i);
    while (i <= len) and (D[i] in ['0'..'9', '.']) do Inc(i);
    if (i <= len) and (D[i] in ['e', 'E']) then
    begin
      Inc(i);
      if (i <= len) and (D[i] in ['-', '+']) then Inc(i);
      while (i <= len) and (D[i] in ['0'..'9']) do Inc(i);
    end;
    s := Copy(D, j, i - j);
    Result := ToF(s);
  end;

  function NextFlag: Boolean;
  begin
    while (i <= len) and (D[i] in [' ', ',', #9, #10, #13]) do Inc(i);
    Result := (i <= len) and (D[i] = '1');
    if (i <= len) and (D[i] in ['0', '1']) then Inc(i);
  end;

  function MoreNums: Boolean;
  var j: Integer;
  begin
    j := i;
    while (j <= len) and (D[j] in [' ', ',', #9, #10, #13]) do Inc(j);
    Result := (j <= len) and (D[j] in ['0'..'9', '-', '+', '.']);
  end;

begin
  for i := 0 to High(Contours) do SetLength(Contours[i], 0);
  contourCount := 0;
  SetLength(cur, 0);
  len := Length(D);
  cx := 0; cy := 0; startX := 0; startY := 0;
  lastCX := 0; lastCY := 0; lastQX := 0; lastQY := 0;
  prev := ' ';
  i := 1;
  while i <= len do
  begin
    while (i <= len) and (D[i] in [' ', ',', #9, #10, #13]) do Inc(i);
    if i > len then Break;
    if D[i] in ['A'..'Z', 'a'..'z'] then begin cmd := D[i]; Inc(i); end
    else cmd := prev;             // implicit repeat of last command
    prev := cmd;
    hadCubic := (cmd in ['C', 'c', 'S', 's']);
    hadQuad := (cmd in ['Q', 'q', 'T', 't']);
    case cmd of
      'M', 'm':
        begin
          x := NextNum; y := NextNum;
          if cmd = 'm' then begin x := cx + x; y := cy + y; end;
          NewSub;
          cx := x; cy := y; startX := x; startY := y;
          AddPt(cur, M, cx, cy);
          // subsequent pairs are implicit L
          while MoreNums do
          begin
            x := NextNum; y := NextNum;
            if cmd = 'm' then begin x := cx + x; y := cy + y; end;
            cx := x; cy := y; AddPt(cur, M, cx, cy);
          end;
        end;
      'L', 'l':
        repeat
          x := NextNum; y := NextNum;
          if cmd = 'l' then begin x := cx + x; y := cy + y; end;
          cx := x; cy := y; AddPt(cur, M, cx, cy);
        until not MoreNums;
      'H', 'h':
        repeat
          x := NextNum; if cmd = 'h' then x := cx + x;
          cx := x; AddPt(cur, M, cx, cy);
        until not MoreNums;
      'V', 'v':
        repeat
          y := NextNum; if cmd = 'v' then y := cy + y;
          cy := y; AddPt(cur, M, cx, cy);
        until not MoreNums;
      'C', 'c':
        repeat
          c1x := NextNum; c1y := NextNum; c2x := NextNum; c2y := NextNum;
          x := NextNum; y := NextNum;
          if cmd = 'c' then
          begin
            c1x := cx + c1x; c1y := cy + c1y; c2x := cx + c2x; c2y := cy + c2y;
            x := cx + x; y := cy + y;
          end;
          FlattenCubic(cur, M, cx, cy, c1x, c1y, c2x, c2y, x, y);
          lastCX := c2x; lastCY := c2y; cx := x; cy := y;
        until not MoreNums;
      'S', 's':
        repeat
          c2x := NextNum; c2y := NextNum; x := NextNum; y := NextNum;
          if cmd = 's' then begin c2x := cx + c2x; c2y := cy + c2y; x := cx + x; y := cy + y; end;
          if prev in ['C', 'c', 'S', 's'] then
          begin c1x := 2 * cx - lastCX; c1y := 2 * cy - lastCY; end
          else begin c1x := cx; c1y := cy; end;
          FlattenCubic(cur, M, cx, cy, c1x, c1y, c2x, c2y, x, y);
          lastCX := c2x; lastCY := c2y; cx := x; cy := y;
        until not MoreNums;
      'Q', 'q':
        repeat
          c1x := NextNum; c1y := NextNum; x := NextNum; y := NextNum;
          if cmd = 'q' then begin c1x := cx + c1x; c1y := cy + c1y; x := cx + x; y := cy + y; end;
          FlattenQuad(cur, M, cx, cy, c1x, c1y, x, y);
          lastQX := c1x; lastQY := c1y; cx := x; cy := y;
        until not MoreNums;
      'T', 't':
        repeat
          x := NextNum; y := NextNum;
          if cmd = 't' then begin x := cx + x; y := cy + y; end;
          if prev in ['Q', 'q', 'T', 't'] then
          begin c1x := 2 * cx - lastQX; c1y := 2 * cy - lastQY; end
          else begin c1x := cx; c1y := cy; end;
          FlattenQuad(cur, M, cx, cy, c1x, c1y, x, y);
          lastQX := c1x; lastQY := c1y; cx := x; cy := y;
        until not MoreNums;
      'A', 'a':
        repeat
          rx := NextNum; ry := NextNum; xr := NextNum;
          if NextFlag then c1x := 1 else c1x := 0;  // largeArc
          if NextFlag then c1y := 1 else c1y := 0;  // sweep
          x := NextNum; y := NextNum;
          if cmd = 'a' then begin x := cx + x; y := cy + y; end;
          ArcTo(cur, M, cx, cy, rx, ry, xr, x, y, c1x <> 0, c1y <> 0);
          cx := x; cy := y;
        until not MoreNums;
      'Z', 'z':
        begin
          cx := startX; cy := startY;
          NewSub;
        end;
    end;
    if not (hadCubic) then begin lastCX := cx; lastCY := cy; end;
    if not (hadQuad) then begin lastQX := cx; lastQY := cy; end;
  end;
  NewSub;
  NContours := contourCount;
end;

{ ---- node walk -------------------------------------------------------- }

procedure PaintNode(Canvas: TTina4Canvas; Tag: THTMLTag; const Parent: TSvgState);
var
  st: TSvgState;
  tn: string;
  c: THTMLTag;
  contours: array of TTina4PointArray;
  nc, i: Integer;
  fillCol, strokeCol: TTina4Color;
  sw: Single;
begin
  st := MergeState(Tag, Parent);
  tn := LowerCase(Tag.TagName);
  if (tn = 'g') or (tn = 'svg') or (tn = 'a') then
  begin
    for c in Tag.Children do PaintNode(Canvas, c, st);
  end
  else if tn = 'rect' then PaintRect(Canvas, Tag, st)
  else if tn = 'circle' then PaintEllipse(Canvas, Tag, st, True)
  else if tn = 'ellipse' then PaintEllipse(Canvas, Tag, st, False)
  else if tn = 'line' then PaintLine(Canvas, Tag, st)
  else if tn = 'polyline' then PaintPoly(Canvas, Tag, st, False)
  else if tn = 'polygon' then PaintPoly(Canvas, Tag, st, True)
  else if tn = 'text' then PaintText(Canvas, Tag, st)
  else if tn = 'path' then
  begin
    SetLength(contours, 64);
    ParsePath(Tag.GetAttribute('d'), st.CTM, contours, nc);
    if nc > 0 then
    begin
      SetLength(contours, nc);
      // fill all subpaths together (holes via nonzero winding)
      if st.HasFill then
      begin
        fillCol := WithAlpha(st.FillColor, st.Opacity * st.FillOpacity);
        Canvas.FillPolygon(contours, fillCol, False);
      end;
      if st.HasStroke then
      begin
        strokeCol := WithAlpha(st.StrokeColor, st.Opacity * st.StrokeOpacity);
        sw := st.StrokeW * MatScale(st.CTM);
        for i := 0 to nc - 1 do
          StrokePath(Canvas, contours[i], strokeCol, sw, False);
      end;
    end;
  end;
end;

{ ---- viewBox setup + entry points ------------------------------------- }

procedure GetViewBox(Root: THTMLTag; out hasVB: Boolean;
  out vbX, vbY, vbW, vbH: Single);
var nums: TSingleArray;
begin
  hasVB := False; vbX := 0; vbY := 0; vbW := 0; vbH := 0;
  nums := NumList(Root.GetAttribute('viewBox'));
  if Length(nums) = 4 then
  begin
    vbX := nums[0]; vbY := nums[1]; vbW := nums[2]; vbH := nums[3];
    hasVB := (vbW > 0) and (vbH > 0);
  end;
end;

function SVGIntrinsicSize(Root: THTMLTag; out W, H: Single): Boolean;
var hasVB: Boolean; vbX, vbY, vbW, vbH: Single;
begin
  W := ToF(Root.GetAttribute('width'), -1);
  H := ToF(Root.GetAttribute('height'), -1);
  if (W > 0) and (H > 0) then Exit(True);
  GetViewBox(Root, hasVB, vbX, vbY, vbW, vbH);
  if hasVB then
  begin
    if W <= 0 then W := vbW;
    if H <= 0 then H := vbH;
    Exit(True);
  end;
  Result := (W > 0) and (H > 0);
end;

procedure PaintSVG(Canvas: TTina4Canvas; Root: THTMLTag; X, Y, W, H: Single);
var
  hasVB: Boolean;
  vbX, vbY, vbW, vbH, sx, sy, s: Single;
  ctm: TMat;
  st: TSvgState;
  c: THTMLTag;
begin
  GetViewBox(Root, hasVB, vbX, vbY, vbW, vbH);
  ctm := MatId;
  if hasVB then
  begin
    // preserveAspectRatio xMidYMid meet (uniform scale, centred)
    sx := W / vbW; sy := H / vbH; s := Min(sx, sy);
    ctm.a := s; ctm.d := s;
    ctm.e := X + (W - vbW * s) / 2 - vbX * s;
    ctm.f := Y + (H - vbH * s) / 2 - vbY * s;
  end
  else
  begin
    ctm.e := X; ctm.f := Y;    // 1:1 user units at the box origin
  end;
  st := DefaultState(ctm);
  for c in Root.Children do PaintNode(Canvas, c, st);
end;

end.
