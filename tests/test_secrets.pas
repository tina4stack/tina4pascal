program test_secrets;

{ Round-trips the secret store. On Windows this exercises real DPAPI
  (CryptProtectData) — the stored file must NOT contain the plaintext — and on
  other platforms the portable file fallback. Deterministic, no network. }

{$mode delphi}{$H+}

uses SysUtils, Classes, Tina4Secrets;

var failed: Integer = 0;

procedure Check(Cond: Boolean; const Msg: string);
begin
  if Cond then WriteLn('  ok   ', Msg)
  else begin WriteLn('  FAIL ', Msg); Inc(failed); end;
end;

var v, token: string; got: Boolean;
{$IFDEF WINDOWS}raw, encPath: string; f: TStringList;{$ENDIF}
begin
  WriteLn('== Tina4Secrets (', TinaSecretBackend, ') ==');

  token := '{"access_token":"eyJhbGc.secret.payload","refresh_token":"r-9f8e7d"}';

  WriteLn('set / get round-trip');
  Check(TinaSecretSet('tina4.session.test', token), 'set a secret');
  Check(TinaSecretGet('tina4.session.test', v) and (v = token), 'get returns the same value');

  WriteLn('overwrite');
  Check(TinaSecretSet('tina4.session.test', 'second'), 'overwrite');
  Check(TinaSecretGet('tina4.session.test', v) and (v = 'second'), 'reads the new value');

  WriteLn('missing key');
  got := TinaSecretGet('tina4.session.does-not-exist', v);
  Check((not got) and (v = ''), 'absent secret → false, empty');

  WriteLn('delete');
  Check(TinaSecretDelete('tina4.session.test'), 'delete');
  Check(not TinaSecretGet('tina4.session.test', v), 'gone after delete');
  Check(TinaSecretDelete('tina4.session.test'), 'delete is idempotent');

  {$IFDEF WINDOWS}
  WriteLn('at-rest encryption (DPAPI)');
  TinaSecretSet('tina4.session.enc', token);
  encPath := GetEnvironmentVariable('LOCALAPPDATA') + '\Tina4\secrets\tina4.session.enc.bin';
  f := TStringList.Create;
  try f.LoadFromFile(encPath); raw := f.Text; finally f.Free; end;
  Check(Pos('refresh_token', raw) = 0, 'stored blob does not contain plaintext (encrypted at rest)');
  TinaSecretDelete('tina4.session.enc');
  {$ENDIF}

  WriteLn;
  if failed = 0 then begin WriteLn('ALL TESTS PASS'); Halt(0); end
  else begin WriteLn(failed, ' FAILURE(S)'); Halt(1); end;
end.
