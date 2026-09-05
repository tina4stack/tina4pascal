program main;

{ CaptureGuard — an HTML-first answer to SetWindowDisplayAffinity.

  The whole UI is one Frond template rendered by the shared Tina4 engine onto a
  single canvas. "Sensitive" data is marked in the MARKUP; a capture-mode flag in
  the context decides whether it paints or is redacted. No per-window OS call, no
  separate HWND per modal/popup — one canvas, same HTML on macOS/Windows/Linux/
  iOS/Android.

  Run:      tina4pascal dev examples/captureguard
  Snapshot: ./main --snap   (writes cg-live.png then cg-captured.png)            }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  Tina4RenderBackend, Tina4ShellCocoa, Tina4Interact, Tina4Events;

const
  ROWS =
    '[' +
    '{"n":1,"stock":"STK-20418-1","vin":"1HGCM82633A004352","owner":"John Q. Smith","title":"4471-A"},' +
    '{"n":2,"stock":"STK-20419-2","vin":"2T1BR32E44C851234","owner":"Maria L. Delgado","title":"4471-B"},' +
    '{"n":3,"stock":"STK-20501-3","vin":"1FTFW1ET5DFA61234","owner":"Robert Chen","title":"4602-C"},' +
    '{"n":4,"stock":"STK-20744-4","vin":"JH4KA7650MC012345","owner":"Aisha Okafor","title":"4610-A"},' +
    '{"n":5,"stock":"STK-20802-5","vin":"5YJ3E1EA7JF006789","owner":"Daniel Kowalski","title":"4688-D"},' +
    '{"n":6,"stock":"STK-21033-6","vin":"WBA3A5C51DF598765","owner":"Priya Raman","title":"4701-B"},' +
    '{"n":7,"stock":"STK-20418-7","vin":"1HGCM82633A004352","owner":"John Q. Smith","title":"4471-A"},' +
    '{"n":8,"stock":"STK-20419-8","vin":"2T1BR32E44C851234","owner":"Maria L. Delgado","title":"4471-B"}' +
    ']';

var
  GCaptured: Boolean = False;
  GPolicy: string = 'Sensitive only';
  GLog: string = '12:28:10  CaptureGuard ready · mode WDA-equivalent (render flag)';

function JB(B: Boolean): string; begin if B then Result := 'true' else Result := 'false'; end;

function BuildContext: string;
begin
  Result := '{"captured":' + JB(GCaptured) +
            ',"policy":"' + GPolicy + '"' +
            ',"log":"' + GLog + '"' +
            ',"rows":' + ROWS + '}';
end;

procedure AddLog(const S: string);
begin
  GLog := GLog + '\n' + S;
end;

procedure Rerender; begin TinaRenderContext(BuildContext); end;

procedure ActCapture(const Args: string);
begin
  GCaptured := not GCaptured;
  if GCaptured then AddLog('12:28:2' + IntToStr(Random(9)) + '  capture detected → sensitive elements redacted')
  else AddLog('12:28:3' + IntToStr(Random(9)) + '  capture ended → content restored');
  Rerender;
end;

procedure ActPolicy(const Args: string);
begin
  GPolicy := Args;
  AddLog('12:28:2' + IntToStr(Random(9)) + '  policy set to ' + Args);
  Rerender;
end;

type
  TApp = class
    Shell: TCocoaShell; Pressed: Boolean;
    Mode: Integer;                 // 0 interactive · 1 two stills · 2 video frames
    Step: Integer; FramesDir: string;
    procedure Paint(C: TTina4Canvas; W, H: Single);
    procedure Down(X, Y: Single); procedure Move(X, Y: Single); procedure Up(X, Y: Single);
    procedure Scroll(X, Y, DX, DY: Single);
    procedure Tick;
  end;
procedure TApp.Paint(C: TTina4Canvas; W, H: Single); begin TinaFrame(Round(W), Round(H), 1); end;

procedure TApp.Tick;
begin
  Inc(Step);
  if Mode = 1 then                 // two stills for the docs
  begin
    if Step = 1 then begin TinaFrame(780, 900, 1); Shell.Snapshot('cg-live.png'); end
    else if Step = 2 then
    begin
      GCaptured := True; AddLog('12:28:24  capture detected -> sensitive elements redacted');
      Rerender; TinaFrame(780, 900, 1); Shell.Snapshot('cg-captured.png'); Shell.Quit;
    end;
    Exit;
  end;
  if Mode = 3 then                 // click-test: tap the capture button, prove it toggles
  begin
    if Step = 1 then begin TinaFrame(780,900,1); Shell.Snapshot('click-before.png'); end
    else if Step = 2 then begin TinaTouch(0, 200, 128); TinaTouch(1, 200, 128); end
    else if Step = 3 then begin TinaFrame(780,900,1); Shell.Snapshot('click-after.png'); Shell.Quit; end;
    Exit;
  end;
  if Mode = 2 then                 // a looping demo: live → capture → restore
  begin
    if Step = 14 then begin GCaptured := True;  AddLog('12:28:24  capture detected -> sensitive redacted'); Rerender; end
    else if Step = 40 then begin GCaptured := False; AddLog('12:28:31  capture ended -> content restored'); Rerender; end;
    TinaFrame(780, 900, 1);
    Shell.Snapshot(FramesDir + '/f_' + Format('%.3d', [Step]) + '.png');
    if Step >= 54 then Shell.Quit;
    Exit;
  end;
end;
procedure TApp.Down(X, Y: Single); begin Pressed := True; TinaTouch(0, X, Y); Shell.Invalidate; end;
procedure TApp.Move(X, Y: Single); begin if Pressed then begin TinaTouch(2, X, Y); Shell.Invalidate; end; end;
procedure TApp.Up(X, Y: Single);   begin Pressed := False; TinaTouch(1, X, Y); Shell.Invalidate; end;
procedure TApp.Scroll(X, Y, DX, DY: Single); begin TinaScrollBy(X, Y, DX, DY); Shell.Invalidate; end;

function LoadTemplate: string;
var f: TStringList; p: string;
begin
  p := ExtractFilePath(ParamStr(0)) + 'captureguard.twig';   // next to the binary
  if not FileExists(p) then p := 'captureguard.twig';        // else the run folder (tina4pascal dev)
  f := TStringList.Create;
  try f.LoadFromFile(p); Result := f.Text;
  finally f.Free; end;
end;

var App: TApp;
begin
  Randomize;
  App := TApp.Create;
  App.Mode := 0;
  if (ParamCount >= 1) and (ParamStr(1) = '--snap') then App.Mode := 1;
  if (ParamCount >= 1) and (ParamStr(1) = '--clicktest') then App.Mode := 3;
  if (ParamCount >= 2) and (ParamStr(1) = '--frames') then
  begin App.Mode := 2; App.FramesDir := ParamStr(2); end;
  App.Shell := TCocoaShell.Create;
  App.Shell.OnPaint := App.Paint;
  App.Shell.OnMouseDown := App.Down; App.Shell.OnMouseDrag := App.Move;
  App.Shell.OnMouseUp := App.Up; App.Shell.OnScroll := App.Scroll;
  App.Shell.OnTick := App.Tick;
  App.Shell.Initialize(780, 900, 'CaptureGuard · Tina4');
  TinaInit(App.Shell.GetMeasuringCanvas);

  RegisterAction('CG:Capture', @ActCapture);
  RegisterAction('CG:Policy', @ActPolicy);

  TinaSetTemplateDir(ExtractFilePath(ParamStr(0)));
  TinaRenderTemplate(LoadTemplate, BuildContext);

  if App.Mode in [1, 3] then App.Shell.StartTicker(120);
  if App.Mode = 2 then App.Shell.StartTicker(80);   // ~12 fps frame capture
  App.Shell.Run;
end.
