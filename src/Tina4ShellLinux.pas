unit Tina4ShellLinux;

{ Linux/X11 desktop shell for the Tina4 native renderer.

  Implements the TTina4Canvas contract on plain Xlib (no GTK/Qt/LCL, no Xft) —
  the same idea as the Cocoa (AppKit) and Windows (GDI) shells. The host creates
  a Display, a back-buffer Pixmap and a GC; the engine paints into the Pixmap
  through this canvas, and the host XCopyArea's it to the window per frame.

  Renders: solid/rounded rects (XFillArc corners), lines, core scalable-font
  text (XLFD/iso8859-1), an intersecting clip stack, gradients (via the portable
  software rasteriser in the base canvas) AND the offscreen filter / mix-blend /
  mask / 3D compositor — drawn into layer Pixmaps, read back with XGetImage, run
  through the shared Tina4Compositor, and XPutImage'd onto the parent (the same
  pipeline the Windows shell runs on a DIB section). CSS transforms and images
  are the remaining v1 gaps (safe no-op degrade).

  Colours are $AARRGGBB; the pixel sent to X assumes a 24/32-bit TrueColor visual
  (RGB in the low 3 bytes), which is what Xorg/XWayland give by default. }

{$mode objfpc}{$H+}{$PACKRECORDS C}

interface

uses
  ctypes, SysUtils, Classes, Tina4RenderBackend, Tina4Compositor;

type
  TX11Image = record Data: PByte; W, H: Integer; end;   // decoded straight RGBA8

type
  PXDisplay = Pointer;
  TXID = culong;
  TDrawable = TXID;
  TGC = Pointer;

  TClipState = record HasClip: Boolean; X, Y, W, H: cint; end;

  TX11Layer = record
    Pm: TXID; Saved: TDrawable; SavedW, SavedH: cint;
    Ox, Oy, Bw, Bh: cint;
    SavedOrgX, SavedOrgY: cint;
    SavedClip: TClipState; SavedStackLen: Integer;
  end;

  TX11Canvas = class(TTina4Canvas)
  private
    FDpy: PXDisplay;
    FScreen: cint;
    FGC: TGC;
    FDraw: TDrawable;
    FW, FH: cint;               // dims of the current draw target
    FOrgX, FOrgY: cint;         // doc->target origin offset (nonzero inside a layer)
    FFonts: TStringList;
    FCur: TClipState;
    FStack: array of TClipState;
    FLayers: array of TX11Layer;
    FImages: array of TX11Image;
    FImageSrc: TStringList;
    function FontFor(SizePx: Single; Styles: TTina4FontStyles): Pointer;
    procedure SetFg(Color: TTina4Color);
    procedure ApplyClip;
    procedure PushState;
    procedure PopState;
    function DX(v: Single): cint; inline;
    function DY(v: Single): cint; inline;
    procedure AlphaFillRound(x, y, w, h, r: cint; Color: TTina4Color);
  public
    constructor Create(ADpy: PXDisplay; AScreen: cint; AGC: TGC);
    destructor Destroy; override;
    procedure BeginFrame(ADraw: TDrawable; AW, AH: cint);
    function LoadImage(const Src: string): Integer; override;
    function ImageSize(Handle: Integer; out W, H: Single): Boolean; override;
    procedure DrawImage(Handle: Integer; X, Y, W, H: Single); override;
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
    function BeginLayer(X, Y, W, H, Pad: Single): Integer; override;
    procedure EndLayerFiltered(Handle: Integer; const FilterSpec, BlendMode, MaskSpec: string); override;
    procedure BackdropFilter(X, Y, W, H: Single; const FilterSpec: string); override;
    procedure EndLayer3D(Handle: Integer; const Corners: array of Single); override;
    function SupportsRGBA: Boolean; override;
    procedure DrawRGBA(Buf: Pointer; BW, BH: Integer; dstX, dstY, dstW, dstH: Single); override;
  end;

{ Grab the back-buffer pixels and write them to a 24-bit BMP — the headless
  snapshot path for the reftest/compliance harness. }
function LinSaveBmp(ADpy: PXDisplay; ADraw: TDrawable; W, H: cint;
  const Path: string): Boolean;

implementation

{$linklib X11}

uses
  base64, md5, FPImage, FPReadPNG, FPReadJPEG, FPReadBMP,
  Types, freetypehdyn, freetype;   // scalable, Unicode, anti-aliased text

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
    obdata: Pointer;
    f: record
      create_image: Pointer;
      destroy_image: function(img: PXImage): cint; cdecl;
      get_pixel: Pointer;
      put_pixel: Pointer;
      sub_image: Pointer;
      add_pixel: Pointer;
    end;
  end;

function XSetForeground(dpy: PXDisplay; gc: TGC; c: culong): cint; cdecl; external;
function XFillRectangle(dpy: PXDisplay; d: TDrawable; gc: TGC; x, y: cint; w, h: cuint): cint; cdecl; external;
function XDrawRectangle(dpy: PXDisplay; d: TDrawable; gc: TGC; x, y: cint; w, h: cuint): cint; cdecl; external;
function XDrawLine(dpy: PXDisplay; d: TDrawable; gc: TGC; x1, y1, x2, y2: cint): cint; cdecl; external;
function XFillArc(dpy: PXDisplay; d: TDrawable; gc: TGC; x, y: cint; w, h: cuint; a1, a2: cint): cint; cdecl; external;
function XSetLineAttributes(dpy: PXDisplay; gc: TGC; w: cuint; ls, cs, js: cint): cint; cdecl; external;
function XSetClipRectangles(dpy: PXDisplay; gc: TGC; xo, yo: cint; r: Pointer; n, ordering: cint): cint; cdecl; external;
function XSetClipMask(dpy: PXDisplay; gc: TGC; p: TXID): cint; cdecl; external;
function XLoadQueryFont(dpy: PXDisplay; name: PChar): PXFontStruct; cdecl; external;
function XFreeFont(dpy: PXDisplay; f: PXFontStruct): cint; cdecl; external;
function XSetFont(dpy: PXDisplay; gc: TGC; font: TXID): cint; cdecl; external;
function XTextWidth(f: PXFontStruct; s: PChar; count: cint): cint; cdecl; external;
function XDrawString(dpy: PXDisplay; d: TDrawable; gc: TGC; x, y: cint; s: PChar; len: cint): cint; cdecl; external;
function XGetImage(dpy: PXDisplay; d: TDrawable; x, y: cint; w, h: cuint; plane: culong; fmt: cint): PXImage; cdecl; external;
function XPutImage(dpy: PXDisplay; d: TDrawable; gc: TGC; img: PXImage; sx, sy, dx, dy: cint; w, h: cuint): cint; cdecl; external;
function XCreatePixmap(dpy: PXDisplay; drw: TXID; w, h, depth: cuint): TXID; cdecl; external;
function XFreePixmap(dpy: PXDisplay; p: TXID): cint; cdecl; external;
function XRootWindow(dpy: PXDisplay; s: cint): TXID; cdecl; external;
function XDefaultDepth(dpy: PXDisplay; s: cint): cint; cdecl; external;

const
  ZPixmap = 2;
  Unsorted = 0;
  AllPlanes = culong($FFFFFFFFFFFFFFFF);

procedure DestroyImage(img: PXImage); inline;
begin
  if (img <> nil) and (img^.f.destroy_image <> nil) then img^.f.destroy_image(img);
end;

function GetPx(img: PXImage; x, y: cint): LongWord; inline;
var p: PByte;
begin
  p := img^.data + y * img^.bytes_per_line + x * (img^.bits_per_pixel div 8);
  Result := (LongWord(p[2]) shl 16) or (LongWord(p[1]) shl 8) or LongWord(p[0]);
end;

procedure SetPx(img: PXImage; x, y: cint; rgb: LongWord); inline;
var p: PByte;
begin
  p := img^.data + y * img^.bytes_per_line + x * (img^.bits_per_pixel div 8);
  p[0] := rgb and $FF; p[1] := (rgb shr 8) and $FF; p[2] := (rgb shr 16) and $FF;
end;

{ blend one premultiplied source pixel (sr,sg,sb,sa) over an opaque RGB dest,
  returning packed 0xRRGGBB — a straight port of the Windows shell's BlendPixel. }
function BlendRGB(dst: LongWord; sr, sg, sb, sa: Single; const Blend: string): LongWord;
var dr, dg, db, br, bg, bb: Single;
begin
  if sa <= 0 then Exit(dst);
  dr := ((dst shr 16) and $FF) / 255; dg := ((dst shr 8) and $FF) / 255; db := (dst and $FF) / 255;
  if Blend = '' then begin br := sr; bg := sg; bb := sb; end
  else
  begin
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
    br := br*sa; bg := bg*sa; bb := bb*sa;
  end;
  dr := br + dr*(1-sa); dg := bg + dg*(1-sa); db := bb + db*(1-sa);
  if dr<0 then dr:=0; if dr>1 then dr:=1; if dg<0 then dg:=0; if dg>1 then dg:=1; if db<0 then db:=0; if db>1 then db:=1;
  Result := (Round(dr*255) shl 16) or (Round(dg*255) shl 8) or Round(db*255);
end;

{ UTF-8 -> Latin-1 (best effort) for the 8-bit iso8859-1 core fonts. }
function ToLatin1(const S: string): AnsiString;
var i, n, cp: Integer; b: Byte;
begin
  Result := ''; i := 1; n := Length(S);
  while i <= n do
  begin
    b := Byte(S[i]);
    if b < $80 then begin Result := Result + AnsiChar(b); Inc(i); end
    else if (b and $E0) = $C0 then begin cp := ((b and $1F) shl 6) or (Byte(S[i+1]) and $3F); if cp <= 255 then Result := Result + AnsiChar(cp) else Result := Result + '?'; Inc(i, 2); end
    else if (b and $F0) = $E0 then begin Result := Result + '?'; Inc(i, 3); end
    else if (b and $F8) = $F0 then begin Result := Result + '?'; Inc(i, 4); end
    else begin Result := Result + '?'; Inc(i); end;
  end;
end;

{ ---- FreeType text (scalable, Unicode, anti-aliased) --------------------
  The X core-font path only reaches 8-bit iso8859-1 fonts, so non-Latin-1 code
  points (-, <->, ...) rendered as tofu. FreeType rasterises glyphs from a TTF
  and we composite the coverage over the back-buffer. Fonts are resolved
  bundled-first — a `fonts/` directory beside the executable ships with the app
  and wins over system fonts, so rendering is identical everywhere (even minimal
  containers). libfreetype is loaded by soname at runtime (no dev symlink, no
  link-time dependency). }
var
  GFtMgr: TFontManager = nil;
  GFtIds: TStringList = nil;    // ttf path -> font id (Objects hold id+1)
  GFtTried: Boolean = False;
  GFtReady: Boolean = False;

function EnsureFt: Boolean;
begin
  if GFtTried then Exit(GFtReady);
  GFtTried := True;
  try
    InitializeFreetype('libfreetype.so.6');   // by soname; present on all Linux
    GFtMgr := TFontManager.Create;
    GFtMgr.Resolution := 72;                   // point size == pixel size
    GFtIds := TStringList.Create; GFtIds.Sorted := True; GFtIds.Duplicates := dupIgnore;
    GFtReady := True;
  except
    GFtReady := False;
  end;
  Result := GFtReady;
end;

{ Ordered font search dirs: a `fonts/` folder beside the exe (bundled with the
  app) first, then the common system locations across distros. }
procedure FontDirs(out Dirs: TStringArray);
begin
  Dirs := TStringArray.Create(
    IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'fonts',
    '/usr/share/fonts/truetype/dejavu',
    '/usr/share/fonts/TTF',
    '/usr/share/fonts/dejavu',
    '/usr/local/share/fonts');
end;

{ Resolve a CSS family + style to a TTF path (bundled first). Falls back to the
  regular weight, then to any .ttf in the bundled fonts dir. '' if none found. }
function FtFontFile(const Family: string; Bold, Italic: Boolean): string;
var first, base, suf, cand: string; p, i: Integer; dirs: TStringArray; sr: TSearchRec;
begin
  Result := '';
  first := LowerCase(Trim(Family));
  p := Pos(',', first); if p > 0 then first := Trim(Copy(first, 1, p - 1));
  first := StringReplace(first, '"', '', [rfReplaceAll]);
  first := StringReplace(first, '''', '', [rfReplaceAll]);
  if first = 'serif' then base := 'DejaVuSerif'
  else if (first = 'monospace') or (first = 'mono') or (first = 'consolas') or (first = 'courier') then base := 'DejaVuSansMono'
  else base := 'DejaVuSans';
  if base = 'DejaVuSerif' then
  begin
    if Bold and Italic then suf := '-BoldItalic' else if Bold then suf := '-Bold'
    else if Italic then suf := '-Italic' else suf := '';
  end
  else
  begin
    if Bold and Italic then suf := '-BoldOblique' else if Bold then suf := '-Bold'
    else if Italic then suf := '-Oblique' else suf := '';
  end;
  FontDirs(dirs);
  for i := 0 to High(dirs) do
  begin
    cand := IncludeTrailingPathDelimiter(dirs[i]) + base + suf + '.ttf';
    if FileExists(cand) then Exit(cand);
  end;
  if suf <> '' then
    for i := 0 to High(dirs) do
    begin
      cand := IncludeTrailingPathDelimiter(dirs[i]) + base + '.ttf';
      if FileExists(cand) then Exit(cand);
    end;
  // last resort: any .ttf a user dropped into the bundled fonts dir
  if FindFirst(IncludeTrailingPathDelimiter(dirs[0]) + '*.ttf', faAnyFile, sr) = 0 then
  begin
    Result := IncludeTrailingPathDelimiter(dirs[0]) + sr.Name;
    FindClose(sr);
  end;
end;

function FtFontId(const Family: string; Bold, Italic: Boolean): Integer;
var path: string; p: Integer;
begin
  Result := -1;
  if not EnsureFt then Exit;
  path := FtFontFile(Family, Bold, Italic);
  if path = '' then Exit;
  p := GFtIds.IndexOf(path);
  if p >= 0 then Exit(PtrInt(GFtIds.Objects[p]) - 1);
  Result := GFtMgr.RequestFont(path);
  if Result >= 0 then GFtIds.AddObject(path, TObject(PtrInt(Result + 1)));
end;

constructor TX11Canvas.Create(ADpy: PXDisplay; AScreen: cint; AGC: TGC);
begin
  inherited Create;
  FDpy := ADpy; FScreen := AScreen; FGC := AGC;
  FFonts := TStringList.Create; FFonts.Sorted := True; FFonts.Duplicates := dupIgnore;
  FImageSrc := TStringList.Create; FImageSrc.Sorted := True; FImageSrc.Duplicates := dupIgnore;
  FCur.HasClip := False; FOrgX := 0; FOrgY := 0;
end;

destructor TX11Canvas.Destroy;
var i: Integer;
begin
  for i := 0 to FFonts.Count - 1 do
    if FFonts.Objects[i] <> nil then XFreeFont(FDpy, PXFontStruct(FFonts.Objects[i]));
  FFonts.Free;
  for i := 0 to High(FImages) do
    if FImages[i].Data <> nil then FreeMem(FImages[i].Data);
  FImageSrc.Free;
  inherited Destroy;
end;

function TX11Canvas.DX(v: Single): cint; begin Result := Round(v) - FOrgX; end;
function TX11Canvas.DY(v: Single): cint; begin Result := Round(v) - FOrgY; end;

procedure TX11Canvas.BeginFrame(ADraw: TDrawable; AW, AH: cint);
begin
  FDraw := ADraw; FW := AW; FH := AH; FOrgX := 0; FOrgY := 0;
  SetLength(FStack, 0); SetLength(FLayers, 0);
  FCur.HasClip := False; ApplyClip;
  XSetForeground(FDpy, FGC, $FFFFFF);
  XFillRectangle(FDpy, FDraw, FGC, 0, 0, AW, AH);
end;

procedure TX11Canvas.SetFg(Color: TTina4Color);
begin
  XSetForeground(FDpy, FGC, culong(Color and $FFFFFF));
end;

{ Resolve a CSS image Src (data: URI or local file) to a temp file FPImage can
  read. http(s) is not fetched here yet (needs the TLS stack) — a follow-up. }
function ResolveImageFile(const Src: string): string;
var low, dir, cache, ext: string; comma: Integer; bytes: AnsiString; fs: TFileStream;
begin
  Result := ''; low := LowerCase(Src);
  dir := IncludeTrailingPathDelimiter(GetTempDir) + 'tina4render' + PathDelim;
  ForceDirectories(dir);
  if Pos('data:', low) = 1 then
  begin
    comma := Pos(',', Src); if comma = 0 then Exit;
    if Pos(';base64', low) = 0 then Exit;
    ext := '.png';
    if (Pos('image/jpeg', low) > 0) or (Pos('image/jpg', low) > 0) then ext := '.jpg'
    else if Pos('image/bmp', low) > 0 then ext := '.bmp';
    cache := dir + MD5Print(MD5String(Src)) + ext;
    if not FileExists(cache) then
    begin
      bytes := DecodeStringBase64(Copy(Src, comma + 1, MaxInt));
      fs := TFileStream.Create(cache, fmCreate);
      try if Length(bytes) > 0 then fs.WriteBuffer(bytes[1], Length(bytes)); finally fs.Free; end;
    end;
    Result := cache;
  end
  else
  begin
    ext := Src;
    if Pos('file://', low) = 1 then ext := Copy(Src, 8, MaxInt);
    if FileExists(ext) then Result := ext;
  end;
end;

function TX11Canvas.LoadImage(const Src: string): Integer;
var idx, n, x, y, o: Integer; file_: string; fp: TFPMemoryImage; c: TFPColor; d: PByte;
begin
  if FImageSrc.Find(Src, idx) then Exit(Integer(PtrInt(FImageSrc.Objects[idx])));
  Result := -1;
  file_ := ResolveImageFile(Src);
  if file_ <> '' then
  begin
    fp := TFPMemoryImage.Create(0, 0);
    try
      try fp.LoadFromFile(file_); except fp.Free; fp := nil; end;
      if fp <> nil then
      begin
        n := Length(FImages); SetLength(FImages, n + 1);
        FImages[n].W := fp.Width; FImages[n].H := fp.Height;
        GetMem(d, fp.Width * fp.Height * 4);
        for y := 0 to fp.Height - 1 do
          for x := 0 to fp.Width - 1 do
          begin
            c := fp.Colors[x, y]; o := (y * fp.Width + x) * 4;
            d[o]   := c.Red shr 8; d[o+1] := c.Green shr 8;
            d[o+2] := c.Blue shr 8; d[o+3] := c.Alpha shr 8;
          end;
        FImages[n].Data := d;
        Result := n;
      end;
    finally
      if fp <> nil then fp.Free;
    end;
  end;
  // FPImage has no WebP reader — fall back to the base pure-Pascal decoder
  // (renders via DrawRGBA).
  if Result < 0 then Result := inherited LoadImage(Src);
  FImageSrc.AddObject(Src, TObject(PtrInt(Result)));
end;

function TX11Canvas.ImageSize(Handle: Integer; out W, H: Single): Boolean;
begin
  W := 0; H := 0;
  if Handle >= WEBP_HANDLE_BASE then Exit(inherited ImageSize(Handle, W, H));
  Result := (Handle >= 0) and (Handle <= High(FImages)) and (FImages[Handle].Data <> nil);
  if Result then begin W := FImages[Handle].W; H := FImages[Handle].H; end;
end;

function TX11Canvas.SupportsRGBA: Boolean;
begin
  Result := True;
end;

{ Blit a straight-alpha $AARRGGBB buffer by the same read-back/blend/put-image
  path as DrawImage, sourcing pixels from the Cardinal buffer. }
procedure TX11Canvas.DrawRGBA(Buf: Pointer; BW, BH: Integer; dstX, dstY, dstW, dstH: Single);
var
  dimg: PXImage; dx0, dy0, dw, dh, vx0, vy0, vx1, vy1: cint;
  i, j, sx, sy: cint; sa: Single; sp, dpx: LongWord; p: PLongWord;
begin
  if (Buf = nil) or (BW <= 0) or (BH <= 0) or (dstW <= 0) or (dstH <= 0) then Exit;
  p := PLongWord(Buf);
  dx0 := Round(dstX) - FOrgX; dy0 := Round(dstY) - FOrgY; dw := Round(dstW); dh := Round(dstH);
  vx0 := dx0; if vx0 < 0 then vx0 := 0;
  vy0 := dy0; if vy0 < 0 then vy0 := 0;
  vx1 := dx0 + dw; if vx1 > FW then vx1 := FW;
  vy1 := dy0 + dh; if vy1 > FH then vy1 := FH;
  if (vx1 <= vx0) or (vy1 <= vy0) then Exit;
  dimg := XGetImage(FDpy, FDraw, vx0, vy0, vx1 - vx0, vy1 - vy0, AllPlanes, ZPixmap);
  if dimg = nil then Exit;
  for j := 0 to (vy1 - vy0) - 1 do
    for i := 0 to (vx1 - vx0) - 1 do
    begin
      sx := ((vx0 + i - dx0) * BW) div dw; sy := ((vy0 + j - dy0) * BH) div dh;
      if (sx < 0) or (sx >= BW) or (sy < 0) or (sy >= BH) then Continue;
      sp := p[sy * BW + sx];                              // $AARRGGBB
      sa := ((sp shr 24) and $FF) / 255;
      if sa <= 0 then Continue;
      dpx := GetPx(dimg, i, j);
      SetPx(dimg, i, j, BlendRGB(dpx, (((sp shr 16) and $FF)/255)*sa,
        (((sp shr 8) and $FF)/255)*sa, ((sp and $FF)/255)*sa, sa, ''));
    end;
  XPutImage(FDpy, FDraw, FGC, dimg, 0, 0, vx0, vy0, vx1 - vx0, vy1 - vy0);
  DestroyImage(dimg);
end;

procedure TX11Canvas.DrawImage(Handle: Integer; X, Y, W, H: Single);
var
  img: TX11Image; dimg: PXImage; dx0, dy0, dw, dh, vx0, vy0, vx1, vy1: cint;
  i, j, sx, sy, so: cint; sa: Single; dpx: LongWord; d: PByte;
begin
  if Handle >= WEBP_HANDLE_BASE then begin inherited DrawImage(Handle, X, Y, W, H); Exit; end;
  if (Handle < 0) or (Handle > High(FImages)) or (FImages[Handle].Data = nil) then Exit;
  if (W <= 0) or (H <= 0) then Exit;
  img := FImages[Handle];
  dx0 := DX(X); dy0 := DY(Y); dw := Round(W); dh := Round(H);
  vx0 := dx0; if vx0 < 0 then vx0 := 0;
  vy0 := dy0; if vy0 < 0 then vy0 := 0;
  vx1 := dx0 + dw; if vx1 > FW then vx1 := FW;
  vy1 := dy0 + dh; if vy1 > FH then vy1 := FH;
  if (vx1 <= vx0) or (vy1 <= vy0) then Exit;
  dimg := XGetImage(FDpy, FDraw, vx0, vy0, vx1 - vx0, vy1 - vy0, AllPlanes, ZPixmap);
  if dimg = nil then Exit;
  d := img.Data;
  for j := 0 to (vy1 - vy0) - 1 do
    for i := 0 to (vx1 - vx0) - 1 do
    begin
      sx := ((vx0 + i - dx0) * img.W) div dw; sy := ((vy0 + j - dy0) * img.H) div dh;
      if (sx < 0) or (sx >= img.W) or (sy < 0) or (sy >= img.H) then Continue;
      so := (sy * img.W + sx) * 4;
      sa := d[so+3] / 255;
      if sa <= 0 then Continue;
      dpx := GetPx(dimg, i, j);
      SetPx(dimg, i, j, BlendRGB(dpx, (d[so]/255)*sa, (d[so+1]/255)*sa, (d[so+2]/255)*sa, sa, ''));
    end;
  XPutImage(FDpy, FDraw, FGC, dimg, 0, 0, vx0, vy0, vx1 - vx0, vy1 - vy0);
  DestroyImage(dimg);
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
    XSetClipMask(FDpy, FGC, 0);
end;

procedure TX11Canvas.PushState;
var n: Integer;
begin n := Length(FStack); SetLength(FStack, n + 1); FStack[n] := FCur; end;

procedure TX11Canvas.PopState;
var n: Integer;
begin
  n := Length(FStack); if n = 0 then Exit;
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
  else fam := 'helvetica';
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

{ Alpha-blend a (optionally rounded) rect over the back-buffer via XGetImage/
  XPutImage — core X fills are opaque, so this is how rgba()/box-shadow render
  (and why the date-picker calendar's soft shadow no longer paints solid black). }
procedure TX11Canvas.AlphaFillRound(x, y, w, h, r: cint; Color: TTina4Color);
var
  img: PXImage; vx0, vy0, vx1, vy1, i, j, px, py, cxp, cyp: cint;
  sr, sg, sb, sa: Single; inside: Boolean; dpx: LongWord;
begin
  if (w <= 0) or (h <= 0) then Exit;
  if r > (w div 2) then r := w div 2;
  if r > (h div 2) then r := h div 2;
  if r < 0 then r := 0;
  vx0 := x; if vx0 < 0 then vx0 := 0;
  vy0 := y; if vy0 < 0 then vy0 := 0;
  vx1 := x + w; if vx1 > FW then vx1 := FW;
  vy1 := y + h; if vy1 > FH then vy1 := FH;
  if (vx1 <= vx0) or (vy1 <= vy0) then Exit;
  sa := ((Color shr 24) and $FF) / 255;
  sr := (((Color shr 16) and $FF) / 255) * sa;
  sg := (((Color shr 8) and $FF) / 255) * sa;
  sb := ((Color and $FF) / 255) * sa;
  img := XGetImage(FDpy, FDraw, vx0, vy0, vx1 - vx0, vy1 - vy0, AllPlanes, ZPixmap);
  if img = nil then Exit;
  for j := 0 to (vy1 - vy0) - 1 do
    for i := 0 to (vx1 - vx0) - 1 do
    begin
      px := vx0 + i; py := vy0 + j; inside := True;
      if r > 0 then
      begin
        if px < x + r then cxp := x + r else if px > x + w - 1 - r then cxp := x + w - 1 - r else cxp := px;
        if py < y + r then cyp := y + r else if py > y + h - 1 - r then cyp := y + h - 1 - r else cyp := py;
        if (cxp <> px) or (cyp <> py) then
          inside := ((px - cxp) * (px - cxp) + (py - cyp) * (py - cyp)) <= r * r;
      end;
      if inside then
      begin
        dpx := GetPx(img, i, j);
        SetPx(img, i, j, BlendRGB(dpx, sr, sg, sb, sa, ''));
      end;
    end;
  XPutImage(FDpy, FDraw, FGC, img, 0, 0, vx0, vy0, vx1 - vx0, vy1 - vy0);
  DestroyImage(img);
end;

procedure TX11Canvas.FillRect(X, Y, W, H: Single; Color: TTina4Color);
var a: LongWord;
begin
  if (W <= 0) or (H <= 0) then Exit;
  a := (LongWord(Color) shr 24) and $FF;
  if (a > 0) and (a < $FF) then begin AlphaFillRound(DX(X), DY(Y), Round(W), Round(H), 0, Color); Exit; end;
  SetFg(Color);
  XFillRectangle(FDpy, FDraw, FGC, DX(X), DY(Y), Round(W), Round(H));
end;

procedure TX11Canvas.StrokeRect(X, Y, W, H, Thickness: Single; Color: TTina4Color);
begin
  SetFg(Color);
  XSetLineAttributes(FDpy, FGC, Round(Thickness), 0, 0, 0);
  XDrawRectangle(FDpy, FDraw, FGC, DX(X), DY(Y), Round(W), Round(H));
end;

procedure TX11Canvas.FillRoundRect(X, Y, W, H, Radius: Single; Color: TTina4Color);
var xi, yi, wi, hi, r, d: cint; a: LongWord;
begin
  if (W <= 0) or (H <= 0) then Exit;
  a := (LongWord(Color) shr 24) and $FF;
  if (a > 0) and (a < $FF) then
  begin AlphaFillRound(DX(X), DY(Y), Round(W), Round(H), Round(Radius), Color); Exit; end;
  r := Round(Radius);
  if r > Round(W / 2) then r := Round(W / 2);
  if r > Round(H / 2) then r := Round(H / 2);
  xi := DX(X); yi := DY(Y); wi := Round(W); hi := Round(H);
  if r <= 0 then begin SetFg(Color); XFillRectangle(FDpy, FDraw, FGC, xi, yi, wi, hi); Exit; end;
  SetFg(Color);
  d := 2 * r;
  XFillRectangle(FDpy, FDraw, FGC, xi + r, yi, wi - d, hi);
  XFillRectangle(FDpy, FDraw, FGC, xi, yi + r, r, hi - d);
  XFillRectangle(FDpy, FDraw, FGC, xi + wi - r, yi + r, r, hi - d);
  XFillArc(FDpy, FDraw, FGC, xi, yi, d, d, 90*64, 90*64);
  XFillArc(FDpy, FDraw, FGC, xi + wi - d, yi, d, d, 0, 90*64);
  XFillArc(FDpy, FDraw, FGC, xi, yi + hi - d, d, d, 180*64, 90*64);
  XFillArc(FDpy, FDraw, FGC, xi + wi - d, yi + hi - d, d, d, 270*64, 90*64);
end;

procedure TX11Canvas.StrokeRoundRect(X, Y, W, H, Radius, Thickness: Single; Color: TTina4Color);
begin
  StrokeRect(X, Y, W, H, Thickness, Color);
end;

procedure TX11Canvas.DrawLine(X1, Y1, X2, Y2, Thickness: Single; Color: TTina4Color);
begin
  SetFg(Color);
  XSetLineAttributes(FDpy, FGC, Round(Thickness), 0, 0, 0);
  XDrawLine(FDpy, FDraw, FGC, DX(X1), DY(Y1), DX(X2), DY(Y2));
end;

procedure TX11Canvas.DrawText(X, Y: Single; const Text: string; FontSize: Single;
  Styles: TTina4FontStyles; Color: TTina4Color);
var
  f: PXFontStruct; s: AnsiString;
  fid, i, gx, gy, sx0, sy0, sx1, sy1, bx, by, px, py, baseY, asc: Integer;
  ub: TUnicodeStringBitmaps; b: PFontBitmap; img: PXImage;
  cov: Byte; ca, sa, sr, sg, sb2: Single; bold, ital: Boolean;
begin
  if Text = '' then Exit;
  bold := (tfsBold in Styles) or (FontWeight >= 600);
  ital := tfsItalic in Styles;
  fid := FtFontId(FontFamily, bold, ital);
  if fid >= 0 then
  begin
    asc := Round(FontSize * 0.8);            // matches MeasureText ascent
    baseY := DY(Y) + asc;
    ub := GFtMgr.GetStringGray(fid, UTF8Decode(Text), FontSize);
    try
      // union of glyph ink rects → the region to read/composite/write
      sx0 := FW; sy0 := FH; sx1 := 0; sy1 := 0;
      for i := 0 to ub.Count - 1 do
      begin
        b := ub.Bitmaps[i];
        if (b^.width <= 0) or (b^.height <= 0) or (b^.data = nil) then Continue;
        bx := DX(X) + b^.x; by := baseY + b^.y;
        if bx < sx0 then sx0 := bx; if by < sy0 then sy0 := by;
        if bx + b^.width > sx1 then sx1 := bx + b^.width;
        if by + b^.height > sy1 then sy1 := by + b^.height;
      end;
      if sx1 <= sx0 then Exit;                // whitespace only, nothing to ink
      if sx0 < 0 then sx0 := 0; if sy0 < 0 then sy0 := 0;
      if sx1 > FW then sx1 := FW; if sy1 > FH then sy1 := FH;
      if FCur.HasClip then
      begin
        if sx0 < FCur.X then sx0 := FCur.X; if sy0 < FCur.Y then sy0 := FCur.Y;
        if sx1 > FCur.X + FCur.W then sx1 := FCur.X + FCur.W;
        if sy1 > FCur.Y + FCur.H then sy1 := FCur.Y + FCur.H;
      end;
      if (sx1 <= sx0) or (sy1 <= sy0) then Exit;
      img := XGetImage(FDpy, FDraw, sx0, sy0, sx1 - sx0, sy1 - sy0, AllPlanes, ZPixmap);
      if img = nil then Exit;
      ca := ((Color shr 24) and $FF) / 255; if ca <= 0 then ca := 1;  // FF=opaque; 0 treated opaque (matches core)
      for i := 0 to ub.Count - 1 do
      begin
        b := ub.Bitmaps[i];
        if (b^.width <= 0) or (b^.height <= 0) or (b^.data = nil) then Continue;
        bx := DX(X) + b^.x; by := baseY + b^.y;
        for gy := 0 to b^.height - 1 do
          for gx := 0 to b^.width - 1 do
          begin
            cov := b^.data^[gy * b^.pitch + gx];
            if cov = 0 then Continue;
            px := bx + gx; py := by + gy;
            if (px < sx0) or (px >= sx1) or (py < sy0) or (py >= sy1) then Continue;
            sa := ca * (cov / 255);
            sr := (((Color shr 16) and $FF) / 255) * sa;
            sg := (((Color shr 8) and $FF) / 255) * sa;
            sb2 := ((Color and $FF) / 255) * sa;
            SetPx(img, px - sx0, py - sy0,
              BlendRGB(GetPx(img, px - sx0, py - sy0), sr, sg, sb2, sa, ''));
          end;
      end;
      XPutImage(FDpy, FDraw, FGC, img, 0, 0, sx0, sy0, sx1 - sx0, sy1 - sy0);
      DestroyImage(img);
    finally
      ub.Free;
    end;
    Exit;
  end;
  // fallback: 8-bit iso8859-1 core font
  f := PXFontStruct(FontFor(FontSize, Styles));
  if f = nil then Exit;
  XSetFont(FDpy, FGC, f^.fid);
  SetFg(Color);
  s := ToLatin1(Text);
  XDrawString(FDpy, FDraw, FGC, DX(X), DY(Y) + f^.ascent, PChar(s), Length(s));
end;

function TX11Canvas.MeasureText(const Text: string; FontSize: Single;
  Styles: TTina4FontStyles): TTina4TextMetrics;
var
  f: PXFontStruct; s: AnsiString; fid: Integer;
  ub: TUnicodeStringBitmaps; b: PFontBitmap; bold, ital: Boolean;
begin
  bold := (tfsBold in Styles) or (FontWeight >= 600);
  ital := tfsItalic in Styles;
  fid := FtFontId(FontFamily, bold, ital);
  if fid >= 0 then
  begin
    ub := GFtMgr.GetStringGray(fid, UTF8Decode(Text), FontSize);
    try
      if ub.Count > 0 then
      begin
        b := ub.Bitmaps[ub.Count - 1];
        Result.Width := b^.x + b^.advanceX / 1024;   // advance width (incl. spaces)
      end
      else
        Result.Width := 0;
    finally
      ub.Free;
    end;
    Result.Ascent := Round(FontSize * 0.8);
    Result.Descent := Round(FontSize * 0.2);
    Result.LineHeight := Result.Ascent + Result.Descent;
    Exit;
  end;
  // fallback: 8-bit iso8859-1 core font
  f := PXFontStruct(FontFor(FontSize, Styles));
  s := ToLatin1(Text);
  if f <> nil then
  begin
    Result.Width := XTextWidth(f, PChar(s), Length(s));
    Result.Ascent := f^.ascent; Result.Descent := f^.descent;
    Result.LineHeight := f^.ascent + f^.descent;
  end
  else
  begin
    Result.Width := Round(Length(s) * FontSize * 0.5);
    Result.Ascent := Round(FontSize * 0.8); Result.Descent := Round(FontSize * 0.2);
    Result.LineHeight := Round(FontSize);
  end;
end;

procedure TX11Canvas.SetClip(X, Y, W, H: Single);
var nx, ny, nr, nb, cr, cb: cint;
begin
  PushState;
  nx := DX(X); ny := DY(Y); nr := nx + Round(W); nb := ny + Round(H);
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

procedure TX11Canvas.ClearClip; begin PopState; end;
procedure TX11Canvas.SaveState; begin PushState; end;
procedure TX11Canvas.RestoreState; begin PopState; end;

{ ---- offscreen compositor (filter / blend / mask / 3D) ---- }

{ Decode a layer's XImage into a premultiplied RGBA Single buffer, synthesising
  alpha from geometry: opaque inside the element's core box, transparent in the
  pad ring so a blur/drop-shadow fades — identical to the Windows DecodeLayer. }
function DecodeLayerImg(img: PXImage; padx, pady, coreW, coreH, bw, bh: cint): PSingle;
var x, y, o: cint; a: Single; rgb: LongWord;
begin
  GetMem(Result, bw * bh * 4 * SizeOf(Single));
  for y := 0 to bh - 1 do
    for x := 0 to bw - 1 do
    begin
      o := (y * bw + x) * 4;
      if (x >= padx) and (x < padx + coreW) and (y >= pady) and (y < pady + coreH) then a := 1 else a := 0;
      rgb := GetPx(img, x, y);
      Result[o]   := (((rgb shr 16) and $FF) / 255) * a;
      Result[o+1] := (((rgb shr 8) and $FF) / 255) * a;
      Result[o+2] := ((rgb and $FF) / 255) * a;
      Result[o+3] := a;
    end;
end;

{ Composite a premultiplied Single RGBA buffer (layerW x layerH, its (0,0) at doc
  ox,oy) onto the parent drawable, clamped to the parent's bounds. }
procedure TX11Canvas.EndLayerFiltered(Handle: Integer; const FilterSpec, BlendMode, MaskSpec: string);
var
  L: TX11Layer; buf: PSingle; layerImg, destImg: PXImage;
  padx, pady, coreW, coreH: cint;
  vx0, vy0, vx1, vy1, i, j, lx, ly, so: cint; blend: string; dpx: LongWord;
begin
  if (Handle < 0) or (Handle > High(FLayers)) then Exit;
  L := FLayers[Handle];
  FDraw := L.Saved; FW := L.SavedW; FH := L.SavedH;
  FOrgX := L.SavedOrgX; FOrgY := L.SavedOrgY;
  FCur := L.SavedClip; SetLength(FStack, L.SavedStackLen); ApplyClip;

  padx := 0; pady := 0; coreW := L.Bw; coreH := L.Bh;
  if FilterSpec <> '' then
  begin
    padx := Round(FilterLayerPad(FilterSpec)); pady := padx;
    coreW := L.Bw - 2*padx; coreH := L.Bh - 2*pady;
    if coreW < 0 then coreW := L.Bw; if coreH < 0 then coreH := L.Bh;
  end;

  layerImg := XGetImage(FDpy, L.Pm, 0, 0, L.Bw, L.Bh, AllPlanes, ZPixmap);
  if layerImg <> nil then
  begin
    buf := DecodeLayerImg(layerImg, padx, pady, coreW, coreH, L.Bw, L.Bh);
    DestroyImage(layerImg);
    if (FilterSpec <> '') or (MaskSpec <> '') then
      ApplyFilterChainF(PSingleBuf(buf), L.Bw, L.Bh, FilterSpec, MaskSpec, 1);

    // valid parent rect (clamp the layer's doc rect into the parent)
    vx0 := L.Ox; if vx0 < 0 then vx0 := 0;
    vy0 := L.Oy; if vy0 < 0 then vy0 := 0;
    vx1 := L.Ox + L.Bw; if vx1 > L.SavedW then vx1 := L.SavedW;
    vy1 := L.Oy + L.Bh; if vy1 > L.SavedH then vy1 := L.SavedH;
    if (vx1 > vx0) and (vy1 > vy0) then
    begin
      destImg := XGetImage(FDpy, L.Saved, vx0, vy0, vx1 - vx0, vy1 - vy0, AllPlanes, ZPixmap);
      if destImg <> nil then
      begin
        blend := LowerCase(BlendMode); if blend = 'normal' then blend := '';
        for j := 0 to (vy1 - vy0) - 1 do
          for i := 0 to (vx1 - vx0) - 1 do
          begin
            lx := (vx0 + i) - L.Ox; ly := (vy0 + j) - L.Oy;
            so := (ly * L.Bw + lx) * 4;
            if buf[so+3] > 0 then
            begin
              dpx := GetPx(destImg, i, j);
              SetPx(destImg, i, j, BlendRGB(dpx, buf[so], buf[so+1], buf[so+2], buf[so+3], blend));
            end;
          end;
        XPutImage(FDpy, L.Saved, FGC, destImg, 0, 0, vx0, vy0, vx1 - vx0, vy1 - vy0);
        DestroyImage(destImg);
      end;
    end;
    FreeMem(buf);
  end;
  XFreePixmap(FDpy, L.Pm);
  SetLength(FLayers, Handle);
end;

function TX11Canvas.BeginLayer(X, Y, W, H, Pad: Single): Integer;
var ox, oy, bw, bh, n: cint; pm: TXID;
begin
  ox := Round(X - Pad); oy := Round(Y - Pad);
  bw := Round(W + 2*Pad); bh := Round(H + 2*Pad);
  if (bw <= 0) or (bh <= 0) then Exit(-1);
  pm := XCreatePixmap(FDpy, XRootWindow(FDpy, FScreen), bw, bh, XDefaultDepth(FDpy, FScreen));
  if pm = 0 then Exit(-1);
  n := Length(FLayers); SetLength(FLayers, n + 1);
  FLayers[n].Pm := pm; FLayers[n].Saved := FDraw; FLayers[n].SavedW := FW; FLayers[n].SavedH := FH;
  FLayers[n].Ox := ox; FLayers[n].Oy := oy; FLayers[n].Bw := bw; FLayers[n].Bh := bh;
  FLayers[n].SavedOrgX := FOrgX; FLayers[n].SavedOrgY := FOrgY;
  FLayers[n].SavedClip := FCur; FLayers[n].SavedStackLen := Length(FStack);
  // redirect drawing into the layer pixmap, doc coords offset so (ox,oy)->(0,0)
  FDraw := pm; FW := bw; FH := bh; FOrgX := ox; FOrgY := oy;
  FCur.HasClip := False; ApplyClip;
  XSetForeground(FDpy, FGC, $FFFFFF);
  XFillRectangle(FDpy, pm, FGC, 0, 0, bw, bh);
  Result := n;
end;

procedure TX11Canvas.EndLayer3D(Handle: Integer; const Corners: array of Single);
var
  L: TX11Layer; src: PSingle; dst: PByte; layerImg, destImg: PXImage;
  minx, miny, maxx, maxy: Single; i, dpw, dph, j, vx0, vy0, vx1, vy1, lx, ly, so: cint;
  quad: array[0..7] of Single; dpx: LongWord;
begin
  if (Handle < 0) or (Handle > High(FLayers)) then Exit;
  L := FLayers[Handle];
  FDraw := L.Saved; FW := L.SavedW; FH := L.SavedH;
  FOrgX := L.SavedOrgX; FOrgY := L.SavedOrgY;
  FCur := L.SavedClip; SetLength(FStack, L.SavedStackLen); ApplyClip;

  layerImg := XGetImage(FDpy, L.Pm, 0, 0, L.Bw, L.Bh, AllPlanes, ZPixmap);
  if layerImg <> nil then
  begin
    src := DecodeLayerImg(layerImg, 0, 0, L.Bw, L.Bh, L.Bw, L.Bh);
    DestroyImage(layerImg);
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
      WarpQuad(PSingleBuf(src), L.Bw, L.Bh, quad, dst, dpw, dph);
      vx0 := Round(minx); if vx0 < 0 then vx0 := 0;
      vy0 := Round(miny); if vy0 < 0 then vy0 := 0;
      vx1 := Round(minx) + dpw; if vx1 > L.SavedW then vx1 := L.SavedW;
      vy1 := Round(miny) + dph; if vy1 > L.SavedH then vy1 := L.SavedH;
      if (vx1 > vx0) and (vy1 > vy0) then
      begin
        destImg := XGetImage(FDpy, L.Saved, vx0, vy0, vx1 - vx0, vy1 - vy0, AllPlanes, ZPixmap);
        if destImg <> nil then
        begin
          for j := 0 to (vy1 - vy0) - 1 do
            for i := 0 to (vx1 - vx0) - 1 do
            begin
              lx := (vx0 + i) - Round(minx); ly := (vy0 + j) - Round(miny);
              so := (ly * dpw + lx) * 4;
              if dst[so+3] > 0 then
              begin
                dpx := GetPx(destImg, i, j);
                SetPx(destImg, i, j, BlendRGB(dpx, dst[so]/255, dst[so+1]/255, dst[so+2]/255, dst[so+3]/255, ''));
              end;
            end;
          XPutImage(FDpy, L.Saved, FGC, destImg, 0, 0, vx0, vy0, vx1 - vx0, vy1 - vy0);
          DestroyImage(destImg);
        end;
      end;
      FreeMem(dst);
    end;
    FreeMem(src);
  end;
  XFreePixmap(FDpy, L.Pm);
  SetLength(FLayers, Handle);
end;

procedure TX11Canvas.BackdropFilter(X, Y, W, H: Single; const FilterSpec: string);
var
  img: PXImage; buf: PSingle; bx, by, bw, bh, i, j, so: cint; rgb: LongWord;
begin
  if FilterSpec = '' then Exit;
  bx := DX(X); by := DY(Y); bw := Round(W); bh := Round(H);
  if bx < 0 then begin bw := bw + bx; bx := 0; end;
  if by < 0 then begin bh := bh + by; by := 0; end;
  if bx + bw > FW then bw := FW - bx;
  if by + bh > FH then bh := FH - by;
  if (bw <= 0) or (bh <= 0) then Exit;
  img := XGetImage(FDpy, FDraw, bx, by, bw, bh, AllPlanes, ZPixmap);
  if img = nil then Exit;
  GetMem(buf, bw * bh * 4 * SizeOf(Single));
  try
    for j := 0 to bh - 1 do
      for i := 0 to bw - 1 do
      begin
        so := (j * bw + i) * 4; rgb := GetPx(img, i, j);
        buf[so] := ((rgb shr 16) and $FF)/255; buf[so+1] := ((rgb shr 8) and $FF)/255;
        buf[so+2] := (rgb and $FF)/255; buf[so+3] := 1;
      end;
    ApplyFilterChainF(PSingleBuf(buf), bw, bh, FilterSpec, '', 1);
    for j := 0 to bh - 1 do
      for i := 0 to bw - 1 do
      begin
        so := (j * bw + i) * 4;
        SetPx(img, i, j, (Round(buf[so]*255) shl 16) or (Round(buf[so+1]*255) shl 8) or Round(buf[so+2]*255));
      end;
    XPutImage(FDpy, FDraw, FGC, img, 0, 0, bx, by, bw, bh);
  finally
    FreeMem(buf); DestroyImage(img);
  end;
end;

{ ---- BMP snapshot ---- }

function LinSaveBmp(ADpy: PXDisplay; ADraw: TDrawable; W, H: cint;
  const Path: string): Boolean;
var
  img: PXImage; fs: TFileStream;
  rowSize, imgSize, fileSize: LongWord;
  x, y, bpp: cint; px: LongWord; p: PByte;
  bfh: array[0..13] of Byte; bih: array[0..39] of Byte;
  row: array of Byte;
  procedure PutLE32(var a: array of Byte; i: Integer; v: LongWord);
  begin a[i]:=v and $FF; a[i+1]:=(v shr 8) and $FF; a[i+2]:=(v shr 16) and $FF; a[i+3]:=(v shr 24) and $FF; end;
  procedure PutLE16(var a: array of Byte; i: Integer; v: Word);
  begin a[i]:=v and $FF; a[i+1]:=(v shr 8) and $FF; end;
begin
  Result := False;
  img := XGetImage(ADpy, ADraw, 0, 0, W, H, AllPlanes, ZPixmap);
  if img = nil then Exit;
  bpp := img^.bits_per_pixel div 8;
  rowSize := ((LongWord(W) * 3 + 3) div 4) * 4;
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
      for y := H - 1 downto 0 do
      begin
        FillChar(row[0], rowSize, 0);
        p := img^.data + y * img^.bytes_per_line;
        for x := 0 to W - 1 do
        begin
          if bpp >= 4 then px := PLongWord(p + x * 4)^
          else px := (PByte(p + x*3 + 2)^ shl 16) or (PByte(p + x*3 + 1)^ shl 8) or PByte(p + x*3)^;
          row[x*3]   := px and $FF;
          row[x*3+1] := (px shr 8) and $FF;
          row[x*3+2] := (px shr 16) and $FF;
        end;
        fs.WriteBuffer(row[0], rowSize);
      end;
      Result := True;
    finally fs.Free; end;
  except Result := False; end;
  DestroyImage(img);
end;

end.
