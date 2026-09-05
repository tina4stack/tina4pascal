program main;

{ Desktop HTTP demo: the shared engine + the FPC HTTP backend (fphttpclient over
  our bundled OpenSSL 1.1.1 — proper Pascal TLS, no Homebrew). Tap a button, the
  engine's Http:Get action fetches the URL and drops the reply into #result.

  Run:  tina4pascal dev examples/httpdemo                                        }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  Tina4RenderBackend, Tina4ShellCocoa, Tina4Interact, Tina4Http, Tina4HttpCocoa;

type
  TApp = class
    Shell: TCocoaShell;
    Pressed: Boolean;
    procedure Paint(C: TTina4Canvas; W, H: Single);
    procedure Down(X, Y: Single); procedure Move(X, Y: Single); procedure Up(X, Y: Single);
    procedure Scroll(X, Y, DX, DY: Single);
    procedure Tick;
  end;

procedure TApp.Paint(C: TTina4Canvas; W, H: Single); begin TinaFrame(Round(W), Round(H), 1); end;
procedure TApp.Down(X, Y: Single); begin Pressed := True; TinaTouch(0, X, Y); Shell.Invalidate; end;
procedure TApp.Move(X, Y: Single); begin if Pressed then begin TinaTouch(2, X, Y); Shell.Invalidate; end; end;
procedure TApp.Up(X, Y: Single);   begin Pressed := False; TinaTouch(1, X, Y); Shell.Invalidate; end;
procedure TApp.Scroll(X, Y, DX, DY: Single); begin TinaScrollBy(X, Y, DX, DY); Shell.Invalidate; end;
procedure TApp.Tick; begin HttpPump; Shell.Invalidate; end;   // deliver responses

function LoadPage: string;
var f: TStringList;
begin
  f := TStringList.Create;
  try f.LoadFromFile(ExtractFilePath(ParamStr(0)) + 'page.html'); Result := f.Text;
  finally f.Free; end;
end;

var App: TApp;
begin
  App := TApp.Create;
  App.Shell := TCocoaShell.Create;
  App.Shell.OnPaint := App.Paint;
  App.Shell.OnMouseDown := App.Down; App.Shell.OnMouseDrag := App.Move;
  App.Shell.OnMouseUp := App.Up; App.Shell.OnScroll := App.Scroll;
  App.Shell.OnTick := App.Tick;

  App.Shell.Initialize(420, 600, 'Tina4 · HTTP');
  TinaInit(App.Shell.GetMeasuringCanvas);
  InstallCocoaHttp;                     // FIRST PRIZE: OS TLS (NSURLSession)
  TinaSetHtml(LoadPage);

  if (ParamCount >= 2) and (ParamStr(1) = '--snapshot') then App.Shell.SnapshotPath := ParamStr(2)
  else App.Shell.StartTicker(100);      // pump HTTP results ~10×/s
  App.Shell.Run;
end.
