program main;

{ Headless stress harness: reproduces "crashes after spamming the buttons".
  Drives the shared engine directly — no window — spamming tap-down/up on the
  button and pumping HTTP, exactly like a user hammering it. Built with -gh so
  heaptrc flags any use-after-free / double-free the moment it happens.

  Uses the Cocoa MEASURING canvas for text metrics (layout only, no drawing).  }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  Tina4RenderBackend, Tina4ShellCocoa, Tina4Interact, Tina4Http, Tina4HttpCocoa;

const
  W = 420; H = 700;

type
  { Delivers instantly on the same thread, so every tap's request completes on
    the next pump — exercises OnHttpResult → SetById → relayout under real load. }
  TInstantBackend = class(TTina4HttpBackend)
    procedure Send(const Req: TTina4HttpRequest); override;
  end;

procedure TInstantBackend.Send(const Req: TTina4HttpRequest);
var r: TTina4HttpResponse;
begin
  r.Id := Req.Id; r.Url := Req.Url; r.Status := 200;
  r.Body := '{ "url": "' + Req.Url + '", "n": 12345 }';
  r.ContentType := 'application/json'; r.Error := '';
  HttpDeliver(r);
end;

var
  shell: TCocoaShell;
  i, r: Integer;
  page: TStringList;
  html: string;
begin
  shell := TCocoaShell.Create;
  shell.Initialize(W, H, 'stress');           // real canvas for measuring
  TinaInit(shell.GetMeasuringCanvas);
  SetHttpBackend(TInstantBackend.Create);      // instant completion, full path

  page := TStringList.Create;
  page.LoadFromFile(ExtractFilePath(ParamStr(0)) + 'page.html');
  html := page.Text; page.Free;
  TinaSetHtml(html);
  TinaFrame(W, H, 1);                          // build layout once

  Writeln('spamming taps…');
  for i := 1 to 2000 do
  begin
    // hammer the button at ~(48, 44) — down then up = a tap
    TinaTouch(0, 48, 44);
    TinaTouch(1, 48, 44);
    r := HttpPump;                             // deliver the completion every tap
    TinaFrame(W, H, 1);                        // relayout+repaint like a frame
    if (i mod 250) = 0 then Writeln('  ', i, ' taps, pending=', HttpPending, ' delivered=', r);
  end;

  // drain the tail
  for i := 1 to 60 do begin HttpPump; TinaFrame(W, H, 1); Sleep(20); end;
  Writeln('survived 2000 taps. pending=', HttpPending);
  Writeln('OK');
end.
