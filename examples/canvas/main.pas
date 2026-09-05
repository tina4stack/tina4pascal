program main;

{ <canvas> with NO JavaScript — the drawing is pure Pascal.

  Registers a painter for `<canvas id="demo">` and draws with the Canvas-2D API
  (Tina4Canvas2D). The engine calls the painter every frame with a context
  clipped + origin-set to the canvas box. Same shared engine as every shell.

  Run:      (build below) ./main
  Snapshot: ./main --snapshot out.png                                        }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Math,
  Tina4RenderBackend, Tina4Canvas2D, Tina4ShellCocoa, Tina4Interact;

const
  PAGE =
    '<body style="margin:0;font-family:sans-serif;background:#fbfaf7">' +
    '<div style="padding:20px">' +
    '<h2 style="color:#1a2aa8">Canvas 2D — pure Pascal, no JavaScript</h2>' +
    '<canvas id="demo" width="360" height="240" ' +
    'style="background:#ffffff;border:1px solid #e6e5f0;border-radius:12px"></canvas>' +
    '<p style="color:#5b5c78">Bars, an arc, a bezier path and text — all drawn by ' +
    'a Pascal painter via the Canvas-2D methods.</p>' +
    '</div></body>';

{ The painter: draws with the familiar Canvas-2D calls. }
procedure DrawDemo(ctx: TTina4Canvas2D);
var i: Integer; bh: Single;
const bars: array[0..4] of Single = (0.5, 0.8, 0.35, 0.95, 0.6);
begin
  // bar chart
  ctx.SetFillColor($FF2B41E6);
  for i := 0 to 4 do
  begin
    bh := 150 * bars[i];
    ctx.FillRect(24 + i * 44, 200 - bh, 30, bh);
  end;
  // a translucent hot-pink circle
  ctx.SetGlobalAlpha(0.85);
  ctx.SetFillColor($FFFF5AA0);
  ctx.BeginPath;
  ctx.Arc(280, 90, 46, 0, 2 * Pi);
  ctx.Fill;
  ctx.SetGlobalAlpha(1);
  // a bezier stroke in yellow
  ctx.SetStrokeColor($FFFFD23C);
  ctx.SetLineWidth(4);
  ctx.BeginPath;
  ctx.MoveTo(24, 40);
  ctx.BezierCurveTo(120, -10, 220, 90, 336, 30);
  ctx.Stroke;
  // labels
  ctx.SetFillColor($FF15162E);
  ctx.SetFont(15, True, False);
  ctx.SetTextAlign('left');
  ctx.FillText('Q1  Q2  Q3  Q4  Q5', 24, 224);
  ctx.SetFont(13, False, False);
  ctx.SetTextAlign('center');
  ctx.SetFillColor($FFFFFFFF);
  ctx.FillText('87%', 280, 95);
end;

type
  TMacApp = class
    Shell: TCocoaShell;
    procedure Paint(Canvas: TTina4Canvas; W, H: Single);
    procedure Down(X, Y: Single);
    procedure Up(X, Y: Single);
    procedure Tick;
  end;

procedure TMacApp.Paint(Canvas: TTina4Canvas; W, H: Single);
begin TinaFrame(Round(W), Round(H), 1); end;
procedure TMacApp.Down(X, Y: Single); begin TinaTouch(0, X, Y); Shell.Invalidate; end;
procedure TMacApp.Up(X, Y: Single);   begin TinaTouch(1, X, Y); Shell.Invalidate; end;
procedure TMacApp.Tick; begin if TinaTick <> 0 then Shell.Invalidate; end;

var
  App: TMacApp;
begin
  App := TMacApp.Create;
  App.Shell := TCocoaShell.Create;
  App.Shell.OnPaint     := App.Paint;
  App.Shell.OnMouseDown := App.Down;
  App.Shell.OnMouseUp   := App.Up;
  App.Shell.OnTick      := App.Tick;

  App.Shell.Initialize(420, 400, 'Tina4 Canvas');
  TinaInit(App.Shell.GetMeasuringCanvas);
  RegisterCanvasPainter('demo', @DrawDemo);   // wire the Pascal painter to <canvas id="demo">
  TinaSetHtml(PAGE);

  if (ParamCount >= 2) and (ParamStr(1) = '--snapshot') then
    App.Shell.SnapshotPath := ParamStr(2)
  else
    App.Shell.StartTicker(33);
  App.Shell.Run;
end.
