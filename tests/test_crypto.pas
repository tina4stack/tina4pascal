program test_crypto;

{ Pins Tina4Crypto against published vectors: NIST SHA-256 test hashes, base64url
  round-trip, and the RFC 7636 (PKCE) S256 challenge example. Deterministic. }

{$mode delphi}{$H+}

uses SysUtils, Tina4Crypto;

var failed: Integer = 0;

procedure Check(Cond: Boolean; const Msg: string);
begin
  if Cond then WriteLn('  ok   ', Msg)
  else begin WriteLn('  FAIL ', Msg); Inc(failed); end;
end;

var v: string;
begin
  WriteLn('== Tina4Crypto (SHA-256 / base64url / PKCE) ==');

  WriteLn('SHA-256 NIST vectors');
  Check(SHA256Hex('') =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855', 'empty string');
  Check(SHA256Hex('abc') =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad', '"abc"');
  Check(SHA256Hex('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq') =
    '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1', '56-byte message (2 blocks)');

  WriteLn('base64url');
  Check(Base64UrlEncode('') = '', 'empty');
  Check(Base64UrlEncode('Man') = 'TWFu', 'no padding needed');
  Check(Base64UrlEncode(#$FB#$FF) = '-_8', 'URL-safe -/_ and stripped padding');
  Check(Base64UrlDecode(Base64UrlEncode(#0#1#2#$FE#$FF'hello')) = #0#1#2#$FE#$FF'hello',
    'decode(encode(x)) round-trips arbitrary bytes');

  WriteLn('PKCE (RFC 7636 Appendix B)');
  Check(PKCEChallengeS256('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk') =
    'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM', 'S256 challenge matches the RFC example');
  v := PKCEVerifier;
  Check(Length(v) = 43, 'generated verifier is 43 chars');
  Check(v <> PKCEVerifier, 'two verifiers differ (non-constant)');

  WriteLn;
  if failed = 0 then begin WriteLn('ALL TESTS PASS'); Halt(0); end
  else begin WriteLn(failed, ' FAILURE(S)'); Halt(1); end;
end.
