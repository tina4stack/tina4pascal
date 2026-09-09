program test_metrics;
{ Headless text-metrics regression.

  Tina4RasterCanvas (the canvas the headless unit tests run on) used to return
  Width=0 from MeasureText — it was built for the Lottie vector subset and had
  no text path. So every inline-block / shrink-to-fit element collapsed to its
  padding: a padded <button>Save</button> measured exactly its 28px of
  horizontal padding, with the label contributing nothing. It now approximates
  advance widths proportionally, so shrink-wrap widths are believable headless
  (the reftest suite renders through the shell canvases with real metrics and is
  unaffected). These assertions fail if MeasureText regresses to a zero width. }
{$mode delphi}{$H+}

uses SysUtils, fpjson, jsonparser,
     Tina4RenderBackend, Tina4RasterCanvas, Tina4Interact;

var Fails: Integer = 0; Total: Integer = 0;

procedure Check(Cond: Boolean; const Msg: string);
begin
  Inc(Total);
  if Cond then WriteLn('  ok   ', Msg)
  else begin WriteLn('  FAIL ', Msg); Inc(Fails); end;
end;

{ Width of the first box with the given id, from the box-tree JSON. }
function WidthOf(N: TJSONData; const Id: string): Single;
var o: TJSONObject; kids: TJSONArray; i: Integer; r: Single;
begin
  Result := -1;
  if not (N is TJSONObject) then Exit;
  o := TJSONObject(N);
  if (o.IndexOfName('id') >= 0) and (o.Get('id', '') = Id) then Exit(o.Get('w', 0.0));
  if o.IndexOfName('children') >= 0 then
  begin
    kids := o.Get('children', TJSONArray(nil));
    if kids <> nil then
      for i := 0 to kids.Count - 1 do
      begin r := WidthOf(kids.Items[i], Id); if r >= 0 then Exit(r); end;
  end;
end;

function BoxW(const Id: string): Single;
var root: TJSONData;
begin
  root := GetJSON(TinaBoxTree);
  try Result := WidthOf(root, Id); finally root.Free; end;
end;

var
  Canvas: TTina4RasterCanvas;
  wBtn, wShort, wLong: Single;
const
  PADH = 28;   // 14px left + 14px right

begin
  WriteLn('=== headless text metrics (shrink-to-fit) ===');
  Canvas := TTina4RasterCanvas.Create(400, 240);
  try
    TinaInit(Canvas);
    TinaSetHtml('<body style="margin:0;font-size:16px">' +
      '<button id="btn" style="padding:8px 14px">Save</button>' +
      '<div id="short" style="display:inline-block;padding:0 14px">Hi</div>' +
      '<div id="long"  style="display:inline-block;padding:0 14px">Hello world wide</div>' +
      '</body>');
    TinaFrame(400, 240, 1);

    wBtn := BoxW('btn');
    Check(wBtn > PADH + 10, 'padded <button> is wider than its 28px padding (got ' +
      FormatFloat('0.0', wBtn) + ')  — label text has width');

    wShort := BoxW('short');
    wLong := BoxW('long');
    Check(wShort > PADH, 'short inline-block wider than padding');
    Check(wLong > wShort + 40, 'more text → wider shrink-wrap (long ' +
      FormatFloat('0.0', wLong) + ' vs short ' + FormatFloat('0.0', wShort) + ')');
  finally
    Canvas.Free;
  end;

  WriteLn(Total - Fails, '/', Total, ' assertions passed.');
  if Fails = 0 then WriteLn('ALL TESTS PASS')
  else begin WriteLn('FAILURES: ', Fails); Halt(1); end;
end.
