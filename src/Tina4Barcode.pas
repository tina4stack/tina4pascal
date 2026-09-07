unit Tina4Barcode;

{ Desktop barcode DECODING via libzbar, loaded dynamically by soname so the
  engine keeps NO build- or link-time dependency on it: the desktop shells call
  this when a <barcode-scanner> is active, scanning works wherever libzbar is
  present, and every other build/target is unaffected when it isn't.

  Decodes an 8-bit grayscale (Y800) frame → the first symbol's value + type.
  iOS/macOS/Android use their OS-native decoders instead; this is the
  Windows/Linux path (chosen: bind a library rather than a pure-Pascal codec).
  This is a shell-layer helper (it has an OS dependency) — never used by the
  portable core. }

{$mode delphi}{$H+}

interface

{ True once libzbar has been located + bound (lazy, on first call). }
function Tina4BarcodeAvailable: Boolean;

{ Decode the first barcode in an 8-bit grayscale image (Gray = W*H bytes, row-
  major, 0 = black .. 255 = white). On success returns True with Value = decoded
  text and Format = the symbology name (e.g. "QR-Code", "EAN-13"). }
function Tina4DecodeBarcode(Gray: PByte; W, H: Integer;
  out Value, Format: string): Boolean;

{ Decode the first barcode in an image FILE (PNG/JPEG/BMP), grayscaling it first.
  The desktop camera loop does the same per captured frame; this also lets a
  barcode be read from a file or screenshot. }
function Tina4ScanImageFile(const Path: string; out Value, Format: string): Boolean;

implementation

uses SysUtils, dynlibs, ctypes, FPImage, FPReadPNG, FPReadJPEG, FPReadBMP;

type
  Tp_v      = function: Pointer; cdecl;
  Tv_p      = procedure(a: Pointer); cdecl;
  Tcfg      = function(s: Pointer; sym, cfg, val: cint): cint; cdecl;
  Tsetfmt   = procedure(img: Pointer; fmt: culong); cdecl;
  Tsetsize  = procedure(img: Pointer; w, h: cuint); cdecl;
  Tsetdata  = procedure(img, data: Pointer; len: culong; cleanup: Pointer); cdecl;
  Tscan     = function(s, img: Pointer): cint; cdecl;
  Tfirstsym = function(img: Pointer): Pointer; cdecl;
  Tsymdata  = function(sym: Pointer): PChar; cdecl;
  Tsymtype  = function(sym: Pointer): cint; cdecl;
  Tsymname  = function(typ: cint): PChar; cdecl;

var
  GTried: Boolean = False;
  GOk: Boolean = False;
  GLib: TLibHandle = 0;
  zScannerCreate:  Tp_v;
  zScannerDestroy: Tv_p;
  zSetConfig:      Tcfg;
  zImageCreate:    Tp_v;
  zImageDestroy:   Tv_p;
  zSetFormat:      Tsetfmt;
  zSetSize:        Tsetsize;
  zSetData:        Tsetdata;
  zScanImage:      Tscan;
  zFirstSymbol:    Tfirstsym;
  zSymbolData:     Tsymdata;
  zSymbolType:     Tsymtype;
  zSymbolName:     Tsymname;

function EnsureZbar: Boolean;

  function Names: TStringArray;
  begin
    {$IFDEF DARWIN}
    Result := TStringArray.Create('libzbar.0.dylib', 'libzbar.dylib');
    {$ELSE}{$IFDEF WINDOWS}
    Result := TStringArray.Create('libzbar-0.dll', 'zbar.dll');
    {$ELSE}
    Result := TStringArray.Create('libzbar.so.0', 'libzbar.so');
    {$ENDIF}{$ENDIF}
  end;

var i: Integer; nm: TStringArray;
begin
  if GTried then Exit(GOk);
  GTried := True;
  nm := Names;
  for i := 0 to High(nm) do
  begin GLib := LoadLibrary(nm[i]); if GLib <> 0 then Break; end;
  if GLib = 0 then Exit(False);
  zScannerCreate  := Tp_v(GetProcedureAddress(GLib, 'zbar_image_scanner_create'));
  zScannerDestroy := Tv_p(GetProcedureAddress(GLib, 'zbar_image_scanner_destroy'));
  zSetConfig      := Tcfg(GetProcedureAddress(GLib, 'zbar_image_scanner_set_config'));
  zImageCreate    := Tp_v(GetProcedureAddress(GLib, 'zbar_image_create'));
  zImageDestroy   := Tv_p(GetProcedureAddress(GLib, 'zbar_image_destroy'));
  zSetFormat      := Tsetfmt(GetProcedureAddress(GLib, 'zbar_image_set_format'));
  zSetSize        := Tsetsize(GetProcedureAddress(GLib, 'zbar_image_set_size'));
  zSetData        := Tsetdata(GetProcedureAddress(GLib, 'zbar_image_set_data'));
  zScanImage      := Tscan(GetProcedureAddress(GLib, 'zbar_scan_image'));
  zFirstSymbol    := Tfirstsym(GetProcedureAddress(GLib, 'zbar_image_first_symbol'));
  zSymbolData     := Tsymdata(GetProcedureAddress(GLib, 'zbar_symbol_get_data'));
  zSymbolType     := Tsymtype(GetProcedureAddress(GLib, 'zbar_symbol_get_type'));
  zSymbolName     := Tsymname(GetProcedureAddress(GLib, 'zbar_get_symbol_name'));
  GOk := Assigned(zScannerCreate) and Assigned(zSetConfig) and Assigned(zImageCreate)
     and Assigned(zSetFormat) and Assigned(zSetSize) and Assigned(zSetData)
     and Assigned(zScanImage) and Assigned(zFirstSymbol) and Assigned(zSymbolData)
     and Assigned(zSymbolType) and Assigned(zSymbolName) and Assigned(zImageDestroy)
     and Assigned(zScannerDestroy);
  Result := GOk;
end;

function Tina4BarcodeAvailable: Boolean;
begin Result := EnsureZbar; end;

function Fourcc(const S: string): culong;
begin
  Result := culong(Ord(S[1])) or (culong(Ord(S[2])) shl 8)
         or (culong(Ord(S[3])) shl 16) or (culong(Ord(S[4])) shl 24);
end;

function Tina4DecodeBarcode(Gray: PByte; W, H: Integer;
  out Value, Format: string): Boolean;
var scanner, img, sym: Pointer; typ: cint; d, nm: PChar;
begin
  Result := False; Value := ''; Format := '';
  if not EnsureZbar then Exit;
  if (Gray = nil) or (W <= 0) or (H <= 0) then Exit;
  scanner := zScannerCreate;
  if scanner = nil then Exit;
  try
    zSetConfig(scanner, 0, 0, 1);            // symbology ZBAR_NONE·cfg ENABLE·1 → all on
    img := zImageCreate;
    if img = nil then Exit;
    zSetFormat(img, Fourcc('Y800'));         // 8-bit grayscale
    zSetSize(img, W, H);
    zSetData(img, Gray, culong(W * H), nil); // no cleanup handler — we own Gray
    if zScanImage(scanner, img) > 0 then
    begin
      sym := zFirstSymbol(img);
      if sym <> nil then
      begin
        d := zSymbolData(sym);
        typ := zSymbolType(sym);
        nm := zSymbolName(typ);
        if d <> nil then Value := string(d);
        if nm <> nil then Format := string(nm);
        Result := Value <> '';
      end;
    end;
    zImageDestroy(img);
  finally
    zScannerDestroy(scanner);
  end;
end;

function Tina4ScanImageFile(const Path: string; out Value, Format: string): Boolean;
var
  img: TFPMemoryImage; gray: TBytes; x, y, w, h: Integer; c: TFPColor;
begin
  Result := False; Value := ''; Format := '';
  if not EnsureZbar then Exit;
  if not FileExists(Path) then Exit;
  img := TFPMemoryImage.Create(0, 0);
  try
    try img.LoadFromFile(Path);            // reader picked from the file's content
    except Exit; end;
    w := img.Width; h := img.Height;
    if (w <= 0) or (h <= 0) then Exit;
    SetLength(gray, w * h);
    for y := 0 to h - 1 do
      for x := 0 to w - 1 do
      begin
        c := img.Colors[x, y];             // 16-bit channels → Rec.601 luma → 8-bit
        gray[y * w + x] := Byte((299 * (c.red shr 8) + 587 * (c.green shr 8)
                                 + 114 * (c.blue shr 8)) div 1000);
      end;
    Result := Tina4DecodeBarcode(@gray[0], w, h, Value, Format);
  finally
    img.Free;
  end;
end;

end.
