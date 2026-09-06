unit Tina4ShellWin;

{ Windows desktop shell for the Tina4 native renderer.

  Implements the TTina4Canvas contract on GDI (the Win32 graphics API) through
  FPC's `Windows` unit — the same idea as the Cocoa shell on AppKit. The window
  host (examples drive it) hands the canvas a device context per frame via
  BeginFrame; the engine then paints through GDI: solid/rounded rects, lines,
  ClearType text, clipping and an affine world transform for CSS transforms.

  A memory DC created once backs text measurement outside a paint cycle (the
  layout pass needs MeasureText). Coordinates are CSS pixels, top-left; colours
  are $AARRGGBB (GDI is opaque RGB in v1 — per-pixel alpha and the offscreen
  filter/3D compositing land on a 32-bit DIB section next). }

{$mode delphi}{$H+}

interface

uses
  Windows, SysUtils, Classes, Tina4RenderBackend, Tina4Compositor;

type
  { one entry of the offscreen filter/blend/3D layer stack }
  TWinLayer = record
    Dib: HBITMAP; Mem: HDC; Bits: PByte; Saved: HDC;
    ox, oy, w, h: Integer;
  end;

  TWinCanvas = class(TTina4Canvas)
  private
    FDC: HDC;              // current frame device context (set by BeginFrame)
    FMeasDC: HDC;          // memory DC for text measurement between frames
    FClipSaved: Boolean;   // a SetClip pushed a SaveDC we must RestoreDC
    FDestBits: PByte;      // the frame's back-buffer DIB pixels (BGRA, top-down)
    FDestW, FDestH: Integer;
    FLayers: array of TWinLayer;
    function FaceFor(const Family: string): WideString;
    function MakeFont(SizePx: Single; Styles: TTina4FontStyles): HFONT;
    function DC: HDC;      // FDC if painting, else the measuring DC
    { composite a premultiplied Single RGBA buffer (pw x ph) into the back-buffer
      at (dx,dy) with the given CSS blend mode (source-over when '') }
    procedure CompositeToDest(buf: PSingleBuf; pw, ph, dx, dy: Integer; const Blend: string);
  public
    constructor Create;
    destructor Destroy; override;
    { ADC is the frame's memory DC; DestBits/DW/DH are its backing 32-bit
      top-down DIB pixels so blend-modes and backdrop-filter can read/write them. }
    procedure BeginFrame(ADC: HDC; DestBits: PByte; DW, DH: Integer);
    procedure FillRect(X, Y, W, H: Single; Color: TTina4Color); override;
    procedure StrokeRect(X, Y, W, H, Thickness: Single; Color: TTina4Color); override;
    procedure FillRoundRect(X, Y, W, H, Radius: Single; Color: TTina4Color); override;
    procedure StrokeRoundRect(X, Y, W, H, Radius, Thickness: Single; Color: TTina4Color); override;
    procedure DrawLine(X1, Y1, X2, Y2, Thickness: Single; Color: TTina4Color); override;
    procedure DrawText(X, Y: Single; const Text: string; FontSize: Single;
      Styles: TTina4FontStyles; Color: TTina4Color); override;
    function MeasureText(const Text: string; FontSize: Single;
      Styles: TTina4FontStyles): TTina4TextMetrics; override;
    procedure SetClip(X, Y, W, H: Single); override;
    procedure ClearClip; override;
    procedure SaveState; override;
    procedure RestoreState; override;
    procedure Translate(DX, DY: Single); override;
    procedure Scale(SX, SY: Single); override;
    procedure Rotate(Degrees: Single); override;
    function BeginLayer(X, Y, W, H, Pad: Single): Integer; override;
    procedure EndLayerFiltered(Handle: Integer; const FilterSpec, BlendMode, MaskSpec: string); override;
    procedure BackdropFilter(X, Y, W, H: Single; const FilterSpec: string); override;
    procedure EndLayer3D(Handle: Integer; const Corners: array of Single); override;
  end;

implementation

const
  CLEARTYPE_QUALITY = 5;

function ColorRefOf(C: TTina4Color): COLORREF;
begin
  // $AARRGGBB -> GDI 0x00BBGGRR
  Result := ((C shr 16) and $FF) or (((C shr 8) and $FF) shl 8) or ((C and $FF) shl 16);
end;

constructor TWinCanvas.Create;
begin
  inherited Create;
  FMeasDC := CreateCompatibleDC(0);
  SetBkMode(FMeasDC, TRANSPARENT);
end;

destructor TWinCanvas.Destroy;
begin
  if FMeasDC <> 0 then DeleteDC(FMeasDC);
  inherited Destroy;
end;

procedure TWinCanvas.BeginFrame(ADC: HDC; DestBits: PByte; DW, DH: Integer);
begin
  FDC := ADC;
  FDestBits := DestBits; FDestW := DW; FDestH := DH;
  SetBkMode(FDC, TRANSPARENT);
  SetGraphicsMode(FDC, GM_ADVANCED);   // enable world transforms for CSS transforms
end;

function TWinCanvas.DC: HDC;
begin
  if FDC <> 0 then Result := FDC else Result := FMeasDC;
end;

{ Map a CSS font-family list to a concrete Windows face. }
function TWinCanvas.FaceFor(const Family: string): WideString;
var f, first: string; p: Integer;
begin
  f := LowerCase(Trim(Family));
  p := Pos(',', f); if p > 0 then first := Trim(Copy(f, 1, p - 1)) else first := f;
  first := StringReplace(first, '"', '', [rfReplaceAll]);
  first := StringReplace(first, '''', '', [rfReplaceAll]);
  if (first = '') or (first = 'sans-serif') or (first = 'system-ui') then Result := 'Segoe UI'
  else if first = 'serif' then Result := 'Times New Roman'
  else if (first = 'monospace') or (first = 'mono') then Result := 'Consolas'
  else Result := UTF8Decode(Trim(Family).Split([','])[0].Trim);
end;

function TWinCanvas.MakeFont(SizePx: Single; Styles: TTina4FontStyles): HFONT;
var lf: LOGFONTW; face: WideString; i, n: Integer;
begin
  FillChar(lf, SizeOf(lf), 0);
  lf.lfHeight := -Round(SizePx);            // negative => em height in device px
  if (tfsBold in Styles) or (FontWeight >= 600) then lf.lfWeight := FW_BOLD
  else lf.lfWeight := FW_NORMAL;
  if tfsItalic in Styles then lf.lfItalic := 1;
  if tfsUnderline in Styles then lf.lfUnderline := 1;
  if tfsStrike in Styles then lf.lfStrikeOut := 1;
  lf.lfQuality := CLEARTYPE_QUALITY;
  lf.lfCharSet := DEFAULT_CHARSET;
  face := FaceFor(FontFamily);
  n := Length(face); if n > 31 then n := 31;
  for i := 1 to n do lf.lfFaceName[i - 1] := WideChar(face[i]);
  lf.lfFaceName[n] := #0;
  Result := CreateFontIndirectW(@lf);
end;

procedure TWinCanvas.FillRect(X, Y, W, H: Single; Color: TTina4Color);
var r: Windows.RECT; br: HBRUSH;
begin
  if (W <= 0) or (H <= 0) then Exit;
  r.Left := Round(X); r.Top := Round(Y); r.Right := Round(X + W); r.Bottom := Round(Y + H);
  br := CreateSolidBrush(ColorRefOf(Color));
  Windows.FillRect(DC, r, br);
  DeleteObject(br);
end;

procedure TWinCanvas.StrokeRect(X, Y, W, H, Thickness: Single; Color: TTina4Color);
var pen, old: HGDIOBJ; oldBr: HGDIOBJ;
begin
  pen := CreatePen(PS_SOLID, Round(Thickness), ColorRefOf(Color));
  old := SelectObject(DC, pen);
  oldBr := SelectObject(DC, GetStockObject(NULL_BRUSH));
  Windows.Rectangle(DC, Round(X), Round(Y), Round(X + W), Round(Y + H));
  SelectObject(DC, oldBr);
  SelectObject(DC, old); DeleteObject(pen);
end;

procedure TWinCanvas.FillRoundRect(X, Y, W, H, Radius: Single; Color: TTina4Color);
var br, old, oldPen: HGDIOBJ; d: Integer;
begin
  if (W <= 0) or (H <= 0) then Exit;
  d := Round(Radius * 2);
  br := CreateSolidBrush(ColorRefOf(Color));
  old := SelectObject(DC, br);
  oldPen := SelectObject(DC, GetStockObject(NULL_PEN));
  Windows.RoundRect(DC, Round(X), Round(Y), Round(X + W) + 1, Round(Y + H) + 1, d, d);
  SelectObject(DC, oldPen);
  SelectObject(DC, old); DeleteObject(br);
end;

procedure TWinCanvas.StrokeRoundRect(X, Y, W, H, Radius, Thickness: Single; Color: TTina4Color);
var pen, old, oldBr: HGDIOBJ; d: Integer;
begin
  d := Round(Radius * 2);
  pen := CreatePen(PS_SOLID, Round(Thickness), ColorRefOf(Color));
  old := SelectObject(DC, pen);
  oldBr := SelectObject(DC, GetStockObject(NULL_BRUSH));
  Windows.RoundRect(DC, Round(X), Round(Y), Round(X + W), Round(Y + H), d, d);
  SelectObject(DC, oldBr);
  SelectObject(DC, old); DeleteObject(pen);
end;

procedure TWinCanvas.DrawLine(X1, Y1, X2, Y2, Thickness: Single; Color: TTina4Color);
var pen, old: HGDIOBJ;
begin
  pen := CreatePen(PS_SOLID, Round(Thickness), ColorRefOf(Color));
  old := SelectObject(DC, pen);
  Windows.MoveToEx(DC, Round(X1), Round(Y1), nil);
  Windows.LineTo(DC, Round(X2), Round(Y2));
  SelectObject(DC, old); DeleteObject(pen);
end;

procedure TWinCanvas.DrawText(X, Y: Single; const Text: string; FontSize: Single;
  Styles: TTina4FontStyles; Color: TTina4Color);
var f, old: HGDIOBJ; w: WideString;
begin
  if Text = '' then Exit;
  f := MakeFont(FontSize, Styles);
  old := SelectObject(DC, f);
  SetTextColor(DC, ColorRefOf(Color));
  SetBkMode(DC, TRANSPARENT);
  if LetterSpacing <> 0 then SetTextCharacterExtra(DC, Round(LetterSpacing));
  w := UTF8Decode(Text);
  Windows.TextOutW(DC, Round(X), Round(Y), PWideChar(w), Length(w));
  if LetterSpacing <> 0 then SetTextCharacterExtra(DC, 0);
  SelectObject(DC, old); DeleteObject(f);
end;

function TWinCanvas.MeasureText(const Text: string; FontSize: Single;
  Styles: TTina4FontStyles): TTina4TextMetrics;
var f, old: HGDIOBJ; w: WideString; sz: SIZE; tm: TEXTMETRICW; d: HDC;
begin
  d := DC;
  f := MakeFont(FontSize, Styles);
  old := SelectObject(d, f);
  w := UTF8Decode(Text);
  sz.cx := 0; sz.cy := 0;
  if w <> '' then Windows.GetTextExtentPoint32W(d, PWideChar(w), Length(w), sz);
  if LetterSpacing <> 0 then sz.cx := sz.cx + Round(LetterSpacing) * Length(w);
  GetTextMetricsW(d, @tm);
  SelectObject(d, old); DeleteObject(f);
  Result.Width := sz.cx;
  Result.Ascent := tm.tmAscent;
  Result.Descent := tm.tmDescent;
  Result.LineHeight := tm.tmHeight;
end;

procedure TWinCanvas.SetClip(X, Y, W, H: Single);
begin
  // one level deep: SaveDC, intersect; ClearClip does RestoreDC
  SaveDC(DC); FClipSaved := True;
  IntersectClipRect(DC, Round(X), Round(Y), Round(X + W), Round(Y + H));
end;

procedure TWinCanvas.ClearClip;
begin
  if FClipSaved then begin RestoreDC(DC, -1); FClipSaved := False; end;
end;

procedure TWinCanvas.SaveState;
begin
  SaveDC(DC);
end;

procedure TWinCanvas.RestoreState;
begin
  RestoreDC(DC, -1);
end;

procedure TWinCanvas.Translate(DX, DY: Single);
var xf: XFORM;
begin
  xf.eM11 := 1; xf.eM12 := 0; xf.eM21 := 0; xf.eM22 := 1; xf.eDx := DX; xf.eDy := DY;
  ModifyWorldTransform(DC, xf, MWT_LEFTMULTIPLY);
end;

procedure TWinCanvas.Scale(SX, SY: Single);
var xf: XFORM;
begin
  xf.eM11 := SX; xf.eM12 := 0; xf.eM21 := 0; xf.eM22 := SY; xf.eDx := 0; xf.eDy := 0;
  ModifyWorldTransform(DC, xf, MWT_LEFTMULTIPLY);
end;

procedure TWinCanvas.Rotate(Degrees: Single);
var xf: XFORM; a, c, s: Single;
begin
  a := Degrees * Pi / 180; c := Cos(a); s := Sin(a);
  xf.eM11 := c; xf.eM12 := s; xf.eM21 := -s; xf.eM22 := c; xf.eDx := 0; xf.eDy := 0;
  ModifyWorldTransform(DC, xf, MWT_LEFTMULTIPLY);
end;

{ ---- offscreen filter / blend / 3D compositing (shared Tina4Compositor) ----
  Windows density is 1 (1 CSS px = 1 device px), so layer buffers are box-sized
  and map 1:1 into the back-buffer. GDI does not write the DIB alpha channel, so
  after drawing we force the element's core box opaque and leave the blur/shadow
  pad transparent (rounded-corner alpha inside the box is a v2 limitation). }

function MakeDib(w, h: Integer; out bits: PByte): HBITMAP;
var bmi: BITMAPINFO;
begin
  FillChar(bmi, SizeOf(bmi), 0);
  bmi.bmiHeader.biSize := SizeOf(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth := w;
  bmi.bmiHeader.biHeight := -h;         // top-down
  bmi.bmiHeader.biPlanes := 1;
  bmi.bmiHeader.biBitCount := 32;
  bmi.bmiHeader.biCompression := BI_RGB;
  bits := nil;
  Result := CreateDIBSection(0, bmi, DIB_RGB_COLORS, bits, 0, 0);
end;

function TWinCanvas.BeginLayer(X, Y, W, H, Pad: Single): Integer;
var ox, oy, bw, bh, n: Integer; dib: HBITMAP; mem: HDC; bits: PByte;
begin
  ox := Round(X - Pad); oy := Round(Y - Pad); bw := Round(W + 2 * Pad); bh := Round(H + 2 * Pad);
  if (bw <= 0) or (bh <= 0) then Exit(-1);
  dib := MakeDib(bw, bh, bits);
  if (dib = 0) or (bits = nil) then Exit(-1);
  FillChar(bits^, bw * bh * 4, 0);      // transparent
  mem := CreateCompatibleDC(FDC);
  SelectObject(mem, dib);
  SetBkMode(mem, TRANSPARENT);
  SetGraphicsMode(mem, GM_ADVANCED);
  SetWindowOrgEx(mem, ox, oy, nil);     // doc coords → buffer pixels
  n := Length(FLayers); SetLength(FLayers, n + 1);
  FLayers[n].Dib := dib; FLayers[n].Mem := mem; FLayers[n].Bits := bits; FLayers[n].Saved := FDC;
  FLayers[n].ox := ox; FLayers[n].oy := oy; FLayers[n].w := bw; FLayers[n].h := bh;
  FDC := mem;                            // redirect drawing into the layer
  Result := n;
end;

{ blend one premultiplied source pixel over an opaque back-buffer BGRA pixel }
procedure BlendPixel(d: PByte; sr, sg, sb, sa: Single; const Blend: string);
var dr, dg, db, br, bg, bb: Single;
begin
  if sa <= 0 then Exit;
  dr := d[2] / 255; dg := d[1] / 255; db := d[0] / 255;   // dest is opaque RGB (BGRA)
  if Blend = '' then begin br := sr; bg := sg; bb := sb; end   // source-over (premult src)
  else
  begin
    // separable blend on straight source colour, then premultiply by sa
    if sa > 0 then begin br := sr / sa; bg := sg / sa; bb := sb / sa; end else begin br := 0; bg := 0; bb := 0; end;
    if Blend = 'multiply' then begin br := br*dr; bg := bg*dg; bb := bb*db; end
    else if Blend = 'screen' then begin br := br+dr-br*dr; bg := bg+dg-bg*dg; bb := bb+db-bb*db; end
    else if Blend = 'darken' then begin if dr<br then br:=dr; if dg<bg then bg:=dg; if db<bb then bb:=db; end
    else if Blend = 'lighten' then begin if dr>br then br:=dr; if dg>bg then bg:=dg; if db>bb then bb:=db; end
    else if Blend = 'difference' then begin br := Abs(br-dr); bg := Abs(bg-dg); bb := Abs(bb-db); end
    else if Blend = 'overlay' then begin
      if dr<=0.5 then br:=2*br*dr else br:=1-2*(1-br)*(1-dr);
      if dg<=0.5 then bg:=2*bg*dg else bg:=1-2*(1-bg)*(1-dg);
      if db<=0.5 then bb:=2*bb*db else bb:=1-2*(1-bb)*(1-db); end;
    br := br * sa; bg := bg * sa; bb := bb * sa;   // re-premultiply
  end;
  // source-over: out = src + dest*(1-sa)
  dr := br + dr*(1-sa); dg := bg + dg*(1-sa); db := bb + db*(1-sa);
  if dr<0 then dr:=0; if dr>1 then dr:=1; if dg<0 then dg:=0; if dg>1 then dg:=1; if db<0 then db:=0; if db>1 then db:=1;
  d[2] := Round(dr*255); d[1] := Round(dg*255); d[0] := Round(db*255); d[3] := 255;
end;

procedure TWinCanvas.CompositeToDest(buf: PSingleBuf; pw, ph, dx, dy: Integer; const Blend: string);
var x, y, tx, ty, so: Integer; d: PByte;
begin
  if FDestBits = nil then Exit;
  GdiFlush;   // ensure GDI's batched draws are in the DIB before we read/write it
  for y := 0 to ph - 1 do
  begin
    ty := dy + y; if (ty < 0) or (ty >= FDestH) then Continue;
    for x := 0 to pw - 1 do
    begin
      tx := dx + x; if (tx < 0) or (tx >= FDestW) then Continue;
      so := (y * pw + x) * 4;
      d := FDestBits + (ty * FDestW + tx) * 4;
      BlendPixel(d, buf[so], buf[so+1], buf[so+2], buf[so+3], Blend);
    end;
  end;
end;

{ decode the layer DIB (BGRA, GDI left alpha=0) into a premultiplied RGBA Single
  buffer, forcing the element's core box (inside the pad) opaque. }
function DecodeLayer(const L: TWinLayer; PadX, PadY, CoreW, CoreH: Integer): PSingle;
var x, y, so, o: Integer; a: Single;
begin
  GetMem(Result, L.w * L.h * 4 * SizeOf(Single));
  for y := 0 to L.h - 1 do
    for x := 0 to L.w - 1 do
    begin
      o := (y * L.w + x) * 4; so := o;
      // inside the core box ⇒ opaque; pad ring ⇒ transparent (blur/shadow fade)
      if (x >= PadX) and (x < PadX + CoreW) and (y >= PadY) and (y < PadY + CoreH) then a := 1 else a := 0;
      Result[so]   := (L.Bits[o+2] / 255) * a;   // R (premultiplied)
      Result[so+1] := (L.Bits[o+1] / 255) * a;   // G
      Result[so+2] := (L.Bits[o]   / 255) * a;   // B
      Result[so+3] := a;
    end;
end;

procedure TWinCanvas.EndLayerFiltered(Handle: Integer; const FilterSpec, BlendMode, MaskSpec: string);
var L: TWinLayer; buf: PSingle; padx, pady, coreW, coreH: Integer;
begin
  if (Handle < 0) or (Handle > High(FLayers)) then Exit;
  L := FLayers[Handle];
  FDC := L.Saved;                       // restore back-buffer DC
  padx := 0; pady := 0; coreW := L.w; coreH := L.h;
  if FilterSpec <> '' then
  begin
    // recover the pad from the filter so blur/shadow fade into transparency
    padx := Round(FilterLayerPad(FilterSpec)); pady := padx;
    coreW := L.w - 2*padx; coreH := L.h - 2*pady;
    if coreW < 0 then coreW := L.w; if coreH < 0 then coreH := L.h;
  end;
  buf := DecodeLayer(L, padx, pady, coreW, coreH);
  try
    if (FilterSpec <> '') or (MaskSpec <> '') then
      ApplyFilterChainF(PSingleBuf(buf), L.w, L.h, FilterSpec, MaskSpec, 1);
    CompositeToDest(PSingleBuf(buf), L.w, L.h, L.ox, L.oy, LowerCase(BlendMode));
  finally
    FreeMem(buf);
  end;
  DeleteDC(L.Mem); DeleteObject(L.Dib);
  SetLength(FLayers, Handle);
end;

procedure TWinCanvas.EndLayer3D(Handle: Integer; const Corners: array of Single);
var
  L: TWinLayer; src: PSingle; dst: PByte; dbuf: PSingle;
  minx, miny, maxx, maxy: Single; i, dpw, dph, j: Integer;
  quad: array[0..7] of Single;
begin
  if (Handle < 0) or (Handle > High(FLayers)) then Exit;
  L := FLayers[Handle];
  FDC := L.Saved;
  src := DecodeLayer(L, 0, 0, L.w, L.h);
  try
    minx := Corners[0]; maxx := Corners[0]; miny := Corners[1]; maxy := Corners[1];
    for i := 1 to 3 do
    begin
      if Corners[i*2]   < minx then minx := Corners[i*2];
      if Corners[i*2]   > maxx then maxx := Corners[i*2];
      if Corners[i*2+1] < miny then miny := Corners[i*2+1];
      if Corners[i*2+1] > maxy then maxy := Corners[i*2+1];
    end;
    dpw := Round(maxx - minx); dph := Round(maxy - miny);
    if (dpw > 0) and (dph > 0) then
    begin
      for i := 0 to 3 do begin quad[i*2] := Corners[i*2] - minx; quad[i*2+1] := Corners[i*2+1] - miny; end;
      GetMem(dst, dpw * dph * 4); FillChar(dst^, dpw * dph * 4, 0);
      WarpQuad(PSingleBuf(src), L.w, L.h, quad, dst, dpw, dph);
      // warped dst is 8-bit premult RGBA → to Single premult for CompositeToDest
      GetMem(dbuf, dpw * dph * 4 * SizeOf(Single));
      for j := 0 to dpw * dph * 4 - 1 do dbuf[j] := dst[j] / 255;
      CompositeToDest(PSingleBuf(dbuf), dpw, dph, Round(minx), Round(miny), '');
      FreeMem(dbuf); FreeMem(dst);
    end;
  finally
    FreeMem(src);
  end;
  DeleteDC(L.Mem); DeleteObject(L.Dib);
  SetLength(FLayers, Handle);
end;

procedure TWinCanvas.BackdropFilter(X, Y, W, H: Single; const FilterSpec: string);
var bx, by, bw, bh, x2, y2, o, so: Integer; buf: PSingle; d: PByte;
begin
  if (FDestBits = nil) or (FilterSpec = '') then Exit;
  bx := Round(X); by := Round(Y); bw := Round(W); bh := Round(H);
  if (bw <= 0) or (bh <= 0) then Exit;
  GdiFlush;   // read the already-painted pixels behind the element
  GetMem(buf, bw * bh * 4 * SizeOf(Single));
  try
    for y2 := 0 to bh - 1 do
      for x2 := 0 to bw - 1 do
      begin
        so := (y2 * bw + x2) * 4;
        if (bx+x2 >= 0) and (bx+x2 < FDestW) and (by+y2 >= 0) and (by+y2 < FDestH) then
        begin
          d := FDestBits + ((by+y2) * FDestW + (bx+x2)) * 4;
          buf[so]   := d[2] / 255; buf[so+1] := d[1] / 255; buf[so+2] := d[0] / 255; buf[so+3] := 1;
        end
        else begin buf[so]:=1; buf[so+1]:=1; buf[so+2]:=1; buf[so+3]:=1; end;
      end;
    ApplyFilterChainF(PSingleBuf(buf), bw, bh, FilterSpec, '', 1);
    for y2 := 0 to bh - 1 do
      for x2 := 0 to bw - 1 do
        if (bx+x2 >= 0) and (bx+x2 < FDestW) and (by+y2 >= 0) and (by+y2 < FDestH) then
        begin
          so := (y2 * bw + x2) * 4; o := 0;
          d := FDestBits + ((by+y2) * FDestW + (bx+x2)) * 4;
          d[2] := Round(buf[so]*255); d[1] := Round(buf[so+1]*255); d[0] := Round(buf[so+2]*255); d[3] := 255;
        end;
  finally
    FreeMem(buf);
  end;
end;

end.
