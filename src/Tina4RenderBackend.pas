unit Tina4RenderBackend;

{ Platform contract for the Tina4 native-pascal HTML renderer.
  See ARCHITECTURE.md: the layout/paint core talks ONLY to these
  abstract classes; each OS supplies a small shell implementing them.
  Coordinates are CSS pixels, origin top-left. Colors are $AARRGGBB. }

{$mode delphi}{$H+}

interface

type
  TTina4Color = Cardinal; // $AARRGGBB

  // tfsOverline has no native font attribute — the layer paints it manually,
  // so shells may ignore it in DrawText (they draw underline/strike natively).
  TTina4FontStyle = (tfsBold, tfsItalic, tfsUnderline, tfsStrike, tfsOverline);
  TTina4FontStyles = set of TTina4FontStyle;

  TTina4TextMetrics = record
    Width: Single;
    Ascent: Single;   // baseline offset from top
    Descent: Single;
    LineHeight: Single;
  end;

  TTina4Point = record X, Y: Single; end;
  TTina4PointArray = array of TTina4Point;

  TTina4Canvas = class
  public
    { Extra spacing between characters (CSS letter-spacing), applied by
      DrawText/MeasureText. Set around a run, reset to 0 after. }
    LetterSpacing: Single;
    { CSS font-family for the next DrawText/MeasureText — a family stack like
      "Gabarito, system-ui, sans-serif" or a registered @font-face name. Set
      around a run, reset to '' (system) after. Backends resolve the first
      family they can, incl. fonts registered via RegisterFont. }
    FontFamily: string;
    { CSS font-weight (100..900) for the next DrawText/MeasureText. 0 or 400 =
      normal. Set around a run, reset to 0 after. Backends combine it with the
      tfsBold style flag (bold ⇒ at least 700). }
    FontWeight: Integer;
    procedure FillRect(X, Y, W, H: Single; Color: TTina4Color); virtual; abstract;
    procedure StrokeRect(X, Y, W, H, Thickness: Single; Color: TTina4Color); virtual; abstract;
    { Rounded variants; default falls back to square corners so simple
      backends (headless/null) stay correct. }
    procedure FillRoundRect(X, Y, W, H, Radius: Single; Color: TTina4Color); virtual;
    procedure StrokeRoundRect(X, Y, W, H, Radius, Thickness: Single; Color: TTina4Color); virtual;
    { Gradient fills for CSS linear-/radial-gradient backgrounds. Colors[] +
      Positions[] (0..1, or <0 = auto/evenly-spaced) describe the stops; Radius
      rounds the box corners. AngleDeg is the CSS gradient angle (0=up,90=right).
      The base class approximates with a flat average-colour fill so headless and
      not-yet-updated shells still render something sensible. }
    procedure FillLinearGradient(X, Y, W, H, Radius, AngleDeg: Single;
      const Colors: array of TTina4Color; const Positions: array of Single); virtual;
    procedure FillRadialGradient(X, Y, W, H, Radius: Single;
      const Colors: array of TTina4Color; const Positions: array of Single); virtual;
    { A soft (blurred) drop shadow for a rounded rect — CSS box-shadow. The base
      class draws a hard-edged rect so simple backends still show a shadow. }
    procedure FillSoftShadow(X, Y, W, H, Radius, Blur: Single; Color: TTina4Color); virtual;
    procedure DrawLine(X1, Y1, X2, Y2, Thickness: Single; Color: TTina4Color); virtual; abstract;
    { Stroke a connected polyline (device coords) with ROUND joins + caps — used
      by the canvas/Lottie path stroker so curved outlines are smooth. The base
      class falls back to independent line segments (visible joints); shells
      override with a native round-joined path stroke. }
    procedure StrokePolyline(const Pts: TTina4PointArray; Width: Single;
      Color: TTina4Color; Closed: Boolean); virtual;
    { Fills the area covered by one or more closed contours (device coords),
      used by the SVG painter for circles, polygons and path shapes. EvenOdd
      selects the even-odd rule; otherwise nonzero winding. The base class
      does a portable software scanline fill emitting 1px FillRect spans, so
      every backend works; shells may override for anti-aliasing. }
    procedure FillPolygon(const Contours: array of TTina4PointArray;
      Color: TTina4Color; EvenOdd: Boolean = False); virtual;
    { Draws text with (X,Y) as the TOP-LEFT of the text box. }
    procedure DrawText(X, Y: Single; const Text: string; FontSize: Single;
      Styles: TTina4FontStyles; Color: TTina4Color); virtual; abstract;
    function MeasureText(const Text: string; FontSize: Single;
      Styles: TTina4FontStyles): TTina4TextMetrics; virtual; abstract;
    { Register a font (ttf/otf) under the CSS `Family` name so FontFamily can
      resolve it (for @font-face). `Src` is either a local file path or an
      http(s) URL — the shell fetches + disk-caches a URL the same way it does
      an <img>. Default: no-op (returns False); shells that can load fonts
      override. }
    function RegisterFont(const Family, Src: string): Boolean; virtual;
    procedure SetClip(X, Y, W, H: Single); virtual; abstract;
    procedure ClearClip; virtual; abstract;
    { Transform stack for CSS transforms (rotate/scale). Default no-ops so
      simple/headless backends ignore them. Always balance Save/Restore. }
    procedure SaveState; virtual;
    procedure RestoreState; virtual;
    procedure Translate(DX, DY: Single); virtual;
    procedure Rotate(Degrees: Single); virtual;
    procedure Scale(SX, SY: Single); virtual;
    { Shear the coordinate system (CSS skew), angles in degrees. Default: no-op. }
    procedure Skew(AngleXDeg, AngleYDeg: Single); virtual;
    { Images: LoadImage fetches (http/https or local path) and decodes,
      returning a handle (-1 on failure) that stays valid for the canvas
      lifetime; repeated calls with the same Src are cached. Default
      implementation supports nothing — backends override. }
    function LoadImage(const Src: string): Integer; virtual;
    function ImageSize(Handle: Integer; out W, H: Single): Boolean; virtual;
    procedure DrawImage(Handle: Integer; X, Y, W, H: Single); virtual;
  end;

  TTina4PaintEvent = procedure(Canvas: TTina4Canvas; Width, Height: Single) of object;
  TTina4MouseButtonEvent = procedure(X, Y: Single) of object;
  TTina4MouseMoveEvent = procedure(X, Y: Single) of object;
  { Scroll carries the cursor position so the app can route the delta to an
    inner scrollable box (overflow:auto) under the pointer. }
  TTina4ScrollEvent = procedure(X, Y, DeltaX, DeltaY: Single) of object;
  TTina4ResizeEvent = procedure(Width, Height: Single) of object;
  { Chars = printable text of the keystroke ('' for pure control keys).
    KeyCode = platform-neutral: use the TK_* constants below. }
  TTina4KeyEvent = procedure(const Chars: string; KeyCode: Integer) of object;
  TTina4TickEvent = procedure of object;

const
  TK_NONE = 0; TK_RETURN = 1; TK_BACKSPACE = 2; TK_TAB = 3; TK_ESCAPE = 4;
  TK_LEFT = 5; TK_RIGHT = 6; TK_UP = 7; TK_DOWN = 8; TK_DELETE = 9;

type
  { OS pointer shapes a shell can show for the CSS `cursor` property. Desktop
    shells map these to native cursors; touch shells ignore them. }
  TTina4Cursor = (tcDefault, tcPointer, tcText, tcMove, tcGrab, tcGrabbing,
    tcCrosshair, tcNotAllowed, tcColResize, tcRowResize, tcWait, tcHelp, tcNone);

  TTina4Shell = class
  public
    OnPaint: TTina4PaintEvent;
    OnMouseDown: TTina4MouseButtonEvent;
    OnMouseUp: TTina4MouseButtonEvent;
    OnMouseMove: TTina4MouseMoveEvent;
    OnMouseDrag: TTina4MouseMoveEvent;   // move with the primary button held
    OnScroll: TTina4ScrollEvent;
    OnResize: TTina4ResizeEvent;
    OnKeyDown: TTina4KeyEvent;
    OnTick: TTina4TickEvent;
    { Fire OnTick every IntervalMs on the UI thread (scripted drivers,
      caret blink, animations). Default: not supported. }
    procedure StartTicker(IntervalMs: Integer); virtual;
    procedure Initialize(Width, Height: Integer; const Title: string); virtual; abstract;
    procedure Invalidate; virtual; abstract;   // request repaint
    procedure Run; virtual; abstract;          // enter event loop
    procedure Quit; virtual; abstract;
    procedure SetTitle(const Title: string); virtual;
    { Set the OS pointer shape (CSS `cursor`). Default: no-op (touch shells). }
    procedure SetCursor(C: TTina4Cursor); virtual;
    { Fetch a URL synchronously and write the bytes to DestPath. Used to pull an
      external <link rel=stylesheet href> before the first layout (same idea as
      the font fetch). Returns True on success. Default: False (no network). }
    function FetchToFile(const Url, DestPath: string): Boolean; virtual;
    { Open the OS file picker; returns the chosen path or '' if cancelled.
      Default '' (no picker); backends override with the native dialog. }
    function PickFile: string; virtual;
    { Capture one still image from the OS camera to a temp file; returns its
      path or '' if unavailable/cancelled. Default ''. }
    function CaptureCamera: string; virtual;
    { Text measurement outside a paint cycle (layout needs this). }
    function GetMeasuringCanvas: TTina4Canvas; virtual; abstract;
  end;

implementation

procedure TTina4Shell.SetTitle(const Title: string);
begin
  // optional per shell
end;

procedure TTina4Shell.SetCursor(C: TTina4Cursor);
begin
  // optional per shell (desktop shells override with native cursors)
end;

function TTina4Shell.FetchToFile(const Url, DestPath: string): Boolean;
begin
  Result := False;   // no network by default; desktop shells override
end;

procedure TTina4Shell.StartTicker(IntervalMs: Integer);
begin
  // optional per shell
end;

function TTina4Shell.PickFile: string;
begin
  Result := '';
end;

function TTina4Shell.CaptureCamera: string;
begin
  Result := '';
end;

procedure TTina4Canvas.StrokePolyline(const Pts: TTina4PointArray; Width: Single;
  Color: TTina4Color; Closed: Boolean);
var i: Integer;
begin
  if Length(Pts) < 2 then Exit;
  for i := 0 to High(Pts) - 1 do
    DrawLine(Pts[i].X, Pts[i].Y, Pts[i + 1].X, Pts[i + 1].Y, Width, Color);
  if Closed then
    DrawLine(Pts[High(Pts)].X, Pts[High(Pts)].Y, Pts[0].X, Pts[0].Y, Width, Color);
end;

procedure TTina4Canvas.FillPolygon(const Contours: array of TTina4PointArray;
  Color: TTina4Color; EvenOdd: Boolean);
var
  fMinY, fMaxY, yc, xI, tmpX: Single;
  minY, maxY, y, i, j, n, cnt, wind, tmpW: Integer;
  xs: array of Single;
  ws: array of Integer;   // edge winding: +1 down, -1 up
  a, b: TTina4Point;
begin
  fMinY := 1e30; fMaxY := -1e30;
  for i := 0 to High(Contours) do
    for j := 0 to High(Contours[i]) do
    begin
      if Contours[i][j].Y < fMinY then fMinY := Contours[i][j].Y;
      if Contours[i][j].Y > fMaxY then fMaxY := Contours[i][j].Y;
    end;
  if fMaxY <= fMinY then Exit;
  minY := Trunc(fMinY); maxY := Trunc(fMaxY) + 1;

  for y := minY to maxY do
  begin
    yc := y + 0.5;
    cnt := 0; SetLength(xs, 0); SetLength(ws, 0);
    for i := 0 to High(Contours) do
    begin
      n := Length(Contours[i]);
      if n < 2 then Continue;
      for j := 0 to n - 1 do
      begin
        a := Contours[i][j];
        b := Contours[i][(j + 1) mod n];
        if a.Y = b.Y then Continue;               // horizontal: no crossing
        if (a.Y <= yc) and (b.Y > yc) then
        begin
          xI := a.X + (yc - a.Y) / (b.Y - a.Y) * (b.X - a.X);
          SetLength(xs, cnt + 1); SetLength(ws, cnt + 1);
          xs[cnt] := xI; ws[cnt] := 1; Inc(cnt);
        end
        else if (b.Y <= yc) and (a.Y > yc) then
        begin
          xI := a.X + (yc - a.Y) / (b.Y - a.Y) * (b.X - a.X);
          SetLength(xs, cnt + 1); SetLength(ws, cnt + 1);
          xs[cnt] := xI; ws[cnt] := -1; Inc(cnt);
        end;
      end;
    end;
    if cnt < 2 then Continue;
    // insertion sort intersections (and winding) by x
    for i := 1 to cnt - 1 do
    begin
      tmpX := xs[i]; tmpW := ws[i]; j := i - 1;
      while (j >= 0) and (xs[j] > tmpX) do
      begin
        xs[j + 1] := xs[j]; ws[j + 1] := ws[j]; Dec(j);
      end;
      xs[j + 1] := tmpX; ws[j + 1] := tmpW;
    end;

    if EvenOdd then
    begin
      i := 0;
      while i + 1 < cnt do
      begin
        if xs[i + 1] > xs[i] then
          FillRect(xs[i], y, xs[i + 1] - xs[i], 1, Color);
        Inc(i, 2);
      end;
    end
    else
    begin
      wind := 0;
      for i := 0 to cnt - 2 do
      begin
        wind := wind + ws[i];
        if (wind <> 0) and (xs[i + 1] > xs[i]) then
          FillRect(xs[i], y, xs[i + 1] - xs[i], 1, Color);
      end;
    end;
  end;
end;

procedure TTina4Canvas.FillRoundRect(X, Y, W, H, Radius: Single; Color: TTina4Color);
begin
  FillRect(X, Y, W, H, Color);
end;

procedure TTina4Canvas.StrokeRoundRect(X, Y, W, H, Radius, Thickness: Single; Color: TTina4Color);
begin
  StrokeRect(X, Y, W, H, Thickness, Color);
end;

{ Average a stop list into one colour (per-channel mean over alpha, R, G, B). }
function AvgStops(const Colors: array of TTina4Color): TTina4Color;
var i, n: Integer; a, r, g, b: Integer;
begin
  n := Length(Colors);
  if n = 0 then Exit($00000000);
  a := 0; r := 0; g := 0; b := 0;
  for i := 0 to n - 1 do
  begin
    a := a + Integer((Colors[i] shr 24) and $FF);
    r := r + Integer((Colors[i] shr 16) and $FF);
    g := g + Integer((Colors[i] shr 8) and $FF);
    b := b + Integer(Colors[i] and $FF);
  end;
  Result := (Cardinal(a div n) shl 24) or (Cardinal(r div n) shl 16) or
            (Cardinal(g div n) shl 8) or Cardinal(b div n);
end;

procedure TTina4Canvas.FillLinearGradient(X, Y, W, H, Radius, AngleDeg: Single;
  const Colors: array of TTina4Color; const Positions: array of Single);
begin
  // base fallback: flat average-colour fill (shells override for real gradients)
  FillRoundRect(X, Y, W, H, Radius, AvgStops(Colors));
end;

procedure TTina4Canvas.FillRadialGradient(X, Y, W, H, Radius: Single;
  const Colors: array of TTina4Color; const Positions: array of Single);
begin
  FillRoundRect(X, Y, W, H, Radius, AvgStops(Colors));
end;

procedure TTina4Canvas.FillSoftShadow(X, Y, W, H, Radius, Blur: Single; Color: TTina4Color);
begin
  // base fallback: a hard-edged shadow rect (no blur)
  FillRoundRect(X, Y, W, H, Radius, Color);
end;

function TTina4Canvas.LoadImage(const Src: string): Integer;
begin
  Result := -1;
end;

function TTina4Canvas.ImageSize(Handle: Integer; out W, H: Single): Boolean;
begin
  W := 0; H := 0;
  Result := False;
end;

function TTina4Canvas.RegisterFont(const Family, Src: string): Boolean;
begin
  Result := False;   // backends that can load fonts override this
end;

procedure TTina4Canvas.DrawImage(Handle: Integer; X, Y, W, H: Single);
begin
  // no-op in the base class
end;

procedure TTina4Canvas.SaveState; begin end;
procedure TTina4Canvas.RestoreState; begin end;
procedure TTina4Canvas.Translate(DX, DY: Single); begin end;
procedure TTina4Canvas.Rotate(Degrees: Single); begin end;
procedure TTina4Canvas.Scale(SX, SY: Single); begin end;
procedure TTina4Canvas.Skew(AngleXDeg, AngleYDeg: Single); begin end;

end.
