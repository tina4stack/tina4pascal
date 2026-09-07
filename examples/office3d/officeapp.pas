program officeapp;

{ Walk the office in first person — pure-software ThreePascal render blitted into
  a Cocoa window. WASD to move, arrow keys to look, Esc to quit. No logins, no
  video — just the space. }

{$mode delphi}{$H+}
{$modeswitch objectivec1}

uses CocoaAll, SysUtils, Math, ThreePascal, OfficeScene;

const W = 900; H = 600;

var
  gScene: TScene; gCam: TPerspectiveCamera; gRend: TWebGLRenderer;
  gPX: Single = 0; gPY: Single = 1.55; gPZ: Single = 8.0;
  gYaw: Single = 0; gPitch: Single = -0.05;
  gKeys: array[0..127] of Boolean;

type
  TOfficeView = objcclass(NSView)
    function isFlipped: ObjCBOOL; override;
    function acceptsFirstResponder: ObjCBOOL; override;
    procedure drawRect(dirty: NSRect); override;
    procedure keyDown(e: NSEvent); override;
    procedure keyUp(e: NSEvent); override;
  end;
  TTicker = objcclass(NSObject)
    procedure tick(t: NSTimer); message 'tick:';
  end;
  TAppDelegate = objcclass(NSObject, NSApplicationDelegateProtocol)
    function applicationShouldTerminateAfterLastWindowClosed(sender: NSApplication): ObjCBOOL;
      message 'applicationShouldTerminateAfterLastWindowClosed:';
  end;

var gView: TOfficeView = nil;

function FrameBMP: TBytes;
var w,h,rowsize,pad,datasize,off,row,col,i,si: Integer;
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
    begin si:=(row*w+col)*4;
      Result[off]:=gRend.Pixels[si+2]; Result[off+1]:=gRend.Pixels[si+1]; Result[off+2]:=gRend.Pixels[si+0]; off:=off+3; end;
    for col:=1 to pad do begin Result[off]:=0; Inc(off); end;
  end;
end;

function TOfficeView.isFlipped: ObjCBOOL; begin Result := False; end;
function TOfficeView.acceptsFirstResponder: ObjCBOOL; begin Result := True; end;

procedure TOfficeView.drawRect(dirty: NSRect);
var bmp: TBytes; d: NSData; im: NSImage;
begin
  if System.Length(gRend.Pixels)=0 then Exit;
  bmp:=FrameBMP;
  d:=NSData.dataWithBytes_length(@bmp[0], System.Length(bmp));
  im:=NSImage(NSImage.alloc.initWithData(d));
  if im<>nil then begin im.drawInRect_fromRect_operation_fraction(bounds, NSZeroRect, NSCompositeSourceOver, 1.0); im.release; end;
end;

procedure TOfficeView.keyDown(e: NSEvent);
begin
  if e.keyCode = 53 then NSApp.terminate(nil);        // Esc
  if e.keyCode < 128 then gKeys[e.keyCode] := True;
end;
procedure TOfficeView.keyUp(e: NSEvent);
begin if e.keyCode < 128 then gKeys[e.keyCode] := False; end;

procedure TTicker.tick(t: NSTimer);
var spd, rot, fx, fz, rx, rz, tx, ty, tz: Single;
begin
  spd:=0.11; rot:=0.035;
  if gKeys[123] then gYaw:=gYaw - rot;                 // left
  if gKeys[124] then gYaw:=gYaw + rot;                 // right
  if gKeys[126] then gPitch:=gPitch + rot;             // up
  if gKeys[125] then gPitch:=gPitch - rot;             // down
  if gPitch> 1.2 then gPitch:= 1.2; if gPitch<-1.2 then gPitch:=-1.2;
  fx:=Sin(gYaw); fz:=-Cos(gYaw);                       // forward (horizontal)
  rx:=Cos(gYaw); rz:=Sin(gYaw);                        // right
  if gKeys[13] then begin gPX:=gPX+fx*spd; gPZ:=gPZ+fz*spd; end;   // W
  if gKeys[1]  then begin gPX:=gPX-fx*spd; gPZ:=gPZ-fz*spd; end;   // S
  if gKeys[0]  then begin gPX:=gPX-rx*spd; gPZ:=gPZ-rz*spd; end;   // A
  if gKeys[2]  then begin gPX:=gPX+rx*spd; gPZ:=gPZ+rz*spd; end;   // D
  if gPX> ROOM_X then gPX:=ROOM_X; if gPX<-ROOM_X then gPX:=-ROOM_X;
  if gPZ> ROOM_Z then gPZ:=ROOM_Z; if gPZ<-ROOM_Z then gPZ:=-ROOM_Z;

  tx:=gPX + Sin(gYaw)*Cos(gPitch); ty:=gPY + Sin(gPitch); tz:=gPZ - Cos(gYaw)*Cos(gPitch);
  gCam.Position.SetXYZ(gPX, gPY, gPZ); gCam.LookAt(tx, ty, tz);
  gRend.Render(gScene, gCam);

  { HUD }
  gRend.FillRectPx(W div 2 - 7, H div 2 - 1, 14, 2, 255,255,255, 0.7);
  gRend.FillRectPx(W div 2 - 1, H div 2 - 7, 2, 14, 255,255,255, 0.7);
  gRend.FillRectPx(0, 0, W, 30, 14,15,31, 0.66);
  gRend.DrawTextPx(14, 9, 'TINA4 OFFICE - WASD MOVE - ARROWS LOOK - ESC QUIT', 2, 236,236,251);
  if gView<>nil then gView.setNeedsDisplay_(True);
end;

function TAppDelegate.applicationShouldTerminateAfterLastWindowClosed(sender: NSApplication): ObjCBOOL;
begin Result := True; end;

var
  pool: NSAutoreleasePool; win: NSWindow; rect: NSRect;
  ticker: TTicker; appDel: TAppDelegate;
  amb: TAmbientLight; sun: TDirectionalLight; lamp: TPointLight; office: TGroup;
begin
  pool:=NSAutoreleasePool.alloc.init;

  gScene:=TScene.Create; gScene.Background.SetHex($0e0f1f);
  gScene.Fog:=TFog.Create($0e0f1f, 22, 46);
  gCam:=TPerspectiveCamera.Create(60, W/H, 0.05, 100);
  gRend:=TWebGLRenderer.Create(W, H, 2);                // 2x AA

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
  win.center;
  gView:=TOfficeView.alloc.initWithFrame(rect);
  win.setContentView(gView);
  win.makeFirstResponder(gView);
  win.makeKeyAndOrderFront(nil);
  NSApp.activateIgnoringOtherApps(True);

  ticker:=TTicker.alloc.init;
  NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats(1/30, ticker, objcselector('tick:'), nil, True);
  pool.drain;
  NSApp.run;
end.
