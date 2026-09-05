program press;

{ Snapshots a button while it is HELD DOWN (touch-down, no release) so we can see
  whether the :active press darken actually paints. Isolates the engine paint
  from any iOS timing. }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  Tina4RenderBackend, Tina4ShellCocoa, Tina4Interact, Tina4Http, Tina4HttpCocoa;

const W = 300; H = 160;
type
  TApp = class
    Shell: TCocoaShell; Done: Boolean;
    procedure Paint(C: TTina4Canvas; PW, PH: Single);
    procedure Tick;
  end;
procedure TApp.Paint(C: TTina4Canvas; PW, PH: Single); begin TinaFrame(Round(PW), Round(PH), 1); end;
procedure TApp.Tick;
begin
  if Done then Exit;
  Done := True;
  TinaFrame(W, H, 1);            // ensure layout exists (build GRoot) first
  TinaTouch(0, 55, 45);          // press the button and HOLD (no up)
  TinaFrame(W, H, 1);            // REPAINT with the pressed state active
  Shell.Snapshot('press.png');
  Shell.Quit;
end;

var App: TApp; p: TStringList; html: string;
begin
  App := TApp.Create;
  App.Shell := TCocoaShell.Create;
  App.Shell.OnPaint := App.Paint; App.Shell.OnTick := App.Tick;
  App.Shell.Initialize(W, H, 'press');
  TinaInit(App.Shell.GetMeasuringCanvas);
  InstallCocoaHttp;
  p := TStringList.Create; p.LoadFromFile(ExtractFilePath(ParamStr(0)) + 'page.html');
  html := p.Text; p.Free;
  TinaSetHtml(html);
  App.Shell.StartTicker(60);
  App.Shell.Run;
end.
