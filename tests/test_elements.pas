program test_elements;
{ Real test for the custom-element registry (both tiers), driven through the
  same Tina4Interact path the hosts use.

  TIER 1 (template expansion): a registered <nicebutton> must expand at Build
  time into a button element carrying the variant class and the onclick, its
  placeholders filled from attributes + inner HTML, idempotently across
  rebuilds, and the expanded button must be a live control (its onclick fires).

  TIER 2 (native element): a registered <sparkbox> must be painted by its Paint
  hook every frame and respond to a tap via its OnTap hook, sized by its
  registered default CSS. Neither tier required any core SameText edit for these
  specific tags — they are registered entirely through the public API here. }
{$mode delphi}{$H+}

uses SysUtils, fpjson, jsonparser,
     Tina4RenderBackend, Tina4RasterCanvas, Tina4HTMLDom,
     Tina4Interact, Tina4Elements, Tina4Events;

const VW = 320; VH = 240;

var
  Fails: Integer = 0; Total: Integer = 0;
  GClicked: Integer = 0;    // <nicebutton> onclick fired count
  GPainted: Integer = 0;    // <sparkbox> paint-hook call count

procedure Check(Cond: Boolean; const Msg: string);
begin
  Inc(Total);
  if Cond then WriteLn('  ok   ', Msg)
  else begin WriteLn('  FAIL ', Msg); Inc(Fails); end;
end;

{ Tier-1 onclick target (registered as the action "test.mark"). }
procedure OnNiceClick(const Args: string);
begin
  Inc(GClicked);
end;

{ Tier-2 paint hook — fills the box and counts calls. }
procedure PaintSpark(const Tag: THTMLTag; X, Y, W, H: Single;
  Canvas: TTina4Canvas; const St: TComputedStyle);
begin
  Inc(GPainted);
  Canvas.FillRect(X, Y, W, H, $FF2B41E6);
end;

{ Tier-2 tap hook — increments the element's own data-count and reports handled. }
function TapSpark(const Tag: THTMLTag): Boolean;
var n: Integer;
begin
  n := StrToIntDef(Tag.GetAttribute('data-count'), 0) + 1;
  Tag.Attributes.AddOrSetValue('data-count', IntToStr(n));
  Result := True;
end;

{ Count nodes with the given tag name anywhere in a box/dom JSON tree. }
function CountTag(N: TJSONData; const Tag: string): Integer;
var o: TJSONObject; kids: TJSONArray; i: Integer;
begin
  Result := 0;
  if not (N is TJSONObject) then Exit;
  o := TJSONObject(N);
  if (o.IndexOfName('tag') >= 0) and SameText(o.Get('tag', ''), Tag) then Inc(Result);
  if o.IndexOfName('children') >= 0 then
  begin
    kids := o.Get('children', TJSONArray(nil));
    if kids <> nil then
      for i := 0 to kids.Count - 1 do Result := Result + CountTag(kids.Items[i], Tag);
  end;
end;

{ First node with tag name; nil if none. }
function FirstTag(N: TJSONData; const Tag: string): TJSONObject;
var o: TJSONObject; kids: TJSONArray; i: Integer; r: TJSONObject;
begin
  Result := nil;
  if not (N is TJSONObject) then Exit;
  o := TJSONObject(N);
  if (o.IndexOfName('tag') >= 0) and SameText(o.Get('tag', ''), Tag) then Exit(o);
  if o.IndexOfName('children') >= 0 then
  begin
    kids := o.Get('children', TJSONArray(nil));
    if kids <> nil then
      for i := 0 to kids.Count - 1 do
      begin r := FirstTag(kids.Items[i], Tag); if r <> nil then Exit(r); end;
  end;
end;

function DomBtnClass: string;   // class attr of the first <button> in the DOM
var root: TJSONData; b: TJSONObject;
begin
  Result := '';
  root := GetJSON(TinaDumpDom);
  try
    b := FirstTag(root, 'button');
    if b <> nil then Result := b.Get('class', '');
  finally root.Free; end;
end;

function BoxTagCount(const Tag: string): Integer;
var root: TJSONData;
begin
  root := GetJSON(TinaBoxTree);
  try Result := CountTag(root, Tag); finally root.Free; end;
end;

{ Centre of the first box with the given tag; ok=False if absent/zero-width. }
procedure TagCenter(const Tag: string; out cx, cy: Single; out ok: Boolean);
var root: TJSONData; s: TJSONObject;
begin
  cx := 0; cy := 0; ok := False;
  root := GetJSON(TinaBoxTree);
  try
    s := FirstTag(root, Tag);
    if s <> nil then
    begin
      cx := s.Get('x', 0.0) + s.Get('w', 0.0) / 2;
      cy := s.Get('y', 0.0) + s.Get('h', 0.0) / 2;
      ok := (s.Get('w', 0.0) > 0);
    end;
  finally root.Free; end;
end;

var
  Canvas: TTina4RasterCanvas;
  cx, cy: Single; ok: Boolean;
  i, before: Integer;

const PAGE =
  '<body style="margin:0">' +
  '<nicebutton id="nb" variant="primary" onclick="test.mark()">Save</nicebutton>' +
  '<sparkbox id="sp"></sparkbox>' +
  '</body>';

begin
  WriteLn('=== custom-element registry (Tier 1 + Tier 2) ===');

  RegisterElement('nicebutton',
    '<button class="nb nb-{variant}" onclick="{onclick}">{children}</button>',
    'nicebutton{display:inline-block} ' +
    'button.nb{display:inline-block;padding:8px 14px;border:0;border-radius:10px}');
  RegisterNativeElement('sparkbox', @PaintSpark, @TapSpark,
    'sparkbox{display:inline-block;width:120px;height:40px}');
  RegisterAction('test.mark', TTina4ActionProc(@OnNiceClick));

  Canvas := TTina4RasterCanvas.Create(VW, VH);
  try
    TinaInit(Canvas);
    TinaSetHtml(PAGE);
    TinaFrame(VW, VH, 1);

    // ---- Tier 1: expansion --------------------------------------------
    Check(BoxTagCount('button') = 1, 'nicebutton expanded into exactly one <button>');
    Check(DomBtnClass = 'nb nb-primary', '{variant} filled the class (nb nb-primary), got "' + DomBtnClass + '"');

    // ---- Tier 1: the expanded button is a live control ----------------
    TagCenter('button', cx, cy, ok);
    Check(ok, 'expanded button has a box to tap');
    before := GClicked;
    TinaTouch(0, cx, cy); TinaTouch(1, cx, cy); TinaFrame(VW, VH, 1);   // tap the button
    Check(GClicked = before + 1, 'onclick propagated — tapping fires the action once');

    // ---- Tier 1: idempotent across rebuilds ---------------------------
    for i := 1 to 5 do TinaFrame(VW, VH, 1);
    Check(BoxTagCount('button') = 1, 'still exactly one <button> after 5 rebuilds (no accumulation)');
    TagCenter('button', cx, cy, ok);
    before := GClicked;
    TinaTouch(0, cx, cy); TinaTouch(1, cx, cy); TinaFrame(VW, VH, 1);
    Check(GClicked = before + 1, 'button still interactive after rebuilds');

    // ---- Tier 2: paint hook -------------------------------------------
    Check(GPainted > 0, 'sparkbox Paint hook ran during a frame');
    Check(BoxTagCount('sparkbox') = 1, 'sparkbox kept its own tag (native, not expanded)');

    // ---- Tier 2: default CSS sized it + tap hook ----------------------
    TagCenter('sparkbox', cx, cy, ok);
    Check(ok, 'sparkbox sized by its registered default CSS (has a box)');
    if ok then
    begin
      Check(TinaAttr('sp', 'data-count') = '', 'sparkbox starts with no data-count');
      TinaTouch(0, cx, cy); TinaTouch(1, cx, cy); TinaFrame(VW, VH, 1);
      Check(TinaAttr('sp', 'data-count') = '1', 'tap 1 → OnTap set data-count=1');
      TinaTouch(0, cx, cy); TinaTouch(1, cx, cy); TinaFrame(VW, VH, 1);
      Check(TinaAttr('sp', 'data-count') = '2', 'tap 2 → OnTap set data-count=2');
    end;

  finally
    Canvas.Free;
    ClearElements;
  end;

  WriteLn(Total - Fails, '/', Total, ' assertions passed.');
  if Fails = 0 then WriteLn('ALL TESTS PASS')
  else begin WriteLn('FAILURES: ', Fails); Halt(1); end;
end.
