program test_sse;
{ Deterministic tests for the SSE line-protocol parser (no sockets). }
{$mode delphi}{$H+}

uses SysUtils, Classes, Tina4SSE;

type
  TCollector = class
    Names, Datas, Ids: TStringList;
    constructor Create;
    procedure OnEvent(const EventName, Data, Id: string);
  end;

constructor TCollector.Create;
begin
  Names := TStringList.Create; Datas := TStringList.Create; Ids := TStringList.Create;
end;

procedure TCollector.OnEvent(const EventName, Data, Id: string);
begin
  Names.Add(EventName); Datas.Add(Data); Ids.Add(Id);
end;

var Fails: Integer = 0; Total: Integer = 0;

procedure Check(Cond: Boolean; const Msg: string);
begin
  Inc(Total);
  if Cond then WriteLn('  ok   ', Msg)
  else begin WriteLn('  FAIL ', Msg); Inc(Fails); end;
end;

procedure Run(const Feed: string; out C: TCollector);
var p: TSSEParser;
begin
  C := TCollector.Create;
  p := TSSEParser.Create;
  try
    p.OnEvent := C.OnEvent;
    p.Feed(Feed);
  finally
    p.Free;
  end;
end;

var C, col: TCollector; po: Word; host, path: string; ok: Boolean;
    pp: TSSEParser; ss: string; ii: Integer;
begin
  WriteLn('=== SSE parser ===');

  Run('data: hello'#10#10, C);
  Check((C.Names.Count = 1) and (C.Names[0] = 'message') and (C.Datas[0] = 'hello'),
    'simple data -> message/"hello"');
  C.Free;

  Run('event: tick'#10'data: 42'#10#10, C);
  Check((C.Names.Count = 1) and (C.Names[0] = 'tick') and (C.Datas[0] = '42'),
    'named event tick/"42"');
  C.Free;

  Run('data: a'#10'data: b'#10#10, C);
  Check((C.Names.Count = 1) and (C.Datas[0] = 'a'#10'b'), 'multi-line data joined with LF');
  C.Free;

  Run('id: 7'#10'data: x'#10#10, C);
  Check((C.Names.Count = 1) and (C.Ids[0] = '7'), 'id field carried on the event');
  C.Free;

  Run(': keep-alive comment'#10'data: y'#10#10, C);
  Check((C.Names.Count = 1) and (C.Datas[0] = 'y'), 'comment line ignored');
  C.Free;

  // two events in one feed, CRLF line endings
  Run('data: one'#13#10#13#10'data: two'#13#10#13#10, C);
  Check((C.Names.Count = 2) and (C.Datas[0] = 'one') and (C.Datas[1] = 'two'),
    'two events, CRLF endings');
  C.Free;

  // a lone id: with no data emits nothing (but no crash)
  Run('id: 9'#10#10'data: z'#10#10, C);
  Check((C.Names.Count = 1) and (C.Datas[0] = 'z'), 'blank event with only id emits nothing');
  C.Free;

  // chunked delivery: the same stream fed one byte at a time must parse the same
  col := TCollector.Create;
  pp := TSSEParser.Create;
  ss := 'event: split'#10'data: abc'#10#10;
  pp.OnEvent := col.OnEvent;
  for ii := 1 to Length(ss) do pp.Feed(ss[ii]);
  Check((col.Names.Count = 1) and (col.Names[0] = 'split') and (col.Datas[0] = 'abc'),
    'byte-at-a-time feed parses identically');
  pp.Free; col.Free;

  WriteLn('=== URL parsing ===');
  ok := ParseHttpUrl('http://localhost:8099/stream', host, po, path);
  Check(ok and (host = 'localhost') and (po = 8099) and (path = '/stream'), 'http://host:port/path');
  ok := ParseHttpUrl('http://example.com/feed', host, po, path);
  Check(ok and (host = 'example.com') and (po = 80) and (path = '/feed'), 'default port 80');
  ok := ParseHttpUrl('https://s.example.com/e', host, po, path);
  Check(ok and (po = 443), 'https default port 443');

  WriteLn;
  if Fails = 0 then WriteLn('ALL ', Total, ' SSE TESTS PASS')
  else WriteLn(Fails, ' of ', Total, ' FAILED');
  Halt(Ord(Fails <> 0));
end.
