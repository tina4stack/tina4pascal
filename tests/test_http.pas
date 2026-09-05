program test_http;

{ Tests the Tina4Http core plumbing — request ids, the deliver→pump→callback
  path, Ok/error classification, and cancel — with a MOCK backend, so the suite
  is deterministic and needs no network. (A live GET is a separate smoke test.)
  Prints "ALL TESTS PASS", exits 0 on success. }

{$mode delphi}{$H+}

uses
  SysUtils, Tina4Http;

type
  { A backend that answers immediately from the URL — no sockets. }
  TMockBackend = class(TTina4HttpBackend)
    procedure Send(const Req: TTina4HttpRequest); override;
  end;

procedure TMockBackend.Send(const Req: TTina4HttpRequest);
var r: TTina4HttpResponse;
begin
  r.Id := Req.Id; r.Url := Req.Url; r.ContentType := 'text/plain'; r.Error := '';
  if Pos('/fail', Req.Url) > 0 then begin r.Status := 500; r.Body := 'boom'; end
  else if Pos('/echo', Req.Url) > 0 then begin r.Status := 200; r.Body := Req.Method + ':' + Req.Body; end
  else if Pos('/headers', Req.Url) > 0 then begin r.Status := 200; r.Body := Req.Headers; end
  else begin r.Status := 200; r.Body := 'hello'; end;
  HttpDeliver(r);
end;

var
  Passed, Failed, Fired: Integer;
  Last: TTina4HttpResponse;

procedure Check(Cond: Boolean; const Name: string);
begin
  if Cond then Inc(Passed)
  else begin Inc(Failed); Writeln('FAIL: ', Name); end;
end;

procedure OnResp(const R: TTina4HttpResponse);
begin
  Last := R; Inc(Fired);
end;

var id: Integer;
begin
  Passed := 0; Failed := 0; Fired := 0;
  SetHttpBackend(TMockBackend.Create);
  Check(HttpBackendInstalled, 'backend installed');

  { GET — callback fires only on pump, on this thread }
  id := HttpGet('http://x/hello', @OnResp);
  Check(id > 0, 'get returns id');
  Check(HttpPending = 1, 'one pending before pump');
  Check(Fired = 0, 'callback not fired before pump');
  Check(HttpPump = 1, 'pump fires one');
  Check((Fired = 1) and Last.Ok and (Last.Body = 'hello'), 'get delivered ok');
  Check(HttpPending = 0, 'no pending after pump');

  { POST echoes method + body }
  Fired := 0;
  HttpPost('http://x/echo', 'data', 'text/plain', @OnResp);
  HttpPump;
  Check((Fired = 1) and (Last.Body = 'POST:data'), 'post body echoed');

  { non-2xx classified as not Ok, status preserved }
  Fired := 0;
  HttpGet('http://x/fail', @OnResp);
  HttpPump;
  Check((Fired = 1) and (not Last.Ok) and (Last.Status = 500), 'failure not ok, status kept');

  { cancel drops the callback even though the mock already delivered }
  Fired := 0;
  id := HttpGet('http://x/hello', @OnResp);
  HttpCancel(id);
  Check(HttpPump = 0, 'cancelled callback not fired');
  Check((Fired = 0) and (HttpPending = 0), 'cancel leaves nothing pending');

  { headers: a per-request header reaches the backend }
  SetHttpBackend(TMockBackend.Create);
  HttpClearHeaders;
  Fired := 0;
  HttpGetEx('http://x/headers', 'Authorization: Bearer PER-REQ', @OnResp);
  HttpPump;
  Check(Pos('Authorization: Bearer PER-REQ', Last.Body) > 0, 'per-request header sent');

  { headers: a global default is applied to every request }
  HttpSetHeader('Authorization', 'Bearer DEFAULT');
  Fired := 0;
  HttpGet('http://x/headers', @OnResp);
  HttpPump;
  Check(Pos('Authorization: Bearer DEFAULT', Last.Body) > 0, 'default header applied');

  { headers: a per-request header OVERRIDES the default of the same name }
  Fired := 0;
  HttpGetEx('http://x/headers', 'Authorization: Bearer OVERRIDE', @OnResp);
  HttpPump;
  Check((Pos('Bearer OVERRIDE', Last.Body) > 0) and (Pos('DEFAULT', Last.Body) = 0),
    'per-request header overrides default');
  HttpClearHeaders;

  { no backend → an error response is delivered }
  SetHttpBackend(nil);
  Fired := 0;
  HttpGet('http://x/hello', @OnResp);
  HttpPump;
  Check((Fired = 1) and (not Last.Ok) and (Last.Error <> ''), 'no backend yields error');

  Writeln;
  Writeln(Passed, ' assertions passed, ', Failed, ' failed.');
  if Failed = 0 then begin Writeln('ALL TESTS PASS'); Halt(0); end
  else Halt(1);
end.
