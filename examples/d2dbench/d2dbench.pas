program d2dbench;
{ Self-contained GPU-vs-software benchmark for the Windows canvas backends.
  Renders a synthetic parallax-style scene (several cached RGBA layers drawn under
  per-frame transforms, plus clip-path star sprites) at 4K and times paint-only
  frames with the GPU Direct2D canvas (TD2DCanvas) and the GDI+ software canvas
  (TWinCanvas). No external assets, so it runs anywhere the framework builds.

  Build: fpc -Mdelphi -B -Fu<tina4pascal>/src d2dbench.pas
  Run:   d2dbench            (both)   d2dbench d2d   d2dbench gdi }
{$mode delphi}{$H+}
uses Windows, SysUtils, Math, Tina4RenderBackend, Tina4ShellWin, Tina4ShellWinD2D;

const
  W = 3840; H = 1400; N = 120; NLAYERS = 5;
var
  wnd: HWND;
  scr, mem: HDC; dib: HBITMAP; ob: HGDIOBJ; bits: PByte; bmi: BITMAPINFO;
  layers: array[0..NLAYERS-1] of array of Cardinal;
  lw, lh: array[0..NLAYERS-1] of Integer;
  star: TTina4PointArray;

{ build a few procedural RGBA layers (gradient + alpha cutout) to stand in for the
  webp parallax art }
procedure MakeLayers;
var i, x, y, iw, ih: Integer; r, g, b, a: Cardinal;
begin
  for i := 0 to NLAYERS - 1 do
  begin
    iw := 1600 + i * 120; ih := 1000 + i * 60; lw[i] := iw; lh[i] := ih;
    SetLength(layers[i], iw * ih);
    for y := 0 to ih - 1 do
      for x := 0 to iw - 1 do
      begin
        r := (x * 255) div iw; g := (y * 255) div ih; b := 128 + (i * 20);
        // a soft diagonal alpha band so layers composite like cutout art
        a := 255;
        if ((x + y + i * 80) mod 400) < 120 then a := 90;
        layers[i][y * iw + x] := (a shl 24) or (r shl 16) or (g shl 8) or b;
      end;
  end;
end;

{ one synthetic frame through any TTina4Canvas: clear, parallax layers, star sprites }
procedure PaintScene(c: TTina4Canvas; ox, oy: Single);
var i, k: Integer; depth, cx, cy: Single;
begin
  c.FillRect(0, 0, W, H, $FF101522);
  cx := W / 2; cy := H / 2;
  for i := 0 to NLAYERS - 1 do
  begin
    depth := 0.1 + i * 0.22;
    c.SaveState;
    c.Translate(cx + ox * depth, cy + oy * depth);
    c.Scale(1.15, 1.15);
    c.Translate(-lw[i] / 2, -lh[i] / 2);
    c.DrawRGBA(@layers[i][0], lw[i], lh[i], 0, 0, lw[i], lh[i]);
    c.RestoreState;
  end;
  // a handful of clip-path star sprites (like the cursor sparkle trail)
  for k := 0 to 23 do
  begin
    c.SaveState;
    c.Translate(300 + (k * 137) mod (W - 600), 200 + (k * 211) mod (H - 400));
    c.Scale(0.6 + (k mod 4) * 0.3, 0.6 + (k mod 4) * 0.3);
    c.Rotate(k * 15 + ox);
    c.ClipPolygon(star);
    c.FillRect(0, 0, 40, 40, (Cardinal(160 + (k * 4) mod 90) shl 24) or $00FF78BB);
    c.RestoreState;
  end;
end;

procedure BenchGDI;
var i: Integer; t: QWord; ms: Double; cv: TWinCanvas;
begin
  cv := TWinCanvas.Create;
  t := GetTickCount64;
  for i := 1 to N do
  begin
    cv.BeginFrame(mem, bits, W, H);
    PaintScene(cv, Sin(i / 10) * 300, Cos(i / 12) * 160);
    GdiFlush;
  end;
  ms := (GetTickCount64 - t) / N;
  WriteLn(Format('  GDI+ (software)   %7.1f ms/frame   (%4.0f fps)', [ms, 1000 / ms]));
  cv.Free;
end;

procedure BenchD2D;
var i: Integer; t: QWord; ms: Double; cv: TD2DCanvas; lost: Integer;
begin
  cv := TD2DCanvas.Create(wnd, True);   // immediate present = true GPU throughput
  if not cv.Available then begin WriteLn('  Direct2D unavailable'); Exit; end;
  lost := 0;
  t := GetTickCount64;
  for i := 1 to N do
  begin
    cv.BeginFrame;
    PaintScene(cv, Sin(i / 10) * 300, Cos(i / 12) * 160);
    if not cv.EndFrame then begin Inc(lost); cv.Recreate; end;
  end;
  ms := (GetTickCount64 - t) / N;
  WriteLn(Format('  Direct2D (GPU)    %7.1f ms/frame   (%4.0f fps)   device-lost=%d', [ms, 1000 / ms, lost]));
  cv.Free;
end;

var which: string;
begin
  which := 'both'; if ParamCount >= 1 then which := LowerCase(ParamStr(1));
  SetLength(star, 8);
  star[0].X := 20; star[0].Y := 0;  star[1].X := 24; star[1].Y := 16;
  star[2].X := 40; star[2].Y := 20; star[3].X := 24; star[3].Y := 24;
  star[4].X := 20; star[4].Y := 40; star[5].X := 16; star[5].Y := 24;
  star[6].X := 0;  star[6].Y := 20; star[7].X := 16; star[7].Y := 16;
  MakeLayers;
  wnd := CreateWindowExW(0, 'STATIC', 'd2dbench', WS_POPUP, 0, 0, W, H, 0, 0, HInstance, nil);
  scr := GetDC(0);
  FillChar(bmi, SizeOf(bmi), 0); bmi.bmiHeader.biSize := SizeOf(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth := W; bmi.bmiHeader.biHeight := -H; bmi.bmiHeader.biPlanes := 1;
  bmi.bmiHeader.biBitCount := 32; bmi.bmiHeader.biCompression := BI_RGB;
  bits := nil; dib := CreateDIBSection(0, bmi, DIB_RGB_COLORS, Pointer(bits), 0, 0);
  mem := CreateCompatibleDC(scr); ob := SelectObject(mem, dib);
  SetBkMode(mem, TRANSPARENT); SetGraphicsMode(mem, GM_ADVANCED);

  WriteLn(Format('=== synthetic hero @ %dx%d, %d frames, paint-only (full res) ===', [W, H, N]));
  if (which = 'gdi') or (which = 'both') then BenchGDI;
  if (which = 'd2d') or (which = 'both') then BenchD2D;

  SelectObject(mem, ob); DeleteObject(dib); DeleteDC(mem); ReleaseDC(0, scr);
end.
