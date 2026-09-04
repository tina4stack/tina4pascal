unit Tina4Http;

{ Async HTTP for Tina4Pascal — the portable core.

  HTTP must never block the render loop, and the platform owns TLS, so this unit
  is split like the canvas: a small PORTABLE core (this file) that app code talks
  to, behind a swappable BACKEND that each platform provides:

    • desktop → Tina4HttpFPC (fphttpclient + OpenSSL, on a worker thread)
    • iOS / macOS → NSURLSession   (native TLS)          [shell]
    • Android → HttpURLConnection  (native TLS)           [shell]

  Threading contract — the important part: a backend runs the request on ITS OWN
  thread and hands the result back with HttpDeliver (thread-safe). The result
  sits in a queue until the main loop calls HttpPump, which fires your callback
  ON THE MAIN THREAD — so a callback may safely mutate the DOM and request a
  repaint, exactly like a tap handler. No locks in app code.

  Usage:
    HttpGet('https://api…/thing', @OnThing);   // returns a request id
    // …each frame (the shell does this): HttpPump;
    procedure OnThing(const R: TTina4HttpResponse);
    begin
      if R.Ok then SetElemText(FindById(Root,'x'), R.Body);
    end;                                                                    }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, SyncObjs;

type
  TTina4HttpResponse = record
    Id: Integer;
    Url: string;
    Status: Integer;        // HTTP status; 0 = transport error (see Error)
    Body: string;
    ContentType: string;
    Error: string;          // '' on success
    function Ok: Boolean;    // 2xx and no transport error
  end;

  TTina4HttpProc   = procedure(const Resp: TTina4HttpResponse);
  TTina4HttpMethod = procedure(const Resp: TTina4HttpResponse) of object;

  { What a backend receives. Strings are copied, so the backend may keep them
    on its worker thread safely. }
  TTina4HttpRequest = record
    Id: Integer;
    Method: string;         // 'GET' | 'POST' | …
    Url: string;
    Body: string;
    ContentType: string;
  end;

  TTina4HttpBackend = class
  public
    { Perform Req asynchronously; call HttpDeliver when done (any thread). }
    procedure Send(const Req: TTina4HttpRequest); virtual; abstract;
  end;

{ Install the platform backend (takes ownership; frees a previous one). }
procedure SetHttpBackend(Backend: TTina4HttpBackend);
function  HttpBackendInstalled: Boolean;

{ Fire a request; returns its id. The callback runs later, on the main thread,
  from HttpPump. GET and POST cover the common cases; use HttpRequest for others. }
function HttpGet(const Url: string; CB: TTina4HttpProc): Integer; overload;
function HttpGet(const Url: string; CB: TTina4HttpMethod): Integer; overload;
function HttpPost(const Url, Body, ContentType: string; CB: TTina4HttpProc): Integer; overload;
function HttpPost(const Url, Body, ContentType: string; CB: TTina4HttpMethod): Integer; overload;
function HttpRequest(const Method, Url, Body, ContentType: string; CB: TTina4HttpMethod): Integer;

{ Backend → core: hand back a completed response (thread-safe, any thread). }
procedure HttpDeliver(const Resp: TTina4HttpResponse);

{ Main thread: deliver every completed response to its callback. Returns how
  many fired. The shell calls this once per frame (or on a timer). }
function HttpPump: Integer;

{ Drop a pending callback (its response, if it still arrives, is ignored). }
procedure HttpCancel(Id: Integer);
{ How many requests are still awaiting a response. }
function HttpPending: Integer;

implementation

type
  TPending = record
    CBProc: TTina4HttpProc;
    CBMethod: TTina4HttpMethod;
  end;

var
  GBackend: TTina4HttpBackend = nil;
  GNextId: Integer = 0;
  GPending: TDictionary<Integer, TPending> = nil;    // main thread only
  GQueue: TList<TTina4HttpResponse> = nil;           // guarded by GLock
  GLock: TCriticalSection = nil;

function TTina4HttpResponse.Ok: Boolean;
begin
  Result := (Error = '') and (Status >= 200) and (Status < 300);
end;

procedure Ensure;
begin
  if GPending = nil then GPending := TDictionary<Integer, TPending>.Create;
  if GQueue = nil then GQueue := TList<TTina4HttpResponse>.Create;
  if GLock = nil then GLock := TCriticalSection.Create;
end;

procedure SetHttpBackend(Backend: TTina4HttpBackend);
begin
  if (GBackend <> nil) and (GBackend <> Backend) then GBackend.Free;
  GBackend := Backend;
end;

function HttpBackendInstalled: Boolean;
begin
  Result := GBackend <> nil;
end;

{ start a request with the pending callback recorded; dispatch or fail fast }
function Start(const Method, Url, Body, ContentType: string; const P: TPending): Integer;
var req: TTina4HttpRequest; r: TTina4HttpResponse;
begin
  Ensure;
  Inc(GNextId);
  Result := GNextId;
  GPending.AddOrSetValue(Result, P);
  if GBackend = nil then
  begin
    r.Id := Result; r.Url := Url; r.Status := 0; r.Body := '';
    r.ContentType := ''; r.Error := 'no HTTP backend installed';
    HttpDeliver(r);
    Exit;
  end;
  req.Id := Result; req.Method := Method; req.Url := Url;
  req.Body := Body; req.ContentType := ContentType;
  GBackend.Send(req);
end;

function HttpGet(const Url: string; CB: TTina4HttpProc): Integer;
var p: TPending;
begin
  p.CBProc := CB; p.CBMethod := nil;
  Result := Start('GET', Url, '', '', p);
end;

function HttpGet(const Url: string; CB: TTina4HttpMethod): Integer;
var p: TPending;
begin
  p.CBProc := nil; p.CBMethod := CB;
  Result := Start('GET', Url, '', '', p);
end;

function HttpPost(const Url, Body, ContentType: string; CB: TTina4HttpProc): Integer;
var p: TPending;
begin
  p.CBProc := CB; p.CBMethod := nil;
  Result := Start('POST', Url, Body, ContentType, p);
end;

function HttpPost(const Url, Body, ContentType: string; CB: TTina4HttpMethod): Integer;
var p: TPending;
begin
  p.CBProc := nil; p.CBMethod := CB;
  Result := Start('POST', Url, Body, ContentType, p);
end;

function HttpRequest(const Method, Url, Body, ContentType: string; CB: TTina4HttpMethod): Integer;
var p: TPending;
begin
  p.CBProc := nil; p.CBMethod := CB;
  Result := Start(Method, Url, Body, ContentType, p);
end;

procedure HttpDeliver(const Resp: TTina4HttpResponse);
begin
  Ensure;
  GLock.Enter;
  try GQueue.Add(Resp);
  finally GLock.Leave; end;
end;

function HttpPump: Integer;
var batch: TArray<TTina4HttpResponse>; i: Integer; r: TTina4HttpResponse; p: TPending;
begin
  Result := 0;
  if (GQueue = nil) or (GLock = nil) then Exit;
  GLock.Enter;                       // snapshot + clear under the lock
  try
    if GQueue.Count = 0 then Exit;
    batch := GQueue.ToArray;
    GQueue.Clear;
  finally GLock.Leave; end;
  for i := 0 to High(batch) do        // then fire callbacks on THIS (main) thread
  begin
    r := batch[i];
    if GPending.TryGetValue(r.Id, p) then
    begin
      GPending.Remove(r.Id);
      if Assigned(p.CBProc) then p.CBProc(r)
      else if Assigned(p.CBMethod) then p.CBMethod(r);
      Inc(Result);
    end;
  end;
end;

procedure HttpCancel(Id: Integer);
begin
  if GPending <> nil then GPending.Remove(Id);
end;

function HttpPending: Integer;
begin
  if GPending = nil then Result := 0 else Result := GPending.Count;
end;

initialization
finalization
  GPending.Free;
  GQueue.Free;
  GLock.Free;
  GBackend.Free;
end.
