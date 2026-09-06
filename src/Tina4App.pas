unit Tina4App;

(*
  Tina4App - one cross-platform native-app host for a Tina4Pascal project.

  A scaffolded project's src/app/main.pas is tiny: it sets mode+H, includes the
  app.rc resource for the exe icon, uses Tina4App, and calls RunApp with the
  window title, the template dir + entry template, a JSON context, the icon PNG,
  and the initial size.

  RunApp opens a native window on the current OS (Win32/GDI, X11, or Cocoa),
  renders the Frond/Twig template through the shared Tina4Interact engine, wears
  the given icon, and runs the event loop - HTML/CSS drives everything, the same
  engine on every platform.
*)

{$mode objfpc}{$H+}

interface

{ Title      window caption
  TemplateDir/Template  Frond/Twig template to render (dir + entry file)
  JsonContext           template variables, e.g. '{"name":"World"}'
  IconPath              PNG for the window/taskbar icon ('' = none)
  W,H        initial window size }
procedure RunApp(const Title, TemplateDir, Template, JsonContext, IconPath: string;
  W, H: Integer);

implementation

uses
  SysUtils, Classes,
{$IFDEF WINDOWS}
  Windows, Tina4RenderBackend, Tina4ShellWin, Tina4Interact;
{$ENDIF}
{$IFDEF LINUX}
  ctypes, Tina4RenderBackend, Tina4ShellLinux, Tina4Interact;
{$ENDIF}
{$IFDEF DARWIN}
  Tina4RenderBackend, Tina4ShellCocoa, Tina4Interact;
{$ENDIF}

{ Render the requested template into the engine's DOM. TinaRenderTemplate takes
  the template TEXT (with {% include %}/{% extends %} resolved from the template
  dir), so we load the entry file's contents and hand them over. }
procedure LoadUI(const TemplateDir, Template, JsonContext: string);
var path, body: string; sl: TStringList;
begin
  if TemplateDir <> '' then TinaSetTemplateDir(TemplateDir);
  if Template <> '' then
  begin
    if TemplateDir <> '' then path := IncludeTrailingPathDelimiter(TemplateDir) + Template
    else path := Template;
    if FileExists(path) then
    begin
      sl := TStringList.Create;
      try sl.LoadFromFile(path); body := sl.Text; finally sl.Free; end;
      TinaRenderTemplate(body, JsonContext);
    end
    else
      TinaSetHtml('<h1 style="font-family:sans-serif;padding:24px;color:#c0392b">Template not found: ' + Template + '</h1>');
  end
  else
    TinaSetHtml('<h1 style="font-family:sans-serif;padding:24px">Hello World!</h1>');
end;

{$IFDEF WINDOWS}
{ ---- Windows / Win32 + GDI ---- }
var
  GCanvas: TWinCanvas;
  GHwnd: HWND;
  GW: Integer = 1024;
  GH: Integer = 768;
  GMouseDown: Boolean = False;

procedure WRepaint; begin InvalidateRect(GHwnd, nil, False); end;

procedure WPaint(dc: HDC);
var mem: HDC; dib, oldb: HGDIOBJ; r: Windows.RECT; white: HBRUSH; bmi: BITMAPINFO; bits: PByte; i: Integer;
begin
  mem := CreateCompatibleDC(dc);
  FillChar(bmi, SizeOf(bmi), 0);
  bmi.bmiHeader.biSize := SizeOf(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth := GW; bmi.bmiHeader.biHeight := -GH;
  bmi.bmiHeader.biPlanes := 1; bmi.bmiHeader.biBitCount := 32; bmi.bmiHeader.biCompression := BI_RGB;
  bits := nil; dib := CreateDIBSection(0, bmi, DIB_RGB_COLORS, bits, 0, 0);
  oldb := SelectObject(mem, dib);
  r.Left := 0; r.Top := 0; r.Right := GW; r.Bottom := GH;
  white := CreateSolidBrush($00FFFFFF); Windows.FillRect(mem, r, white); DeleteObject(white);
  GdiFlush;
  if bits <> nil then for i := 0 to GW * GH - 1 do bits[i*4+3] := 255;
  GCanvas.BeginFrame(mem, bits, GW, GH);
  TinaFrame(GW, GH, 1.0);
  GdiFlush;
  BitBlt(dc, 0, 0, GW, GH, mem, 0, 0, SRCCOPY);
  SelectObject(mem, oldb); DeleteObject(dib); DeleteDC(mem);
end;

function WWndProc(hwnd: HWND; msg: UINT; wp: WPARAM; lp: LPARAM): LRESULT; stdcall;
var ps: PAINTSTRUCT; dc: HDC; x, y, dz: Integer;
begin
  Result := 0;
  case msg of
    WM_PAINT: begin dc := BeginPaint(hwnd, ps); WPaint(dc); EndPaint(hwnd, ps); end;
    WM_ERASEBKGND: Result := 1;
    WM_SIZE: begin GW := SmallInt(lp and $FFFF); GH := SmallInt((lp shr 16) and $FFFF); WRepaint; end;
    WM_LBUTTONDOWN: begin GMouseDown := True; SetCapture(hwnd);
      x := SmallInt(lp and $FFFF); y := SmallInt((lp shr 16) and $FFFF); TinaTouch(0, x, y); WRepaint; end;
    WM_LBUTTONUP: begin GMouseDown := False; ReleaseCapture;
      x := SmallInt(lp and $FFFF); y := SmallInt((lp shr 16) and $FFFF); TinaTouch(1, x, y); WRepaint; end;
    WM_MOUSEMOVE: begin x := SmallInt(lp and $FFFF); y := SmallInt((lp shr 16) and $FFFF);
      if GMouseDown then begin TinaTouch(2, x, y); WRepaint; end else TinaHover(x, y); end;
    WM_MOUSEWHEEL: begin dz := SmallInt((wp shr 16) and $FFFF); TinaScrollBy(GW div 2, GH div 2, 0, -dz); WRepaint; end;
    WM_CHAR: begin TinaKey(Integer(wp)); WRepaint; end;
    WM_TIMER: if TinaTick = 1 then WRepaint;
    WM_DESTROY: PostQuitMessage(0);
  else
    Result := DefWindowProcW(hwnd, msg, wp, lp);
  end;
end;

procedure RunApp(const Title, TemplateDir, Template, JsonContext, IconPath: string; W, H: Integer);
var wc: WNDCLASSEXW; m: MSG; cls, cap: UnicodeString; ico: HICON;
begin
  GW := W; GH := H;
  cls := 'Tina4AppWindow';
  FillChar(wc, SizeOf(wc), 0);
  wc.cbSize := SizeOf(wc); wc.style := CS_HREDRAW or CS_VREDRAW;
  wc.lpfnWndProc := @WWndProc; wc.hInstance := HInstance;
  wc.hCursor := LoadCursor(0, IDC_ARROW); wc.hbrBackground := 0;
  wc.lpszClassName := PWideChar(cls);
  RegisterClassExW(wc);
  cap := UnicodeString(Title);
  GHwnd := CreateWindowExW(0, PWideChar(cls), PWideChar(cap), WS_OVERLAPPEDWINDOW,
    CW_USEDEFAULT, CW_USEDEFAULT, W, H, 0, 0, HInstance, nil);
  if IconPath <> '' then
  begin
    ico := WinLoadHIcon(IconPath);
    if ico <> 0 then
    begin
      SendMessageW(GHwnd, WM_SETICON, ICON_BIG, LPARAM(ico));
      SendMessageW(GHwnd, WM_SETICON, ICON_SMALL, LPARAM(ico));
    end;
  end;
  GCanvas := TWinCanvas.Create;
  TinaInit(GCanvas);
  LoadUI(TemplateDir, Template, JsonContext);
  SetWindowTextW(GHwnd, PWideChar(cap));
  SetTimer(GHwnd, 1, 16, nil);
  ShowWindow(GHwnd, SW_SHOW); UpdateWindow(GHwnd);
  while GetMessage(m, 0, 0, 0) do begin TranslateMessage(m); DispatchMessage(m); end;
end;
{$ENDIF}

{$IFDEF LINUX}
{ ---- Linux / X11 ---- }
const
  ExposureMask = 1 shl 15; ButtonPressMask = 1 shl 2; ButtonReleaseMask = 1 shl 3;
  PointerMotionMask = 1 shl 6; StructureNotifyMask = 1 shl 17;
  Expose_ = 12; ButtonPress_ = 4; ButtonRelease_ = 5; MotionNotify_ = 6;
  ConfigureNotify_ = 22; ClientMessage_ = 33;
  OFF_X = 64; OFF_Y = 68; OFF_CFG_W = 56; OFF_CFG_H = 60; OFF_EXPOSE_COUNT = 56; OFF_CM_DATA0 = 56;

function XOpenDisplay(name: PChar): PXDisplay; cdecl; external 'X11';
function XCloseDisplay(d: PXDisplay): cint; cdecl; external 'X11';
function XDefaultScreen(d: PXDisplay): cint; cdecl; external 'X11';
function XRootWindow(d: PXDisplay; s: cint): TXID; cdecl; external 'X11';
function XDefaultDepth(d: PXDisplay; s: cint): cint; cdecl; external 'X11';
function XWhitePixel(d: PXDisplay; s: cint): culong; cdecl; external 'X11';
function XBlackPixel(d: PXDisplay; s: cint): culong; cdecl; external 'X11';
function XCreateSimpleWindow(d: PXDisplay; parent: TXID; x, y: cint; w, h, bw: cuint; border, bg: culong): TXID; cdecl; external 'X11';
function XStoreName(d: PXDisplay; w: TXID; name: PChar): cint; cdecl; external 'X11';
function XSelectInput(d: PXDisplay; w: TXID; mask: clong): cint; cdecl; external 'X11';
function XMapWindow(d: PXDisplay; w: TXID): cint; cdecl; external 'X11';
function XCreatePixmap(d: PXDisplay; drw: TXID; w, h, depth: cuint): TXID; cdecl; external 'X11';
function XFreePixmap(d: PXDisplay; p: TXID): cint; cdecl; external 'X11';
function XCreateGC(d: PXDisplay; drw: TXID; mask: culong; values: Pointer): TGC; cdecl; external 'X11';
function XCopyArea(d: PXDisplay; src, dst: TXID; gc: TGC; sx, sy: cint; w, h: cuint; dx, dy: cint): cint; cdecl; external 'X11';
function XFlush(d: PXDisplay): cint; cdecl; external 'X11';
function XNextEvent(d: PXDisplay; ev: Pointer): cint; cdecl; external 'X11';
function XInternAtom(d: PXDisplay; name: PChar; only_if: cint): TXID; cdecl; external 'X11';
function XSetWMProtocols(d: PXDisplay; w: TXID; protocols: Pointer; count: cint): cint; cdecl; external 'X11';

function LI32(const ev; off: Integer): cint; begin Result := PInt32(PByte(@ev) + off)^; end;

procedure RunApp(const Title, TemplateDir, Template, JsonContext, IconPath: string; W, H: Integer);
var
  dpy: PXDisplay; scr: cint; win, pixmap: TXID; gc: TGC; canvas: TX11Canvas;
  GWv, GHv, pmW, pmH: cint; mouseDown: Boolean; wmDelete: TXID; ev: array[0..191] of Byte; etype: Integer;

  procedure EnsurePixmap;
  begin
    if (pixmap = 0) or (pmW <> GWv) or (pmH <> GHv) then
    begin
      if pixmap <> 0 then XFreePixmap(dpy, pixmap);
      pixmap := XCreatePixmap(dpy, XRootWindow(dpy, scr), GWv, GHv, XDefaultDepth(dpy, scr));
      pmW := GWv; pmH := GHv;
    end;
  end;
  procedure Render;
  begin
    EnsurePixmap; canvas.BeginFrame(pixmap, GWv, GHv); TinaFrame(GWv, GHv, 1.0);
    XCopyArea(dpy, pixmap, win, gc, 0, 0, GWv, GHv, 0, 0); XFlush(dpy);
  end;
begin
  GWv := W; GHv := H; pixmap := 0; pmW := 0; pmH := 0; mouseDown := False;
  dpy := XOpenDisplay(nil);
  if dpy = nil then begin Writeln('cannot open X display (set DISPLAY)'); Halt(1); end;
  scr := XDefaultScreen(dpy);
  gc := XCreateGC(dpy, XRootWindow(dpy, scr), 0, nil);
  win := XCreateSimpleWindow(dpy, XRootWindow(dpy, scr), 0, 0, GWv, GHv, 0,
    XBlackPixel(dpy, scr), XWhitePixel(dpy, scr));
  XStoreName(dpy, win, PChar(Title));
  XSelectInput(dpy, win, ExposureMask or ButtonPressMask or ButtonReleaseMask or
    PointerMotionMask or StructureNotifyMask);
  wmDelete := XInternAtom(dpy, 'WM_DELETE_WINDOW', 0);
  XSetWMProtocols(dpy, win, @wmDelete, 1);
  XMapWindow(dpy, win);
  canvas := TX11Canvas.Create(dpy, scr, gc);
  TinaInit(canvas);
  LoadUI(TemplateDir, Template, JsonContext);
  while True do
  begin
    XNextEvent(dpy, @ev); etype := LI32(ev, 0);
    case etype of
      Expose_: if LI32(ev, OFF_EXPOSE_COUNT) = 0 then Render;
      ConfigureNotify_: if (LI32(ev, OFF_CFG_W) > 0) and (LI32(ev, OFF_CFG_H) > 0) then
        begin GWv := LI32(ev, OFF_CFG_W); GHv := LI32(ev, OFF_CFG_H); end;
      ButtonPress_: begin mouseDown := True; TinaTouch(0, LI32(ev, OFF_X), LI32(ev, OFF_Y)); Render; end;
      ButtonRelease_: begin mouseDown := False; TinaTouch(1, LI32(ev, OFF_X), LI32(ev, OFF_Y)); Render; end;
      MotionNotify_: if mouseDown then begin TinaTouch(2, LI32(ev, OFF_X), LI32(ev, OFF_Y)); Render; end
        else TinaHover(LI32(ev, OFF_X), LI32(ev, OFF_Y));
      ClientMessage_: if TXID(PPtrUInt(PByte(@ev) + OFF_CM_DATA0)^) = wmDelete then Break;
    end;
  end;
  XCloseDisplay(dpy);
end;
{$ENDIF}

{$IFDEF DARWIN}
{ ---- macOS / Cocoa ---- wires TCocoaShell into the shared Tina4Interact engine }
var
  GShell: TCocoaShell;

procedure MPaint(Canvas: TTina4Canvas; W, H: Single);
begin TinaFrame(Round(W), Round(H), 1.0); end;
procedure MDown(X, Y: Single); begin TinaTouch(0, X, Y); GShell.Invalidate; end;
procedure MUp(X, Y: Single);   begin TinaTouch(1, X, Y); GShell.Invalidate; end;
procedure MMove(X, Y: Single); begin TinaHover(X, Y); end;
procedure MDrag(X, Y: Single); begin TinaTouch(2, X, Y); GShell.Invalidate; end;
procedure MScroll(X, Y, DX, DY: Single); begin TinaScrollBy(X, Y, DX, DY); GShell.Invalidate; end;
procedure MTick; begin if TinaTick = 1 then GShell.Invalidate; end;

procedure RunApp(const Title, TemplateDir, Template, JsonContext, IconPath: string; W, H: Integer);
begin
  GShell := TCocoaShell.Create;
  TinaInit(GShell.GetMeasuringCanvas);
  LoadUI(TemplateDir, Template, JsonContext);
  GShell.OnPaint := @MPaint;
  GShell.OnMouseDown := @MDown;
  GShell.OnMouseUp := @MUp;
  GShell.OnMouseMove := @MMove;
  GShell.OnMouseDrag := @MDrag;
  GShell.OnScroll := @MScroll;
  GShell.OnTick := @MTick;
  GShell.Initialize(W, H, Title);
  GShell.StartTicker(16);
  GShell.Run;
end;
{$ENDIF}

end.
