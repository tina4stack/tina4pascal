program test_resizedom;
{ Regression test: a runtime-added DOM node must SURVIVE a viewport width change.

  The bug: TinaFrame re-parsed the whole document on a width change (ParseDoc),
  freeing the live DOM. An app that had added a node at runtime (e.g. the hero's
  sparkle spawner appending to #sparks, or any Tina4Builtins.AppendChild) kept a
  dangling pointer to the freed node, and the next mutation wrote into freed
  memory → crash on maximise. The fix relayouts on a width change instead of
  re-parsing, so the DOM (and app-added nodes) persists. }
{$mode delphi}{$H+}

uses SysUtils,
     Tina4RenderBackend, Tina4RasterCanvas, Tina4Interact, Tina4Builtins, Tina4HTMLDom;

var
  Canvas: TTina4RasterCanvas;
  Fails: Integer = 0;

procedure Check(Cond: Boolean; const Msg: string);
begin
  if Cond then WriteLn('  ok   ', Msg)
  else begin WriteLn('  FAIL ', Msg); Inc(Fails); end;
end;

const
  PAGE = '<body style="margin:0"><div id="box" style="position:relative;' +
         'width:100vw;height:100vh"></div></body>';

var
  box, added, found: THTMLTag;
begin
  WriteLn('=== runtime node survives a resize ===');
  Canvas := TTina4RasterCanvas.Create(400, 300);
  try
    TinaInit(Canvas);
    TinaSetHtml(PAGE);
    TinaFrame(400, 300, 1);

    box := FindById(BuiltinsRoot, 'box');
    Check(box <> nil, 'container present after initial parse');

    // add a node at runtime, like Tina4Builtins.AppendChild (the spawner path)
    added := CreateElement('i');
    SetAttr(added, 'id', 'runtime');
    AppendChild(box, added);
    TinaInvalidateLayout;
    TinaFrame(400, 300, 1);
    Check(FindById(BuiltinsRoot, 'runtime') = added, 'runtime node present before resize');

    // RESIZE: a different viewport width. Pre-fix this re-parsed and freed `added`.
    TinaFrame(800, 300, 1);
    found := FindById(BuiltinsRoot, 'runtime');
    Check(found <> nil, 'runtime node still in the DOM after a width change');
    Check(found = added, 'it is the SAME node (DOM was relayouted, not re-parsed)');

    // and a mutation on it must be safe (this is what crashed on maximise)
    SetStyleProp(added, 'left', '10px');
    TinaInvalidateLayout;
    TinaFrame(800, 300, 1);
    Check(True, 'mutating the node after resize does not corrupt the heap');

    WriteLn;
    if Fails = 0 then WriteLn('ALL TESTS PASS')
    else WriteLn(Fails, ' FAILED');
  finally
    Canvas.Free;
  end;
  if Fails <> 0 then Halt(1);
end.
