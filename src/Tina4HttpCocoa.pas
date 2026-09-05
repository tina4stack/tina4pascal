unit Tina4HttpCocoa;

{ macOS (desktop) HTTP backend for Tina4Http — FIRST PRIZE: the OS TLS stack.
  Uses Foundation's NSURLSession on a worker thread, so HTTPS goes through
  Apple's Secure Transport / system trust store with nothing crypto shipped.
  (When a native backend isn't wired, Tina4HttpFPC is the OpenSSL fallback.)

  NSURLSession is async via a completion block; FPC's block support is limited,
  so we run a synchronous request on the worker thread and hand the result to
  HttpDeliver, which the UI loop drains with HttpPump. }

{$mode delphi}{$modeswitch objectivec1}

interface

procedure InstallCocoaHttp;

implementation

uses
  CocoaAll, Classes, SysUtils, Tina4Http;

function NS(const S: string): NSString;
begin
  Result := NSString.stringWithUTF8String(PAnsiChar(S));
end;

type
  THttpThread = class(TThread)
  private
    FReq: TTina4HttpRequest;
  protected
    procedure Execute; override;
  public
    constructor Create(const Req: TTina4HttpRequest);
  end;

  TCocoaHttpBackend = class(TTina4HttpBackend)
  public
    procedure Send(const Req: TTina4HttpRequest); override;
  end;

constructor THttpThread.Create(const Req: TTina4HttpRequest);
begin
  FReq := Req;
  FreeOnTerminate := True;
  inherited Create(False);
end;

procedure THttpThread.Execute;
var
  pool: NSAutoreleasePool;
  url: NSURL; req: NSMutableURLRequest;
  resp: NSURLResponse; err: NSError; data: NSData;
  r: TTina4HttpResponse;
begin
  pool := NSAutoreleasePool.alloc.init;
  try
    r.Id := FReq.Id; r.Url := FReq.Url; r.Status := 0;
    r.Body := ''; r.ContentType := ''; r.Error := '';
    url := NSURL.URLWithString(NS(FReq.Url));
    if url = nil then begin r.Error := 'bad url'; HttpDeliver(r); Exit; end;
    req := NSMutableURLRequest.requestWithURL(url);
    req.setHTTPMethod(NS(FReq.Method));
    req.setTimeoutInterval(20);
    req.setValue_forHTTPHeaderField(NS('Tina4Pascal'), NS('User-Agent'));
    if FReq.Body <> '' then
    begin
      req.setHTTPBody(NS(FReq.Body).dataUsingEncoding(NSUTF8StringEncoding));
      if FReq.ContentType <> '' then
        req.setValue_forHTTPHeaderField(NS(FReq.ContentType), NS('Content-Type'));
    end;
    resp := nil; err := nil;
    data := NSURLConnection.sendSynchronousRequest_returningResponse_error(req, @resp, @err);
    if err <> nil then
      r.Error := string(err.localizedDescription.UTF8String)
    else
    begin
      if (resp <> nil) and resp.isKindOfClass(NSHTTPURLResponse) then
        r.Status := NSHTTPURLResponse(resp).statusCode;
      if data <> nil then
        r.Body := string(NSString(NSString.alloc.initWithData_encoding(
          data, NSUTF8StringEncoding)).UTF8String);
    end;
    HttpDeliver(r);
  finally
    pool.release;
  end;
end;

procedure TCocoaHttpBackend.Send(const Req: TTina4HttpRequest);
begin
  THttpThread.Create(Req);
end;

procedure InstallCocoaHttp;
begin
  SetHttpBackend(TCocoaHttpBackend.Create);
end;

end.
