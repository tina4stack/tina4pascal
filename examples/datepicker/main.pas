program main;

{ Native calendar date picker demo. Snapshot mode drives it: closed → tap the
  field to open the calendar → tap a day → snapshot each state.
  Run: tina4pascal dev examples/datepicker    |    ./main --snap                 }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  Tina4RenderBackend, Tina4ShellCocoa, Tina4Interact;

const W = 460; H = 620;
type
  TApp = class
    Shell: TCocoaShell; Pressed, Snap: Boolean; Step: Integer;
    procedure Paint(C: TTina4Canvas; PW, PH: Single);
    procedure Down(X, Y: Single); procedure Move(X, Y: Single); procedure Up(X, Y: Single);
    procedure Tick;
  end;
procedure TApp.Paint(C: TTina4Canvas; PW, PH: Single); begin TinaFrame(Round(PW), Round(PH), 1); end;
procedure TApp.Down(X, Y: Single); begin Pressed := True; TinaTouch(0, X, Y); Shell.Invalidate; end;
procedure TApp.Move(X, Y: Single); begin if Pressed then begin TinaTouch(2, X, Y); Shell.Invalidate; end; end;
procedure TApp.Up(X, Y: Single);   begin Pressed := False; TinaTouch(1, X, Y); Shell.Invalidate; end;
procedure TApp.Tick;
begin
  if not Snap then Exit;
  Inc(Step);
  if Step = 1 then begin TinaFrame(W,H,1); Shell.Snapshot('dp-closed.png'); end
  else if Step = 2 then begin TinaTouch(0,120,110); TinaTouch(1,120,110); end   // tap field → open
  else if Step = 3 then begin TinaFrame(W,H,1); Shell.Snapshot('dp-open.png'); end
  else if Step = 4 then begin TinaTouch(0,230,300); TinaTouch(1,230,300); end   // tap a day
  else if Step = 5 then begin TinaFrame(W,H,1); Shell.Snapshot('dp-picked.png'); Shell.Quit; end;
end;

function LoadPage: string;
var f: TStringList; p: string;
begin
  p := ExtractFilePath(ParamStr(0)) + 'page.html';
  if not FileExists(p) then p := 'page.html';
  f := TStringList.Create;
  try f.LoadFromFile(p); Result := f.Text; finally f.Free; end;
end;

var App: TApp;
begin
  App := TApp.Create;
  App.Snap := (ParamCount >= 1) and (ParamStr(1) = '--snap');
  App.Shell := TCocoaShell.Create;
  App.Shell.OnPaint := App.Paint;
  App.Shell.OnMouseDown := App.Down; App.Shell.OnMouseDrag := App.Move; App.Shell.OnMouseUp := App.Up;
  App.Shell.OnTick := App.Tick;
  App.Shell.Initialize(W, H, 'Tina4 · Date picker');
  TinaInit(App.Shell.GetMeasuringCanvas);
  TinaSetHtml(LoadPage);
  if App.Snap then App.Shell.StartTicker(120);
  App.Shell.Run;
end.
