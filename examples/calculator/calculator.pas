program calculator;

{ A calculator, the Tina4Pascal way.

  The UI is calculator.html — a real, editable HTML/CSS file, the single source
  of truth for how it looks. There are NO widget objects. Each key carries a
  SEMANTIC event, onclick="calc.digit(7)" / "calc.op(+)" / "calc.eq()", and the
  engine surfaces it as a string. The arithmetic lives in the portable unit
  Tina4CalcApp, which registers those named actions at load — so the SAME logic
  and the SAME HTML run here on the desktop (Tina4App.RunApp) and inside the
  Android JNI library.

  STANDALONE: the HTML is compiled in (calculator_ui.inc, generated from
  calculator.html by gen_ui_inc.sh), so the built exe ships with no external
  asset. If calculator.html happens to sit next to the exe it's used instead —
  handy for editing the UI without a rebuild. }

{$mode delphi}{$H+}
{$IFDEF WINDOWS}{$apptype gui}{$ENDIF}   // windowed app — no console window pops up
{$IFDEF WINDOWS}{$R calculator.rc}{$ENDIF}   // embed MAINICON (calculator.ico)

uses
  SysUtils,
  Tina4CalcApp,        // registers calc.* actions in its initialization
  Tina4App;            // RunApp — the shared cross-platform host

{$I calculator_ui.inc}  // const CALC_HTML — the embedded UI

var here: string;
begin
  here := ExtractFilePath(ParamStr(0));
  if FileExists(here + 'calculator.html') then
    RunApp('Calculator', here, 'calculator.html', '{}', '', 360, 620)  // dev: live file
  else
    RunApp('Calculator', '', CALC_HTML, '{}', '', 360, 620);           // shipped: embedded
end.
