program main;

{ A complete Tina4Pascal app in one small file — the shape every app has.

  1. STATE lives in plain Pascal vars.
  2. The UI is app.html; double-brace placeholders are filled from state.
  3. A tap is delivered as onclick="Object:Method()" and routed to a handler you
     registered. The handler changes state and re-renders. That's the loop.

  Run it with:  tina4pascal dev .        (from this folder)               }

{$mode delphi}{$H+}

uses
  SysUtils, Classes,
  Tina4HTMLDom, Tina4RenderBackend, Tina4ShellCocoa, Tina4HTMLLayout,
  Tina4Events, Tina4Services;

var
  Count: Integer = 0;          // <-- your application state

type
  { The Cocoa shell delivers paint/click as methods, so we hang them on a tiny
    host object. Your app LOGIC stays in the plain procs registered below. }
  TApp = class
    Parser: THTMLParser;
    Sheet: TCSSStyleSheet;
    Engine: TLayoutEngine;
    Root: TLayoutBox;
    Shell: TCocoaShell;
    function  BuildHTML: string;                 // app.html + state
    procedure Render;                            // state -> HTML -> layout
    procedure Paint(Canvas: TTina4Canvas; W, H: Single);
    procedure Click(X, Y: Single);
  end;

var
  App: TApp;

function TApp.BuildHTML: string;
var f: TStringList;
begin
  f := TStringList.Create;
  try f.LoadFromFile('app.html'); Result := f.Text;
  finally f.Free; end;
  Result := StringReplace(Result, '{{count}}', IntToStr(Count), [rfReplaceAll]);
end;

procedure TApp.Render;
var i: Integer;
begin
  FreeAndNil(Parser); Parser := THTMLParser.Create;
  Parser.Parse(BuildHTML);
  // load the page's <style> blocks into a fresh stylesheet (so classes apply)
  FreeAndNil(Sheet); Sheet := TCSSStyleSheet.Create;
  for i := 0 to Parser.StyleBlocks.Count - 1 do
    Sheet.AddCSS(Parser.StyleBlocks[i]);
  FreeAndNil(Root); FreeAndNil(Engine);
  Engine := TLayoutEngine.Create(Shell.GetMeasuringCanvas, Sheet);
  Root := Engine.Build(Parser.Root, 480);
  Shell.Invalidate;
end;

procedure TApp.Paint(Canvas: TTina4Canvas; W, H: Single);
begin
  if Root = nil then Render;
  Canvas.FillRect(0, 0, W, H, $FFFBFAF7);
  PaintBox(Canvas, Root, 0);
end;

procedure TApp.Click(X, Y: Single);
var t: THTMLTag;
begin
  if Root = nil then Exit;
  t := HitTest(Root, X, Y);
  while t <> nil do
  begin
    if t.HasAttribute('onclick') then
    begin
      DispatchAction(t.GetAttribute('onclick'));  // runs your registered proc
      Render;
      Exit;
    end;
    t := t.Parent;
  end;
end;

{ ---- your app's behaviour (plain procs, registered by name) ---- }
procedure Up(const Args: string);   begin Inc(Count); StoreSet('count', IntToStr(Count)); end;
procedure Down(const Args: string); begin if Count > 0 then Dec(Count); StoreSet('count', IntToStr(Count)); end;

begin
  App := TApp.Create;
  App.Sheet := TCSSStyleSheet.Create;
  App.Shell := TCocoaShell.Create;
  App.Shell.OnPaint   := App.Paint;
  App.Shell.OnMouseUp := App.Click;

  StoreInit(GetCurrentDir);                              // localStore in this folder
  Count := StrToIntDef(StoreGetDef('count', '0'), 0);    // restore last value
  RegisterAction('App:Up', @Up);
  RegisterAction('App:Down', @Down);

  App.Shell.Initialize(480, 360, 'My Tina4 App');
  if ParamCount >= 1 then App.Shell.SnapshotPath := ParamStr(1);  // headless capture
  App.Render;
  App.Shell.Run;
end.
