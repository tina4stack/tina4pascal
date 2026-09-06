unit Tina4Live;

{ Declarative live-data binding for the HTML app model — the "reactive surface".

  Registers HTML actions that connect an SSE or WebSocket stream and route each
  message to a DOM element by id, with zero Pascal glue:

    <button onclick="sse.connect('http://host/stream', 'ticker')">subscribe</button>
    <button onclick="ws.connect('ws://host/socket', 'chat')">connect</button>
    <button onclick="live.close()">disconnect</button>

  Each incoming message replaces the text of the target element (SetElementText)
  and marks the DOM dirty so the host relayouts + repaints. Connections run on
  worker threads; the host pumps them by calling LiveDrain from its ticker (the
  same main-thread pump used for momentum/caret), so every handler runs on the
  UI thread and may safely touch the DOM.

  Threading note: a host that links this unit must pull in a thread driver
  (`cthreads` first in the program uses on Unix) for the SSE/WS worker threads. }

{$mode delphi}{$H+}

interface

{ Register sse.connect / ws.connect / live.close with Tina4Events. Call once. }
procedure RegisterLiveActions;

{ Fire any queued messages from every open connection onto their bound DOM
  elements (UI thread). Call from the shell ticker each frame. }
procedure LiveDrain;

{ Close and free every live connection (e.g. on document teardown). }
procedure CloseAllLive;

implementation

uses
  SysUtils, Classes, Tina4HTMLDom, Tina4Events, Tina4Builtins, Tina4SSE, Tina4WebSocket;

type
  { one bound connection: a stream + the element id its messages update }
  TLiveConn = class
    Target: string;
    SSE: TTina4SSE;
    WS: TTina4WebSocketClient;
    procedure Apply(const Text: string);
    procedure OnSSE(const EventName, Data, Id: string);
    procedure OnWS(const Text: string);
  end;

var
  GConns: array of TLiveConn;

procedure TLiveConn.Apply(const Text: string);
var el: THTMLTag;
begin
  el := FindById(BuiltinsRoot, Target);
  if el <> nil then begin SetElementText(el, Text); BuiltinsDirty := True; end;
end;

procedure TLiveConn.OnSSE(const EventName, Data, Id: string);
begin Apply(Data); end;

procedure TLiveConn.OnWS(const Text: string);
begin Apply(Text); end;

{ split "'url', 'target'" into its two unquoted parts }
procedure TwoArgs(const Args: string; out A, B: string);
var s: string; i, depth, comma: Integer; inq: Char;
begin
  s := Trim(Args); comma := 0; depth := 0; inq := #0;
  for i := 1 to Length(s) do
  begin
    if inq <> #0 then begin if s[i] = inq then inq := #0; end
    else if (s[i] = '''') or (s[i] = '"') then inq := s[i]
    else if s[i] = '(' then Inc(depth)
    else if s[i] = ')' then Dec(depth)
    else if (s[i] = ',') and (depth = 0) then begin comma := i; Break; end;
  end;
  if comma > 0 then begin A := Unquote(Trim(Copy(s, 1, comma - 1))); B := Unquote(Trim(Copy(s, comma + 1, MaxInt))); end
  else begin A := Unquote(s); B := ''; end;
end;

procedure Track(C: TLiveConn);
var n: Integer;
begin n := Length(GConns); SetLength(GConns, n + 1); GConns[n] := C; end;

procedure ActSSEConnect(const Args: string);
var url, target: string; c: TLiveConn;
begin
  TwoArgs(Args, url, target);
  if (url = '') or (target = '') then Exit;
  c := TLiveConn.Create; c.Target := target;
  c.SSE := TTina4SSE.Create(url);
  c.SSE.OnEvent := c.OnSSE;
  c.SSE.Open;
  Track(c);
end;

procedure ActWSConnect(const Args: string);
var url, target: string; c: TLiveConn;
begin
  TwoArgs(Args, url, target);
  if (url = '') or (target = '') then Exit;
  c := TLiveConn.Create; c.Target := target;
  c.WS := TTina4WebSocketClient.Create(url);
  c.WS.OnMessage := c.OnWS;
  c.WS.Connect;
  Track(c);
end;

procedure ActLiveClose(const Args: string);
begin CloseAllLive; end;

procedure LiveDrain;
var i: Integer;
begin
  for i := 0 to High(GConns) do
  begin
    if GConns[i].SSE <> nil then GConns[i].SSE.Drain;
    if GConns[i].WS  <> nil then GConns[i].WS.Drain;
  end;
end;

procedure CloseAllLive;
var i: Integer;
begin
  for i := 0 to High(GConns) do
  begin
    if GConns[i].SSE <> nil then GConns[i].SSE.Free;
    if GConns[i].WS  <> nil then GConns[i].WS.Free;
    GConns[i].Free;
  end;
  SetLength(GConns, 0);
end;

procedure RegisterLiveActions;
begin
  RegisterAction('sse.connect', @ActSSEConnect);
  RegisterAction('ws.connect', @ActWSConnect);
  RegisterAction('live.close', @ActLiveClose);
end;

end.
