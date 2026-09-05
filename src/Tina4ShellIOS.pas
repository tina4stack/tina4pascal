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
  CFBase, CFString, CFAttributedString, CFDictionary, CFURL,
  CGBase, CGContext, CGColor, CGColorSpace, CGGeometry, CGPath,
  CGImage, CGImageSource, CGAffineTransforms,
  CTFont, CTLine, CTStringAttributes,
  Tina4RenderBackend;

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
    function MakeColor(Color: TTina4Color): CGColorRef;
    function MakeFont(FontSize: Single; Styles: TTina4FontStyles): CTFontRef;
    function MakeLine(const Text: string; FontSize: Single;
      Styles: TTina4FontStyles; Color: TTina4Color): CTLineRef;
    procedure RRectPath(X, Y, W, H, Radius: Single);
  public
    constructor Create;
    destructor Destroy; override;
    procedure BeginFrame(Ctx: CGContextRef);
    procedure FillRect(X, Y, W, H: Single; Color: TTina4Color); override;
    procedure StrokeRect(X, Y, W, H, Thickness: Single; Color: TTina4Color); override;
    procedure FillRoundRect(X, Y, W, H, Radius: Single; Color: TTina4Color); override;
    procedure StrokeRoundRect(X, Y, W, H, Radius, Thickness: Single; Color: TTina4Color); override;
    procedure DrawLine(X1, Y1, X2, Y2, Thickness: Single; Color: TTina4Color); override;
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
    function LoadImage(const Src: string): Integer; override;
    function ImageSize(Handle: Integer; out W, H: Single): Boolean; override;
    procedure DrawImage(Handle: Integer; X, Y, W, H: Single); override;
  end;

implementation

uses SysUtils, md5;

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

function TIOSCanvas.MakeFont(FontSize: Single; Styles: TTina4FontStyles): CTFontRef;
var name: string; cf: CFStringRef;
begin
  if (tfsBold in Styles) and (tfsItalic in Styles) then name := 'Helvetica-BoldOblique'
  else if tfsBold in Styles then name := 'Helvetica-Bold'
  else if tfsItalic in Styles then name := 'Helvetica-Oblique'
  else name := 'Helvetica';
  cf := CFStr(name);
  Result := CTFontCreateWithName(cf, FontSize, nil);
  CFRelease(cf);
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

end.
