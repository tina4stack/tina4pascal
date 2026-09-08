unit Tina4Live;

{ Declarative live-data binding for the HTML app model — the "reactive surface".

  Registers HTML actions that connect an SSE or WebSocket stream and route each
  message to the DOM with zero Pascal glue:

    <button onclick="sse.connect('http://host/stream', 'ticker')">subscribe</button>
    <button onclick="ws.connect('ws://host/socket', 'log', 'append')">connect</button>
    <input id="msg"><button onclick="ws.send('#msg')">send</button>
    <button onclick="live.close()">disconnect</button>

  Message routing (per incoming message):
    - JSON object  -> each top-level field updates the element whose id == the
      key (a "price"/"chg" object fills #price and #chg). One stream drives a
      whole UI, declaratively, by id.
    - otherwise (or no field matched) -> the whole message goes to the connect
      target element: replaces its text, or with mode 'append' adds a child line
      (chat/log).

  Two-way: `ws.send('literal')` sends a literal; `ws.send('#id')` sends the value
  of the input with that id over the most-recently-opened WebSocket.

  Connections run on worker threads; the host pumps them by calling LiveDrain from
  its ticker (the same main-thread pump used for momentum/caret), so every handler
  runs on the UI thread and may safely touch the DOM.

  Threading note: a host that links this unit must pull in a thread driver
  (`cthreads` first in the program uses on Unix) for the SSE/WS worker threads. }

{$mode delphi}{$H+}

interface

{ Register sse.connect / ws.connect / ws.send / live.close with Tina4Events. }
procedure RegisterLiveActions;

{ Route one incoming message against the current DOM (BuiltinsRoot): a JSON
  object updates elements by id (field name == id); otherwise the whole message
  goes to Target (replace, or append a child line when AppendMode). Marks the
  DOM dirty. The transport handlers call this; exposed for tests. }
procedure RouteMessage(const Target, Text: string; AppendMode: Boolean);

{ Fire any queued messages from every open connection onto their bound DOM
  elements (UI thread). Call from the shell ticker each frame. }
procedure LiveDrain;

{ Close and free every live connection (e.g. on document teardown). }
procedure CloseAllLive;

implementation

uses
  SysUtils, Classes, fpjson, jsonparser,
  Tina4HTMLDom, Tina4Events, Tina4Builtins, Tina4SSE, Tina4WebSocket;

type
  { one bound connection: a stream + the element id its whole-message text
    updates, plus whether that update appends (log) or replaces }
  TLiveConn = class
    Target: string;
    Append: Boolean;
    SSE: TTina4SSE;
    WS: TTina4WebSocketClient;
    procedure Apply(const Text: string);
    procedure OnSSE(const EventName, Data, Id: string);
    procedure OnWS(const Text: string);
  end;

var
  GConns: array of TLiveConn;

{ Append a message as a new child line under Target (chat/log), rather than
  replacing its text. The line is a plain <div> holding a #text node. }
procedure AppendLine(Target: THTMLTag; const S: string);
var line, tx: THTMLTag;
begin
  line := THTMLTag.Create;
  line.TagName := 'div';
  line.Parent := Target;
  tx := THTMLTag.Create;
  tx.TagName := '#text';
  tx.Text := S;
  tx.Parent := line;
  line.Children.Add(tx);
  Target.Children.Add(line);
end;

{ Stringify a JSON value for display: scalars as-is, objects/arrays compact. }
function JsonValueText(D: TJSONData): string;
begin
  if D = nil then Exit('');
  case D.JSONType of
    jtString, jtNumber: Result := D.AsString;
    jtBoolean: Result := D.AsJSON;   // 'true'/'false' lowercase (JSON spec), not Pascal 'True'
    jtNull: Result := '';
  else
    Result := D.AsJSON;   // nested object/array -> compact JSON
  end;
end;

{ Route a JSON-object message to elements by id (id == field name). Returns True
  if the text parsed as a JSON object AND at least one field matched an element. }
function RouteJson(const Text: string): Boolean;
var d: TJSONData; o: TJSONObject; i: Integer; el: THTMLTag;
begin
  Result := False;
  d := nil;
  try
    try d := GetJSON(Text) except d := nil end;
    if (d = nil) or not (d is TJSONObject) then Exit;
    o := TJSONObject(d);
    for i := 0 to o.Count - 1 do
    begin
      el := FindById(BuiltinsRoot, o.Names[i]);
      if el <> nil then
      begin
        SetElementText(el, JsonValueText(o.Items[i]));
        Result := True;
      end;
    end;
  finally
    d.Free;
  end;
end;

procedure RouteMessage(const Target, Text: string; AppendMode: Boolean);
var el: THTMLTag;
begin
  if not RouteJson(Text) then        // JSON object -> by-id field routing
  begin                              // plain text (or no field matched) -> target
    el := FindById(BuiltinsRoot, Target);
    if el <> nil then
      if AppendMode then AppendLine(el, Text) else SetElementText(el, Text);
  end;
  BuiltinsDirty := True;
end;

procedure TLiveConn.Apply(const Text: string);
begin RouteMessage(Target, Text, Append); end;

procedure TLiveConn.OnSSE(const EventName, Data, Id: string);
begin Apply(Data); end;

procedure TLiveConn.OnWS(const Text: string);
begin Apply(Text); end;

{ Split "'a', 'b', 'c'" into its top-level comma-separated, unquoted parts. }
function SplitArgs(const Args: string): TArray<string>;
var s: string; i, start, depth: Integer; inq: Char;
  procedure Push(const Raw: string);
  var n: Integer;
  begin n := Length(Result); SetLength(Result, n + 1); Result[n] := Unquote(Trim(Raw)); end;
begin
  SetLength(Result, 0);
  s := Trim(Args);
  if s = '' then Exit;
  start := 1; depth := 0; inq := #0;
  for i := 1 to Length(s) do
  begin
    if inq <> #0 then begin if s[i] = inq then inq := #0; end
    else if (s[i] = '''') or (s[i] = '"') then inq := s[i]
    else if s[i] = '(' then Inc(depth)
    else if s[i] = ')' then Dec(depth)
    else if (s[i] = ',') and (depth = 0) then
    begin Push(Copy(s, start, i - start)); start := i + 1; end;
  end;
  Push(Copy(s, start, MaxInt));
end;

procedure Track(C: TLiveConn);
var n: Integer;
begin n := Length(GConns); SetLength(GConns, n + 1); GConns[n] := C; end;

{ Read the value an input/element carries, for ws.send('#id'): the 'value'
  attribute (inputs), else the element's first text node. }
function ElementValue(const Id: string): string;
var el, c: THTMLTag; i: Integer;
begin
  Result := '';
  el := FindById(BuiltinsRoot, Id);
  if el = nil then Exit;
  Result := el.GetAttribute('value');
  if Result <> '' then Exit;
  for i := 0 to el.Children.Count - 1 do
  begin
    c := el.Children[i];
    if c.TagName = '#text' then Exit(c.Text);
  end;
end;

procedure ActSSEConnect(const Args: string);
var a: TArray<string>; c: TLiveConn;
begin
  a := SplitArgs(Args);
  if (Length(a) < 1) or (a[0] = '') then Exit;
  c := TLiveConn.Create;
  if Length(a) >= 2 then c.Target := a[1];
  c.Append := (Length(a) >= 3) and SameText(a[2], 'append');
  c.SSE := TTina4SSE.Create(a[0]);
  c.SSE.OnEvent := c.OnSSE;
  c.SSE.Open;
  Track(c);
end;

procedure ActWSConnect(const Args: string);
var a: TArray<string>; c: TLiveConn;
begin
  a := SplitArgs(Args);
  if (Length(a) < 1) or (a[0] = '') then Exit;
  c := TLiveConn.Create;
  if Length(a) >= 2 then c.Target := a[1];
  c.Append := (Length(a) >= 3) and SameText(a[2], 'append');
  c.WS := TTina4WebSocketClient.Create(a[0]);
  c.WS.OnMessage := c.OnWS;
  c.WS.Connect;
  Track(c);
end;

{ ws.send('literal') or ws.send('#inputId') → most-recently-opened WebSocket. }
procedure ActWSSend(const Args: string);
var a: TArray<string>; msg: string; i: Integer;
begin
  a := SplitArgs(Args);
  if Length(a) < 1 then Exit;
  msg := a[0];
  if (msg <> '') and (msg[1] = '#') then msg := ElementValue(Copy(msg, 2, MaxInt));
  for i := High(GConns) downto 0 do
    if GConns[i].WS <> nil then begin GConns[i].WS.Send(msg); Break; end;
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
  RegisterAction('ws.send', @ActWSSend);
  RegisterAction('live.close', @ActLiveClose);
end;

end.
