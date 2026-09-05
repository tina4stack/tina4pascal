program main;

{ Proves <include src> end to end: sets a default auth header, loads a page with
  an <include> to a protected URL, lets the engine fetch + splice the snippet,
  then snapshots. httpbin.org/headers echoes the request headers, so the injected
  card shows our Authorization — auth travelled with the include.

  Run:  (built by the test below) ./main --out inc.png                          }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  Tina4RenderBackend, Tina4ShellCocoa, Tina4Interact, Tina4Http, Tina4HttpCocoa;

type
  TApp = class
    Shell: TCocoaShell;
    OutPath: string;
    SawPending: Boolean;
    Settle, Ticks: Integer;
    procedure Paint(C: TTina4Canvas; W, H: Single);
    procedure Tick;
  end;

procedure TApp.Paint(C: TTina4Canvas; W, H: Single);
begin
  TinaFrame(Round(W), Round(H), 1);
end;

procedure TApp.Tick;
begin
  HttpPump;                          // deliver + splice the include
  Shell.Invalidate;
  Inc(Ticks);
  if HttpPending > 0 then SawPending := True;
  if (SawPending and (HttpPending = 0)) then Inc(Settle);
  // once the fetch is in and a couple of frames have laid it out, snapshot + quit
  if ((Settle > 3) or (Ticks > 120)) then
  begin
    Shell.Snapshot(OutPath);
    Shell.Quit;
  end;
end;

function LoadPage: string;
var f: TStringList;
begin
  f := TStringList.Create;
  try f.LoadFromFile(ExtractFilePath(ParamStr(0)) + 'page.html'); Result := f.Text;
  finally f.Free; end;
end;

var App: TApp; i: Integer;
begin
  App := TApp.Create;
  App.OutPath := 'inc.png';
  for i := 1 to ParamCount - 1 do
    if ParamStr(i) = '--out' then App.OutPath := ParamStr(i + 1);

  App.Shell := TCocoaShell.Create;
  App.Shell.OnPaint := App.Paint;
  App.Shell.OnTick := App.Tick;
  App.Shell.Initialize(430, 640, 'Tina4 · include');
  TinaInit(App.Shell.GetMeasuringCanvas);
  InstallCocoaHttp;                                  // OS TLS
  TinaSetHeader('Authorization', 'Bearer TINA4-DEFAULT-SECRET'); // global default
  TinaSetHtml(LoadPage);
  App.Shell.StartTicker(100);
  App.Shell.Run;
end.
