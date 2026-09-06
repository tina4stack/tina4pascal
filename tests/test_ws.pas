program test_ws;
{ Deterministic tests for the WebSocket frame codec (no sockets). }
{$mode delphi}{$H+}

uses SysUtils, Classes, Tina4WebSocket;

type
  TCap = class
    Msgs: TStringList;
    CtrlOp: Integer;
    constructor Create;
    procedure OnMsg(const Text: string);
    procedure OnCtrl(Opcode: Byte; const Payload: string);
  end;

constructor TCap.Create; begin Msgs := TStringList.Create; CtrlOp := -1; end;
procedure TCap.OnMsg(const Text: string); begin Msgs.Add(Text); end;
procedure TCap.OnCtrl(Opcode: Byte; const Payload: string); begin CtrlOp := Opcode; end;

var Fails: Integer = 0; Total: Integer = 0;
procedure Check(Cond: Boolean; const Msg: string);
begin
  Inc(Total);
  if Cond then WriteLn('  ok   ', Msg) else begin WriteLn('  FAIL ', Msg); Inc(Fails); end;
end;

function Bytes(const a: array of Integer): string;
var i: Integer;
begin Result := ''; for i := 0 to High(a) do Result := Result + Chr(a[i] and $FF); end;

var d: TWSDecoder; c: TCap; port: Word; host, path: string; big, framed: string; i: Integer;
begin
  WriteLn('=== WebSocket frame codec ===');

  // 1. masked client encode -> decode roundtrip
  c := TCap.Create; d := TWSDecoder.Create; d.OnMessage := c.OnMsg;
  d.Feed(WSEncodeFrame(WS_TEXT, 'Hello', True));
  Check((c.Msgs.Count = 1) and (c.Msgs[0] = 'Hello'), 'masked text roundtrip -> "Hello"');
  d.Free; c.Free;

  // 2. decode a known unmasked server text frame: 0x81 0x05 H e l l o
  c := TCap.Create; d := TWSDecoder.Create; d.OnMessage := c.OnMsg;
  d.Feed(Bytes([$81, $05, $48, $65, $6C, $6C, $6F]));
  Check((c.Msgs.Count = 1) and (c.Msgs[0] = 'Hello'), 'unmasked server frame decodes "Hello"');
  d.Free; c.Free;

  // 3. fragmentation: text(fin=0,"Hel") + continuation(fin=1,"lo")
  c := TCap.Create; d := TWSDecoder.Create; d.OnMessage := c.OnMsg;
  d.Feed(Bytes([$01, $03, $48, $65, $6C]));   // opcode text, FIN=0
  d.Feed(Bytes([$80, $02, $6C, $6F]));        // opcode cont, FIN=1
  Check((c.Msgs.Count = 1) and (c.Msgs[0] = 'Hello'), 'fragmented message reassembled');
  d.Free; c.Free;

  // 4. control frame: ping (0x89) with payload
  c := TCap.Create; d := TWSDecoder.Create; d.OnMessage := c.OnMsg; d.OnControl := c.OnCtrl;
  d.Feed(Bytes([$89, $02, $61, $62]));
  Check(c.CtrlOp = WS_PING, 'ping frame surfaces as a control');
  d.Free; c.Free;

  // 5. 16-bit length: a 200-byte masked payload roundtrips
  big := ''; for i := 1 to 200 do big := big + Chr(65 + (i mod 26));
  c := TCap.Create; d := TWSDecoder.Create; d.OnMessage := c.OnMsg;
  d.Feed(WSEncodeFrame(WS_TEXT, big, True));
  Check((c.Msgs.Count = 1) and (c.Msgs[0] = big), '16-bit length (200 bytes) roundtrip');
  d.Free; c.Free;

  // 6. byte-at-a-time delivery parses identically
  c := TCap.Create; d := TWSDecoder.Create; d.OnMessage := c.OnMsg;
  framed := WSEncodeFrame(WS_TEXT, 'stream', True);
  for i := 1 to Length(framed) do d.Feed(framed[i]);
  Check((c.Msgs.Count = 1) and (c.Msgs[0] = 'stream'), 'byte-at-a-time feed parses identically');
  d.Free; c.Free;

  WriteLn('=== URL parsing ===');
  Check(ParseWsUrl('ws://localhost:9001/chat', host, port, path) and (host='localhost') and (port=9001) and (path='/chat'), 'ws://host:port/path');
  Check(ParseWsUrl('wss://s/ep', host, port, path) and (port=443), 'wss default port 443');

  WriteLn;
  if Fails = 0 then WriteLn('ALL ', Total, ' WS TESTS PASS')
  else WriteLn(Fails, ' of ', Total, ' FAILED');
  Halt(Ord(Fails <> 0));
end.
