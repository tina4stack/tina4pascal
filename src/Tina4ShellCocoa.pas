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
    procedure StartTicker(IntervalMs: Integer); override;
    function PickFile: string; override;
    function CaptureCamera: string; override;
    function GetMeasuringCanvas: TTina4Canvas; override;
  end;

implementation

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
  fam, cand: string; parts: TStringArray; k: Integer; f: NSFont;
begin
  Result := nil;
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
  begin
    if tfsBold in Styles then Result := NSFont.boldSystemFontOfSize(FontSize)
    else Result := NSFont.systemFontOfSize(FontSize);
  end
  else if tfsBold in Styles then
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

end.
