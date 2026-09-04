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

{ macOS ships Secure Transport, not OpenSSL, so FPC's loader finds no libssl on
  the default path. Point it at a Homebrew/local build if one is present (this
  is desktop-only; the mobile shells use native TLS, no OpenSSL to ship). }
function FirstExisting(const Paths: array of string): string;
var i: Integer;
begin
  Result := '';
  for i := Low(Paths) to High(Paths) do
    if FileExists(Paths[i]) then Exit(Paths[i]);
end;

procedure PointOpenSSL;
begin
{$IFDEF DARWIN}
  if SSLLibFile = '' then
    SSLLibFile := FirstExisting([
      '/opt/homebrew/lib/libssl.dylib',
      '/opt/homebrew/opt/openssl/lib/libssl.dylib',
      '/usr/local/opt/openssl/lib/libssl.dylib']);
  if SSLUtilFile = '' then
    SSLUtilFile := FirstExisting([
      '/opt/homebrew/lib/libcrypto.dylib',
      '/opt/homebrew/opt/openssl/lib/libcrypto.dylib',
      '/usr/local/opt/openssl/lib/libcrypto.dylib']);
{$ENDIF}
end;

procedure InstallFPCHttp;
begin
  PointOpenSSL;
  SetHttpBackend(TFPCHttpBackend.Create);
end;

end.
