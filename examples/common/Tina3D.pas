unit Tina3D;

{ The desktop "DOM" for ThreePascal — following three.js's proven pattern: the
  APP owns the render loop. You create a window bound to a renderer (three.js's
  renderer.domElement appended to the page), then drive it yourself:

    procedure Animate;
    begin
      RequestAnimationFrame(@Animate);       // like requestAnimationFrame(animate)
      controls.Update; ...                   // update state
      renderer.Render(scene, camera);        // renderer.render(scene, camera)
      Present;                               // composite the frame (browser does this for you)
    end;
    begin CreateWindow('title', w, h, renderer); RequestAnimationFrame(@Animate); Run; end.

  The engine provides the surface, the loop pump, present, input state, and a
  WalkControls helper (three.js PointerLockControls analogue). No OS calls in
  apps. macOS uses Cocoa + a CADisplayLink; Windows uses a Win32 window and a
  DIB blit of the renderer's RGBA framebuffer — the same buffer the Android
  shell blits. The app source is identical on both. }

{$mode delphi}{$H+}
{$IFDEF DARWIN}{$modeswitch objectivec1}{$ENDIF}

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

uses SysUtils, Math
  {$IFDEF DARWIN}, CocoaAll, MacBlit{$ENDIF}
  {$IFDEF WINDOWS}, Windows{$ENDIF};

{ ---- shared state + pure helpers (platform-agnostic) --------------------- }
var
  gRend: TWebGLRenderer; gPending: TRAFProc = nil;
  gKeys: array[0..255] of Boolean; gMDX: Single = 0; gMDY: Single = 0;
  gLocked: Boolean = False; gFPS: Single = 0; gLastMs: QWord = 0;
  gWalkInit: Boolean = False; gPX, gPY, gPZ, gYaw, gPitch: Single;

function KeyPressed(code: Integer): Boolean; begin Result:=(code>=0) and (code<256) and gKeys[code]; end;
function ConsumeMouseDX: Single; begin Result:=gMDX; gMDX:=0; end;
function ConsumeMouseDY: Single; begin Result:=gMDY; gMDY:=0; end;

procedure RequestAnimationFrame(cb: TRAFProc); begin gPending:=cb; end;

{ FPS meter drawn into the renderer's own framebuffer (cross-platform). }
procedure DrawFps;
var now, dt: QWord;
begin
  now:=GetTickCount64; if gLastMs>0 then dt:=now-gLastMs else dt:=16; gLastMs:=now;
  if dt<1 then dt:=1; gFPS:=gFPS*0.85 + (1000.0/dt)*0.15;
  gRend.FillRectPx(gRend.Width-116, 0, 116, 28, 14,15,31, 0.6);
  gRend.DrawTextPx(gRend.Width-106, 8, 'FPS '+IntToStr(Round(gFPS))+'  '+IntToStr(dt)+'MS', 2, 79,209,139);
end;

{$IFDEF DARWIN}
{ ============================ macOS / Cocoa ============================== }
{$linkframework CoreGraphics}
{$linkframework QuartzCore}
function CGAssociateMouseAndMouseCursorPosition(connected: LongInt): LongInt; cdecl; external;

type
  CAFrameRateRange = record minimum, maximum, preferred: single; end;
  CADisplayLink = objcclass external (NSObject)
    procedure addToRunLoop_forMode(rl: NSRunLoop; mode: NSString); message 'addToRunLoop:forMode:';
    procedure setPreferredFrameRateRange(r: CAFrameRateRange); message 'setPreferredFrameRateRange:';
    procedure invalidate; message 'invalidate';
  end;
  NSViewDisplayLink = objccategory external (NSView)
    function displayLinkWithTarget_selector(target: id; sel: SEL): CADisplayLink; message 'displayLinkWithTarget:selector:';
  end;

procedure PointerLock;   begin if gLocked then Exit; NSCursor.hide; CGAssociateMouseAndMouseCursorPosition(0); gLocked:=True; end;
procedure PointerUnlock; begin if not gLocked then Exit; CGAssociateMouseAndMouseCursorPosition(1); NSCursor.unhide; gLocked:=False; end;

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
  T3DTicker = objcclass(NSObject)
    procedure tick(t: NSTimer); message 'tick:';
    procedure frame(sender: id); message 'frame:';
  end;
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

procedure T3DTicker.tick(t: NSTimer);
var cb: TRAFProc;
begin if Assigned(gPending) then begin cb:=gPending; gPending:=nil; cb(); end; end;
procedure T3DTicker.frame(sender: id);
var cb: TRAFProc;
begin if Assigned(gPending) then begin cb:=gPending; gPending:=nil; cb(); end; end;

function T3DDelegate.applicationShouldTerminateAfterLastWindowClosed(s: NSApplication): ObjCBOOL; begin Result:=True; end;
procedure T3DDelegate.applicationWillTerminate(n: NSNotification); begin PointerUnlock; end;

procedure CreateWindow(const title: string; w, h: Integer; renderer: TWebGLRenderer);
var win: NSWindow; rect: NSRect; del: T3DDelegate; ticker: T3DTicker;
    dl: CADisplayLink; frr: CAFrameRateRange;
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
  dl:=gView.displayLinkWithTarget_selector(id(ticker), objcselector('frame:'));
  if dl<>nil then
  begin
    frr.minimum:=60; frr.maximum:=120; frr.preferred:=120;
    dl.setPreferredFrameRateRange(frr);
    dl.addToRunLoop_forMode(NSRunLoop.mainRunLoop, NSDefaultRunLoopMode);
  end
  else
    NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats(1/120, ticker, objcselector('tick:'), nil, True);
end;

procedure Present;
begin
  if gRend=nil then Exit;
  DrawFps;
  MacBlit.Present(gView, @gRend.Pixels[0], gRend.Width, gRend.Height);
end;

procedure Run; begin NSApp.run; end;
{$ENDIF}

{$IFDEF WINDOWS}
{ ============================ Windows / Win32 =========================== }
var
  gHwnd: HWND = 0; gW: Integer = 0; gH: Integer = 0;
  gBits: array of Byte;          // BGRA top-down DIB, filled from gRend.Pixels each frame

procedure PointerLock;   begin gLocked:=True; end;    // no cursor capture needed for the flock demo
procedure PointerUnlock; begin gLocked:=False; end;

{ RGBA (R,G,B,A) → 32bpp DIB (B,G,R,0), then blit to the window. }
procedure WinBlit;
var n, i: Integer; src: PByte; dst: PByte; bi: BITMAPINFO; dc: HDC; cr: TRect;
begin
  if (gHwnd=0) or (gRend=nil) then Exit;
  n := gRend.Width * gRend.Height;
  if Length(gBits) <> n*4 then SetLength(gBits, n*4);
  src := @gRend.Pixels[0]; dst := @gBits[0];
  for i := 0 to n-1 do
  begin
    dst[0] := src[2]; dst[1] := src[1]; dst[2] := src[0]; dst[3] := 0;   // B G R 0
    Inc(src, 4); Inc(dst, 4);
  end;
  FillChar(bi, SizeOf(bi), 0);
  bi.bmiHeader.biSize := SizeOf(BITMAPINFOHEADER);
  bi.bmiHeader.biWidth := gRend.Width;
  bi.bmiHeader.biHeight := -gRend.Height;    // negative = top-down
  bi.bmiHeader.biPlanes := 1;
  bi.bmiHeader.biBitCount := 32;
  bi.bmiHeader.biCompression := BI_RGB;
  dc := GetDC(gHwnd);
  GetClientRect(gHwnd, cr);                    // stretch to fill the (DPI-scaled) client
  StretchDIBits(dc, 0, 0, cr.Right, cr.Bottom, 0, 0, gRend.Width, gRend.Height,
    @gBits[0], bi, DIB_RGB_COLORS, SRCCOPY);
  ReleaseDC(gHwnd, dc);
end;

function VkToKey(vk: WPARAM): Integer;
begin
  case vk of
    Ord('W'): Result:=KEY_W; Ord('A'): Result:=KEY_A; Ord('S'): Result:=KEY_S; Ord('D'): Result:=KEY_D;
    VK_LEFT: Result:=KEY_LEFT; VK_RIGHT: Result:=KEY_RIGHT; VK_UP: Result:=KEY_UP; VK_DOWN: Result:=KEY_DOWN;
  else Result:=-1;
  end;
end;

function WndProc(hwnd: HWND; msg: UINT; wp: WPARAM; lp: LPARAM): LRESULT; stdcall;
var k: Integer;
begin
  Result := 0;
  case msg of
    WM_KEYDOWN:
      begin
        if wp = VK_ESCAPE then begin PostQuitMessage(0); Exit; end;
        k := VkToKey(wp); if (k>=0) and (k<256) then gKeys[k]:=True;
      end;
    WM_KEYUP: begin k := VkToKey(wp); if (k>=0) and (k<256) then gKeys[k]:=False; end;
    WM_PAINT: begin WinBlit; ValidateRect(hwnd, nil); end;
    WM_DESTROY: begin PostQuitMessage(0); end;
  else
    Result := DefWindowProcW(hwnd, msg, wp, lp);
  end;
end;

procedure CreateWindow(const title: string; w, h: Integer; renderer: TWebGLRenderer);
var wc: WNDCLASSW; cap: UnicodeString; r: TRect; style: DWORD;
begin
  gRend := renderer; gW := w; gH := h;
  FillChar(wc, SizeOf(wc), 0);
  wc.lpfnWndProc := @WndProc;
  wc.hInstance := HInstance;
  wc.hCursor := LoadCursor(0, IDC_ARROW);
  wc.hbrBackground := 0;
  wc.lpszClassName := 'Tina3DWindow';
  RegisterClassW(wc);
  { size the window so the CLIENT area is w×h }
  style := WS_OVERLAPPEDWINDOW;
  r.Left := 0; r.Top := 0; r.Right := w; r.Bottom := h;
  AdjustWindowRect(r, style, False);
  cap := UnicodeString(title);
  gHwnd := CreateWindowExW(0, 'Tina3DWindow', PWideChar(cap), style,
    CW_USEDEFAULT, CW_USEDEFAULT, r.Right-r.Left, r.Bottom-r.Top, 0, 0, HInstance, nil);
  ShowWindow(gHwnd, SW_SHOW); UpdateWindow(gHwnd);
end;

procedure Present;
begin
  if gRend=nil then Exit;
  DrawFps;
  WinBlit;
end;

{ game loop: pump messages, then run the pending rAF callback as fast as the
  software renderer allows (Sleep(1) when idle so we don't spin a core flat). }
procedure Run;
var msg: TMsg; cb: TRAFProc;
begin
  while True do
  begin
    while PeekMessageW(msg, 0, 0, 0, PM_REMOVE) do
    begin
      if msg.message = WM_QUIT then Exit;
      TranslateMessage(msg); DispatchMessageW(msg);
    end;
    if Assigned(gPending) then begin cb:=gPending; gPending:=nil; cb(); end
    else Sleep(1);
  end;
end;
{$ENDIF}

{ ---- shared: WalkControls (pure math over the input state) --------------- }
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
