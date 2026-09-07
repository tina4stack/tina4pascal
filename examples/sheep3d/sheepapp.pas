program sheepapp;

{ A real macOS app: ThreePascal renders the animated sheep in pure software to an
  RGBA buffer each frame; a Cocoa NSView blits that buffer via NSBitmapImageRep.
  No OpenGL, no GPU — so none of the GLFW/macOS issues. Camera orbits; the sheep
  walks (AnimationMixer). Close the window (or Cmd-Q) to quit. }

{$mode delphi}{$H+}
{$modeswitch objectivec1}

uses CocoaAll, SysUtils, ThreePascal, RamModel;

const W = 780; H = 540;

var
  gScene: TScene; gCam: TPerspectiveCamera; gRend: TWebGLRenderer;
  gMixer: TAnimationMixer; gTurn: Single = 0;

type
  TSheepView = objcclass(NSView)
    function isFlipped: ObjCBOOL; override;
    procedure drawRect(dirty: NSRect); override;
  end;
  TTicker = objcclass(NSObject)
    procedure tick(t: NSTimer); message 'tick:';
  end;
  TAppDelegate = objcclass(NSObject, NSApplicationDelegateProtocol)
    function applicationShouldTerminateAfterLastWindowClosed(sender: NSApplication): ObjCBOOL;
      message 'applicationShouldTerminateAfterLastWindowClosed:';
  end;

var gView: TSheepView = nil;

{ encode the current frame as an in-memory 24-bit BMP (bottom-up, BGR) — NSImage
  decodes it via ImageIO. Avoids the unbound NSBitmapImageRep raw initialiser. }
function FrameBMP: TBytes;
var w, h, rowsize, pad, datasize, off, row, col, i, si: Integer;
begin
  w:=gRend.Width; h:=gRend.Height; rowsize:=w*3; pad:=(4-(rowsize mod 4)) mod 4;
  datasize:=(rowsize+pad)*h; SetLength(Result, 54+datasize); FillChar(Result[0], 54, 0);
  Result[0]:=$42; Result[1]:=$4D; i:=54+datasize; Move(i,Result[2],4);
  i:=54; Move(i,Result[10],4); i:=40; Move(i,Result[14],4);
  Move(w,Result[18],4); Move(h,Result[22],4); Result[26]:=1; Result[28]:=24; Move(datasize,Result[34],4);
  off:=54;
  for row:=h-1 downto 0 do
  begin
    for col:=0 to w-1 do
    begin
      si:=(row*w+col)*4;
      Result[off]:=gRend.Pixels[si+2]; Result[off+1]:=gRend.Pixels[si+1]; Result[off+2]:=gRend.Pixels[si+0];
      off:=off+3;
    end;
    for col:=1 to pad do begin Result[off]:=0; Inc(off); end;
  end;
end;

function TSheepView.isFlipped: ObjCBOOL; begin Result := False; end;  // NSImage draws upright in a bottom-left-origin view

procedure TSheepView.drawRect(dirty: NSRect);
var bmp: TBytes; d: NSData; im: NSImage;
begin
  if System.Length(gRend.Pixels) = 0 then Exit;
  bmp := FrameBMP;
  d := NSData.dataWithBytes_length(@bmp[0], System.Length(bmp));
  im := NSImage(NSImage.alloc.initWithData(d));
  if im <> nil then
  begin
    im.drawInRect_fromRect_operation_fraction(bounds, NSZeroRect, NSCompositeSourceOver, 1.0);
    im.release;
  end;
end;

procedure TTicker.tick(t: NSTimer);
begin
  gTurn := gTurn + 0.010;
  gCam.Position.SetXYZ(Sin(gTurn)*2.9, 1.4, Cos(gTurn)*2.9);    // slow orbit
  gCam.LookAt(0, 0.72, 0);
  gMixer.Update(1/30);                                          // walk the ram
  gRend.Render(gScene, gCam);
  gRend.DrawTextPx(16, 14, 'TINA4 3D - WALKING RAM', 2, 255,255,255);
  gRend.DrawTextPx(16, H-24, 'MERINO RAM - PURE SOFTWARE - NO GPU', 2, 150,152,180);
  if gView <> nil then gView.setNeedsDisplay_(True);
end;

function TAppDelegate.applicationShouldTerminateAfterLastWindowClosed(sender: NSApplication): ObjCBOOL;
begin Result := True; end;

var
  pool: NSAutoreleasePool; win: NSWindow; rect: NSRect;
  ticker: TTicker; appDel: TAppDelegate; sheep: TGroup;
  amb: TAmbientLight; sun: TDirectionalLight; floor: TMesh;
begin
  pool := NSAutoreleasePool.alloc.init;

  { --- build the 3D scene --- }
  gScene := TScene.Create; gScene.Background.SetHex($0e0f1f);
  gCam := TPerspectiveCamera.Create(45, W/H, 0.05, 100);
  gRend := TWebGLRenderer.Create(W, H);
  amb := TAmbientLight.Create($ffffff, 0.55); gScene.Add(amb);
  sun := TDirectionalLight.Create($fff4cf, 0.8); sun.Position.SetXYZ(4, 9, 5); gScene.Add(sun);
  floor := TMesh.Create(TPlaneGeometry.Create(30, 30), TMeshStandardMaterial.Create($1b7a3a));
  floor.Rotation.x := -Pi/2; gScene.Add(floor);
  sheep := BuildRam; gScene.Add(sheep);
  gMixer := TAnimationMixer.Create(sheep); gMixer.Play(RamWalkClip);
  gRend.Render(gScene, gCam);

  { --- Cocoa app + window --- }
  NSApplication.sharedApplication;
  NSApp.setActivationPolicy(NSApplicationActivationPolicyRegular);
  appDel := TAppDelegate.alloc.init; NSApp.setDelegate(NSApplicationDelegateProtocol(appDel));

  rect := NSMakeRect(0, 0, W, H);
  win := NSWindow.alloc.initWithContentRect_styleMask_backing_defer(rect,
    NSTitledWindowMask or NSClosableWindowMask or NSMiniaturizableWindowMask,
    NSBackingStoreBuffered, False);
  win.setTitle(NSSTR('Tina4 3D — Walking Ram'));
  win.center;
  gView := TSheepView.alloc.initWithFrame(rect);
  win.setContentView(gView);
  win.makeKeyAndOrderFront(nil);
  NSApp.activateIgnoringOtherApps(True);

  ticker := TTicker.alloc.init;
  NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats(
    1/30, ticker, objcselector('tick:'), nil, True);

  pool.drain;
  NSApp.run;
end.
