program test_notify;
{ Verify the notify.show action path: onclick string → DispatchAction →
  ActNotifyShow → Tina4Notify → the registered handler, with literal args and
  an element-id whose text is surfaced. (The native banner is shell-side.) }
{$mode delphi}{$H+}

uses SysUtils, Tina4HTMLDom, Tina4RenderBackend, Tina4Events, Tina4Builtins;

var GT, GB, GTag: string; GN: Integer;

procedure CaptureNotify(const Title, Body, Tag: string);
begin
  GT := Title; GB := Body; GTag := Tag; Inc(GN);
end;

var Fails: Integer = 0; Total: Integer = 0;
procedure Check(Cond: Boolean; const Msg: string);
begin
  Inc(Total);
  if Cond then WriteLn('  ok   ', Msg) else begin WriteLn('  FAIL ', Msg); Inc(Fails); end;
end;

var P: THTMLParser;
begin
  RegisterBuiltinActions;
  Tina4SetNotifyHandler(@CaptureNotify);

  // a doc with an element whose text we want to surface
  P := THTMLParser.Create;
  P.Parse('<div><span id="msg">count 5</span></div>');
  BuiltinsRoot := P.Root;

  WriteLn('=== notify.show ===');

  GN := 0;
  Check(DispatchAction('notify.show(''Alert'', ''Something happened'')'), 'dispatch literal args');
  Check((GN = 1) and (GT = 'Alert') and (GB = 'Something happened'),
    'two literal args → title/body');

  GN := 0;
  Check(DispatchAction('notify.show(''Only title'')'), 'dispatch one arg');
  Check((GN = 1) and (GT = 'Only title') and (GB = ''), 'one arg → title only, empty body');

  GN := 0;
  Check(DispatchAction('notify.show(''Live'', msg)'), 'dispatch id body arg');
  Check((GN = 1) and (GT = 'Live') and (GB = 'count 5'),
    'element id resolves to its text ("count 5")');

  WriteLn;
  if Fails = 0 then WriteLn('ALL ', Total, ' NOTIFY TESTS PASS')
  else WriteLn(Fails, ' of ', Total, ' FAILED');
  Halt(Ord(Fails <> 0));
end.
