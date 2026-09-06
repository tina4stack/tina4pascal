unit Tina4SSE;

{ Server-Sent Events client for the Tina4 native data layer.

  SSE is a long-lived HTTP GET whose body streams `event:`/`data:`/`id:` lines
  (text/event-stream). This unit has two pieces:

    • TSSEParser — the pure line-protocol state machine (no I/O). Feed it bytes;
      it fires OnEvent(name, data, id) once per blank-line-terminated block.
      Fully deterministic and unit-tested.

    • TTina4SSE — a worker thread (FPC ssockets) that opens the stream and feeds
      the parser, queueing each event thread-safely. The UI thread calls Drain
      (from the shell ticker) to fire OnEvent on itself, so handlers may touch
      the DOM and repaint. Auto-reconnect honours `retry:` and Last-Event-ID.

  v1 is plaintext http:// (portable on every FPC target via ssockets). https://
  (TLS) is a follow-up — reuse each shell's OS stack or openssl. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs, ssockets, sslsockets, opensslsockets;

type
  { fired once per SSE event; EventName defaults to 'message' }
  TSSEEventProc = procedure(const EventName, Data, Id: string) of object;

  { pure line-protocol parser — no sockets, unit-testable }
  TSSEParser = class
  private
    FBuf: string;            // bytes not yet split into a complete line
    FEvent, FData, FId: string;
    FHasData: Boolean;
    procedure HandleLine(const Line: string);
    procedure Dispatch;
  public
    OnEvent: TSSEEventProc;
    LastId: string;
    RetryMs: Integer;
    procedure Feed(const Chunk: string);   // push raw bytes; fires OnEvent inline
    procedure Reset;
  end;

  TTina4SSE = class;

  TSSEThread = class(TThread)
  private
    FOwner: TTina4SSE;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TTina4SSE);
  end;

  { queued (name,data,id) waiting for the UI thread to fire it }
  TSSEQueued = record EventName, Data, Id: string; end;

  TTina4SSE = class
  private
    FUrl, FHost, FPath: string;
    FPort: Word;
    FSecure: Boolean;            // https:// → wrap the socket in TLS
    FThread: TSSEThread;
    FLock: TCriticalSection;
    FQueue: array of TSSEQueued;
    FLastId: string;
    FStop: Boolean;
    procedure Enqueue(const EventName, Data, Id: string);
  public
    OnEvent: TSSEEventProc;    // fired on the UI thread from Drain
    constructor Create(const Url: string);
    destructor Destroy; override;
    procedure Open;
    procedure Close;
    { UI thread: fire queued events on OnEvent. Call from the shell ticker. }
    procedure Drain;
    property Host: string read FHost;
    property Path: string read FPath;
    property Port: Word read FPort;
  end;

{ Split a URL into host/port/path. Returns False if not http://. }
function ParseHttpUrl(const Url: string; out Host: string; out Port: Word; out Path: string): Boolean;

implementation

function ParseHttpUrl(const Url: string; out Host: string; out Port: Word; out Path: string): Boolean;
var s, hostport: string; p: Integer;
begin
  Result := False; Host := ''; Port := 80; Path := '/';
  s := Url;
  if LowerCase(Copy(s, 1, 7)) = 'http://' then Delete(s, 1, 7)
  else if LowerCase(Copy(s, 1, 8)) = 'https://' then begin Delete(s, 1, 8); Port := 443; end
  else Exit;
  p := Pos('/', s);
  if p > 0 then begin hostport := Copy(s, 1, p - 1); Path := Copy(s, p, MaxInt); end
  else begin hostport := s; Path := '/'; end;
  p := Pos(':', hostport);
  if p > 0 then
  begin
    Host := Copy(hostport, 1, p - 1);
    Port := StrToIntDef(Copy(hostport, p + 1, MaxInt), Port);
  end
  else Host := hostport;
  Result := Host <> '';
end;

{ ---- TSSEParser --------------------------------------------------------- }

procedure TSSEParser.Reset;
begin
  FBuf := ''; FEvent := ''; FData := ''; FId := ''; FHasData := False;
end;

procedure TSSEParser.Dispatch;
var name, data: string;
begin
  if not FHasData then
  begin
    // a lone `id:` with no data still updates LastId but emits nothing
    FEvent := ''; Exit;
  end;
  if FEvent <> '' then name := FEvent else name := 'message';
  data := FData;
  if (data <> '') and (data[Length(data)] = #10) then Delete(data, Length(data), 1);
  if Assigned(OnEvent) then OnEvent(name, data, LastId);
  FEvent := ''; FData := ''; FHasData := False;
end;

procedure TSSEParser.HandleLine(const Line: string);
var field, value: string; c: Integer;
begin
  if Line = '' then begin Dispatch; Exit; end;       // blank line ends an event
  if Line[1] = ':' then Exit;                          // comment
  c := Pos(':', Line);
  if c = 0 then begin field := Line; value := ''; end
  else
  begin
    field := Copy(Line, 1, c - 1);
    value := Copy(Line, c + 1, MaxInt);
    if (value <> '') and (value[1] = ' ') then Delete(value, 1, 1);  // one leading space
  end;
  if field = 'event' then FEvent := value
  else if field = 'data' then begin FData := FData + value + #10; FHasData := True; end
  else if field = 'id' then begin FId := value; LastId := value; end
  else if field = 'retry' then RetryMs := StrToIntDef(value, RetryMs);
end;

procedure TSSEParser.Feed(const Chunk: string);
var i: Integer; line: string;
begin
  FBuf := FBuf + Chunk;
  // process complete lines (handle \n, \r\n and bare \r)
  i := 1;
  while i <= Length(FBuf) do
  begin
    if (FBuf[i] = #10) or (FBuf[i] = #13) then
    begin
      line := Copy(FBuf, 1, i - 1);
      // consume the newline (and a paired \n after \r)
      if (FBuf[i] = #13) and (i < Length(FBuf)) and (FBuf[i + 1] = #10) then Inc(i);
      Delete(FBuf, 1, i);
      HandleLine(line);
      i := 1;
    end
    else Inc(i);
  end;
end;

{ ---- TSSEThread (worker) ------------------------------------------------ }

constructor TSSEThread.Create(AOwner: TTina4SSE);
begin
  FOwner := AOwner;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TSSEThread.Execute;
var
  sock: TInetSocket; parser: TSSEParser; req, chunk: string;
  buf: array[0..4095] of Byte; n, i, headerEnd: Integer; raw: string; inBody: Boolean;
  retry: Integer;
begin
  parser := TSSEParser.Create;
  parser.OnEvent := FOwner.Enqueue;   // (name,data,id) -> owner queue
  parser.RetryMs := 3000;
  try
    while not FOwner.FStop do
    begin
      inBody := False; raw := '';
      sock := nil;
      try
        try
          if FOwner.FSecure then
            sock := TInetSocket.Create(FOwner.FHost, FOwner.FPort,
                      TSSLSocketHandler.GetDefaultHandlerClass.Create)   // TLS (needs OpenSSL)
          else
            sock := TInetSocket.Create(FOwner.FHost, FOwner.FPort);
        except
          sock := nil;
        end;
        if sock <> nil then
        begin
          req := 'GET ' + FOwner.FPath + ' HTTP/1.1'#13#10 +
                 'Host: ' + FOwner.FHost + #13#10 +
                 'Accept: text/event-stream'#13#10 +
                 'Cache-Control: no-cache'#13#10;
          if FOwner.FLastId <> '' then req := req + 'Last-Event-ID: ' + FOwner.FLastId + #13#10;
          req := req + 'Connection: keep-alive'#13#10#13#10;
          sock.Write(req[1], Length(req));
          while not FOwner.FStop do
          begin
            n := sock.Read(buf, SizeOf(buf));
            if n <= 0 then Break;              // server closed / error → reconnect
            SetString(chunk, PAnsiChar(@buf[0]), n);
            if not inBody then
            begin
              raw := raw + chunk;
              headerEnd := Pos(#13#10#13#10, raw);
              if headerEnd > 0 then
              begin
                inBody := True;
                parser.Feed(Copy(raw, headerEnd + 4, MaxInt));
                raw := '';
              end;
            end
            else
              parser.Feed(chunk);
          end;
        end;
      finally
        if sock <> nil then sock.Free;
      end;
      if FOwner.FStop then Break;
      // reconnect after the retry interval (Last-Event-ID carried in FOwner)
      FOwner.FLastId := parser.LastId;
      retry := parser.RetryMs; if retry < 500 then retry := 500;
      i := 0;
      while (i < retry) and (not FOwner.FStop) do begin Sleep(50); Inc(i, 50); end;
    end;
  finally
    parser.Free;
  end;
end;

{ ---- TTina4SSE ---------------------------------------------------------- }

constructor TTina4SSE.Create(const Url: string);
begin
  FUrl := Url;
  ParseHttpUrl(Url, FHost, FPort, FPath);
  FSecure := LowerCase(Copy(Trim(Url), 1, 6)) = 'https:';
  FLock := TCriticalSection.Create;
end;

destructor TTina4SSE.Destroy;
begin
  Close;
  FLock.Free;
  inherited Destroy;
end;

procedure TTina4SSE.Enqueue(const EventName, Data, Id: string);
var n: Integer;
begin
  FLock.Enter;
  try
    n := Length(FQueue); SetLength(FQueue, n + 1);
    FQueue[n].EventName := EventName; FQueue[n].Data := Data; FQueue[n].Id := Id;
  finally
    FLock.Leave;
  end;
end;

procedure TTina4SSE.Open;
begin
  if FThread <> nil then Exit;
  FStop := False;
  FThread := TSSEThread.Create(Self);
end;

procedure TTina4SSE.Close;
begin
  FStop := True;
  if FThread <> nil then
  begin
    FThread.WaitFor;
    FThread.Free;
    FThread := nil;
  end;
end;

procedure TTina4SSE.Drain;
var items: array of TSSEQueued; i: Integer;
begin
  FLock.Enter;
  try
    items := FQueue; FQueue := nil;
  finally
    FLock.Leave;
  end;
  for i := 0 to High(items) do
    if Assigned(OnEvent) then OnEvent(items[i].EventName, items[i].Data, items[i].Id);
end;

end.
