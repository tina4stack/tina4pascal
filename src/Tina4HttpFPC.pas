unit Tina4HttpFPC;

{ Desktop HTTP backend for Tina4Http, using FPC's fphttpclient on a worker
  thread. TLS comes from OpenSSL via `opensslsockets` (its unit registers the
  https handler just by being used). Good for macOS / Linux / Windows; the
  mobile shells provide native NSURLSession / HttpURLConnection backends
  instead (system TLS, no OpenSSL to ship).

  Call InstallFPCHttp once at startup. }

{$mode delphi}{$H+}

interface

procedure InstallFPCHttp;

implementation

uses
  SysUtils, Classes, fphttpclient, opensslsockets, openssl, Tina4Http;

type
  { One request, one thread. Frees itself when done. }
  THttpThread = class(TThread)
  private
    FReq: TTina4HttpRequest;
  protected
    procedure Execute; override;
  public
    constructor Create(const Req: TTina4HttpRequest);
  end;

  TFPCHttpBackend = class(TTina4HttpBackend)
  public
    procedure Send(const Req: TTina4HttpRequest); override;
  end;

constructor THttpThread.Create(const Req: TTina4HttpRequest);
begin
  FReq := Req;                    // record copy (strings are ref-counted → safe)
  FreeOnTerminate := True;
  inherited Create(False);
end;

procedure THttpThread.Execute;
var
  client: TFPHTTPClient;
  resp: TTina4HttpResponse;
  reqBody, respStream: TStringStream;
begin
  resp.Id := FReq.Id; resp.Url := FReq.Url;
  resp.Status := 0; resp.Body := ''; resp.ContentType := ''; resp.Error := '';
  client := TFPHTTPClient.Create(nil);
  reqBody := TStringStream.Create(FReq.Body);
  respStream := TStringStream.Create('');
  try
    client.AllowRedirect := True;
    client.AddHeader('User-Agent', 'Tina4Pascal');
    if (FReq.Body <> '') then
    begin
      if FReq.ContentType <> '' then client.AddHeader('Content-Type', FReq.ContentType);
      client.RequestBody := reqBody;
    end;
    try
      // empty allowed-codes = accept ANY status without raising; the status is
      // read from the client, so 4xx/5xx come back as a normal response.
      client.HTTPMethod(FReq.Method, FReq.Url, respStream, []);
      resp.Body := respStream.DataString;
      resp.Status := client.ResponseStatusCode;
      resp.ContentType := client.ResponseHeaders.Values['Content-Type'];
    except
      on E: Exception do          // transport failure (DNS/TLS/refused/timeout)
      begin
        resp.Status := 0;
        resp.Error := E.Message;
      end;
    end;
  finally
    client.RequestBody := nil;
    reqBody.Free;
    respStream.Free;
    client.Free;
  end;
  HttpDeliver(resp);              // back to the core queue (thread-safe)
end;

procedure TFPCHttpBackend.Send(const Req: TTina4HttpRequest);
begin
  THttpThread.Create(Req);       // starts immediately; frees itself
end;

{ This OpenSSL-backed path is the FALLBACK for platforms without a native TLS
  backend (Linux, Windows) — there FPC's loader finds the system libssl on the
  default search path with no help. On macOS/iOS/Android use the native OS-TLS
  backends (Tina4HttpCocoa / iOS / Android) instead — first prize, and nothing
  crypto is shipped. NB: FPC 3.2.2's OpenSSL binding does not initialise on
  Darwin/arm64 (any OpenSSL version), which is exactly why macOS uses Cocoa. }
procedure InstallFPCHttp;
begin
  SetHttpBackend(TFPCHttpBackend.Create);
end;

end.
