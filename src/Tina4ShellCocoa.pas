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
  SysUtils, Classes, MD5, CocoaAll, Tina4RenderBackend;

type
  TCocoaShell = class;

  TCocoaCanvas = class(TTina4Canvas)
  private
    FImages: TList;                   // handle -> NSImage (retained, as Pointer)
    FImageBySrc: TStringList;         // src -> handle in Objects[] (sorted)
    function FontFor(FontSize: Single; Styles: TTina4FontStyles): NSFont;
    function AttrsFor(FontSize: Single; Styles: TTina4FontStyles;
      Color: TTina4Color): NSDictionary;
  public
    constructor Create;
    destructor Destroy; override;
    function LoadImage(const Src: string): Integer; override;
    function ImageSize(Handle: Integer; out W, H: Single): Boolean; override;
    procedure DrawImage(Handle: Integer; X, Y, W, H: Single); override;
    procedure FillRect(X, Y, W, H: Single; Color: TTina4Color); override;
    procedure StrokeRect(X, Y, W, H, Thickness: Single; Color: TTina4Color); override;
    procedure FillRoundRect(X, Y, W, H, Radius: Single; Color: TTina4Color); override;
    procedure StrokeRoundRect(X, Y, W, H, Radius, Thickness: Single; Color: TTina4Color); override;
    procedure DrawLine(X1, Y1, X2, Y2, Thickness: Single; Color: TTina4Color); override;
    procedure DrawText(X, Y: Single; const Text: string; FontSize: Single;
      Styles: TTina4FontStyles; Color: TTina4Color); override;
    function MeasureText(const Text: string; FontSize: Single;
      Styles: TTina4FontStyles): TTina4TextMetrics; override;
    procedure SetClip(X, Y, W, H: Single); override;
    procedure ClearClip; override;
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
    procedure scrollWheel(event: NSEvent); override;
  end;

  TCocoaShell = class(TTina4Shell)
  private
    FWindow: NSWindow;
    FView: TTina4View;
    FCanvas: TCocoaCanvas;
  public
    { When non-empty, the next completed paint is written to this PNG path
      (then cleared). Seed of the headless render-to-image mode. }
    SnapshotPath: string;
    destructor Destroy; override;
    procedure Initialize(Width, Height: Integer; const Title: string); override;
    procedure Invalidate; override;
    procedure Run; override;
    procedure Quit; override;
    function GetMeasuringCanvas: TTina4Canvas; override;
  end;

implementation

function NSColorOf(C: TTina4Color): NSColor;
begin
  Result := NSColor.colorWithCalibratedRed_green_blue_alpha(
    ((C shr 16) and $FF) / 255.0,
    ((C shr 8) and $FF) / 255.0,
    (C and $FF) / 255.0,
    ((C shr 24) and $FF) / 255.0);
end;

function NSStr(const S: string): NSString;
begin
  Result := NSString.stringWithUTF8String(PAnsiChar(UTF8Encode(S)));
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
  if (Pos('http://', LowerCase(Src)) = 1) or (Pos('https://', LowerCase(Src)) = 1) then
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
    FImageBySrc.AddObject(Src, TObject(PtrInt(-1)));
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
  Result := (Handle >= 0) and (Handle < FImages.Count) and (FImages[Handle] <> nil);
  if Result then
  begin
    sz := NSImage(FImages[Handle]).size;
    W := sz.width; H := sz.height;
  end;
end;

procedure TCocoaCanvas.DrawImage(Handle: Integer; X, Y, W, H: Single);
begin
  if (Handle < 0) or (Handle >= FImages.Count) or (FImages[Handle] = nil) then Exit;
  NSImage(FImages[Handle]).drawInRect_fromRect_operation_fraction_respectFlipped_hints(
    NSMakeRect(X, Y, W, H), NSZeroRect, NSCompositeSourceOver, 1.0, True, nil);
end;

function TCocoaCanvas.FontFor(FontSize: Single; Styles: TTina4FontStyles): NSFont;
var
  fm: NSFontManager;
  traits: NSFontTraitMask;
begin
  traits := 0;
  if tfsBold in Styles then traits := traits or NSBoldFontMask;
  if tfsItalic in Styles then traits := traits or NSItalicFontMask;
  if traits = 0 then
    Result := NSFont.systemFontOfSize(FontSize)
  else
  begin
    fm := NSFontManager.sharedFontManager;
    Result := fm.fontWithFamily_traits_weight_size(NSStr('Helvetica'), traits, 5, FontSize);
    if Result = nil then Result := NSFont.systemFontOfSize(FontSize);
  end;
end;

function TCocoaCanvas.AttrsFor(FontSize: Single; Styles: TTina4FontStyles;
  Color: TTina4Color): NSDictionary;
var
  keys: array[0..2] of Pointer;
  vals: array[0..2] of Pointer;
  n: Integer;
begin
  keys[0] := Pointer(NSFontAttributeName);
  vals[0] := Pointer(FontFor(FontSize, Styles));
  keys[1] := Pointer(NSForegroundColorAttributeName);
  vals[1] := Pointer(NSColorOf(Color));
  n := 2;
  if tfsUnderline in Styles then
  begin
    keys[2] := Pointer(NSUnderlineStyleAttributeName);
    vals[2] := Pointer(NSNumber.numberWithInt(NSUnderlineStyleSingle));
    n := 3;
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
  NSColorOf(Color).setFill;
  NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius(
    NSMakeRect(X, Y, W, H), Radius, Radius).fill;
end;

procedure TCocoaCanvas.StrokeRoundRect(X, Y, W, H, Radius, Thickness: Single; Color: TTina4Color);
var
  p: NSBezierPath;
begin
  NSColorOf(Color).setStroke;
  p := NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius(
    NSMakeRect(X + Thickness / 2, Y + Thickness / 2, W - Thickness, H - Thickness),
    Radius, Radius);
  p.setLineWidth(Thickness);
  p.stroke;
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
  Result.LineHeight := sz.height;
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

{ TTina4View }

function TTina4View.isFlipped: ObjCBOOL;
begin
  Result := True; // top-left origin, matches HTML coordinates
end;

function TTina4View.acceptsFirstResponder: ObjCBOOL;
begin
  Result := True;
end;

procedure TTina4View.drawRect(dirtyRect: NSRect);
var
  rep: NSBitmapImageRep;
  png: NSData;
  path: string;
begin
  if (shell <> nil) and Assigned(shell.OnPaint) then
    shell.OnPaint(shell.FCanvas, bounds.size.width, bounds.size.height);
  if (shell <> nil) and (shell.SnapshotPath <> '') then
  begin
    path := shell.SnapshotPath;
    shell.SnapshotPath := ''; // clear first: cacheDisplay re-enters drawRect
    rep := bitmapImageRepForCachingDisplayInRect(bounds);
    cacheDisplayInRect_toBitmapImageRep(bounds, rep);
    png := rep.representationUsingType_properties(NSPNGFileType, nil);
    png.writeToFile_atomically(NSSTR(PAnsiChar(UTF8Encode(path))), True);
  end;
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

procedure TTina4View.scrollWheel(event: NSEvent);
var
  dx, dy: Single;
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
  if (shell <> nil) and Assigned(shell.OnScroll) then
    shell.OnScroll(dx, dy);
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
  FWindow.setAcceptsMouseMovedEvents(True);
  FWindow.makeFirstResponder(FView);

  FCanvas := TCocoaCanvas.Create;

  FWindow.makeKeyAndOrderFront(nil);
  NSApp.activateIgnoringOtherApps(True);
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

function TCocoaShell.GetMeasuringCanvas: TTina4Canvas;
begin
  if FCanvas = nil then FCanvas := TCocoaCanvas.Create;
  Result := FCanvas;
end;

end.
