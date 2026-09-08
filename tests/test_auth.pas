program test_auth;

{ Headless test for Tina4Auth: OIDC discovery parse, the PKCE authorize URL,
  token-response + JWT claim parsing, and generic role+permission RBAC with
  configurable dotted-path claims (flat and Keycloak-style). Deterministic —
  builds its own unsigned JWTs (the client trusts the token, the server verifies
  the signature), so no IdP or network is involved. }

{$mode delphi}{$H+}

uses SysUtils, DateUtils, Tina4Crypto, Tina4Auth;

var failed: Integer = 0;

procedure Check(Cond: Boolean; const Msg: string);
begin
  if Cond then WriteLn('  ok   ', Msg)
  else begin WriteLn('  FAIL ', Msg); Inc(failed); end;
end;

{ header.payload.sig — signature is a placeholder (client never verifies it). }
function MakeJWT(const PayloadJson: string): string;
begin
  Result := Base64UrlEncode('{"alg":"RS256","typ":"JWT"}') + '.' +
            Base64UrlEncode(RawByteString(PayloadJson)) + '.' + 'sig';
end;

function Cfg(const RolesClaim: string): TTina4AuthConfig;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.ClientId := 'app';
  Result.RedirectUri := 'http://127.0.0.1:8765/cb';
  Result.AuthEndpoint := 'https://idp.example/auth';
  Result.TokenEndpoint := 'https://idp.example/token';
  Result.RolesClaim := RolesClaim;
end;

var
  url, v, st, jwt, tok: string;
  future, past: Int64;
begin
  WriteLn('== Tina4Auth (OIDC / PKCE / JWT / RBAC) ==');
  future := DateTimeToUnix(IncHour(Now, 1));
  past   := DateTimeToUnix(IncHour(Now, -1));

  WriteLn('discovery');
  TinaAuthConfigure(Cfg(''));
  Check(TinaAuthDiscover('{"issuer":"https://idp.example",' +
    '"authorization_endpoint":"https://idp.example/authorize",' +
    '"token_endpoint":"https://idp.example/tok"}'), 'discovery doc parses');

  WriteLn('PKCE authorize URL');
  url := TinaAuthAuthorizeUrl(v, st);
  Check(Pos('https://idp.example/authorize?', url) = 1, 'uses the discovered auth endpoint');
  Check(Pos('response_type=code', url) > 0, 'response_type=code');
  Check(Pos('client_id=app', url) > 0, 'client_id');
  Check(Pos('redirect_uri=http%3A%2F%2F127.0.0.1%3A8765%2Fcb', url) > 0, 'redirect_uri percent-encoded');
  Check(Pos('code_challenge_method=S256', url) > 0, 'S256 method');
  Check((Pos('code_challenge=', url) > 0) and (Pos('state=', url) > 0), 'challenge + state present');
  Check(Length(v) = 43, 'code_verifier is 43 chars');

  WriteLn('token response + RBAC (flat claims)');
  TinaAuthConfigure(Cfg('roles'));
  jwt := MakeJWT('{"sub":"u1","email":"a@b.com","roles":["admin","user"],' +
    '"permissions":["invoice.write","invoice.read"],"exp":' + IntToStr(future) + '}');
  tok := '{"access_token":"' + jwt + '","refresh_token":"r1","id_token":"i1","expires_in":3600}';
  Check(TinaAuthHandleTokenResponse(tok), 'token response parses');
  Check(TinaAuthenticated, 'authenticated');
  Check(TinaHasRole('admin') and TinaHasRole('user'), 'roles extracted');
  Check(not TinaHasRole('root'), 'absent role denied');
  Check(TinaCan('invoice.write'), 'permission granted');
  Check(not TinaCan('invoice.delete'), 'absent permission denied');
  Check(TinaClaim('sub') = 'u1', 'claim by name (sub)');
  Check(TinaClaim('email') = 'a@b.com', 'claim by name (email)');
  Check(TinaRefreshToken = 'r1', 'refresh token stored');
  Check(TinaIdToken = 'i1', 'id token stored');

  WriteLn('token-endpoint request bodies');
  Check(Pos('grant_type=authorization_code', TinaAuthTokenBody('CD', 'VF')) > 0, 'auth_code grant');
  Check((Pos('code=CD', TinaAuthTokenBody('CD', 'VF')) > 0) and
        (Pos('code_verifier=VF', TinaAuthTokenBody('CD', 'VF')) > 0), 'code + PKCE verifier');
  Check(Pos('client_id=app', TinaAuthTokenBody('CD', 'VF')) > 0, 'client_id included');
  Check(Pos('grant_type=refresh_token', TinaAuthRefreshBody) > 0, 'refresh grant');
  Check(Pos('refresh_token=r1', TinaAuthRefreshBody) > 0, 'refresh body uses the stored token');
  Check(TinaAuthTokenEndpoint = 'https://idp.example/token', 'token endpoint exposed');

  WriteLn('dotted-path roles (Keycloak realm_access.roles)');
  TinaAuthConfigure(Cfg('realm_access.roles'));
  Check(TinaAuthLoadToken(MakeJWT('{"sub":"u2","realm_access":{"roles":["seller","viewer"]},"exp":' +
    IntToStr(future) + '}')), 'keycloak JWT loads');
  Check(TinaHasRole('seller') and TinaHasRole('viewer'), 'nested roles extracted');
  Check(not TinaHasRole('admin'), 'admin not present here');

  WriteLn('expiry + logout');
  Check(TinaAuthLoadToken(MakeJWT('{"sub":"u3","exp":' + IntToStr(past) + '}')), 'expired JWT loads');
  Check(TinaAuthExpired, 'past-exp token is expired');
  Check(not TinaAuthenticated, 'expired → not authenticated');
  TinaAuthLogout;
  Check((TinaAccessToken = '') and not TinaAuthenticated, 'logout clears the session');

  WriteLn;
  if failed = 0 then begin WriteLn('ALL TESTS PASS'); Halt(0); end
  else begin WriteLn(failed, ' FAILURE(S)'); Halt(1); end;
end.
