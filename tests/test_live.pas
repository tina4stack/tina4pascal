program test_live;
{ End-to-end: an HTML sse.connect / ws.connect action binds a live stream to a
  DOM element by id; after pumping LiveDrain, the element's text is the last
  message. Needs a local SSE server (:8099) and a WS push server (:9098). }
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Tina4HTMLDom, Tina4Events, Tina4Builtins, Tina4Live;

function ElemText(Root: THTMLTag; const Id: string): string;
var el: THTMLTag; i: Integer;
begin
  Result := ''; el := FindById(Root, Id); if el = nil then Exit;
  for i := 0 to el.Children.Count - 1 do
    if el.Children[i].TagName = '#text' then Result := Result + el.Children[i].Text;
end;

var Fails: Integer = 0; Total: Integer = 0;
procedure Check(Cond: Boolean; const Msg: string);
begin Inc(Total); if Cond then WriteLn('  ok   ', Msg) else begin WriteLn('  FAIL ', Msg); Inc(Fails); end; end;

var P: THTMLParser; i: Integer; tickTxt, chatTxt: string;
begin
  P := THTMLParser.Create;
  P.Parse('<div><span id="ticker">idle</span><span id="chat">idle</span></div>');
  BuiltinsRoot := P.Root;
  RegisterLiveActions;

  WriteLn('=== sse.connect / ws.connect ===');

  DispatchAction('sse.connect(''http://127.0.0.1:8099/stream'', ''ticker'')');
  DispatchAction('ws.connect(''ws://127.0.0.1:9098/'', ''chat'')');

  // pump like a shell ticker for ~3s
  for i := 1 to 60 do begin LiveDrain; Sleep(50); end;

  tickTxt := ElemText(P.Root, 'ticker');
  chatTxt := ElemText(P.Root, 'chat');
  WriteLn('  #ticker="', tickTxt, '"   #chat="', chatTxt, '"');
  Check(Pos('count', tickTxt) > 0, 'SSE updated #ticker with a streamed value');
  Check(chatTxt = 'ws hello', 'WebSocket updated #chat with the pushed message');

  CloseAllLive;
  WriteLn;
  if Fails = 0 then WriteLn('ALL ', Total, ' LIVE TESTS PASS')
  else WriteLn(Fails, ' of ', Total, ' FAILED');
  Halt(Ord(Fails <> 0));
end.
