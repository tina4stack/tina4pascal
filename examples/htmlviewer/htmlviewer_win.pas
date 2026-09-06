program htmlviewer_win;

{ Windows host for the Tina4 renderer: a Win32 window that paints the engine
  through the GDI canvas (Tina4ShellWin) and forwards mouse/wheel/keys to the
  shared Tina4Interact engine. Double-buffered via a memory DIB to avoid flicker.

  Build (native on Windows, or cross from macOS/Linux):
    fpc -Mdelphi -Fu../../src htmlviewer_win.pas
  Run:
    htmlviewer_win page.html          (defaults to the built-in demo) }

{$mode delphi}{$H+}
{$apptype gui}
{$R htmlviewer_win.rc}

uses
  Windows, SysUtils, Classes,
  Tina4RenderBackend, Tina4ShellWin, Tina4Interact;

const
  NIM_ADD = 0; NIM_MODIFY = 1; NIM_DELETE = 2;
  NIF_MESSAGE = $1; NIF_ICON = $2; NIF_TIP = $4; NIF_INFO = $10;
  NIIF_INFO = $1;

type
  { the Windows-2000+ NOTIFYICONDATAW (FPC's built-in one predates the balloon
    fields), truncated at dwInfoFlags — cbSize below picks this V2 layout }
  TNotifyIconDataW = record
    cbSize: DWORD;
    hWnd: HWND;
    uID: UINT;
    uFlags: UINT;
    uCallbackMessage: UINT;
    hIcon: HICON;
    szTip: array[0..127] of WideChar;
    dwState: DWORD;
    dwStateMask: DWORD;
    szInfo: array[0..255] of WideChar;
    uTimeoutOrVersion: UINT;
    szInfoTitle: array[0..63] of WideChar;
    dwInfoFlags: DWORD;
  end;

function Shell_NotifyIconW(dwMessage: DWORD; lpData: Pointer): BOOL; stdcall;
  external 'shell32.dll' name 'Shell_NotifyIconW';

var
  GCanvas: TWinCanvas;
  GHwnd: HWND;
  GW: Integer = 1024;
  GH: Integer = 768;
  GMouseDown: Boolean = False;
  GNid: TNotifyIconDataW;
  GTrayAdded: Boolean = False;

{ copy a WideString into a fixed WideChar array field (NUL-terminated) }
procedure WFill(p: PWideChar; cap: Integer; const s: WideString);
var i, n: Integer;
begin
  n := Length(s); if n > cap - 1 then n := cap - 1;
  for i := 1 to n do p[i - 1] := s[i];
  p[n] := #0;
end;

{ notify.show(...) on Windows → a Shell_NotifyIcon balloon/toast }
procedure NotifyWin(const Title, Body, Tag: string);
begin
  if not GTrayAdded then Exit;
  GNid.uFlags := NIF_INFO;
  GNid.dwInfoFlags := NIIF_INFO;
  WFill(@GNid.szInfoTitle[0], Length(GNid.szInfoTitle), UTF8Decode(Title));
  WFill(@GNid.szInfo[0], Length(GNid.szInfo), UTF8Decode(Body));
  Shell_NotifyIconW(NIM_MODIFY, @GNid);
end;

procedure TrayAdd;
begin
  FillChar(GNid, SizeOf(GNid), 0);
  GNid.cbSize := SizeOf(GNid);
  GNid.hWnd := GHwnd;
  GNid.uID := 1;
  GNid.uFlags := NIF_ICON or NIF_TIP;
  GNid.hIcon := LoadIcon(0, IDI_APPLICATION);
  WFill(@GNid.szTip[0], Length(GNid.szTip), 'Tina4Pascal');
  GTrayAdded := Shell_NotifyIconW(NIM_ADD, @GNid);
end;

procedure Repaint;
begin
  InvalidateRect(GHwnd, nil, False);
end;

procedure PaintFrame(dc: HDC);
var
  mem: HDC; dib, oldb: HGDIOBJ; r: Windows.RECT; white: HBRUSH;
  bmi: BITMAPINFO; bits: PByte; i: Integer;
begin
  // double buffer into a 32-bit top-down DIB section so the canvas has direct
  // pixel access (blend modes, backdrop-filter, the offscreen compositor)
  mem := CreateCompatibleDC(dc);
  FillChar(bmi, SizeOf(bmi), 0);
  bmi.bmiHeader.biSize := SizeOf(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth := GW; bmi.bmiHeader.biHeight := -GH;   // top-down
  bmi.bmiHeader.biPlanes := 1; bmi.bmiHeader.biBitCount := 32; bmi.bmiHeader.biCompression := BI_RGB;
  bits := nil;
  dib := CreateDIBSection(0, bmi, DIB_RGB_COLORS, bits, 0, 0);
  oldb := SelectObject(mem, dib);
  r.Left := 0; r.Top := 0; r.Right := GW; r.Bottom := GH;
  white := CreateSolidBrush($00FFFFFF);
  Windows.FillRect(mem, r, white);
  DeleteObject(white);
  GdiFlush;
  if bits <> nil then                       // give the white ground a solid alpha
    for i := 0 to GW * GH - 1 do bits[i*4+3] := 255;
  GCanvas.BeginFrame(mem, bits, GW, GH);
  TinaFrame(GW, GH, 1.0);
  GdiFlush;
  BitBlt(dc, 0, 0, GW, GH, mem, 0, 0, SRCCOPY);
  SelectObject(mem, oldb);
  DeleteObject(dib); DeleteDC(mem);
end;

function WndProc(hwnd: HWND; msg: UINT; wp: WPARAM; lp: LPARAM): LRESULT; stdcall;
var ps: PAINTSTRUCT; dc: HDC; x, y: Integer; dz: Integer;
begin
  Result := 0;
  case msg of
    WM_PAINT:
      begin
        dc := BeginPaint(hwnd, ps);
        PaintFrame(dc);
        EndPaint(hwnd, ps);
      end;
    WM_ERASEBKGND: Result := 1;   // we fully repaint; skip flicker
    WM_SIZE:
      begin
        GW := SmallInt(lp and $FFFF); GH := SmallInt((lp shr 16) and $FFFF);
        Repaint;
      end;
    WM_LBUTTONDOWN:
      begin
        GMouseDown := True; SetCapture(hwnd);
        x := SmallInt(lp and $FFFF); y := SmallInt((lp shr 16) and $FFFF);
        TinaTouch(0, x, y); Repaint;
      end;
    WM_LBUTTONUP:
      begin
        GMouseDown := False; ReleaseCapture;
        x := SmallInt(lp and $FFFF); y := SmallInt((lp shr 16) and $FFFF);
        TinaTouch(1, x, y); Repaint;
      end;
    WM_MOUSEMOVE:
      begin
        x := SmallInt(lp and $FFFF); y := SmallInt((lp shr 16) and $FFFF);
        if GMouseDown then TinaTouch(2, x, y) else TinaHover(x, y);
        if GMouseDown then Repaint;
      end;
    WM_MOUSEWHEEL:
      begin
        dz := SmallInt((wp shr 16) and $FFFF);
        TinaScrollBy(GW div 2, GH div 2, 0, -dz);   // wheel notch -> scroll
        Repaint;
      end;
    WM_CHAR:
      begin
        TinaKey(Integer(wp)); Repaint;
      end;
    WM_TIMER:
      begin
        if TinaTick = 1 then Repaint;
      end;
    WM_DESTROY:
      begin
        if GTrayAdded then Shell_NotifyIconW(NIM_DELETE, @GNid);
        PostQuitMessage(0);
      end;
  else
    // DefWindowProcW (not the ANSI DefWindowProc alias): the class is registered
    // with RegisterClassExW, so a Unicode window whose fallback ran through the
    // ANSI DefWindowProc mangled the caption (WM_SETTEXT/WM_GETTEXT) down to its
    // first byte — hence the old one-letter "T" title.
    Result := DefWindowProcW(hwnd, msg, wp, lp);
  end;
end;

procedure LoadInitial;
var html: string; sl: TStringList; path: string;
begin
  path := ParamStr(1);
  if (path <> '') and FileExists(path) then
  begin
    sl := TStringList.Create;
    try sl.LoadFromFile(path); html := sl.Text; finally sl.Free; end;
    TinaSetHtml(html);
  end
  else
    TinaSetHtml('@demo');
end;

{ Find the Tina4 branding logo by walking up from the exe (and the cwd) looking
  for branding\icon.png, so the shipped app wears the real logo wherever it runs
  from in the tree. }
function FindBrandingIcon: string;
var base, cand: string; i: Integer;
begin
  Result := '';
  base := ExtractFileDir(ParamStr(0));
  for i := 0 to 5 do
  begin
    cand := IncludeTrailingPathDelimiter(base) + 'branding' + PathDelim + 'icon.png';
    if FileExists(cand) then Exit(cand);
    base := ExtractFileDir(base);
    if base = '' then Break;
  end;
  cand := 'branding' + PathDelim + 'icon.png';
  if FileExists(cand) then Result := cand;
end;

{ Put the branding logo on the window (title bar + taskbar). }
procedure ApplyWindowIcon(hwnd: HWND);
var ico: HICON; p: string;
begin
  p := FindBrandingIcon;
  if p = '' then Exit;
  ico := WinLoadHIcon(p);
  if ico <> 0 then
  begin
    SendMessageW(hwnd, WM_SETICON, ICON_BIG, LPARAM(ico));
    SendMessageW(hwnd, WM_SETICON, ICON_SMALL, LPARAM(ico));
  end;
end;

{ Headless render: paint one page into an offscreen DIB and write it to a PNG,
  no window shown. Drives the Windows reftest/compliance harness (mirrors the
  macOS viewer's `<page> --snapshot <out.png>`). Fixed 1024x800 like the suite. }
procedure RunSnapshot(const page, outPath: string);
const SW = 1024; SH = 800;
var
  mem: HDC; dib, oldb: HGDIOBJ; bmi: BITMAPINFO; bits: PByte; i: Integer;
  sl: TStringList; html: string; canvas: TWinCanvas;
begin
  GW := SW; GH := SH;
  mem := CreateCompatibleDC(0);
  FillChar(bmi, SizeOf(bmi), 0);
  bmi.bmiHeader.biSize := SizeOf(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth := SW; bmi.bmiHeader.biHeight := -SH;   // top-down
  bmi.bmiHeader.biPlanes := 1; bmi.bmiHeader.biBitCount := 32; bmi.bmiHeader.biCompression := BI_RGB;
  bits := nil;
  dib := CreateDIBSection(0, bmi, DIB_RGB_COLORS, bits, 0, 0);
  oldb := SelectObject(mem, dib);
  SetBkMode(mem, TRANSPARENT); SetGraphicsMode(mem, GM_ADVANCED);
  if bits <> nil then
    for i := 0 to SW * SH - 1 do
    begin bits[i*4] := 255; bits[i*4+1] := 255; bits[i*4+2] := 255; bits[i*4+3] := 255; end;
  canvas := TWinCanvas.Create;
  TinaInit(canvas);
  html := '@demo';
  if (page <> '') and FileExists(page) then
  begin
    sl := TStringList.Create;
    try sl.LoadFromFile(page); html := sl.Text; finally sl.Free; end;
  end;
  TinaSetHtml(html);
  canvas.BeginFrame(mem, bits, SW, SH);
  TinaFrame(SW, SH, 1.0);
  GdiFlush;
  WinSaveDibPng(bits, SW, SH, outPath);
  canvas.Free;
  SelectObject(mem, oldb); DeleteObject(dib); DeleteDC(mem);
end;

var
  wc: WNDCLASSEXW;
  m: MSG;
  cls: UnicodeString;
  title: UnicodeString;
  i: Integer;
  snapOut: string;
begin
  // headless: <page> --snapshot <out.png>
  snapOut := '';
  for i := 1 to ParamCount - 1 do
    if ParamStr(i) = '--snapshot' then snapOut := ParamStr(i + 1);
  if snapOut <> '' then
  begin
    RunSnapshot(ParamStr(1), snapOut);
    Halt(0);
  end;

  cls := 'Tina4Window';
  FillChar(wc, SizeOf(wc), 0);
  wc.cbSize := SizeOf(wc);
  wc.style := CS_HREDRAW or CS_VREDRAW;
  wc.lpfnWndProc := @WndProc;
  wc.hInstance := HInstance;
  wc.hCursor := LoadCursor(0, IDC_ARROW);
  wc.hbrBackground := 0;
  wc.lpszClassName := PWideChar(cls);
  RegisterClassExW(wc);

  title := 'Tina4Pascal - Windows';
  GHwnd := CreateWindowExW(0, PWideChar(cls), PWideChar(title),
    WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, GW, GH, 0, 0, HInstance, nil);
  ApplyWindowIcon(GHwnd);

  GCanvas := TWinCanvas.Create;
  TinaInit(GCanvas);
  TrayAdd;                                 // tray icon backs the balloon toasts
  Tina4SetNotifyHandler(@NotifyWin);       // notify.show(...) → Windows toast
  LoadInitial;

  SetTimer(GHwnd, 1, 16, nil);   // ~60fps tick for animations/caret
  ShowWindow(GHwnd, SW_SHOW);
  UpdateWindow(GHwnd);

  while GetMessage(m, 0, 0, 0) do
  begin
    TranslateMessage(m);
    DispatchMessage(m);
  end;
end.
