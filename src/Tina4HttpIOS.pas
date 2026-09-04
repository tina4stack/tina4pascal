unit Tina4HttpIOS;

{ iOS HTTP backend for Tina4Http — bridges to NSURLSession in the Obj-C app, so
  HTTPS uses Apple's native TLS (Secure Transport / the system trust store),
  with no OpenSSL shipped. Symmetric to the Android HttpURLConnection backend.

  The request is handed to a C function the app implements (tina4_ios_http_send);
  the app runs an NSURLSession data task and, on completion, calls back the
  Pascal export tina4_http_result, which queues the response for HttpPump. }

{$mode delphi}{$H+}

interface

uses
  ctypes, Tina4Http;

{ Install as the process HTTP backend (call once at startup, after TinaInit). }
procedure InstallIOSHttp;

{ Exported for the Obj-C side to call when a request completes. The `public
  name` makes it a linker-visible C symbol from inside the static library. }
procedure tina4_http_result(Id, Status: cint; Body, Error: PAnsiChar); cdecl;

implementation

procedure tina4_http_result(Id, Status: cint; Body, Error: PAnsiChar); cdecl;
  public name '_tina4_http_result';   // Mach-O C symbols carry a leading _
var r: TTina4HttpResponse;
begin
  r.Id := Id; r.Url := ''; r.Status := Status;
  r.Body := string(Body); r.ContentType := ''; r.Error := string(Error);
  HttpDeliver(r);
end;

{ Implemented in the app (ios/app/Http.m) — starts an NSURLSession data task. }
procedure tina4_ios_http_send(Id: cint; Method, Url, Body, Ctype: PAnsiChar); cdecl;
  external name 'tina4_ios_http_send';

type
  TIOSHttpBackend = class(TTina4HttpBackend)
  public
    procedure Send(const Req: TTina4HttpRequest); override;
  end;

procedure TIOSHttpBackend.Send(const Req: TTina4HttpRequest);
begin
  tina4_ios_http_send(Req.Id, PAnsiChar(Req.Method), PAnsiChar(Req.Url),
    PAnsiChar(Req.Body), PAnsiChar(Req.ContentType));
end;

procedure InstallIOSHttp;
begin
  SetHttpBackend(TIOSHttpBackend.Create);
end;

end.
