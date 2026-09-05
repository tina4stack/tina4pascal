program seg;

{ Radios styled as buttons (segmented control): appearance:none + :checked. The
  first snapshot shows the initial selection; then we tap the 3rd segment and
  snapshot again — the selection must move (mutual exclusion by name). }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  Tina4RenderBackend, Tina4ShellCocoa, Tina4Interact, Tina4Http, Tina4HttpCocoa;

const W = 460; H = 200;
var
  shell: TCocoaShell; step: Integer = 0;

type TApp = class procedure Paint(C: TTina4Canvas; PW, PH: Single); procedure Tick; end;
procedure TApp.Paint(C: TTina4Canvas; PW, PH: Single); begin TinaFrame(Round(PW), Round(PH), 1); end;
procedure TApp.Tick;
begin
  Inc(step);
  if step = 1 then begin TinaFrame(W, H, 1); shell.Snapshot('seg1.png'); end
  else if step = 2 then
  begin
    TinaTouch(0, 250, 55); TinaTouch(1, 250, 55);   // tap the 3rd segment (~"Month")
    TinaFrame(W, H, 1); shell.Snapshot('seg2.png'); shell.Quit;
  end;
end;

const HTML =
  '<html><head><style>' +
  'body{font-family:sans-serif;background:#fbfaf7;padding:20px}' +
  '.seg{appearance:none;padding:11px 20px;margin-right:8px;background:#f3f2fb;' +
  '     color:#15162e;border:1px solid #e6e5f0;border-radius:11px;font-weight:bold;font-size:15px}' +
  '.seg:checked{background:#2b41e6;color:#ffffff;border-color:#2b41e6}' +
  '</style></head><body>' +
  '<input type="radio" name="view" value="Day" checked class="seg">' +
  '<input type="radio" name="view" value="Week" class="seg">' +
  '<input type="radio" name="view" value="Month" class="seg">' +
  '</body></html>';

var App: TApp;
begin
  App := TApp.Create;
  shell := TCocoaShell.Create;
  shell.OnPaint := App.Paint; shell.OnTick := App.Tick;
  shell.Initialize(W, H, 'segmented');
  TinaInit(shell.GetMeasuringCanvas);
  TinaSetHtml(HTML);
  shell.StartTicker(120);
  shell.Run;
end.
