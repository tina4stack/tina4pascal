program main;

{ A complete Tina4Pascal app in a few small files — the shape every app has.

  1. STATE + behaviour live in a portable unit (src/AppLogic.pas). It registers
     named actions (app.up / app.down) that mutate state and update the DOM.
  2. The UI is app.html — double-brace placeholders are the initial context; a
     tap is delivered as onclick="app.up()" and routed to your handler.
  3. RunApp (Tina4App) is the shared cross-platform host — the SAME main.pas and
     app.html build and run on macOS, Windows and Linux, and RunApp's
     `--dump-html` lets the CLI bundle the exact UI into the iOS/Android apps.

  Run it:      tina4pascal dev .            (desktop, live-edit app.html)
  Mobile:      tina4pascal build ios        (or: deploy ios / build android)
               — AppLogic ships in the engine via "appUnits" in tina4.json.   }

{$mode delphi}{$H+}
{$IFDEF WINDOWS}{$apptype gui}{$ENDIF}   // windowed app — no console window pops up

uses
  SysUtils,
  AppLogic,            // registers app.* actions in its initialization
  Tina4App;            // RunApp — the shared cross-platform host

var here: string;
begin
  here := ExtractFilePath(ParamStr(0));
  { Render the live app.html so edits show on the next run with no rebuild. Look
    in the working directory first (how `tina4pascal dev` and the mobile build's
    --dump-html run — from the project root), then next to the binary (a shipped
    desktop build). The mobile build renders this same app.html via --dump-html
    and bundles the result, so the phone shows the same UI. }
  if FileExists('app.html') then
    RunApp('My Tina4 App', GetCurrentDir, 'app.html', '{"count":0}', '', 420, 520)
  else if FileExists(here + 'app.html') then
    RunApp('My Tina4 App', here, 'app.html', '{"count":0}', '', 420, 520)
  else
    RunApp('My Tina4 App', '',
      '<body style="font-family:sans-serif;padding:36px;text-align:center">' +
      '<h1 id="count">0</h1><p>app.html was not found</p></body>',
      '{"count":0}', '', 420, 520);
end.
