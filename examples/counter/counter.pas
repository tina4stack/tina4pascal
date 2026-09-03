program counter;

{ The Tina4Pascal app model in one file.

  There are NO widget components. The UI is an HTML string; the app is an
  event loop. State lives in the app (here, a single integer); when it
  changes, the app re-renders the HTML and the renderer repaints. User
  interaction comes back as SEMANTIC events — onclick="Obj:Method(args)" —
  not as button objects. This is the same model Tina4Delphi's TTina4HTMLRender
  exposes, and the same one a Frond template + a data feed will drive. }

{$mode delphi}{$H+}

uses
  SysUtils, Classes,
  Tina4HTMLDom, Tina4RenderBackend, Tina4ShellCocoa, Tina4HTMLLayout;

type
  TCounterApp = class
  public
    Shell: TCocoaShell;
    Parser: THTMLParser;
    Sheet: TCSSStyleSheet;
    Engine: TLayoutEngine;
    Root: TLayoutBox;
    Count: Integer;                 // <-- the entire application state
    procedure Render;               // state -> HTML -> layout
    procedure Paint(Canvas: TTina4Canvas; W, H: Single);
    procedure Click(X, Y: Single);  // hit-test -> onclick -> mutate state
  end;

{ Build the HTML for the current state and lay it out. Called on every change.
  A real app would use a Frond template here instead of string concatenation. }
procedure TCounterApp.Render;
var
  html: string;
begin
  html :=
    '<body style="font-family:sans-serif;padding:40px;text-align:center">' +
    '  <h1 style="font-size:64px;margin:0">' + IntToStr(Count) + '</h1>' +
    '  <p style="color:#5b5c78">clicks so far</p>' +
    '  <div style="margin-top:20px">' +
    '    <span onclick="Counter:Dec()" style="display:inline-block;' +
    '      background:#f3f2fb;color:#15162e;border:1px solid #e6e5f0;' +
    '      border-radius:11px;padding:12px 22px;font-size:22px">–</span>' +
    '    <span onclick="Counter:Inc()" style="display:inline-block;' +
    '      background:#4f46e5;color:#fff;border-radius:11px;' +
    '      padding:12px 22px;font-size:22px;margin-left:10px">+</span>' +
    '    <span onclick="Counter:Reset()" style="display:inline-block;' +
    '      color:#5b5c78;padding:12px 16px;font-size:16px;margin-left:16px">reset</span>' +
    '  </div>' +
    '</body>';
  FreeAndNil(Parser);
  Parser := THTMLParser.Create;
  Parser.Parse(html);
  FreeAndNil(Root);
  FreeAndNil(Engine);
  Engine := TLayoutEngine.Create(Shell.GetMeasuringCanvas, Sheet);
  Root := Engine.Build(Parser.Root, 480);
  Shell.Invalidate;
end;

procedure TCounterApp.Paint(Canvas: TTina4Canvas; W, H: Single);
begin
  if (Root = nil) or (Engine = nil) then
  begin
    Engine := TLayoutEngine.Create(Canvas, Sheet);
    Root := Engine.Build(Parser.Root, W);
  end;
  Canvas.FillRect(0, 0, W, H, $FFFBFAF7);   // Tina4 --paper
  PaintBox(Canvas, Root, 0);
end;

{ A click is routed to the deepest element under the cursor; we walk up to the
  nearest onclick and dispatch it. The handler string is the contract — the app
  decides what "Counter:Inc()" means. }
procedure TCounterApp.Click(X, Y: Single);
var
  t: THTMLTag;
  action: string;
begin
  if Root = nil then Exit;
  t := HitTest(Root, X, Y);
  while t <> nil do
  begin
    if t.HasAttribute('onclick') then
    begin
      action := t.GetAttribute('onclick');
      if action = 'Counter:Inc()' then Inc(Count)
      else if action = 'Counter:Dec()' then Dec(Count)
      else if action = 'Counter:Reset()' then Count := 0;
      Render;                       // state changed -> re-render
      Exit;
    end;
    t := t.Parent;
  end;
end;

var
  App: TCounterApp;
begin
  App := TCounterApp.Create;
  App.Count := 0;
  App.Sheet := TCSSStyleSheet.Create;
  App.Shell := TCocoaShell.Create;
  App.Shell.OnPaint := App.Paint;
  App.Shell.OnMouseUp := App.Click;
  App.Shell.Initialize(480, 360, 'Tina4 Counter');
  if ParamCount >= 1 then App.Shell.SnapshotPath := ParamStr(1);  // capture + demo
  App.Count := 7;                   // preset for the snapshot demo
  App.Render;                       // initial paint
  App.Shell.Run;
end.
