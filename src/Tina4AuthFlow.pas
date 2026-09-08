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

implementation

uses SysUtils, Classes, ssockets
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

end.
