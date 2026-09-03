unit Tina4QR;

{ Pure-Pascal QR Code encoder (byte mode, ECC level L, versions 1..10).
  Zero OS dependencies — belongs in the core layer. Produces a boolean
  module matrix that the layout engine paints with plain FillRects.

  Covers up to 274 bytes of UTF-8, which comfortably fits URLs, tokens and
  short text. Reference: ISO/IEC 18004. }

{$mode delphi}{$H+}

interface

type
  { [Row, Col] = True means a dark module. Size = 17 + 4*Version. }
  TQRMatrix = record
    Size: Integer;
    Modules: array of array of Boolean;
  end;

{ Encodes Data (raw bytes, typically UTF-8) as a QR matrix. Returns False if
  the data is longer than a version-10 level-L symbol can hold (274 bytes). }
function QREncode(const Data: string; out Matrix: TQRMatrix): Boolean;

{ Reed-Solomon self-test hook: EC codewords for the given data bytes, as a
  space-separated decimal string. Used by the unit test to pin RS behaviour. }
function QRTestEC(const Data: array of Byte; ECCount: Integer): string;

implementation

uses SysUtils;

type
  TByteArray = array of Byte;
  TIntArray = array of Integer;

{ ---- version parameters, ECC level L ---------------------------------- }
type
  TVerInfo = record
    ECPerBlock: Integer;
    Grp1Blocks, Grp1Data: Integer;
    Grp2Blocks, Grp2Data: Integer;
    TotalData: Integer;
  end;

const
  { index 1..10; index 0 unused }
  VER: array[0..10] of TVerInfo = (
    (ECPerBlock: 0;  Grp1Blocks: 0; Grp1Data: 0;   Grp2Blocks: 0; Grp2Data: 0;  TotalData: 0),
    (ECPerBlock: 7;  Grp1Blocks: 1; Grp1Data: 19;  Grp2Blocks: 0; Grp2Data: 0;  TotalData: 19),
    (ECPerBlock: 10; Grp1Blocks: 1; Grp1Data: 34;  Grp2Blocks: 0; Grp2Data: 0;  TotalData: 34),
    (ECPerBlock: 15; Grp1Blocks: 1; Grp1Data: 55;  Grp2Blocks: 0; Grp2Data: 0;  TotalData: 55),
    (ECPerBlock: 20; Grp1Blocks: 1; Grp1Data: 80;  Grp2Blocks: 0; Grp2Data: 0;  TotalData: 80),
    (ECPerBlock: 26; Grp1Blocks: 1; Grp1Data: 108; Grp2Blocks: 0; Grp2Data: 0;  TotalData: 108),
    (ECPerBlock: 18; Grp1Blocks: 2; Grp1Data: 68;  Grp2Blocks: 0; Grp2Data: 0;  TotalData: 136),
    (ECPerBlock: 20; Grp1Blocks: 2; Grp1Data: 78;  Grp2Blocks: 0; Grp2Data: 0;  TotalData: 156),
    (ECPerBlock: 24; Grp1Blocks: 2; Grp1Data: 97;  Grp2Blocks: 0; Grp2Data: 0;  TotalData: 194),
    (ECPerBlock: 30; Grp1Blocks: 2; Grp1Data: 116; Grp2Blocks: 0; Grp2Data: 0;  TotalData: 232),
    (ECPerBlock: 18; Grp1Blocks: 2; Grp1Data: 68;  Grp2Blocks: 2; Grp2Data: 69; TotalData: 274)
  );

{ alignment-pattern centre coordinates per version (besides version 1) }
function AlignCoords(Version: Integer): TIntArray;
begin
  case Version of
    2:  Result := TIntArray.Create(6, 18);
    3:  Result := TIntArray.Create(6, 22);
    4:  Result := TIntArray.Create(6, 26);
    5:  Result := TIntArray.Create(6, 30);
    6:  Result := TIntArray.Create(6, 34);
    7:  Result := TIntArray.Create(6, 22, 38);
    8:  Result := TIntArray.Create(6, 24, 42);
    9:  Result := TIntArray.Create(6, 26, 46);
    10: Result := TIntArray.Create(6, 28, 50);
  else
    Result := nil;
  end;
end;

{ ---- GF(256) arithmetic (primitive poly 0x11D) ------------------------ }
var
  GFExp: array[0..511] of Integer;
  GFLog: array[0..255] of Integer;
  GFReady: Boolean = False;

procedure InitGF;
var
  i, x: Integer;
begin
  if GFReady then Exit;
  x := 1;
  for i := 0 to 254 do
  begin
    GFExp[i] := x;
    GFLog[x] := i;
    x := x shl 1;
    if x >= 256 then x := x xor $11D;
  end;
  for i := 255 to 511 do GFExp[i] := GFExp[i - 255];
  GFReady := True;
end;

function GFMul(a, b: Integer): Integer;
begin
  if (a = 0) or (b = 0) then Result := 0
  else Result := GFExp[GFLog[a] + GFLog[b]];
end;

{ Reed-Solomon generator polynomial of the given degree }
function RSGenPoly(Degree: Integer): TByteArray;
var
  i, j: Integer;
  root: Integer;
  nextv: TByteArray;
begin
  SetLength(Result, 1);
  Result[0] := 1;
  root := 1;
  for i := 0 to Degree - 1 do
  begin
    SetLength(nextv, Length(Result) + 1);
    for j := 0 to High(nextv) do nextv[j] := 0;
    for j := 0 to High(Result) do
    begin
      nextv[j] := nextv[j] xor Result[j];
      nextv[j + 1] := nextv[j + 1] xor GFMul(Result[j], root);
    end;
    Result := Copy(nextv);
    root := GFMul(root, 2);
  end;
end;

{ EC codewords for one data block }
function RSEncodeBlock(const Data: TByteArray; ECCount: Integer): TByteArray;
var
  gen: TByteArray;
  i, j, factor: Integer;
  buf: TByteArray;
begin
  gen := RSGenPoly(ECCount);
  SetLength(buf, Length(Data) + ECCount);
  for i := 0 to High(Data) do buf[i] := Data[i];
  for i := Length(Data) to High(buf) do buf[i] := 0;
  for i := 0 to High(Data) do
  begin
    factor := buf[i];
    if factor <> 0 then
      for j := 0 to High(gen) do
        buf[i + j] := buf[i + j] xor GFMul(gen[j], factor);
  end;
  SetLength(Result, ECCount);
  for i := 0 to ECCount - 1 do Result[i] := buf[Length(Data) + i];
end;

{ ---- bit buffer -------------------------------------------------------- }
type
  TBitBuf = record
    Bytes: TByteArray;
    BitLen: Integer;
  end;

procedure BitPush(var B: TBitBuf; Value, Bits: Integer);
var
  i, bit, bytePos, bitPos: Integer;
begin
  for i := Bits - 1 downto 0 do
  begin
    bit := (Value shr i) and 1;
    bytePos := B.BitLen shr 3;
    bitPos := 7 - (B.BitLen and 7);
    if bytePos > High(B.Bytes) then SetLength(B.Bytes, bytePos + 1);
    if bit = 1 then B.Bytes[bytePos] := B.Bytes[bytePos] or (1 shl bitPos);
    Inc(B.BitLen);
  end;
end;

{ ---- matrix helpers ---------------------------------------------------- }
type
  TFnMask = array of array of Boolean;   // True = function module (reserved)

procedure SetModule(var M: TQRMatrix; var Fn: TFnMask; r, c: Integer;
  dark, isFunction: Boolean);
begin
  M.Modules[r][c] := dark;
  if isFunction then Fn[r][c] := True;
end;

procedure PlaceFinder(var M: TQRMatrix; var Fn: TFnMask; r, c: Integer);
var
  dr, dc, rr, cc: Integer;
  dark: Boolean;
begin
  for dr := -1 to 7 do
    for dc := -1 to 7 do
    begin
      rr := r + dr; cc := c + dc;
      if (rr < 0) or (rr >= M.Size) or (cc < 0) or (cc >= M.Size) then Continue;
      dark := (dr >= 0) and (dr <= 6) and (dc >= 0) and (dc <= 6) and
        ((dr = 0) or (dr = 6) or (dc = 0) or (dc = 6) or
         ((dr >= 2) and (dr <= 4) and (dc >= 2) and (dc <= 4)));
      SetModule(M, Fn, rr, cc, dark, True);
    end;
end;

procedure PlaceAlignment(var M: TQRMatrix; var Fn: TFnMask; r, c: Integer);
var
  dr, dc: Integer;
  dark: Boolean;
begin
  for dr := -2 to 2 do
    for dc := -2 to 2 do
    begin
      dark := (Abs(dr) = 2) or (Abs(dc) = 2) or ((dr = 0) and (dc = 0));
      SetModule(M, Fn, r + dr, c + dc, dark, True);
    end;
end;

{ 15-bit BCH format information for ECC level L (bits 01) + mask }
function FormatBits(Mask: Integer): Integer;
const
  G = $537;      // generator 0b10100110111
  XORMASK = $5412;
var
  data, rem, i: Integer;
begin
  data := ($01 shl 3) or Mask;    // level L = 01
  rem := data shl 10;
  for i := 14 downto 10 do
    if ((rem shr i) and 1) = 1 then rem := rem xor (G shl (i - 10));
  Result := ((data shl 10) or rem) xor XORMASK;
end;

{ 18-bit BCH version information (versions >= 7) }
function VersionBits(Version: Integer): Integer;
const
  G = $1F25;
var
  rem, i: Integer;
begin
  rem := Version shl 12;
  for i := 17 downto 12 do
    if ((rem shr i) and 1) = 1 then rem := rem xor (G shl (i - 12));
  Result := (Version shl 12) or rem;
end;

procedure PlaceFormat(var M: TQRMatrix; var Fn: TFnMask; Mask: Integer);
var
  fmt, i, bit: Integer;
begin
  fmt := FormatBits(Mask);
  { top-left, split around the finder }
  for i := 0 to 14 do
  begin
    bit := (fmt shr i) and 1;
    if i < 6 then SetModule(M, Fn, 8, i, bit = 1, True)
    else if i = 6 then SetModule(M, Fn, 8, 7, bit = 1, True)
    else if i = 7 then SetModule(M, Fn, 8, 8, bit = 1, True)
    else if i = 8 then SetModule(M, Fn, 7, 8, bit = 1, True)
    else SetModule(M, Fn, 14 - i, 8, bit = 1, True);
  end;
  { the mirrored copy: bits 0..7 run right-to-left along row 8 (top-right
    finder), bits 8..14 run top-to-bottom down column 8 (bottom-left). }
  for i := 0 to 14 do
  begin
    bit := (fmt shr i) and 1;
    if i < 8 then SetModule(M, Fn, 8, M.Size - 1 - i, bit = 1, True)
    else SetModule(M, Fn, M.Size - 15 + i, 8, bit = 1, True);
  end;
  { the always-dark module }
  SetModule(M, Fn, M.Size - 8, 8, True, True);
end;

procedure PlaceVersion(var M: TQRMatrix; var Fn: TFnMask; Version: Integer);
var
  vb, i, bit, r, c: Integer;
begin
  if Version < 7 then Exit;
  vb := VersionBits(Version);
  for i := 0 to 17 do
  begin
    bit := (vb shr i) and 1;
    r := i div 3;
    c := i mod 3;
    SetModule(M, Fn, r, M.Size - 11 + c, bit = 1, True);
    SetModule(M, Fn, M.Size - 11 + c, r, bit = 1, True);
  end;
end;

function MaskBit(Mask, r, c: Integer): Boolean;
begin
  case Mask of
    0: Result := ((r + c) mod 2) = 0;
    1: Result := (r mod 2) = 0;
    2: Result := (c mod 3) = 0;
    3: Result := ((r + c) mod 3) = 0;
    4: Result := (((r div 2) + (c div 3)) mod 2) = 0;
    5: Result := (((r * c) mod 2) + ((r * c) mod 3)) = 0;
    6: Result := ((((r * c) mod 2) + ((r * c) mod 3)) mod 2) = 0;
    7: Result := ((((r + c) mod 2) + ((r * c) mod 3)) mod 2) = 0;
  else
    Result := False;
  end;
end;

{ penalty score of a fully masked matrix, for mask selection }
function Penalty(const M: TQRMatrix): Integer;
var
  r, c, run, i: Integer;
  cur, prev: Boolean;
  dark: Integer;
  total: Integer;
  ratio: Integer;
begin
  total := 0;
  { rule 1: runs of 5+ same-colour in rows and columns }
  for r := 0 to M.Size - 1 do
  begin
    run := 1; prev := M.Modules[r][0];
    for c := 1 to M.Size - 1 do
    begin
      cur := M.Modules[r][c];
      if cur = prev then Inc(run)
      else begin
        if run >= 5 then Inc(total, run - 2);
        run := 1; prev := cur;
      end;
    end;
    if run >= 5 then Inc(total, run - 2);
  end;
  for c := 0 to M.Size - 1 do
  begin
    run := 1; prev := M.Modules[0][c];
    for r := 1 to M.Size - 1 do
    begin
      cur := M.Modules[r][c];
      if cur = prev then Inc(run)
      else begin
        if run >= 5 then Inc(total, run - 2);
        run := 1; prev := cur;
      end;
    end;
    if run >= 5 then Inc(total, run - 2);
  end;
  { rule 2: 2x2 blocks of one colour }
  for r := 0 to M.Size - 2 do
    for c := 0 to M.Size - 2 do
      if (M.Modules[r][c] = M.Modules[r][c + 1]) and
         (M.Modules[r][c] = M.Modules[r + 1][c]) and
         (M.Modules[r][c] = M.Modules[r + 1][c + 1]) then Inc(total, 3);
  { rule 3: finder-like 1:1:3:1:1 patterns in rows and columns }
  for r := 0 to M.Size - 1 do
    for c := 0 to M.Size - 11 do
    begin
      if M.Modules[r][c] and (not M.Modules[r][c+1]) and M.Modules[r][c+2] and
         M.Modules[r][c+3] and M.Modules[r][c+4] and (not M.Modules[r][c+5]) and
         M.Modules[r][c+6] then
      begin
        if (c + 10 <= M.Size - 1) and (not M.Modules[r][c+7]) and (not M.Modules[r][c+8]) and
           (not M.Modules[r][c+9]) and (not M.Modules[r][c+10]) then Inc(total, 40);
        if (c - 4 >= 0) and (not M.Modules[r][c-1]) and (not M.Modules[r][c-2]) and
           (not M.Modules[r][c-3]) and (not M.Modules[r][c-4]) then Inc(total, 40);
      end;
    end;
  for c := 0 to M.Size - 1 do
    for r := 0 to M.Size - 11 do
    begin
      if M.Modules[r][c] and (not M.Modules[r+1][c]) and M.Modules[r+2][c] and
         M.Modules[r+3][c] and M.Modules[r+4][c] and (not M.Modules[r+5][c]) and
         M.Modules[r+6][c] then
      begin
        if (r + 10 <= M.Size - 1) and (not M.Modules[r+7][c]) and (not M.Modules[r+8][c]) and
           (not M.Modules[r+9][c]) and (not M.Modules[r+10][c]) then Inc(total, 40);
        if (r - 4 >= 0) and (not M.Modules[r-1][c]) and (not M.Modules[r-2][c]) and
           (not M.Modules[r-3][c]) and (not M.Modules[r-4][c]) then Inc(total, 40);
      end;
    end;
  { rule 4: overall dark/light balance }
  dark := 0;
  for r := 0 to M.Size - 1 do
    for c := 0 to M.Size - 1 do
      if M.Modules[r][c] then Inc(dark);
  ratio := (dark * 100) div (M.Size * M.Size);
  i := Abs(ratio - 50);
  Inc(total, (i div 5) * 10);
  Result := total;
end;

function QRTestEC(const Data: array of Byte; ECCount: Integer): string;
var d, ec: TByteArray; i: Integer;
begin
  InitGF;
  SetLength(d, Length(Data));
  for i := 0 to High(Data) do d[i] := Data[i];
  ec := RSEncodeBlock(d, ECCount);
  Result := '';
  for i := 0 to High(ec) do
  begin
    if i > 0 then Result := Result + ' ';
    Result := Result + IntToStr(ec[i]);
  end;
end;



{ ---- top-level encode ------------------------------------------------- }
function QREncode(const Data: string; out Matrix: TQRMatrix): Boolean;
var
  version, size, i, j, k, r, c: Integer;
  ccBits, capBits, needBits: Integer;
  bits: TBitBuf;
  padByte, dataLen: Integer;
  dataCW: TByteArray;
  blocks: array of TByteArray;
  ecBlocks: array of TByteArray;
  nBlocks, bi, maxData, maxEC: Integer;
  final: TByteArray;
  fnMask: TFnMask;
  coords: TIntArray;
  ax, ay: Integer;
  skipFinder: Boolean;
  col, dir, bitIdx, byteIdx, bit: Integer;
  candidate, best: TQRMatrix;
  bestScore, score, mask: Integer;
  vInfo: TVerInfo;
  off: Integer;
begin
  Result := False;
  InitGF;
  dataLen := Length(Data);

  { pick smallest version that holds the byte-mode payload }
  version := 0;
  for i := 1 to 10 do
  begin
    if i >= 10 then ccBits := 16 else ccBits := 8;
    capBits := VER[i].TotalData * 8;
    needBits := 4 + ccBits + dataLen * 8;
    if needBits <= capBits then begin version := i; Break; end;
  end;
  if version = 0 then Exit;   // too long for v10-L

  vInfo := VER[version];
  size := 17 + 4 * version;

  { ---- build the bitstream ---- }
  SetLength(bits.Bytes, 0);
  bits.BitLen := 0;
  BitPush(bits, $4, 4);                                  // byte mode
  if version >= 10 then BitPush(bits, dataLen, 16)
  else BitPush(bits, dataLen, 8);
  for i := 1 to dataLen do BitPush(bits, Ord(Data[i]), 8);
  { terminator (up to 4 zero bits) }
  capBits := vInfo.TotalData * 8;
  k := capBits - bits.BitLen;
  if k > 4 then k := 4;
  if k > 0 then BitPush(bits, 0, k);
  { pad to a byte boundary }
  while (bits.BitLen and 7) <> 0 do BitPush(bits, 0, 1);
  { pad bytes 0xEC / 0x11 to fill the capacity }
  padByte := $EC;
  while (bits.BitLen div 8) < vInfo.TotalData do
  begin
    BitPush(bits, padByte, 8);
    if padByte = $EC then padByte := $11 else padByte := $EC;
  end;
  SetLength(dataCW, vInfo.TotalData);
  for i := 0 to vInfo.TotalData - 1 do dataCW[i] := bits.Bytes[i];

  { ---- split into blocks, compute EC per block ---- }
  nBlocks := vInfo.Grp1Blocks + vInfo.Grp2Blocks;
  SetLength(blocks, nBlocks);
  SetLength(ecBlocks, nBlocks);
  off := 0;
  for bi := 0 to nBlocks - 1 do
  begin
    if bi < vInfo.Grp1Blocks then dataLen := vInfo.Grp1Data
    else dataLen := vInfo.Grp2Data;
    SetLength(blocks[bi], dataLen);
    for i := 0 to dataLen - 1 do blocks[bi][i] := dataCW[off + i];
    Inc(off, dataLen);
    ecBlocks[bi] := RSEncodeBlock(blocks[bi], vInfo.ECPerBlock);
  end;

  { ---- interleave data then EC codewords ---- }
  maxData := vInfo.Grp1Data;
  if vInfo.Grp2Data > maxData then maxData := vInfo.Grp2Data;
  maxEC := vInfo.ECPerBlock;
  SetLength(final, 0);
  k := 0;
  for i := 0 to maxData - 1 do
    for bi := 0 to nBlocks - 1 do
      if i <= High(blocks[bi]) then
      begin
        SetLength(final, k + 1); final[k] := blocks[bi][i]; Inc(k);
      end;
  for i := 0 to maxEC - 1 do
    for bi := 0 to nBlocks - 1 do
      if i <= High(ecBlocks[bi]) then
      begin
        SetLength(final, k + 1); final[k] := ecBlocks[bi][i]; Inc(k);
      end;

  { ---- assemble the base matrix (function patterns) ---- }
  candidate.Size := size;
  SetLength(candidate.Modules, size, size);
  SetLength(fnMask, size, size);
  for r := 0 to size - 1 do
    for c := 0 to size - 1 do
    begin
      candidate.Modules[r][c] := False;
      fnMask[r][c] := False;
    end;

  PlaceFinder(candidate, fnMask, 0, 0);
  PlaceFinder(candidate, fnMask, 0, size - 7);
  PlaceFinder(candidate, fnMask, size - 7, 0);

  { timing patterns }
  for i := 8 to size - 9 do
  begin
    SetModule(candidate, fnMask, 6, i, (i mod 2) = 0, True);
    SetModule(candidate, fnMask, i, 6, (i mod 2) = 0, True);
  end;

  { alignment patterns }
  coords := AlignCoords(version);
  if coords <> nil then
    for i := 0 to High(coords) do
      for j := 0 to High(coords) do
      begin
        ay := coords[i]; ax := coords[j];
        skipFinder :=
          ((ay <= 8) and (ax <= 8)) or
          ((ay <= 8) and (ax >= size - 9)) or
          ((ay >= size - 9) and (ax <= 8));
        if not skipFinder then PlaceAlignment(candidate, fnMask, ay, ax);
      end;

  PlaceVersion(candidate, fnMask, version);
  { reserve the format-info modules (values set per mask below) }
  PlaceFormat(candidate, fnMask, 0);

  { ---- place data bits in the zig-zag, skipping function modules ---- }
  bitIdx := 0;
  col := size - 1;
  dir := -1;   // upward first
  while col > 0 do
  begin
    if col = 6 then Dec(col);   // skip the vertical timing column
    r := 0;
    while (r >= 0) and (r < size) do
    begin
      if dir = -1 then k := size - 1 - r else k := r;
      for j := 0 to 1 do
      begin
        c := col - j;
        if not fnMask[k][c] then
        begin
          bit := 0;
          if (bitIdx shr 3) <= High(final) then
          begin
            byteIdx := bitIdx shr 3;
            bit := (final[byteIdx] shr (7 - (bitIdx and 7))) and 1;
          end;
          candidate.Modules[k][c] := (bit = 1);
          Inc(bitIdx);
        end;
      end;
      Inc(r);
    end;
    dir := -dir;
    Dec(col, 2);
  end;

  { ---- try all 8 masks, keep the lowest-penalty one ---- }
  bestScore := MaxInt;
  best.Size := size;
  SetLength(best.Modules, size, size);
  for mask := 0 to 7 do
  begin
    { copy candidate, apply mask to non-function modules }
    for r := 0 to size - 1 do
      for c := 0 to size - 1 do
      begin
        if fnMask[r][c] then
          best.Modules[r][c] := candidate.Modules[r][c]
        else
          best.Modules[r][c] := candidate.Modules[r][c] xor MaskBit(mask, r, c);
      end;
    PlaceFormat(best, fnMask, mask);
    score := Penalty(best);
    if score < bestScore then
    begin
      bestScore := score;
      Matrix.Size := size;
      SetLength(Matrix.Modules, size, size);
      for r := 0 to size - 1 do
        for c := 0 to size - 1 do
          Matrix.Modules[r][c] := best.Modules[r][c];
    end;
  end;

  Result := True;
end;

end.
