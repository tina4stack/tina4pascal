unit Tina4WebSocket;

{ WebSocket client (RFC 6455) for the Tina4 native data layer.

  Three pieces, matching the SSE unit's shape:

    • WSEncodeFrame / TWSDecoder — the pure frame codec (FIN, opcodes, client
      masking, 7/16/64-bit lengths, fragmentation reassembly). No I/O; unit-tested.

    • The handshake — a GET Upgrade with a random Sec-WebSocket-Key; the server's
      101 + Sec-WebSocket-Accept is validated against sha1(key+GUID).

    • TTina4WebSocketClient — a worker thread (FPC ssockets) that handshakes and
      reads frames, auto-answers ping with pong, and queues text messages
      thread-safely; the UI thread calls Drain (from the shell ticker) to fire
      OnMessage on itself so handlers can touch the DOM and repaint.

  v1 is ws:// (portable via ssockets on every FPC target). wss:// (TLS) is next. }

{$mode delphi}{$H+}

interface

uses SysUtils, Classes, SyncObjs, ssockets, sslsockets, opensslsockets, base64, sha1;

const
  WS_TEXT = $1; WS_BINARY = $2; WS_CLOSE = $8; WS_PING = $9; WS_PONG = $A;

type
  TWSMessageProc = procedure(const Text: string) of object;
  TWSNotifyProc  = procedure of object;

  { streaming frame decoder: Feed bytes; fires OnMessage per complete text
    message and OnControl for close/ping/pong. }
  TWSDecoder = class
  private
    FBuf: string;
    FMsg: string;        // reassembled fragments
    FMsgOpcode: Byte;
  public
    OnMessage: TWSMessageProc;
    OnControl: procedure(Opcode: Byte; const Payload: string) of object;
    procedure Feed(const Chunk: string);
    procedure Reset;
  end;

  TTina4WebSocketClient = class;

  TWSThread = class(TThread)
  private
    FOwner: TTina4WebSocketClient;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TTina4WebSocketClient);
  end;

  TTina4WebSocketClient = class
  private
    FUrl, FHost, FPath: string;
    FPort: Word;
    FSecure: Boolean;            // wss:// → wrap the socket in TLS
    FThread: TWSThread;
    FSock: TInetSocket;
    FLock, FSendLock: TCriticalSection;
    FQueue: array of string;     // text messages awaiting Drain
    FStop, FOpen: Boolean;
    procedure EnqueueMsg(const Text: string);
    procedure OnCtrl(Opcode: Byte; const Payload: string);
    procedure RawSend(const Frame: string);
  public
    OnMessage: TWSMessageProc;   // fired on the UI thread from Drain
    OnOpen: TWSNotifyProc;
    OnClose: TWSNotifyProc;
    constructor Create(const Url: string);
    destructor Destroy; override;
    procedure Connect;
    procedure Send(const Text: string);
    procedure Close;
    procedure Drain;             // UI thread: fire queued messages on OnMessage
    property IsOpen: Boolean read FOpen;
  end;

{ Encode one frame (client frames are masked). Payload is a byte string. }
function WSEncodeFrame(Opcode: Byte; const Payload: string; Masked: Boolean): string;
{ Parse ws://host:port/path (wss:// sets port 443). }
function ParseWsUrl(const Url: string; out Host: string; out Port: Word; out Path: string): Boolean;

implementation

const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

{ RFC 6455 accept token: base64( sha1( clientKey + GUID ) ). }
function ComputeAccept(const Key: string): string;
var dig: TSHA1Digest; s: string;
begin
  dig := SHA1String(Key + WS_GUID);
  SetString(s, PAnsiChar(@dig[0]), SizeOf(dig));   // 20 raw digest bytes
  Result := EncodeStringBase64(s);
end;

{ Case-insensitive header value from a raw HTTP response (up to the blank line). }
function HeaderValue(const Raw, Name: string): string;
var lines: TStringArray; i, c: Integer; ln, lname: string;
begin
  Result := ''; lname := LowerCase(Name);
  lines := Raw.Split([#13#10]);
  for i := 0 to High(lines) do
  begin
    ln := lines[i]; if ln = '' then Break;
    c := Pos(':', ln);
    if (c > 0) and (LowerCase(Trim(Copy(ln, 1, c - 1))) = lname) then
      Exit(Trim(Copy(ln, c + 1, MaxInt)));
  end;
end;

function ParseWsUrl(const Url: string; out Host: string; out Port: Word; out Path: string): Boolean;
var s, hostport: string; p: Integer;
begin
  Result := False; Host := ''; Port := 80; Path := '/';
  s := Url;
  if LowerCase(Copy(s, 1, 5)) = 'ws://' then Delete(s, 1, 5)
  else if LowerCase(Copy(s, 1, 6)) = 'wss://' then begin Delete(s, 1, 6); Port := 443; end
  else if LowerCase(Copy(s, 1, 7)) = 'http://' then Delete(s, 1, 7)
  else Exit;
  p := Pos('/', s);
  if p > 0 then begin hostport := Copy(s, 1, p - 1); Path := Copy(s, p, MaxInt); end
  else begin hostport := s; Path := '/'; end;
  p := Pos(':', hostport);
  if p > 0 then begin Host := Copy(hostport, 1, p - 1); Port := StrToIntDef(Copy(hostport, p + 1, MaxInt), Port); end
  else Host := hostport;
  Result := Host <> '';
end;

function WSEncodeFrame(Opcode: Byte; const Payload: string; Masked: Boolean): string;
var n, i: Integer; mk: array[0..3] of Byte;
begin
  n := Length(Payload);
  Result := Chr($80 or (Opcode and $0F));                    // FIN + opcode
  if n <= 125 then Result := Result + Chr((Ord(Masked) shl 7) or n)
  else if n <= 65535 then
    Result := Result + Chr((Ord(Masked) shl 7) or 126) + Chr((n shr 8) and $FF) + Chr(n and $FF)
  else
  begin
    Result := Result + Chr((Ord(Masked) shl 7) or 127);
    for i := 7 downto 0 do Result := Result + Chr((Int64(n) shr (i * 8)) and $FF);
  end;
  if Masked then
  begin
    for i := 0 to 3 do mk[i] := Random(256);
    for i := 0 to 3 do Result := Result + Chr(mk[i]);
    for i := 1 to n do Result := Result + Chr(Ord(Payload[i]) xor mk[(i - 1) and 3]);
  end
  else
    Result := Result + Payload;
end;

{ ---- TWSDecoder --------------------------------------------------------- }

procedure TWSDecoder.Reset;
begin FBuf := ''; FMsg := ''; FMsgOpcode := 0; end;

procedure TWSDecoder.Feed(const Chunk: string);
var b0, b1: Byte; fin, masked: Boolean; opcode: Byte; len: Int64; pos, i, need: Integer;
    mk: array[0..3] of Byte; payload: string;
begin
  FBuf := FBuf + Chunk;
  while True do
  begin
    if Length(FBuf) < 2 then Exit;
    b0 := Ord(FBuf[1]); b1 := Ord(FBuf[2]);
    fin := (b0 and $80) <> 0; opcode := b0 and $0F;
    masked := (b1 and $80) <> 0; len := b1 and $7F; pos := 3;
    if len = 126 then
    begin
      if Length(FBuf) < 4 then Exit;
      len := (Ord(FBuf[3]) shl 8) or Ord(FBuf[4]); pos := 5;
    end
    else if len = 127 then
    begin
      if Length(FBuf) < 10 then Exit;
      len := 0; for i := 0 to 7 do len := (len shl 8) or Ord(FBuf[3 + i]); pos := 11;
    end;
    if masked then
    begin
      if Length(FBuf) < pos + 3 then Exit;
      for i := 0 to 3 do mk[i] := Ord(FBuf[pos + i]); Inc(pos, 4);
    end;
    need := (pos - 1) + len;
    if Length(FBuf) < need then Exit;                        // incomplete frame
    payload := Copy(FBuf, pos, len);
    if masked then
      for i := 1 to Length(payload) do payload[i] := Chr(Ord(payload[i]) xor mk[(i - 1) and 3]);
    Delete(FBuf, 1, need);
    // control frames pass straight through
    if opcode >= $8 then
    begin
      if Assigned(OnControl) then OnControl(opcode, payload);
      Continue;
    end;
    // data frames: reassemble fragments (opcode 0 = continuation)
    if opcode <> 0 then begin FMsg := payload; FMsgOpcode := opcode; end
    else FMsg := FMsg + payload;
    if fin then
    begin
      if (FMsgOpcode = WS_TEXT) and Assigned(OnMessage) then OnMessage(FMsg);
      FMsg := ''; FMsgOpcode := 0;
    end;
  end;
end;

{ ---- TWSThread (worker) ------------------------------------------------- }

constructor TWSThread.Create(AOwner: TTina4WebSocketClient);
begin
  FOwner := AOwner; FreeOnTerminate := False;
  inherited Create(False);
end;

function RandKey: string;
var b: array[0..15] of Byte; i: Integer;
begin
  for i := 0 to 15 do b[i] := Random(256);
  SetString(Result, PAnsiChar(@b[0]), 16);
  Result := EncodeStringBase64(Result);
end;

procedure TWSThread.Execute;
var
  dec: TWSDecoder; key, req, raw, chunk: string;
  buf: array[0..4095] of Byte; n, he: Integer;
begin
  dec := TWSDecoder.Create;
  dec.OnMessage := FOwner.EnqueueMsg;
  dec.OnControl := FOwner.OnCtrl;
  try
    try
      if FOwner.FSecure then
        FOwner.FSock := TInetSocket.Create(FOwner.FHost, FOwner.FPort,
                          TSSLSocketHandler.GetDefaultHandlerClass.Create)   // TLS (needs OpenSSL)
      else
        FOwner.FSock := TInetSocket.Create(FOwner.FHost, FOwner.FPort);
    except
      FOwner.FSock := nil;
    end;
    if FOwner.FSock <> nil then
    begin
      key := RandKey;
      req := 'GET ' + FOwner.FPath + ' HTTP/1.1'#13#10 +
             'Host: ' + FOwner.FHost + #13#10 +
             'Upgrade: websocket'#13#10 +
             'Connection: Upgrade'#13#10 +
             'Sec-WebSocket-Key: ' + key + #13#10 +
             'Sec-WebSocket-Version: 13'#13#10#13#10;
      FOwner.FSock.Write(req[1], Length(req));
      // read the handshake response up to the blank line
      raw := '';
      while (Pos(#13#10#13#10, raw) = 0) and (not FOwner.FStop) do
      begin
        n := FOwner.FSock.Read(buf, SizeOf(buf));
        if n <= 0 then Break;
        SetString(chunk, PAnsiChar(@buf[0]), n); raw := raw + chunk;
      end;
      he := Pos(#13#10#13#10, raw);
      // require 101 Switching Protocols AND a matching Sec-WebSocket-Accept
      if (he > 0) and (Pos(' 101', raw) > 0) and
         (HeaderValue(raw, 'Sec-WebSocket-Accept') = ComputeAccept(key)) then
      begin
        FOwner.FOpen := True;
        if Assigned(FOwner.OnOpen) then FOwner.OnOpen;  // note: worker thread
        // feed any body bytes already read past the header
        if he + 3 < Length(raw) then dec.Feed(Copy(raw, he + 4, MaxInt));
        while not FOwner.FStop do
        begin
          n := FOwner.FSock.Read(buf, SizeOf(buf));
          if n <= 0 then Break;
          SetString(chunk, PAnsiChar(@buf[0]), n);
          dec.Feed(chunk);
        end;
      end;
    end;
  finally
    FOwner.FOpen := False;
    if FOwner.FSock <> nil then begin FOwner.FSock.Free; FOwner.FSock := nil; end;
    dec.Free;
  end;
end;

{ ---- TTina4WebSocketClient ---------------------------------------------- }

constructor TTina4WebSocketClient.Create(const Url: string);
begin
  FUrl := Url;
  ParseWsUrl(Url, FHost, FPort, FPath);
  FSecure := LowerCase(Copy(Trim(Url), 1, 4)) = 'wss:';
  FLock := TCriticalSection.Create;
  FSendLock := TCriticalSection.Create;
end;

destructor TTina4WebSocketClient.Destroy;
begin
  Close;
  FLock.Free; FSendLock.Free;
  inherited Destroy;
end;

procedure TTina4WebSocketClient.EnqueueMsg(const Text: string);
var n: Integer;
begin
  FLock.Enter;
  try n := Length(FQueue); SetLength(FQueue, n + 1); FQueue[n] := Text; finally FLock.Leave; end;
end;

procedure TTina4WebSocketClient.RawSend(const Frame: string);
begin
  FSendLock.Enter;
  try
    if (FSock <> nil) and (Frame <> '') then FSock.Write(Frame[1], Length(Frame));
  except
  end;
  FSendLock.Leave;
end;

procedure TTina4WebSocketClient.OnCtrl(Opcode: Byte; const Payload: string);
begin
  if Opcode = WS_PING then RawSend(WSEncodeFrame(WS_PONG, Payload, True))
  else if Opcode = WS_CLOSE then FStop := True;
end;

procedure TTina4WebSocketClient.Connect;
begin
  if FThread <> nil then Exit;
  FStop := False;
  FThread := TWSThread.Create(Self);
end;

procedure TTina4WebSocketClient.Send(const Text: string);
begin
  if FOpen then RawSend(WSEncodeFrame(WS_TEXT, Text, True));
end;

procedure TTina4WebSocketClient.Close;
begin
  if FOpen then RawSend(WSEncodeFrame(WS_CLOSE, '', True));
  FStop := True;
  if FThread <> nil then begin FThread.WaitFor; FThread.Free; FThread := nil; end;
  if Assigned(OnClose) then OnClose;
end;

procedure TTina4WebSocketClient.Drain;
var items: array of string; i: Integer;
begin
  FLock.Enter;
  try items := FQueue; FQueue := nil; finally FLock.Leave; end;
  for i := 0 to High(items) do
    if Assigned(OnMessage) then OnMessage(items[i]);
end;

end.
