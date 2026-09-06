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

uses
  Windows, SysUtils, Classes,
  Tina4RenderBackend, Tina4ShellWin, Tina4Interact;

var
  GCanvas: TWinCanvas;
  GHwnd: HWND;
  GW: Integer = 1024;
  GH: Integer = 768;
  GMouseDown: Boolean = False;

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
    WM_DESTROY: PostQuitMessage(0);
  else
    Result := DefWindowProc(hwnd, msg, wp, lp);
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

var
  wc: WNDCLASSEXW;
  m: MSG;
  cls: WideString;
begin
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

  GHwnd := CreateWindowExW(0, PWideChar(cls), PWideChar(WideString('Tina4Pascal — Windows')),
    WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, GW, GH, 0, 0, HInstance, nil);

  GCanvas := TWinCanvas.Create;
  TinaInit(GCanvas);
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
