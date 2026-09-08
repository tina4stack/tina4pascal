program test_live;
{ Deterministic tests for the reactive live-data routing (no sockets): JSON
  field->id binding, plain-text-to-target, JSON fallback, and append mode. }
{$mode delphi}{$H+}

uses SysUtils, Tina4HTMLDom, Tina4Builtins, Tina4Live;

var Fails: Integer = 0; Total: Integer = 0;
procedure Check(Cond: Boolean; const Msg: string);
begin
  Inc(Total);
  if Cond then WriteLn('  ok   ', Msg) else begin WriteLn('  FAIL ', Msg); Inc(Fails); end;
end;

{ first #text child's text, '' if none }
function TextOf(Root: THTMLTag; const Id: string): string;
var el, c: THTMLTag; i: Integer;
begin
  Result := '';
  el := FindById(Root, Id);
  if el = nil then Exit;
  for i := 0 to el.Children.Count - 1 do
  begin
    c := el.Children[i];
    if c.TagName = '#text' then Exit(c.Text);
  end;
end;

function ChildDivCount(Root: THTMLTag; const Id: string): Integer;
var el, c: THTMLTag; i: Integer;
begin
  Result := 0;
  el := FindById(Root, Id);
  if el = nil then Exit;
  for i := 0 to el.Children.Count - 1 do
  begin
    c := el.Children[i];
    if c.TagName = 'div' then Inc(Result);
  end;
end;

const HTML =
  '<body>' +
  '  <span id="price"></span><span id="chg"></span>' +
  '  <div id="status"></div>' +
  '  <div id="log"></div>' +
  '</body>';

var Parser: THTMLParser;
begin
  WriteLn('=== reactive live-data routing ===');
  Parser := THTMLParser.Create;
  try
    Parser.Parse(HTML);
    BuiltinsRoot := Parser.Root;

    // 1. JSON object -> elements by id (field name == id)
    RouteMessage('', '{"price":"189.2","chg":"+2%"}', False);
    Check(TextOf(Parser.Root, 'price') = '189.2', 'JSON field #price = 189.2');
    Check(TextOf(Parser.Root, 'chg')   = '+2%',   'JSON field #chg = +2%');

    // 2. numbers/booleans stringify
    RouteMessage('', '{"price":42,"chg":true}', False);
    Check(TextOf(Parser.Root, 'price') = '42',   'JSON number stringified');
    Check(TextOf(Parser.Root, 'chg')   = 'true', 'JSON bool stringified');

    // 3. plain text -> the connect target element
    RouteMessage('status', 'connected', False);
    Check(TextOf(Parser.Root, 'status') = 'connected', 'plain text -> #status');

    // 4. JSON with no matching id falls back to the target (raw text)
    RouteMessage('status', '{"nope":"x"}', False);
    Check(TextOf(Parser.Root, 'status') = '{"nope":"x"}', 'unmatched JSON -> target raw');

    // 5. append mode adds child lines instead of replacing
    RouteMessage('log', 'line 1', True);
    RouteMessage('log', 'line 2', True);
    Check(ChildDivCount(Parser.Root, 'log') = 2, 'append mode: two <div> lines under #log');

    // 6. a matched field wins over the target (target untouched)
    RouteMessage('status', '{"price":"7"}', False);
    Check(TextOf(Parser.Root, 'price')  = '7',            'matched field routed');
    Check(TextOf(Parser.Root, 'status') = '{"nope":"x"}', 'target untouched when a field matched');
  finally
    Parser.Free;
  end;

  WriteLn(Total - Fails, '/', Total, ' assertions passed.');
  if Fails = 0 then WriteLn('ALL TESTS PASS') else begin WriteLn('FAILURES: ', Fails); Halt(1); end;
end.
