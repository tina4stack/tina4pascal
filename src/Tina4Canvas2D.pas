unit Tina4Canvas2D;

{ A pure-Pascal HTML5 Canvas 2D context.

  Tina4's answer to `<canvas>`: no JavaScript, no Skia. The "script" that draws
  is Pascal — an app registers a painter for a <canvas id="…"> and draws with the
  familiar Canvas-2D method names (paths, transforms, text, images), which map
  onto the portable render backend (Tina4RenderBackend). Because it renders in the
  core it works on every shell for free and is snapshot-testable.

  The context tracks its OWN affine matrix and captures path points in device
  space as they are added (like a real canvas), so fills/strokes stay correct
  under translate/rotate/scale. Colours are $AARRGGBB Cardinals (Pascal-native);
  string setters (`#rgb`, `rgb()/rgba()`, common names) are provided too. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Math, Tina4RenderBackend;

type
  TCanvasMatrix = record A, B, C, D, E, F: Single; end;   // [a c e / b d f]

  TCanvasState = record
    M: TCanvasMatrix;
    Fill, Stroke: TTina4Color;
    LineWidth, Alpha, FontSize: Single;
    FontStyles: TTina4FontStyles;
    FontFamily: string;
    TextAlign: string;      // 'left' | 'center' | 'right'
    TextBaseline: string;   // 'top' | 'middle' | 'alphabetic' | 'bottom'
  end;

  TTina4Canvas2D = class
  private
    FCanvas: TTina4Canvas;
    FW, FH: Single;                 // canvas box size (CSS px)
    FBg: TTina4Color;               // box background (for clearRect)
    S: TCanvasState;                // current state
    FStack: array of TCanvasState;
    FPath: array of TTina4PointArray;  // subpaths in DEVICE space
    FSub: TTina4PointArray;            // subpath being built
    FSubLen: Integer;
    FStartX, FStartY: Single;          // current subpath start (user space)
    FCurX, FCurY: Single;              // current point (user space)
    FHasCur: Boolean;
    procedure PushSub;
    procedure AddDev(UX, UY: Single);
    function Dev(UX, UY: Single): TTina4Point;
    function ApplyAlpha(C: TTina4Color): TTina4Color;
    function MatrixScale: Single;   // device-per-user scale, for line widths
  public
    constructor Create(ACanvas: TTina4Canvas; AWidth, AHeight: Single;
      ABg: TTina4Color);

    // --- state ---
    procedure Save;
    procedure Restore;

    // --- transforms ---
    procedure Translate(X, Y: Single);
    procedure Rotate(Radians: Single);
    procedure Scale(X, Y: Single);
    procedure Transform(A, B, C, D, E, F: Single);
    procedure SetTransform(A, B, C, D, E, F: Single);
    procedure ResetTransform;

    // --- style ---
    procedure SetFillColor(C: TTina4Color);
    procedure SetStrokeColor(C: TTina4Color);
    procedure SetFillStyle(const CSS: string);
    procedure SetStrokeStyle(const CSS: string);
    procedure SetLineWidth(W: Single);
    procedure SetGlobalAlpha(A: Single);
    procedure SetFont(SizePx: Single; Bold, Italic: Boolean; const Family: string = '');
    procedure SetTextAlign(const A: string);
    procedure SetTextBaseline(const B: string);

    // --- rectangles ---
    procedure ClearRect(X, Y, W, H: Single);
    procedure FillRect(X, Y, W, H: Single);
    procedure StrokeRect(X, Y, W, H: Single);

    // --- paths ---
    procedure BeginPath;
    procedure ClosePath;
    procedure MoveTo(X, Y: Single);
    procedure LineTo(X, Y: Single);
    procedure Rect(X, Y, W, H: Single);
    procedure Arc(CX, CY, R, StartAngle, EndAngle: Single; Anticlockwise: Boolean = False);
    procedure ArcTo(X1, Y1, X2, Y2, R: Single);
    procedure QuadraticCurveTo(CPX, CPY, X, Y: Single);
    procedure BezierCurveTo(CP1X, CP1Y, CP2X, CP2Y, X, Y: Single);
    procedure Ellipse(CX, CY, RX, RY, Rotation, StartAngle, EndAngle: Single;
      Anticlockwise: Boolean = False);
    procedure Fill(EvenOdd: Boolean = False);
    procedure Stroke;

    // --- text ---
    procedure FillText(const Text: string; X, Y: Single);
    procedure StrokeText(const Text: string; X, Y: Single);
    function MeasureText(const Text: string): Single;

    // --- images ---  (Src is a URL/path resolved by the backend image cache)
    procedure DrawImage(const Src: string; DX, DY: Single); overload;
    procedure DrawImage(const Src: string; DX, DY, DW, DH: Single); overload;

    property Width: Single read FW;
    property Height: Single read FH;
  end;

{ Parse a CSS colour string to $AARRGGBB (hex 3/4/6/8, rgb()/rgba(), names).
  Returns True on success. }
function ParseCanvasColor(const S: string; out C: TTina4Color): Boolean;

type
  { A painter draws one <canvas>. Registered by the canvas's id; the engine calls
    it every paint with a context already clipped + origin-set to the box. }
  TCanvasPaintProc = procedure(Ctx: TTina4Canvas2D);

procedure RegisterCanvasPainter(const Id: string; Proc: TCanvasPaintProc);
function  FindCanvasPainter(const Id: string): TCanvasPaintProc;
procedure ClearCanvasPainters;

{ Shared animation clock for time-driven canvas content (e.g. <lottie>). The
  paint marks itself active while animated content is on screen; the shell's tick
  advances the clock and keeps repainting while active. }
procedure AnimMarkActive;
procedure AnimResetActive;
function  AnimActive: Boolean;
procedure AnimAdvance(dtSeconds: Double);
function  AnimClock: Double;
{ Mark a self-contained animated box (e.g. <lottie>) active AND record its screen
  rect (CSS px). The union of these rects is the ONLY region a shell must repaint
  on an animation-only frame — a retained backing-store blits the rest. Plain
  AnimMarkActive (CSS transitions/keyframes) instead forces a full repaint, since
  those effects aren't confined to a known box. }
procedure AnimMarkRegion(X, Y, W, H: Single);
{ The animated region from the last paint (CSS px). Result=False when there's no
  animation, or when animated content needs a full repaint (AnimMarkActive). }
function  AnimRegion(out X, Y, W, H: Single): Boolean;

implementation

var
  GAnimClock: Double = 0;
  GAnimActive: Boolean = False;
  GAnimNeedsFull: Boolean = False;              // a full repaint is required (CSS anim)
  GAnimRectValid: Boolean = False;
  GAnimRX0, GAnimRY0, GAnimRX1, GAnimRY1: Single;

procedure AnimMarkActive;  begin GAnimActive := True; GAnimNeedsFull := True; end;
procedure AnimResetActive;
begin
  GAnimActive := False; GAnimNeedsFull := False; GAnimRectValid := False;
end;
function  AnimActive: Boolean; begin Result := GAnimActive; end;
procedure AnimAdvance(dtSeconds: Double); begin GAnimClock := GAnimClock + dtSeconds; end;
function  AnimClock: Double; begin Result := GAnimClock; end;

procedure AnimMarkRegion(X, Y, W, H: Single);
begin
  GAnimActive := True;
  if not GAnimRectValid then
  begin GAnimRX0 := X; GAnimRY0 := Y; GAnimRX1 := X + W; GAnimRY1 := Y + H; GAnimRectValid := True; end
  else
  begin
    if X < GAnimRX0 then GAnimRX0 := X;
    if Y < GAnimRY0 then GAnimRY0 := Y;
    if X + W > GAnimRX1 then GAnimRX1 := X + W;
    if Y + H > GAnimRY1 then GAnimRY1 := Y + H;
  end;
end;

function AnimRegion(out X, Y, W, H: Single): Boolean;
begin
  Result := GAnimRectValid and not GAnimNeedsFull;
  if Result then
  begin X := GAnimRX0; Y := GAnimRY0; W := GAnimRX1 - GAnimRX0; H := GAnimRY1 - GAnimRY0; end
  else begin X := 0; Y := 0; W := 0; H := 0; end;
end;

{ ---- painter registry ------------------------------------------------- }

var
  GPainterIds: array of string;
  GPainterProcs: array of TCanvasPaintProc;

procedure RegisterCanvasPainter(const Id: string; Proc: TCanvasPaintProc);
var i, n: Integer;
begin
  for i := 0 to High(GPainterIds) do
    if GPainterIds[i] = Id then begin GPainterProcs[i] := Proc; Exit; end;
  n := Length(GPainterIds);
  SetLength(GPainterIds, n + 1); SetLength(GPainterProcs, n + 1);
  GPainterIds[n] := Id; GPainterProcs[n] := Proc;
end;

function FindCanvasPainter(const Id: string): TCanvasPaintProc;
var i: Integer;
begin
  Result := nil;
  if Id = '' then Exit;
  for i := 0 to High(GPainterIds) do
    if GPainterIds[i] = Id then Exit(GPainterProcs[i]);
end;

procedure ClearCanvasPainters;
begin SetLength(GPainterIds, 0); SetLength(GPainterProcs, 0); end;

{ ---- matrix helpers --------------------------------------------------- }

function MatIdentity: TCanvasMatrix;
begin
  Result.A := 1; Result.B := 0; Result.C := 0;
  Result.D := 1; Result.E := 0; Result.F := 0;
end;

// r = m * n  (apply n first, then m — i.e. n is the incremental transform)
function MatMul(const M, N: TCanvasMatrix): TCanvasMatrix;
begin
  Result.A := M.A * N.A + M.C * N.B;
  Result.B := M.B * N.A + M.D * N.B;
  Result.C := M.A * N.C + M.C * N.D;
  Result.D := M.B * N.C + M.D * N.D;
  Result.E := M.A * N.E + M.C * N.F + M.E;
  Result.F := M.B * N.E + M.D * N.F + M.F;
end;

{ ---- colour parsing --------------------------------------------------- }

function HexNib(C: Char): Integer;
begin
  case C of
    '0'..'9': Result := Ord(C) - Ord('0');
    'a'..'f': Result := Ord(C) - Ord('a') + 10;
    'A'..'F': Result := Ord(C) - Ord('A') + 10;
  else Result := -1;
  end;
end;

function ParseCanvasColor(const S: string; out C: TTina4Color): Boolean;
var t: string; r, g, b, a, i: Integer; parts: TStringArray; body: string;
begin
  Result := False; C := $FF000000;
  t := LowerCase(Trim(S));
  if t = '' then Exit;
  if t = 'transparent' then begin C := $00000000; Exit(True); end;
  // named (the common set) — FPC has no case-of-string, so an if/else ladder
  if t = 'black'   then begin C := $FF000000; Exit(True); end
  else if t = 'white'   then begin C := $FFFFFFFF; Exit(True); end
  else if t = 'red'     then begin C := $FFFF0000; Exit(True); end
  else if t = 'green'   then begin C := $FF008000; Exit(True); end
  else if t = 'lime'    then begin C := $FF00FF00; Exit(True); end
  else if t = 'blue'    then begin C := $FF0000FF; Exit(True); end
  else if t = 'yellow'  then begin C := $FFFFFF00; Exit(True); end
  else if (t = 'cyan') or (t = 'aqua') then begin C := $FF00FFFF; Exit(True); end
  else if (t = 'magenta') or (t = 'fuchsia') then begin C := $FFFF00FF; Exit(True); end
  else if (t = 'gray') or (t = 'grey') then begin C := $FF808080; Exit(True); end
  else if t = 'silver'  then begin C := $FFC0C0C0; Exit(True); end
  else if t = 'orange'  then begin C := $FFFFA500; Exit(True); end
  else if t = 'purple'  then begin C := $FF800080; Exit(True); end
  else if t = 'navy'    then begin C := $FF000080; Exit(True); end
  else if t = 'teal'    then begin C := $FF008080; Exit(True); end
  else if t = 'pink'    then begin C := $FFFFC0CB; Exit(True); end;
  if (t[1] = '#') then
  begin
    t := Copy(t, 2, MaxInt);
    if Length(t) = 3 then
    begin
      r := HexNib(t[1]); g := HexNib(t[2]); b := HexNib(t[3]);
      if (r < 0) or (g < 0) or (b < 0) then Exit;
      C := $FF000000 or (Cardinal(r * 17) shl 16) or (Cardinal(g * 17) shl 8) or Cardinal(b * 17);
      Exit(True);
    end
    else if Length(t) = 6 then
    begin
      for i := 1 to 6 do if HexNib(t[i]) < 0 then Exit;
      C := $FF000000 or Cardinal(StrToInt('$' + t));
      Exit(True);
    end
    else if Length(t) = 8 then
    begin
      for i := 1 to 8 do if HexNib(t[i]) < 0 then Exit;
      // #rrggbbaa -> $aarrggbb
      a := StrToInt('$' + Copy(t, 7, 2));
      C := (Cardinal(a) shl 24) or Cardinal(StrToInt('$' + Copy(t, 1, 6)));
      Exit(True);
    end;
    Exit;
  end;
  if (Pos('rgb', t) = 1) then
  begin
    i := Pos('(', t); if i = 0 then Exit;
    body := Copy(t, i + 1, Pos(')', t) - i - 1);
    parts := body.Split([',']);
    if Length(parts) < 3 then Exit;
    r := StrToIntDef(Trim(parts[0]), 0);
    g := StrToIntDef(Trim(parts[1]), 0);
    b := StrToIntDef(Trim(parts[2]), 0);
    a := 255;
    if Length(parts) >= 4 then a := Round(StrToFloatDef(Trim(parts[3]), 1) * 255);
    C := (Cardinal(a and $FF) shl 24) or (Cardinal(r and $FF) shl 16)
       or (Cardinal(g and $FF) shl 8) or Cardinal(b and $FF);
    Exit(True);
  end;
end;

{ ---- TTina4Canvas2D --------------------------------------------------- }

constructor TTina4Canvas2D.Create(ACanvas: TTina4Canvas; AWidth, AHeight: Single;
  ABg: TTina4Color);
begin
  inherited Create;
  FCanvas := ACanvas; FW := AWidth; FH := AHeight; FBg := ABg;
  S.M := MatIdentity;
  S.Fill := $FF000000; S.Stroke := $FF000000;
  S.LineWidth := 1; S.Alpha := 1; S.FontSize := 10; S.FontStyles := [];
  S.FontFamily := ''; S.TextAlign := 'left'; S.TextBaseline := 'alphabetic';
  SetLength(FPath, 0); FSubLen := 0; FHasCur := False;
end;

function TTina4Canvas2D.Dev(UX, UY: Single): TTina4Point;
begin
  Result.X := S.M.A * UX + S.M.C * UY + S.M.E;
  Result.Y := S.M.B * UX + S.M.D * UY + S.M.F;
end;

procedure TTina4Canvas2D.AddDev(UX, UY: Single);
begin
  if FSubLen = Length(FSub) then SetLength(FSub, Max(8, FSubLen * 2));
  FSub[FSubLen] := Dev(UX, UY);
  Inc(FSubLen);
  FCurX := UX; FCurY := UY; FHasCur := True;
end;

procedure TTina4Canvas2D.PushSub;
var n: Integer;
begin
  if FSubLen >= 2 then
  begin
    n := Length(FPath); SetLength(FPath, n + 1);
    SetLength(FSub, FSubLen);   // trim
    FPath[n] := Copy(FSub, 0, FSubLen);
  end;
  FSubLen := 0; SetLength(FSub, 0);
end;

function TTina4Canvas2D.ApplyAlpha(C: TTina4Color): TTina4Color;
var a: Cardinal;
begin
  if S.Alpha >= 1 then Exit(C);
  a := Round(((C shr 24) and $FF) * S.Alpha);
  Result := (a shl 24) or (C and $00FFFFFF);
end;

// --- state ---
procedure TTina4Canvas2D.Save;
var n: Integer;
begin
  n := Length(FStack); SetLength(FStack, n + 1); FStack[n] := S;
end;

procedure TTina4Canvas2D.Restore;
var n: Integer;
begin
  n := Length(FStack);
  if n > 0 then begin S := FStack[n - 1]; SetLength(FStack, n - 1); end;
end;

// --- transforms ---
procedure TTina4Canvas2D.Translate(X, Y: Single);
var m: TCanvasMatrix;
begin m := MatIdentity; m.E := X; m.F := Y; S.M := MatMul(S.M, m); end;

procedure TTina4Canvas2D.Scale(X, Y: Single);
var m: TCanvasMatrix;
begin m := MatIdentity; m.A := X; m.D := Y; S.M := MatMul(S.M, m); end;

procedure TTina4Canvas2D.Rotate(Radians: Single);
var m: TCanvasMatrix; c, s2: Single;
begin
  c := Cos(Radians); s2 := Sin(Radians);
  m.A := c; m.B := s2; m.C := -s2; m.D := c; m.E := 0; m.F := 0;
  S.M := MatMul(S.M, m);
end;

procedure TTina4Canvas2D.Transform(A, B, C, D, E, F: Single);
var m: TCanvasMatrix;
begin
  m.A := A; m.B := B; m.C := C; m.D := D; m.E := E; m.F := F;
  S.M := MatMul(S.M, m);
end;

procedure TTina4Canvas2D.SetTransform(A, B, C, D, E, F: Single);
begin S.M.A := A; S.M.B := B; S.M.C := C; S.M.D := D; S.M.E := E; S.M.F := F; end;

procedure TTina4Canvas2D.ResetTransform;
begin S.M := MatIdentity; end;

// --- style ---
procedure TTina4Canvas2D.SetFillColor(C: TTina4Color);   begin S.Fill := C; end;
procedure TTina4Canvas2D.SetStrokeColor(C: TTina4Color); begin S.Stroke := C; end;
procedure TTina4Canvas2D.SetFillStyle(const CSS: string);
var c: TTina4Color; begin if ParseCanvasColor(CSS, c) then S.Fill := c; end;
procedure TTina4Canvas2D.SetStrokeStyle(const CSS: string);
var c: TTina4Color; begin if ParseCanvasColor(CSS, c) then S.Stroke := c; end;
procedure TTina4Canvas2D.SetLineWidth(W: Single);   begin if W > 0 then S.LineWidth := W; end;
procedure TTina4Canvas2D.SetGlobalAlpha(A: Single);
begin if A < 0 then A := 0; if A > 1 then A := 1; S.Alpha := A; end;
procedure TTina4Canvas2D.SetFont(SizePx: Single; Bold, Italic: Boolean; const Family: string);
begin
  if SizePx > 0 then S.FontSize := SizePx;
  S.FontStyles := [];
  if Bold then Include(S.FontStyles, tfsBold);
  if Italic then Include(S.FontStyles, tfsItalic);
  S.FontFamily := Family;
end;
procedure TTina4Canvas2D.SetTextAlign(const A: string);    begin S.TextAlign := LowerCase(A); end;
procedure TTina4Canvas2D.SetTextBaseline(const B: string); begin S.TextBaseline := LowerCase(B); end;

// --- rectangles ---
procedure TTina4Canvas2D.FillRect(X, Y, W, H: Single);
var poly: array[0..0] of TTina4PointArray;
begin
  SetLength(poly[0], 4);
  poly[0][0] := Dev(X, Y);     poly[0][1] := Dev(X + W, Y);
  poly[0][2] := Dev(X + W, Y + H); poly[0][3] := Dev(X, Y + H);
  FCanvas.FillPolygon(poly, ApplyAlpha(S.Fill), False);
end;

procedure TTina4Canvas2D.ClearRect(X, Y, W, H: Single);
var poly: array[0..0] of TTina4PointArray;
begin
  SetLength(poly[0], 4);
  poly[0][0] := Dev(X, Y);     poly[0][1] := Dev(X + W, Y);
  poly[0][2] := Dev(X + W, Y + H); poly[0][3] := Dev(X, Y + H);
  FCanvas.FillPolygon(poly, FBg, False);   // "erase" to the box background
end;

procedure TTina4Canvas2D.StrokeRect(X, Y, W, H: Single);
var pts: TTina4PointArray;
begin
  SetLength(pts, 4);
  pts[0] := Dev(X, Y); pts[1] := Dev(X + W, Y);
  pts[2] := Dev(X + W, Y + H); pts[3] := Dev(X, Y + H);
  FCanvas.StrokePolyline(pts, S.LineWidth * MatrixScale, ApplyAlpha(S.Stroke), True);
end;

// --- paths ---
procedure TTina4Canvas2D.BeginPath;
begin SetLength(FPath, 0); FSubLen := 0; SetLength(FSub, 0); FHasCur := False; end;

procedure TTina4Canvas2D.MoveTo(X, Y: Single);
begin PushSub; FStartX := X; FStartY := Y; AddDev(X, Y); end;

procedure TTina4Canvas2D.LineTo(X, Y: Single);
begin if not FHasCur then MoveTo(X, Y) else AddDev(X, Y); end;

procedure TTina4Canvas2D.ClosePath;
begin if FHasCur then AddDev(FStartX, FStartY); end;

procedure TTina4Canvas2D.Rect(X, Y, W, H: Single);
begin
  MoveTo(X, Y); LineTo(X + W, Y); LineTo(X + W, Y + H); LineTo(X, Y + H); ClosePath;
end;

procedure TTina4Canvas2D.Arc(CX, CY, R, StartAngle, EndAngle: Single; Anticlockwise: Boolean);
var span, a: Single; segs, i: Integer;
begin
  if Anticlockwise then
  begin
    while EndAngle > StartAngle do EndAngle := EndAngle - 2 * Pi;
  end
  else
    while EndAngle < StartAngle do EndAngle := EndAngle + 2 * Pi;
  span := EndAngle - StartAngle;
  segs := Max(6, Round(Abs(span) / (Pi / 32)));   // ~ every 5.6°
  for i := 0 to segs do
  begin
    a := StartAngle + span * (i / segs);
    if (i = 0) and not FHasCur then MoveTo(CX + R * Cos(a), CY + R * Sin(a))
    else LineTo(CX + R * Cos(a), CY + R * Sin(a));
  end;
end;

procedure TTina4Canvas2D.Ellipse(CX, CY, RX, RY, Rotation, StartAngle, EndAngle: Single;
  Anticlockwise: Boolean);
var span, a, px, py, c, s2: Single; segs, i: Integer;
begin
  if Anticlockwise then
    while EndAngle > StartAngle do EndAngle := EndAngle - 2 * Pi
  else
    while EndAngle < StartAngle do EndAngle := EndAngle + 2 * Pi;
  span := EndAngle - StartAngle;
  segs := Max(8, Round(Abs(span) / (Pi / 32)));
  c := Cos(Rotation); s2 := Sin(Rotation);
  for i := 0 to segs do
  begin
    a := StartAngle + span * (i / segs);
    px := RX * Cos(a); py := RY * Sin(a);
    if (i = 0) and not FHasCur then MoveTo(CX + px * c - py * s2, CY + px * s2 + py * c)
    else LineTo(CX + px * c - py * s2, CY + px * s2 + py * c);
  end;
end;

procedure TTina4Canvas2D.ArcTo(X1, Y1, X2, Y2, R: Single);
begin
  // simplified: corner via the tangent point (good enough for rounded rects)
  LineTo(X1, Y1);
  LineTo(X2, Y2);
end;

procedure TTina4Canvas2D.QuadraticCurveTo(CPX, CPY, X, Y: Single);
var i, segs: Integer; t, mt, sx, sy: Single;
begin
  if not FHasCur then MoveTo(CPX, CPY);
  sx := FCurX; sy := FCurY; segs := 24;
  for i := 1 to segs do
  begin
    t := i / segs; mt := 1 - t;
    LineTo(mt * mt * sx + 2 * mt * t * CPX + t * t * X,
           mt * mt * sy + 2 * mt * t * CPY + t * t * Y);
  end;
end;

procedure TTina4Canvas2D.BezierCurveTo(CP1X, CP1Y, CP2X, CP2Y, X, Y: Single);
var i, segs: Integer; t, mt, sx, sy: Single;
begin
  if not FHasCur then MoveTo(CP1X, CP1Y);
  sx := FCurX; sy := FCurY; segs := 32;
  for i := 1 to segs do
  begin
    t := i / segs; mt := 1 - t;
    LineTo(mt*mt*mt*sx + 3*mt*mt*t*CP1X + 3*mt*t*t*CP2X + t*t*t*X,
           mt*mt*mt*sy + 3*mt*mt*t*CP1Y + 3*mt*t*t*CP2Y + t*t*t*Y);
  end;
end;

procedure TTina4Canvas2D.Fill(EvenOdd: Boolean);
begin
  PushSub;
  if Length(FPath) > 0 then FCanvas.FillPolygon(FPath, ApplyAlpha(S.Fill), EvenOdd);
end;

function TTina4Canvas2D.MatrixScale: Single;
begin
  Result := Sqrt(Abs(S.M.A * S.M.D - S.M.B * S.M.C));   // sqrt of the area scale
  if Result <= 0.0001 then Result := 1;
end;

procedure TTina4Canvas2D.Stroke;
var i, m: Integer; col: TTina4Color; dw: Single; sub: TTina4PointArray; closed: Boolean;
begin
  PushSub;
  col := ApplyAlpha(S.Stroke);
  dw := S.LineWidth * MatrixScale;      // line width lives in user space → to device
  if dw < 0.4 then dw := 0.4;
  for i := 0 to High(FPath) do
  begin
    sub := FPath[i];
    m := Length(sub);
    if m < 2 then Continue;
    // a ClosePath duplicated the first point at the end — pass it as a closed
    // ring so the join at the closure is round too
    closed := (m > 2) and (Abs(sub[m - 1].X - sub[0].X) < 0.01)
                      and (Abs(sub[m - 1].Y - sub[0].Y) < 0.01);
    if closed then
      FCanvas.StrokePolyline(Copy(sub, 0, m - 1), dw, col, True)
    else
      FCanvas.StrokePolyline(sub, dw, col, False);
  end;
end;

// --- text ---
procedure TTina4Canvas2D.FillText(const Text: string; X, Y: Single);
var p: TTina4Point; m: TTina4TextMetrics; dx, dy: Single;
begin
  dx := 0; dy := 0;
  if S.TextAlign <> 'left' then
  begin
    m := FCanvas.MeasureText(Text, S.FontSize, S.FontStyles);
    if S.TextAlign = 'center' then dx := -m.Width / 2
    else if (S.TextAlign = 'right') or (S.TextAlign = 'end') then dx := -m.Width;
  end;
  if S.TextBaseline = 'top' then dy := 0
  else if S.TextBaseline = 'middle' then dy := -S.FontSize * 0.35
  else dy := -S.FontSize * 0.8;   // alphabetic/bottom ~ shift up from the baseline
  p := Dev(X + dx, Y + dy);
  FCanvas.DrawText(p.X, p.Y, Text, S.FontSize, S.FontStyles, ApplyAlpha(S.Fill));
end;

procedure TTina4Canvas2D.StrokeText(const Text: string; X, Y: Single);
var p: TTina4Point;
begin
  // no glyph outlines on the backend — approximate with the stroke colour
  p := Dev(X, Y - S.FontSize * 0.8);
  FCanvas.DrawText(p.X, p.Y, Text, S.FontSize, S.FontStyles, ApplyAlpha(S.Stroke));
end;

function TTina4Canvas2D.MeasureText(const Text: string): Single;
begin Result := FCanvas.MeasureText(Text, S.FontSize, S.FontStyles).Width; end;

// --- images ---
procedure TTina4Canvas2D.DrawImage(const Src: string; DX, DY: Single);
var h, iw, ih: Integer; fw, fh: Single;
begin
  h := FCanvas.LoadImage(Src);
  if h < 0 then Exit;
  if not FCanvas.ImageSize(h, fw, fh) then Exit;
  iw := Round(fw); ih := Round(fh);
  DrawImage(Src, DX, DY, iw, ih);
end;

procedure TTina4Canvas2D.DrawImage(const Src: string; DX, DY, DW, DH: Single);
var h: Integer; p: TTina4Point;
begin
  h := FCanvas.LoadImage(Src);
  if h < 0 then Exit;
  p := Dev(DX, DY);   // axis-aligned placement (rotation/scale of images: TODO)
  FCanvas.DrawImage(h, p.X, p.Y, DW, DH);
end;

end.
