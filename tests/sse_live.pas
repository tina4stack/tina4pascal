program sse_live;
{ Live SSE smoke test: connect to a local text/event-stream server, drain
  events on the "UI thread" for a few seconds, print them. Exit 0 if >=1 event. }
{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Tina4SSE;

type
  TRec = class
    Count: Integer;
    procedure OnEvent(const EventName, Data, Id: string);
  end;

procedure TRec.OnEvent(const EventName, Data, Id: string);
begin
  Inc(Count);
  WriteLn(Format('  event #%d  name=%-8s id=%-3s data=%s', [Count, EventName, Id, Data]));
end;

var sse: TTina4SSE; rec: TRec; i: Integer; url: string;
begin
  if ParamCount >= 1 then url := ParamStr(1) else url := 'http://127.0.0.1:8099/stream';
  WriteLn('connecting to ', url);
  rec := TRec.Create;
  sse := TTina4SSE.Create(url);
  sse.OnEvent := rec.OnEvent;
  sse.Open;
  // pump like a shell ticker would (~50ms) for 3 seconds
  for i := 1 to 60 do begin sse.Drain; Sleep(50); end;
  sse.Close;
  sse.Free;
  WriteLn('received ', rec.Count, ' events');
  Halt(Ord(rec.Count = 0));
end.
