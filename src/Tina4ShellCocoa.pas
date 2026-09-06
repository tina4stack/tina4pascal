unit Tina4ShellCocoa;

{ macOS shell for the Tina4 native renderer: NSWindow + flipped NSView,
  text via AppKit string drawing. Pure FPC Objective-Pascal (CocoaAll),
  no Lazarus/LCL. See ARCHITECTURE.md. }

{$mode delphi}{$H+}
{$modeswitch objectivec1}

interface

uses
  { NOTE: do not instantiate generics (TList<>/TDictionary<>) with objcclass
    types — FPC 3.2.2/aarch64 dies with Internal error 2009092303. Plain
    TList/TStringList are used for the image store instead. }
  SysUtils, Classes, MD5, CocoaAll, MacOSAll, AVKit, AVFoundation, CTFontManager,
  CTFontDescriptor, CFBase, CFURL, CFArray, CFString, CFError, Tina4RenderBackend,
  Tina4Compositor;

type
  TCocoaShell = class;

  { one entry of the offscreen filter/blend layer stack }
  TLayerRec = record
    rep: NSBitmapImageRep;   // pixel buffer being drawn into
    ctx: NSGraphicsContext;  // graphics context wrapping rep (pushed as current)
    ox, oy, w, h: Single;    // doc-space origin + logical size of the buffer
  end;

  TCocoaCanvas = class(TTina4Canvas)
  private
    FImages: TList;                   // handle -> NSImage (retained, as Pointer)
    FImageBySrc: TStringList;         // src -> handle in Objects[] (sorted)
    FLayers: array of TLayerRec;      // offscreen compositing stack
    function FontFor(FontSize: Single; Styles: TTina4FontStyles): NSFont;
    function AttrsFor(FontSize: Single; Styles: TTina4FontStyles;
      Color: TTina4Color): NSDictionary;
  public
    constructor Create;
    destructor Destroy; override;
    function LoadImage(const Src: string): Integer; override;
    function RegisterFont(const Family, Src: string): Boolean; override;
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
    procedure FillSoftShadow(X, Y, W, H, Radius, Blur: Single; Color: TTina4Color); override;
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
    procedure Translate(DX, DY: Single); override;
    procedure Rotate(Degrees: Single); override;
    procedure Scale(SX, SY: Single); override;
    procedure Skew(AngleXDeg, AngleYDeg: Single); override;
    procedure TransformMatrix(A, B, C, D, E, F: Single); override;
    procedure ClipPolygon(const Pts: TTina4PointArray); override;
    function BeginLayer(X, Y, W, H, Pad: Single): Integer; override;
    procedure EndLayerFiltered(Handle: Integer; const FilterSpec, BlendMode, MaskSpec: string); override;
    procedure BackdropFilter(X, Y, W, H: Single; const FilterSpec: string); override;
    procedure EndLayer3D(Handle: Integer; const Corners: array of Single); override;
  end;

  { NSTimer target bridging into the shell's OnTick }
  TTina4Ticker = objcclass(NSObject)
  public
    shell: TCocoaShell;
    procedure tick(t: NSTimer); message 'tick:';
  end;

  { NSView subclass forwarding everything to the shell }
  TTina4View = objcclass(NSView)
  public
    shell: TCocoaShell;
    function isFlipped: ObjCBOOL; override;
    function acceptsFirstResponder: ObjCBOOL; override;
    procedure drawRect(dirtyRect: NSRect); override;
    procedure mouseDown(event: NSEvent); override;
    procedure mouseUp(event: NSEvent); override;
    procedure mouseMoved(event: NSEvent); override;
    procedure mouseDragged(event: NSEvent); override;
    procedure scrollWheel(event: NSEvent); override;
    procedure keyDown(event: NSEvent); override;
    { NSWindowDelegate: closing the window quits the app (no lingering process). }
    procedure windowWillClose(notification: NSNotification); message 'windowWillClose:';
  end;

  TCocoaShell = class(TTina4Shell)
  private
    FWindow: NSWindow;
    FView: TTina4View;
    FCanvas: TCocoaCanvas;
    FCursor: TTina4Cursor;    // last-set cursor (avoid re-setting every move)
    FCursorHidden: Boolean;   // cursor:none hide/unhide is stacked — track it
  public
    { When non-empty, the next completed paint is written to this PNG path
      (then cleared). Seed of the headless render-to-image mode. }
    SnapshotPath: string;
    { Automation mode: no visible window, no Dock icon, no focus steal. Set
      before Initialize by headless callers (--snapshot / --script). }
    Headless: Boolean;
    destructor Destroy; override;
    { Render the current document straight to a PNG off-screen (no window
      shown, no run loop needed). Used by --snapshot and the reftest driver. }
    procedure Snapshot(const Path: string);
    procedure Initialize(Width, Height: Integer; const Title: string); override;
    procedure Invalidate; override;
    procedure Run; override;
    procedure Quit; override;
    procedure SetTitle(const Title: string); override;
    procedure SetCursor(C: TTina4Cursor); override;
    procedure Notify(const Title, Body, Tag: string); override;
    function FetchToFile(const Url, DestPath: string): Boolean; override;
    procedure StartTicker(IntervalMs: Integer); override;
    function PickFile: string; override;
    function CaptureCamera: string; override;
    function GetMeasuringCanvas: TTina4Canvas; override;
  end;

implementation

uses
  Tina4Interact;   // native media embeds (<video>) query — TinaEmbed*

var
  { @font-face aliases: CSS family (lowercased) -> the font's real registered
    name. Process-global because CoreText registration is process-wide and the
    measuring + paint canvases are distinct instances. }
  GFontAlias: TStringList = nil;
  { native <video> overlays, keyed by source URL (NSString -> AVPlayerView) }
  GVideoViews: NSMutableDictionary = nil;

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

function NSColorOf(C: TTina4Color): NSColor;
begin
  { sRGB, NOT calibrated/generic RGB — calibrated maps e.g. 128 to ~146 when
    captured into the sRGB snapshot bitmap. sRGB keeps CSS values exact. }
  Result := NSColor.colorWithSRGBRed_green_blue_alpha(
    ((C shr 16) and $FF) / 255.0,
    ((C shr 8) and $FF) / 255.0,
    (C and $FF) / 255.0,
    ((C shr 24) and $FF) / 255.0);
end;

function NSStr(const S: string): NSString;
begin
  { Strings in this stack are already UTF-8 (see Tina4HTMLDom header) —
    do NOT UTF8Encode again or multibyte chars double-encode into mojibake. }
  Result := NSString.stringWithUTF8String(PAnsiChar(S));
end;

{ TCocoaCanvas }

constructor TCocoaCanvas.Create;
begin
  FImages := TList.Create;
  FImageBySrc := TStringList.Create;
  FImageBySrc.Sorted := True;
end;

destructor TCocoaCanvas.Destroy;
var
  i: Integer;
begin
  for i := 0 to FImages.Count - 1 do
    if FImages[i] <> nil then NSImage(FImages[i]).release;
  FImages.Free;
  FImageBySrc.Free;
  inherited;
end;

{ Register a font for @font-face. Src may be a local path or an http(s) URL
  (fetched + disk-cached exactly like an <img>). After CoreText registers the
  file we read back the font's real family name and alias the CSS `Family` to
  it, since the two frequently differ (e.g. "Inter" vs "Inter 18pt"). }
function TCocoaCanvas.RegisterFont(const Family, Src: string): Boolean;
var
  data: NSData;
  cacheDir, cacheFile, path: string;
  url: CFURLRef;
  err: CFErrorRef;
  descs: CFArrayRef;
  desc: CTFontDescriptorRef;
  nameRef: CFTypeRef;
  actual: string;
begin
  Result := False;
  path := '';
  if (Pos('http://', LowerCase(Src)) = 1) or (Pos('https://', LowerCase(Src)) = 1) then
  begin
    cacheDir := GetEnvironmentVariable('HOME') + '/.cache/tina4render/';
    ForceDirectories(cacheDir);
    cacheFile := cacheDir + MD5Print(MD5String(Src)) + '.font';
    if not FileExists(cacheFile) then
    begin
      data := NSData.dataWithContentsOfURL(NSURL.URLWithString(NSStr(Src)));
      if (data <> nil) and (data.length > 0) then
        data.writeToFile_atomically(NSStr(cacheFile), True);
    end;
    if FileExists(cacheFile) then path := cacheFile;
  end
  else if FileExists(Src) then
    path := Src;
  if path = '' then Exit;

  url := CFURLCreateWithFileSystemPath(nil, CFStringRef(NSStr(path)),
    kCFURLPOSIXPathStyle, False);
  if url = nil then Exit;
  try
    err := nil;
    // Idempotent enough for our use: a re-register of the same URL just fails
    // harmlessly; we still resolve the actual family name below.
    CTFontManagerRegisterFontsForURL(url, kCTFontManagerScopeProcess, err);

    // Read the font's real family name so FontFor can map the CSS name to it.
    actual := '';
    descs := CTFontManagerCreateFontDescriptorsFromURL(url);
    if descs <> nil then
    begin
      if CFArrayGetCount(descs) > 0 then
      begin
        desc := CTFontDescriptorRef(CFArrayGetValueAtIndex(descs, 0));
        nameRef := CTFontDescriptorCopyAttribute(desc, kCTFontFamilyNameAttribute);
        if nameRef <> nil then
        begin
          actual := string(NSString(nameRef).UTF8String);
          CFRelease(nameRef);
        end;
      end;
      CFRelease(descs);
    end;
    if actual <> '' then
    begin
      FontAliasMap.Values[LowerCase(Trim(Family))] := actual;
      Result := True;
    end;
  finally
    CFRelease(url);
  end;
end;

function TCocoaCanvas.LoadImage(const Src: string): Integer;
var
  data: NSData;
  img: NSImage;
  cacheDir, cacheFile: string;
  idx: Integer;
begin
  if FImageBySrc.Find(Src, idx) then
    Exit(Integer(PtrInt(FImageBySrc.Objects[idx])));
  Result := -1;
  data := nil;
  if Pos('data:', LowerCase(Src)) = 1 then
  begin
    // data: URI — decode the base64 payload after the comma (self-contained
    // images, common in CSS background-image and small icons).
    idx := Pos(',', Src);
    if idx > 0 then
      data := NSData.alloc.initWithBase64EncodedString_options(
        NSStr(Copy(Src, idx + 1, MaxInt)),
        NSDataBase64DecodingIgnoreUnknownCharacters).autorelease;
  end
  else if (Pos('http://', LowerCase(Src)) = 1) or (Pos('https://', LowerCase(Src)) = 1) then
  begin
    cacheDir := GetEnvironmentVariable('HOME') + '/.cache/tina4render/';
    ForceDirectories(cacheDir);
    cacheFile := cacheDir + MD5Print(MD5String(Src)) + '.img';
    if FileExists(cacheFile) then
      data := NSData.dataWithContentsOfFile(NSStr(cacheFile))
    else
    begin
      // Foundation handles TLS + redirects; synchronous convenience API.
      data := NSData.dataWithContentsOfURL(NSURL.URLWithString(NSStr(Src)));
      if (data <> nil) and (data.length > 0) then
        data.writeToFile_atomically(NSStr(cacheFile), True);
    end;
  end
  else if FileExists(Src) then
    data := NSData.dataWithContentsOfFile(NSStr(Src));
  if (data = nil) or (data.length = 0) then
  begin
    FImageBySrc.AddObject(Src, TObject(PtrInt(-1))); // cache the failure
    Exit;
  end;
  img := NSImage.alloc.initWithData(data);
  if img = nil then
  begin
    // Native decode failed (e.g. WebP on older macOS) — try the base class's
    // pure-Pascal decoder, which renders via DrawRGBA.
    Result := inherited LoadImage(Src);
    FImageBySrc.AddObject(Src, TObject(PtrInt(Result)));
    Exit;
  end;
  FImages.Add(img);
  Result := FImages.Count - 1;
  FImageBySrc.AddObject(Src, TObject(PtrInt(Result)));
end;

function TCocoaCanvas.ImageSize(Handle: Integer; out W, H: Single): Boolean;
var
  sz: NSSize;
begin
  W := 0; H := 0;
  if Handle >= WEBP_HANDLE_BASE then Exit(inherited ImageSize(Handle, W, H));
  Result := (Handle >= 0) and (Handle < FImages.Count) and (FImages[Handle] <> nil);
  if Result then
  begin
    sz := NSImage(FImages[Handle]).size;
    W := sz.width; H := sz.height;
  end;
end;

procedure TCocoaCanvas.DrawImage(Handle: Integer; X, Y, W, H: Single);
begin
  if Handle >= WEBP_HANDLE_BASE then begin inherited DrawImage(Handle, X, Y, W, H); Exit; end;
  if (Handle < 0) or (Handle >= FImages.Count) or (FImages[Handle] = nil) then Exit;
  NSImage(FImages[Handle]).drawInRect_fromRect_operation_fraction_respectFlipped_hints(
    NSMakeRect(X, Y, W, H), NSZeroRect, NSCompositeSourceOver, 1.0, True, nil);
end;

{ Map a CSS numeric weight (100..900) to an NSFontManager weight class
  (1=thin … 5=regular … 9=bold … 15=black). }
function CSSWeightToMgr(w: Integer): Integer;
begin
  if w <= 100 then Result := 2
  else if w <= 200 then Result := 3
  else if w <= 300 then Result := 4
  else if w <= 400 then Result := 5
  else if w <= 500 then Result := 6
  else if w <= 600 then Result := 8
  else if w <= 700 then Result := 9
  else if w <= 800 then Result := 11
  else Result := 13;
end;

{ Step a font toward a target NSFontManager weight class via convertWeight. }
function ApplyWeight(f: NSFont; targetMgr: Integer): NSFont;
var fm: NSFontManager; cur, guard: Integer;
begin
  Result := f;
  fm := NSFontManager.sharedFontManager;
  cur := 5;  // system regular ≈ class 5
  guard := 0;
  while (cur < targetMgr) and (guard < 10) do
  begin Result := fm.convertWeight_ofFont(True, Result); Inc(cur); Inc(guard); end;
  while (cur > targetMgr) and (guard < 20) do
  begin Result := fm.convertWeight_ofFont(False, Result); Dec(cur); Inc(guard); end;
end;

function TCocoaCanvas.FontFor(FontSize: Single; Styles: TTina4FontStyles): NSFont;
var
  fm: NSFontManager;
  fam, cand: string; parts: TStringArray; k, w: Integer; f: NSFont;
begin
  Result := nil;
  w := FontWeight; if w = 0 then w := 400;
  if (tfsBold in Styles) and (w < 700) then w := 700;   // bold flag ⇒ ≥700
  // Resolve the CSS font-family stack: first candidate that names a real font
  // (a system generic, or a face installed / registered via @font-face) wins.
  fam := Trim(FontFamily);
  if fam <> '' then
  begin
    parts := fam.Split([',']);
    for k := 0 to High(parts) do
    begin
      cand := Trim(parts[k]).DeQuotedString('"').DeQuotedString('''');
      cand := Trim(cand);
      if cand = '' then Continue;
      // @font-face: map the CSS family to the font's real registered name.
      if FontAliasMap.IndexOfName(LowerCase(cand)) >= 0 then
        cand := FontAliasMap.Values[LowerCase(cand)];
      if SameText(cand, 'system-ui') or SameText(cand, '-apple-system')
         or SameText(cand, 'sans-serif') then
        Break   // fall through to the system font below
      else if SameText(cand, 'serif') then
        f := NSFont.fontWithName_size(NSStr('Times New Roman'), FontSize)
      else if SameText(cand, 'monospace') then
        f := NSFont.fontWithName_size(NSStr('Menlo'), FontSize)
      else
        f := NSFont.fontWithName_size(NSStr(cand), FontSize);   // named/registered
      if f <> nil then begin Result := f; Break; end;
    end;
  end;
  // San Francisco system font — what browsers resolve -apple-system / system-ui
  // to on macOS, so metrics track Chrome closely.
  if Result = nil then
    // system font stepped to the numeric weight (San Francisco covers the range)
    Result := ApplyWeight(NSFont.systemFontOfSize(FontSize), CSSWeightToMgr(w))
  else if w >= 600 then
  begin
    fm := NSFontManager.sharedFontManager;
    Result := fm.convertFont_toHaveTrait(Result, NSBoldFontMask);
  end;
  if tfsItalic in Styles then
  begin
    fm := NSFontManager.sharedFontManager;
    Result := fm.convertFont_toHaveTrait(Result, NSItalicFontMask);
  end;
end;

function TCocoaCanvas.AttrsFor(FontSize: Single; Styles: TTina4FontStyles;
  Color: TTina4Color): NSDictionary;
var
  keys: array[0..4] of Pointer;
  vals: array[0..4] of Pointer;
  n: Integer;
begin
  keys[0] := Pointer(NSFontAttributeName);
  vals[0] := Pointer(FontFor(FontSize, Styles));
  keys[1] := Pointer(NSForegroundColorAttributeName);
  vals[1] := Pointer(NSColorOf(Color));
  n := 2;
  if tfsUnderline in Styles then
  begin
    keys[n] := Pointer(NSUnderlineStyleAttributeName);
    vals[n] := Pointer(NSNumber.numberWithInt(NSUnderlineStyleSingle));
    Inc(n);
  end;
  if tfsStrike in Styles then
  begin
    keys[n] := Pointer(NSStrikethroughStyleAttributeName);
    vals[n] := Pointer(NSNumber.numberWithInt(NSUnderlineStyleSingle));
    Inc(n);
  end;
  if LetterSpacing <> 0 then
  begin
    keys[n] := Pointer(NSKernAttributeName);
    vals[n] := Pointer(NSNumber.numberWithDouble(LetterSpacing));
    Inc(n);
  end;
  Result := NSDictionary.dictionaryWithObjects_forKeys_count(@vals[0], @keys[0], n);
end;

procedure TCocoaCanvas.FillRect(X, Y, W, H: Single; Color: TTina4Color);
begin
  NSColorOf(Color).setFill;
  NSRectFillUsingOperation(NSMakeRect(X, Y, W, H), NSCompositeSourceOver);
end;

procedure TCocoaCanvas.StrokeRect(X, Y, W, H, Thickness: Single; Color: TTina4Color);
var
  p: NSBezierPath;
begin
  NSColorOf(Color).setStroke;
  p := NSBezierPath.bezierPathWithRect(NSMakeRect(X + Thickness / 2, Y + Thickness / 2,
    W - Thickness, H - Thickness));
  p.setLineWidth(Thickness);
  p.stroke;
end;

procedure TCocoaCanvas.FillRoundRect(X, Y, W, H, Radius: Single; Color: TTina4Color);
begin
  // a corner radius can't exceed half the shorter side (pill = radius >= H/2)
  if Radius > W / 2 then Radius := W / 2;
  if Radius > H / 2 then Radius := H / 2;
  NSColorOf(Color).setFill;
  NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius(
    NSMakeRect(X, Y, W, H), Radius, Radius).fill;
end;

procedure TCocoaCanvas.StrokeRoundRect(X, Y, W, H, Radius, Thickness: Single; Color: TTina4Color);
var
  p: NSBezierPath;
begin
  if Radius > W / 2 then Radius := W / 2;
  if Radius > H / 2 then Radius := H / 2;
  NSColorOf(Color).setStroke;
  p := NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius(
    NSMakeRect(X + Thickness / 2, Y + Thickness / 2, W - Thickness, H - Thickness),
    Radius, Radius);
  p.setLineWidth(Thickness);
  p.stroke;
end;

function BuildNSGradient(const Colors: array of TTina4Color;
  const Positions: array of Single): NSGradient;
var
  arr: NSMutableArray;
  locs: array of Double;
  i, n: Integer;
begin
  n := Length(Colors);
  arr := NSMutableArray.arrayWithCapacity(n);
  SetLength(locs, n);
  for i := 0 to n - 1 do
  begin
    arr.addObject(NSColorOf(Colors[i]));
    if (i < Length(Positions)) and (Positions[i] >= 0) then locs[i] := Positions[i]
    else if n > 1 then locs[i] := i / (n - 1)
    else locs[i] := 0;
    if (i > 0) and (locs[i] < locs[i - 1]) then locs[i] := locs[i - 1]; // monotonic
  end;
  Result := NSGradient(NSGradient.alloc).initWithColors_atLocations_colorSpace(
    arr, @locs[0], NSColorSpace.sRGBColorSpace);
end;

procedure TCocoaCanvas.FillLinearGradient(X, Y, W, H, Radius, AngleDeg: Single;
  const Colors: array of TTina4Color; const Positions: array of Single);
var
  grad: NSGradient;
  path: NSBezierPath;
  a, dx, dy, gradLen, cx, cy: Double;
begin
  if Length(Colors) = 0 then Exit;
  if Radius > W / 2 then Radius := W / 2;
  if Radius > H / 2 then Radius := H / 2;
  grad := BuildNSGradient(Colors, Positions);
  if grad = nil then Exit;
  NSGraphicsContext.currentContext.saveGraphicsState;
  path := NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius(
    NSMakeRect(X, Y, W, H), Radius, Radius);
  path.addClip;
  // CSS angle: 0=up, 90=right. Flipped view is y-down, matching CSS.
  a := AngleDeg * Pi / 180;
  dx := Sin(a); dy := -Cos(a);
  gradLen := Abs(W * Sin(a)) + Abs(H * Cos(a));
  cx := X + W / 2; cy := Y + H / 2;
  grad.drawFromPoint_toPoint_options(
    NSMakePoint(cx - dx * gradLen / 2, cy - dy * gradLen / 2),
    NSMakePoint(cx + dx * gradLen / 2, cy + dy * gradLen / 2), 0);
  NSGraphicsContext.currentContext.restoreGraphicsState;
  grad.release;
end;

procedure TCocoaCanvas.FillRadialGradient(X, Y, W, H, Radius: Single;
  const Colors: array of TTina4Color; const Positions: array of Single);
var
  grad: NSGradient;
  path: NSBezierPath;
begin
  if Length(Colors) = 0 then Exit;
  if Radius > W / 2 then Radius := W / 2;
  if Radius > H / 2 then Radius := H / 2;
  grad := BuildNSGradient(Colors, Positions);
  if grad = nil then Exit;
  NSGraphicsContext.currentContext.saveGraphicsState;
  path := NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius(
    NSMakeRect(X, Y, W, H), Radius, Radius);
  path.addClip;
  grad.drawInBezierPath_relativeCenterPosition(path, NSMakePoint(0, 0));
  NSGraphicsContext.currentContext.restoreGraphicsState;
  grad.release;
end;

procedure TCocoaCanvas.FillSoftShadow(X, Y, W, H, Radius, Blur: Single; Color: TTina4Color);
var
  sh: NSShadow;
  path: NSBezierPath;
begin
  if Radius > W / 2 then Radius := W / 2;
  if Radius > H / 2 then Radius := H / 2;
  NSGraphicsContext.currentContext.saveGraphicsState;
  sh := NSShadow(NSShadow.alloc.init).autorelease;
  sh.setShadowBlurRadius(Blur);
  sh.setShadowOffset(NSMakeSize(0, 0));   // offset already baked into X,Y
  sh.setShadowColor(NSColorOf(Color));
  sh.set_;
  // draw the shape in the shadow colour; NSShadow blurs what we paint. Painting
  // slightly outside the visible area is fine — the blur is what shows.
  NSColorOf(Color).setFill;
  path := NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius(
    NSMakeRect(X, Y, W, H), Radius, Radius);
  path.fill;
  NSGraphicsContext.currentContext.restoreGraphicsState;
end;

procedure TCocoaCanvas.DrawLine(X1, Y1, X2, Y2, Thickness: Single; Color: TTina4Color);
var
  p: NSBezierPath;
begin
  NSColorOf(Color).setStroke;
  p := NSBezierPath.bezierPath;
  p.moveToPoint(NSMakePoint(X1, Y1));
  p.lineToPoint(NSMakePoint(X2, Y2));
  p.setLineWidth(Thickness);
  p.stroke;
end;

procedure TCocoaCanvas.StrokePolyline(const Pts: TTina4PointArray; Width: Single;
  Color: TTina4Color; Closed: Boolean);
var p: NSBezierPath; i: Integer;
begin
  if Length(Pts) < 2 then Exit;
  p := NSBezierPath.bezierPath;
  p.moveToPoint(NSMakePoint(Pts[0].X, Pts[0].Y));
  for i := 1 to High(Pts) do p.lineToPoint(NSMakePoint(Pts[i].X, Pts[i].Y));
  if Closed then p.closePath;
  p.setLineWidth(Width);
  p.setLineJoinStyle(NSRoundLineJoinStyle);
  p.setLineCapStyle(NSRoundLineCapStyle);
  NSColorOf(Color).setStroke;
  p.stroke;
end;

procedure TCocoaCanvas.FillPolygon(const Contours: array of TTina4PointArray;
  Color: TTina4Color; EvenOdd: Boolean);
var
  p: NSBezierPath;
  i, j: Integer;
begin
  p := NSBezierPath.bezierPath;
  for i := 0 to High(Contours) do
  begin
    if Length(Contours[i]) < 2 then Continue;
    p.moveToPoint(NSMakePoint(Contours[i][0].X, Contours[i][0].Y));
    for j := 1 to High(Contours[i]) do
      p.lineToPoint(NSMakePoint(Contours[i][j].X, Contours[i][j].Y));
    p.closePath;
  end;
  if EvenOdd then p.setWindingRule(NSEvenOddWindingRule)
  else p.setWindingRule(NSNonZeroWindingRule);
  NSColorOf(Color).setFill;
  p.fill;
end;

procedure TCocoaCanvas.DrawText(X, Y: Single; const Text: string; FontSize: Single;
  Styles: TTina4FontStyles; Color: TTina4Color);
begin
  if Text = '' then Exit;
  NSStr(Text).drawAtPoint_withAttributes(NSMakePoint(X, Y),
    AttrsFor(FontSize, Styles, Color));
end;

function TCocoaCanvas.MeasureText(const Text: string; FontSize: Single;
  Styles: TTina4FontStyles): TTina4TextMetrics;
var
  sz: NSSize;
  f: NSFont;
begin
  f := FontFor(FontSize, Styles);
  sz := NSStr(Text).sizeWithAttributes(AttrsFor(FontSize, Styles, $FF000000));
  Result.Width := sz.width;
  Result.Ascent := f.ascender;
  Result.Descent := -f.descender;
  // ascent+descent, WITHOUT external leading (sz.height includes it) — so a
  // glyph centres in its line box instead of riding high next to a checkbox.
  Result.LineHeight := f.ascender - f.descender;
end;

procedure TCocoaCanvas.SetClip(X, Y, W, H: Single);
begin
  NSGraphicsContext.currentContext.saveGraphicsState;
  NSBezierPath.bezierPathWithRect(NSMakeRect(X, Y, W, H)).addClip;
end;

procedure TCocoaCanvas.ClearClip;
begin
  NSGraphicsContext.currentContext.restoreGraphicsState;
end;

procedure TCocoaCanvas.SaveState;
begin
  NSGraphicsContext.currentContext.saveGraphicsState;
end;

procedure TCocoaCanvas.RestoreState;
begin
  NSGraphicsContext.currentContext.restoreGraphicsState;
end;

procedure TCocoaCanvas.Translate(DX, DY: Single);
var t: NSAffineTransform;
begin
  t := NSAffineTransform.transform;
  t.translateXBy_yBy(DX, DY);
  t.concat;
end;

procedure TCocoaCanvas.Rotate(Degrees: Single);
var t: NSAffineTransform;
begin
  t := NSAffineTransform.transform;
  t.rotateByDegrees(Degrees);
  t.concat;
end;

procedure TCocoaCanvas.Scale(SX, SY: Single);
var t: NSAffineTransform;
begin
  t := NSAffineTransform.transform;
  t.scaleXBy_yBy(SX, SY);
  t.concat;
end;

procedure TCocoaCanvas.Skew(AngleXDeg, AngleYDeg: Single);
var t: NSAffineTransform; s: NSAffineTransformStruct; ax, ay: Double;
begin
  // CSS skew: x' = x + tan(ax)·y, y' = y + tan(ay)·x
  ax := AngleXDeg * Pi / 180; ay := AngleYDeg * Pi / 180;
  s.m11 := 1; s.m12 := Sin(ay) / Cos(ay);
  s.m21 := Sin(ax) / Cos(ax); s.m22 := 1;
  s.tX := 0; s.tY := 0;
  t := NSAffineTransform.transform;
  t.setTransformStruct(s);
  t.concat;
end;

procedure TCocoaCanvas.TransformMatrix(A, B, C, D, E, F: Single);
var t: NSAffineTransform; s: NSAffineTransformStruct;
begin
  // CSS matrix(a,b,c,d,e,f): [a c e / b d f / 0 0 1]
  s.m11 := A; s.m12 := B;
  s.m21 := C; s.m22 := D;
  s.tX := E;  s.tY := F;
  t := NSAffineTransform.transform;
  t.setTransformStruct(s);
  t.concat;
end;

procedure TCocoaCanvas.ClipPolygon(const Pts: TTina4PointArray);
var p: NSBezierPath; i: Integer;
begin
  if Length(Pts) < 3 then Exit; // degenerate: leave unclipped
  p := NSBezierPath.bezierPath;
  p.moveToPoint(NSMakePoint(Pts[0].X, Pts[0].Y));
  for i := 1 to High(Pts) do p.lineToPoint(NSMakePoint(Pts[i].X, Pts[i].Y));
  p.closePath;
  p.addClip; // intersects with the current clip; undone by RestoreState
end;

{ ---- offscreen filter / blend compositing -------------------------------- }
{ The pixel math (filter chain, gradient mask, drop-shadow, 3D warp, half<->float,
  blend-mode mapping) lives in the portable Tina4Compositor unit and is shared
  with the iOS shell. Here we only bridge NSBitmapImageRep <-> a Single buffer. }

function CGBlendOf(const Mode: string): CGBlendMode;
begin
  Result := CGBlendMode(CGBlendForMode(LowerCase(Mode)));
end;

{ Decode a rep (8-bit or 16-bit float, pre-/non-premultiplied RGBA) into a planar
  premultiplied Single buffer, run the shared filter+mask chain, write it back. }
procedure ApplyFilterToRep(rep: NSBitmapImageRep; const Spec, MaskSpec: string; Scale: Single);
var
  data: PByte; buf: PSingle;
  pw, ph, bpr, bps, n, i, o, so: Integer;
  premult, isFloat: Boolean;

  function ReadSample(byteOff: Integer): Single;
  begin
    if isFloat then Result := Half2Single(PWord(data + byteOff)^)
    else Result := data[byteOff] / 255;
  end;
  procedure WriteSample(byteOff: Integer; v: Single);
  begin
    if v < 0 then v := 0; if v > 1 then v := 1;
    if isFloat then PWord(data + byteOff)^ := Single2Half(v)
    else data[byteOff] := Round(v * 255);
  end;

begin
  data := PByte(rep.bitmapData);
  pw := rep.pixelsWide; ph := rep.pixelsHigh; bpr := rep.bytesPerRow;
  if (data = nil) or (pw = 0) or (ph = 0) then Exit;
  isFloat := (rep.bitmapFormat and 4) <> 0;   // NSBitmapFormatFloatingPointSamples
  premult := (rep.bitmapFormat and 2) = 0;     // clear Nonpremultiplied bit
  bps := (rep.bitsPerPixel div 8) div 4;       // bytes per sample (1 or 2)
  n := pw * ph;
  GetMem(buf, n * 4 * SizeOf(Single));
  try
    for i := 0 to n - 1 do
    begin
      o := (i div pw) * bpr + (i mod pw) * bps * 4; so := i * 4;
      buf[so]   := ReadSample(o);         buf[so+1] := ReadSample(o + bps);
      buf[so+2] := ReadSample(o + bps*2); buf[so+3] := ReadSample(o + bps*3);
      if not premult then
      begin buf[so] := buf[so]*buf[so+3]; buf[so+1] := buf[so+1]*buf[so+3]; buf[so+2] := buf[so+2]*buf[so+3]; end;
    end;
    ApplyFilterChainF(PSingleBuf(buf), pw, ph, Spec, MaskSpec, Scale);
    for i := 0 to n - 1 do
    begin
      o := (i div pw) * bpr + (i mod pw) * bps * 4; so := i * 4;
      if premult then
      begin
        WriteSample(o, buf[so]); WriteSample(o + bps, buf[so+1]);
        WriteSample(o + bps*2, buf[so+2]); WriteSample(o + bps*3, buf[so+3]);
      end
      else
      begin
        if buf[so+3] > 0 then
        begin
          WriteSample(o, buf[so]/buf[so+3]); WriteSample(o + bps, buf[so+1]/buf[so+3]);
          WriteSample(o + bps*2, buf[so+2]/buf[so+3]);
        end
        else begin WriteSample(o, 0); WriteSample(o + bps, 0); WriteSample(o + bps*2, 0); end;
        WriteSample(o + bps*3, buf[so+3]);
      end;
    end;
  finally
    FreeMem(buf);
  end;
end;
function TCocoaCanvas.BeginLayer(X, Y, W, H, Pad: Single): Integer;
var img: NSImage; t: NSAffineTransform; ox, oy, bw, bh: Single; n: Integer;
begin
  ox := X - Pad; oy := Y - Pad; bw := W + 2 * Pad; bh := H + 2 * Pad;
  if (bw <= 0) or (bh <= 0) then Exit(-1);
  img := NSImage.alloc.initWithSize(NSMakeSize(bw, bh));
  img.lockFocusFlipped(True);           // top-left origin: text renders upright
  t := NSAffineTransform.transform;
  t.translateXBy_yBy(-ox, -oy);         // doc coords -> buffer coords
  t.concat;
  n := Length(FLayers);
  SetLength(FLayers, n + 1);
  FLayers[n].rep := nil;                 // rasterised on End
  FLayers[n].ctx := NSGraphicsContext(img);   // stash the NSImage in ctx slot
  FLayers[n].ox := ox; FLayers[n].oy := oy; FLayers[n].w := bw; FLayers[n].h := bh;
  Result := n;
end;

procedure TCocoaCanvas.EndLayerFiltered(Handle: Integer; const FilterSpec, BlendMode, MaskSpec: string);
var
  img: NSImage; rep: NSBitmapImageRep;
  ox, oy, bw, bh, sc: Single;
  cg: CGContextRef;
begin
  if (Handle < 0) or (Handle > High(FLayers)) then Exit;
  img := NSImage(FLayers[Handle].ctx);
  ox := FLayers[Handle].ox; oy := FLayers[Handle].oy;
  bw := FLayers[Handle].w; bh := FLayers[Handle].h;
  img.unlockFocus;                       // restore the parent context
  // rasterise to an 8-bit pixel buffer via the image's CGImage (TIFFRepresentation
  // hands back 16-bit float samples, which we don't want to touch per-pixel)
  rep := NSBitmapImageRep(NSBitmapImageRep.alloc.initWithCGImage(
    img.CGImageForProposedRect_context_hints(nil, nil, nil)));
  if rep <> nil then
  begin
    if bw > 0 then sc := rep.pixelsWide / bw else sc := 1;
    if (FilterSpec <> '') or (MaskSpec <> '') then ApplyFilterToRep(rep, FilterSpec, MaskSpec, sc);
    if BlendMode <> '' then
    begin
      // mix-blend-mode: draw the CGImage directly so CGContextSetBlendMode is
      // honoured (NSImageRep.drawInRect would reset the blend mode). The extra
      // translate+scale keeps the image upright in the flipped view context.
      cg := CGContextRef(NSGraphicsContext.currentContext.CGContext);
      CGContextSaveGState(cg);
      CGContextSetBlendMode(cg, CGBlendOf(LowerCase(BlendMode)));
      CGContextTranslateCTM(cg, ox, oy + bh);
      CGContextScaleCTM(cg, 1, -1);
      CGContextDrawImage(cg, CGRectMake(0, 0, bw, bh), rep.CGImage);
      CGContextRestoreGState(cg);
    end
    else
      rep.drawInRect_fromRect_operation_fraction_respectFlipped_hints(
        NSMakeRect(ox, oy, bw, bh), NSZeroRect, 2 {SourceOver}, 1.0, True, nil);
    rep.release;
  end;
  img.release;
  SetLength(FLayers, Handle);            // pop
end;

procedure TCocoaCanvas.EndLayer3D(Handle: Integer; const Corners: array of Single);
var
  img: NSImage; srcRep: NSBitmapImageRep;
  src: PSingle; dst: PByte;
  pw, ph, bps, i, dpw, dph, sxi: Integer;
  premult, isFloat: Boolean; sdata: PByte; sbpr: Integer;
  bw, sc, minx, miny, maxx, maxy, a0: Single;
  o00: Integer;
  quad: array[0..7] of Single;
  cg, bmp: CGContextRef; cs: CGColorSpaceRef; cgimg: CGImageRef;
begin
  if (Handle < 0) or (Handle > High(FLayers)) then Exit;
  img := NSImage(FLayers[Handle].ctx);
  bw := FLayers[Handle].w;
  img.unlockFocus;
  srcRep := NSBitmapImageRep(NSBitmapImageRep.alloc.initWithCGImage(
    img.CGImageForProposedRect_context_hints(nil, nil, nil)));
  if srcRep = nil then begin img.release; SetLength(FLayers, Handle); Exit; end;
  pw := srcRep.pixelsWide; ph := srcRep.pixelsHigh;
  if bw > 0 then sc := pw / bw else sc := 1;
  // decode the element texture into a premultiplied Single buffer
  sdata := PByte(srcRep.bitmapData); sbpr := srcRep.bytesPerRow;
  isFloat := (srcRep.bitmapFormat and 4) <> 0;
  premult := (srcRep.bitmapFormat and 2) = 0;
  bps := (srcRep.bitsPerPixel div 8) div 4;
  GetMem(src, pw * ph * 4 * SizeOf(Single));
  for i := 0 to pw * ph - 1 do
  begin
    o00 := (i div pw) * sbpr + (i mod pw) * bps * 4;
    for sxi := 0 to 3 do
      if isFloat then src[i*4+sxi] := Half2Single(PWord(sdata + o00 + sxi*bps)^)
      else src[i*4+sxi] := sdata[o00 + sxi*bps] / 255;
    if not premult then
    begin
      a0 := src[i*4+3];
      src[i*4] := src[i*4]*a0; src[i*4+1] := src[i*4+1]*a0; src[i*4+2] := src[i*4+2]*a0;
    end;
  end;
  // doc-space AABB of the projected quad
  minx := Corners[0]; maxx := Corners[0]; miny := Corners[1]; maxy := Corners[1];
  for i := 1 to 3 do
  begin
    if Corners[i*2]   < minx then minx := Corners[i*2];
    if Corners[i*2]   > maxx then maxx := Corners[i*2];
    if Corners[i*2+1] < miny then miny := Corners[i*2+1];
    if Corners[i*2+1] > maxy then maxy := Corners[i*2+1];
  end;
  dpw := Round((maxx - minx) * sc); dph := Round((maxy - miny) * sc);
  if (dpw <= 0) or (dph <= 0) then begin FreeMem(src); srcRep.release; img.release; SetLength(FLayers, Handle); Exit; end;
  // quad corners in device pixels relative to the AABB, then shared warp
  for i := 0 to 3 do
  begin quad[i*2] := (Corners[i*2] - minx) * sc; quad[i*2+1] := (Corners[i*2+1] - miny) * sc; end;
  GetMem(dst, dpw * dph * 4);
  FillChar(dst^, dpw * dph * 4, 0);
  WarpQuad(PSingleBuf(src), pw, ph, quad, dst, dpw, dph);
  // wrap dst in a CGImage and blit into the view context at the AABB
  cs := CGColorSpaceCreateDeviceRGB;
  bmp := CGBitmapContextCreate(dst, dpw, dph, 8, dpw*4, cs, kCGImageAlphaPremultipliedLast);
  if bmp <> nil then
  begin
    cgimg := CGBitmapContextCreateImage(bmp);
    cg := CGContextRef(NSGraphicsContext.currentContext.CGContext);
    CGContextSaveGState(cg);
    CGContextTranslateCTM(cg, minx, miny + (maxy - miny));
    CGContextScaleCTM(cg, 1, -1);
    CGContextDrawImage(cg, CGRectMake(0, 0, maxx - minx, maxy - miny), cgimg);
    CGContextRestoreGState(cg);
    CGImageRelease(cgimg);
    CGContextRelease(bmp);
  end;
  CGColorSpaceRelease(cs);
  FreeMem(dst); FreeMem(src);
  srcRep.release; img.release;
  SetLength(FLayers, Handle);
end;

procedure TCocoaCanvas.BackdropFilter(X, Y, W, H: Single; const FilterSpec: string);
var rep: NSBitmapImageRep; sc: Single;
begin
  if (W <= 0) or (H <= 0) or (FilterSpec = '') then Exit;
  // grab what has already been painted under the element from the focused view
  rep := NSBitmapImageRep(NSBitmapImageRep.alloc.initWithFocusedViewRect(NSMakeRect(X, Y, W, H)));
  if rep <> nil then
  begin
    if W > 0 then sc := rep.pixelsWide / W else sc := 1;
    ApplyFilterToRep(rep, FilterSpec, '', sc);
    rep.drawInRect_fromRect_operation_fraction_respectFlipped_hints(
      NSMakeRect(X, Y, W, H), NSZeroRect, 2 {SourceOver}, 1.0, True, nil);
    rep.release;
  end;
end;

{ TTina4View }

function TTina4View.isFlipped: ObjCBOOL;
begin
  Result := True; // top-left origin, matches HTML coordinates
end;

function TTina4View.acceptsFirstResponder: ObjCBOOL;
begin
  Result := True;
end;

{ Overlay a native AVPlayerView over each <video> box the engine laid out, and
  position it (screen points, scroll already applied). Reused across frames and
  torn down when the box is gone — the macOS twin of the iOS Tina4View path. }
procedure SyncCocoaVideos(host: NSView);
var
  n, i, flags: LongInt; x, y, w, h: Single; src: string;
  key: NSString; url: NSURL; player: AVPlayer; pv: AVPlayerView;
  live: NSMutableSet; keys: NSArray; k: LongWord;
begin
  if GVideoViews = nil then GVideoViews := NSMutableDictionary.alloc.init;
  n := TinaEmbedCount;
  live := NSMutableSet.setWithCapacity(8);
  for i := 0 to n - 1 do
  begin
    TinaEmbedRect(i, x, y, w, h);
    src := TinaEmbedSrc(i);
    if (w <= 0) or (h <= 0) or (src = '') then Continue;
    key := NSString.stringWithUTF8String(PChar(src));
    live.addObject(key);
    pv := AVPlayerView(GVideoViews.objectForKey(key));
    if pv = nil then
    begin
      url := NSURL.URLWithString(key);
      if url = nil then Continue;
      flags := TinaEmbedFlags(i);   // 1 controls·2 autoplay·4 loop·8 muted
      player := AVPlayer.playerWithURL(url);
      player.setMuted((flags and 8) <> 0);                    // `muted`
      pv := AVPlayerView(AVPlayerView.alloc).initWithFrame(NSMakeRect(x, y, w, h));
      pv.setPlayer(player);
      if (flags and 1) <> 0 then                              // `controls`
        pv.setControlsStyle(AVPlayerViewControlsStyleInline)
      else
        pv.setControlsStyle(AVPlayerViewControlsStyleNone);
      pv.setVideoGravity(AVLayerVideoGravityResizeAspect);
      host.addSubview(pv);
      GVideoViews.setObject_forKey(pv, key);
      if (flags and 2) <> 0 then player.play;                 // `autoplay` (loop: TODO on macOS)
    end
    else
      pv.setFrame(NSMakeRect(x, y, w, h));   // track scroll
  end;
  // remove players whose <video> is no longer laid out
  keys := GVideoViews.allKeys;
  if keys.count = 0 then Exit;      // NB: count is unsigned — never do count-1 at 0
  for k := 0 to keys.count - 1 do
  begin
    key := NSString(keys.objectAtIndex(k));
    if not live.containsObject(key) then
    begin
      pv := AVPlayerView(GVideoViews.objectForKey(key));
      if pv <> nil then
      begin
        if pv.player <> nil then pv.player.pause;
        pv.removeFromSuperview;
      end;
      GVideoViews.removeObjectForKey(key);
    end;
  end;
end;

procedure TTina4View.drawRect(dirtyRect: NSRect);
var path: string;
begin
  if (shell <> nil) and Assigned(shell.OnPaint) then
    shell.OnPaint(shell.FCanvas, bounds.size.width, bounds.size.height);
  { A scripted/interactive snapshot request piggybacks on the normal paint.
    Clear the path first so the cacheDisplay re-entry into drawRect is a no-op. }
  if (shell <> nil) and (shell.SnapshotPath <> '') then
  begin
    path := shell.SnapshotPath;
    shell.SnapshotPath := '';
    shell.Snapshot(path);
  end;
  // native <video> overlays — only in a real window (skip headless snapshots)
  if window <> nil then SyncCocoaVideos(self);
end;

procedure TTina4View.mouseDown(event: NSEvent);
var
  p: NSPoint;
begin
  p := convertPoint_fromView(event.locationInWindow, nil);
  if (shell <> nil) and Assigned(shell.OnMouseDown) then
    shell.OnMouseDown(p.x, p.y);
end;

procedure TTina4View.mouseUp(event: NSEvent);
var
  p: NSPoint;
begin
  p := convertPoint_fromView(event.locationInWindow, nil);
  if (shell <> nil) and Assigned(shell.OnMouseUp) then
    shell.OnMouseUp(p.x, p.y);
end;

procedure TTina4View.mouseMoved(event: NSEvent);
var
  p: NSPoint;
begin
  p := convertPoint_fromView(event.locationInWindow, nil);
  if (shell <> nil) and Assigned(shell.OnMouseMove) then
    shell.OnMouseMove(p.x, p.y);
end;

procedure TTina4View.mouseDragged(event: NSEvent);
var
  p: NSPoint;
begin
  p := convertPoint_fromView(event.locationInWindow, nil);
  if (shell <> nil) and Assigned(shell.OnMouseDrag) then
    shell.OnMouseDrag(p.x, p.y);
end;

procedure TTina4View.keyDown(event: NSEvent);
var
  chars: string;
  code: Integer;
  ns: NSString;
begin
  ns := event.charactersIgnoringModifiers;
  if (ns <> nil) and (ns.length > 0) then chars := string(ns.UTF8String) else chars := '';
  case event.keyCode of
    36, 76: code := TK_RETURN;
    51:     code := TK_BACKSPACE;
    48:     code := TK_TAB;
    53:     code := TK_ESCAPE;
    123:    code := TK_LEFT;
    124:    code := TK_RIGHT;
    125:    code := TK_DOWN;
    126:    code := TK_UP;
    117:    code := TK_DELETE;
  else
    code := TK_NONE;
  end;
  if code <> TK_NONE then chars := '';
  if (shell <> nil) and Assigned(shell.OnKeyDown) then
    shell.OnKeyDown(chars, code);
  // deliberately not calling inherited: avoids the system beep
end;

procedure TTina4View.windowWillClose(notification: NSNotification);
begin
  NSApp.terminate(nil);   // closing the window quits the app
end;

procedure TTina4View.scrollWheel(event: NSEvent);
var
  dx, dy: Single;
  p: NSPoint;
begin
  { Trackpads report pixel-precise deltas (with momentum events for free);
    wheel mice report lines — scale those up. The renderer owns scrolling,
    so all the OS supplies is deltas. }
  if event.hasPreciseScrollingDeltas then
  begin
    dx := event.scrollingDeltaX;
    dy := event.scrollingDeltaY;
  end
  else
  begin
    dx := event.deltaX * 24;
    dy := event.deltaY * 24;
  end;
  p := convertPoint_fromView(event.locationInWindow, nil);
  if (shell <> nil) and Assigned(shell.OnScroll) then
    shell.OnScroll(p.x, p.y, dx, dy);
end;

{ TCocoaShell }

destructor TCocoaShell.Destroy;
begin
  FCanvas.Free;
  inherited;
end;

procedure TCocoaShell.Initialize(Width, Height: Integer; const Title: string);
var
  rect: NSRect;
  pool: NSAutoreleasePool;
begin
  pool := NSAutoreleasePool.alloc.init;
  NSApplication.sharedApplication;
  NSApp.setActivationPolicy(NSApplicationActivationPolicyRegular);

  rect := NSMakeRect(0, 0, Width, Height);
  FWindow := NSWindow.alloc.initWithContentRect_styleMask_backing_defer(rect,
    NSTitledWindowMask or NSClosableWindowMask or NSMiniaturizableWindowMask or
    NSResizableWindowMask, NSBackingStoreBuffered, False);
  FWindow.setTitle(NSStr(Title));
  FWindow.center;

  FView := TTina4View.alloc.initWithFrame(rect);
  FView.shell := Self;
  FWindow.setContentView(FView);
  FWindow.setDelegate(NSWindowDelegateProtocol(FView));   // windowWillClose → quit
  FWindow.setAcceptsMouseMovedEvents(True);
  FWindow.makeFirstResponder(FView);

  FCanvas := TCocoaCanvas.Create;

  if Headless then
    // no Dock icon, no focus steal, window never ordered on screen
    NSApp.setActivationPolicy(NSApplicationActivationPolicyProhibited)
  else
  begin
    FWindow.makeKeyAndOrderFront(nil);
    NSApp.activateIgnoringOtherApps(True);
  end;
  pool.drain;
end;

procedure TCocoaShell.Snapshot(const Path: string);
var
  rep: NSBitmapImageRep;
  png: NSData;
  pool: NSAutoreleasePool;
begin
  if FView = nil then Exit;
  pool := NSAutoreleasePool.alloc.init;
  // render the (flipped) view straight into an off-screen bitmap — no window
  // needs to be visible, so this works headless and never steals focus
  rep := FView.bitmapImageRepForCachingDisplayInRect(FView.bounds);
  FView.cacheDisplayInRect_toBitmapImageRep(FView.bounds, rep);
  png := rep.representationUsingType_properties(NSPNGFileType, nil);
  png.writeToFile_atomically(NSSTR(PAnsiChar(UTF8Encode(Path))), True);
  pool.drain;
end;

procedure TCocoaShell.Invalidate;
begin
  if FView <> nil then FView.setNeedsDisplay_(True);
end;

procedure TCocoaShell.Run;
begin
  NSApp.run;
end;

procedure TCocoaShell.Quit;
begin
  NSApp.terminate(nil);
end;

procedure TCocoaShell.SetTitle(const Title: string);
begin
  if FWindow <> nil then FWindow.setTitle(NSStr(Title));
end;

procedure TCocoaShell.SetCursor(C: TTina4Cursor);
var cur: NSCursor;
begin
  if C = FCursor then Exit;               // unchanged since last move — skip
  FCursor := C;
  if FCursorHidden and (C <> tcNone) then // leaving cursor:none — show it again
  begin NSCursor.unhide; FCursorHidden := False; end;
  case C of
    tcPointer:    cur := NSCursor.pointingHandCursor;
    tcText:       cur := NSCursor.IBeamCursor;
    tcMove,
    tcGrab:       cur := NSCursor.openHandCursor;
    tcGrabbing:   cur := NSCursor.closedHandCursor;
    tcCrosshair:  cur := NSCursor.crosshairCursor;
    tcNotAllowed: cur := NSCursor.operationNotAllowedCursor;
    tcColResize:  cur := NSCursor.resizeLeftRightCursor;
    tcRowResize:  cur := NSCursor.resizeUpDownCursor;
    tcNone:
      begin
        if not FCursorHidden then begin NSCursor.hide; FCursorHidden := True; end;
        Exit;
      end;
  else
    cur := NSCursor.arrowCursor;          // default / wait / help
  end;
  if cur <> nil then cur.set_;
end;

{ Post a Notification Center banner. AppleScript's `display notification` works
  from any process (a bundled app is not required), so we launch osascript with
  NSTask — non-blocking, no shell quoting (args are passed directly). }
procedure TCocoaShell.Notify(const Title, Body, Tag: string);
  function Esc(const S: string): string;   // escape for an AppleScript string literal
  begin
    Result := StringReplace(S, '\', '\\', [rfReplaceAll]);
    Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
  end;
var task: NSTask; args: NSMutableArray; script: string;
begin
  script := 'display notification "' + Esc(Body) + '" with title "' + Esc(Title) + '"';
  args := NSMutableArray.arrayWithCapacity(2);
  args.addObject(NSSTR('-e'));
  args.addObject(NSSTR(PAnsiChar(UTF8Encode(script))));
  task := NSTask.alloc.init;
  task.setLaunchPath(NSSTR('/usr/bin/osascript'));
  task.setArguments(args);
  try task.launch; except end;   // best-effort; never block the UI
  task.release;
end;

function TCocoaShell.FetchToFile(const Url, DestPath: string): Boolean;
var data: NSData;
begin
  Result := False;
  // Foundation handles TLS + redirects via its synchronous convenience API.
  data := NSData.dataWithContentsOfURL(NSURL.URLWithString(NSStr(Url)));
  if (data <> nil) and (data.length > 0) then
    Result := data.writeToFile_atomically(NSStr(DestPath), True);
end;

function TCocoaShell.PickFile: string;
var
  panel: NSOpenPanel;
begin
  Result := '';
  panel := NSOpenPanel.openPanel;
  panel.setCanChooseFiles(True);
  panel.setCanChooseDirectories(False);
  panel.setAllowsMultipleSelection(False);
  if panel.runModal = NSModalResponseOK then
    if panel.URLs.count > 0 then
      Result := string(NSURL(panel.URLs.objectAtIndex(0)).path.UTF8String);
end;

function TCocoaShell.CaptureCamera: string;
begin
  { A live AVFoundation capture session belongs in a dedicated camera shell
    unit (it needs an AVCaptureSession + preview layer + permission prompt).
    Until that lands, fall back to letting the user pick an image file so the
    <camera> element and its value pipeline work end to end. }
  Result := PickFile;
end;

procedure TTina4Ticker.tick(t: NSTimer);
begin
  if (shell <> nil) and Assigned(shell.OnTick) then
    shell.OnTick;
end;

procedure TCocoaShell.StartTicker(IntervalMs: Integer);
var
  ticker: TTina4Ticker;
begin
  ticker := TTina4Ticker.alloc.init;
  ticker.shell := Self;
  NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats(
    IntervalMs / 1000.0, ticker, objcselector('tick:'), nil, True);
end;

function TCocoaShell.GetMeasuringCanvas: TTina4Canvas;
begin
  if FCanvas = nil then FCanvas := TCocoaCanvas.Create;
  Result := FCanvas;
end;

finalization
  GFontAlias.Free;
end.
