unit Tina4ShellIOS;

{ iOS shell for the Tina4 native renderer.

  Implements the TTina4Canvas contract on Apple's C graphics stack — Core
  Graphics for shapes/images and Core Text for glyphs — using FPC's `univint`
  bindings, so no Objective-C is needed on the Pascal side. The Obj-C UIView
  (Tina4View.m) creates one TIOSCanvas, hands it the drawRect CGContext each
  frame via BeginFrame, and forwards touches/keys to the shared Tina4Interact
  engine through the C shim in tina4ios.pas.

  Coordinates: a UIView's drawRect context is already top-left / y-down and in
  POINTS (UIKit scales for retina), which lines up with the engine's CSS-px
  space — so the shell runs at density 1 and only Core Text / images need the
  local vertical flip that those two APIs require. Colours are $AARRGGBB. }

{$mode delphi}{$H+}
{$modeswitch objectivec1}

interface

uses
  CFBase, CFString, CFAttributedString, CFDictionary, CFURL, CFError,
  CGBase, CGContext, CGColor, CGColorSpace, CGGeometry, CGPath, CGGradient,
  CGImage, CGImageSource, CGBitmapContext, CGAffineTransforms, CGFont, CGDataProvider,
  CTFont, CTFontTraits, CTFontManager, CTLine, CTStringAttributes,
  Tina4RenderBackend, Tina4Compositor;

{ Implemented in the app (ios/app/ImageLoader.m): async NSURLSession download of
  a remote image to `path` (native TLS). On completion it calls tina4_image_ready
  so the engine relayouts and picks the cached file up. Idempotent per URL. }
procedure tina4_ios_fetch_image(Url, Path: PAnsiChar); cdecl;
  external name 'tina4_ios_fetch_image';

type
  TIOSCanvas = class(TTina4Canvas)
  private
    FCtx: CGContextRef;             // current frame's CGContext (from drawRect)
    FSpace: CGColorSpaceRef;        // cached device RGB colour space
    FImgs: array of record Img: CGImageRef; W, H: Single; end;
    FImgSrcs: array of string;
    FAssetBase: string;             // dir a relative <img src> resolves against
    FLayers: array of record        // offscreen filter/blend/3D layer stack
      Ctx, Saved: CGContextRef; ox, oy, w, h, sc: Single;
    end;
    function MakeColor(Color: TTina4Color): CGColorRef;
    function MakeFont(FontSize: Single; Styles: TTina4FontStyles): CTFontRef;
    function MakeLine(const Text: string; FontSize: Single;
      Styles: TTina4FontStyles; Color: TTina4Color): CTLineRef;
    procedure RRectPath(X, Y, W, H, Radius: Single);
  public
    constructor Create;
    destructor Destroy; override;
    procedure BeginFrame(Ctx: CGContextRef);
    procedure SetAssetBase(const Dir: string);   // bundle resource dir for relative <img>
    procedure FillRect(X, Y, W, H: Single; Color: TTina4Color); override;
    procedure StrokeRect(X, Y, W, H, Thickness: Single; Color: TTina4Color); override;
    procedure FillRoundRect(X, Y, W, H, Radius: Single; Color: TTina4Color); override;
    procedure StrokeRoundRect(X, Y, W, H, Radius, Thickness: Single; Color: TTina4Color); override;
    procedure DrawLine(X1, Y1, X2, Y2, Thickness: Single; Color: TTina4Color); override;
    procedure StrokePolyline(const Pts: TTina4PointArray; Width: Single;
      Color: TTina4Color; Closed: Boolean); override;
    procedure FillPolygon(const Contours: array of TTina4PointArray;
      Color: TTina4Color; EvenOdd: Boolean = False); override;
    procedure DrawText(X, Y: Single; const Text: string; FontSize: Single;
      Styles: TTina4FontStyles; Color: TTina4Color); override;
    function MeasureText(const Text: string; FontSize: Single;
      Styles: TTina4FontStyles): TTina4TextMetrics; override;
    procedure SetClip(X, Y, W, H: Single); override;
    procedure ClearClip; override;
    procedure SaveState; override;
    procedure RestoreState; override;
    procedure Scale(SX, SY: Single); override;
    procedure Translate(DX, DY: Single); override;
    procedure Rotate(Degrees: Single); override;
    procedure FillLinearGradient(X, Y, W, H, Radius, AngleDeg: Single;
      const Colors: array of TTina4Color; const Positions: array of Single); override;
    procedure FillRadialGradient(X, Y, W, H, Radius: Single;
      const Colors: array of TTina4Color; const Positions: array of Single); override;
    function LoadImage(const Src: string): Integer; override;
    function RegisterFont(const Family, Src: string): Boolean; override;
    function ImageSize(Handle: Integer; out W, H: Single): Boolean; override;
    procedure DrawImage(Handle: Integer; X, Y, W, H: Single); override;
    function BeginLayer(X, Y, W, H, Pad: Single): Integer; override;
    procedure EndLayerFiltered(Handle: Integer; const FilterSpec, BlendMode, MaskSpec: string); override;
    procedure EndLayer3D(Handle: Integer; const Corners: array of Single); override;
    { backdrop-filter needs a read-back of the view's pixels, which a plain
      CGContext can't provide on iOS — it stays the base no-op (degrades). }
  end;

implementation

uses SysUtils, Classes, md5;

var
  { @font-face aliases: CSS family (lowercased) -> the font's real registered
    name. Process-global; registration is process-wide on iOS too. }
  GFontAlias: TStringList = nil;

function FontAliasMap: TStringList;
begin
  if GFontAlias = nil then
  begin
    GFontAlias := TStringList.Create;
    GFontAlias.Sorted := True;
    GFontAlias.Duplicates := dupIgnore;
  end;
  Result := GFontAlias;
end;

{ ---- helpers ----------------------------------------------------------- }

function R(X, Y, W, H: Single): CGRect;
begin
  Result.origin.x := X; Result.origin.y := Y;
  Result.size.width := W; Result.size.height := H;
end;

function CFStr(const S: string): CFStringRef;
begin
  Result := CFStringCreateWithCString(nil, PAnsiChar(S), kCFStringEncodingUTF8);
end;

constructor TIOSCanvas.Create;
begin
  inherited Create;
  FSpace := CGColorSpaceCreateDeviceRGB;
end;

destructor TIOSCanvas.Destroy;
var i: Integer;
begin
  for i := 0 to High(FImgs) do
    if FImgs[i].Img <> nil then CGImageRelease(FImgs[i].Img);
  if FSpace <> nil then CGColorSpaceRelease(FSpace);
  inherited Destroy;
end;

procedure TIOSCanvas.BeginFrame(Ctx: CGContextRef);
begin
  FCtx := Ctx;
end;

procedure TIOSCanvas.SetAssetBase(const Dir: string);
begin
  FAssetBase := Dir;
end;

function TIOSCanvas.MakeColor(Color: TTina4Color): CGColorRef;
var comps: array[0..3] of CGFloat;
begin
  comps[0] := ((Color shr 16) and $FF) / 255;  // r
  comps[1] := ((Color shr 8)  and $FF) / 255;  // g
  comps[2] := ( Color         and $FF) / 255;  // b
  comps[3] := ((Color shr 24) and $FF) / 255;  // a
  Result := CGColorCreate(FSpace, @comps[0]);
end;

procedure SetFill(Ctx: CGContextRef; Color: TTina4Color);
begin
  CGContextSetRGBFillColor(Ctx,
    ((Color shr 16) and $FF) / 255, ((Color shr 8) and $FF) / 255,
    (Color and $FF) / 255, ((Color shr 24) and $FF) / 255);
end;

procedure SetStroke(Ctx: CGContextRef; Color: TTina4Color);
begin
  CGContextSetRGBStrokeColor(Ctx,
    ((Color shr 16) and $FF) / 255, ((Color shr 8) and $FF) / 255,
    (Color and $FF) / 255, ((Color shr 24) and $FF) / 255);
end;

{ ---- shapes ------------------------------------------------------------ }

procedure TIOSCanvas.FillRect(X, Y, W, H: Single; Color: TTina4Color);
begin
  SetFill(FCtx, Color);
  CGContextFillRect(FCtx, R(X, Y, W, H));
end;

procedure TIOSCanvas.StrokeRect(X, Y, W, H, Thickness: Single; Color: TTina4Color);
begin
  SetStroke(FCtx, Color);
  CGContextSetLineWidth(FCtx, Thickness);
  CGContextStrokeRect(FCtx, R(X + Thickness / 2, Y + Thickness / 2,
    W - Thickness, H - Thickness));
end;

{ Trace a rounded-rect path straight into the context (no CGPath object), using
  arc-to-point corners; the caller then fills or strokes it. }
procedure TIOSCanvas.RRectPath(X, Y, W, H, Radius: Single);
var rad: Single;
begin
  rad := Radius;
  if rad > W / 2 then rad := W / 2;
  if rad > H / 2 then rad := H / 2;
  if rad < 0 then rad := 0;
  CGContextBeginPath(FCtx);
  CGContextMoveToPoint(FCtx, X + rad, Y);
  CGContextAddArcToPoint(FCtx, X + W, Y,     X + W, Y + H, rad);  // top-right
  CGContextAddArcToPoint(FCtx, X + W, Y + H, X,     Y + H, rad);  // bottom-right
  CGContextAddArcToPoint(FCtx, X,     Y + H, X,     Y,     rad);  // bottom-left
  CGContextAddArcToPoint(FCtx, X,     Y,     X + W, Y,     rad);  // top-left
  CGContextClosePath(FCtx);
end;

procedure TIOSCanvas.FillRoundRect(X, Y, W, H, Radius: Single; Color: TTina4Color);
begin
  SetFill(FCtx, Color);
  RRectPath(X, Y, W, H, Radius);
  CGContextFillPath(FCtx);
end;

procedure TIOSCanvas.StrokeRoundRect(X, Y, W, H, Radius, Thickness: Single; Color: TTina4Color);
begin
  SetStroke(FCtx, Color);
  CGContextSetLineWidth(FCtx, Thickness);
  RRectPath(X + Thickness / 2, Y + Thickness / 2, W - Thickness, H - Thickness, Radius);
  CGContextStrokePath(FCtx);
end;

procedure TIOSCanvas.DrawLine(X1, Y1, X2, Y2, Thickness: Single; Color: TTina4Color);
begin
  SetStroke(FCtx, Color);
  CGContextSetLineWidth(FCtx, Thickness);
  CGContextBeginPath(FCtx);
  CGContextMoveToPoint(FCtx, X1, Y1);
  CGContextAddLineToPoint(FCtx, X2, Y2);
  CGContextStrokePath(FCtx);
end;

procedure TIOSCanvas.StrokePolyline(const Pts: TTina4PointArray; Width: Single;
  Color: TTina4Color; Closed: Boolean);
var i: Integer;
begin
  if Length(Pts) < 2 then Exit;
  SetStroke(FCtx, Color);
  CGContextSetLineWidth(FCtx, Width);
  CGContextSetLineJoin(FCtx, kCGLineJoinRound);
  CGContextSetLineCap(FCtx, kCGLineCapRound);
  CGContextBeginPath(FCtx);
  CGContextMoveToPoint(FCtx, Pts[0].X, Pts[0].Y);
  for i := 1 to High(Pts) do CGContextAddLineToPoint(FCtx, Pts[i].X, Pts[i].Y);
  if Closed then CGContextClosePath(FCtx);
  CGContextStrokePath(FCtx);
end;

procedure TIOSCanvas.FillPolygon(const Contours: array of TTina4PointArray;
  Color: TTina4Color; EvenOdd: Boolean);
var i, j: Integer;
begin
  SetFill(FCtx, Color);
  CGContextBeginPath(FCtx);
  for i := 0 to High(Contours) do
  begin
    if Length(Contours[i]) < 2 then Continue;
    CGContextMoveToPoint(FCtx, Contours[i][0].X, Contours[i][0].Y);
    for j := 1 to High(Contours[i]) do
      CGContextAddLineToPoint(FCtx, Contours[i][j].X, Contours[i][j].Y);
    CGContextClosePath(FCtx);
  end;
  if EvenOdd then CGContextEOFillPath(FCtx) else CGContextFillPath(FCtx);
end;

{ ---- text (Core Text) -------------------------------------------------- }

{ Resolve the CSS font-family stack to a concrete base face name. }
function IOSBaseFontName(const Family: string): string;
var cand: string; parts: TStringArray; k: Integer;
begin
  Result := '';
  if Trim(Family) = '' then Exit;
  parts := Family.Split([',']);
  for k := 0 to High(parts) do
  begin
    cand := Trim(parts[k]).DeQuotedString('"').DeQuotedString('''');
    cand := Trim(cand);
    if cand = '' then Continue;
    // @font-face: map the CSS family to the font's real registered name.
    if FontAliasMap.IndexOfName(LowerCase(cand)) >= 0 then
      Exit(FontAliasMap.Values[LowerCase(cand)]);
    if SameText(cand, 'system-ui') or SameText(cand, '-apple-system')
       or SameText(cand, 'sans-serif') then Exit('')        // system Helvetica
    else if SameText(cand, 'serif') then Exit('Georgia')
    else if SameText(cand, 'monospace') then Exit('Menlo')
    else Exit(cand);                                        // named/registered font
  end;
end;

function TIOSCanvas.MakeFont(FontSize: Single; Styles: TTina4FontStyles): CTFontRef;
var name: string; cf: CFStringRef; base, styled: CTFontRef; mask: CTFontSymbolicTraits;
begin
  name := IOSBaseFontName(FontFamily);
  if name = '' then
  begin
    // system Helvetica with the exact style variant (fast path)
    if (tfsBold in Styles) and (tfsItalic in Styles) then name := 'Helvetica-BoldOblique'
    else if tfsBold in Styles then name := 'Helvetica-Bold'
    else if tfsItalic in Styles then name := 'Helvetica-Oblique'
    else name := 'Helvetica';
    cf := CFStr(name);
    Result := CTFontCreateWithName(cf, FontSize, nil);
    CFRelease(cf);
    Exit;
  end;
  // named/generic face: create then layer bold/italic via symbolic traits
  cf := CFStr(name);
  base := CTFontCreateWithName(cf, FontSize, nil);
  CFRelease(cf);
  mask := 0;
  if tfsBold in Styles then mask := mask or kCTFontTraitBold;
  if tfsItalic in Styles then mask := mask or kCTFontTraitItalic;
  if mask <> 0 then
  begin
    styled := CTFontCreateCopyWithSymbolicTraits(base, FontSize, nil, mask, mask);
    if styled <> nil then begin CFRelease(base); Result := styled; end
    else Result := base;   // trait unavailable in this face — keep the base
  end
  else Result := base;
end;

function TIOSCanvas.MakeLine(const Text: string; FontSize: Single;
  Styles: TTina4FontStyles; Color: TTina4Color): CTLineRef;
var
  s: CFStringRef; attr: CFMutableAttributedStringRef;
  font: CTFontRef; col: CGColorRef; rng: CFRange; len: CFIndex;
begin
  s := CFStr(Text);
  attr := CFAttributedStringCreateMutable(nil, 0);
  CFAttributedStringReplaceString(attr, CFRangeMake(0, 0), s);
  len := CFStringGetLength(s);
  rng := CFRangeMake(0, len);
  font := MakeFont(FontSize, Styles);
  col := MakeColor(Color);
  CFAttributedStringSetAttribute(attr, rng, kCTFontAttributeName, font);
  CFAttributedStringSetAttribute(attr, rng, kCTForegroundColorAttributeName, col);
  Result := CTLineCreateWithAttributedString(CFAttributedStringRef(attr));
  CGColorRelease(col);
  CFRelease(font);
  CFRelease(attr);
  CFRelease(s);
end;

procedure TIOSCanvas.DrawText(X, Y: Single; const Text: string; FontSize: Single;
  Styles: TTina4FontStyles; Color: TTina4Color);
var line: CTLineRef; asc, desc, lead: CGFloat;
begin
  if Text = '' then Exit;
  line := MakeLine(Text, FontSize, Styles, Color);
  CTLineGetTypographicBounds(line, @asc, @desc, @lead);
  // (X,Y) is the text-box top-left; Core Text draws at the baseline in a y-up
  // frame, so translate to the baseline and flip locally.
  CGContextSaveGState(FCtx);
  CGContextSetTextMatrix(FCtx, CGAffineTransformIdentity);
  CGContextTranslateCTM(FCtx, X, Y + asc);
  CGContextScaleCTM(FCtx, 1, -1);
  CGContextSetTextPosition(FCtx, 0, 0);
  CTLineDraw(line, FCtx);
  CGContextRestoreGState(FCtx);
  CFRelease(line);
end;

function TIOSCanvas.MeasureText(const Text: string; FontSize: Single;
  Styles: TTina4FontStyles): TTina4TextMetrics;
var line: CTLineRef; asc, desc, lead, w: CGFloat;
begin
  if Text = '' then
  begin
    // still need ascent/descent for line-height; measure a space
    line := MakeLine(' ', FontSize, Styles, $FF000000);
    CTLineGetTypographicBounds(line, @asc, @desc, @lead);
    CFRelease(line);
    Result.Width := 0;
  end
  else
  begin
    line := MakeLine(Text, FontSize, Styles, $FF000000);
    w := CTLineGetTypographicBounds(line, @asc, @desc, @lead);
    CFRelease(line);
    Result.Width := w;
  end;
  Result.Ascent := asc;
  Result.Descent := desc;
  Result.LineHeight := asc + desc;   // exclude external leading (match Android),
end;                                 // so glyphs centre in the line box, not high

{ ---- clip / state ------------------------------------------------------ }

procedure TIOSCanvas.SetClip(X, Y, W, H: Single);
begin
  CGContextSaveGState(FCtx);
  CGContextClipToRect(FCtx, R(X, Y, W, H));
end;

procedure TIOSCanvas.ClearClip;
begin
  CGContextRestoreGState(FCtx);
end;

procedure TIOSCanvas.SaveState;
begin
  CGContextSaveGState(FCtx);
end;

procedure TIOSCanvas.RestoreState;
begin
  CGContextRestoreGState(FCtx);
end;

procedure TIOSCanvas.Scale(SX, SY: Single);
begin
  CGContextScaleCTM(FCtx, SX, SY);
end;

procedure TIOSCanvas.Translate(DX, DY: Single);
begin
  CGContextTranslateCTM(FCtx, DX, DY);
end;

procedure TIOSCanvas.Rotate(Degrees: Single);
begin
  // y-down context: a positive CTM rotation reads as CSS clockwise
  CGContextRotateCTM(FCtx, Degrees * Pi / 180);
end;

procedure TIOSCanvas.FillLinearGradient(X, Y, W, H, Radius, AngleDeg: Single;
  const Colors: array of TTina4Color; const Positions: array of Single);
var
  grad: CGGradientRef;
  comps, locs: array of Double;
  i, n: Integer;
  a, dx, dy, gl, cx, cy: Double;
begin
  n := Length(Colors); if n = 0 then Exit;
  SetLength(comps, n * 4); SetLength(locs, n);
  for i := 0 to n - 1 do
  begin
    comps[i*4]   := ((Colors[i] shr 16) and $FF) / 255;
    comps[i*4+1] := ((Colors[i] shr 8) and $FF) / 255;
    comps[i*4+2] := (Colors[i] and $FF) / 255;
    comps[i*4+3] := ((Colors[i] shr 24) and $FF) / 255;
    if (i < Length(Positions)) and (Positions[i] >= 0) then locs[i] := Positions[i]
    else if n > 1 then locs[i] := i / (n - 1) else locs[i] := 0;
    if (i > 0) and (locs[i] < locs[i-1]) then locs[i] := locs[i-1];
  end;
  grad := CGGradientCreateWithColorComponents(FSpace, @comps[0], @locs[0], n);
  if grad = nil then Exit;
  CGContextSaveGState(FCtx);
  RRectPath(X, Y, W, H, Radius); CGContextClip(FCtx);
  a := AngleDeg * Pi / 180; dx := Sin(a); dy := -Cos(a);
  gl := Abs(W * Sin(a)) + Abs(H * Cos(a)); cx := X + W/2; cy := Y + H/2;
  CGContextDrawLinearGradient(FCtx, grad,
    CGPointMake(cx - dx*gl/2, cy - dy*gl/2),
    CGPointMake(cx + dx*gl/2, cy + dy*gl/2), 3);  // extend both ends
  CGContextRestoreGState(FCtx);
  CGGradientRelease(grad);
end;

procedure TIOSCanvas.FillRadialGradient(X, Y, W, H, Radius: Single;
  const Colors: array of TTina4Color; const Positions: array of Single);
var
  grad: CGGradientRef;
  comps, locs: array of Double;
  i, n: Integer;
  cx, cy, r: Double;
begin
  n := Length(Colors); if n = 0 then Exit;
  SetLength(comps, n * 4); SetLength(locs, n);
  for i := 0 to n - 1 do
  begin
    comps[i*4]   := ((Colors[i] shr 16) and $FF) / 255;
    comps[i*4+1] := ((Colors[i] shr 8) and $FF) / 255;
    comps[i*4+2] := (Colors[i] and $FF) / 255;
    comps[i*4+3] := ((Colors[i] shr 24) and $FF) / 255;
    if (i < Length(Positions)) and (Positions[i] >= 0) then locs[i] := Positions[i]
    else if n > 1 then locs[i] := i / (n - 1) else locs[i] := 0;
    if (i > 0) and (locs[i] < locs[i-1]) then locs[i] := locs[i-1];
  end;
  grad := CGGradientCreateWithColorComponents(FSpace, @comps[0], @locs[0], n);
  if grad = nil then Exit;
  CGContextSaveGState(FCtx);
  RRectPath(X, Y, W, H, Radius); CGContextClip(FCtx);
  cx := X + W/2; cy := Y + H/2; r := Sqrt(Sqr(W/2) + Sqr(H/2));  // farthest corner
  CGContextDrawRadialGradient(FCtx, grad, CGPointMake(cx, cy), 0,
    CGPointMake(cx, cy), r, 3);
  CGContextRestoreGState(FCtx);
  CGGradientRelease(grad);
end;

{ ---- images (Core Graphics + Image I/O) -------------------------------- }

{ Where a remote image is cached on disk (app sandbox, survives relaunches). }
function IOSImageCachePath(const Src: string): string;
var dir: string;
begin
  dir := GetEnvironmentVariable('HOME') + '/Library/Caches/tina4render/';
  ForceDirectories(dir);
  Result := dir + MD5Print(MD5String(Src)) + '.img';
end;

function TIOSCanvas.LoadImage(const Src: string): Integer;
var
  i: Integer; localPath: string; lower: string;
  url: CFURLRef; isrc: CGImageSourceRef; img: CGImageRef;
begin
  Result := -1;
  if Src = '' then Exit;
  for i := 0 to High(FImgSrcs) do
    if FImgSrcs[i] = Src then Exit(i);       // decoded, in-memory (instant re-render)

  lower := LowerCase(Src);
  if (Pos('http://', lower) = 1) or (Pos('https://', lower) = 1) then
  begin
    localPath := IOSImageCachePath(Src);
    if not FileExists(localPath) then
    begin
      // not downloaded yet — kick off the async native-TLS fetch and bail.
      // NOT cached as a failure, so the next relayout (after tina4_image_ready)
      // re-runs this and decodes the now-present file.
      tina4_ios_fetch_image(PAnsiChar(Src), PAnsiChar(localPath));
      Exit;
    end;
  end
  else if (Length(Src) > 0) and (Src[1] = '/') then
    localPath := Src                         // absolute file path
  else if FAssetBase <> '' then
    localPath := FAssetBase + '/' + Src      // relative → bundled app resource
  else
    localPath := Src;                        // local file / data path

  url := CFURLCreateFromFileSystemRepresentation(nil, PAnsiChar(localPath),
    Length(localPath), False);
  if url = nil then Exit;
  isrc := CGImageSourceCreateWithURL(url, nil);
  CFRelease(url);
  if isrc = nil then Exit;
  img := CGImageSourceCreateImageAtIndex(isrc, 0, nil);
  CFRelease(isrc);
  if img = nil then Exit;
  i := Length(FImgs);
  SetLength(FImgs, i + 1);
  SetLength(FImgSrcs, i + 1);
  FImgs[i].Img := img;
  FImgs[i].W := CGImageGetWidth(img);
  FImgs[i].H := CGImageGetHeight(img);
  FImgSrcs[i] := Src;                         // key by the ORIGINAL src
  Result := i;
end;

{ Where a downloaded font is cached on disk (app sandbox, survives relaunches). }
function IOSFontCachePath(const Src: string): string;
var dir: string;
begin
  dir := GetEnvironmentVariable('HOME') + '/Library/Caches/tina4render/';
  ForceDirectories(dir);
  Result := dir + MD5Print(MD5String(Src)) + '.font';
end;

{ @font-face: register a font under the CSS `Family`. `Src` is a local path or
  an http(s) URL. A URL is fetched async (reusing the native-TLS image loader,
  which relayouts on completion); until the file lands we return False, and the
  next relayout re-runs this with the file present. Once local we register the
  face via the CoreGraphics font path (the URL/descriptor APIs are macOS-only —
  __IPHONE_NA), then alias the CSS family to its PostScript name so
  CTFontCreateWithName resolves it. }
function TIOSCanvas.RegisterFont(const Family, Src: string): Boolean;
var
  localPath, lower, actual: string;
  provider: CGDataProviderRef;
  cgFont: CGFontRef;
  err: CFErrorRef;
  nameRef: CFStringRef;
  buf: array[0..255] of AnsiChar;
begin
  Result := False;
  if (Trim(Family) = '') or (Trim(Src) = '') then Exit;
  lower := LowerCase(Src);
  if (Pos('http://', lower) = 1) or (Pos('https://', lower) = 1) then
  begin
    localPath := IOSFontCachePath(Src);
    if not FileExists(localPath) then
    begin
      tina4_ios_fetch_image(PAnsiChar(Src), PAnsiChar(localPath)); // async fetch
      Exit;                                    // not ready — relayout will retry
    end;
  end
  else if FileExists(Src) then
    localPath := Src
  else
    Exit;

  provider := CGDataProviderCreateWithFilename(PAnsiChar(localPath));
  if provider = nil then Exit;
  cgFont := CGFontCreateWithDataProvider(provider);
  CGDataProviderRelease(provider);
  if cgFont = nil then Exit;
  try
    err := nil;
    CTFontManagerRegisterGraphicsFont(cgFont, err);   // process-wide

    actual := '';
    nameRef := CGFontCopyPostScriptName(cgFont);
    if nameRef <> nil then
    begin
      if CFStringGetCString(nameRef, buf, SizeOf(buf), kCFStringEncodingUTF8) then
        actual := string(buf);
      CFRelease(nameRef);
    end;
    if actual <> '' then
    begin
      FontAliasMap.Values[LowerCase(Trim(Family))] := actual;
      Result := True;
    end;
  finally
    CGFontRelease(cgFont);
  end;
end;

function TIOSCanvas.ImageSize(Handle: Integer; out W, H: Single): Boolean;
begin
  Result := (Handle >= 0) and (Handle < Length(FImgs));
  if Result then begin W := FImgs[Handle].W; H := FImgs[Handle].H; end
  else begin W := 0; H := 0; end;
end;

procedure TIOSCanvas.DrawImage(Handle: Integer; X, Y, W, H: Single);
begin
  if (Handle < 0) or (Handle >= Length(FImgs)) then Exit;
  // CGContextDrawImage assumes y-up; flip locally so the bitmap is upright.
  CGContextSaveGState(FCtx);
  CGContextTranslateCTM(FCtx, X, Y + H);
  CGContextScaleCTM(FCtx, 1, -1);
  CGContextDrawImage(FCtx, R(0, 0, W, H), FImgs[Handle].Img);
  CGContextRestoreGState(FCtx);
end;

{ ---- offscreen filter / blend / 3D compositing (shared Tina4Compositor) ---- }

function TIOSCanvas.BeginLayer(X, Y, W, H, Pad: Single): Integer;
var ox, oy, bw, bh, sc: Single; pw, ph, n: Integer; bctx: CGContextRef; ctm: CGAffineTransform;
begin
  ox := X - Pad; oy := Y - Pad; bw := W + 2 * Pad; bh := H + 2 * Pad;
  if (bw <= 0) or (bh <= 0) then Exit(-1);
  ctm := CGContextGetCTM(FCtx);
  sc := Abs(ctm.a); if sc <= 0 then sc := 1;   // device px per point
  pw := Round(bw * sc); ph := Round(bh * sc);
  bctx := CGBitmapContextCreate(nil, pw, ph, 8, pw * 4, FSpace, kCGImageAlphaPremultipliedLast);
  if bctx = nil then Exit(-1);
  // y-down in point space, origin at the box top-left (matches the view context)
  CGContextTranslateCTM(bctx, 0, ph);
  CGContextScaleCTM(bctx, sc, -sc);
  CGContextTranslateCTM(bctx, -ox, -oy);
  n := Length(FLayers); SetLength(FLayers, n + 1);
  FLayers[n].Ctx := bctx; FLayers[n].Saved := FCtx;
  FLayers[n].ox := ox; FLayers[n].oy := oy; FLayers[n].w := bw; FLayers[n].h := bh; FLayers[n].sc := sc;
  FCtx := bctx;                 // redirect all drawing into the layer
  Result := n;
end;

procedure TIOSCanvas.EndLayerFiltered(Handle: Integer; const FilterSpec, BlendMode, MaskSpec: string);
var
  bctx: CGContextRef; ox, oy, bw, bh, sc: Single; pw, ph, i: Integer;
  data: PByte; buf: PSingle; img: CGImageRef; v: Single;
begin
  if (Handle < 0) or (Handle > High(FLayers)) then Exit;
  bctx := FLayers[Handle].Ctx;
  ox := FLayers[Handle].ox; oy := FLayers[Handle].oy;
  bw := FLayers[Handle].w; bh := FLayers[Handle].h; sc := FLayers[Handle].sc;
  FCtx := FLayers[Handle].Saved;    // restore the view context
  data := PByte(CGBitmapContextGetData(bctx));
  pw := CGBitmapContextGetWidth(bctx); ph := CGBitmapContextGetHeight(bctx);
  if (data <> nil) and ((FilterSpec <> '') or (MaskSpec <> '')) then
  begin
    GetMem(buf, pw * ph * 4 * SizeOf(Single));
    for i := 0 to pw * ph * 4 - 1 do buf[i] := data[i] / 255;   // 8-bit premult → Single
    ApplyFilterChainF(PSingleBuf(buf), pw, ph, FilterSpec, MaskSpec, sc);
    for i := 0 to pw * ph * 4 - 1 do
    begin v := buf[i]; if v < 0 then v := 0; if v > 1 then v := 1; data[i] := Round(v * 255); end;
    FreeMem(buf);
  end;
  img := CGBitmapContextCreateImage(bctx);
  if img <> nil then
  begin
    CGContextSaveGState(FCtx);
    if BlendMode <> '' then CGContextSetBlendMode(FCtx, CGBlendForMode(LowerCase(BlendMode)));
    CGContextTranslateCTM(FCtx, ox, oy + bh);   // upright y-down blit
    CGContextScaleCTM(FCtx, 1, -1);
    CGContextDrawImage(FCtx, R(0, 0, bw, bh), img);
    CGContextRestoreGState(FCtx);
    CGImageRelease(img);
  end;
  CGContextRelease(bctx);
  SetLength(FLayers, Handle);
end;

procedure TIOSCanvas.EndLayer3D(Handle: Integer; const Corners: array of Single);
var
  bctx, tmp: CGContextRef; ox, oy, bw, bh, sc, minx, miny, maxx, maxy: Single;
  pw, ph, dpw, dph, i: Integer; data, dst: PByte; src: PSingle; img: CGImageRef;
  quad: array[0..7] of Single;
begin
  if (Handle < 0) or (Handle > High(FLayers)) then Exit;
  bctx := FLayers[Handle].Ctx; sc := FLayers[Handle].sc;
  ox := FLayers[Handle].ox; oy := FLayers[Handle].oy; bw := FLayers[Handle].w; bh := FLayers[Handle].h;
  FCtx := FLayers[Handle].Saved;
  data := PByte(CGBitmapContextGetData(bctx));
  pw := CGBitmapContextGetWidth(bctx); ph := CGBitmapContextGetHeight(bctx);
  if data <> nil then
  begin
    GetMem(src, pw * ph * 4 * SizeOf(Single));
    for i := 0 to pw * ph * 4 - 1 do src[i] := data[i] / 255;   // premult 8-bit → Single
    minx := Corners[0]; maxx := Corners[0]; miny := Corners[1]; maxy := Corners[1];
    for i := 1 to 3 do
    begin
      if Corners[i*2]   < minx then minx := Corners[i*2];
      if Corners[i*2]   > maxx then maxx := Corners[i*2];
      if Corners[i*2+1] < miny then miny := Corners[i*2+1];
      if Corners[i*2+1] > maxy then maxy := Corners[i*2+1];
    end;
    dpw := Round((maxx - minx) * sc); dph := Round((maxy - miny) * sc);
    if (dpw > 0) and (dph > 0) then
    begin
      for i := 0 to 3 do
      begin quad[i*2] := (Corners[i*2] - minx) * sc; quad[i*2+1] := (Corners[i*2+1] - miny) * sc; end;
      GetMem(dst, dpw * dph * 4); FillChar(dst^, dpw * dph * 4, 0);
      WarpQuad(PSingleBuf(src), pw, ph, quad, dst, dpw, dph);
      tmp := CGBitmapContextCreate(dst, dpw, dph, 8, dpw * 4, FSpace, kCGImageAlphaPremultipliedLast);
      if tmp <> nil then
      begin
        img := CGBitmapContextCreateImage(tmp);
        if img <> nil then
        begin
          CGContextSaveGState(FCtx);
          CGContextTranslateCTM(FCtx, minx, miny + (maxy - miny));
          CGContextScaleCTM(FCtx, 1, -1);
          CGContextDrawImage(FCtx, R(0, 0, maxx - minx, maxy - miny), img);
          CGContextRestoreGState(FCtx);
          CGImageRelease(img);
        end;
        CGContextRelease(tmp);
      end;
      FreeMem(dst);
    end;
    FreeMem(src);
  end;
  CGContextRelease(bctx);
  SetLength(FLayers, Handle);
end;

finalization
  GFontAlias.Free;
end.
