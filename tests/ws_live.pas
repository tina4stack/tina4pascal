program ws_live;
{ Live WebSocket smoke test: connect to a local echo server, send a message,
  drain the echo on the "UI thread". Exit 0 if the echo came back. }
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Tina4WebSocket;

type
  TRec = class
    Got: string; Count: Integer;
    procedure OnMsg(const Text: string);
  end;

procedure TRec.OnMsg(const Text: string);
begin Got := Text; Inc(Count); WriteLn('  <- ', Text); end;

var ws: TTina4WebSocketClient; rec: TRec; i: Integer; url: string;
begin
  if ParamCount >= 1 then url := ParamStr(1) else url := 'ws://127.0.0.1:9099/';
  WriteLn('connecting to ', url);
  rec := TRec.Create;
  ws := TTina4WebSocketClient.Create(url);
  ws.OnMessage := rec.OnMsg;
  ws.Connect;
  // wait for the handshake, then send
  for i := 1 to 40 do begin if ws.IsOpen then Break; Sleep(50); end;
  if ws.IsOpen then begin WriteLn('  -> hello from tina4'); ws.Send('hello from tina4'); end
  else WriteLn('  (did not open)');
  for i := 1 to 40 do begin ws.Drain; Sleep(50); end;   // pump like a ticker
  ws.Close;
  ws.Free;
  WriteLn('received ', rec.Count, ' messages; last="', rec.Got, '"');
  Halt(Ord(rec.Got <> 'hello from tina4'));
end.
