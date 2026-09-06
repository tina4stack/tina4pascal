program htmlviewer_x11;

{ Linux/X11 host for the Tina4 renderer: a plain Xlib window that paints the
  engine through Tina4ShellLinux (Xlib canvas) into a back-buffer Pixmap and
  XCopyArea's it to the window, forwarding mouse events to Tina4Interact.

  Build (native on Linux, needs a libX11.so the linker can see):
    fpc -Mdelphi -Fu../../src -Fl<dir-with-libX11.so> htmlviewer_x11.pas
  Run:
    ./htmlviewer_x11 page.html            (defaults to the built-in @demo)
    ./htmlviewer_x11 page.html --snapshot out.bmp   (headless snapshot) }

{$mode objfpc}{$H+}{$PACKRECORDS C}

uses
  ctypes, SysUtils, Classes,
  Tina4RenderBackend, Tina4ShellLinux, Tina4Interact;

const
  ExposureMask       = 1 shl 15;
  ButtonPressMask    = 1 shl 2;
  ButtonReleaseMask  = 1 shl 3;
  PointerMotionMask  = 1 shl 6;
  StructureNotifyMask= 1 shl 17;
  Expose_          = 12;
  ButtonPress_     = 4;
  ButtonRelease_   = 5;
  MotionNotify_    = 6;
  ConfigureNotify_ = 22;
  ClientMessage_   = 33;
  // byte offsets into a 64-bit XEvent (see Xlib.h struct layouts)
  OFF_X = 64; OFF_Y = 68; OFF_CFG_W = 56; OFF_CFG_H = 60;
  OFF_EXPOSE_COUNT = 56; OFF_CM_DATA0 = 56;

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

var
  dpy: PXDisplay;
  scr: cint;
  win, pixmap: TXID;
  gc: TGC;
  canvas: TX11Canvas;
  GW: cint = 1024;
  GH: cint = 768;
  pmW: cint = 0;
  pmH: cint = 0;
  mouseDown: Boolean = False;
  wmDelete: TXID;

procedure LoadPage(const page: string);
var sl: TStringList; html: string;
begin
  html := '@demo';
  if (page <> '') and FileExists(page) then
  begin
    sl := TStringList.Create;
    try sl.LoadFromFile(page); html := sl.Text; finally sl.Free; end;
  end;
  TinaSetHtml(html);
end;

procedure EnsurePixmap;
begin
  if (pixmap = 0) or (pmW <> GW) or (pmH <> GH) then
  begin
    if pixmap <> 0 then XFreePixmap(dpy, pixmap);
    pixmap := XCreatePixmap(dpy, XRootWindow(dpy, scr), GW, GH, XDefaultDepth(dpy, scr));
    pmW := GW; pmH := GH;
  end;
end;

procedure Render;
begin
  EnsurePixmap;
  canvas.BeginFrame(pixmap, GW, GH);
  TinaFrame(GW, GH, 1.0);
  XCopyArea(dpy, pixmap, win, gc, 0, 0, GW, GH, 0, 0);
  XFlush(dpy);
end;

function I32(const ev; off: Integer): cint;
begin Result := PInt32(PByte(@ev) + off)^; end;

procedure RunSnapshot(const page, outPath: string);
begin
  GW := 1024; GH := 800;
  pixmap := XCreatePixmap(dpy, XRootWindow(dpy, scr), GW, GH, XDefaultDepth(dpy, scr));
  canvas := TX11Canvas.Create(dpy, scr, gc);
  TinaInit(canvas);
  LoadPage(page);
  canvas.BeginFrame(pixmap, GW, GH);
  TinaFrame(GW, GH, 1.0);
  XFlush(dpy);
  if LinSaveBmp(dpy, pixmap, GW, GH, outPath) then
    Writeln('snapshot -> ', outPath)
  else
    Writeln('snapshot FAILED');
end;

var
  ev: array[0..191] of Byte;
  page, snapOut: string;
  i, etype: Integer;
begin
  page := ''; snapOut := '';
  if (ParamCount >= 1) and (ParamStr(1) <> '') and (Copy(ParamStr(1),1,2) <> '--') then page := ParamStr(1);
  for i := 1 to ParamCount - 1 do
    if ParamStr(i) = '--snapshot' then snapOut := ParamStr(i + 1);

  dpy := XOpenDisplay(nil);
  if dpy = nil then begin Writeln('cannot open X display (set DISPLAY)'); Halt(1); end;
  scr := XDefaultScreen(dpy);
  gc := XCreateGC(dpy, XRootWindow(dpy, scr), 0, nil);

  if snapOut <> '' then
  begin
    RunSnapshot(page, snapOut);
    XCloseDisplay(dpy);
    Halt(0);
  end;

  win := XCreateSimpleWindow(dpy, XRootWindow(dpy, scr), 0, 0, GW, GH, 0,
    XBlackPixel(dpy, scr), XWhitePixel(dpy, scr));
  XStoreName(dpy, win, 'Tina4Pascal - Linux');
  XSelectInput(dpy, win, ExposureMask or ButtonPressMask or ButtonReleaseMask or
    PointerMotionMask or StructureNotifyMask);
  wmDelete := XInternAtom(dpy, 'WM_DELETE_WINDOW', 0);
  XSetWMProtocols(dpy, win, @wmDelete, 1);
  XMapWindow(dpy, win);

  canvas := TX11Canvas.Create(dpy, scr, gc);
  TinaInit(canvas);
  LoadPage(page);

  while True do
  begin
    XNextEvent(dpy, @ev);
    etype := I32(ev, 0);
    case etype of
      Expose_:
        if I32(ev, OFF_EXPOSE_COUNT) = 0 then Render;
      ConfigureNotify_:
        begin
          if (I32(ev, OFF_CFG_W) > 0) and (I32(ev, OFF_CFG_H) > 0) then
          begin GW := I32(ev, OFF_CFG_W); GH := I32(ev, OFF_CFG_H); end;
        end;
      ButtonPress_:
        begin mouseDown := True; TinaTouch(0, I32(ev, OFF_X), I32(ev, OFF_Y)); Render; end;
      ButtonRelease_:
        begin mouseDown := False; TinaTouch(1, I32(ev, OFF_X), I32(ev, OFF_Y)); Render; end;
      MotionNotify_:
        begin
          if mouseDown then begin TinaTouch(2, I32(ev, OFF_X), I32(ev, OFF_Y)); Render; end
          else TinaHover(I32(ev, OFF_X), I32(ev, OFF_Y));
        end;
      ClientMessage_:
        if TXID(PPtrUInt(PByte(@ev) + OFF_CM_DATA0)^) = wmDelete then Break;
    end;
  end;

  XCloseDisplay(dpy);
end.
