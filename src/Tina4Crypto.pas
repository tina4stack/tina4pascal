unit Tina4Crypto;

{ Minimal self-contained crypto for the auth layer: SHA-256, base64url, and PKCE
  (RFC 7636) helpers. Pure Pascal — no OS or external library — so it builds on
  every target and is deterministically testable against the published NIST /
  RFC vectors. Portable-core-safe (zero OS deps). }

{$mode delphi}{$H+}

interface

type
  TSHA256Digest = array[0..31] of Byte;

function SHA256Bytes(const Data: RawByteString): TSHA256Digest;
function SHA256Hex(const Data: RawByteString): string;

{ URL-safe base64 (RFC 4648 §5): '+'→'-', '/'→'_', no '=' padding. }
function Base64UrlEncode(const Data: RawByteString): string;
function Base64UrlDecode(const S: string): RawByteString;

{ A high-entropy PKCE code_verifier (43 chars, unreserved set). }
function PKCEVerifier: string;
{ code_challenge = base64url(SHA-256(code_verifier)) — the S256 method. }
function PKCEChallengeS256(const Verifier: string): string;

implementation

uses SysUtils, base64;

const
  K: array[0..63] of LongWord = (
    $428a2f98,$71374491,$b5c0fbcf,$e9b5dba5,$3956c25b,$59f111f1,$923f82a4,$ab1c5ed5,
    $d807aa98,$12835b01,$243185be,$550c7dc3,$72be5d74,$80deb1fe,$9bdc06a7,$c19bf174,
    $e49b69c1,$efbe4786,$0fc19dc6,$240ca1cc,$2de92c6f,$4a7484aa,$5cb0a9dc,$76f988da,
    $983e5152,$a831c66d,$b00327c8,$bf597fc7,$c6e00bf3,$d5a79147,$06ca6351,$14292967,
    $27b70a85,$2e1b2138,$4d2c6dfc,$53380d13,$650a7354,$766a0abb,$81c2c92e,$92722c85,
    $a2bfe8a1,$a81a664b,$c24b8b70,$c76c51a3,$d192e819,$d6990624,$f40e3585,$106aa070,
    $19a4c116,$1e376c08,$2748774c,$34b0bcb5,$391c0cb3,$4ed8aa4a,$5b9cca4f,$682e6ff3,
    $748f82ee,$78a5636f,$84c87814,$8cc70208,$90befffa,$a4506ceb,$bef9a3f7,$c67178f2);

function ROTR(x: LongWord; n: Byte): LongWord; inline;
begin Result := (x shr n) or (x shl (32 - n)); end;

function SHA256Bytes(const Data: RawByteString): TSHA256Digest;
var
  h: array[0..7] of LongWord;
  msg: RawByteString;
  ml: QWord;
  i, t: Integer;
  w: array[0..63] of LongWord;
  a, b, c, d, e, f, g, hh, s0, s1, ch, maj, t1, t2: LongWord;
begin
  h[0] := $6a09e667; h[1] := $bb67ae85; h[2] := $3c6ef372; h[3] := $a54ff53a;
  h[4] := $510e527f; h[5] := $9b05688c; h[6] := $1f83d9ab; h[7] := $5be0cd19;
  ml := QWord(Length(Data)) * 8;
  msg := Data + #$80;
  while (Length(msg) mod 64) <> 56 do msg := msg + #0;
  for i := 7 downto 0 do msg := msg + AnsiChar(Byte((ml shr (i * 8)) and $FF));
  i := 1;
  while i <= Length(msg) do
  begin
    for t := 0 to 15 do
      w[t] := (LongWord(Byte(msg[i + t*4])) shl 24) or (LongWord(Byte(msg[i + t*4 + 1])) shl 16)
           or (LongWord(Byte(msg[i + t*4 + 2])) shl 8) or LongWord(Byte(msg[i + t*4 + 3]));
    for t := 16 to 63 do
    begin
      s0 := ROTR(w[t-15], 7) xor ROTR(w[t-15], 18) xor (w[t-15] shr 3);
      s1 := ROTR(w[t-2], 17) xor ROTR(w[t-2], 19) xor (w[t-2] shr 10);
      w[t] := w[t-16] + s0 + w[t-7] + s1;
    end;
    a := h[0]; b := h[1]; c := h[2]; d := h[3]; e := h[4]; f := h[5]; g := h[6]; hh := h[7];
    for t := 0 to 63 do
    begin
      s1 := ROTR(e, 6) xor ROTR(e, 11) xor ROTR(e, 25);
      ch := (e and f) xor ((not e) and g);
      t1 := hh + s1 + ch + K[t] + w[t];
      s0 := ROTR(a, 2) xor ROTR(a, 13) xor ROTR(a, 22);
      maj := (a and b) xor (a and c) xor (b and c);
      t2 := s0 + maj;
      hh := g; g := f; f := e; e := d + t1; d := c; c := b; b := a; a := t1 + t2;
    end;
    Inc(h[0], a); Inc(h[1], b); Inc(h[2], c); Inc(h[3], d);
    Inc(h[4], e); Inc(h[5], f); Inc(h[6], g); Inc(h[7], hh);
    Inc(i, 64);
  end;
  for t := 0 to 7 do
  begin
    Result[t*4]   := Byte((h[t] shr 24) and $FF);
    Result[t*4+1] := Byte((h[t] shr 16) and $FF);
    Result[t*4+2] := Byte((h[t] shr 8) and $FF);
    Result[t*4+3] := Byte(h[t] and $FF);
  end;
end;

function SHA256Hex(const Data: RawByteString): string;
var d: TSHA256Digest; i: Integer;
begin
  d := SHA256Bytes(Data);
  Result := '';
  for i := 0 to 31 do Result := Result + LowerCase(IntToHex(d[i], 2));
end;

function Base64UrlEncode(const Data: RawByteString): string;
begin
  Result := EncodeStringBase64(Data);
  Result := StringReplace(Result, #13, '', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '', [rfReplaceAll]);
  Result := StringReplace(Result, '+', '-', [rfReplaceAll]);
  Result := StringReplace(Result, '/', '_', [rfReplaceAll]);
  Result := StringReplace(Result, '=', '', [rfReplaceAll]);
end;

function Base64UrlDecode(const S: string): RawByteString;
var t: string;
begin
  t := StringReplace(S, '-', '+', [rfReplaceAll]);
  t := StringReplace(t, '_', '/', [rfReplaceAll]);
  while (Length(t) mod 4) <> 0 do t := t + '=';
  try Result := DecodeStringBase64(t, False); except Result := ''; end;
end;

function RandomBytes(n: Integer): RawByteString;
{$IFNDEF WINDOWS}
var f: file; got: Integer;
{$ENDIF}
var i: Integer;
begin
  SetLength(Result, n);
  {$IFNDEF WINDOWS}
  AssignFile(f, '/dev/urandom');
  {$I-} Reset(f, 1); {$I+}
  if IOResult = 0 then
  begin
    BlockRead(f, Result[1], n, got);
    CloseFile(f);
    if got = n then Exit;
  end;
  {$ENDIF}
  Randomize;
  for i := 1 to n do Result[i] := AnsiChar(Random(256));
end;

function PKCEVerifier: string;
begin
  { 32 random bytes → 43 base64url chars, all in the RFC unreserved set. }
  Result := Base64UrlEncode(RandomBytes(32));
end;

function PKCEChallengeS256(const Verifier: string): string;
var d: TSHA256Digest; raw: RawByteString; i: Integer;
begin
  d := SHA256Bytes(RawByteString(Verifier));
  SetLength(raw, 32);
  for i := 0 to 31 do raw[i + 1] := AnsiChar(d[i]);
  Result := Base64UrlEncode(raw);
end;

end.
