program main;

{ Template-driven Tina4 app: a Frond template (todos.twig) rendered against a
  JSON context by the SHARED engine, then laid out and painted natively. The
  same TinaRenderTemplate call drives Android / iOS / macOS. Change the context
  and call TinaRenderContext to re-render — the template-driven app model.

  Run:  tina4pascal dev examples/template   (or: fpc + run from this folder)     }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  Tina4RenderBackend, Tina4ShellCocoa, Tina4Interact;

const
  CONTEXT =
    '{"title":"Today","done":2,"tasks":[' +
    '{"text":"Wire Frond into the engine","done":true,"priority":"done"},' +
    '{"text":"Ship the macOS app","done":true},' +
    '{"text":"Native mobile HTTP (on-device HTTPS)","done":false,"priority":"next"},' +
    '{"text":"Remote CSS + <embed>","done":false}' +
    ']}';

type
  TApp = class
    Shell: TCocoaShell;
    Pressed: Boolean;
    procedure Paint(C: TTina4Canvas; W, H: Single);
    procedure Down(X, Y: Single); procedure Move(X, Y: Single); procedure Up(X, Y: Single);
    procedure Scroll(X, Y, DX, DY: Single);
  end;

procedure TApp.Paint(C: TTina4Canvas; W, H: Single);
begin TinaFrame(Round(W), Round(H), 1); end;
procedure TApp.Down(X, Y: Single); begin Pressed := True; TinaTouch(0, X, Y); Shell.Invalidate; end;
procedure TApp.Move(X, Y: Single); begin if Pressed then begin TinaTouch(2, X, Y); Shell.Invalidate; end; end;
procedure TApp.Up(X, Y: Single);   begin Pressed := False; TinaTouch(1, X, Y); Shell.Invalidate; end;
procedure TApp.Scroll(X, Y, DX, DY: Single); begin TinaScrollBy(X, Y, DX, DY); Shell.Invalidate; end;

function LoadTemplate: string;
var f: TStringList;
begin
  f := TStringList.Create;
  try f.LoadFromFile(ExtractFilePath(ParamStr(0)) + 'todos.twig'); Result := f.Text;
  finally f.Free; end;
end;

var App: TApp;
begin
  App := TApp.Create;
  App.Shell := TCocoaShell.Create;
  App.Shell.OnPaint := App.Paint;
  App.Shell.OnMouseDown := App.Down; App.Shell.OnMouseDrag := App.Move;
  App.Shell.OnMouseUp := App.Up; App.Shell.OnScroll := App.Scroll;

  App.Shell.Initialize(390, 620, 'Tina4 · Frond');
  TinaInit(App.Shell.GetMeasuringCanvas);
  TinaSetTemplateDir(ExtractFilePath(ParamStr(0)));   // for include/extends
  TinaRenderTemplate(LoadTemplate, CONTEXT);          // Frond → HTML → layout

  if (ParamCount >= 2) and (ParamStr(1) = '--snapshot') then App.Shell.SnapshotPath := ParamStr(2);
  App.Shell.Run;
end.
