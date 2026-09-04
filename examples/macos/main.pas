program main;

{ Tina4Pascal as a native macOS app — the SAME shared engine (Tina4Interact) as
  Android and iOS, driven here by the Cocoa shell. It renders controls.html with
  full interaction: tap, type, checkboxes/radios, the <select> dropdown, inner
  scrollers, fling and the caret. Proof that the engine is the app and the shell
  is just plumbing.

  Run:      tina4pascal macos
  Snapshot: main --snapshot out.png                                        }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  Tina4RenderBackend, Tina4ShellCocoa, Tina4Interact;

type
  TMacApp = class
    Shell: TCocoaShell;
    Pressed: Boolean;
    Blink: Integer;
    procedure Paint(Canvas: TTina4Canvas; W, H: Single);
    procedure Down(X, Y: Single);
    procedure Move(X, Y: Single);
    procedure Up(X, Y: Single);
    procedure Scroll(X, Y, DX, DY: Single);
    procedure Key(const Chars: string; Code: Integer);
    procedure Tick;
    procedure Handle(R: Integer);
  end;

procedure TMacApp.Paint(Canvas: TTina4Canvas; W, H: Single);
begin
  TinaFrame(Round(W), Round(H), 1);    // points == CSS px on macOS (density 1)
end;

procedure TMacApp.Handle(R: Integer);
begin
  case R of
    TINA_PICK_FILE: TinaSetFile(Shell.PickFile);
    TINA_CAPTURE:   TinaSetPhoto(Shell.CaptureCamera);
  end;
  Shell.Invalidate;
end;

procedure TMacApp.Down(X, Y: Single);
begin Pressed := True; Handle(TinaTouch(0, X, Y)); end;

procedure TMacApp.Move(X, Y: Single);
begin if Pressed then Handle(TinaTouch(2, X, Y)); end;

procedure TMacApp.Up(X, Y: Single);
begin Pressed := False; Handle(TinaTouch(1, X, Y)); end;

procedure TMacApp.Scroll(X, Y, DX, DY: Single);
begin TinaScrollBy(X, Y, DX, DY); Shell.Invalidate; end;

procedure TMacApp.Key(const Chars: string; Code: Integer);
begin
  if Code = TK_BACKSPACE then TinaKey(8)
  else if Code = TK_RETURN then TinaKey(10)
  else if Chars <> '' then TinaKey(Ord(Chars[1]));   // ASCII fast path
  Shell.Invalidate;
end;

procedure TMacApp.Tick;
begin
  TinaTick;                              // momentum
  Inc(Blink);
  if Blink mod 15 = 0 then TinaBlinkCaret;   // ~500ms at 33ms/tick
  Shell.Invalidate;
end;

{ read controls.html from the exe dir, the .app Resources, or the cwd }
function LoadPage: string;
var dir, p: string; f: TStringList;

  function Has(const Path: string): Boolean;
  begin Result := FileExists(Path); if Result then p := Path; end;

begin
  dir := ExtractFilePath(ParamStr(0));
  p := '';
  if not Has(dir + 'controls.html') then
    if not Has(dir + '../Resources/controls.html') then
      Has('controls.html');
  if p = '' then Exit('<body style="padding:40px;font-family:sans-serif">' +
    '<h1>controls.html not found</h1></body>');
  f := TStringList.Create;
  try f.LoadFromFile(p); Result := f.Text;
  finally f.Free; end;
end;

var
  App: TMacApp;
begin
  App := TMacApp.Create;
  App.Shell := TCocoaShell.Create;
  App.Shell.OnPaint     := App.Paint;
  App.Shell.OnMouseDown := App.Down;
  App.Shell.OnMouseDrag := App.Move;
  App.Shell.OnMouseUp   := App.Up;
  App.Shell.OnScroll    := App.Scroll;
  App.Shell.OnKeyDown   := App.Key;
  App.Shell.OnTick      := App.Tick;

  App.Shell.Initialize(390, 780, 'Tina4Pascal');   // phone-ish portrait window
  TinaInit(App.Shell.GetMeasuringCanvas);
  TinaSetHtml(LoadPage);

  if (ParamCount >= 2) and (ParamStr(1) = '--snapshot') then
    App.Shell.SnapshotPath := ParamStr(2)
  else
    App.Shell.StartTicker(33);           // caret + fling (skip for a snapshot)

  App.Shell.Run;
end.
