program test_interact;
{ REAL interaction test — drives the actual tap -> mutate -> rebuild path through
  Tina4Interact (the same unit the Win/Linux hosts use), not a smoke test.

  Every click routes through TinaTouch, and TinaFrame relayouts by calling
  GEngine.Build on the LIVE (mutated) DOM — which re-runs InjectPseudo. The page
  deliberately carries ::before/::after content, so each of the ~12 clicks below
  strips-and-reinjects the pseudo nodes: this is the exact path that used to
  raise EArgumentOutOfRangeException (the InjectPseudo double-delete) and that a
  snapshot/leakcheck run never touched because neither drives interaction.

  Assertions read LIVE DOM state back via TinaHasAttr/TinaAttr — TinaCurrentHtml
  returns the original source, not the mutated tree, so it cannot prove a toggle.
  Each assertion would flip to FAIL if the behaviour regressed:
    - checkbox toggles on/off across rebuilds
    - a radio group stays mutually exclusive
    - a <select> commits the tapped option's value through the overlay path
  Control centres come from TinaBoxTree (real laid-out geometry), so the test
  does not hard-code pixel positions for the direct controls. }
{$mode delphi}{$H+}

uses SysUtils, fpjson, jsonparser,
     Tina4RenderBackend, Tina4RasterCanvas, Tina4Interact;

const
  VW = 320; VH = 420;         // viewport, physical px (density 1 -> CSS px == physical)
  OPT_ROW_H = 44;             // Tina4Interact GOptRowH: <select> overlay row height
  { The dropdown panel sits at selectBox.y + selectBox.h + 6, with a 6px inner
    pad before the first row. Row i spans [top + i*ROW_H, +ROW_H). These mirror
    RenderSelectOverlay; if that geometry changes, the select assertion fails
    loudly (correctly) and this is the one place to update. }
  PANEL_GAP = 6;
  PANEL_PAD = 6;

var
  Canvas: TTina4RasterCanvas;
  Fails: Integer = 0; Total: Integer = 0;

procedure Check(Cond: Boolean; const Msg: string);
begin
  Inc(Total);
  if Cond then WriteLn('  ok   ', Msg)
  else begin WriteLn('  FAIL ', Msg); Inc(Fails); end;
end;

{ Depth-first search of the box-tree JSON for a node carrying "id":Id. }
function FindNode(N: TJSONData; const Id: string): TJSONObject;
var o: TJSONObject; kids: TJSONArray; i: Integer; r: TJSONObject;
begin
  Result := nil;
  if not (N is TJSONObject) then Exit;
  o := TJSONObject(N);
  if (o.IndexOfName('id') >= 0) and (o.Get('id', '') = Id) then Exit(o);
  if o.IndexOfName('children') >= 0 then
  begin
    kids := o.Get('children', TJSONArray(nil));
    if kids <> nil then
      for i := 0 to kids.Count - 1 do
      begin
        r := FindNode(kids.Items[i], Id);
        if r <> nil then Exit(r);
      end;
  end;
end;

{ Centre of the laid-out box with the given id, in physical px. Fails hard (via
  a returned negative) if the id is not in the tree. }
procedure BoxCentre(const Id: string; out cx, cy: Single; out found: Boolean);
var root: TJSONData; node: TJSONObject;
begin
  cx := -1; cy := -1; found := False;
  root := GetJSON(TinaBoxTree);
  try
    node := FindNode(root, Id);
    if node = nil then Exit;
    cx := node.Get('x', 0.0) + node.Get('w', 0.0) / 2;
    cy := node.Get('y', 0.0) + node.Get('h', 0.0) / 2;
    found := True;
  finally
    root.Free;
  end;
end;

{ Top-left/size of a box, for computing the select overlay row positions. }
procedure BoxRect(const Id: string; out bx, by, bw, bh: Single; out found: Boolean);
var root: TJSONData; node: TJSONObject;
begin
  bx := 0; by := 0; bw := 0; bh := 0; found := False;
  root := GetJSON(TinaBoxTree);
  try
    node := FindNode(root, Id);
    if node = nil then Exit;
    bx := node.Get('x', 0.0); by := node.Get('y', 0.0);
    bw := node.Get('w', 0.0); bh := node.Get('h', 0.0);
    found := True;
  finally
    root.Free;
  end;
end;

procedure Frame; begin TinaFrame(VW, VH, 1); end;

{ One tap (down then up) at physical px, then relayout — the shell's click. }
procedure Tap(x, y: Single);
begin
  TinaTouch(0, x, y);
  TinaTouch(1, x, y);
  Frame;
end;

{ Tap the centre of the control with the given id. }
function TapId(const Id: string): Boolean;
var cx, cy: Single; ok: Boolean;
begin
  BoxCentre(Id, cx, cy, ok);
  Result := ok;
  if ok then Tap(cx, cy);
end;

const PAGE =
  '<body style="margin:0;font-family:Helvetica">' +
  '<style>' +
  '  .tag::before{content:"# "}' +          // pseudo nodes injected+stripped every Build
  '  .tag::after{content:" ."}' +
  '  .note::before{content:"* "}' +
  '</style>' +
  '<h1 class="tag" style="height:40px;margin:0">Form</h1>' +
  '<label style="display:block;height:34px"><input type="checkbox" id="agree"> I agree</label>' +
  '<label class="note" style="display:block;height:34px"><input type="radio" name="plan" id="mo" checked> Monthly</label>' +
  '<label style="display:block;height:34px"><input type="radio" name="plan" id="yr"> Yearly</label>' +
  '<select id="fruit" style="display:block;margin-top:8px">' +
    '<option>Apple</option><option>Banana</option><option>Cherry</option>' +
  '</select>' +
  '<p class="tag">done</p>' +
  '</body>';

var
  selX, selY, selW, selH, rowCy: Single;
  ok: Boolean;
  i: Integer;

begin
  WriteLn('=== real interaction test (tap -> mutate -> rebuild) ===');
  Canvas := TTina4RasterCanvas.Create(VW, VH);
  try
    TinaInit(Canvas);
    TinaSetHtml(PAGE);
    Frame;   // first Build injects the ::before/::after pseudo nodes

    // ---- checkbox: toggles across rebuilds -------------------------------
    Check(not TinaHasAttr('agree', 'checked'), 'checkbox starts unchecked');
    Check(TapId('agree'), 'checkbox is hittable at its box centre');
    Check(TinaHasAttr('agree', 'checked'), 'first tap checks the checkbox');
    TapId('agree');
    Check(not TinaHasAttr('agree', 'checked'), 'second tap unchecks it');
    TapId('agree');
    Check(TinaHasAttr('agree', 'checked'), 'third tap re-checks (stable across Builds)');

    // ---- radio group: mutual exclusivity ---------------------------------
    Check(TinaHasAttr('mo', 'checked') and not TinaHasAttr('yr', 'checked'),
          'radio: Monthly checked, Yearly not (initial)');
    Check(TapId('yr'), 'radio Yearly hittable');
    Check(TinaHasAttr('yr', 'checked') and not TinaHasAttr('mo', 'checked'),
          'tapping Yearly checks it and clears Monthly (exclusive)');
    TapId('mo');
    Check(TinaHasAttr('mo', 'checked') and not TinaHasAttr('yr', 'checked'),
          'tapping Monthly back flips exclusivity the other way');

    // ---- select: commit the tapped option's value ------------------------
    Check(TinaAttr('fruit', 'value') = '', 'select has no committed value initially');
    BoxRect('fruit', selX, selY, selW, selH, ok);
    Check(ok, 'select box found in layout tree');
    // open the dropdown, then tap row index 1 ("Banana")
    Tap(selX + selW / 2, selY + selH / 2);                 // open
    rowCy := selY + selH + PANEL_GAP + PANEL_PAD + 1 * OPT_ROW_H + OPT_ROW_H / 2;
    Tap(selX + selW / 2, rowCy);                           // pick "Banana"
    Check(TinaAttr('fruit', 'value') = 'Banana',
          'tapping row 1 commits value "Banana" (got "' + TinaAttr('fruit', 'value') + '")');

    // ---- survive a burst of rebuilds on the pseudo page ------------------
    for i := 1 to 6 do TapId('agree');    // 6 more Builds, InjectPseudo each time
    Check(True, 'no crash after a burst of pseudo-page rebuilds');

  finally
    Canvas.Free;
  end;

  WriteLn(Total - Fails, '/', Total, ' assertions passed.');
  if Fails = 0 then WriteLn('ALL TESTS PASS')
  else begin WriteLn('FAILURES: ', Fails); Halt(1); end;
end.
