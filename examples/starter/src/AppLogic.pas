unit AppLogic;

{ Your app's behaviour, as a portable unit.

  It holds plain state and the named actions the UI's onclick handlers dispatch
  to (app.up / app.down). Each action updates state, writes the new value into
  the <element id="count"> of whatever document the engine is showing, and flags
  the layout dirty so the shell repaints — no widgets, no window code.

  Registration happens in `initialization`, so EVERY shell that links this unit
  gets the behaviour: the desktop host (Tina4App.RunApp) and, because this unit
  is listed under "appUnits" in tina4.json, the iOS (libtina4ios.a) and Android
  (libtina4.so) engine libraries too. One unit, every platform. }

{$mode delphi}{$H+}

interface

{ Automatic via initialization; exposed so a host can (re)install explicitly. }
procedure RegisterAppActions;

implementation

uses
  SysUtils,
  Tina4HTMLDom,    // THTMLTag
  Tina4Events,     // RegisterAction
  Tina4Builtins;   // BuiltinsRoot, FindById, SetElementText, BuiltinsDirty

var
  Count: Integer = 0;   // <-- your application state

{ Push the current state into the live DOM and ask for a repaint. }
procedure Refresh;
var t: THTMLTag;
begin
  t := FindById(BuiltinsRoot, 'count');
  if t <> nil then SetElementText(t, IntToStr(Count));
  BuiltinsDirty := True;
end;

procedure Up(const Args: string);
begin
  Inc(Count);
  Refresh;
end;

procedure Down(const Args: string);
begin
  if Count > 0 then Dec(Count);
  Refresh;
end;

procedure RegisterAppActions;
begin
  RegisterAction('app.up', TTina4ActionProc(@Up));
  RegisterAction('app.down', TTina4ActionProc(@Down));
end;

initialization
  RegisterAppActions;
end.
