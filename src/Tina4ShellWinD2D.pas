unit Tina4ShellWinD2D;

{ GPU-accelerated Windows canvas for the Tina4 native renderer (Direct2D).

  A drop-in alternative to Tina4ShellWin's GDI+ TWinCanvas: the same TTina4Canvas
  contract, but layer compositing, transforms, clipping, opacity and image blits
  run on the GPU through Direct2D (d2d1.dll) instead of GDI+ software rasterising.
  This is what closes the gap with macOS, whose canvas is GPU-backed CoreGraphics.

  Why hand-rolled COM: FPC 3.2.2 ships no Direct2D/D2D1 unit, so the few interfaces
  we need (ID2D1Factory, ID2D1(Hwnd)RenderTarget, ID2D1Bitmap, ID2D1PathGeometry +
  sink, ID2D1SolidColorBrush, gradient brushes/collections) are declared below as
  raw vtables (records of stdcall function pointers) — this avoids FPC's interface
  refcounting and calling-convention surprises and lets us lay out every vtable
  slot explicitly. We never call a struct-RETURNING D2D method (GetSize et al.),
  the classic x86 ABI trap; the few struct-by-VALUE *parameters* (points, sizes)
  are pushed on the stack normally.

  The render target draws straight to the HWND and presents itself in EndDraw, so
  the GDI+ back-buffer + StretchBlt dance in Tina4App's WPaint is bypassed on this
  path. Device-lost / resize recreate the target (D2DERR_RECREATE_TARGET).

  Coordinates are CSS pixels, top-left; colours are $AARRGGBB (alpha 0 == opaque,
  matching the GDI path's ArgbOf convention). Density is 1 (dpi forced to 96 so a
  DIP equals a pixel), so the whole viewport renders at full resolution — the GPU
  absorbs the fill cost the software path could not. }

{$mode delphi}{$H+}

interface

uses
  Windows, SysUtils, Math, Tina4RenderBackend;

type
  { ---- plain D2D structs (field order matches the Windows SDK) ---- }
  TD2DPoint = record x, y: Single; end;
  TD2DRectF = record left, top, right, bottom: Single; end;
  TD2DColorF = record r, g, b, a: Single; end;
  TD2DMatrix = record m11, m12, m21, m22, dx, dy: Single; end;
  TD2DSizeU = record w, h: LongWord; end;
  TD2DRoundedRect = record rect: TD2DRectF; rx, ry: Single; end;
  TD2DPixelFormat = record format, alphaMode: LongWord; end;
  TD2DBitmapProps = record pixelFormat: TD2DPixelFormat; dpiX, dpiY: Single; end;
  TD2DRenderTargetProps = record
    rtType: LongWord; pixelFormat: TD2DPixelFormat; dpiX, dpiY: Single;
    usage, minLevel: LongWord;
  end;
  TD2DHwndRTProps = record hwnd: HWND; pixelSize: TD2DSizeU; presentOptions: LongWord; end;
  TD2DGradientStop = record position: Single; color: TD2DColorF; end;
  TD2DLinearGradProps = record startPoint, endPoint: TD2DPoint; end;
  TD2DRadialGradProps = record center, originOffset: TD2DPoint; radiusX, radiusY: Single; end;
  TD2DLayerParams = record
    contentBounds: TD2DRectF;
    geometricMask: Pointer;
    maskAntialiasMode: LongWord;
    maskTransform: TD2DMatrix;
    opacity: Single;
    opacityBrush: Pointer;
    layerOptions: LongWord;
  end;

  { ---- COM vtables (exact slot order; unused slots are opaque Pointers) ---- }
  PComVtbl = ^TComVtbl;
  TComVtbl = array[0..255] of Pointer;   // for the generic Release helper

  PD2DFactoryVtbl = ^TD2DFactoryVtbl;
  TD2DFactoryVtbl = record
    QueryInterface, AddRef, Release: Pointer;              // IUnknown 0..2
    ReloadSystemMetrics, GetDesktopDpi,                    // 3,4
    CreateRectangleGeometry, CreateRoundedRectangleGeometry,
    CreateEllipseGeometry, CreateGeometryGroup,
    CreateTransformedGeometry: Pointer;                    // 5..9
    CreatePathGeometry: function(This: Pointer; out geom: Pointer): HResult; stdcall; // 10
    CreateStrokeStyle, CreateDrawingStateBlock,
    CreateWicBitmapRenderTarget: Pointer;                  // 11..13
    CreateHwndRenderTarget: function(This: Pointer;        // 14
      const rtProps: TD2DRenderTargetProps;
      const hwndProps: TD2DHwndRTProps; out rt: Pointer): HResult; stdcall;
    // (CreateDxgiSurfaceRenderTarget, CreateDCRenderTarget unused)
  end;

  PD2DRTVtbl = ^TD2DRTVtbl;
  TD2DRTVtbl = record
    QueryInterface, AddRef, Release, GetFactory: Pointer;  // 0..3
    CreateBitmap: function(This: Pointer; size: TD2DSizeU; srcData: Pointer;  // 4
      pitch: LongWord; const props: TD2DBitmapProps; out bitmap: Pointer): HResult; stdcall;
    CreateBitmapFromWicBitmap, CreateSharedBitmap, CreateBitmapBrush: Pointer; // 5..7
    CreateSolidColorBrush: function(This: Pointer; const color: TD2DColorF;   // 8
      brushProps: Pointer; out brush: Pointer): HResult; stdcall;
    CreateGradientStopCollection: function(This: Pointer; stops: Pointer;     // 9
      count, gamma, extendMode: LongWord; out coll: Pointer): HResult; stdcall;
    CreateLinearGradientBrush: function(This: Pointer; const props: TD2DLinearGradProps; // 10
      brushProps, coll: Pointer; out brush: Pointer): HResult; stdcall;
    CreateRadialGradientBrush: function(This: Pointer; const props: TD2DRadialGradProps; // 11
      brushProps, coll: Pointer; out brush: Pointer): HResult; stdcall;
    CreateCompatibleRenderTarget: Pointer;                 // 12
    CreateLayer: function(This: Pointer; size: Pointer; out layer: Pointer): HResult; stdcall; // 13
    CreateMesh: Pointer;                                   // 14
    // NOTE: a D2D1_POINT_2F parameter declared by VALUE in the C header is passed
    // by the MSVC x86 ABI as a hidden POINTER (verified by disassembly: BeginFigure
    // does `mov (arg),al`). A D2D1_SIZE_U (two ints, CreateBitmap) IS passed by
    // value — so only the all-float point aggregates take a pointer. We therefore
    // declare every by-value point param as a Pointer and pass its address.
    DrawLine: procedure(This: Pointer; p0, p1: Pointer; brush: Pointer;         // 15
      strokeWidth: Single; strokeStyle: Pointer); stdcall;
    DrawRectangle: Pointer;                                // 16
    FillRectangle: procedure(This: Pointer; const rect: TD2DRectF; brush: Pointer); stdcall; // 17
    DrawRoundedRectangle: Pointer;                         // 18
    FillRoundedRectangle: procedure(This: Pointer; const rr: TD2DRoundedRect; brush: Pointer); stdcall; // 19
    DrawEllipse, FillEllipse, DrawGeometry: Pointer;       // 20..22
    FillGeometry: procedure(This: Pointer; geom, brush, opacityBrush: Pointer); stdcall; // 23
    FillMesh, FillOpacityMask: Pointer;                    // 24,25
    DrawBitmap: procedure(This: Pointer; bitmap, destRect: Pointer;           // 26
      opacity: Single; interpMode: LongWord; srcRect: Pointer); stdcall;
    DrawTextA, DrawTextLayout, DrawGlyphRun: Pointer;      // 27..29
    SetTransform: procedure(This: Pointer; const m: TD2DMatrix); stdcall;     // 30
    GetTransform: Pointer;                                 // 31
    SetAntialiasMode: procedure(This: Pointer; mode: LongWord); stdcall;      // 32
    GetAntialiasMode, SetTextAntialiasMode, GetTextAntialiasMode,
    SetTextRenderingParams, GetTextRenderingParams, SetTags, GetTags: Pointer; // 33..39
    PushLayer: procedure(This: Pointer; const params: TD2DLayerParams; layer: Pointer); stdcall; // 40
    PopLayer: procedure(This: Pointer); stdcall;           // 41
    Flush, SaveDrawingState, RestoreDrawingState: Pointer; // 42..44
    PushAxisAlignedClip: procedure(This: Pointer; const clipRect: TD2DRectF; aaMode: LongWord); stdcall; // 45
    PopAxisAlignedClip: procedure(This: Pointer); stdcall; // 46
    Clear: procedure(This: Pointer; const color: TD2DColorF); stdcall;        // 47
    BeginDraw: procedure(This: Pointer); stdcall;          // 48
    EndDraw: function(This: Pointer; tag1, tag2: Pointer): HResult; stdcall;  // 49
    // (GetPixelFormat/SetDpi/GetDpi/GetSize/GetPixelSize/... unused — we never
    //  reach them; struct-returning ones are the reason we recreate on resize.)
  end;

  PD2DSinkVtbl = ^TD2DSinkVtbl;
  TD2DSinkVtbl = record
    QueryInterface, AddRef, Release, GetFactory: Pointer;  // 0..3
    SetFillMode: procedure(This: Pointer; mode: LongWord); stdcall;           // 4
    SetSegmentFlags: Pointer;                              // 5
    BeginFigure: procedure(This: Pointer; startPoint: Pointer; figureBegin: LongWord); stdcall; // 6 (point by pointer — see DrawLine note)
    AddLines: procedure(This: Pointer; points: Pointer; count: LongWord); stdcall; // 7
    AddBeziers: Pointer;                                   // 8
    EndFigure: procedure(This: Pointer; figureEnd: LongWord); stdcall;        // 9
    Close: function(This: Pointer): HResult; stdcall;      // 10
  end;

  PD2DPathVtbl = ^TD2DPathVtbl;
  TD2DPathVtbl = record
    QueryInterface, AddRef, Release, GetFactory: Pointer;  // 0..3
    GetBounds, GetWidenedBounds, StrokeContainsPoint, FillContainsPoint,
    CompareWithGeometry, Simplify, Tessellate, CombineWithGeometry, Outline,
    ComputeArea, ComputeLength, ComputePointAtLength, Widen: Pointer;         // 4..16
    Open: function(This: Pointer; out sink: Pointer): HResult; stdcall;       // 17
  end;

  PD2DBrushVtbl = ^TD2DBrushVtbl;
  TD2DBrushVtbl = record
    QueryInterface, AddRef, Release, GetFactory: Pointer;  // 0..3
    SetOpacity, SetTransform, GetOpacity, GetTransform: Pointer;              // 4..7 (ID2D1Brush)
    SetColor: procedure(This: Pointer; const color: TD2DColorF); stdcall;     // 8 (ID2D1SolidColorBrush)
  end;

  { one cached GPU bitmap for a DrawRGBA source buffer }
  TD2DCachedBmp = record
    Hash: Cardinal; W, H: Integer; Bmp: Pointer;
  end;

  { clip-stack entry. ckAAClip = a PushAxisAlignedClip. ckPoly = a polygon clip-path:
    a bbox PushAxisAlignedClip plus the polygon points (DEVICE space), so a solid
    fill inside it is scan-converted to FillRectangle spans — the star shape. We do
    NOT use a geometric-mask layer or FillGeometry: rendering an ID2D1Geometry in
    this hand-rolled binding corrupts the composited frame (it shrank the whole
    already-painted scene under the sparks' tiny scale). FillRectangle is solid. }
  TD2DClipKind = (ckAAClip, ckPoly);
  TD2DClip = record Kind: TD2DClipKind; Pts, PrevPts: TTina4PointArray; end;

  { save-state marker: the transform + clip depth to roll back to }
  TD2DSave = record M: TD2DMatrix; ClipDepth: Integer; end;

  TD2DCanvas = class(TTina4Canvas)
  private
    FHwnd: HWND;
    FFactory: Pointer;
    FRT: Pointer;                 // ID2D1HwndRenderTarget (used as ID2D1RenderTarget)
    FBrush: Pointer;              // reusable solid-colour brush
    FRtW, FRtH: Integer;          // render-target pixel size
    FAvailable: Boolean;
    FInFrame: Boolean;
    FPresentImmediately: Boolean; // true = direct present (benchmark throughput);
                                  // false = DWM-composited vsync (robust, default)
    FM: TD2DMatrix;               // current transform (CTM)
    FClips: array of TD2DClip;    // active D2D clip stack
    FNClips: Integer;
    FSaves: array of TD2DSave;    // save-state markers
    FNSaves: Integer;
    FCache: array of TD2DCachedBmp;  // DrawRGBA bitmap cache (owned by FRT)
    FNCache: Integer;
    FActivePolyPts: TTina4PointArray;  // DEVICE-space points of innermost clip-path (or nil)
    FMeasDC: HDC;                 // GDI DC for MeasureText (text glyphs are a stub)
    function CreateTargetFor(w, h: Integer): Boolean;
    procedure ReleaseTarget;
    procedure FreeCache;
    procedure PushAAClip;
    procedure PopClip;
    procedure FillPolySpans(const Pts: TTina4PointArray);  // scanline fill via FillRectangle
    function BitmapFor(Buf: Pointer; BW, BH: Integer): Pointer;
    function MakeGeometry(const Pts: TTina4PointArray): Pointer;
  public
    { PresentImmediately: True presents directly (uncapped — for the benchmark);
      False (default) uses the normal DWM-composited vsync present, which is
      robust while the window is moved/occluded and keeps the on-screen content
      in sync with DWM (so tools that read the window via DWM see live frames). }
    constructor Create(AHwnd: HWND; PresentImmediately: Boolean = False);
    destructor Destroy; override;
    property Available: Boolean read FAvailable;
    property RtW: Integer read FRtW;     // current render-target pixel size
    property RtH: Integer read FRtH;
    { Begin a frame: BeginDraw, reset transform/clips, clear to white. }
    procedure BeginFrame;
    { End a frame: EndDraw + present. Returns False on device-lost (caller should
      Recreate and repaint). }
    function EndFrame: Boolean;
    { Rebuild the render target. AW/AH give the new pixel size explicitly (resize);
      0,0 reads the window's current client rect (device-lost recovery). }
    procedure Recreate(AW: Integer = 0; AH: Integer = 0);

    procedure FillRect(X, Y, W, H: Single; Color: TTina4Color); override;
    procedure StrokeRect(X, Y, W, H, Thickness: Single; Color: TTina4Color); override;
    procedure FillRoundRect(X, Y, W, H, Radius: Single; Color: TTina4Color); override;
    procedure FillLinearGradient(X, Y, W, H, Radius, AngleDeg: Single;
      const Colors: array of TTina4Color; const Positions: array of Single); override;
    procedure FillRadialGradient(X, Y, W, H, Radius: Single;
      const Colors: array of TTina4Color; const Positions: array of Single); override;
    procedure DrawLine(X1, Y1, X2, Y2, Thickness: Single; Color: TTina4Color); override;
    procedure DrawText(X, Y: Single; const Text: string; FontSize: Single;
      Styles: TTina4FontStyles; Color: TTina4Color); override;
    function MeasureText(const Text: string; FontSize: Single;
      Styles: TTina4FontStyles): TTina4TextMetrics; override;
    procedure SetClip(X, Y, W, H: Single); override;
    procedure ClipPolygon(const Pts: TTina4PointArray); override;
    procedure ClipRoundRect(X, Y, W, H, Radius: Single); override;
    procedure ClearClip; override;
    procedure SaveState; override;
    procedure RestoreState; override;
    procedure Translate(DX, DY: Single); override;
    procedure Scale(SX, SY: Single); override;
    procedure Rotate(Degrees: Single); override;
    procedure Skew(AngleXDeg, AngleYDeg: Single); override;
    procedure TransformMatrix(A, B, C, D, E, F: Single); override;
    function SupportsRGBA: Boolean; override;
    procedure DrawRGBA(Buf: Pointer; BW, BH: Integer; DX, DY, DW, DH: Single); override;
  end;

implementation

const
  D2DERR_RECREATE_TARGET = HResult($8899000C);

  { D2D1_FACTORY_TYPE_SINGLE_THREADED } D2D1_FACTORY_SINGLE = 0;
  { DXGI_FORMAT_B8G8R8A8_UNORM }        DXGI_B8G8R8A8 = 87;
  { D2D1_ALPHA_MODE_PREMULTIPLIED }     ALPHA_PREMULT = 1;
  { D2D1_PRESENT_OPTIONS_NONE (DWM-composited vsync) / _IMMEDIATELY (direct) }
  PRESENT_NONE = 0; PRESENT_IMMEDIATELY = 2;
  { D2D1_BITMAP_INTERPOLATION_MODE_LINEAR } INTERP_LINEAR = 1;
  { D2D1_ANTIALIAS_MODE_PER_PRIMITIVE / _ALIASED } AA_PER_PRIMITIVE = 0; AA_ALIASED = 1;
  { D2D1_FIGURE_BEGIN_FILLED / D2D1_FIGURE_END_CLOSED } FIGURE_FILLED = 0; FIGURE_CLOSED = 1;
  { D2D1_FILL_MODE_WINDING } FILL_WINDING = 1;
  { D2D1_EXTEND_MODE_CLAMP / D2D1_GAMMA_2_2 } EXTEND_CLAMP = 0; GAMMA_22 = 0;

  CACHE_MAX = 32;

  IID_ID2D1Factory: TGUID = '{06152247-6F50-465A-9245-118BFD3B6007}';

function D2D1CreateFactory(factoryType: LongWord; const riid: TGUID;
  pFactoryOptions: Pointer; out ppIFactory: Pointer): HResult; stdcall;
  external 'd2d1.dll' name 'D2D1CreateFactory';

{ ---- vtable call helpers (explicit so the slot usage is obvious) ---- }
function RT(obj: Pointer): PD2DRTVtbl; inline; begin RT := PD2DRTVtbl(PPointer(obj)^); end;
function FC(obj: Pointer): PD2DFactoryVtbl; inline; begin FC := PD2DFactoryVtbl(PPointer(obj)^); end;

{ Generic COM Release (slot 2 in every IUnknown vtable). }
function ComRelease(obj: Pointer): LongWord;
type TRel = function(This: Pointer): LongWord; stdcall;
begin
  if obj = nil then Exit(0);
  ComRelease := TRel(PComVtbl(PPointer(obj)^)^[2])(obj);
end;

{ $AARRGGBB -> straight D2D1_COLOR_F. Alpha 0 is treated as opaque (the engine's
  "unset" convention, matching the GDI path's ArgbOf). }
function ColorF(C: TTina4Color): TD2DColorF;
var a: Cardinal;
begin
  a := (C shr 24) and $FF;
  if a = 0 then a := $FF;
  ColorF.a := a / 255;
  ColorF.r := ((C shr 16) and $FF) / 255;
  ColorF.g := ((C shr 8) and $FF) / 255;
  ColorF.b := (C and $FF) / 255;
end;

function RectF(l, t, r, b: Single): TD2DRectF; inline;
begin RectF.left := l; RectF.top := t; RectF.right := r; RectF.bottom := b; end;

function Identity: TD2DMatrix; inline;
begin
  Identity.m11 := 1; Identity.m12 := 0; Identity.m21 := 0; Identity.m22 := 1;
  Identity.dx := 0; Identity.dy := 0;
end;

{ Affine product A*B (row-vector convention): a point transforms as p' = p*A*B, so
  A is applied first — matching GDI's MWT_LEFTMULTIPLY (CSS child-first nesting). }
function MatMul(const A, B: TD2DMatrix): TD2DMatrix;
begin
  MatMul.m11 := A.m11 * B.m11 + A.m12 * B.m21;
  MatMul.m12 := A.m11 * B.m12 + A.m12 * B.m22;
  MatMul.m21 := A.m21 * B.m11 + A.m22 * B.m21;
  MatMul.m22 := A.m21 * B.m12 + A.m22 * B.m22;
  MatMul.dx  := A.dx * B.m11 + A.dy * B.m21 + B.dx;
  MatMul.dy  := A.dx * B.m12 + A.dy * B.m22 + B.dy;
end;

{ Sparse FNV-1a over up to 64 pixels — tell a static image from a changed one
  cheaply (same idea as the GDI scale cache). }
function BufHash(Buf: Pointer; BW, BH: Integer): Cardinal;
var n, stride, idx, i: Integer; h: Cardinal;
begin
  n := BW * BH; h := 2166136261;
  stride := n div 64; if stride < 1 then stride := 1;
  idx := 0; i := 0;
  while (idx < n) and (i < 64) do
  begin
    h := (h xor PCardinal(PByte(Buf) + idx * 4)^) * 16777619;
    Inc(idx, stride); Inc(i);
  end;
  BufHash := h xor Cardinal(BW) xor (Cardinal(BH) shl 16);
end;

constructor TD2DCanvas.Create(AHwnd: HWND; PresentImmediately: Boolean = False);
var r: HResult;
begin
  inherited Create;
  FHwnd := AHwnd;
  FPresentImmediately := PresentImmediately;
  FM := Identity;
  FMeasDC := CreateCompatibleDC(0);
  SetBkMode(FMeasDC, TRANSPARENT);
  r := D2D1CreateFactory(D2D1_FACTORY_SINGLE, IID_ID2D1Factory, nil, FFactory);
  if (r <> S_OK) or (FFactory = nil) then begin FAvailable := False; Exit; end;
  FAvailable := CreateTargetFor(0, 0);
end;

destructor TD2DCanvas.Destroy;
begin
  ReleaseTarget;
  if FFactory <> nil then begin ComRelease(FFactory); FFactory := nil; end;
  if FMeasDC <> 0 then DeleteDC(FMeasDC);
  inherited Destroy;
end;

function TD2DCanvas.CreateTargetFor(w, h: Integer): Boolean;
var rc: TRect; rtp: TD2DRenderTargetProps; hp: TD2DHwndRTProps; r: HResult;
begin
  Result := False;
  if (w <= 0) or (h <= 0) then
  begin
    GetClientRect(FHwnd, rc);
    w := rc.Right - rc.Left; h := rc.Bottom - rc.Top;
    if w <= 0 then w := 1; if h <= 0 then h := 1;
  end;
  FillChar(rtp, SizeOf(rtp), 0);     // DEFAULT type, DPI 96 (dpi 0 => default), usage/level 0
  rtp.pixelFormat.format := DXGI_B8G8R8A8;
  rtp.pixelFormat.alphaMode := ALPHA_PREMULT;
  hp.hwnd := FHwnd;
  hp.pixelSize.w := w; hp.pixelSize.h := h;
  if FPresentImmediately then hp.presentOptions := PRESENT_IMMEDIATELY
  else hp.presentOptions := PRESENT_NONE;
  r := FC(FFactory)^.CreateHwndRenderTarget(FFactory, rtp, hp, FRT);
  if (r <> S_OK) or (FRT = nil) then Exit;
  FRtW := w; FRtH := h;
  // one reusable solid brush
  if RT(FRT)^.CreateSolidColorBrush(FRT, ColorF($FF000000), nil, FBrush) <> S_OK then
  begin ComRelease(FRT); FRT := nil; Exit; end;
  Result := True;
end;

procedure TD2DCanvas.FreeCache;
var i: Integer;
begin
  for i := 0 to FNCache - 1 do
    if FCache[i].Bmp <> nil then ComRelease(FCache[i].Bmp);
  FNCache := 0;
  SetLength(FCache, 0);
end;

procedure TD2DCanvas.ReleaseTarget;
begin
  FreeCache;   // bitmaps are owned by the target — drop them first
  FActivePolyPts := nil;
  if FBrush <> nil then begin ComRelease(FBrush); FBrush := nil; end;
  if FRT <> nil then begin ComRelease(FRT); FRT := nil; end;
end;

procedure TD2DCanvas.Recreate(AW: Integer = 0; AH: Integer = 0);
begin
  ReleaseTarget;
  FAvailable := CreateTargetFor(AW, AH);
  FInFrame := False;
end;

procedure TD2DCanvas.BeginFrame;
begin
  if (FRT = nil) and FAvailable then Recreate;
  if FRT = nil then Exit;
  FNClips := 0; FNSaves := 0; FActivePolyPts := nil; FM := Identity;
  RT(FRT)^.BeginDraw(FRT);
  RT(FRT)^.SetTransform(FRT, FM);
  RT(FRT)^.Clear(FRT, ColorF($FFFFFFFF));
  FInFrame := True;
end;

function TD2DCanvas.EndFrame: Boolean;
var r: HResult; i: Integer;
begin
  Result := True;
  if (FRT = nil) or (not FInFrame) then Exit;
  // balance any clips the frame left open (defensive)
  for i := FNClips - 1 downto 0 do
  begin
    RT(FRT)^.PopAxisAlignedClip(FRT);
    FClips[i].Pts := nil; FClips[i].PrevPts := nil;
  end;
  FNClips := 0; FActivePolyPts := nil;
  r := RT(FRT)^.EndDraw(FRT, nil, nil);
  FInFrame := False;
  if r = D2DERR_RECREATE_TARGET then begin ReleaseTarget; Result := False; end;
end;

{ ---- fills ------------------------------------------------------------- }

procedure TD2DCanvas.FillRect(X, Y, W, H: Single; Color: TTina4Color);
begin
  if (FRT = nil) or (W <= 0) or (H <= 0) then Exit;
  PD2DBrushVtbl(PPointer(FBrush)^)^.SetColor(FBrush, ColorF(Color));
  // Inside a clip-path polygon, fill the polygon itself (the star) rather than the
  // rect — the rect is the element box the polygon clips, so this reproduces the
  // CSS clip-path. Scan-fill the DEVICE-space polygon under an identity transform.
  if FActivePolyPts <> nil then
  begin
    RT(FRT)^.SetTransform(FRT, Identity);
    FillPolySpans(FActivePolyPts);
    RT(FRT)^.SetTransform(FRT, FM);
  end
  else
    RT(FRT)^.FillRectangle(FRT, RectF(X, Y, X + W, Y + H), FBrush);
end;

procedure TD2DCanvas.StrokeRect(X, Y, W, H, Thickness: Single; Color: TTina4Color);
var t: Single;
begin
  if (FRT = nil) or (W <= 0) or (H <= 0) then Exit;
  t := Thickness; if t < 1 then t := 1;
  PD2DBrushVtbl(PPointer(FBrush)^)^.SetColor(FBrush, ColorF(Color));
  // four thin filled edges (avoids declaring DrawRectangle's stroke-style slot)
  RT(FRT)^.FillRectangle(FRT, RectF(X, Y, X + W, Y + t), FBrush);             // top
  RT(FRT)^.FillRectangle(FRT, RectF(X, Y + H - t, X + W, Y + H), FBrush);     // bottom
  RT(FRT)^.FillRectangle(FRT, RectF(X, Y, X + t, Y + H), FBrush);             // left
  RT(FRT)^.FillRectangle(FRT, RectF(X + W - t, Y, X + W, Y + H), FBrush);     // right
end;

procedure TD2DCanvas.FillRoundRect(X, Y, W, H, Radius: Single; Color: TTina4Color);
var rr: TD2DRoundedRect; r: Single;
begin
  if (FRT = nil) or (W <= 0) or (H <= 0) then Exit;
  r := Radius; if r > W / 2 then r := W / 2; if r > H / 2 then r := H / 2; if r < 0 then r := 0;
  PD2DBrushVtbl(PPointer(FBrush)^)^.SetColor(FBrush, ColorF(Color));
  if r <= 0 then
  begin RT(FRT)^.FillRectangle(FRT, RectF(X, Y, X + W, Y + H), FBrush); Exit; end;
  rr.rect := RectF(X, Y, X + W, Y + H); rr.rx := r; rr.ry := r;
  RT(FRT)^.FillRoundedRectangle(FRT, rr, FBrush);
end;

{ Build the 0..1 stop locations (explicit position wins, else evenly spread,
  clamped monotonic) — the same rule the other shells use. }
procedure BuildStops(const Colors: array of TTina4Color; const Positions: array of Single;
  out stops: array of TD2DGradientStop);
var i, n: Integer; loc: Single;
begin
  n := Length(Colors);
  for i := 0 to n - 1 do
  begin
    if (i < Length(Positions)) and (Positions[i] >= 0) then loc := Positions[i]
    else if n > 1 then loc := i / (n - 1) else loc := 0;
    if (i > 0) and (loc < stops[i - 1].position) then loc := stops[i - 1].position;
    stops[i].position := loc;
    stops[i].color := ColorF(Colors[i]);
  end;
  if n > 0 then begin stops[0].position := 0; stops[n - 1].position := 1; end;
end;

procedure TD2DCanvas.FillLinearGradient(X, Y, W, H, Radius, AngleDeg: Single;
  const Colors: array of TTina4Color; const Positions: array of Single);
var
  stops: array of TD2DGradientStop; coll, br: Pointer; n: Integer;
  props: TD2DLinearGradProps; rr: TD2DRoundedRect;
  a, dxu, dyu, gl, cx, cy: Single;
begin
  n := Length(Colors);
  if (FRT = nil) or (n = 0) or (W <= 0) or (H <= 0) then Exit;
  SetLength(stops, n); BuildStops(Colors, Positions, stops);
  coll := nil;
  if RT(FRT)^.CreateGradientStopCollection(FRT, @stops[0], n, GAMMA_22, EXTEND_CLAMP, coll) <> S_OK then Exit;
  a := AngleDeg * Pi / 180; dxu := Sin(a); dyu := -Cos(a);
  gl := Abs(W * Sin(a)) + Abs(H * Cos(a)); if gl <= 0 then gl := 1;
  cx := X + W / 2; cy := Y + H / 2;
  props.startPoint.x := cx - dxu * gl / 2; props.startPoint.y := cy - dyu * gl / 2;
  props.endPoint.x := cx + dxu * gl / 2;   props.endPoint.y := cy + dyu * gl / 2;
  br := nil;
  if RT(FRT)^.CreateLinearGradientBrush(FRT, props, nil, coll, br) = S_OK then
  begin
    if Radius > 0 then
    begin
      rr.rect := RectF(X, Y, X + W, Y + H);
      rr.rx := Radius; rr.ry := Radius;
      if rr.rx > W / 2 then rr.rx := W / 2; if rr.ry > H / 2 then rr.ry := H / 2;
      RT(FRT)^.FillRoundedRectangle(FRT, rr, br);
    end
    else RT(FRT)^.FillRectangle(FRT, RectF(X, Y, X + W, Y + H), br);
    ComRelease(br);
  end;
  ComRelease(coll);
end;

procedure TD2DCanvas.FillRadialGradient(X, Y, W, H, Radius: Single;
  const Colors: array of TTina4Color; const Positions: array of Single);
var
  stops: array of TD2DGradientStop; coll, br: Pointer; n: Integer;
  props: TD2DRadialGradProps; rr: TD2DRoundedRect; rad: Single;
begin
  n := Length(Colors);
  if (FRT = nil) or (n = 0) or (W <= 0) or (H <= 0) then Exit;
  SetLength(stops, n); BuildStops(Colors, Positions, stops);
  coll := nil;
  if RT(FRT)^.CreateGradientStopCollection(FRT, @stops[0], n, GAMMA_22, EXTEND_CLAMP, coll) <> S_OK then Exit;
  rad := Sqrt((W / 2) * (W / 2) + (H / 2) * (H / 2)); if rad <= 0 then rad := 1;
  props.center.x := X + W / 2; props.center.y := Y + H / 2;
  props.originOffset.x := 0; props.originOffset.y := 0;
  props.radiusX := rad; props.radiusY := rad;
  br := nil;
  if RT(FRT)^.CreateRadialGradientBrush(FRT, props, nil, coll, br) = S_OK then
  begin
    if Radius > 0 then
    begin
      rr.rect := RectF(X, Y, X + W, Y + H);
      rr.rx := Radius; rr.ry := Radius;
      if rr.rx > W / 2 then rr.rx := W / 2; if rr.ry > H / 2 then rr.ry := H / 2;
      RT(FRT)^.FillRoundedRectangle(FRT, rr, br);
    end
    else RT(FRT)^.FillRectangle(FRT, RectF(X, Y, X + W, Y + H), br);
    ComRelease(br);
  end;
  ComRelease(coll);
end;

procedure TD2DCanvas.DrawLine(X1, Y1, X2, Y2, Thickness: Single; Color: TTina4Color);
var t: Single; p0, p1: TD2DPoint;
begin
  if FRT = nil then Exit;
  t := Thickness; if t < 1 then t := 1;
  p0.x := X1; p0.y := Y1; p1.x := X2; p1.y := Y2;
  PD2DBrushVtbl(PPointer(FBrush)^)^.SetColor(FBrush, ColorF(Color));
  RT(FRT)^.DrawLine(FRT, @p0, @p1, FBrush, t, nil);
end;

{ ---- text: glyph rendering is a documented gap (DirectWrite TODO); the hero has
  no text. MeasureText still works (via a GDI DC) so layout stays correct for any
  incidental text. ---- }
procedure TD2DCanvas.DrawText(X, Y: Single; const Text: string; FontSize: Single;
  Styles: TTina4FontStyles; Color: TTina4Color);
begin
  // no-op: DirectWrite backend not implemented in this prototype
end;

function TD2DCanvas.MeasureText(const Text: string; FontSize: Single;
  Styles: TTina4FontStyles): TTina4TextMetrics;
var lf: LOGFONTW; f, old: HGDIOBJ; w: WideString; sz: SIZE; tm: TEXTMETRICW;
begin
  FillChar(Result, SizeOf(Result), 0);
  FillChar(lf, SizeOf(lf), 0);
  lf.lfHeight := -Round(FontSize);
  if FontWeight >= 100 then lf.lfWeight := FontWeight else lf.lfWeight := FW_NORMAL;
  if (tfsBold in Styles) and (lf.lfWeight < FW_BOLD) then lf.lfWeight := FW_BOLD;
  if tfsItalic in Styles then lf.lfItalic := 1;
  lf.lfCharSet := DEFAULT_CHARSET;
  f := CreateFontIndirectW(@lf);
  old := SelectObject(FMeasDC, f);
  w := UTF8Decode(Text);
  sz.cx := 0; sz.cy := 0;
  if w <> '' then GetTextExtentPoint32W(FMeasDC, PWideChar(w), Length(w), sz);
  if LetterSpacing <> 0 then sz.cx := sz.cx + Round(LetterSpacing) * Length(w);
  GetTextMetricsW(FMeasDC, @tm);
  SelectObject(FMeasDC, old); DeleteObject(f);
  Result.Width := sz.cx;
  Result.Ascent := tm.tmAscent;
  Result.Descent := tm.tmDescent;
  Result.LineHeight := tm.tmHeight;
end;

{ ---- clipping + transform stack --------------------------------------- }

procedure TD2DCanvas.PushAAClip;
begin
  if FNClips = Length(FClips) then SetLength(FClips, FNClips + 8);
  FClips[FNClips].Kind := ckAAClip; FClips[FNClips].Pts := nil; FClips[FNClips].PrevPts := nil;
  Inc(FNClips);
end;

procedure TD2DCanvas.PopClip;
begin
  if FNClips <= 0 then Exit;
  Dec(FNClips);
  RT(FRT)^.PopAxisAlignedClip(FRT);   // both kinds pushed a PushAxisAlignedClip
  if FClips[FNClips].Kind = ckPoly then
  begin
    FActivePolyPts := FClips[FNClips].PrevPts;
    FClips[FNClips].Pts := nil; FClips[FNClips].PrevPts := nil;
  end;
end;

{ Scan-convert a polygon (DEVICE-space points) to FillRectangle spans with the
  current transform at identity. Even-odd rule — the hero star is a simple
  (non-self-intersecting) octagon, so pairs of crossings fill correctly. }
procedure TD2DCanvas.FillPolySpans(const Pts: TTina4PointArray);
var
  n, i, j, y, y0, y1, cnt, k: Integer;
  fMinY, fMaxY, yc, xi, t: Single;
  xs: array of Single; a, b: TTina4Point;
begin
  n := Length(Pts);
  if n < 3 then Exit;
  fMinY := Pts[0].Y; fMaxY := fMinY;
  for i := 1 to n - 1 do
  begin
    if Pts[i].Y < fMinY then fMinY := Pts[i].Y;
    if Pts[i].Y > fMaxY then fMaxY := Pts[i].Y;
  end;
  y0 := Floor(fMinY); y1 := Ceil(fMaxY);
  SetLength(xs, n);
  for y := y0 to y1 do
  begin
    yc := y + 0.5; cnt := 0;
    for i := 0 to n - 1 do
    begin
      a := Pts[i]; b := Pts[(i + 1) mod n];
      if a.Y = b.Y then Continue;
      if ((a.Y <= yc) and (b.Y > yc)) or ((b.Y <= yc) and (a.Y > yc)) then
      begin
        xi := a.X + (yc - a.Y) / (b.Y - a.Y) * (b.X - a.X);
        xs[cnt] := xi; Inc(cnt);
      end;
    end;
    // insertion sort the crossings
    for i := 1 to cnt - 1 do
    begin
      t := xs[i]; j := i - 1;
      while (j >= 0) and (xs[j] > t) do begin xs[j + 1] := xs[j]; Dec(j); end;
      xs[j + 1] := t;
    end;
    k := 0;
    while k + 1 < cnt do
    begin
      if xs[k + 1] > xs[k] then
        RT(FRT)^.FillRectangle(FRT, RectF(xs[k], y, xs[k + 1], y + 1), FBrush);
      Inc(k, 2);
    end;
  end;
end;

procedure TD2DCanvas.SetClip(X, Y, W, H: Single);
begin
  if FRT = nil then Exit;
  RT(FRT)^.PushAxisAlignedClip(FRT, RectF(X, Y, X + W, Y + H), AA_ALIASED);
  PushAAClip;
end;

procedure TD2DCanvas.ClearClip;
begin
  if FRT = nil then Exit;
  PopClip;
end;

{ Build a closed-figure path geometry in user space from a polygon. }
function TD2DCanvas.MakeGeometry(const Pts: TTina4PointArray): Pointer;
var geom, sink: Pointer; i, n: Integer; p0: TD2DPoint; rest: array of TD2DPoint;
begin
  Result := nil;
  n := Length(Pts);
  if (FFactory = nil) or (n < 3) then Exit;
  if FC(FFactory)^.CreatePathGeometry(FFactory, geom) <> S_OK then Exit;
  sink := nil;
  if PD2DPathVtbl(PPointer(geom)^)^.Open(geom, sink) <> S_OK then begin ComRelease(geom); Exit; end;
  PD2DSinkVtbl(PPointer(sink)^)^.SetFillMode(sink, FILL_WINDING);
  p0.x := Pts[0].X; p0.y := Pts[0].Y;
  PD2DSinkVtbl(PPointer(sink)^)^.BeginFigure(sink, @p0, FIGURE_FILLED);
  SetLength(rest, n - 1);
  for i := 1 to n - 1 do begin rest[i - 1].x := Pts[i].X; rest[i - 1].y := Pts[i].Y; end;
  PD2DSinkVtbl(PPointer(sink)^)^.AddLines(sink, @rest[0], n - 1);
  PD2DSinkVtbl(PPointer(sink)^)^.EndFigure(sink, FIGURE_CLOSED);
  PD2DSinkVtbl(PPointer(sink)^)^.Close(sink);
  ComRelease(sink);
  Result := geom;
end;

{ Push a geometry as a clip layer. The geometry is in user space; D2D applies the
  current render-target transform to it (maskTransform identity), so clip-path
  tracks transform:scale()/rotate() natively — e.g. the hero's sparkle stars. }
procedure TD2DCanvas.ClipPolygon(const Pts: TTina4PointArray);
var i, n: Integer; minx, miny, maxx, maxy, dx, dy: Single; dev: TTina4PointArray;
begin
  if (FRT = nil) or (Length(Pts) < 3) then Exit;
  // Clip-path. Rendering an ID2D1Geometry (PushLayer mask OR FillGeometry) corrupts
  // the frame in this binding, so remember the polygon as DEVICE-space points and
  // scan-fill it in FillRect, and push a safe axis-aligned bbox clip for any other
  // drawing inside the clip-path.
  n := Length(Pts);
  SetLength(dev, n);
  minx := 1e30; maxx := -1e30; miny := 1e30; maxy := -1e30;
  for i := 0 to n - 1 do
  begin
    dev[i].X := Pts[i].X * FM.m11 + Pts[i].Y * FM.m21 + FM.dx;
    dev[i].Y := Pts[i].X * FM.m12 + Pts[i].Y * FM.m22 + FM.dy;
    dx := dev[i].X; dy := dev[i].Y;
    if dx < minx then minx := dx; if dx > maxx then maxx := dx;
    if dy < miny then miny := dy; if dy > maxy then maxy := dy;
  end;
  RT(FRT)^.SetTransform(FRT, Identity);    // bbox is in device space
  RT(FRT)^.PushAxisAlignedClip(FRT, RectF(minx, miny, maxx, maxy), AA_PER_PRIMITIVE);
  RT(FRT)^.SetTransform(FRT, FM);
  if FNClips = Length(FClips) then SetLength(FClips, FNClips + 8);
  FClips[FNClips].Kind := ckPoly; FClips[FNClips].Pts := dev;
  FClips[FNClips].PrevPts := FActivePolyPts; Inc(FNClips);
  FActivePolyPts := dev;
end;

procedure TD2DCanvas.ClipRoundRect(X, Y, W, H, Radius: Single);
begin
  if FRT = nil then Exit;
  if Radius <= 0 then begin SetClip(X, Y, W, H); Exit; end;
  ClipPolygon(RoundRectPolygon(X, Y, W, H, Radius));
end;

procedure TD2DCanvas.SaveState;
begin
  if FRT = nil then Exit;
  if FNSaves = Length(FSaves) then SetLength(FSaves, FNSaves + 8);
  FSaves[FNSaves].M := FM; FSaves[FNSaves].ClipDepth := FNClips; Inc(FNSaves);
end;

procedure TD2DCanvas.RestoreState;
begin
  if (FRT = nil) or (FNSaves <= 0) then Exit;
  Dec(FNSaves);
  while FNClips > FSaves[FNSaves].ClipDepth do PopClip;
  FM := FSaves[FNSaves].M;
  RT(FRT)^.SetTransform(FRT, FM);
end;

procedure TD2DCanvas.Translate(DX, DY: Single);
var t: TD2DMatrix;
begin
  if FRT = nil then Exit;
  t := Identity; t.dx := DX; t.dy := DY;
  FM := MatMul(t, FM); RT(FRT)^.SetTransform(FRT, FM);
end;

procedure TD2DCanvas.Scale(SX, SY: Single);
var t: TD2DMatrix;
begin
  if FRT = nil then Exit;
  t := Identity; t.m11 := SX; t.m22 := SY;
  FM := MatMul(t, FM); RT(FRT)^.SetTransform(FRT, FM);
end;

procedure TD2DCanvas.Rotate(Degrees: Single);
var t: TD2DMatrix; a, c, s: Single;
begin
  if FRT = nil then Exit;
  a := Degrees * Pi / 180; c := Cos(a); s := Sin(a);
  t := Identity; t.m11 := c; t.m12 := s; t.m21 := -s; t.m22 := c;
  FM := MatMul(t, FM); RT(FRT)^.SetTransform(FRT, FM);
end;

procedure TD2DCanvas.Skew(AngleXDeg, AngleYDeg: Single);
var t: TD2DMatrix;
begin
  if FRT = nil then Exit;
  t := Identity;
  t.m21 := Sin(AngleXDeg * Pi / 180) / Cos(AngleXDeg * Pi / 180);
  t.m12 := Sin(AngleYDeg * Pi / 180) / Cos(AngleYDeg * Pi / 180);
  FM := MatMul(t, FM); RT(FRT)^.SetTransform(FRT, FM);
end;

procedure TD2DCanvas.TransformMatrix(A, B, C, D, E, F: Single);
var t: TD2DMatrix;
begin
  if FRT = nil then Exit;
  t.m11 := A; t.m12 := B; t.m21 := C; t.m22 := D; t.dx := E; t.dy := F;
  FM := MatMul(t, FM); RT(FRT)^.SetTransform(FRT, FM);
end;

{ ---- images (DrawRGBA) ------------------------------------------------- }

function TD2DCanvas.SupportsRGBA: Boolean;
begin
  Result := True;
end;

{ Find or build a GPU bitmap for this source buffer. The webp parallax layers are
  static each frame, so a content-hash hit means a straight DrawBitmap with no
  re-upload; the GPU does the per-frame scale under SetTransform. Pixels arrive as
  straight $AARRGGBB and are premultiplied once on upload (D2D RTs don't accept a
  straight-alpha bitmap). Bitmaps are owned by FRT and dropped when it is rebuilt. }
function TD2DCanvas.BitmapFor(Buf: Pointer; BW, BH: Integer): Pointer;
var
  hash: Cardinal; i, n, slot: Integer; src, dst: PCardinal;
  pm: array of Cardinal; a, r, g, b: Cardinal; sz: TD2DSizeU; bp: TD2DBitmapProps; bmp: Pointer;
begin
  Result := nil;
  if (FRT = nil) or (Buf = nil) or (BW <= 0) or (BH <= 0) then Exit;
  hash := BufHash(Buf, BW, BH);
  for i := 0 to FNCache - 1 do
    if (FCache[i].Hash = hash) and (FCache[i].W = BW) and (FCache[i].H = BH) then
      Exit(FCache[i].Bmp);

  n := BW * BH;
  SetLength(pm, n);
  src := PCardinal(Buf); dst := @pm[0];
  for i := 0 to n - 1 do
  begin
    // memory is B,G,R,A (little-endian $AARRGGBB) -> premultiply each channel by A
    a := (src[i] shr 24) and $FF;
    if a = 0 then dst[i] := 0
    else if a = $FF then dst[i] := src[i]
    else
    begin
      r := (((src[i] shr 16) and $FF) * a + 127) div 255;
      g := (((src[i] shr 8) and $FF) * a + 127) div 255;
      b := ((src[i] and $FF) * a + 127) div 255;
      dst[i] := (a shl 24) or (r shl 16) or (g shl 8) or b;
    end;
  end;

  sz.w := BW; sz.h := BH;
  bp.pixelFormat.format := DXGI_B8G8R8A8;
  bp.pixelFormat.alphaMode := ALPHA_PREMULT;
  bp.dpiX := 96; bp.dpiY := 96;
  if RT(FRT)^.CreateBitmap(FRT, sz, @pm[0], BW * 4, bp, bmp) <> S_OK then Exit;

  if FNCache >= CACHE_MAX then FreeCache;   // simple cap: drop all, rebuild (rare)
  if FNCache = Length(FCache) then SetLength(FCache, FNCache + 8);
  slot := FNCache; Inc(FNCache);
  FCache[slot].Hash := hash; FCache[slot].W := BW; FCache[slot].H := BH; FCache[slot].Bmp := bmp;
  Result := bmp;
end;

procedure TD2DCanvas.DrawRGBA(Buf: Pointer; BW, BH: Integer; DX, DY, DW, DH: Single);
var bmp: Pointer; dr: TD2DRectF;
begin
  if (FRT = nil) or (DW <= 0) or (DH <= 0) then Exit;
  bmp := BitmapFor(Buf, BW, BH);
  if bmp = nil then Exit;
  dr := RectF(DX, DY, DX + DW, DY + DH);
  RT(FRT)^.DrawBitmap(FRT, bmp, @dr, 1.0, INTERP_LINEAR, nil);
end;

end.
