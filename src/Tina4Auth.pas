unit Tina4Auth;

{ OIDC / OAuth2 auth + RBAC brain for Tina4 apps. Generic OpenID Connect:
  Authorization-Code flow with PKCE (S256) for native/public clients, JWT claim
  parsing, and role+permission access checks. Provider-agnostic — the roles and
  permissions claim locations are configurable dotted paths (so Keycloak's
  `realm_access.roles`, a flat `roles`, or `permissions` all work).

  This unit is pure logic (fpjson + Tina4Crypto): it builds the authorize URL,
  parses the token + JWT responses, and answers TinaCan/TinaHasRole. The
  side-effectful transport lives elsewhere: the system-browser launch + loopback
  listener (per-shell) POST the code to the token endpoint and hand the JSON to
  TinaAuthHandleTokenResponse; secure token storage is Tina4Secrets; the RBAC
  hook + declarative guards live in the engine. Server-side RBAC stays the
  security boundary — this is UX gating + attaching the bearer token. }

{$mode delphi}{$H+}

interface

type
  TTina4AuthConfig = record
    Issuer: string;          // e.g. https://idp.example.com/realms/app
    ClientId: string;
    RedirectUri: string;     // desktop: http://127.0.0.1:<port>/cb · mobile: myapp://cb
    Scope: string;           // default 'openid profile email'
    AuthEndpoint: string;    // set directly, or filled by TinaAuthDiscover
    TokenEndpoint: string;
    RolesClaim: string;      // dotted path, default 'roles' (Keycloak: realm_access.roles)
    PermsClaim: string;      // dotted path, default 'permissions'
  end;

procedure TinaAuthConfigure(const Cfg: TTina4AuthConfig);
{ Fill AuthEndpoint/TokenEndpoint (and Issuer) from a discovery document
  (.well-known/openid-configuration JSON). }
function  TinaAuthDiscover(const DiscoveryJson: string): Boolean;

{ Build the PKCE authorization URL to open in the system browser. Returns the URL
  and hands back the code_verifier + state to correlate the redirect. }
function  TinaAuthAuthorizeUrl(out Verifier, State: string): string;

{ Parse a token-endpoint JSON response (access_token, refresh_token, id_token,
  expires_in, ...) into the session (tokens, expiry) and load the JWT claims. }
function  TinaAuthHandleTokenResponse(const Json: string): Boolean;

{ Load claims directly from a JWT access token (used by refresh + tests). }
function  TinaAuthLoadToken(const AccessToken: string): Boolean;

function  TinaAuthenticated: Boolean;
function  TinaAuthExpired: Boolean;         // access token past its exp (5s skew)
function  TinaAccessToken: string;
function  TinaRefreshToken: string;
function  TinaIdToken: string;

{ RBAC. Roles/perms come from the configured claim paths. }
function  TinaHasRole(const Role: string): Boolean;
function  TinaCan(const Perm: string): Boolean;
{ Read any claim by dotted path (e.g. 'sub', 'realm_access.roles', 'email'). '' if absent. }
function  TinaClaim(const Path: string): string;

procedure TinaAuthLogout;

implementation

uses SysUtils, Classes, StrUtils, DateUtils, fpjson, jsonparser, Tina4Crypto;

var
  GCfg: TTina4AuthConfig;
  GAccess, GRefresh, GId: string;
  GClaims: TJSONObject = nil;    // parsed JWT payload (owned)
  GRoles: TStringList = nil;
  GPerms: TStringList = nil;
  GExpiresAt: TDateTime = 0;

{ Navigate a dotted path through nested JSON objects; returns the node or nil. }
function JPath(Root: TJSONData; const Path: string): TJSONData;
var parts: TStringArray; i: Integer; cur: TJSONData;
begin
  Result := nil;
  if Root = nil then Exit;
  parts := Path.Split(['.']);
  cur := Root;
  for i := 0 to High(parts) do
  begin
    if (cur = nil) or (cur.JSONType <> jtObject) then Exit(nil);
    cur := TJSONObject(cur).Find(parts[i]);
  end;
  Result := cur;
end;

{ Collect string members of the array/scalar at a dotted path into List. }
procedure CollectStrings(Root: TJSONData; const Path: string; List: TStringList);
var node: TJSONData; i: Integer;
begin
  List.Clear;
  node := JPath(Root, Path);
  if node = nil then Exit;
  if node.JSONType = jtArray then
  begin
    for i := 0 to TJSONArray(node).Count - 1 do
      if TJSONArray(node).Items[i].JSONType = jtString then
        List.Add(TJSONArray(node).Items[i].AsString);
  end
  else if node.JSONType = jtString then
    List.Add(node.AsString);   // space-separated? keep exact for now
end;

procedure EnsureLists;
begin
  if GRoles = nil then GRoles := TStringList.Create;
  if GPerms = nil then GPerms := TStringList.Create;
end;

function DefaultsApplied(const Cfg: TTina4AuthConfig): TTina4AuthConfig;
begin
  Result := Cfg;
  if Result.Scope = '' then Result.Scope := 'openid profile email';
  if Result.RolesClaim = '' then Result.RolesClaim := 'roles';
  if Result.PermsClaim = '' then Result.PermsClaim := 'permissions';
end;

procedure TinaAuthConfigure(const Cfg: TTina4AuthConfig);
begin
  GCfg := DefaultsApplied(Cfg);
end;

function TinaAuthDiscover(const DiscoveryJson: string): Boolean;
var d: TJSONData; o: TJSONObject; s: string;
begin
  Result := False;
  try d := GetJSON(DiscoveryJson); except Exit; end;
  try
    if d.JSONType <> jtObject then Exit;
    o := TJSONObject(d);
    s := o.Get('authorization_endpoint', ''); if s <> '' then GCfg.AuthEndpoint := s;
    s := o.Get('token_endpoint', '');         if s <> '' then GCfg.TokenEndpoint := s;
    s := o.Get('issuer', '');                 if s <> '' then GCfg.Issuer := s;
    Result := (GCfg.AuthEndpoint <> '') and (GCfg.TokenEndpoint <> '');
  finally d.Free; end;
end;

{ percent-encode for a query value (RFC 3986 unreserved kept). }
function UrlEnc(const S: string): string;
var i: Integer; ch: Char;
begin
  Result := '';
  for i := 1 to Length(S) do
  begin
    ch := S[i];
    if ((ch >= 'A') and (ch <= 'Z')) or ((ch >= 'a') and (ch <= 'z')) or
       ((ch >= '0') and (ch <= '9')) or (ch = '-') or (ch = '_') or (ch = '.') or (ch = '~') then
      Result := Result + ch
    else
      Result := Result + '%' + UpperCase(IntToHex(Ord(ch), 2));
  end;
end;

function TinaAuthAuthorizeUrl(out Verifier, State: string): string;
var challenge, sep: string;
begin
  Verifier := PKCEVerifier;
  State := Base64UrlEncode(RawByteString(PKCEVerifier));  // opaque, unguessable
  challenge := PKCEChallengeS256(Verifier);
  if Pos('?', GCfg.AuthEndpoint) > 0 then sep := '&' else sep := '?';
  Result := GCfg.AuthEndpoint + sep +
    'response_type=code' +
    '&client_id=' + UrlEnc(GCfg.ClientId) +
    '&redirect_uri=' + UrlEnc(GCfg.RedirectUri) +
    '&scope=' + UrlEnc(GCfg.Scope) +
    '&state=' + UrlEnc(State) +
    '&code_challenge=' + UrlEnc(challenge) +
    '&code_challenge_method=S256';
end;

function TinaAuthLoadToken(const AccessToken: string): Boolean;
var dot1, dot2: Integer; payload: RawByteString; d: TJSONData; exp: Int64;
begin
  Result := False;
  if GClaims <> nil then begin GClaims.Free; GClaims := nil; end;
  EnsureLists; GRoles.Clear; GPerms.Clear; GExpiresAt := 0;
  dot1 := Pos('.', AccessToken);
  if dot1 = 0 then Exit;
  dot2 := PosEx('.', AccessToken, dot1 + 1);
  if dot2 = 0 then Exit;
  payload := Base64UrlDecode(Copy(AccessToken, dot1 + 1, dot2 - dot1 - 1));
  if payload = '' then Exit;
  try d := GetJSON(string(payload)); except Exit; end;
  if d.JSONType <> jtObject then begin d.Free; Exit; end;
  GClaims := TJSONObject(d);
  CollectStrings(GClaims, GCfg.RolesClaim, GRoles);
  CollectStrings(GClaims, GCfg.PermsClaim, GPerms);
  exp := GClaims.Get('exp', Int64(0));
  if exp > 0 then GExpiresAt := UnixToDateTime(exp);
  GAccess := AccessToken;
  Result := True;
end;

function TinaAuthHandleTokenResponse(const Json: string): Boolean;
var d: TJSONData; o: TJSONObject; exp: Integer;
begin
  Result := False;
  try d := GetJSON(Json); except Exit; end;
  try
    if d.JSONType <> jtObject then Exit;
    o := TJSONObject(d);
    GRefresh := o.Get('refresh_token', GRefresh);
    GId := o.Get('id_token', '');
    if o.Get('access_token', '') <> '' then
      TinaAuthLoadToken(o.Get('access_token', ''));
    exp := o.Get('expires_in', 0);        // seconds; refine the exp if the JWT lacked one
    if (exp > 0) and (GExpiresAt = 0) then GExpiresAt := IncSecond(Now, exp);
    Result := GAccess <> '';
  finally d.Free; end;
end;

function TinaAuthenticated: Boolean;
begin Result := (GAccess <> '') and (not TinaAuthExpired); end;

function TinaAuthExpired: Boolean;
begin
  if GExpiresAt = 0 then Exit(False);            // unknown expiry → treat as valid
  Result := Now > IncSecond(GExpiresAt, 5);      // 5s clock skew
end;

function TinaAccessToken: string;  begin Result := GAccess; end;
function TinaRefreshToken: string; begin Result := GRefresh; end;
function TinaIdToken: string;      begin Result := GId; end;

function TinaHasRole(const Role: string): Boolean;
begin EnsureLists; Result := GRoles.IndexOf(Role) >= 0; end;

function TinaCan(const Perm: string): Boolean;
begin EnsureLists; Result := GPerms.IndexOf(Perm) >= 0; end;

function TinaClaim(const Path: string): string;
var node: TJSONData;
begin
  Result := '';
  node := JPath(GClaims, Path);
  if node = nil then Exit;
  if node.JSONType in [jtString, jtNumber, jtBoolean] then Result := node.AsString
  else Result := node.AsJSON;   // objects/arrays as their JSON text
end;

procedure TinaAuthLogout;
begin
  GAccess := ''; GRefresh := ''; GId := ''; GExpiresAt := 0;
  if GClaims <> nil then begin GClaims.Free; GClaims := nil; end;
  EnsureLists; GRoles.Clear; GPerms.Clear;
end;

finalization
  if GClaims <> nil then GClaims.Free;
  GRoles.Free; GPerms.Free;

end.
