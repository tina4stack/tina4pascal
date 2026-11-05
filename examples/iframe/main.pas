program main;

{ <iframe> in a tina4pascal app: a native page (drawn by the engine) with a live
  web preview inside it. The engine lays the <iframe> out as a box; the Cocoa
  shell overlays the OS's own WKWebView on it and keeps it positioned while the
  native page scrolls. No browser or web engine is bundled — see plan/adr/0016.

  Serve the page the frame shows, then run the app:
    python3 -m http.server 8765 --bind 127.0.0.1 -d examples/iframe/site
    sh examples/iframe/build.sh --run

  Flags:  --autoscroll N   scroll the native page by N px after ~1s (demo/test) }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  Tina4RenderBackend, Tina4ShellCocoa, Tina4Interact, Tina4Events, Tina4Builtins,
  Tina4HTMLDom;

type
  TIframeApp = class
    Shell: TCocoaShell;
    Pressed: Boolean;
    Ticks, AutoScroll: Integer;
    procedure Paint(Canvas: TTina4Canvas; W, H: Single);
    procedure Down(X, Y: Single);
    procedure Move(X, Y: Single);
    procedure Up(X, Y: Single);
    procedure Scroll(X, Y, DX, DY: Single);
    procedure Tick;
  end;

procedure TIframeApp.Paint(Canvas: TTina4Canvas; W, H: Single);
begin
  TinaFrame(Round(W), Round(H), 1);    // points == CSS px on macOS
end;

procedure TIframeApp.Down(X, Y: Single);
begin Pressed := True; TinaTouch(0, X, Y); Shell.Invalidate; end;

procedure TIframeApp.Move(X, Y: Single);
begin if Pressed then begin TinaTouch(2, X, Y); Shell.Invalidate; end; end;

procedure TIframeApp.Up(X, Y: Single);
begin Pressed := False; TinaTouch(1, X, Y); Shell.Invalidate; end;

procedure TIframeApp.Scroll(X, Y, DX, DY: Single);
begin TinaScrollBy(X, Y, DX, DY); Shell.Invalidate; end;

procedure TIframeApp.Tick;
begin
  TinaTick;                            // scroll momentum
  Inc(Ticks);
  if (AutoScroll <> 0) and (Ticks = 30) then TinaScrollBy(10, 10, 0, -AutoScroll);   // -DY = down
  Shell.Invalidate;
end;

{ frame.go('url') — point the iframe at another page. The shell sees the new
  src on the next frame and reloads the same web view in place. }
procedure ActGo(const Args: string);
begin
  SetAttr(FindById(BuiltinsRoot, 'preview'), 'src', Unquote(Trim(Args)));
end;

{ frame.toggle() — display:none takes the iframe out of the layout, so the shell
  removes its web view; showing it again creates a fresh one. }
procedure ActToggle(const Args: string);
var t: THTMLTag; v: string;
begin
  t := FindById(BuiltinsRoot, 'preview');
  if t = nil then Exit;
  if not t.Style.TryGetValue('display', v) then v := '';
  if v = 'none' then SetStyleProp(t, 'display', 'inline-block')
  else SetStyleProp(t, 'display', 'none');
end;

{ read app.html from the exe dir, the .app Resources, or the cwd }
function LoadPage: string;
var dir, p: string; f: TStringList;

  function Has(const Path: string): Boolean;
  begin Result := FileExists(Path); if Result then p := Path; end;

begin
  dir := ExtractFilePath(ParamStr(0));
  p := '';
  if not Has(dir + 'app.html') then
    if not Has(dir + '../Resources/app.html') then
      if not Has('app.html') then
        Has('examples/iframe/app.html');
  if p = '' then Exit('<body style="padding:40px;font-family:sans-serif">' +
    '<h1>app.html not found</h1></body>');
  f := TStringList.Create;
  try f.LoadFromFile(p); Result := f.Text;
  finally f.Free; end;
end;

var
  App: TIframeApp;
  i: Integer;
begin
  App := TIframeApp.Create;
  for i := 1 to ParamCount - 1 do
    if ParamStr(i) = '--autoscroll' then App.AutoScroll := StrToIntDef(ParamStr(i + 1), 0);
  App.Shell := TCocoaShell.Create;
  App.Shell.OnPaint     := App.Paint;
  App.Shell.OnMouseDown := App.Down;
  App.Shell.OnMouseDrag := App.Move;
  App.Shell.OnMouseUp   := App.Up;
  App.Shell.OnScroll    := App.Scroll;
  App.Shell.OnTick      := App.Tick;

  App.Shell.Initialize(760, 720, 'Tina4 · iframe');
  TinaInit(App.Shell.GetMeasuringCanvas);
  RegisterAction('frame.go', @ActGo);
  RegisterAction('frame.toggle', @ActToggle);
  TinaSetHtml(LoadPage);

  App.Shell.StartTicker(33);
  App.Shell.Run;
end.
