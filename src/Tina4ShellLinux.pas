unit Tina4ShellLinux;

{ Linux/X11 desktop shell for the Tina4 native renderer.

  Implements the TTina4Canvas contract on plain Xlib (no GTK/Qt/LCL, no Xft) —
  the same idea as the Cocoa (AppKit) and Windows (GDI) shells. The host creates
  a Display, a back-buffer Pixmap and a GC; the engine paints into the Pixmap
  through this canvas: solid/rounded rects, lines, clipping and antialiased-ish
  core-font text; the host then XCopyArea's the Pixmap to the window per frame.

  v1 scope (parity foothold, mirrors the Android shell's "no compositing yet"):
  shapes, gradients (via the portable software rasteriser in the base canvas),
  text and clipping all render. CSS transforms, images and the offscreen
  filter/blend/mask/3D compositor degrade safely (the base contract's no-ops),
  and are the next step here — Xrender/XRender-picture or the software raster.

  Colours are $AARRGGBB; the pixel sent to X assumes a 24-bit TrueColor visual
  (RGB in the low 3 bytes), which is what Xorg/XWayland give by default. }

{$mode objfpc}{$H+}{$PACKRECORDS C}

interface

uses
  ctypes, SysUtils, Classes, Tina4RenderBackend;

type
  PXDisplay = Pointer;
  TXID = culong;
  TDrawable = TXID;
  TGC = Pointer;

  TClipState = record HasClip: Boolean; X, Y, W, H: cint; end;

  TX11Canvas = class(TTina4Canvas)
  private
    FDpy: PXDisplay;
    FScreen: cint;
    FGC: TGC;
    FDraw: TDrawable;
    FW, FH: cint;
    FFonts: TStringList;          // XLFD -> PXFontStruct (Objects)
    FCur: TClipState;
    FStack: array of TClipState;
    function FontFor(SizePx: Single; Styles: TTina4FontStyles): Pointer;
    procedure SetFg(Color: TTina4Color);
    procedure ApplyClip;
    procedure PushState;
    procedure PopState;
  public
    constructor Create(ADpy: PXDisplay; AScreen: cint; AGC: TGC);
    destructor Destroy; override;
    procedure BeginFrame(ADraw: TDrawable; AW, AH: cint);
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
  end;

{ Grab the back-buffer pixels and write them to a 24-bit BMP — the headless
  snapshot path for the reftest/compliance harness (mirrors the mac/win
  `<page> --snapshot`). Returns True on success. }
function LinSaveBmp(ADpy: PXDisplay; ADraw: TDrawable; W, H: cint;
  const Path: string): Boolean;

implementation

{$linklib X11}

type
  PXFontStruct = ^TXFontStruct;
  TXCharStruct = record
    lbearing, rbearing, width, ascent, descent: cshort; attributes: cushort;
  end;
  TXFontStruct = record
    ext_data: Pointer;
    fid: TXID;
    direction: cuint;
    min_char_or_byte2, max_char_or_byte2: cuint;
    min_byte1, max_byte1: cuint;
    all_chars_exist: cint;
    default_char: cuint;
    n_properties: cint;
    properties: Pointer;
    min_bounds, max_bounds: TXCharStruct;
    per_char: Pointer;
    ascent: cint;
    descent: cint;
  end;

  TXRectangle = record x, y: cshort; width, height: cushort; end;

  PXImage = ^TXImage;
  TXImage = record
    width, height: cint;
    xoffset: cint;
    format: cint;
    data: PByte;
    byte_order: cint;
    bitmap_unit: cint;
    bitmap_bit_order: cint;
    bitmap_pad: cint;
    depth: cint;
    bytes_per_line: cint;
    bits_per_pixel: cint;
    red_mask, green_mask, blue_mask: culong;
  end;

function XSetForeground(dpy: PXDisplay; gc: TGC; c: culong): cint; cdecl; external;
function XFillRectangle(dpy: PXDisplay; d: TDrawable; gc: TGC; x, y: cint; w, h: cuint): cint; cdecl; external;
function XDrawRectangle(dpy: PXDisplay; d: TDrawable; gc: TGC; x, y: cint; w, h: cuint): cint; cdecl; external;
function XDrawLine(dpy: PXDisplay; d: TDrawable; gc: TGC; x1, y1, x2, y2: cint): cint; cdecl; external;
function XFillArc(dpy: PXDisplay; d: TDrawable; gc: TGC; x, y: cint; w, h: cuint; a1, a2: cint): cint; cdecl; external;
function XDrawArc(dpy: PXDisplay; d: TDrawable; gc: TGC; x, y: cint; w, h: cuint; a1, a2: cint): cint; cdecl; external;
function XSetLineAttributes(dpy: PXDisplay; gc: TGC; w: cuint; ls, cs, js: cint): cint; cdecl; external;
function XSetClipRectangles(dpy: PXDisplay; gc: TGC; xo, yo: cint; r: Pointer; n, ordering: cint): cint; cdecl; external;
function XSetClipMask(dpy: PXDisplay; gc: TGC; p: TXID): cint; cdecl; external;
function XLoadQueryFont(dpy: PXDisplay; name: PChar): PXFontStruct; cdecl; external;
function XFreeFont(dpy: PXDisplay; f: PXFontStruct): cint; cdecl; external;
function XSetFont(dpy: PXDisplay; gc: TGC; font: TXID): cint; cdecl; external;
function XTextWidth(f: PXFontStruct; s: PChar; count: cint): cint; cdecl; external;
function XDrawString(dpy: PXDisplay; d: TDrawable; gc: TGC; x, y: cint; s: PChar; len: cint): cint; cdecl; external;
function XGetImage(dpy: PXDisplay; d: TDrawable; x, y: cint; w, h: cuint; plane: culong; fmt: cint): PXImage; cdecl; external;

const
  ZPixmap = 2;
  CoordModeOrigin = 0;
  Unsorted = 0;

{ ---- helpers ---- }

{ UTF-8 -> Latin-1 (best effort): core X fonts are 8-bit iso8859-1, so map the
  BMP Latin-1 range and drop the rest to '?'. Fine for the Western demo text;
  full Unicode text is a job for Xft/freetype (the quality upgrade). }
function ToLatin1(const S: string): AnsiString;
var i, n, cp: Integer; b: Byte;
begin
  Result := '';
  i := 1; n := Length(S);
  while i <= n do
  begin
    b := Byte(S[i]);
    if b < $80 then begin Result := Result + AnsiChar(b); Inc(i); end
    else if (b and $E0) = $C0 then
    begin
      cp := ((b and $1F) shl 6) or (Byte(S[i+1]) and $3F);
      if cp <= 255 then Result := Result + AnsiChar(cp) else Result := Result + '?';
      Inc(i, 2);
    end
    else if (b and $F0) = $E0 then begin Result := Result + '?'; Inc(i, 3); end
    else if (b and $F8) = $F0 then begin Result := Result + '?'; Inc(i, 4); end
    else begin Result := Result + '?'; Inc(i); end;
  end;
end;

constructor TX11Canvas.Create(ADpy: PXDisplay; AScreen: cint; AGC: TGC);
begin
  inherited Create;
  FDpy := ADpy; FScreen := AScreen; FGC := AGC;
  FFonts := TStringList.Create;
  FFonts.Sorted := True; FFonts.Duplicates := dupIgnore;
  FCur.HasClip := False;
end;

destructor TX11Canvas.Destroy;
var i: Integer;
begin
  for i := 0 to FFonts.Count - 1 do
    if FFonts.Objects[i] <> nil then XFreeFont(FDpy, PXFontStruct(FFonts.Objects[i]));
  FFonts.Free;
  inherited Destroy;
end;

procedure TX11Canvas.BeginFrame(ADraw: TDrawable; AW, AH: cint);
begin
  FDraw := ADraw; FW := AW; FH := AH;
  SetLength(FStack, 0);
  FCur.HasClip := False; ApplyClip;
  XSetForeground(FDpy, FGC, $FFFFFF);           // white ground
  XFillRectangle(FDpy, FDraw, FGC, 0, 0, AW, AH);
end;

procedure TX11Canvas.SetFg(Color: TTina4Color);
begin
  XSetForeground(FDpy, FGC, culong(Color and $FFFFFF));   // $AARRGGBB -> RGB
end;

procedure TX11Canvas.ApplyClip;
var r: TXRectangle;
begin
  if FCur.HasClip then
  begin
    r.x := FCur.X; r.y := FCur.Y; r.width := FCur.W; r.height := FCur.H;
    XSetClipRectangles(FDpy, FGC, 0, 0, @r, 1, Unsorted);
  end
  else
    XSetClipMask(FDpy, FGC, 0);   // None
end;

procedure TX11Canvas.PushState;
var n: Integer;
begin
  n := Length(FStack); SetLength(FStack, n + 1); FStack[n] := FCur;
end;

procedure TX11Canvas.PopState;
var n: Integer;
begin
  n := Length(FStack);
  if n = 0 then Exit;
  FCur := FStack[n - 1]; SetLength(FStack, n - 1); ApplyClip;
end;

function TX11Canvas.FontFor(SizePx: Single; Styles: TTina4FontStyles): Pointer;
var fam, weight, slant, first, xlfd: string; px, p: Integer; f: PXFontStruct;
begin
  first := LowerCase(Trim(FontFamily));
  p := Pos(',', first); if p > 0 then first := Trim(Copy(first, 1, p - 1));
  first := StringReplace(first, '"', '', [rfReplaceAll]);
  first := StringReplace(first, '''', '', [rfReplaceAll]);
  if (first = '') or (first = 'sans-serif') or (first = 'system-ui') or (first = 'arial') then fam := 'helvetica'
  else if first = 'serif' then fam := 'times'
  else if (first = 'monospace') or (first = 'mono') or (first = 'consolas') then fam := 'courier'
  else fam := 'helvetica';   // unknown/unavailable specific family -> safe core scalable face
  if (tfsBold in Styles) or (FontWeight >= 600) then weight := 'bold' else weight := 'medium';
  if tfsItalic in Styles then slant := 'i' else slant := 'r';
  px := Round(SizePx); if px < 6 then px := 6;
  xlfd := Format('-*-%s-%s-%s-normal--%d-0-0-0-*-0-iso8859-1', [fam, weight, slant, px]);

  p := FFonts.IndexOf(xlfd);
  if p >= 0 then Exit(Pointer(FFonts.Objects[p]));
  f := XLoadQueryFont(FDpy, PChar(xlfd));
  if f = nil then f := XLoadQueryFont(FDpy, PChar(Format('-*-*-%s-%s-normal--%d-0-0-0-*-0-iso8859-1', [weight, slant, px])));
  if f = nil then f := XLoadQueryFont(FDpy, 'fixed');
  FFonts.AddObject(xlfd, TObject(f));
  Result := f;
end;

procedure TX11Canvas.FillRect(X, Y, W, H: Single; Color: TTina4Color);
begin
  if (W <= 0) or (H <= 0) then Exit;
  SetFg(Color);
  XFillRectangle(FDpy, FDraw, FGC, Round(X), Round(Y), Round(W), Round(H));
end;

procedure TX11Canvas.StrokeRect(X, Y, W, H, Thickness: Single; Color: TTina4Color);
begin
  SetFg(Color);
  XSetLineAttributes(FDpy, FGC, Round(Thickness), 0, 0, 0);
  XDrawRectangle(FDpy, FDraw, FGC, Round(X), Round(Y), Round(W), Round(H));
end;

procedure TX11Canvas.FillRoundRect(X, Y, W, H, Radius: Single; Color: TTina4Color);
var xi, yi, wi, hi, r, d: cint;
begin
  if (W <= 0) or (H <= 0) then Exit;
  r := Round(Radius);
  if r > Round(W / 2) then r := Round(W / 2);
  if r > Round(H / 2) then r := Round(H / 2);
  xi := Round(X); yi := Round(Y); wi := Round(W); hi := Round(H);
  if r <= 0 then begin FillRect(X, Y, W, H, Color); Exit; end;
  SetFg(Color);
  d := 2 * r;
  XFillRectangle(FDpy, FDraw, FGC, xi + r, yi, wi - d, hi);           // centre column
  XFillRectangle(FDpy, FDraw, FGC, xi, yi + r, r, hi - d);            // left edge
  XFillRectangle(FDpy, FDraw, FGC, xi + wi - r, yi + r, r, hi - d);   // right edge
  XFillArc(FDpy, FDraw, FGC, xi, yi, d, d, 90*64, 90*64);                    // TL
  XFillArc(FDpy, FDraw, FGC, xi + wi - d, yi, d, d, 0, 90*64);               // TR
  XFillArc(FDpy, FDraw, FGC, xi, yi + hi - d, d, d, 180*64, 90*64);          // BL
  XFillArc(FDpy, FDraw, FGC, xi + wi - d, yi + hi - d, d, d, 270*64, 90*64); // BR
end;

procedure TX11Canvas.StrokeRoundRect(X, Y, W, H, Radius, Thickness: Single; Color: TTina4Color);
begin
  // v1: square stroke (rounded stroke is a later refinement)
  StrokeRect(X, Y, W, H, Thickness, Color);
end;

procedure TX11Canvas.DrawLine(X1, Y1, X2, Y2, Thickness: Single; Color: TTina4Color);
begin
  SetFg(Color);
  XSetLineAttributes(FDpy, FGC, Round(Thickness), 0, 0, 0);
  XDrawLine(FDpy, FDraw, FGC, Round(X1), Round(Y1), Round(X2), Round(Y2));
end;

procedure TX11Canvas.DrawText(X, Y: Single; const Text: string; FontSize: Single;
  Styles: TTina4FontStyles; Color: TTina4Color);
var f: PXFontStruct; s: AnsiString; baseline: cint;
begin
  if Text = '' then Exit;
  f := PXFontStruct(FontFor(FontSize, Styles));
  if f = nil then Exit;
  XSetFont(FDpy, FGC, f^.fid);
  SetFg(Color);
  s := ToLatin1(Text);
  baseline := Round(Y) + f^.ascent;
  XDrawString(FDpy, FDraw, FGC, Round(X), baseline, PChar(s), Length(s));
end;

function TX11Canvas.MeasureText(const Text: string; FontSize: Single;
  Styles: TTina4FontStyles): TTina4TextMetrics;
var f: PXFontStruct; s: AnsiString;
begin
  f := PXFontStruct(FontFor(FontSize, Styles));
  s := ToLatin1(Text);
  if f <> nil then
  begin
    Result.Width := XTextWidth(f, PChar(s), Length(s));
    Result.Ascent := f^.ascent;
    Result.Descent := f^.descent;
    Result.LineHeight := f^.ascent + f^.descent;
  end
  else
  begin
    Result.Width := Round(Length(s) * FontSize * 0.5);
    Result.Ascent := Round(FontSize * 0.8);
    Result.Descent := Round(FontSize * 0.2);
    Result.LineHeight := Round(FontSize);
  end;
end;

procedure TX11Canvas.SetClip(X, Y, W, H: Single);
var nx, ny, nr, nb, cr, cb: cint;
begin
  PushState;
  nx := Round(X); ny := Round(Y); nr := Round(X + W); nb := Round(Y + H);
  if FCur.HasClip then
  begin
    cr := FCur.X + FCur.W; cb := FCur.Y + FCur.H;
    if FCur.X > nx then nx := FCur.X;
    if FCur.Y > ny then ny := FCur.Y;
    if cr < nr then nr := cr;
    if cb < nb then nb := cb;
  end;
  FCur.HasClip := True; FCur.X := nx; FCur.Y := ny;
  FCur.W := nr - nx; FCur.H := nb - ny;
  if FCur.W < 0 then FCur.W := 0; if FCur.H < 0 then FCur.H := 0;
  ApplyClip;
end;

procedure TX11Canvas.ClearClip;
begin
  PopState;
end;

procedure TX11Canvas.SaveState;
begin
  PushState;
end;

procedure TX11Canvas.RestoreState;
begin
  PopState;
end;

{ ---- BMP snapshot ---- }

function LinSaveBmp(ADpy: PXDisplay; ADraw: TDrawable; W, H: cint;
  const Path: string): Boolean;
var
  img: PXImage; fs: TFileStream;
  rowSize, imgSize, fileSize, off: LongWord;
  x, y, bpp: Integer; px: LongWord; p: PByte;
  bfh: array[0..13] of Byte; bih: array[0..39] of Byte;
  row: array of Byte;
  procedure PutLE32(var a: array of Byte; i: Integer; v: LongWord);
  begin a[i]:=v and $FF; a[i+1]:=(v shr 8) and $FF; a[i+2]:=(v shr 16) and $FF; a[i+3]:=(v shr 24) and $FF; end;
  procedure PutLE16(var a: array of Byte; i: Integer; v: Word);
  begin a[i]:=v and $FF; a[i+1]:=(v shr 8) and $FF; end;
begin
  Result := False;
  img := XGetImage(ADpy, ADraw, 0, 0, W, H, culong($FFFFFFFFFFFFFFFF), ZPixmap);
  if img = nil then Exit;
  bpp := img^.bits_per_pixel div 8;
  rowSize := ((LongWord(W) * 3 + 3) div 4) * 4;   // 24-bit rows padded to 4
  imgSize := rowSize * LongWord(H);
  fileSize := 54 + imgSize;
  FillChar(bfh, SizeOf(bfh), 0); FillChar(bih, SizeOf(bih), 0);
  bfh[0] := Ord('B'); bfh[1] := Ord('M');
  PutLE32(bfh, 2, fileSize); PutLE32(bfh, 10, 54);
  PutLE32(bih, 0, 40); PutLE32(bih, 4, LongWord(W)); PutLE32(bih, 8, LongWord(H));
  PutLE16(bih, 12, 1); PutLE16(bih, 14, 24); PutLE32(bih, 20, imgSize);
  SetLength(row, rowSize);
  try
    fs := TFileStream.Create(Path, fmCreate);
    try
      fs.WriteBuffer(bfh, 14); fs.WriteBuffer(bih, 40);
      for y := H - 1 downto 0 do                     // BMP is bottom-up
      begin
        FillChar(row[0], rowSize, 0);
        p := img^.data + y * img^.bytes_per_line;
        for x := 0 to W - 1 do
        begin
          if bpp >= 4 then px := PLongWord(p + x * 4)^
          else px := (PByte(p + x*3 + 2)^ shl 16) or (PByte(p + x*3 + 1)^ shl 8) or PByte(p + x*3)^;
          row[x*3]   := px and $FF;          // B
          row[x*3+1] := (px shr 8) and $FF;  // G
          row[x*3+2] := (px shr 16) and $FF; // R
        end;
        fs.WriteBuffer(row[0], rowSize);
      end;
      Result := True;
    finally fs.Free; end;
  except
    Result := False;
  end;
end;

end.
