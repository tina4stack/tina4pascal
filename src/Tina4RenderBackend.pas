unit Tina4RenderBackend;

{ Platform contract for the Tina4 native-pascal HTML renderer.
  See ARCHITECTURE.md: the layout/paint core talks ONLY to these
  abstract classes; each OS supplies a small shell implementing them.
  Coordinates are CSS pixels, origin top-left. Colors are $AARRGGBB. }

{$mode delphi}{$H+}

interface

uses SysUtils, Classes, base64, Tina4WebP;

const
  { Handles at/above this are base-class RGBA images (pure-Pascal WebP decode),
    distinguishing them from a shell's native image handles. }
  WEBP_HANDLE_BASE = $40000000;

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
    { Clip subsequent drawing to an arbitrary polygon (CSS clip-path; the core
      tessellates circle/ellipse/inset/polygon to points in box coords). Must be
      balanced by a SaveState/RestoreState pair. Default: no-op (no clipping —
      the element simply paints unclipped, a safe degrade). }
    procedure ClipPolygon(const Pts: TTina4PointArray); virtual;
    { Transform stack for CSS transforms (rotate/scale). Default no-ops so
      simple/headless backends ignore them. Always balance Save/Restore. }
    procedure SaveState; virtual;
    procedure RestoreState; virtual;
    procedure Translate(DX, DY: Single); virtual;
    procedure Rotate(Degrees: Single); virtual;
    procedure Scale(SX, SY: Single); virtual;
    { Shear the coordinate system (CSS skew), angles in degrees. Default: no-op. }
    procedure Skew(AngleXDeg, AngleYDeg: Single); virtual;
    { Concatenate a 2D affine matrix (CSS matrix(a,b,c,d,e,f)). Default: no-op. }
    procedure TransformMatrix(A, B, C, D, E, F: Single); virtual;
    { Images: LoadImage fetches (http/https or local path) and decodes,
      returning a handle (-1 on failure) that stays valid for the canvas
      lifetime; repeated calls with the same Src are cached. Default
      implementation supports nothing — backends override. }
    function LoadImage(const Src: string): Integer; virtual;
    function ImageSize(Handle: Integer; out W, H: Single): Boolean; virtual;
    procedure DrawImage(Handle: Integer; X, Y, W, H: Single); virtual;
    { Offscreen compositing for CSS filter / mix-blend-mode. BeginLayer redirects
      all subsequent drawing into an offscreen buffer covering the doc-space rect
      (X,Y,W,H) grown by Pad on every side (Pad gives blur/shadow room). It
      returns a layer handle, or -1 when the backend has no offscreen support —
      the caller then draws directly and the effect is skipped (a safe degrade).
      EndLayerFiltered pops the buffer, applies the CSS `filter` chain to its
      pixels, and composites it back onto the parent using BlendMode ('' / 'normal'
      = source-over). Nesting is a stack; always balance the Begin/End pair. }
    function BeginLayer(X, Y, W, H, Pad: Single): Integer; virtual;
    procedure EndLayerFiltered(Handle: Integer; const FilterSpec, BlendMode, MaskSpec: string); virtual;
    { CSS backdrop-filter: capture the already-painted pixels under the rect
      (X,Y,W,H), run the filter chain over them, and paint the result back — done
      BEFORE the element itself draws. Default: no-op (backend has no read-back). }
    procedure BackdropFilter(X, Y, W, H: Single; const FilterSpec: string); virtual;
    { Finish a layer begun for a 3D transform: map the captured element texture
      onto the projected quadrilateral. Corners is [x0,y0,x1,y1,x2,y2,x3,y3] in
      doc coords for the texture's TL, TR, BR, BL. Default: no-op (drops the
      layer), so backends without a warp show nothing rather than an unwarped
      copy — callers may prefer to skip the 3D path when BeginLayer returns -1. }
    procedure EndLayer3D(Handle: Integer; const Corners: array of Single); virtual;
    { Blit a raw $AARRGGBB pixel buffer (BW×BH, row-major, top-left origin,
      straight/non-premultiplied alpha) into the doc-space rect (DX,DY,DW,DH),
      scaling as needed. Lets the core render vector-heavy, time-driven content
      (e.g. a <lottie>) into an in-process software buffer (Tina4RasterCanvas) and
      hand the shell ONE composited image per frame instead of hundreds of small
      draw calls — decisive on Android where each call is a JNI round-trip. A
      backend advertises real support via SupportsRGBA; the default is a no-op, so
      the core keeps a direct-draw fallback for backends that don't implement it. }
    function SupportsRGBA: Boolean; virtual;
    procedure DrawRGBA(Buf: Pointer; BW, BH: Integer; DX, DY, DW, DH: Single); virtual;
    destructor Destroy; override;
  protected
    { Base-class pure-Pascal image store: decodes formats the shell's native
      loader can't (currently WebP) from a local file or data: URI, and renders
      them via the DrawRGBA contract. Shells fall back to this from LoadImage and
      delegate WEBP_HANDLE_BASE handles back here in ImageSize/DrawImage. Headless
      canvases (e.g. the PDF exporter) that override neither get WebP for free. }
    FBaseSrc: TStringList;                    // Src -> handle (in Objects)
    FBasePix: array of array of Cardinal;     // per-handle $AARRGGBB pixels
    FBaseW, FBaseH: array of Integer;
    FBaseCount: Integer;
    function DecodeToBaseStore(const Src: string): Integer;
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
    { Post a local OS notification (Notification Center / toast / libnotify).
      Tag lets a later notification replace an earlier one with the same tag.
      Default: no-op; each desktop/mobile shell overrides with the native call. }
    procedure Notify(const Title, Body, Tag: string); virtual;
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

  { A decoupled notification hook: the host wires this to its shell's Notify, and
    the core (an HTML `notify.show` action or an SSE/WS handler) calls Tina4Notify
    without a shell reference. No-op until a host registers a handler. }
  TTina4NotifyProc = procedure(const Title, Body, Tag: string);

procedure Tina4SetNotifyHandler(P: TTina4NotifyProc);
procedure Tina4Notify(const Title, Body, Tag: string);

implementation

var GNotifyHook: TTina4NotifyProc = nil;

procedure Tina4SetNotifyHandler(P: TTina4NotifyProc);
begin
  GNotifyHook := P;
end;

procedure Tina4Notify(const Title, Body, Tag: string);
begin
  if Assigned(GNotifyHook) then GNotifyHook(Title, Body, Tag);
end;

procedure TTina4Shell.SetTitle(const Title: string);
begin
  // optional per shell
end;

procedure TTina4Shell.SetCursor(C: TTina4Cursor);
begin
  // optional per shell (desktop shells override with native cursors)
end;

procedure TTina4Shell.Notify(const Title, Body, Tag: string);
begin
  // optional per shell (desktop/mobile shells post a native notification)
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

{ Resolve the CSS stop offsets into a monotonic 0..1 location array — the same
  rule the Cocoa/iOS shells use: an explicit Positions[i] >= 0 wins, otherwise
  the stop is spread evenly, and each location is clamped up to its predecessor
  so the list never runs backwards. }
procedure BuildStopLocs(const Colors: array of TTina4Color;
  const Positions: array of Single; out Locs: array of Single);
var i, n: Integer;
begin
  n := Length(Colors);
  for i := 0 to n - 1 do
  begin
    if (i < Length(Positions)) and (Positions[i] >= 0) then Locs[i] := Positions[i]
    else if n > 1 then Locs[i] := i / (n - 1)
    else Locs[i] := 0;
    if (i > 0) and (Locs[i] < Locs[i - 1]) then Locs[i] := Locs[i - 1];
  end;
end;

{ Straight (non-premultiplied) RGBA lerp of the stop list at parameter t (0..1).
  A fully transparent stop (alpha 0, e.g. the CSS `transparent` keyword, which is
  rgba(0,0,0,0)) would otherwise drag the colour toward black across the fade;
  since the portable path paints opaque (see note on FillLinearGradient), we
  borrow the opposite stop's RGB for a zero-alpha endpoint so `pink→transparent`
  fades pink→pink rather than pink→black. }
function SampleStops(t: Single; const Colors: array of TTina4Color;
  const Locs: array of Single): TTina4Color;
var i, n: Integer; f: Single; c0, c1: TTina4Color;
    r0, g0, b0, r1, g1, b1, a0, a1: Integer; r, g, b: Integer;
begin
  n := Length(Colors);
  if n = 0 then Exit($00000000);
  if n = 1 then Exit(Colors[0]);
  if t <= Locs[0] then Exit(Colors[0]);
  if t >= Locs[n - 1] then Exit(Colors[n - 1]);
  i := 0;
  while (i < n - 1) and (t > Locs[i + 1]) do Inc(i);
  c0 := Colors[i]; c1 := Colors[i + 1];
  if Locs[i + 1] > Locs[i] then f := (t - Locs[i]) / (Locs[i + 1] - Locs[i]) else f := 0;
  a0 := (c0 shr 24) and $FF; r0 := (c0 shr 16) and $FF; g0 := (c0 shr 8) and $FF; b0 := c0 and $FF;
  a1 := (c1 shr 24) and $FF; r1 := (c1 shr 16) and $FF; g1 := (c1 shr 8) and $FF; b1 := c1 and $FF;
  if (a0 = 0) and (a1 <> 0) then begin r0 := r1; g0 := g1; b0 := b1; end
  else if (a1 = 0) and (a0 <> 0) then begin r1 := r0; g1 := g0; b1 := b0; end;
  r := r0 + Round((r1 - r0) * f);
  g := g0 + Round((g1 - g0) * f);
  b := b0 + Round((b1 - b0) * f);
  Result := $FF000000 or (Cardinal(r) shl 16) or (Cardinal(g) shl 8) or Cardinal(b);
end;

{ Portable software gradient: rasterises the box scanline by scanline, coalescing
  equal-colour runs into single FillRect spans, so every backend that can fill a
  rect (GDI, headless, Android) gets real linear/radial gradients through the
  contract — Cocoa/iOS still override with the native GPU path. Rounded corners
  are honoured by insetting each scanline to the corner arc. Kind: 0=linear (CSS
  angle 0=up, 90=right), 1=radial (centred, farthest-corner). Opaque in this path
  (GDI has no per-pixel alpha in v1); semi-transparent stops don't blend the
  backdrop. }
procedure SoftGradientFill(C: TTina4Canvas; Kind: Integer;
  X, Y, W, H, Radius, AngleDeg: Single;
  const Colors: array of TTina4Color; const Positions: array of Single);
var
  locs: array of Single;
  n, y0, y1, py, px, x0, x1, runStart: Integer;
  r, cx, cy, dxu, dyu, gradLen, rad, a, yc, dEdge, dTop, dBot, inset, xl, xr, t, proj: Single;
  col, runCol: TTina4Color;
begin
  n := Length(Colors);
  if (n = 0) or (W <= 0) or (H <= 0) then Exit;
  SetLength(locs, n);
  BuildStopLocs(Colors, Positions, locs);

  r := Radius;
  if r > W / 2 then r := W / 2;
  if r > H / 2 then r := H / 2;
  if r < 0 then r := 0;

  cx := X + W / 2; cy := Y + H / 2;
  a := AngleDeg * Pi / 180;
  dxu := Sin(a); dyu := -Cos(a);
  gradLen := Abs(W * Sin(a)) + Abs(H * Cos(a));
  if gradLen <= 0 then gradLen := 1;
  rad := Sqrt((W / 2) * (W / 2) + (H / 2) * (H / 2));
  if rad <= 0 then rad := 1;

  y0 := Round(Y); y1 := Round(Y + H) - 1;
  for py := y0 to y1 do
  begin
    yc := py + 0.5;
    // rounded-corner inset for this scanline
    inset := 0;
    if r > 0 then
    begin
      dTop := yc - Y; dBot := (Y + H) - yc;
      if dTop < dBot then dEdge := dTop else dEdge := dBot;
      if dEdge < r then inset := r - Sqrt(Abs(r * r - (r - dEdge) * (r - dEdge)));
    end;
    xl := X + inset; xr := X + W - inset;
    x0 := Round(xl); x1 := Round(xr) - 1;
    if x1 < x0 then Continue;

    runStart := x0;
    runCol := 0;
    for px := x0 to x1 do
    begin
      if Kind = 0 then
      begin
        proj := (px + 0.5 - cx) * dxu + (yc - cy) * dyu;
        t := (proj + gradLen / 2) / gradLen;
      end
      else
        t := Sqrt((px + 0.5 - cx) * (px + 0.5 - cx) + (yc - cy) * (yc - cy)) / rad;
      if t < 0 then t := 0 else if t > 1 then t := 1;
      col := SampleStops(t, Colors, locs);
      if px = x0 then begin runStart := px; runCol := col; end
      else if col <> runCol then
      begin
        C.FillRect(runStart, py, px - runStart, 1, runCol);
        runStart := px; runCol := col;
      end;
    end;
    C.FillRect(runStart, py, x1 + 1 - runStart, 1, runCol);
  end;
end;

procedure TTina4Canvas.FillLinearGradient(X, Y, W, H, Radius, AngleDeg: Single;
  const Colors: array of TTina4Color; const Positions: array of Single);
begin
  SoftGradientFill(Self, 0, X, Y, W, H, Radius, AngleDeg, Colors, Positions);
end;

procedure TTina4Canvas.FillRadialGradient(X, Y, W, H, Radius: Single;
  const Colors: array of TTina4Color; const Positions: array of Single);
begin
  SoftGradientFill(Self, 1, X, Y, W, H, Radius, 0, Colors, Positions);
end;

procedure TTina4Canvas.FillSoftShadow(X, Y, W, H, Radius, Blur: Single; Color: TTina4Color);
begin
  // base fallback: a hard-edged shadow rect (no blur)
  FillRoundRect(X, Y, W, H, Radius, Color);
end;

{ Decode a WebP (local file or data: URI) to the base RGBA store, converting the
  decoder's R,G,B,A bytes to $AARRGGBB Cardinals (endian-safe). Cached by Src. }
function TTina4Canvas.DecodeToBaseStore(const Src: string): Integer;
var
  idx, comma, i, n: Integer;
  raw, rgba: TBytes; dec: RawByteString; ms: TMemoryStream;
  w, h: Integer; px: array of Cardinal;
begin
  Result := -1;
  if FBaseSrc = nil then FBaseSrc := TStringList.Create;
  idx := FBaseSrc.IndexOf(Src);
  if idx >= 0 then Exit(Integer(PtrInt(FBaseSrc.Objects[idx])));
  raw := nil;
  if Copy(LowerCase(Src), 1, 5) = 'data:' then
  begin
    comma := Pos(',', Src);
    if comma > 0 then
    begin
      try dec := DecodeStringBase64(Copy(Src, comma + 1, MaxInt), False); except dec := ''; end;
      SetLength(raw, Length(dec));
      if Length(dec) > 0 then Move(dec[1], raw[0], Length(dec));
    end;
  end
  else if FileExists(Src) then
  begin
    ms := TMemoryStream.Create;
    try
      ms.LoadFromFile(Src);
      SetLength(raw, ms.Size);
      if ms.Size > 0 then Move(ms.Memory^, raw[0], ms.Size);
    finally ms.Free; end;
  end;
  if Length(raw) < 12 then Exit;
  // Sniff the RIFF/WEBP container — only WebP is handled here (the shell owns
  // PNG/JPEG via its native decoder); leave everything else to fail cleanly.
  if not ((raw[0] = Ord('R')) and (raw[1] = Ord('I')) and (raw[2] = Ord('F')) and (raw[3] = Ord('F'))
      and (raw[8] = Ord('W')) and (raw[9] = Ord('E')) and (raw[10] = Ord('B')) and (raw[11] = Ord('P'))) then Exit;
  if not Tina4DecodeWebP(@raw[0], Length(raw), rgba, w, h) then Exit;
  if (w <= 0) or (h <= 0) or (Length(rgba) < w * h * 4) then Exit;
  n := w * h;
  SetLength(px, n);
  for i := 0 to n - 1 do
    px[i] := (Cardinal(rgba[i*4+3]) shl 24) or (Cardinal(rgba[i*4+0]) shl 16)
          or (Cardinal(rgba[i*4+1]) shl 8) or Cardinal(rgba[i*4+2]);
  if FBaseCount = Length(FBasePix) then
  begin
    SetLength(FBasePix, FBaseCount + 8); SetLength(FBaseW, FBaseCount + 8); SetLength(FBaseH, FBaseCount + 8);
  end;
  FBasePix[FBaseCount] := px; FBaseW[FBaseCount] := w; FBaseH[FBaseCount] := h;
  Result := WEBP_HANDLE_BASE + FBaseCount;
  FBaseSrc.AddObject(Src, TObject(PtrInt(Result)));
  Inc(FBaseCount);
end;

function TTina4Canvas.LoadImage(const Src: string): Integer;
begin
  // The base class can itself decode WebP (pure Pascal) from a file/data: URI.
  Result := DecodeToBaseStore(Src);
end;

function TTina4Canvas.ImageSize(Handle: Integer; out W, H: Single): Boolean;
var i: Integer;
begin
  W := 0; H := 0;
  if Handle >= WEBP_HANDLE_BASE then
  begin
    i := Handle - WEBP_HANDLE_BASE;
    Result := (i >= 0) and (i < FBaseCount);
    if Result then begin W := FBaseW[i]; H := FBaseH[i]; end;
    Exit;
  end;
  Result := False;
end;

destructor TTina4Canvas.Destroy;
begin
  FBaseSrc.Free;
  inherited Destroy;
end;

function TTina4Canvas.RegisterFont(const Family, Src: string): Boolean;
begin
  Result := False;   // backends that can load fonts override this
end;

procedure TTina4Canvas.DrawImage(Handle: Integer; X, Y, W, H: Single);
var i: Integer;
begin
  // Base-store (WebP) handles render through the DrawRGBA contract (virtual
  // dispatch → the shell's real blit, or a headless canvas's XObject embed).
  if Handle >= WEBP_HANDLE_BASE then
  begin
    i := Handle - WEBP_HANDLE_BASE;
    if (i >= 0) and (i < FBaseCount) and (Length(FBasePix[i]) > 0) then
      DrawRGBA(@FBasePix[i][0], FBaseW[i], FBaseH[i], X, Y, W, H);
  end;
end;

procedure TTina4Canvas.SaveState; begin end;
procedure TTina4Canvas.RestoreState; begin end;
procedure TTina4Canvas.Translate(DX, DY: Single); begin end;
procedure TTina4Canvas.Rotate(Degrees: Single); begin end;
procedure TTina4Canvas.Scale(SX, SY: Single); begin end;
procedure TTina4Canvas.Skew(AngleXDeg, AngleYDeg: Single); begin end;
procedure TTina4Canvas.TransformMatrix(A, B, C, D, E, F: Single); begin end;
procedure TTina4Canvas.ClipPolygon(const Pts: TTina4PointArray); begin end;
function TTina4Canvas.BeginLayer(X, Y, W, H, Pad: Single): Integer; begin Result := -1; end;
procedure TTina4Canvas.EndLayerFiltered(Handle: Integer; const FilterSpec, BlendMode, MaskSpec: string); begin end;
procedure TTina4Canvas.BackdropFilter(X, Y, W, H: Single; const FilterSpec: string); begin end;
procedure TTina4Canvas.EndLayer3D(Handle: Integer; const Corners: array of Single); begin end;
function TTina4Canvas.SupportsRGBA: Boolean; begin Result := False; end;
procedure TTina4Canvas.DrawRGBA(Buf: Pointer; BW, BH: Integer; DX, DY, DW, DH: Single); begin end;

end.
