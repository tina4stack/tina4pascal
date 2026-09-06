unit Tina4WebP;

{ Pure-Pascal WebP decoder — no OS codecs, no external DLLs, no FPImage. Decodes a
  WebP byte buffer to straight-alpha RGBA so `<img>` works identically on EVERY
  Tina4 shell (incl. Windows GDI+/Linux, which have no WebP) and headless targets
  (the PDF exporter). Framework-decoupled: a plain function in the portable core.

  This unit covers the LOSSLESS path (VP8L) + alpha — the common case for UI icons
  and graphics ("small image rendering"). Lossy VP8 is decoded by Tina4WebPVP8
  (added separately); Tina4DecodeWebP dispatches on the chunk type. }

{$mode delphi}{$H+}{$POINTERMATH ON}

interface

uses SysUtils;

{ Decode a WebP image. Data/Size = the whole file bytes. On success returns True
  with RGBA = W*H*4 straight-alpha bytes (R,G,B,A), top-left origin. }
function Tina4DecodeWebP(Data: PByte; Size: Integer; out RGBA: TBytes;
  out W, H: Integer): Boolean;

implementation

uses Tina4WebPVP8;

type
  { LSB-first bit reader over a byte span (VP8L bit order). }
  TBitReader = record
    Buf: PByte; Len: Integer; Pos: Integer;   // byte position
    Bits: UInt64; Have: Integer;              // bit accumulator
    EOS: Boolean;
  end;

procedure BR_Init(var br: TBitReader; Buf: PByte; Len: Integer);
begin
  br.Buf := Buf; br.Len := Len; br.Pos := 0; br.Bits := 0; br.Have := 0; br.EOS := False;
end;

function BR_Read(var br: TBitReader; n: Integer): Cardinal;
begin
  while br.Have < n do
  begin
    if br.Pos < br.Len then
    begin
      br.Bits := br.Bits or (UInt64(br.Buf[br.Pos]) shl br.Have);
      Inc(br.Pos); Inc(br.Have, 8);
    end
    else begin br.EOS := True; Inc(br.Have, 8); end;   // pad with zeros past EOS
  end;
  Result := Cardinal(br.Bits and ((UInt64(1) shl n) - 1));
  br.Bits := br.Bits shr n; Dec(br.Have, n);
end;

{ Ensure at least n bits are buffered (zero-padded past EOS), without consuming. }
procedure BR_Fill(var br: TBitReader; n: Integer); inline;
begin
  while br.Have < n do
  begin
    if br.Pos < br.Len then
    begin
      br.Bits := br.Bits or (UInt64(br.Buf[br.Pos]) shl br.Have);
      Inc(br.Pos); Inc(br.Have, 8);
    end
    else begin br.EOS := True; Inc(br.Have, 8); end;
  end;
end;

{ Peek n buffered bits (call BR_Fill first); does not consume. }
function BR_Peek(var br: TBitReader; n: Integer): Cardinal; inline;
begin
  Result := Cardinal(br.Bits and ((UInt64(1) shl n) - 1));
end;

{ Drop n already-buffered bits. }
procedure BR_Consume(var br: TBitReader; n: Integer); inline;
begin
  br.Bits := br.Bits shr n; Dec(br.Have, n);
end;

{ ---- canonical Huffman ------------------------------------------------- }

const
  MAX_ALLOWED_CODE_LENGTH = 15;
  HUFF_ROOT_BITS = 9;                   // root lookup covers codes up to 9 bits
  HUFF_ROOT_SIZE = 1 shl HUFF_ROOT_BITS;

type
  THuffman = record
    // Root fast table (libwebp-style): peek HUFF_ROOT_BITS, one lookup gives the
    // symbol + its length for any code <= HUFF_ROOT_BITS. FastLen=0 → the code is
    // longer than the root; fall back to the canonical bit-walk (rare).
    Counts: array[0..MAX_ALLOWED_CODE_LENGTH] of Integer;
    Symbols: array of Integer;          // symbols sorted by (len, symbol)
    FastLen: array of Byte;             // [HUFF_ROOT_SIZE] code length, 0 = overflow
    FastSym: array of Integer;          // [HUFF_ROOT_SIZE] symbol
    NumSymbols: Integer;
    OneSym: Integer;                    // >=0 → single-symbol code (consumes 0 bits)
  end;

{ Reverse the low n bits of v (stream reads LSB-first, canonical codes are MSB-first). }
function ReverseBits(v: Cardinal; n: Integer): Cardinal; inline;
var i: Integer;
begin
  Result := 0;
  for i := 0 to n - 1 do begin Result := (Result shl 1) or (v and 1); v := v shr 1; end;
end;

{ Build canonical Huffman from per-symbol code lengths. }
function Huff_Build(var h: THuffman; const Lengths: array of Integer; Count: Integer): Boolean;
var i, len, code, sym: Integer; offs: array[0..MAX_ALLOWED_CODE_LENGTH+1] of Integer;
    nonZero, key, step: Integer;
begin
  Result := False;
  for i := 0 to MAX_ALLOWED_CODE_LENGTH do h.Counts[i] := 0;
  nonZero := 0;
  for i := 0 to Count - 1 do
  begin
    if Lengths[i] > MAX_ALLOWED_CODE_LENGTH then Exit;
    Inc(h.Counts[Lengths[i]]);
    if Lengths[i] <> 0 then Inc(nonZero);
  end;
  h.Counts[0] := 0;
  if nonZero = 0 then Exit;
  // check for over-subscription (skip strict check for single-symbol trees)
  // sorted symbols by length then symbol index
  offs[1] := 0;
  for len := 1 to MAX_ALLOWED_CODE_LENGTH do
    offs[len + 1] := offs[len] + h.Counts[len];
  SetLength(h.Symbols, nonZero);
  for i := 0 to Count - 1 do
    if Lengths[i] <> 0 then
    begin
      h.Symbols[offs[Lengths[i]]] := i;
      Inc(offs[Lengths[i]]);
    end;
  h.NumSymbols := nonZero;
  if nonZero = 1 then begin h.OneSym := h.Symbols[0]; Result := True; Exit; end;  // 0-bit path, no table
  h.OneSym := -1;
  // Build the root fast table: assign canonical codes in (len, symbol) order and
  // splat each short code across the table by its bit-reversed key.
  SetLength(h.FastLen, HUFF_ROOT_SIZE);
  SetLength(h.FastSym, HUFF_ROOT_SIZE);
  for i := 0 to HUFF_ROOT_SIZE - 1 do h.FastLen[i] := 0;
  code := 0; sym := 0;
  for len := 1 to MAX_ALLOWED_CODE_LENGTH do
  begin
    for i := 0 to h.Counts[len] - 1 do
    begin
      if len <= HUFF_ROOT_BITS then
      begin
        key := Integer(ReverseBits(Cardinal(code), len));
        step := 1 shl len;
        while key < HUFF_ROOT_SIZE do
        begin
          h.FastLen[key] := len; h.FastSym[key] := h.Symbols[sym];
          key := key + step;
        end;
      end;
      Inc(sym); Inc(code);
    end;
    code := code shl 1;
  end;
  Result := True;
end;

{ Decode one symbol using the canonical length/count walk (LSB-first codes are
  reversed per WebP: read one bit at a time, MSB-building the code). }
function Huff_Decode(var h: THuffman; var br: TBitReader): Integer;
var len, code, first, count, index: Integer; el: Integer;
begin
  if h.OneSym >= 0 then Exit(h.OneSym);   // single-symbol code: 0 bits consumed
  // Root fast path: one peek + one table lookup for codes up to HUFF_ROOT_BITS.
  BR_Fill(br, HUFF_ROOT_BITS);
  index := Integer(BR_Peek(br, HUFF_ROOT_BITS));
  el := h.FastLen[index];
  if el > 0 then begin BR_Consume(br, el); Exit(h.FastSym[index]); end;
  // Overflow: code longer than the root table — canonical bit-walk.
  code := 0; first := 0; index := 0;
  for len := 1 to MAX_ALLOWED_CODE_LENGTH do
  begin
    code := code or Integer(BR_Read(br, 1));
    count := h.Counts[len];
    if code - first < count then
      Exit(h.Symbols[index + (code - first)]);
    index := index + count;
    first := (first + count) shl 1;
    code := code shl 1;
  end;
  Result := -1;
end;

{ code-length alphabet order (WebP spec) }
const
  KCodeLengthCodeOrder: array[0..18] of Integer =
    (17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15);

{ Read one Huffman code (simple or normal) with alphabet size AlphaSize. }
function ReadHuffmanCode(var h: THuffman; var br: TBitReader; AlphaSize: Integer): Boolean;
var numSym, i, len, sym, prev, rep, repVal, maxSym, symCnt: Integer;
    clLens: array[0..18] of Integer; clh: THuffman;
    lengths: array of Integer;
begin
  Result := False;
  if BR_Read(br, 1) = 1 then
  begin
    // simple code: 1 or 2 symbols
    numSym := Integer(BR_Read(br, 1)) + 1;
    SetLength(lengths, AlphaSize);
    for i := 0 to AlphaSize - 1 do lengths[i] := 0;
    if BR_Read(br, 1) = 1 then sym := Integer(BR_Read(br, 8))   // 8-bit symbol
    else sym := Integer(BR_Read(br, 1));                         // 1-bit symbol
    if sym < AlphaSize then lengths[sym] := 1;
    if numSym = 2 then
    begin
      sym := Integer(BR_Read(br, 8));
      if sym < AlphaSize then lengths[sym] := 1;
    end;
    Result := Huff_Build(h, lengths, AlphaSize);
    Exit;
  end;
  // normal code: read code-length code lengths
  for i := 0 to 18 do clLens[i] := 0;
  numSym := Integer(BR_Read(br, 4)) + 4;
  for i := 0 to numSym - 1 do
    clLens[KCodeLengthCodeOrder[i]] := Integer(BR_Read(br, 3));
  if not Huff_Build(clh, clLens, 19) then Exit;
  // read the actual code lengths using clh, with repeat codes 16/17/18
  SetLength(lengths, AlphaSize);
  for i := 0 to AlphaSize - 1 do lengths[i] := 0;
  // optional length limit
  maxSym := AlphaSize;
  if BR_Read(br, 1) = 1 then
  begin
    len := Integer(BR_Read(br, 3));
    maxSym := 2 + Integer(BR_Read(br, len * 2 + 2)) * 1;   // length_nbits handling
    // (per spec: max_symbol = 2 + ReadBits(2 + 2*ReadBits(3)))
  end;
  prev := 8; i := 0; symCnt := 0;
  while (i < AlphaSize) do
  begin
    if symCnt >= maxSym then Break;
    sym := Huff_Decode(clh, br);
    if sym < 0 then Exit;
    Inc(symCnt);
    if sym < 16 then
    begin
      lengths[i] := sym; Inc(i);
      if sym <> 0 then prev := sym;
    end
    else
    begin
      if sym = 16 then begin rep := 3 + Integer(BR_Read(br, 2)); repVal := prev; end
      else if sym = 17 then begin rep := 3 + Integer(BR_Read(br, 3)); repVal := 0; end
      else begin rep := 11 + Integer(BR_Read(br, 7)); repVal := 0; end;
      while (rep > 0) and (i < AlphaSize) do
      begin lengths[i] := repVal; Inc(i); Dec(rep); end;
    end;
  end;
  Result := Huff_Build(h, lengths, AlphaSize);
end;

{ ---- VP8L ------------------------------------------------------------- }

const
  // WebP kCodeToPlane — 120 entries, (yoffset<<4) | (8-xoffset)
  KDistMap: array[0..119] of Integer = (
    $18,$07,$17,$19,$28,$06,$27,$29,$16,$1a,
    $26,$2a,$38,$05,$37,$39,$15,$1b,$36,$3a,
    $25,$2b,$48,$04,$47,$49,$14,$1c,$35,$3b,
    $46,$4a,$24,$2c,$58,$45,$4b,$34,$3c,$03,
    $57,$59,$13,$1d,$56,$5a,$23,$2d,$44,$4c,
    $55,$5b,$33,$3d,$68,$02,$67,$69,$12,$1e,
    $66,$6a,$22,$2e,$54,$5c,$43,$4d,$65,$6b,
    $32,$3e,$78,$01,$77,$79,$53,$5d,$11,$1f,
    $64,$6c,$42,$4e,$76,$7a,$21,$2f,$75,$7b,
    $31,$3f,$63,$6d,$52,$5e,$00,$74,$7c,$41,
    $4f,$10,$20,$62,$6e,$30,$73,$7d,$51,$5f,
    $40,$72,$7e,$61,$6f,$50,$71,$7f,$60,$70);

type
  TArgbBuf = array of Cardinal;   // ARGB, 0xAARRGGBB

  TVP8LDec = record
    br: TBitReader;
    xsize, ysize: Integer;
  end;

{ forward } function DecodeImageStream(var br: TBitReader; xsize, ysize: Integer;
  isLevel0: Boolean; out outW, outH: Integer; out pix: TArgbBuf): Boolean; forward;

function ColorTransformDelta(t: ShortInt; c: ShortInt): Integer; inline;
begin
  Result := (Integer(t) * Integer(c)) shr 5;
end;

{ WebP prefix code → value + extra bits. Used for BOTH length and distance
  symbols (same scheme). A fixed 24-entry base/extra table only covers symbols
  0..23 (fine for lengths, whose alphabet is 24) but distance symbols run to
  ~39 on large images — so decode by the spec formula, not a truncated table. }
function PrefixExtract(sym: Integer; var br: TBitReader): Integer;
var extra, offset: Integer;
begin
  if sym < 4 then Exit(sym + 1);
  extra := (sym - 2) shr 1;
  offset := (2 + (sym and 1)) shl extra;
  Result := offset + Integer(BR_Read(br, extra)) + 1;
end;

{ Distance code → pixel distance using the 2D map. }
function PlaneCodeToDist(planeCode, xsize: Integer): Integer;
var yoff, xoff, code: Integer;
begin
  if planeCode > 120 then Exit(planeCode - 120);
  code := KDistMap[planeCode - 1];
  yoff := code shr 4;
  xoff := 8 - (code and $0F);
  Result := yoff * xsize + xoff;
  if Result < 1 then Result := 1;
end;

{ Read the LZ77-coded, Huffman-coded ARGB pixels for one image stream. }
function DecodePixels(var br: TBitReader; xsize, ysize: Integer;
  cacheBits: Integer; hg: Pointer; hgUsed: Boolean;
  metaW: Integer; metaPix: TArgbBuf; metaBits: Integer;
  var groups: array of THuffman; nGroups: Integer;
  out pix: TArgbBuf): Boolean;
type PHuffGroup = ^THuffman;
var
  numPix, i, x, y, g, sym, red, blue, alpha, len, distSym, dist, planeCode: Integer;
  cache: TArgbBuf; cacheSize, cacheShift, argb: Integer;
  cacheIdx: Integer;
  function GroupIndex(px, py: Integer): Integer;
  var mp: Cardinal;
  begin
    if metaBits = 0 then Exit(0);
    mp := metaPix[(py shr metaBits) * metaW + (px shr metaBits)];
    Result := (mp shr 8) and $FFFF;   // meta stored in the green+red bytes
  end;
  function Grp(idx, chan: Integer): PHuffGroup;
  begin
    Result := @groups[idx * 5 + chan];
  end;
begin
  Result := False;
  numPix := xsize * ysize;
  SetLength(pix, numPix);
  cacheSize := 0; cacheShift := 0;
  if cacheBits > 0 then
  begin
    cacheSize := 1 shl cacheBits; cacheShift := 32 - cacheBits;
    SetLength(cache, cacheSize);
    for i := 0 to cacheSize - 1 do cache[i] := 0;
  end;
  x := 0; y := 0; i := 0;
  while i < numPix do
  begin
    g := GroupIndex(x, y);
    sym := Huff_Decode(Grp(g, 0)^, br);
    if sym < 0 then Exit;
    if sym < 256 then
    begin
      red   := Huff_Decode(Grp(g, 1)^, br);
      blue  := Huff_Decode(Grp(g, 2)^, br);
      alpha := Huff_Decode(Grp(g, 3)^, br);
      if (red < 0) or (blue < 0) or (alpha < 0) then Exit;
      argb := (alpha shl 24) or (red shl 16) or (sym shl 8) or blue;
      pix[i] := Cardinal(argb);
      if cacheBits > 0 then
        cache[(Cardinal($1e35a7bd * Cardinal(argb)) shr cacheShift)] := Cardinal(argb);
      Inc(i); Inc(x); if x >= xsize then begin x := 0; Inc(y); end;
    end
    else if sym < 256 + 24 then
    begin
      // LZ77 length (prefix formula, not the 24-entry table)
      len := PrefixExtract(sym - 256, br);
      distSym := Huff_Decode(Grp(g, 4)^, br);
      if distSym < 0 then Exit;
      planeCode := PrefixExtract(distSym, br);
      dist := PlaneCodeToDist(planeCode, xsize);
      if (dist <= 0) or (i - dist < 0) then Exit;
      while (len > 0) and (i < numPix) do
      begin
        argb := Integer(pix[i - dist]);
        pix[i] := Cardinal(argb);
        if cacheBits > 0 then
          cache[(Cardinal($1e35a7bd * Cardinal(argb)) shr cacheShift)] := Cardinal(argb);
        Inc(i); Inc(x); if x >= xsize then begin x := 0; Inc(y); end;
        Dec(len);
      end;
    end
    else
    begin
      // color cache index
      cacheIdx := sym - (256 + 24);
      if (cacheBits <= 0) or (cacheIdx >= cacheSize) then Exit;
      argb := Integer(cache[cacheIdx]);
      pix[i] := Cardinal(argb);
      Inc(i); Inc(x); if x >= xsize then begin x := 0; Inc(y); end;
    end;
  end;
  Result := True;
end;

{ Build the Huffman groups (5 codes each). Returns groups + count. }
function ReadHuffmanGroups(var br: TBitReader; xsize, ysize: Integer; isLevel0: Boolean;
  cacheBits: Integer; out groups: TArray<THuffman>; out nGroups: Integer;
  out metaW: Integer; out metaPix: TArgbBuf; out metaBits: Integer): Boolean;
var
  i, alphaG, mW, mH, maxGroup: Integer;
begin
  Result := False;
  metaBits := 0; metaW := 0; nGroups := 1;
  if isLevel0 and (BR_Read(br, 1) = 1) then
  begin
    // entropy image: huffman_bits, then a sub-image whose (r<<8|g)? gives group idx
    metaBits := Integer(BR_Read(br, 3)) + 2;
    mW := (xsize + (1 shl metaBits) - 1) shr metaBits;
    mH := (ysize + (1 shl metaBits) - 1) shr metaBits;
    if not DecodeImageStream(br, mW, mH, False, mW, mH, metaPix) then Exit;
    metaW := mW;
    maxGroup := 0;
    for i := 0 to Length(metaPix) - 1 do
      if Integer((metaPix[i] shr 8) and $FFFF) > maxGroup then maxGroup := Integer((metaPix[i] shr 8) and $FFFF);
    nGroups := maxGroup + 1;
  end;
  SetLength(groups, nGroups * 5);
  alphaG := 256 + 24;
  if cacheBits > 0 then alphaG := alphaG + (1 shl cacheBits);
  for i := 0 to nGroups - 1 do
  begin
    if not ReadHuffmanCode(groups[i*5+0], br, alphaG) then Exit;  // green+len+cache
    if not ReadHuffmanCode(groups[i*5+1], br, 256) then Exit;      // red
    if not ReadHuffmanCode(groups[i*5+2], br, 256) then Exit;      // blue
    if not ReadHuffmanCode(groups[i*5+3], br, 256) then Exit;      // alpha
    if not ReadHuffmanCode(groups[i*5+4], br, 40) then Exit;       // distance
  end;
  Result := True;
end;

{ ---- inverse transforms ------------------------------------------------ }

type
  TTransform = record
    Kind: Integer;          // 0 pred, 1 color, 2 subgreen, 3 indexing
    Bits: Integer;          // block size bits (pred/color)
    W, H: Integer;          // transform sub-image size
    Data: TArgbBuf;         // predictor modes / color multipliers / palette
    PalSize: Integer;
  end;

function Clip255(v: Integer): Integer; inline;
begin
  if v < 0 then Result := 0 else if v > 255 then Result := 255 else Result := v;
end;

procedure InvSubtractGreen(var pix: TArgbBuf);
var i, a, r, g, b: Integer;
begin
  for i := 0 to Length(pix) - 1 do
  begin
    a := (pix[i] shr 24) and $FF; g := (pix[i] shr 8) and $FF;
    r := (pix[i] shr 16) and $FF; b := pix[i] and $FF;
    r := (r + g) and $FF; b := (b + g) and $FF;
    pix[i] := Cardinal((a shl 24) or (r shl 16) or (g shl 8) or b);
  end;
end;

procedure InvColor(var t: TTransform; var pix: TArgbBuf; xsize, ysize: Integer);
var x, y, r, g, b, a: Integer; m: Cardinal; gtr, gtb, rtb: ShortInt;
begin
  for y := 0 to ysize - 1 do
    for x := 0 to xsize - 1 do
    begin
      m := t.Data[(y shr t.Bits) * t.W + (x shr t.Bits)];
      gtr := ShortInt((m shr 0) and $FF);      // green_to_red
      gtb := ShortInt((m shr 8) and $FF);      // green_to_blue
      rtb := ShortInt((m shr 16) and $FF);     // red_to_blue
      a := (pix[y*xsize+x] shr 24) and $FF; g := (pix[y*xsize+x] shr 8) and $FF;
      r := (pix[y*xsize+x] shr 16) and $FF; b := pix[y*xsize+x] and $FF;
      r := (r + ColorTransformDelta(gtr, ShortInt(g))) and $FF;
      b := (b + ColorTransformDelta(gtb, ShortInt(g))) and $FF;
      b := (b + ColorTransformDelta(rtb, ShortInt(r))) and $FF;
      pix[y*xsize+x] := Cardinal((a shl 24) or (r shl 16) or (g shl 8) or b);
    end;
end;

{ Expand a color-indexed image: pix is packedW×ysize (index in the green byte,
  possibly several indices packed per byte); output is outW×ysize palette colours. }
procedure InvIndexing(var t: TTransform; var pix: TArgbBuf; packedW, outW, ysize: Integer);
var x, y, bpp, perByte, packed_, idx: Integer; newpix: TArgbBuf;
begin
  if t.PalSize <= 2 then bpp := 1
  else if t.PalSize <= 4 then bpp := 2
  else if t.PalSize <= 16 then bpp := 4
  else bpp := 8;
  perByte := 8 div bpp;
  SetLength(newpix, outW * ysize);
  for y := 0 to ysize - 1 do
    for x := 0 to outW - 1 do
    begin
      if bpp = 8 then idx := (pix[y*packedW + x] shr 8) and $FF
      else
      begin
        packed_ := (pix[y*packedW + (x div perByte)] shr 8) and $FF;
        idx := (packed_ shr ((x mod perByte) * bpp)) and ((1 shl bpp) - 1);
      end;
      if idx >= t.PalSize then idx := t.PalSize - 1;
      newpix[y*outW + x] := t.Data[idx];
    end;
  pix := newpix;
end;

{ predictors 0..13 }
function Predict(mode: Integer; left, top, tl, tr: Cardinal): Cardinal;
  function AddCh(a, b, shift: Integer): Integer; begin Result := ((a shr shift) and $FF) + ((b shr shift) and $FF); end;
  function Avg2(a, b: Cardinal): Cardinal;
  var s: Integer; res: Cardinal;
  begin
    res := 0;
    for s := 0 to 3 do res := res or Cardinal((((Integer(a shr (s*8)) and $FF) + (Integer(b shr (s*8)) and $FF)) div 2) shl (s*8));
    Result := res;
  end;
  function Avg3(a, b, c: Cardinal): Cardinal;
  var s, v: Integer; res: Cardinal;
  begin
    res := 0;
    for s := 0 to 3 do begin v := (((Integer(a shr (s*8)) and $FF) + (Integer(b shr (s*8)) and $FF)) div 2 + (Integer(c shr (s*8)) and $FF)) div 2; res := res or Cardinal(v shl (s*8)); end;
    Result := res;
  end;
  function Clamp(v: Integer): Integer; begin if v<0 then Clamp:=0 else if v>255 then Clamp:=255 else Clamp:=v; end;
  function ClampAddSubFull(a, b, c: Cardinal): Cardinal;
  var s, v: Integer; res: Cardinal;
  begin
    res := 0;
    for s := 0 to 3 do begin v := Clamp((Integer(a shr (s*8)) and $FF) + (Integer(b shr (s*8)) and $FF) - (Integer(c shr (s*8)) and $FF)); res := res or Cardinal(v shl (s*8)); end;
    Result := res;
  end;
  { WebP ClampedAddSubtractHalf: per channel clip(ave + (ave - c)/2), ave=Avg2(a,b). }
  function ClampAddSubHalf(ave, c: Cardinal): Cardinal;
  var s, av, cv, v: Integer; res: Cardinal;
  begin
    res := 0;
    for s := 0 to 3 do
    begin
      av := Integer(ave shr (s*8)) and $FF; cv := Integer(c shr (s*8)) and $FF;
      v := Clamp(av + (av - cv) div 2);
      res := res or Cardinal(v shl (s*8));
    end;
    Result := res;
  end;
  function Select(l, tp, corner: Cardinal): Cardinal;
  var s, pa, pb, gl, gt, gc: Integer;
  begin
    // WebP "select" (Predictor11): pa=Σ|top-corner|, pb=Σ|left-corner|;
    // libwebp returns top when pb<=pa (ties → top), else left.
    pa := 0; pb := 0;
    for s := 0 to 3 do
    begin
      gl := (Integer(l shr (s*8)) and $FF); gt := (Integer(tp shr (s*8)) and $FF); gc := (Integer(corner shr (s*8)) and $FF);
      pa := pa + Abs(gt - gc);
      pb := pb + Abs(gl - gc);
    end;
    if pb <= pa then Result := tp else Result := l;
  end;
begin
  case mode of
    0: Result := $FF000000;
    1: Result := left;
    2: Result := top;
    3: Result := tr;
    4: Result := tl;
    5: Result := Avg3(left, tr, top);
    6: Result := Avg2(left, tl);
    7: Result := Avg2(left, top);
    8: Result := Avg2(tl, top);
    9: Result := Avg2(top, tr);
    10: Result := Avg2(Avg2(left, tl), Avg2(top, tr));
    11: Result := Select(left, top, tl);
    12: Result := ClampAddSubFull(left, top, tl);
    13: Result := ClampAddSubHalf(Avg2(left, top), tl);
  else Result := $FF000000;
  end;
end;

procedure InvPredictor(var t: TTransform; var pix: TArgbBuf; xsize, ysize: Integer);
var x, y, mode: Integer; pred, left, top, tl, tr: Cardinal;
  function Add(a, b: Cardinal): Cardinal;
  var s: Integer; res: Cardinal;
  begin res := 0; for s := 0 to 3 do res := res or Cardinal((((Integer(a shr (s*8)) and $FF)+(Integer(b shr (s*8)) and $FF)) and $FF) shl (s*8)); Result := res; end;
begin
  for y := 0 to ysize - 1 do
    for x := 0 to xsize - 1 do
    begin
      if (x = 0) and (y = 0) then pred := $FF000000
      else if y = 0 then pred := pix[y*xsize + x - 1]              // top row → left (mode 1)
      else if x = 0 then pred := pix[(y-1)*xsize + x]              // left col → top (mode 2)
      else
      begin
        mode := Integer((t.Data[(y shr t.Bits) * t.W + (x shr t.Bits)] shr 8) and $0F);
        left := pix[y*xsize + x - 1];
        top := pix[(y-1)*xsize + x];
        tl := pix[(y-1)*xsize + x - 1];
        if x + 1 < xsize then tr := pix[(y-1)*xsize + x + 1] else tr := pix[(y-1)*xsize + x];
        pred := Predict(mode, left, top, tl, tr);
      end;
      pix[y*xsize + x] := Add(pix[y*xsize + x], pred);
    end;
end;

{ ---- image stream ------------------------------------------------------ }

function DecodeImageStream(var br: TBitReader; xsize, ysize: Integer;
  isLevel0: Boolean; out outW, outH: Integer; out pix: TArgbBuf): Boolean;
var
  transforms: array of TTransform;
  nT, tType, cacheBits, i: Integer;
  groups: TArray<THuffman>; nGroups, metaW, metaBits: Integer; metaPix: TArgbBuf;
  curW: Integer;
  procedure ReadTransform;
  var t: TTransform; j, palSize: Integer; palPix: TArgbBuf; pw, ph: Integer;
  begin
    t.Kind := tType;
    if (tType = 0) or (tType = 1) then
    begin
      t.Bits := Integer(BR_Read(br, 3)) + 2;
      t.W := (curW + (1 shl t.Bits) - 1) shr t.Bits;
      t.H := (ysize + (1 shl t.Bits) - 1) shr t.Bits;
      DecodeImageStream(br, t.W, t.H, False, pw, ph, t.Data);
    end
    else if tType = 3 then
    begin
      palSize := Integer(BR_Read(br, 8)) + 1;
      t.PalSize := palSize;
      DecodeImageStream(br, palSize, 1, False, pw, ph, palPix);
      // palette is delta-coded along x
      for j := 1 to palSize - 1 do
        palPix[j] := Cardinal(
          ((((palPix[j] shr 24) and $FF) + ((palPix[j-1] shr 24) and $FF)) and $FF) shl 24 or
          ((((palPix[j] shr 16) and $FF) + ((palPix[j-1] shr 16) and $FF)) and $FF) shl 16 or
          ((((palPix[j] shr 8) and $FF) + ((palPix[j-1] shr 8) and $FF)) and $FF) shl 8 or
          (((palPix[j] and $FF) + (palPix[j-1] and $FF)) and $FF));
      t.Data := palPix;
      // color-indexing packs pixels horizontally when palette is small
      if palSize <= 2 then curW := (curW + 7) shr 3
      else if palSize <= 4 then curW := (curW + 3) shr 2
      else if palSize <= 16 then curW := (curW + 1) shr 1;
    end;
    // tType 2 (subtract green): no data
    SetLength(transforms, nT + 1); transforms[nT] := t; Inc(nT);
  end;
begin
  Result := False;
  nT := 0; curW := xsize;
  if isLevel0 then
    while BR_Read(br, 1) = 1 do
    begin
      tType := Integer(BR_Read(br, 2));
      ReadTransform;
    end;
  // color cache
  cacheBits := 0;
  if BR_Read(br, 1) = 1 then cacheBits := Integer(BR_Read(br, 4));
  // huffman groups
  if not ReadHuffmanGroups(br, curW, ysize, isLevel0, cacheBits, groups, nGroups, metaW, metaPix, metaBits) then Exit;
  // pixels
  if not DecodePixels(br, curW, ysize, cacheBits, nil, False, metaW, metaPix, metaBits, groups, nGroups, pix) then Exit;
  // inverse transforms (reverse order); indexing expands the packed width back to
  // the original xsize.
  for i := nT - 1 downto 0 do
  begin
    case transforms[i].Kind of
      0: InvPredictor(transforms[i], pix, curW, ysize);
      1: InvColor(transforms[i], pix, curW, ysize);
      2: InvSubtractGreen(pix);
      3: begin InvIndexing(transforms[i], pix, curW, xsize, ysize); curW := xsize; end;
    end;
  end;
  outW := curW; outH := ysize;
  Result := True;
end;

{ ---- container --------------------------------------------------------- }

function Rd32(p: PByte): Cardinal; inline;
begin Result := p[0] or (p[1] shl 8) or (p[2] shl 16) or (Cardinal(p[3]) shl 24); end;

{ Gradient predictor for the alpha spatial filter (clamped a+b-c). }
function AlphaGrad(a, b, c: Integer): Integer; inline;
var g: Integer;
begin
  g := a + b - c;
  if g < 0 then Result := 0 else if g > 255 then Result := 255 else Result := g;
end;

{ Reverse the WebP alpha spatial filter (1=horizontal, 2=vertical, 3=gradient)
  in place over a W*H byte plane, row by row (prev row = already-reconstructed). }
procedure AlphaUnfilter(var a: TBytes; W, H, filter: Integer);
var x, y, o, up, pred: Integer;
begin
  if filter = 0 then Exit;
  for y := 0 to H - 1 do
  begin
    o := y * W;
    if y = 0 then
    begin
      // top row: always horizontal (left) prediction, first pixel from 0
      for x := 1 to W - 1 do a[o + x] := Byte(a[o + x] + a[o + x - 1]);
    end
    else case filter of
      1: begin  // horizontal: first pixel predicts from the pixel above, rest from left
           a[o] := Byte(a[o] + a[o - W]);
           for x := 1 to W - 1 do a[o + x] := Byte(a[o + x] + a[o + x - 1]);
         end;
      2: for x := 0 to W - 1 do a[o + x] := Byte(a[o + x] + a[o + x - W]);  // vertical: from above
      3: begin  // gradient: clamp(left + above - above-left)
           a[o] := Byte(a[o] + a[o - W]);   // first pixel: from above
           for x := 1 to W - 1 do
           begin
             up := a[o + x - W];
             pred := AlphaGrad(a[o + x - 1], up, a[o + x - 1 - W]);
             a[o + x] := Byte(a[o + x] + pred);
           end;
         end;
    end;
  end;
end;

{ Decode a WebP 'ALPH' chunk (Data/Size = chunk payload) into the A bytes of an
  already-RGB-filled RGBA buffer. method 0 = raw plane, 1 = VP8L-lossless (alpha
  carried in the green channel); then the spatial filter is reversed. }
function DecodeAlpha(Data: PByte; Size, W, H: Integer; var RGBA: TBytes): Boolean;
var
  method, filter, i, n, oW, oH: Integer;
  aBr: TBitReader; aPix: TArgbBuf; plane: TBytes;
begin
  Result := False;
  if (Size < 1) or (W <= 0) or (H <= 0) then Exit;
  n := W * H;
  method := Data[0] and $03;
  filter := (Data[0] shr 2) and $03;
  // (bits 4-5 pre-processing, 6-7 reserved: no decode-time effect for the common case)
  SetLength(plane, n);
  if method = 0 then
  begin
    if Size - 1 < n then Exit;
    Move((Data + 1)^, plane[0], n);
  end
  else
  begin
    // lossless: a headerless VP8L stream whose GREEN channel holds alpha
    BR_Init(aBr, Data + 1, Size - 1);
    if not DecodeImageStream(aBr, W, H, True, oW, oH, aPix) then Exit;
    if Length(aPix) < n then Exit;
    for i := 0 to n - 1 do plane[i] := (aPix[i] shr 8) and $FF;
  end;
  AlphaUnfilter(plane, W, H, filter);
  if Length(RGBA) < n * 4 then Exit;
  for i := 0 to n - 1 do RGBA[i*4+3] := plane[i];
  Result := True;
end;

function Tina4DecodeWebP(Data: PByte; Size: Integer; out RGBA: TBytes;
  out W, H: Integer): Boolean;
var
  p: PByte; fourcc: string; clen: Cardinal;
  br: TBitReader; pix: TArgbBuf; oW, oH, i: Integer;
  alphData: PByte; alphLen: Integer;
begin
  Result := False; W := 0; H := 0;
  alphData := nil; alphLen := 0;
  if (Data = nil) or (Size < 20) then Exit;
  if not ((Data[0] = Ord('R')) and (Data[1] = Ord('I')) and (Data[2] = Ord('F')) and (Data[3] = Ord('F'))) then Exit;
  if not ((Data[8] = Ord('W')) and (Data[9] = Ord('E')) and (Data[10] = Ord('B')) and (Data[11] = Ord('P'))) then Exit;
  p := Data + 12;
  while (p + 8) <= (Data + Size) do
  begin
    SetString(fourcc, PAnsiChar(p), 4);
    clen := Rd32(p + 4);
    if fourcc = 'VP8L' then
    begin
      if p[8] <> $2F then Exit;                 // VP8L signature
      BR_Init(br, p + 9, clen - 1);
      W := Integer(BR_Read(br, 14)) + 1;
      H := Integer(BR_Read(br, 14)) + 1;
      BR_Read(br, 1);                            // alpha_is_used flag (consumed, unused)
      BR_Read(br, 3);                            // version
      if not DecodeImageStream(br, W, H, True, oW, oH, pix) then Exit;
      SetLength(RGBA, W * H * 4);
      for i := 0 to W * H - 1 do
      begin
        RGBA[i*4+0] := (pix[i] shr 16) and $FF;   // R
        RGBA[i*4+1] := (pix[i] shr 8) and $FF;    // G
        RGBA[i*4+2] := pix[i] and $FF;            // B
        RGBA[i*4+3] := (pix[i] shr 24) and $FF;   // A
      end;
      Exit(True);
    end
    else if fourcc = 'ALPH' then
    begin
      // stash the alpha chunk; it precedes the 'VP8 ' image it applies to
      alphData := p + 8; alphLen := Integer(clen);
    end
    else if fourcc = 'VP8 ' then
    begin
      // lossy VP8 — decoded by Tina4WebPVP8 (pure-Pascal intra decoder).
      Result := Tina4DecodeVP8(p + 8, clen, RGBA, W, H);
      // apply a preceding ALPH chunk (transparent lossy WebP)
      if Result and (alphData <> nil) then
        DecodeAlpha(alphData, alphLen, W, H, RGBA);
      Exit;
    end;
    // skip chunk (padded to even)
    p := p + 8 + clen + (clen and 1);
  end;
end;

end.
