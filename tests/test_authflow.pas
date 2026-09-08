program test_authflow;

{ Tests the desktop auth transport's pure logic: URL decoding, parsing the
  loopback redirect request line into code/state/error, and that a free loopback
  port can be found. The raw socket accept is OS glue driven by the shells; the
  security-relevant parsing is what's pinned here. }

{$mode delphi}{$H+}

uses SysUtils, Tina4AuthFlow;

var failed: Integer = 0;

procedure Check(Cond: Boolean; const Msg: string);
begin
  if Cond then WriteLn('  ok   ', Msg)
  else begin WriteLn('  FAIL ', Msg); Inc(failed); end;
end;

var code, state, err: string; port: Word;
begin
  WriteLn('== Tina4 auth transport (redirect parse / url decode / port) ==');

  WriteLn('UrlDecode');
  Check(UrlDecode('a%2Fb%3Fc') = 'a/b?c', 'percent-decodes %XX');
  Check(UrlDecode('one+two') = 'one two', 'plus → space');
  Check(UrlDecode('plain') = 'plain', 'plain text unchanged');

  WriteLn('AuthParseRedirect');
  Check(AuthParseRedirect('GET /cb?code=ABC-123&state=xyz789 HTTP/1.1', code, state, err),
    'parses a normal redirect');
  Check((code = 'ABC-123') and (state = 'xyz789') and (err = ''), 'code + state extracted');

  Check(AuthParseRedirect('GET /cb?state=s&code=a%2Fb%2Bc HTTP/1.1', code, state, err),
    'parses with encoded code, any param order');
  Check(code = 'a/b+c', 'code percent-decoded');

  Check(AuthParseRedirect('GET /cb?error=access_denied&state=s HTTP/1.1', code, state, err),
    'an error redirect still returns true');
  Check((err = 'access_denied') and (code = ''), 'error captured, no code');

  Check(not AuthParseRedirect('GET /cb HTTP/1.1', code, state, err), 'no query → false');
  Check(not AuthParseRedirect('garbage', code, state, err), 'malformed line → false');

  WriteLn('free loopback port');
  port := TinaAuthFreePort(8760, 8790);
  Check((port >= 8760) and (port <= 8790), 'found a bindable 127.0.0.1 port');

  WriteLn;
  if failed = 0 then begin WriteLn('ALL TESTS PASS'); Halt(0); end
  else begin WriteLn(failed, ' FAILURE(S)'); Halt(1); end;
end.
