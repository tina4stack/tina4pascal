unit Tina3D;

{ The macOS "DOM" for ThreePascal — following three.js's proven pattern: the APP
  owns the render loop. You create a window bound to a renderer (three.js's
  renderer.domElement appended to the page), then drive it yourself:

    procedure Animate;
    begin
      RequestAnimationFrame(@Animate);       // like requestAnimationFrame(animate)
      controls.Update; ...                   // update state
      renderer.Render(scene, camera);        // renderer.render(scene, camera)
      Present;                               // composite the frame (browser does this for you)
    end;
    begin CreateWindow('title', w, h, renderer); RequestAnimationFrame(@Animate); Run; end.

  The engine provides the surface, the loop pump, GPU present, input state, and a
  WalkControls helper (three.js PointerLockControls analogue). No Cocoa in apps. }

{$mode delphi}{$H+}
{$modeswitch objectivec1}

interface

uses ThreePascal;

type TRAFProc = procedure;

procedure CreateWindow(const title: string; w, h: Integer; renderer: TWebGLRenderer);
procedure RequestAnimationFrame(cb: TRAFProc);
procedure Present;                                  // show renderer's current frame (+ FPS)
procedure Run;                                      // enter the event loop

{ input — polled, like reading DOM events }
function  KeyPressed(code: Integer): Boolean;
procedure PointerLock; procedure PointerUnlock;
function  ConsumeMouseDX: Single; function ConsumeMouseDY: Single;

{ three.js PointerLockControls analogue: WASD + mouse-look, bounded, fixed eye height }
procedure WalkControls(cam: TPerspectiveCamera; boundX, boundZ: Single);

const
  KEY_W=13; KEY_A=0; KEY_S=1; KEY_D=2; KEY_LEFT=123; KEY_RIGHT=124; KEY_DOWN=125; KEY_UP=126;

implementation

uses CocoaAll, SysUtils, Math, MacBlit;

{$linkframework CoreGraphics}
function CGAssociateMouseAndMouseCursorPosition(connected: LongInt): LongInt; cdecl; external;

var
  gRend: TWebGLRenderer; gPending: TRAFProc = nil;
  gKeys: array[0..127] of Boolean; gMDX: Single = 0; gMDY: Single = 0;
  gLocked: Boolean = False; gFPS: Single = 0; gLastMs: QWord = 0;
  gWalkInit: Boolean = False; gPX, gPY, gPZ, gYaw, gPitch: Single;

procedure PointerLock;   begin if gLocked then Exit; NSCursor.hide; CGAssociateMouseAndMouseCursorPosition(0); gLocked:=True; end;
procedure PointerUnlock; begin if not gLocked then Exit; CGAssociateMouseAndMouseCursorPosition(1); NSCursor.unhide; gLocked:=False; end;
function KeyPressed(code: Integer): Boolean; begin Result:=(code>=0) and (code<128) and gKeys[code]; end;
function ConsumeMouseDX: Single; begin Result:=gMDX; gMDX:=0; end;
function ConsumeMouseDY: Single; begin Result:=gMDY; gMDY:=0; end;

type
  T3DView = objcclass(NSView)
    function isFlipped: ObjCBOOL; override;
    function acceptsFirstResponder: ObjCBOOL; override;
    procedure drawRect(dirty: NSRect); override;
    procedure keyDown(e: NSEvent); override;
    procedure keyUp(e: NSEvent); override;
    procedure mouseMoved(e: NSEvent); override;
    procedure mouseDown(e: NSEvent); override;
  end;
  T3DTicker = objcclass(NSObject) procedure tick(t: NSTimer); message 'tick:'; end;
  T3DDelegate = objcclass(NSObject, NSApplicationDelegateProtocol)
    function applicationShouldTerminateAfterLastWindowClosed(s: NSApplication): ObjCBOOL; message 'applicationShouldTerminateAfterLastWindowClosed:';
    procedure applicationWillTerminate(n: NSNotification); message 'applicationWillTerminate:';
  end;

var gView: T3DView = nil;

function T3DView.isFlipped: ObjCBOOL; begin Result:=False; end;
function T3DView.acceptsFirstResponder: ObjCBOOL; begin Result:=True; end;
procedure T3DView.drawRect(dirty: NSRect); begin end;
procedure T3DView.mouseDown(e: NSEvent); begin PointerLock; end;
procedure T3DView.mouseMoved(e: NSEvent); begin if gLocked then begin gMDX:=gMDX+e.deltaX; gMDY:=gMDY+e.deltaY; end; end;
procedure T3DView.keyDown(e: NSEvent);
begin
  case e.keyCode of
    53: begin PointerUnlock; NSApp.terminate(nil); end;
    7:  if (gRend<>nil) then begin if gRend.Samples=1 then gRend.SetSamples(2) else gRend.SetSamples(1); end;
  end;
  if e.keyCode<128 then gKeys[e.keyCode]:=True;
end;
procedure T3DView.keyUp(e: NSEvent); begin if e.keyCode<128 then gKeys[e.keyCode]:=False; end;

{ the pump — fires the app's pending rAF callback (which renders + reschedules) }
procedure T3DTicker.tick(t: NSTimer);
var cb: TRAFProc;
begin
  if Assigned(gPending) then begin cb:=gPending; gPending:=nil; cb(); end;
end;

function T3DDelegate.applicationShouldTerminateAfterLastWindowClosed(s: NSApplication): ObjCBOOL; begin Result:=True; end;
procedure T3DDelegate.applicationWillTerminate(n: NSNotification); begin PointerUnlock; end;

procedure CreateWindow(const title: string; w, h: Integer; renderer: TWebGLRenderer);
var win: NSWindow; rect: NSRect; del: T3DDelegate; ticker: T3DTicker;
begin
  gRend:=renderer;
  NSApplication.sharedApplication;
  NSApp.setActivationPolicy(NSApplicationActivationPolicyRegular);
  del:=T3DDelegate.alloc.init; NSApp.setDelegate(NSApplicationDelegateProtocol(del));
  rect:=NSMakeRect(0,0,w,h);
  win:=NSWindow.alloc.initWithContentRect_styleMask_backing_defer(rect,
    NSTitledWindowMask or NSClosableWindowMask or NSMiniaturizableWindowMask, NSBackingStoreBuffered, False);
  win.setTitle(NSSTR(PChar(title))); win.center; win.setAcceptsMouseMovedEvents(True);
  gView:=T3DView.alloc.initWithFrame(rect); gView.setWantsLayer(True);
  win.setContentView(gView); win.makeFirstResponder(gView); win.makeKeyAndOrderFront(nil);
  NSApp.activateIgnoringOtherApps(True);
  ticker:=T3DTicker.alloc.init;
  NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats(1/60, ticker, objcselector('tick:'), nil, True);
end;

procedure RequestAnimationFrame(cb: TRAFProc); begin gPending:=cb; end;

procedure Present;
var now, dt: QWord;
begin
  if gRend=nil then Exit;
  now:=GetTickCount64; if gLastMs>0 then dt:=now-gLastMs else dt:=16; gLastMs:=now;
  if dt<1 then dt:=1; gFPS:=gFPS*0.85 + (1000.0/dt)*0.15;
  gRend.FillRectPx(gRend.Width-116, 0, 116, 28, 14,15,31, 0.6);
  gRend.DrawTextPx(gRend.Width-106, 8, 'FPS '+IntToStr(Round(gFPS))+'  '+IntToStr(dt)+'MS', 2, 79,209,139);
  MacBlit.Present(gView, @gRend.Pixels[0], gRend.Width, gRend.Height);
end;

procedure Run; begin NSApp.run; end;

procedure WalkControls(cam: TPerspectiveCamera; boundX, boundZ: Single);
const SPD=0.11; ROT=0.03; SENS=0.0026;
var fx, fz, rx, rz, tx, ty, tz: Single;
begin
  if not gWalkInit then
  begin gPX:=cam.Position.x; gPY:=cam.Position.y; gPZ:=cam.Position.z; gYaw:=0; gPitch:=-0.05; gWalkInit:=True; end;
  gYaw:=gYaw + ConsumeMouseDX*SENS; gPitch:=gPitch - ConsumeMouseDY*SENS;
  if KeyPressed(KEY_LEFT) then gYaw:=gYaw-ROT; if KeyPressed(KEY_RIGHT) then gYaw:=gYaw+ROT;
  if KeyPressed(KEY_UP) then gPitch:=gPitch+ROT; if KeyPressed(KEY_DOWN) then gPitch:=gPitch-ROT;
  if gPitch>1.2 then gPitch:=1.2; if gPitch<-1.2 then gPitch:=-1.2;
  fx:=Sin(gYaw); fz:=-Cos(gYaw); rx:=Cos(gYaw); rz:=Sin(gYaw);
  if KeyPressed(KEY_W) then begin gPX:=gPX+fx*SPD; gPZ:=gPZ+fz*SPD; end;
  if KeyPressed(KEY_S) then begin gPX:=gPX-fx*SPD; gPZ:=gPZ-fz*SPD; end;
  if KeyPressed(KEY_A) then begin gPX:=gPX-rx*SPD; gPZ:=gPZ-rz*SPD; end;
  if KeyPressed(KEY_D) then begin gPX:=gPX+rx*SPD; gPZ:=gPZ+rz*SPD; end;
  if gPX>boundX then gPX:=boundX; if gPX<-boundX then gPX:=-boundX;
  if gPZ>boundZ then gPZ:=boundZ; if gPZ<-boundZ then gPZ:=-boundZ;
  tx:=gPX+Sin(gYaw)*Cos(gPitch); ty:=gPY+Sin(gPitch); tz:=gPZ-Cos(gYaw)*Cos(gPitch);
  cam.Position.SetXYZ(gPX, gPY, gPZ); cam.LookAt(tx, ty, tz);
end;

end.
