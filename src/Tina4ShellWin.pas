unit Tina4ShellWin;

{ Windows desktop shell for the Tina4 native renderer.

  Implements the TTina4Canvas contract on GDI (the Win32 graphics API) through
  FPC's `Windows` unit — the same idea as the Cocoa shell on AppKit. The window
  host (examples drive it) hands the canvas a device context per frame via
  BeginFrame; the engine then paints through GDI: solid/rounded rects, lines,
  ClearType text, clipping and an affine world transform for CSS transforms.

  A memory DC created once backs text measurement outside a paint cycle (the
  layout pass needs MeasureText). Coordinates are CSS pixels, top-left; colours
  are $AARRGGBB (GDI is opaque RGB in v1 — per-pixel alpha and the offscreen
  filter/3D compositing land on a 32-bit DIB section next). }

{$mode delphi}{$H+}

interface

uses
  Windows, SysUtils, Classes, Tina4RenderBackend, Tina4Compositor;

type
  { one entry of the offscreen filter/blend/3D layer stack }
  TWinLayer = record
    Dib: HBITMAP; Mem: HDC; Bits: PByte; Saved: HDC;
    ox, oy, w, h: Integer;
  end;

  { one decoded image: a GDI+ GpImage plus its pixel size }
  TWinImage = record Img: Pointer; W, H: Integer; end;

  TWinCanvas = class(TTina4Canvas)
  private
    FDC: HDC;              // current frame device context (set by BeginFrame)
    FMeasDC: HDC;          // memory DC for text measurement between frames
    FClipSaved: Boolean;   // a SetClip pushed a SaveDC we must RestoreDC
    FDestBits: PByte;      // the frame's back-buffer DIB pixels (BGRA, top-down)
    FDestW, FDestH: Integer;
    FLayers: array of TWinLayer;
    FImages: array of TWinImage;  // handle -> decoded GDI+ image
    FImageSrc: TStringList;       // src -> handle (Objects=PtrInt), -1 = cached failure
    function FaceFor(const Family: string): WideString;
    function MakeFont(SizePx: Single; Styles: TTina4FontStyles): HFONT;
    function DC: HDC;      // FDC if painting, else the measuring DC
    { composite a premultiplied Single RGBA buffer (pw x ph) into the back-buffer
      at (dx,dy) with the given CSS blend mode (source-over when '') }
    procedure CompositeToDest(buf: PSingleBuf; pw, ph, dx, dy: Integer; const Blend: string);
  public
    constructor Create;
    destructor Destroy; override;
    { ADC is the frame's memory DC; DestBits/DW/DH are its backing 32-bit
      top-down DIB pixels so blend-modes and backdrop-filter can read/write them. }
    procedure BeginFrame(ADC: HDC; DestBits: PByte; DW, DH: Integer);
    function LoadImage(const Src: string): Integer; override;
    function ImageSize(Handle: Integer; out W, H: Single): Boolean; override;
    procedure DrawImage(Handle: Integer; X, Y, W, H: Single); override;
    procedure FillRect(X, Y, W, H: Single; Color: TTina4Color); override;
    procedure StrokeRect(X, Y, W, H, Thickness: Single; Color: TTina4Color); override;
    procedure FillRoundRect(X, Y, W, H, Radius: Single; Color: TTina4Color); override;
    procedure StrokeRoundRect(X, Y, W, H, Radius, Thickness: Single; Color: TTina4Color); override;
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
    procedure ClearClip; override;
    procedure SaveState; override;
    procedure RestoreState; override;
    procedure Translate(DX, DY: Single); override;
    procedure Scale(SX, SY: Single); override;
    procedure Rotate(Degrees: Single); override;
    function BeginLayer(X, Y, W, H, Pad: Single): Integer; override;
    procedure EndLayerFiltered(Handle: Integer; const FilterSpec, BlendMode, MaskSpec: string); override;
    procedure BackdropFilter(X, Y, W, H: Single; const FilterSpec: string); override;
    procedure EndLayer3D(Handle: Integer; const Corners: array of Single); override;
  end;

{ Decode an image file (png/jpg/ico/bmp) through GDI+ and hand back a Windows
  HICON, so the app/window can wear the real Tina4 branding logo instead of the
  default. Returns 0 if the file is missing or cannot be decoded. }
function WinLoadHIcon(const Path: string): HICON;

{ Save a 32-bit top-down BGRA buffer (w*h*4 bytes) as an opaque PNG via GDI+.
  Used by the headless snapshot / reftest path. }
function WinSaveDibPng(bits: PByte; w, h: Integer; const path: string): Boolean;

implementation

uses
  base64, md5;

const
  CLEARTYPE_QUALITY = 5;

{ ---- GDI+ flat API (image decode + blit) ---------------------------------
  Images on Windows go through GDI+ (gdiplus.dll, present on every supported
  Windows): it decodes png/jpg/gif/bmp and blits with alpha through the same
  HDC the engine paints into, so clipping (border-radius / overflow) is honoured.
  The GDI world transform used for CSS transforms is GDI-only and not seen by
  GDI+, so an image inside a `transform` paints unwarped in v1. }
type
  TGpRectF = record x, y, w, h: Single; end;
  TGdiplusStartupInput = record
    GdiplusVersion: LongWord;
    DebugEventCallback: Pointer;
    SuppressBackgroundThread: LongBool;
    SuppressExternalCodecs: LongBool;
  end;

function GdiplusStartup(out token: PtrUInt; const input: TGdiplusStartupInput;
  output: Pointer): Integer; stdcall; external 'gdiplus.dll';
procedure GdiplusShutdown(token: PtrUInt); stdcall; external 'gdiplus.dll';
function GdipLoadImageFromFile(filename: PWideChar; out image: Pointer): Integer;
  stdcall; external 'gdiplus.dll';
function GdipDisposeImage(image: Pointer): Integer; stdcall; external 'gdiplus.dll';
function GdipGetImageWidth(image: Pointer; out w: LongWord): Integer;
  stdcall; external 'gdiplus.dll';
function GdipGetImageHeight(image: Pointer; out h: LongWord): Integer;
  stdcall; external 'gdiplus.dll';
function GdipCreateFromHDC(hdc: HDC; out graphics: Pointer): Integer;
  stdcall; external 'gdiplus.dll';
function GdipDeleteGraphics(graphics: Pointer): Integer; stdcall; external 'gdiplus.dll';
function GdipSetInterpolationMode(graphics: Pointer; mode: Integer): Integer;
  stdcall; external 'gdiplus.dll';
function GdipDrawImageRectI(graphics, image: Pointer; x, y, w, h: Integer): Integer;
  stdcall; external 'gdiplus.dll';
function GdipDrawImageRectRectI(graphics, image: Pointer;
  dstx, dsty, dstw, dsth, srcx, srcy, srcw, srch, srcUnit: Integer;
  imageAttributes, callback, callbackData: Pointer): Integer;
  stdcall; external 'gdiplus.dll';
function GdipCreateImageAttributes(out imageattr: Pointer): Integer;
  stdcall; external 'gdiplus.dll';
function GdipSetImageAttributesWrapMode(imageattr: Pointer; wrap: Integer;
  argb: LongWord; clamp: LongBool): Integer; stdcall; external 'gdiplus.dll';
function GdipDisposeImageAttributes(imageattr: Pointer): Integer;
  stdcall; external 'gdiplus.dll';
function GdipCreateHICONFromBitmap(bitmap: Pointer; out hicon: HICON): Integer;
  stdcall; external 'gdiplus.dll';
function GdipCreateBitmapFromScan0(w, h, stride, format: Integer; scan0: PByte;
  out bitmap: Pointer): Integer; stdcall; external 'gdiplus.dll';
function GdipSaveImageToFile(image: Pointer; filename: PWideChar;
  const clsid: TGUID; encoderParams: Pointer): Integer; stdcall; external 'gdiplus.dll';
{ vector shapes with anti-aliasing + true ARGB alpha }
function GdipSetSmoothingMode(graphics: Pointer; mode: Integer): Integer; stdcall; external 'gdiplus.dll';
function GdipCreateSolidFill(argb: LongWord; out brush: Pointer): Integer; stdcall; external 'gdiplus.dll';
function GdipDeleteBrush(brush: Pointer): Integer; stdcall; external 'gdiplus.dll';
function GdipCreatePen1(argb: LongWord; width: Single; unit_: Integer; out pen: Pointer): Integer; stdcall; external 'gdiplus.dll';
function GdipDeletePen(pen: Pointer): Integer; stdcall; external 'gdiplus.dll';
function GdipCreatePath(brushMode: Integer; out path: Pointer): Integer; stdcall; external 'gdiplus.dll';
function GdipDeletePath(path: Pointer): Integer; stdcall; external 'gdiplus.dll';
function GdipAddPathArc(path: Pointer; x, y, w, h, startAngle, sweepAngle: Single): Integer; stdcall; external 'gdiplus.dll';
function GdipAddPathLine(path: Pointer; x1, y1, x2, y2: Single): Integer; stdcall; external 'gdiplus.dll';
function GdipClosePathFigure(path: Pointer): Integer; stdcall; external 'gdiplus.dll';
function GdipFillPath(graphics, brush, path: Pointer): Integer; stdcall; external 'gdiplus.dll';
function GdipDrawPath(graphics, pen, path: Pointer): Integer; stdcall; external 'gdiplus.dll';
function GdipFillRectangle(graphics, brush: Pointer; x, y, w, h: Single): Integer; stdcall; external 'gdiplus.dll';
function GdipCreateMatrix2(m11, m12, m21, m22, dx, dy: Single; out matrix: Pointer): Integer; stdcall; external 'gdiplus.dll';
{ gradient brushes (anti-aliased, multi-stop, alpha-aware) }
function GdipCreateLineBrushFromRectWithAngle(const rect: TGpRectF; c1, c2: LongWord;
  angle: Single; isAngleScalable: LongBool; wrapMode: Integer; out brush: Pointer): Integer; stdcall; external 'gdiplus.dll';
function GdipSetLinePresetBlend(brush: Pointer; blend: PLongWord; positions: PSingle; count: Integer): Integer; stdcall; external 'gdiplus.dll';
function GdipCreatePathGradientFromPath(path: Pointer; out brush: Pointer): Integer; stdcall; external 'gdiplus.dll';
function GdipSetPathGradientCenterColor(brush: Pointer; c: LongWord): Integer; stdcall; external 'gdiplus.dll';
function GdipSetPathGradientSurroundColorsWithCount(brush: Pointer; colors: PLongWord; var count: Integer): Integer; stdcall; external 'gdiplus.dll';
function GdipSetPathGradientPresetBlend(brush: Pointer; blend: PLongWord; positions: PSingle; count: Integer): Integer; stdcall; external 'gdiplus.dll';
function GdipSetPathGradientCenterPointI(brush: Pointer; const pt: TPoint): Integer; stdcall; external 'gdiplus.dll';
function GdipSetWorldTransform(graphics, matrix: Pointer): Integer; stdcall; external 'gdiplus.dll';
function GdipDeleteMatrix(matrix: Pointer): Integer; stdcall; external 'gdiplus.dll';

{ Append a rounded-rect figure to a GDI+ path (radius clamped to half the box). }
procedure GpRoundRectPath(path: Pointer; x, y, w, h, r: Single);
var d: Single;
begin
  if r > w / 2 then r := w / 2;
  if r > h / 2 then r := h / 2;
  if r <= 0 then
  begin
    GdipAddPathLine(path, x, y, x+w, y); GdipAddPathLine(path, x+w, y, x+w, y+h);
    GdipAddPathLine(path, x+w, y+h, x, y+h); GdipClosePathFigure(path); Exit;
  end;
  d := 2 * r;
  GdipAddPathArc(path, x, y, d, d, 180, 90);
  GdipAddPathArc(path, x + w - d, y, d, d, 270, 90);
  GdipAddPathArc(path, x + w - d, y + h - d, d, d, 0, 90);
  GdipAddPathArc(path, x, y + h - d, d, d, 90, 90);
  GdipClosePathFigure(path);
end;

function URLDownloadToFileW(caller: Pointer; url, filename: PWideChar;
  reserved: DWORD; cb: Pointer): HRESULT; stdcall; external 'urlmon.dll';

var
  GGdiplusToken: PtrUInt = 0;
  GGdiplusOK: Boolean = False;

{ Start GDI+ once, lazily, on first image/icon use. }
procedure EnsureGdiplus;
var si: TGdiplusStartupInput;
begin
  if GGdiplusOK then Exit;
  FillChar(si, SizeOf(si), 0);
  si.GdiplusVersion := 1;
  if GdiplusStartup(GGdiplusToken, si, nil) = 0 then GGdiplusOK := True;
end;

{ Open a GDI+ graphics on the current DC, anti-aliased and carrying the DC's GDI
  world transform (so CSS transforms still apply). Returns nil if GDI+ is off. }
function GpBegin(dc: HDC): Pointer;
var g, m: Pointer; xf: Windows.XFORM;
begin
  Result := nil;
  EnsureGdiplus; if not GGdiplusOK then Exit;
  if GdipCreateFromHDC(dc, g) <> 0 then Exit;
  GdipSetSmoothingMode(g, 4);              // SmoothingModeAntiAlias
  if GetWorldTransform(dc, xf) then
    if GdipCreateMatrix2(xf.eM11, xf.eM12, xf.eM21, xf.eM22, xf.eDx, xf.eDy, m) = 0 then
    begin GdipSetWorldTransform(g, m); GdipDeleteMatrix(m); end;
  Result := g;
end;

{ Write raw bytes to a file (whole-buffer). }
procedure BytesToFile(const Bytes: AnsiString; const Path: string);
var fs: TFileStream;
begin
  fs := TFileStream.Create(Path, fmCreate);
  try
    if Length(Bytes) > 0 then fs.WriteBuffer(Bytes[1], Length(Bytes));
  finally
    fs.Free;
  end;
end;

{ Resolve a CSS image Src (data: URI, http(s) URL, or local path) to a decodable
  local file, using a temp cache so repeat/network sources are only fetched once.
  Returns '' if it cannot be resolved. }
function ResolveImageToFile(const Src: string): string;
var
  low, cacheDir, cacheFile, ext, b64: string;
  comma: Integer;
begin
  Result := '';
  low := LowerCase(Src);
  cacheDir := IncludeTrailingPathDelimiter(GetTempDir) + 'tina4render' + PathDelim;
  ForceDirectories(cacheDir);

  if Pos('data:', low) = 1 then
  begin
    comma := Pos(',', Src);
    if comma = 0 then Exit;
    ext := '.img';
    if Pos('image/png', low) > 0 then ext := '.png'
    else if (Pos('image/jpeg', low) > 0) or (Pos('image/jpg', low) > 0) then ext := '.jpg'
    else if Pos('image/gif', low) > 0 then ext := '.gif'
    else if Pos('image/bmp', low) > 0 then ext := '.bmp';
    cacheFile := cacheDir + MD5Print(MD5String(Src)) + ext;
    if not FileExists(cacheFile) then
    begin
      b64 := Copy(Src, comma + 1, MaxInt);
      // only base64 payloads are supported (the common CSS/img case)
      if Pos(';base64', low) = 0 then Exit;
      try BytesToFile(DecodeStringBase64(b64), cacheFile); except Exit; end;
    end;
    Result := cacheFile;
  end
  else if (Pos('http://', low) = 1) or (Pos('https://', low) = 1) then
  begin
    cacheFile := cacheDir + MD5Print(MD5String(Src)) + '.img';
    if not FileExists(cacheFile) then
      if URLDownloadToFileW(nil, PWideChar(UTF8Decode(Src)),
           PWideChar(UTF8Decode(cacheFile)), 0, nil) <> 0 then Exit;
    if FileExists(cacheFile) then Result := cacheFile;
  end
  else
  begin
    ext := Src;
    if Pos('file://', low) = 1 then ext := Copy(Src, 8, MaxInt);
    if FileExists(ext) then Result := ext;
  end;
end;

function WinLoadHIcon(const Path: string): HICON;
var img: Pointer; file_: string;
begin
  Result := 0;
  EnsureGdiplus;
  if not GGdiplusOK then Exit;
  file_ := ResolveImageToFile(Path);
  if file_ = '' then Exit;
  img := nil;
  if GdipLoadImageFromFile(PWideChar(UTF8Decode(file_)), img) <> 0 then Exit;
  if img <> nil then
  begin
    GdipCreateHICONFromBitmap(img, Result);
    GdipDisposeImage(img);
  end;
end;

{ Save a 32-bit top-down BGRA DIB buffer to a PNG (GDI+), for headless snapshots
  — the Windows side of the reftest/compliance harness. Uses 32bppRGB so the
  alpha channel (which GDI leaves at 0 on drawn pixels) is ignored and the output
  is opaque. }
function WinSaveDibPng(bits: PByte; w, h: Integer; const path: string): Boolean;
const
  PNG_CLSID: TGUID = '{557CF406-1A04-11D3-9A73-0000F81EF32E}';
  PixelFormat32bppRGB = $22009;
var bmp: Pointer;
begin
  Result := False;
  EnsureGdiplus;
  if not GGdiplusOK then Exit;
  if GdipCreateBitmapFromScan0(w, h, w * 4, PixelFormat32bppRGB, bits, bmp) <> 0 then Exit;
  Result := GdipSaveImageToFile(bmp, PWideChar(UTF8Decode(path)), PNG_CLSID, nil) = 0;
  GdipDisposeImage(bmp);
end;

function ColorRefOf(C: TTina4Color): COLORREF;
begin
  // $AARRGGBB -> GDI 0x00BBGGRR
  Result := ((C shr 16) and $FF) or (((C shr 8) and $FF) shl 8) or ((C and $FF) shl 16);
end;

constructor TWinCanvas.Create;
begin
  inherited Create;
  FMeasDC := CreateCompatibleDC(0);
  SetBkMode(FMeasDC, TRANSPARENT);
  FImageSrc := TStringList.Create;
  FImageSrc.Sorted := True;
  FImageSrc.Duplicates := dupIgnore;
end;

destructor TWinCanvas.Destroy;
var i: Integer;
begin
  for i := 0 to High(FImages) do
    if FImages[i].Img <> nil then GdipDisposeImage(FImages[i].Img);
  FImageSrc.Free;
  if FMeasDC <> 0 then DeleteDC(FMeasDC);
  inherited Destroy;
end;

procedure TWinCanvas.BeginFrame(ADC: HDC; DestBits: PByte; DW, DH: Integer);
begin
  FDC := ADC;
  FDestBits := DestBits; FDestW := DW; FDestH := DH;
  SetBkMode(FDC, TRANSPARENT);
  SetGraphicsMode(FDC, GM_ADVANCED);   // enable world transforms for CSS transforms
end;

function TWinCanvas.DC: HDC;
begin
  if FDC <> 0 then Result := FDC else Result := FMeasDC;
end;

function TWinCanvas.LoadImage(const Src: string): Integer;
var idx, n: Integer; file_: string; img: Pointer; w, h: LongWord;
begin
  if FImageSrc.Find(Src, idx) then
    Exit(Integer(PtrInt(FImageSrc.Objects[idx])));
  Result := -1;
  EnsureGdiplus;
  if GGdiplusOK then
  begin
    file_ := ResolveImageToFile(Src);
    if file_ <> '' then
    begin
      img := nil;
      if (GdipLoadImageFromFile(PWideChar(UTF8Decode(file_)), img) = 0) and (img <> nil) then
      begin
        w := 0; h := 0;
        GdipGetImageWidth(img, w); GdipGetImageHeight(img, h);
        n := Length(FImages); SetLength(FImages, n + 1);
        FImages[n].Img := img; FImages[n].W := w; FImages[n].H := h;
        Result := n;
      end;
    end;
  end;
  FImageSrc.AddObject(Src, TObject(PtrInt(Result)));   // cache success or failure
end;

function TWinCanvas.ImageSize(Handle: Integer; out W, H: Single): Boolean;
begin
  W := 0; H := 0;
  Result := (Handle >= 0) and (Handle <= High(FImages)) and (FImages[Handle].Img <> nil);
  if Result then begin W := FImages[Handle].W; H := FImages[Handle].H; end;
end;

procedure TWinCanvas.DrawImage(Handle: Integer; X, Y, W, H: Single);
var g, attr: Pointer; iw, ih: LongWord;
begin
  if (Handle < 0) or (Handle > High(FImages)) or (FImages[Handle].Img = nil) then Exit;
  if (W <= 0) or (H <= 0) then Exit;
  if GdipCreateFromHDC(DC, g) <> 0 then Exit;
  GdipSetInterpolationMode(g, 7);   // HighQualityBicubic
  // Draw from the explicit source rect with a TileFlipXY wrap mode: when the
  // image is upscaled (e.g. background-size:cover on a tiny bitmap), bicubic
  // sampling past the edge would otherwise fade to transparent and leave a halo.
  iw := 0; ih := 0;
  GdipGetImageWidth(FImages[Handle].Img, iw);
  GdipGetImageHeight(FImages[Handle].Img, ih);
  attr := nil;
  if (iw > 0) and (ih > 0) and (GdipCreateImageAttributes(attr) = 0) then
  begin
    GdipSetImageAttributesWrapMode(attr, 3 {WrapModeTileFlipXY}, 0, False);
    GdipDrawImageRectRectI(g, FImages[Handle].Img,
      Round(X), Round(Y), Round(W), Round(H),
      0, 0, Integer(iw), Integer(ih), 2 {UnitPixel}, attr, nil, nil);
    GdipDisposeImageAttributes(attr);
  end
  else
    GdipDrawImageRectI(g, FImages[Handle].Img, Round(X), Round(Y), Round(W), Round(H));
  GdipDeleteGraphics(g);
end;

{ Map a CSS font-family list to a concrete Windows face. }
function TWinCanvas.FaceFor(const Family: string): WideString;
var f, first: string; p: Integer;
begin
  f := LowerCase(Trim(Family));
  p := Pos(',', f); if p > 0 then first := Trim(Copy(f, 1, p - 1)) else first := f;
  first := StringReplace(first, '"', '', [rfReplaceAll]);
  first := StringReplace(first, '''', '', [rfReplaceAll]);
  if (first = '') or (first = 'sans-serif') or (first = 'system-ui') then Result := 'Segoe UI'
  else if first = 'serif' then Result := 'Times New Roman'
  else if (first = 'monospace') or (first = 'mono') then Result := 'Consolas'
  else Result := UTF8Decode(Trim(Family).Split([','])[0].Trim);
end;

function TWinCanvas.MakeFont(SizePx: Single; Styles: TTina4FontStyles): HFONT;
var lf: LOGFONTW; face: WideString; i, n: Integer;
begin
  FillChar(lf, SizeOf(lf), 0);
  lf.lfHeight := -Round(SizePx);            // negative => em height in device px
  if (tfsBold in Styles) or (FontWeight >= 600) then lf.lfWeight := FW_BOLD
  else lf.lfWeight := FW_NORMAL;
  if tfsItalic in Styles then lf.lfItalic := 1;
  if tfsUnderline in Styles then lf.lfUnderline := 1;
  if tfsStrike in Styles then lf.lfStrikeOut := 1;
  lf.lfQuality := CLEARTYPE_QUALITY;
  lf.lfCharSet := DEFAULT_CHARSET;
  face := FaceFor(FontFamily);
  n := Length(face); if n > 31 then n := 31;
  for i := 1 to n do lf.lfFaceName[i - 1] := WideChar(face[i]);
  lf.lfFaceName[n] := #0;
  Result := CreateFontIndirectW(@lf);
end;

procedure TWinCanvas.FillRect(X, Y, W, H: Single; Color: TTina4Color);
var r: Windows.RECT; hbr: HBRUSH; g, br: Pointer; a: LongWord;
begin
  if (W <= 0) or (H <= 0) then Exit;
  a := (LongWord(Color) shr 24) and $FF;
  if (a > 0) and (a < $FF) then    // genuine partial alpha (rgba/shadow) -> GDI+ blend
  begin
    g := GpBegin(DC);
    if g <> nil then
    begin
      if GdipCreateSolidFill(LongWord(Color), br) = 0 then
      begin GdipFillRectangle(g, br, X, Y, W, H); GdipDeleteBrush(br); end;
      GdipDeleteGraphics(g); Exit;
    end;
  end;
  r.Left := Round(X); r.Top := Round(Y); r.Right := Round(X + W); r.Bottom := Round(Y + H);
  hbr := CreateSolidBrush(ColorRefOf(Color));
  Windows.FillRect(DC, r, hbr);
  DeleteObject(hbr);
end;

procedure TWinCanvas.StrokeRect(X, Y, W, H, Thickness: Single; Color: TTina4Color);
var pen, old: HGDIOBJ; oldBr: HGDIOBJ;
begin
  pen := CreatePen(PS_SOLID, Round(Thickness), ColorRefOf(Color));
  old := SelectObject(DC, pen);
  oldBr := SelectObject(DC, GetStockObject(NULL_BRUSH));
  Windows.Rectangle(DC, Round(X), Round(Y), Round(X + W), Round(Y + H));
  SelectObject(DC, oldBr);
  SelectObject(DC, old); DeleteObject(pen);
end;

{ alpha 0 from the engine means "opaque, unset" (the old GDI path ignored alpha);
  a real partial alpha like the box-shadow's 0x14 is honoured. }
function ArgbOf(Color: TTina4Color): LongWord; inline;
begin
  Result := LongWord(Color);
  if (Result shr 24) = 0 then Result := Result or $FF000000;
end;

procedure TWinCanvas.FillRoundRect(X, Y, W, H, Radius: Single; Color: TTina4Color);
var g, br, path: Pointer; hbr, oldbr, oldpen: HGDIOBJ; d: Integer;
begin
  if (W <= 0) or (H <= 0) then Exit;
  g := GpBegin(DC);
  if g <> nil then
  begin
    if GdipCreatePath(0, path) = 0 then
    begin
      GpRoundRectPath(path, X, Y, W, H, Radius);
      if GdipCreateSolidFill(ArgbOf(Color), br) = 0 then
      begin GdipFillPath(g, br, path); GdipDeleteBrush(br); end;
      GdipDeletePath(path);
    end;
    GdipDeleteGraphics(g);
    Exit;
  end;
  d := Round(Radius * 2);                       // GDI fallback
  hbr := CreateSolidBrush(ColorRefOf(Color));
  oldbr := SelectObject(DC, hbr);
  oldpen := SelectObject(DC, GetStockObject(NULL_PEN));
  Windows.RoundRect(DC, Round(X), Round(Y), Round(X + W) + 1, Round(Y + H) + 1, d, d);
  SelectObject(DC, oldpen); SelectObject(DC, oldbr); DeleteObject(hbr);
end;

procedure TWinCanvas.StrokeRoundRect(X, Y, W, H, Radius, Thickness: Single; Color: TTina4Color);
var g, pen, path: Pointer; hpen, old, oldBr: HGDIOBJ; d: Integer;
begin
  g := GpBegin(DC);
  if g <> nil then
  begin
    if GdipCreatePath(0, path) = 0 then
    begin
      GpRoundRectPath(path, X, Y, W, H, Radius);
      if GdipCreatePen1(ArgbOf(Color), Thickness, 2, pen) = 0 then   // unit 2 = pixel
      begin GdipDrawPath(g, pen, path); GdipDeletePen(pen); end;
      GdipDeletePath(path);
    end;
    GdipDeleteGraphics(g);
    Exit;
  end;
  d := Round(Radius * 2);
  hpen := CreatePen(PS_SOLID, Round(Thickness), ColorRefOf(Color));
  old := SelectObject(DC, hpen);
  oldBr := SelectObject(DC, GetStockObject(NULL_BRUSH));
  Windows.RoundRect(DC, Round(X), Round(Y), Round(X + W), Round(Y + H), d, d);
  SelectObject(DC, oldBr); SelectObject(DC, old); DeleteObject(hpen);
end;

procedure TWinCanvas.FillLinearGradient(X, Y, W, H, Radius, AngleDeg: Single;
  const Colors: array of TTina4Color; const Positions: array of Single);
var
  g, br, path: Pointer; rc: TGpRectF; n, i: Integer;
  argb: array of LongWord; pos: array of Single; loc, gdipAngle: Single;
begin
  n := Length(Colors);
  if (n = 0) or (W <= 0) or (H <= 0) then Exit;
  g := GpBegin(DC);
  if g = nil then begin inherited FillLinearGradient(X, Y, W, H, Radius, AngleDeg, Colors, Positions); Exit; end;
  SetLength(argb, n); SetLength(pos, n);
  for i := 0 to n - 1 do
  begin
    argb[i] := ArgbOf(Colors[i]);
    if (i < Length(Positions)) and (Positions[i] >= 0) then loc := Positions[i]
    else if n > 1 then loc := i / (n - 1) else loc := 0;
    if (i > 0) and (loc < pos[i-1]) then loc := pos[i-1];
    pos[i] := loc;
  end;
  pos[0] := 0; pos[n-1] := 1;                 // preset blend needs the endpoints
  rc.x := X; rc.y := Y; rc.w := W; rc.h := H;
  gdipAngle := AngleDeg - 90;                 // CSS 0=up,90=right -> GDI+ 0=L->R
  if GdipCreateLineBrushFromRectWithAngle(rc, argb[0], argb[n-1], gdipAngle, False, 0, br) = 0 then
  begin
    if n > 2 then GdipSetLinePresetBlend(br, @argb[0], @pos[0], n);
    if GdipCreatePath(0, path) = 0 then
    begin
      GpRoundRectPath(path, X, Y, W, H, Radius);
      GdipFillPath(g, br, path);
      GdipDeletePath(path);
    end;
    GdipDeleteBrush(br);
  end;
  GdipDeleteGraphics(g);
end;

procedure TWinCanvas.FillRadialGradient(X, Y, W, H, Radius: Single;
  const Colors: array of TTina4Color; const Positions: array of Single);
var
  g, br, path: Pointer; n, i, cnt: Integer;
  argb: array of LongWord; pos: array of Single; loc: Single;
  surround: array[0..0] of LongWord; ctr: TPoint;
begin
  n := Length(Colors);
  if (n = 0) or (W <= 0) or (H <= 0) then Exit;
  g := GpBegin(DC);
  if g = nil then begin inherited FillRadialGradient(X, Y, W, H, Radius, Colors, Positions); Exit; end;
  if GdipCreatePath(0, path) <> 0 then begin GdipDeleteGraphics(g); Exit; end;
  GpRoundRectPath(path, X, Y, W, H, Radius);
  if GdipCreatePathGradientFromPath(path, br) = 0 then
  begin
    GdipSetPathGradientCenterColor(br, ArgbOf(Colors[0]));         // CSS: first = centre
    surround[0] := ArgbOf(Colors[n-1]); cnt := 1;                  // last = edge
    GdipSetPathGradientSurroundColorsWithCount(br, @surround[0], cnt);
    ctr.x := Round(X + W/2); ctr.y := Round(Y + H/2);
    GdipSetPathGradientCenterPointI(br, ctr);
    if n > 2 then
    begin
      // path-gradient blend runs boundary(0)->centre(1): reverse the CSS stops
      SetLength(argb, n); SetLength(pos, n);
      for i := 0 to n - 1 do
      begin
        argb[i] := ArgbOf(Colors[n-1-i]);
        if (n-1-i < Length(Positions)) and (Positions[n-1-i] >= 0) then loc := 1 - Positions[n-1-i]
        else loc := i / (n - 1);
        if (i > 0) and (loc < pos[i-1]) then loc := pos[i-1];
        pos[i] := loc;
      end;
      pos[0] := 0; pos[n-1] := 1;
      GdipSetPathGradientPresetBlend(br, @argb[0], @pos[0], n);
    end;
    GdipFillPath(g, br, path);
    GdipDeleteBrush(br);
  end;
  GdipDeletePath(path);
  GdipDeleteGraphics(g);
end;

procedure TWinCanvas.DrawLine(X1, Y1, X2, Y2, Thickness: Single; Color: TTina4Color);
var pen, old: HGDIOBJ;
begin
  pen := CreatePen(PS_SOLID, Round(Thickness), ColorRefOf(Color));
  old := SelectObject(DC, pen);
  Windows.MoveToEx(DC, Round(X1), Round(Y1), nil);
  Windows.LineTo(DC, Round(X2), Round(Y2));
  SelectObject(DC, old); DeleteObject(pen);
end;

procedure TWinCanvas.DrawText(X, Y: Single; const Text: string; FontSize: Single;
  Styles: TTina4FontStyles; Color: TTina4Color);
var f, old: HGDIOBJ; w: WideString;
begin
  if Text = '' then Exit;
  f := MakeFont(FontSize, Styles);
  old := SelectObject(DC, f);
  SetTextColor(DC, ColorRefOf(Color));
  SetBkMode(DC, TRANSPARENT);
  if LetterSpacing <> 0 then SetTextCharacterExtra(DC, Round(LetterSpacing));
  w := UTF8Decode(Text);
  Windows.TextOutW(DC, Round(X), Round(Y), PWideChar(w), Length(w));
  if LetterSpacing <> 0 then SetTextCharacterExtra(DC, 0);
  SelectObject(DC, old); DeleteObject(f);
end;

function TWinCanvas.MeasureText(const Text: string; FontSize: Single;
  Styles: TTina4FontStyles): TTina4TextMetrics;
var f, old: HGDIOBJ; w: WideString; sz: SIZE; tm: TEXTMETRICW; d: HDC;
begin
  d := DC;
  f := MakeFont(FontSize, Styles);
  old := SelectObject(d, f);
  w := UTF8Decode(Text);
  sz.cx := 0; sz.cy := 0;
  if w <> '' then Windows.GetTextExtentPoint32W(d, PWideChar(w), Length(w), sz);
  if LetterSpacing <> 0 then sz.cx := sz.cx + Round(LetterSpacing) * Length(w);
  GetTextMetricsW(d, @tm);
  SelectObject(d, old); DeleteObject(f);
  Result.Width := sz.cx;
  Result.Ascent := tm.tmAscent;
  Result.Descent := tm.tmDescent;
  Result.LineHeight := tm.tmHeight;
end;

procedure TWinCanvas.SetClip(X, Y, W, H: Single);
begin
  // one level deep: SaveDC, intersect; ClearClip does RestoreDC
  SaveDC(DC); FClipSaved := True;
  IntersectClipRect(DC, Round(X), Round(Y), Round(X + W), Round(Y + H));
end;

procedure TWinCanvas.ClearClip;
begin
  if FClipSaved then begin RestoreDC(DC, -1); FClipSaved := False; end;
end;

{ CSS clip-path: intersect a polygon (device coords) into the current clip.
  Undone by the surrounding SaveState/RestoreState, matching the Cocoa backend.
  The GDI region is in device space, so it ignores any active world transform —
  fine for a plain clip-path (the transform is identity); a clip-path combined
  with rotate/scale is a known limitation. }
procedure TWinCanvas.ClipPolygon(const Pts: TTina4PointArray);
var rgn: HRGN; i, n: Integer; gp: array of TPoint;
begin
  n := Length(Pts);
  if n < 3 then Exit;
  SetLength(gp, n);
  for i := 0 to n - 1 do
  begin
    gp[i].X := Round(Pts[i].X);
    gp[i].Y := Round(Pts[i].Y);
  end;
  rgn := CreatePolygonRgn(gp[0], n, WINDING);
  if rgn <> 0 then
  begin
    ExtSelectClipRgn(DC, rgn, RGN_AND);
    DeleteObject(rgn);
  end;
end;

procedure TWinCanvas.SaveState;
begin
  SaveDC(DC);
end;

procedure TWinCanvas.RestoreState;
begin
  RestoreDC(DC, -1);
end;

procedure TWinCanvas.Translate(DX, DY: Single);
var xf: XFORM;
begin
  xf.eM11 := 1; xf.eM12 := 0; xf.eM21 := 0; xf.eM22 := 1; xf.eDx := DX; xf.eDy := DY;
  ModifyWorldTransform(DC, xf, MWT_LEFTMULTIPLY);
end;

procedure TWinCanvas.Scale(SX, SY: Single);
var xf: XFORM;
begin
  xf.eM11 := SX; xf.eM12 := 0; xf.eM21 := 0; xf.eM22 := SY; xf.eDx := 0; xf.eDy := 0;
  ModifyWorldTransform(DC, xf, MWT_LEFTMULTIPLY);
end;

procedure TWinCanvas.Rotate(Degrees: Single);
var xf: XFORM; a, c, s: Single;
begin
  a := Degrees * Pi / 180; c := Cos(a); s := Sin(a);
  xf.eM11 := c; xf.eM12 := s; xf.eM21 := -s; xf.eM22 := c; xf.eDx := 0; xf.eDy := 0;
  ModifyWorldTransform(DC, xf, MWT_LEFTMULTIPLY);
end;

{ ---- offscreen filter / blend / 3D compositing (shared Tina4Compositor) ----
  Windows density is 1 (1 CSS px = 1 device px), so layer buffers are box-sized
  and map 1:1 into the back-buffer. GDI does not write the DIB alpha channel, so
  after drawing we force the element's core box opaque and leave the blur/shadow
  pad transparent (rounded-corner alpha inside the box is a v2 limitation). }

function MakeDib(w, h: Integer; out bits: PByte): HBITMAP;
var bmi: BITMAPINFO;
begin
  FillChar(bmi, SizeOf(bmi), 0);
  bmi.bmiHeader.biSize := SizeOf(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth := w;
  bmi.bmiHeader.biHeight := -h;         // top-down
  bmi.bmiHeader.biPlanes := 1;
  bmi.bmiHeader.biBitCount := 32;
  bmi.bmiHeader.biCompression := BI_RGB;
  bits := nil;
  Result := CreateDIBSection(0, bmi, DIB_RGB_COLORS, bits, 0, 0);
end;

function TWinCanvas.BeginLayer(X, Y, W, H, Pad: Single): Integer;
var ox, oy, bw, bh, n: Integer; dib: HBITMAP; mem: HDC; bits: PByte;
begin
  ox := Round(X - Pad); oy := Round(Y - Pad); bw := Round(W + 2 * Pad); bh := Round(H + 2 * Pad);
  if (bw <= 0) or (bh <= 0) then Exit(-1);
  dib := MakeDib(bw, bh, bits);
  if (dib = 0) or (bits = nil) then Exit(-1);
  FillChar(bits^, bw * bh * 4, 0);      // transparent
  mem := CreateCompatibleDC(FDC);
  SelectObject(mem, dib);
  SetBkMode(mem, TRANSPARENT);
  SetGraphicsMode(mem, GM_ADVANCED);
  SetWindowOrgEx(mem, ox, oy, nil);     // doc coords → buffer pixels
  n := Length(FLayers); SetLength(FLayers, n + 1);
  FLayers[n].Dib := dib; FLayers[n].Mem := mem; FLayers[n].Bits := bits; FLayers[n].Saved := FDC;
  FLayers[n].ox := ox; FLayers[n].oy := oy; FLayers[n].w := bw; FLayers[n].h := bh;
  FDC := mem;                            // redirect drawing into the layer
  Result := n;
end;

{ blend one premultiplied source pixel over an opaque back-buffer BGRA pixel }
procedure BlendPixel(d: PByte; sr, sg, sb, sa: Single; const Blend: string);
var dr, dg, db, br, bg, bb: Single;
begin
  if sa <= 0 then Exit;
  dr := d[2] / 255; dg := d[1] / 255; db := d[0] / 255;   // dest is opaque RGB (BGRA)
  if Blend = '' then begin br := sr; bg := sg; bb := sb; end   // source-over (premult src)
  else
  begin
    // separable blend on straight source colour, then premultiply by sa
    if sa > 0 then begin br := sr / sa; bg := sg / sa; bb := sb / sa; end else begin br := 0; bg := 0; bb := 0; end;
    if Blend = 'multiply' then begin br := br*dr; bg := bg*dg; bb := bb*db; end
    else if Blend = 'screen' then begin br := br+dr-br*dr; bg := bg+dg-bg*dg; bb := bb+db-bb*db; end
    else if Blend = 'darken' then begin if dr<br then br:=dr; if dg<bg then bg:=dg; if db<bb then bb:=db; end
    else if Blend = 'lighten' then begin if dr>br then br:=dr; if dg>bg then bg:=dg; if db>bb then bb:=db; end
    else if Blend = 'difference' then begin br := Abs(br-dr); bg := Abs(bg-dg); bb := Abs(bb-db); end
    else if Blend = 'overlay' then begin
      if dr<=0.5 then br:=2*br*dr else br:=1-2*(1-br)*(1-dr);
      if dg<=0.5 then bg:=2*bg*dg else bg:=1-2*(1-bg)*(1-dg);
      if db<=0.5 then bb:=2*bb*db else bb:=1-2*(1-bb)*(1-db); end;
    br := br * sa; bg := bg * sa; bb := bb * sa;   // re-premultiply
  end;
  // source-over: out = src + dest*(1-sa)
  dr := br + dr*(1-sa); dg := bg + dg*(1-sa); db := bb + db*(1-sa);
  if dr<0 then dr:=0; if dr>1 then dr:=1; if dg<0 then dg:=0; if dg>1 then dg:=1; if db<0 then db:=0; if db>1 then db:=1;
  d[2] := Round(dr*255); d[1] := Round(dg*255); d[0] := Round(db*255); d[3] := 255;
end;

procedure TWinCanvas.CompositeToDest(buf: PSingleBuf; pw, ph, dx, dy: Integer; const Blend: string);
var x, y, tx, ty, so: Integer; d: PByte;
begin
  if FDestBits = nil then Exit;
  GdiFlush;   // ensure GDI's batched draws are in the DIB before we read/write it
  for y := 0 to ph - 1 do
  begin
    ty := dy + y; if (ty < 0) or (ty >= FDestH) then Continue;
    for x := 0 to pw - 1 do
    begin
      tx := dx + x; if (tx < 0) or (tx >= FDestW) then Continue;
      so := (y * pw + x) * 4;
      d := FDestBits + (ty * FDestW + tx) * 4;
      BlendPixel(d, buf[so], buf[so+1], buf[so+2], buf[so+3], Blend);
    end;
  end;
end;

{ decode the layer DIB (BGRA, GDI left alpha=0) into a premultiplied RGBA Single
  buffer, forcing the element's core box (inside the pad) opaque. }
function DecodeLayer(const L: TWinLayer; PadX, PadY, CoreW, CoreH: Integer): PSingle;
var x, y, so, o: Integer; a: Single;
begin
  GetMem(Result, L.w * L.h * 4 * SizeOf(Single));
  for y := 0 to L.h - 1 do
    for x := 0 to L.w - 1 do
    begin
      o := (y * L.w + x) * 4; so := o;
      // inside the core box ⇒ opaque; pad ring ⇒ transparent (blur/shadow fade)
      if (x >= PadX) and (x < PadX + CoreW) and (y >= PadY) and (y < PadY + CoreH) then a := 1 else a := 0;
      Result[so]   := (L.Bits[o+2] / 255) * a;   // R (premultiplied)
      Result[so+1] := (L.Bits[o+1] / 255) * a;   // G
      Result[so+2] := (L.Bits[o]   / 255) * a;   // B
      Result[so+3] := a;
    end;
end;

procedure TWinCanvas.EndLayerFiltered(Handle: Integer; const FilterSpec, BlendMode, MaskSpec: string);
var L: TWinLayer; buf: PSingle; padx, pady, coreW, coreH: Integer;
begin
  if (Handle < 0) or (Handle > High(FLayers)) then Exit;
  L := FLayers[Handle];
  FDC := L.Saved;                       // restore back-buffer DC
  padx := 0; pady := 0; coreW := L.w; coreH := L.h;
  if FilterSpec <> '' then
  begin
    // recover the pad from the filter so blur/shadow fade into transparency
    padx := Round(FilterLayerPad(FilterSpec)); pady := padx;
    coreW := L.w - 2*padx; coreH := L.h - 2*pady;
    if coreW < 0 then coreW := L.w; if coreH < 0 then coreH := L.h;
  end;
  buf := DecodeLayer(L, padx, pady, coreW, coreH);
  try
    if (FilterSpec <> '') or (MaskSpec <> '') then
      ApplyFilterChainF(PSingleBuf(buf), L.w, L.h, FilterSpec, MaskSpec, 1);
    CompositeToDest(PSingleBuf(buf), L.w, L.h, L.ox, L.oy, LowerCase(BlendMode));
  finally
    FreeMem(buf);
  end;
  DeleteDC(L.Mem); DeleteObject(L.Dib);
  SetLength(FLayers, Handle);
end;

procedure TWinCanvas.EndLayer3D(Handle: Integer; const Corners: array of Single);
var
  L: TWinLayer; src: PSingle; dst: PByte; dbuf: PSingle;
  minx, miny, maxx, maxy: Single; i, dpw, dph, j: Integer;
  quad: array[0..7] of Single;
begin
  if (Handle < 0) or (Handle > High(FLayers)) then Exit;
  L := FLayers[Handle];
  FDC := L.Saved;
  src := DecodeLayer(L, 0, 0, L.w, L.h);
  try
    minx := Corners[0]; maxx := Corners[0]; miny := Corners[1]; maxy := Corners[1];
    for i := 1 to 3 do
    begin
      if Corners[i*2]   < minx then minx := Corners[i*2];
      if Corners[i*2]   > maxx then maxx := Corners[i*2];
      if Corners[i*2+1] < miny then miny := Corners[i*2+1];
      if Corners[i*2+1] > maxy then maxy := Corners[i*2+1];
    end;
    dpw := Round(maxx - minx); dph := Round(maxy - miny);
    if (dpw > 0) and (dph > 0) then
    begin
      for i := 0 to 3 do begin quad[i*2] := Corners[i*2] - minx; quad[i*2+1] := Corners[i*2+1] - miny; end;
      GetMem(dst, dpw * dph * 4); FillChar(dst^, dpw * dph * 4, 0);
      WarpQuad(PSingleBuf(src), L.w, L.h, quad, dst, dpw, dph);
      // warped dst is 8-bit premult RGBA → to Single premult for CompositeToDest
      GetMem(dbuf, dpw * dph * 4 * SizeOf(Single));
      for j := 0 to dpw * dph * 4 - 1 do dbuf[j] := dst[j] / 255;
      CompositeToDest(PSingleBuf(dbuf), dpw, dph, Round(minx), Round(miny), '');
      FreeMem(dbuf); FreeMem(dst);
    end;
  finally
    FreeMem(src);
  end;
  DeleteDC(L.Mem); DeleteObject(L.Dib);
  SetLength(FLayers, Handle);
end;

procedure TWinCanvas.BackdropFilter(X, Y, W, H: Single; const FilterSpec: string);
var bx, by, bw, bh, x2, y2, o, so: Integer; buf: PSingle; d: PByte;
begin
  if (FDestBits = nil) or (FilterSpec = '') then Exit;
  bx := Round(X); by := Round(Y); bw := Round(W); bh := Round(H);
  if (bw <= 0) or (bh <= 0) then Exit;
  GdiFlush;   // read the already-painted pixels behind the element
  GetMem(buf, bw * bh * 4 * SizeOf(Single));
  try
    for y2 := 0 to bh - 1 do
      for x2 := 0 to bw - 1 do
      begin
        so := (y2 * bw + x2) * 4;
        if (bx+x2 >= 0) and (bx+x2 < FDestW) and (by+y2 >= 0) and (by+y2 < FDestH) then
        begin
          d := FDestBits + ((by+y2) * FDestW + (bx+x2)) * 4;
          buf[so]   := d[2] / 255; buf[so+1] := d[1] / 255; buf[so+2] := d[0] / 255; buf[so+3] := 1;
        end
        else begin buf[so]:=1; buf[so+1]:=1; buf[so+2]:=1; buf[so+3]:=1; end;
      end;
    ApplyFilterChainF(PSingleBuf(buf), bw, bh, FilterSpec, '', 1);
    for y2 := 0 to bh - 1 do
      for x2 := 0 to bw - 1 do
        if (bx+x2 >= 0) and (bx+x2 < FDestW) and (by+y2 >= 0) and (by+y2 < FDestH) then
        begin
          so := (y2 * bw + x2) * 4; o := 0;
          d := FDestBits + ((by+y2) * FDestW + (bx+x2)) * 4;
          d[2] := Round(buf[so]*255); d[1] := Round(buf[so+1]*255); d[0] := Round(buf[so+2]*255); d[3] := 255;
        end;
  finally
    FreeMem(buf);
  end;
end;

end.
