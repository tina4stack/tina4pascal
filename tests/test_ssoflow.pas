program test_ssoflow;

{ End-to-end desktop SSO glue: the loopback listener actually accepts a live
  socket connection (a client thread plays the browser's redirect) and parses
  the code/state; and an auth session round-trips through the native secret
  store (save → logout → restore), re-deriving roles/expiry from the JWT.
  No IdP, no network beyond 127.0.0.1. }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, DateUtils, ssockets,
  Tina4Crypto, Tina4Auth, Tina4AuthFlow, Tina4Secrets;

var failed: Integer = 0;

procedure Check(Cond: Boolean; const Msg: string);
begin
  if Cond then WriteLn('  ok   ', Msg)
  else begin WriteLn('  FAIL ', Msg); Inc(failed); end;
end;

function MakeJWT(const PayloadJson: string): string;
begin
  Result := Base64UrlEncode('{"alg":"RS256","typ":"JWT"}') + '.' +
            Base64UrlEncode(RawByteString(PayloadJson)) + '.' + 'sig';
end;

var gPort: Word;

{ plays the browser: after a beat, connect to the loopback and send the redirect }
type
  TRedirectClient = class(TThread)
  protected procedure Execute; override;
  end;

procedure TRedirectClient.Execute;
var c: TInetSocket; s: string;
begin
  Sleep(300);
  try
    c := TInetSocket.Create('127.0.0.1', gPort);
    try
      s := 'GET /cb?code=ABC-123&state=st-xyz HTTP/1.1'#13#10'Host: 127.0.0.1'#13#10#13#10;
      c.Write(s[1], Length(s));
      Sleep(150);
    finally c.Free; end;
  except end;
end;

function Cfg: TTina4AuthConfig;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.ClientId := 'app';
  Result.RedirectUri := 'http://127.0.0.1/cb';
  Result.RolesClaim := 'roles';
end;

var
  client: TRedirectClient;
  code, state, err, jwt, tok: string;
  future: Int64;
begin
  WriteLn('== Tina4 SSO flow (live loopback accept + session persistence) ==');

  WriteLn('loopback accept (a client thread sends the redirect)');
  gPort := TinaAuthFreePort(8760, 8790);
  Check(gPort <> 0, 'found a free loopback port');
  client := TRedirectClient.Create(False);
  try
    Check(TinaAuthAwaitRedirect(gPort, 4000, code, state, err),
      'accepted a real connection and parsed a redirect');
    Check((code = 'ABC-123') and (state = 'st-xyz') and (err = ''),
      'code + state read from the live HTTP request line');
  finally
    client.WaitFor; client.Free;
  end;

  WriteLn('timeout when no redirect arrives');
  gPort := TinaAuthFreePort(8760, 8790);
  Check(not TinaAuthAwaitRedirect(gPort, 400, code, state, err),
    'returns false after the timeout (no hang)');

  WriteLn('session save / restore through the secret store (', TinaSecretBackend, ')');
  TinaAuthConfigure(Cfg);
  future := DateTimeToUnix(IncHour(Now, 1));
  jwt := MakeJWT('{"sub":"u1","roles":["admin","user"],"exp":' + IntToStr(future) + '}');
  tok := '{"access_token":"' + jwt + '","refresh_token":"r-9f8","id_token":"i-42"}';
  Check(TinaAuthHandleTokenResponse(tok), 'signed in (token loaded)');
  Check(TinaAuthSaveSession('tina4.session.flowtest'), 'session persisted');

  TinaAuthLogout;
  Check(not TinaAuthenticated, 'logged out (in-memory session cleared)');

  Check(TinaAuthRestoreSession('tina4.session.flowtest'), 'session restored from the store');
  Check(TinaAuthenticated, 're-authenticated from persisted tokens');
  Check(TinaHasRole('admin') and TinaHasRole('user'), 'roles survived the round-trip');
  Check(TinaRefreshToken = 'r-9f8', 'refresh token restored');
  Check(TinaIdToken = 'i-42', 'id token restored');

  TinaAuthClearSession('tina4.session.flowtest');
  Check(not TinaAuthRestoreSession('tina4.session.flowtest'), 'cleared session no longer restores');

  WriteLn;
  if failed = 0 then begin WriteLn('ALL TESTS PASS'); Halt(0); end
  else begin WriteLn(failed, ' FAILURE(S)'); Halt(1); end;
end.
