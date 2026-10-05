program test_builtins_nodes;
{ REAL test for the agnostic runtime DOM-node API in Tina4Builtins (ADR-0013):
  create / append / remove / set-attr / set-style, plus child access. These are
  generic building blocks — the test composes a plain tree, not any particular
  effect. Each assertion flips to FAIL if the behaviour regresses. }
{$mode delphi}{$H+}

uses SysUtils, Tina4HTMLDom, Tina4Builtins;

var
  Fails: Integer = 0; Total: Integer = 0;
  Root, a, b: THTMLTag;
  v: string;

procedure Check(Cond: Boolean; const Msg: string);
begin
  Inc(Total);
  if Cond then WriteLn('  ok   ', Msg)
  else begin WriteLn('  FAIL ', Msg); Inc(Fails); end;
end;

function StyleOf(T: THTMLTag; const Prop: string): string;
begin
  if not T.Style.TryGetValue(Prop, Result) then Result := '';
end;

begin
  WriteLn('=== Tina4Builtins DOM-node API test ===');
  Root := THTMLTag.Create;
  Root.TagName := 'div';
  try
    { create is detached and does not dirty the live tree }
    BuiltinsDirty := False;
    a := CreateElement('SPAN');
    Check(a.TagName = 'span', 'CreateElement lowercases the tag name');
    Check(a.Parent = nil, 'a created element is detached (no parent)');
    Check(not BuiltinsDirty, 'CreateElement alone does not set BuiltinsDirty');

    { attributes + inline style, lowercased keys }
    SetAttr(a, 'ID', 'x1');
    SetStyleProp(a, 'Color', 'red');
    Check(a.GetAttribute('id') = 'x1', 'SetAttr stores (lowercased) attribute');
    Check(StyleOf(a, 'color') = 'red', 'SetStyleProp stores (lowercased) inline style');

    { append into the tree → dirties + is findable }
    BuiltinsDirty := False;
    AppendChild(Root, a);
    Check(BuiltinsDirty, 'AppendChild sets BuiltinsDirty');
    Check(ChildCount(Root) = 1, 'child appended');
    Check(ChildAt(Root, 0) = a, 'ChildAt returns the appended node');
    Check(a.Parent = Root, 'appended node points back at its new parent');
    Check(FindById(Root, 'x1') = a, 'appended node is findable by id');

    { move semantics: appending elsewhere detaches from the old parent }
    b := CreateElement('i');
    AppendChild(a, b);
    Check((ChildCount(a) = 1) and (b.Parent = a), 'nested append works');
    AppendChild(Root, b);                       // reparent b from a to Root
    Check(ChildCount(a) = 0, 'reparenting detaches from the old parent');
    Check((ChildCount(Root) = 2) and (b.Parent = Root), 'reparented under the new parent');

    { remove frees the subtree and detaches }
    BuiltinsDirty := False;
    RemoveNode(b);
    Check(BuiltinsDirty, 'RemoveNode sets BuiltinsDirty');
    Check(ChildCount(Root) = 1, 'removed node is gone from its parent');

    WriteLn;
    if Fails = 0 then WriteLn('ALL TESTS PASS')
    else WriteLn(Fails, ' of ', Total, ' FAILED');
  finally
    Root.Free;   // frees a (and any remaining subtree)
  end;
  if Fails <> 0 then Halt(1);
end.
