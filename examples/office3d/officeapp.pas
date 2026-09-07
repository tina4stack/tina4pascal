program officeapp;

{ Walk the office in first person — pure-software ThreePascal render blitted into
  a Cocoa window. Mouse looks (pointer locked to centre), WASD moves, X toggles
  anti-aliasing, Esc quits. No logins, no video. }

{$mode delphi}{$H+}
{$modeswitch objectivec1}

uses CocoaAll, SysUtils, Math, ThreePascal, OfficeScene;

{$linkframework CoreGraphics}
type TCGPoint = record x, y: Double; end;
     CGImageRef = Pointer; CGColorSpaceRef = Pointer; CGDataProviderRef = Pointer;
function CGAssociateMouseAndMouseCursorPosition(connected: LongInt): LongInt; cdecl; external;
function CGColorSpaceCreateDeviceRGB: CGColorSpaceRef; cdecl; external;
function CGDataProviderCreateWithData(a,b:Pointer;c:NativeUInt;d:Pointer):CGDataProviderRef; cdecl; external;
function CGImageCreate(w,h,bpc,bpp,bpr:NativeUInt; sp:CGColorSpaceRef; bi:LongWord;
  pr:CGDataProviderRef; dec_:Pointer; interp:LongBool; intent:LongInt):CGImageRef; cdecl; external;
procedure CGImageRelease(i:CGImageRef); cdecl; external;
procedure CGColorSpaceRelease(s:CGColorSpaceRef); cdecl; external;
procedure CGDataProviderRelease(p:CGDataProviderRef); cdecl; external;

const W = 900; H = 600;

var
  gScene: TScene; gCam: TPerspectiveCamera; gRend: TWebGLRenderer;
  gPX: Single = 0; gPY: Single = 1.55; gPZ: Single = 8.0;
  gYaw: Single = 0; gPitch: Single = -0.05;
  gKeys: array[0..127] of Boolean;
  gLocked: Boolean = False;
  gFPS: Single = 0;

procedure Lock;   begin if gLocked then Exit; NSCursor.hide; CGAssociateMouseAndMouseCursorPosition(0); gLocked:=True; end;
procedure Unlock; begin if not gLocked then Exit; CGAssociateMouseAndMouseCursorPosition(1); NSCursor.unhide; gLocked:=False; end;

type
  TOfficeView = objcclass(NSView)
    function isFlipped: ObjCBOOL; override;
    function acceptsFirstResponder: ObjCBOOL; override;
    procedure drawRect(dirty: NSRect); override;
    procedure keyDown(e: NSEvent); override;
    procedure keyUp(e: NSEvent); override;
    procedure mouseMoved(e: NSEvent); override;
    procedure mouseDown(e: NSEvent); override;
  end;
  TTicker = objcclass(NSObject)
    procedure tick(t: NSTimer); message 'tick:';
  end;
  TAppDelegate = objcclass(NSObject, NSApplicationDelegateProtocol)
    function applicationShouldTerminateAfterLastWindowClosed(sender: NSApplication): ObjCBOOL;
      message 'applicationShouldTerminateAfterLastWindowClosed:';
    procedure applicationWillTerminate(n: NSNotification); message 'applicationWillTerminate:';
  end;

var gView: TOfficeView = nil;

{ wrap the raw RGBA buffer as a CGImage (no copy, no encode/decode) — the window
  server composites it on the GPU when set as the layer's contents. }
function MakeCGImage: CGImageRef;
var cs: CGColorSpaceRef; pr: CGDataProviderRef;
begin
  cs:=CGColorSpaceCreateDeviceRGB;
  pr:=CGDataProviderCreateWithData(nil, @gRend.Pixels[0], gRend.Width*gRend.Height*4, nil);
  Result:=CGImageCreate(gRend.Width, gRend.Height, 8, 32, gRend.Width*4, cs, 1 {PremultipliedLast},
                        pr, nil, False, 0);
  CGColorSpaceRelease(cs); CGDataProviderRelease(pr);
end;

procedure Present;
var img: CGImageRef;
begin
  if (gView=nil) or (gView.layer=nil) or (System.Length(gRend.Pixels)=0) then Exit;
  img:=MakeCGImage;
  gView.layer.setContents(id(img));               // GPU-composited display
  if img<>nil then CGImageRelease(img);
end;

function TOfficeView.isFlipped: ObjCBOOL; begin Result := False; end;
function TOfficeView.acceptsFirstResponder: ObjCBOOL; begin Result := True; end;
procedure TOfficeView.drawRect(dirty: NSRect); begin end;   // layer-backed; content set via Present

procedure TOfficeView.mouseDown(e: NSEvent); begin Lock; end;   // click to capture the mouse

procedure TOfficeView.mouseMoved(e: NSEvent);
const SENS = 0.0026;
begin
  if not gLocked then Exit;
  gYaw   := gYaw + e.deltaX*SENS;
  gPitch := gPitch - e.deltaY*SENS;
  if gPitch> 1.2 then gPitch:= 1.2; if gPitch<-1.2 then gPitch:=-1.2;
end;

procedure TOfficeView.keyDown(e: NSEvent);
begin
  case e.keyCode of
    53: begin Unlock; NSApp.terminate(nil); end;    // Esc
    7:  if gRend.Samples=1 then gRend.SetSamples(2) else gRend.SetSamples(1);   // X: toggle AA
  end;
  if e.keyCode < 128 then gKeys[e.keyCode] := True;
end;
procedure TOfficeView.keyUp(e: NSEvent);
begin if e.keyCode < 128 then gKeys[e.keyCode] := False; end;

procedure TTicker.tick(t: NSTimer);
var spd, rot, fx, fz, rx, rz, tx, ty, tz: Single; t0: QWord; dt: QWord;
begin
  spd:=0.11; rot:=0.03;
  if gKeys[123] then gYaw:=gYaw - rot;                 // arrow-key look (fallback)
  if gKeys[124] then gYaw:=gYaw + rot;
  if gKeys[126] then gPitch:=gPitch + rot;
  if gKeys[125] then gPitch:=gPitch - rot;
  if gPitch> 1.2 then gPitch:= 1.2; if gPitch<-1.2 then gPitch:=-1.2;
  fx:=Sin(gYaw); fz:=-Cos(gYaw); rx:=Cos(gYaw); rz:=Sin(gYaw);
  if gKeys[13] then begin gPX:=gPX+fx*spd; gPZ:=gPZ+fz*spd; end;   // W
  if gKeys[1]  then begin gPX:=gPX-fx*spd; gPZ:=gPZ-fz*spd; end;   // S
  if gKeys[0]  then begin gPX:=gPX-rx*spd; gPZ:=gPZ-rz*spd; end;   // A
  if gKeys[2]  then begin gPX:=gPX+rx*spd; gPZ:=gPZ+rz*spd; end;   // D
  if gPX> ROOM_X then gPX:=ROOM_X; if gPX<-ROOM_X then gPX:=-ROOM_X;
  if gPZ> ROOM_Z then gPZ:=ROOM_Z; if gPZ<-ROOM_Z then gPZ:=-ROOM_Z;

  tx:=gPX + Sin(gYaw)*Cos(gPitch); ty:=gPY + Sin(gPitch); tz:=gPZ - Cos(gYaw)*Cos(gPitch);
  gCam.Position.SetXYZ(gPX, gPY, gPZ); gCam.LookAt(tx, ty, tz);
  t0:=GetTickCount64;
  gRend.Render(gScene, gCam);
  dt:=GetTickCount64 - t0; if dt<1 then dt:=1;
  gFPS:=gFPS*0.85 + (1000.0/dt)*0.15;             // render-capacity fps (smoothed)

  gRend.FillRectPx(W div 2 - 7, H div 2 - 1, 14, 2, 255,255,255, 0.7);
  gRend.FillRectPx(W div 2 - 1, H div 2 - 7, 2, 14, 255,255,255, 0.7);
  gRend.FillRectPx(0, 0, W, 30, 14,15,31, 0.66);
  if gLocked then
    gRend.DrawTextPx(14, 9, 'TINA4 OFFICE - MOUSE LOOK - WASD MOVE - X AA - ESC QUIT', 2, 236,236,251)
  else
    gRend.DrawTextPx(14, 9, 'CLICK TO CAPTURE MOUSE - WASD MOVE - ARROWS LOOK', 2, 255,210,60);
  gRend.FillRectPx(W-118, 0, 118, 30, 14,15,31, 0.66);
  gRend.DrawTextPx(W-108, 9, 'FPS ' + IntToStr(Round(gFPS)) + '  ' + IntToStr(dt) + 'MS', 2, 79,209,139);
  Present;
end;

function TAppDelegate.applicationShouldTerminateAfterLastWindowClosed(sender: NSApplication): ObjCBOOL;
begin Result := True; end;
procedure TAppDelegate.applicationWillTerminate(n: NSNotification);
begin Unlock; end;

var
  pool: NSAutoreleasePool; win: NSWindow; rect: NSRect;
  ticker: TTicker; appDel: TAppDelegate;
  amb: TAmbientLight; sun: TDirectionalLight; lamp: TPointLight; office: TGroup;
begin
  pool:=NSAutoreleasePool.alloc.init;

  gScene:=TScene.Create; gScene.Background.SetHex($0e0f1f);
  gScene.Fog:=TFog.Create($0e0f1f, 22, 46);
  gCam:=TPerspectiveCamera.Create(60, W/H, 0.05, 100);
  gRend:=TWebGLRenderer.Create(W, H, 1);               // 1x for a smooth walk; X toggles AA

  amb:=TAmbientLight.Create($ffffff, 0.6); gScene.Add(amb);
  sun:=TDirectionalLight.Create($fff4cf, 0.55); sun.Position.SetXYZ(6,12,4); gScene.Add(sun);
  lamp:=TPointLight.Create($aac0ff, 0.5, 20); lamp.Position.SetXYZ(0,3,0); gScene.Add(lamp);
  office:=BuildOffice; gScene.Add(office);

  NSApplication.sharedApplication;
  NSApp.setActivationPolicy(NSApplicationActivationPolicyRegular);
  appDel:=TAppDelegate.alloc.init; NSApp.setDelegate(NSApplicationDelegateProtocol(appDel));

  rect:=NSMakeRect(0,0,W,H);
  win:=NSWindow.alloc.initWithContentRect_styleMask_backing_defer(rect,
    NSTitledWindowMask or NSClosableWindowMask or NSMiniaturizableWindowMask, NSBackingStoreBuffered, False);
  win.setTitle(NSSTR('Tina4 3D — Walkable Office'));
  win.center; win.setAcceptsMouseMovedEvents(True);
  gView:=TOfficeView.alloc.initWithFrame(rect);
  gView.setWantsLayer(True);                        // layer-backed → GPU-composited blit
  win.setContentView(gView);
  win.makeFirstResponder(gView);
  win.makeKeyAndOrderFront(nil);
  NSApp.activateIgnoringOtherApps(True);
  Lock;                                                 // capture the mouse on launch

  ticker:=TTicker.alloc.init;
  NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats(1/60, ticker, objcselector('tick:'), nil, True);
  pool.drain;
  NSApp.run;
end.
