unit Tina4AuthFlow;

{ Desktop transport helpers for the OIDC login (shell-adjacent — OS browser
  launch + loopback sockets; NOT the portable core). The security-relevant
  parsing is pure and testable here (AuthParseRedirect / UrlDecode); opening the
  browser and picking a free port are thin OS wrappers. A shell drives the flow:
  pick a port → build redirect_uri http://127.0.0.1:<port>/cb → TinaAuthAuthorizeUrl
  → TinaAuthOpenBrowser → accept the redirect on that port and feed its request
  line to AuthParseRedirect → TinaAuthTokenBody → POST via Tina4Http →
  TinaAuthHandleTokenResponse. Mobile uses a custom URI scheme in its shell. }

{$mode delphi}{$H+}

interface

{ Percent-decode a query value ('+' → space, %XX → byte). }
function UrlDecode(const S: string): string;

{ Parse an HTTP request line ("GET /cb?code=..&state=..&error=.. HTTP/1.1") from
  the loopback redirect into its code / state / error params. True if a code or
  error was present. Pure — the socket layer just hands it the first line. }
function AuthParseRedirect(const RequestLine: string;
  out Code, State, ErrCode: string): Boolean;

{ Open a URL in the OS default browser. }
procedure TinaAuthOpenBrowser(const Url: string);

{ First bindable loopback port in [Lo..Hi]; 0 if none is free. }
function TinaAuthFreePort(Lo, Hi: Word): Word;

{ Bind 127.0.0.1:Port, accept ONE connection (the browser's redirect), read its
  request line, reply with a small "you can close this" page, and hand the
  parsed code/state/error back (via AuthParseRedirect). Blocks until a redirect
  arrives or TimeoutMs elapses (0 = wait forever). True if a code/error came in.
  This is the OS glue a desktop shell runs after TinaAuthOpenBrowser. }
function TinaAuthAwaitRedirect(Port: Word; TimeoutMs: Integer;
  out Code, State, ErrCode: string): Boolean;

{ Persist / restore the current auth session (access+refresh+id tokens) via the
  native secret store (Tina4Secrets — DPAPI on Windows). Restore repopulates
  Tina4Auth exactly as a fresh token response would, re-deriving roles/claims/
  expiry from the stored JWT. Key is the secret name, e.g. 'tina4.session'. }
function TinaAuthSaveSession(const Key: string): Boolean;
function TinaAuthRestoreSession(const Key: string): Boolean;
procedure TinaAuthClearSession(const Key: string);

implementation

uses SysUtils, Classes, ssockets, Tina4Auth, Tina4Secrets
  {$IFDEF WINDOWS}, Windows, ShellApi{$ELSE}, Unix{$ENDIF};

function UrlDecode(const S: string): string;
var i, code, e: Integer;
begin
  Result := '';
  i := 1;
  while i <= Length(S) do
  begin
    if (S[i] = '%') and (i + 2 <= Length(S)) then
    begin
      Val('$' + Copy(S, i + 1, 2), code, e);
      if e = 0 then begin Result := Result + AnsiChar(code); Inc(i, 3); end
      else begin Result := Result + S[i]; Inc(i); end;
    end
    else if S[i] = '+' then begin Result := Result + ' '; Inc(i); end
    else begin Result := Result + S[i]; Inc(i); end;
  end;
end;

function AuthParseRedirect(const RequestLine: string;
  out Code, State, ErrCode: string): Boolean;
var target, qs, kv, k: string; sp1, sp2, q, i: Integer; parts: TStringArray;
begin
  Code := ''; State := ''; ErrCode := '';
  sp1 := Pos(' ', RequestLine);
  if sp1 = 0 then Exit(False);
  sp2 := sp1 + 1; while (sp2 <= Length(RequestLine)) and (RequestLine[sp2] <> ' ') do Inc(sp2);
  target := Copy(RequestLine, sp1 + 1, sp2 - sp1 - 1);   // e.g. /cb?code=..&state=..
  q := Pos('?', target);
  if q = 0 then Exit(False);
  qs := Copy(target, q + 1, MaxInt);
  parts := qs.Split(['&']);
  for i := 0 to High(parts) do
  begin
    kv := parts[i];
    q := Pos('=', kv);
    if q = 0 then Continue;
    k := Copy(kv, 1, q - 1);
    if k = 'code' then Code := UrlDecode(Copy(kv, q + 1, MaxInt))
    else if k = 'state' then State := UrlDecode(Copy(kv, q + 1, MaxInt))
    else if k = 'error' then ErrCode := UrlDecode(Copy(kv, q + 1, MaxInt));
  end;
  Result := (Code <> '') or (ErrCode <> '');
end;

procedure TinaAuthOpenBrowser(const Url: string);
begin
  {$IFDEF WINDOWS}
  ShellExecuteW(0, 'open', PWideChar(UTF8Decode(Url)), nil, nil, 5 { SW_SHOW });
  {$ELSE}{$IFDEF DARWIN}
  fpSystem('open ' + QuotedStr(Url));
  {$ELSE}
  fpSystem('xdg-open ' + QuotedStr(Url) + ' >/dev/null 2>&1 &');
  {$ENDIF}{$ENDIF}
end;

function TinaAuthFreePort(Lo, Hi: Word): Word;
var p: Word; s: TInetServer;
begin
  Result := 0;
  for p := Lo to Hi do
  begin
    s := TInetServer.Create('127.0.0.1', p);
    try
      try s.Bind; Exit(p); except Continue; end;
    finally s.Free; end;
  end;
end;

{ ---- loopback accept ----------------------------------------------------- }
type
  TAuthLoop = class
    Line: string;
    Got: Boolean;
    Deadline: QWord;      // GetTickCount64 deadline; 0 = wait forever
    procedure Connected(Sender: TObject; Data: TSocketStream);
    procedure Idle(Sender: TObject);
  end;

procedure TAuthLoop.Connected(Sender: TObject; Data: TSocketStream);
var buf: array[0..8191] of AnsiChar; n, p: Integer; req, resp: string;
begin
  n := Data.Read(buf, SizeOf(buf) - 1);
  if n > 0 then
  begin
    SetString(req, PAnsiChar(@buf[0]), n);
    p := Pos(#13#10, req); if p = 0 then p := Pos(#10, req);
    if p > 0 then Line := Copy(req, 1, p - 1) else Line := req;
  end;
  resp := 'HTTP/1.1 200 OK'#13#10 +
          'Content-Type: text/html; charset=utf-8'#13#10 +
          'Connection: close'#13#10#13#10 +
          '<!doctype html><meta charset="utf-8">' +
          '<body style="font-family:sans-serif;text-align:center;padding:56px 24px;color:#15162e">' +
          '<h2 style="margin:0 0 8px">Signed in</h2>' +
          '<p style="color:#5b5c78">You can close this window and return to the app.</p></body>';
  try Data.Write(resp[1], Length(resp)); except end;
  Got := True;
  (Sender as TSocketServer).StopAccepting(False);   // one redirect is all we need
end;

procedure TAuthLoop.Idle(Sender: TObject);
begin
  if (Deadline <> 0) and (GetTickCount64 >= Deadline) then
    (Sender as TSocketServer).StopAccepting(True);
end;

function TinaAuthAwaitRedirect(Port: Word; TimeoutMs: Integer;
  out Code, State, ErrCode: string): Boolean;
var srv: TInetServer; loop: TAuthLoop;
begin
  Result := False; Code := ''; State := ''; ErrCode := '';
  loop := TAuthLoop.Create;
  srv := TInetServer.Create('127.0.0.1', Port);
  try
    srv.ReuseAddress := True;
    if TimeoutMs > 0 then
    begin
      srv.AcceptIdleTimeOut := 200;                 // poll OnIdle ~5x/sec
      loop.Deadline := GetTickCount64 + QWord(TimeoutMs);
    end;
    srv.OnConnect := loop.Connected;                // {$mode delphi}: no @ on method events
    srv.OnIdle := loop.Idle;
    srv.Bind;
    srv.Listen;
    try srv.StartAccepting; except end;             // returns once StopAccepting fires
    if loop.Got then Result := AuthParseRedirect(loop.Line, Code, State, ErrCode);
  finally
    srv.Free; loop.Free;
  end;
end;

{ ---- session persistence (via Tina4Secrets) ------------------------------ }
function JsonEsc(const S: string): string;
var i: Integer;
begin
  Result := '';
  for i := 1 to Length(S) do
    case S[i] of
      '\': Result := Result + '\\';
      '"': Result := Result + '\"';
    else   Result := Result + S[i];
    end;
end;

function TinaAuthSaveSession(const Key: string): Boolean;
var js: string;
begin
  if (TinaAccessToken = '') then Exit(False);      // nothing to persist
  js := '{"access_token":"' + JsonEsc(TinaAccessToken) + '"';
  if TinaRefreshToken <> '' then js := js + ',"refresh_token":"' + JsonEsc(TinaRefreshToken) + '"';
  if TinaIdToken <> '' then js := js + ',"id_token":"' + JsonEsc(TinaIdToken) + '"';
  js := js + '}';
  Result := TinaSecretSet(Key, js);
end;

function TinaAuthRestoreSession(const Key: string): Boolean;
var js: string;
begin
  Result := False;
  if not TinaSecretGet(Key, js) then Exit;
  if js = '' then Exit;
  Result := TinaAuthHandleTokenResponse(js);       // re-derives claims/roles/expiry from the JWT
end;

procedure TinaAuthClearSession(const Key: string);
begin
  TinaSecretDelete(Key);
end;

end.
