unit Tina4Events;

{ Semantic event dispatch for the Tina4 app model.

  The renderer never runs app logic itself — an `onclick="Counter:Inc(2)"`
  surfaces as a string, and the app decides what it means. This unit is the
  registry that turns that string into a call: the app registers named
  actions, the shell dispatches to them. Pure Pascal, shared by every shell
  (desktop, Android, …). Mirrors Tina4Delphi's object:method(params) contract. }

{$mode delphi}{$H+}

interface

type
  { An action handler. Args is the raw text between the parentheses (or '' ). }
  TTina4ActionProc = procedure(const Args: string);
  TTina4ActionMethod = procedure(const Args: string) of object;

{ Register a handler under a name. The name matches the part of an onclick
  before '(' , case-insensitively — e.g. "Counter:Inc" or a bare "inc". A
  second registration under the same name replaces the first. }
procedure RegisterAction(const Name: string; Proc: TTina4ActionProc); overload;
procedure RegisterAction(const Name: string; Method: TTina4ActionMethod); overload;

{ Parse an onclick handler ("Name(args)" or "Name") and call its action.
  Returns True if a handler was found and invoked. }
function DispatchAction(const Handler: string): Boolean;

{ Drop all registrations (e.g. when an app tears down). }
procedure ClearActions;

implementation

uses SysUtils;

type
  TEntry = record
    Name: string;
    Proc: TTina4ActionProc;
    Method: TTina4ActionMethod;
    IsMethod: Boolean;
  end;

var
  Entries: array of TEntry;

function IndexOfName(const Name: string): Integer;
var i: Integer; n: string;
begin
  n := LowerCase(Name);
  for i := 0 to High(Entries) do
    if LowerCase(Entries[i].Name) = n then Exit(i);
  Result := -1;
end;

procedure RegisterAction(const Name: string; Proc: TTina4ActionProc);
var i: Integer;
begin
  i := IndexOfName(Name);
  if i < 0 then begin i := Length(Entries); SetLength(Entries, i + 1); end;
  Entries[i].Name := Name;
  Entries[i].Proc := Proc;
  Entries[i].Method := nil;
  Entries[i].IsMethod := False;
end;

procedure RegisterAction(const Name: string; Method: TTina4ActionMethod);
var i: Integer;
begin
  i := IndexOfName(Name);
  if i < 0 then begin i := Length(Entries); SetLength(Entries, i + 1); end;
  Entries[i].Name := Name;
  Entries[i].Proc := nil;
  Entries[i].Method := Method;
  Entries[i].IsMethod := True;
end;

function DispatchAction(const Handler: string): Boolean;
var
  name, args: string;
  p, i: Integer;
begin
  Result := False;
  p := Pos('(', Handler);
  if p > 0 then
  begin
    name := Trim(Copy(Handler, 1, p - 1));
    args := Copy(Handler, p + 1, MaxInt);
    p := Pos(')', args);            // strip the trailing ")"
    if p > 0 then args := Copy(args, 1, p - 1);
    args := Trim(args);
  end
  else
  begin
    name := Trim(Handler);
    args := '';
  end;
  i := IndexOfName(name);
  if i < 0 then Exit;
  if Entries[i].IsMethod then
  begin
    if Assigned(Entries[i].Method) then Entries[i].Method(args);
  end
  else
    if Assigned(Entries[i].Proc) then Entries[i].Proc(args);
  Result := True;
end;

procedure ClearActions;
begin
  SetLength(Entries, 0);
end;

end.
