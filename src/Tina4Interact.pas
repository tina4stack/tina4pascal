unit Tina4Interact;

{ Platform-neutral interaction engine for the Tina4 native renderer.

  This is the shared brain behind every mobile/desktop shell (Android, iOS,
  Cocoa, Windows, Linux). It owns the live document, layout, scrolling with
  momentum, focus, the text caret, and the <select> dropdown overlay — and it
  talks ONLY to the abstract TTina4Canvas contract, so a shell just has to:

    1. create a canvas (its native TTina4Canvas subclass) and call TinaInit;
    2. per frame: canvas.BeginFrame(...) then TinaFrame(wPx, hPx, density);
    3. forward touches to TinaTouch and typed characters to TinaKey;
    4. act on TinaTouch's return code (show/hide keyboard, fling, pick file,
       capture photo) and feed results back via TinaSetFile / TinaSetPhoto.

  Interaction model: the document is parsed ONCE into a live DOM. A tap or a
  keystroke MUTATES that DOM (a checkbox's `checked`, an input's `value`, a
  select's `value`) and re-runs layout only — the tree is never re-parsed, so
  edits persist. The focused control is GFocusedTag; its text lives in the DOM
  `value` attribute, exactly where the layout and caret code read it.

  Coordinates arrive from the shell in physical device pixels; the engine lays
  out in CSS px (= px / density) and scales the canvas up, so text has a
  sensible physical size and media queries see a phone-width viewport. }

{$mode delphi}{$H+}

interface

uses
  Tina4RenderBackend;

{ Return codes from TinaTouch (a tap/gesture): what the shell should do next. }
const
  TINA_NONE      = 0;   // nothing
  TINA_SHOW_KBD  = 1;   // a text field gained focus — raise the soft keyboard
  TINA_HIDE_KBD  = 2;   // focus left a text field — dismiss the keyboard
  TINA_FLING     = 3;   // begin a momentum fling (drive TinaTick per frame)
  TINA_PICK_FILE = 4;   // an <input type=file> was tapped — open the picker
  TINA_CAPTURE   = 5;   // a <camera> was tapped — open the capture UI

{ Wire up the engine to a shell canvas. Call once, before the first frame. }
procedure TinaInit(Canvas: TTina4Canvas);
{ Load a document ("@demo" = the built-in interactive demo). }
procedure TinaSetHtml(const Html: string);
{ ---- Frond templates ---------------------------------------------------
  Render a page from a Frond template + a JSON context (app state) and load it.
  The template is remembered, so on a state change you re-render with just the
  new context via TinaRenderContext — the template-driven app model. }
procedure TinaSetTemplateDir(const Dir: string);   // for {% include %}/{% extends %}
procedure TinaRenderTemplate(const Template, JsonContext: string);
procedure TinaRenderContext(const JsonContext: string);   // reuse last template
{ Lay out (if needed) and paint one frame. The shell must have already called
  Canvas.BeginFrame for this frame; WPx/HPx are the surface size in physical
  pixels and Density is points-per-pixel (1 on a non-scaled desktop). }
procedure TinaFrame(WPx, HPx: Integer; Density: Single);
{ A touch: Action 0=down, 1=up, 2=move; X/Y in physical pixels. Returns one of
  the TINA_* codes. }
function TinaTouch(Action: Integer; X, Y: Single): Integer;
{ Wheel/trackpad scroll by (DX,DY) at (X,Y) device px — scrolls the box under
  the cursor, or the page. (Desktop shells deliver deltas; the engine scrolls.) }
procedure TinaScrollBy(X, Y, DX, DY: Single);
{ Cursor moved (desktop mouse, no button) → drives the :hover pseudo-class.
  Pass device px, like TinaTouch. Never called on touch platforms. }
procedure TinaHover(X, Y: Single);
{ Advance momentum one frame; 1 = keep animating. }
function TinaTick: Integer;
{ 1 once if the just-loaded document autofocused an input (raise the keyboard). }
function TinaWantsKeyboard: Integer;
{ Drop input focus (e.g. the shell's keyboard was dismissed). }
procedure TinaBlurInput;
{ Toggle the caret blink phase; 1 while a field is focused (keep blinking). }
function TinaBlinkCaret: Integer;
{ A typed character: 8=backspace, 10=newline, >=32 printable. }
procedure TinaKey(Codepoint: Integer);
{ Focused control kind for IME config: 0 none, 1 text, 2 textarea. }
function TinaFocusKind: Integer;
{ Move focus to the next text field; returns the new kind (0 = none/at end). }
function TinaFocusNext: Integer;
{ A filename chosen by the system picker → the pending <input type=file>. }
procedure TinaSetFile(const Name: string);
{ A captured photo path → <img id="shot"> (and stamps the camera control). }
procedure TinaSetPhoto(const Path: string);

{ Set a default HTTP header sent on every request — Http:Get, API calls, and
  <include> fetches. Call once after login, e.g.
  TinaSetHeader('Authorization', 'Bearer ' + token). '' value clears it. }
procedure TinaSetHeader(const Name, Value: string);

{ Force a relayout on the next frame — the shells call this when an async
  resource (e.g. a remote image just downloaded to the cache) becomes ready,
  so the layout re-runs LoadImage and the image drops in. }
procedure TinaInvalidateLayout;

{ Dark mode: drives the `@media (prefers-color-scheme: dark)` rules (and its
  :root var overrides). The shell sets it from the OS appearance; relayout re-
  cascades. Off by default (light). }
procedure TinaSetColorScheme(Dark: Boolean);

{ Capture protection: while ON, every element marked class="sensitive" (or a
  <secure> tag) paints as a solid redaction bar — its content is never drawn.
  The shell calls this the instant the OS reports a screen capture / recording
  starts (SetWindowDisplayAffinity, NSWindowSharingType, FLAG_SECURE), and clears
  it when capture ends. Paint-time only: no reflow, and the live user is
  unaffected. Repaint after calling. }
procedure TinaSetCaptureProtected(Protect: Boolean);

implementation

uses
  SysUtils, Classes, Math, DateUtils, Generics.Collections, fpjson, jsonparser,
  Tina4HTMLDom, Tina4HTMLLayout, Tina4Events, Tina4Frond, Tina4Http, Tina4Services;

var
  GFrond: TFrond = nil;         // the template engine (created on first use)
  GTemplate: string = '';       // last template, for TinaRenderContext
  GCanvas: TTina4Canvas = nil;
  GParser: THTMLParser = nil;
  GSheet: TCSSStyleSheet = nil;
  GEngine: TLayoutEngine = nil;
  GRoot: TLayoutBox = nil;
  GHtml: string = '';
  GFontsDone: TStringList = nil; // @font-face families already registered (this canvas)
  GDocDirty: Boolean = True;     // needs a full re-parse (new document)
  GLayoutDirty: Boolean = False; // DOM mutated → re-run layout only
  GLayoutW: Single = -1;
  GDensity: Single = 1;
  GViewH: Single = 0;           // CSS px
  GScrollY: Single = 0;         // CSS px
  // touch + momentum (all CSS px). A gesture locks onto GDragBox on touch-down
  // (an inner overflow scroller, or nil = the page) and flings on both axes.
  GDownX, GDownY, GLastX, GLastY: Single;
  GVelX, GVelY, GFlingVX, GFlingVY: Single;
  GDragBox: TLayoutBox = nil;
  GMoved: Boolean = False;
  // interaction state
  GFocusedTag: THTMLTag = nil;   // focused text/textarea control (nil = none)
  GAutoKeyboard: Boolean = False;
  GDemo: Boolean = False;
  GCount: Integer = 0;
  GActionsReady: Boolean = False;
  // open <select> dropdown overlay (nil = closed). Painted on top of the page;
  // rows are hit-tested in screen space.
  GOpenSelect: THTMLTag = nil;
  GRangeDrag: THTMLTag = nil;          // <input type=range> being dragged
  GFileTag: THTMLTag = nil;            // <input type=file>/<camera> awaiting a result
  GOptCount: Integer = 0;
  GOptTop: array[0..63] of Single;    // screen-y of each option row
  GOptRowH: Single = 44;
  GOverX, GOverY, GOverW: Single;
  GScrollToFocus: Boolean = False;    // bring the focused field on-screen next paint
  GDarkMode: Boolean = False;         // prefers-color-scheme: dark active?
  // open <input type=date> calendar overlay (nil = closed)
  GOpenDate: THTMLTag = nil;
  GCalYear: Integer = 0; GCalMonth: Integer = 1;   // the month on show
  GCalX, GCalW, GCalGridY, GCalCellW, GCalCellH: Single;
  GCalHdrY, GCalHdrH, GCalTodayY, GCalTodayH: Single;
  GCalFirstDow, GCalDays: Integer;    // weekday of the 1st (0=Sun), days in month
  GYearMinusMs, GYearPlusMs: QWord;   // last « / » tap — a quick 2nd tap = ±10 years

{ ---- DOM helpers ------------------------------------------------------- }
procedure SetAttr(Tag: THTMLTag; const Name, Value: string);
begin
  if Tag <> nil then Tag.Attributes.AddOrSetValue(LowerCase(Name), Value);
end;

procedure DelAttr(Tag: THTMLTag; const Name: string);
begin
  if Tag <> nil then Tag.Attributes.Remove(LowerCase(Name));
end;

{ First descendant (or self) with id=Id. }
function FindById(Node: THTMLTag; const Id: string): THTMLTag;
var c: THTMLTag;
begin
  Result := nil;
  if Node = nil then Exit;
  if Node.GetAttribute('id') = Id then Exit(Node);
  for c in Node.Children do
  begin
    Result := FindById(c, Id);
    if Result <> nil then Exit;
  end;
end;

{ Replace an element's text with a single #text child. }
procedure SetElemText(Tag: THTMLTag; const S: string);
var t, c: THTMLTag;
begin
  if Tag = nil then Exit;
  for c in Tag.Children do
    if c.TagName = '#text' then begin c.Text := S; Exit; end;
  t := THTMLTag.Create;
  t.TagName := '#text'; t.Text := S; t.Parent := Tag;
  Tag.Children.Add(t);
end;

procedure BlurAll;
begin
  if GFocusedTag <> nil then GFocusedTag.IsFocused := False;
  GFocusedTag := nil;
end;

procedure FocusTag(Tag: THTMLTag);
begin
  BlurAll;
  GFocusedTag := Tag;
  if Tag <> nil then Tag.IsFocused := True;
  Tina4CaretVisible := True;
end;

{ Control kind of a tag, but ckNone for anything that is NOT a form-control
  element. (Tina4HTMLLayout.ControlKindOf assumes it is only ever called on a
  real control and falls back to ckTextInput otherwise — so a bare tap on a
  <label>/<div>/<span> must be filtered here first, or it would "focus" text.) }
function CtrlKind(Tag: THTMLTag): TControlKind;
begin
  if (Tag <> nil) and IsFormControlTag(Tag.TagName) then Result := ControlKindOf(Tag)
  else Result := ckNone;
end;

{ Collect focusable text/textarea controls (skipping disabled) in doc order. }
procedure CollectInputs(Node: THTMLTag; List: Classes.TList);
var c: THTMLTag;
begin
  if Node = nil then Exit;
  if (CtrlKind(Node) in [ckTextInput, ckTextarea]) and
     not Node.HasAttribute('disabled') then List.Add(Node);
  for c in Node.Children do CollectInputs(c, List);
end;

{ 0 = nothing focused, 1 = text input, 2 = textarea. Drives the IME config. }
function FocusKindOf: Integer;
begin
  if GFocusedTag = nil then Exit(0);
  case CtrlKind(GFocusedTag) of
    ckTextarea:  Result := 2;
    ckTextInput: Result := 1;
  else Result := 0;
  end;
end;

{ First control descendant (or self) of Node, else nil. }
function FindControlIn(Node: THTMLTag): THTMLTag;
var c: THTMLTag;
begin
  Result := nil;
  if Node = nil then Exit;
  if CtrlKind(Node) <> ckNone then Exit(Node);
  for c in Node.Children do
  begin
    Result := FindControlIn(c);
    if Result <> nil then Exit;
  end;
end;

{ If the tap landed on (or inside) a <label>, the control that label activates —
  by `for=id`, by wrapping the control, or (Tina4 convenience) a control sibling
  in the same row. nil if this is not a label. }
function LabelTarget(Node: THTMLTag): THTMLTag;
var lbl, c, ctl: THTMLTag;
begin
  Result := nil;
  lbl := Node;
  while (lbl <> nil) and not SameText(lbl.TagName, 'label') do lbl := lbl.Parent;
  if lbl = nil then Exit;
  if lbl.HasAttribute('for') then
  begin
    ctl := FindById(GParser.Root, lbl.GetAttribute('for'));
    if (ctl <> nil) and (CtrlKind(ctl) <> ckNone) then Exit(ctl);
  end;
  ctl := FindControlIn(lbl);          // control nested in the label
  if ctl <> nil then Exit(ctl);
  if lbl.Parent <> nil then           // a control beside it in the same row
    for c in lbl.Parent.Children do
      if CtrlKind(c) <> ckNone then Exit(c);
end;

{ The actionable element under a point — an onclick target or a button/checkbox/
  radio — for :active-style press feedback. Text inputs are excluded (they get a
  caret, not a press fill). Platform-agnostic: same result on every shell. }
function PressTargetAt(cx, cy: Single): THTMLTag;
var hit, ctrl: THTMLTag; k: TControlKind;
begin
  Result := nil;
  if GRoot = nil then Exit;
  hit := HitTest(GRoot, cx, cy + GScrollY);
  ctrl := LabelTarget(hit);
  if ctrl = nil then
  begin
    ctrl := hit;
    while (ctrl <> nil) and (CtrlKind(ctrl) = ckNone) and
          not ctrl.HasAttribute('onclick') do
      ctrl := ctrl.Parent;
  end;
  if ctrl = nil then Exit;
  k := CtrlKind(ctrl);
  if ctrl.HasAttribute('onclick') or (k = ckButton) or (k = ckCheckbox)
     or (k = ckRadio) or (k = ckFile) then
    Result := ctrl;
end;

{ The <input type=range> under the finger (walking up from the hit), or nil. }
function RangeAt(cx, cy: Single): THTMLTag;
var ctrl: THTMLTag;
begin
  Result := nil;
  if GRoot = nil then Exit;
  ctrl := HitTest(GRoot, cx, cy + GScrollY);
  while (ctrl <> nil) and (CtrlKind(ctrl) <> ckRange) do ctrl := ctrl.Parent;
  Result := ctrl;
end;

{ Set a range's value from a touch X (snapped to step), so dragging works. }
procedure SetRangeFromX(tag: THTMLTag; screenX: Single);
var box: TLayoutBox; mn, mx, st, frac, val: Single;
begin
  box := FindBoxForTag(GRoot, tag);
  if (box = nil) or (box.W <= 0) then Exit;
  mn := StrToFloatDef(tag.GetAttribute('min'), 0);
  mx := StrToFloatDef(tag.GetAttribute('max'), 100);
  if mx <= mn then mx := mn + 1;
  st := StrToFloatDef(tag.GetAttribute('step'), 1); if st <= 0 then st := 1;
  frac := (screenX - box.X) / box.W;
  if frac < 0 then frac := 0; if frac > 1 then frac := 1;
  val := mn + frac * (mx - mn);
  val := mn + Round((val - mn) / st) * st;      // snap to step
  if val > mx then val := mx; if val < mn then val := mn;
  if Abs(val - Round(val)) < 0.001 then
    tag.Attributes.AddOrSetValue('value', IntToStr(Round(val)))
  else
    tag.Attributes.AddOrSetValue('value', FloatToStrF(val, ffGeneral, 6, 2));
end;

var
  GActiveTag: THTMLTag = nil;    // element with the :active pseudo-class (pressed)
  GHoverTag: THTMLTag = nil;     // element with the :hover pseudo-class (cursor/finger over)

{ Dirty layout so a pseudo-class change re-applies its CSS — but only when the
  sheet actually uses :hover/:active/:focus, so a normal page pays nothing. }
procedure PseudoDirty;
begin
  if (GSheet <> nil) and GSheet.HasInteractiveSelectors then GLayoutDirty := True;
end;

{ Set the :hover element (nil to clear). }
procedure SetHoverTag(T: THTMLTag);
begin
  if T = GHoverTag then Exit;
  if GHoverTag <> nil then GHoverTag.IsHovered := False;
  GHoverTag := T;
  if GHoverTag <> nil then GHoverTag.IsHovered := True;
  PseudoDirty;
end;

{ Set the :active element (nil to clear). A press is the touch equivalent of a
  hover, so it drives BOTH :active and :hover — a page styled with either gives
  feedback on touch. On desktop the cursor already set hover; this is a no-op there. }
procedure SetActiveTag(T: THTMLTag);
begin
  if T <> GActiveTag then
  begin
    if GActiveTag <> nil then GActiveTag.IsActive := False;
    GActiveTag := T;
    if GActiveTag <> nil then GActiveTag.IsActive := True;
    PseudoDirty;
  end;
  SetHoverTag(T);
end;

{ Clear `checked` from every radio in the same name-group as Tag. }
procedure ClearRadioGroup(Node: THTMLTag; const GroupName: string);
var c: THTMLTag;
begin
  if Node = nil then Exit;
  if (CtrlKind(Node) = ckRadio) and
     (Node.GetAttribute('name') = GroupName) then
    DelAttr(Node, 'checked');
  for c in Node.Children do ClearRadioGroup(c, GroupName);
end;

{ ---- interactive demo document (state → HTML) ------------------------- }
function BuildDemo: string;
var i: Integer; list, chips: string; hue: array[0..4] of string;
begin
  list := '';
  for i := 1 to 24 do
    list := list + '<div class="item">Scrollable row ' + IntToStr(i) + '</div>';
  hue[0] := '#4F46E5'; hue[1] := '#ff5aa0'; hue[2] := '#1aa85b';
  hue[3] := '#ffb020'; hue[4] := '#8b5cf6';
  chips := '';
  for i := 1 to 10 do
    chips := chips + '<span class="chip" style="background:' + hue[i mod 5] +
      '">' + IntToStr(i) + '</span>';
  Result :=
    '<!doctype html><html><head><style>' +
    'body{font-family:sans-serif;background:#fbfaf7;color:#15162e;margin:0;padding:16px}' +
    'h1{font-size:22px;margin:0 0 2px}.sub{color:#5b5c78;margin:0 0 16px;font-size:13px}' +
    '.card{background:#fff;border:1px solid #e6e5f0;border-radius:16px;padding:16px;margin-bottom:12px}' +
    '.big{font-size:40px;font-weight:bold;color:#4F46E5}' +
    '.btn{background:#4F46E5;color:#fff;border-radius:11px;padding:12px 18px;font-weight:bold;font-size:18px}' +
    '.btn2{background:#f3f2fb;color:#15162e;border:1px solid #e6e5f0;border-radius:11px;padding:12px 16px}' +
    '.rowc{display:flex;gap:10px;align-items:center}' +
    '.item{padding:12px;border-bottom:1px solid #eee}' +
    'input{border:1px solid #c9c8dd;border-radius:10px;padding:12px;font-size:16px}' +
    '.strip{overflow-x:auto;white-space:nowrap}' +
    '.chip{display:inline-block;vertical-align:middle;width:120px;height:80px;' +
      'border-radius:14px;color:#fff;font-size:28px;font-weight:bold;' +
      'text-align:center;padding-top:24px;margin-right:10px}' +
    '</style></head><body>' +
    '<h1>Interactive demo</h1>' +
    '<p class="sub">Vertical + horizontal scroll · fling · tap · type.</p>' +
    '<div class="card"><div class="rowc">' +
      '<span class="btn2" onclick="Counter:Dec()">' + #$E2#$88#$92 + '</span>' +
      '<span class="big" id="count">' + IntToStr(GCount) + '</span>' +
      '<span class="btn" onclick="Counter:Inc()">+</span>' +
      '<span class="btn2" onclick="Counter:Reset()">reset</span>' +
    '</div></div>' +
    '<div class="card">' +
      '<div class="sub" style="margin-bottom:8px">Autofocused &mdash; just start typing:</div>' +
      '<input type="text" value="" placeholder="Type something' +
        #$E2#$80#$A6 + '" autofocus>' +
    '</div>' +
    '<div class="sub" style="margin:0 0 6px">Swipe sideways ' + #$E2#$86#$94 + '</div>' +
    '<div class="card strip">' + chips + '</div>' +
    '<div class="card" style="padding:0">' + list + '</div>' +
    '</body></html>';
end;

{ ---- registered actions (the app model) ------------------------------- }
procedure SyncCount;
var el: THTMLTag;
begin
  if GParser = nil then Exit;
  el := FindById(GParser.Root, 'count');
  if el <> nil then begin SetElemText(el, IntToStr(GCount)); GLayoutDirty := True; end;
end;

procedure ActInc(const Args: string);   begin Inc(GCount); SyncCount; end;
procedure ActDec(const Args: string);   begin Dec(GCount); SyncCount; end;
procedure ActReset(const Args: string); begin GCount := 0; SyncCount; end;

{ set the text of an element by id and re-lay-out }
procedure SetById(const Id, Text: string);
var el: THTMLTag;
begin
  if GParser = nil then Exit;
  el := FindById(GParser.Root, Id);
  if el <> nil then begin SetElemText(el, Text); GLayoutDirty := True; end;
end;

{ HTTP demo: fetch a URL (arg) and drop the body into #result. The callback runs
  on the main thread via HttpPump, so touching the DOM is safe. }
procedure OnHttpResult(const R: TTina4HttpResponse);
begin
  if R.Ok then SetById('result', Copy(R.Body, 1, 4000))
  else if R.Error <> '' then SetById('result', 'Network error: ' + R.Error)
  else SetById('result', 'HTTP ' + IntToStr(R.Status) + #10 + Copy(R.Body, 1, 4000));
end;

procedure ActHttpGet(const Args: string);
begin
  SetById('result', 'Loading ' + Args + ' …');
  HttpGet(Trim(Args), @OnHttpResult);
end;

procedure EnsureActions;
begin
  if GActionsReady then Exit;
  RegisterAction('Counter:Inc', @ActInc);
  RegisterAction('Counter:Dec', @ActDec);
  RegisterAction('Counter:Reset', @ActReset);
  RegisterAction('Http:Get', @ActHttpGet);
  GActionsReady := True;
end;

function BodyBg: TTina4Color; begin Result := $FFFBFAF7; end;

{ Focus the first input[autofocus] in the tree, if any. }
function AutofocusFirst(Node: THTMLTag): Boolean;
var c: THTMLTag;
begin
  Result := False;
  if Node = nil then Exit;
  if (CtrlKind(Node) in [ckTextInput, ckTextarea]) and
     Node.HasAttribute('autofocus') then
  begin FocusTag(Node); Exit(True); end;
  for c in Node.Children do
    if AutofocusFirst(c) then Exit(True);
end;

{ ---- <include src="…"> — fetch an HTML snippet and splice it into the DOM ----

  <include> is replaced (not wrapped) by the fetched fragment, so its content
  joins the parent flow naturally. The fetch is async; a stable marker attribute
  lets the callback re-find the node, so an intervening re-parse can't dangle.
  Auth travels as headers: a global default (HttpSetHeader) OR per-tag
  attributes — authorization="Bearer …" / bearer="…" — which Frond can template
  in. `sandbox` neutralises a remote/untrusted snippet (drops script/iframe/
  object/embed and every on* handler) for adverts and third-party content. }

var
  GIncSeq: Integer = 0;                 // unique marker per include
  GIncPending: TStringList = nil;       // reqId → "marker|src"

procedure LoadIncludes(Root: THTMLTag); forward;
procedure InjectInclude(const Marker, Html: string); forward;
procedure OnIncludeResult(const R: TTina4HttpResponse); forward;

{ Strip interactivity from an untrusted subtree: dangerous tags + on* handlers. }
procedure SandboxSubtree(Node: THTMLTag);
var i: Integer; c: THTMLTag; keys: array of string; k: string;
begin
  if Node = nil then Exit;
  for i := Node.Children.Count - 1 downto 0 do
  begin
    c := Node.Children[i];
    if SameText(c.TagName, 'script') or SameText(c.TagName, 'iframe')
       or SameText(c.TagName, 'object') or SameText(c.TagName, 'embed') then
    begin
      Node.Children.Delete(i); c.Parent := nil; c.Free; Continue;
    end;
    SandboxSubtree(c);
  end;
  if Node.Attributes <> nil then
  begin
    SetLength(keys, 0);
    for k in Node.Attributes.Keys do
      if (Length(k) >= 2) and SameText(Copy(k, 1, 2), 'on') then
      begin SetLength(keys, Length(keys) + 1); keys[High(keys)] := k; end;
    for k in keys do Node.Attributes.Remove(k);
  end;
end;

function FindByMarker(Node: THTMLTag; const Marker: string): THTMLTag;
var c: THTMLTag;
begin
  Result := nil;
  if Node = nil then Exit;
  if Node.GetAttribute('data-tina4-inc') = Marker then Exit(Node);
  for c in Node.Children do
  begin
    Result := FindByMarker(c, Marker);
    if Result <> nil then Exit;
  end;
end;

{ Per-include auth header, from attributes (Frond can template the value in). }
function IncHeadersOf(Node: THTMLTag): string;
begin
  if Node.HasAttribute('authorization') then
    Result := 'Authorization: ' + Node.GetAttribute('authorization')
  else if Node.HasAttribute('bearer') then
    Result := 'Authorization: Bearer ' + Node.GetAttribute('bearer')
  else
    Result := '';
end;

procedure InjectInclude(const Marker, Html: string);
var
  inc, parent, c: THTMLTag; fragP: THTMLParser; newNodes: TList<THTMLTag>;
  i, idx, k: Integer; sandboxed: Boolean;
begin
  if GParser = nil then Exit;
  inc := FindByMarker(GParser.Root, Marker);
  if inc = nil then Exit;                 // node gone (a re-parse happened)
  parent := inc.Parent;
  if parent = nil then Exit;
  idx := parent.Children.IndexOf(inc);
  if idx < 0 then Exit;
  sandboxed := inc.HasAttribute('sandbox');
  fragP := THTMLParser.Create;
  newNodes := TList<THTMLTag>.Create;
  try
    fragP.Parse(Html);
    for i := 0 to fragP.StyleBlocks.Count - 1 do   // fragment's own <style>
      GSheet.AddCSS(fragP.StyleBlocks[i]);
    while fragP.Root.Children.Count > 0 do          // detach so Free won't take them
    begin
      c := fragP.Root.Children[0];
      fragP.Root.Children.Delete(0);
      c.Parent := nil;
      if sandboxed then SandboxSubtree(c);
      newNodes.Add(c);
    end;
    parent.Children.Delete(idx);                    // replace <include> with the nodes
    inc.Parent := nil;
    for k := newNodes.Count - 1 downto 0 do
    begin
      newNodes[k].Parent := parent;
      parent.Children.Insert(idx, newNodes[k]);
    end;
    inc.Free;
    for k := 0 to newNodes.Count - 1 do             // includes nested in the fragment
      LoadIncludes(newNodes[k]);
  finally
    newNodes.Free;
    fragP.Free;
  end;
  GLayoutDirty := True;
end;

procedure OnIncludeResult(const R: TTina4HttpResponse);
var v, marker, src, msg: string; p: Integer;
begin
  if GIncPending = nil then Exit;
  v := GIncPending.Values[IntToStr(R.Id)];
  if v = '' then Exit;
  GIncPending.Values[IntToStr(R.Id)] := '';
  p := Pos('|', v);
  marker := Copy(v, 1, p - 1); src := Copy(v, p + 1, MaxInt);
  if R.Ok then
  begin
    CachePut('inc:' + src, R.Body, 300);            // 5-min cache
    InjectInclude(marker, R.Body);
  end
  else
  begin
    if R.Error <> '' then msg := R.Error else msg := 'HTTP ' + IntToStr(R.Status);
    InjectInclude(marker,
      '<div style="color:#b00020;font-size:12px;padding:6px">include failed: '
      + msg + '</div>');
  end;
end;

procedure CollectIncludes(Node: THTMLTag; List: TList<THTMLTag>);
var c: THTMLTag;
begin
  if Node = nil then Exit;
  if SameText(Node.TagName, 'include') and Node.HasAttribute('src')
     and not Node.HasAttribute('data-tina4-inc') then
  begin
    Inc(GIncSeq);
    Node.Attributes.AddOrSetValue('data-tina4-inc', IntToStr(GIncSeq));
    List.Add(Node);
  end;
  for c in Node.Children do CollectIncludes(c, List);
end;

procedure ProcessInclude(Node: THTMLTag);
var src, hdrs, cached, marker: string; reqId: Integer;
begin
  marker := Node.GetAttribute('data-tina4-inc');
  src := Trim(Node.GetAttribute('src'));
  if src = '' then Exit;
  if CacheGet('inc:' + src, cached) then
  begin
    InjectInclude(marker, cached);                  // instant, from cache
    Exit;
  end;
  if GIncPending = nil then GIncPending := TStringList.Create;
  hdrs := IncHeadersOf(Node);
  reqId := HttpGetEx(src, hdrs, @OnIncludeResult);
  GIncPending.Values[IntToStr(reqId)] := marker + '|' + src;
end;

{ Scan the tree, mark every un-loaded <include>, then fetch/inject each. Marking
  before processing keeps the traversal clean of the mutations inject causes. }
procedure LoadIncludes(Root: THTMLTag);
var list: TList<THTMLTag>; i: Integer;
begin
  list := TList<THTMLTag>.Create;
  try
    CollectIncludes(Root, list);
    for i := 0 to list.Count - 1 do ProcessInclude(list[i]);
  finally
    list.Free;
  end;
end;

{ Full re-parse: build DOM + stylesheet + engine + layout. }
{ @font-face: hand each declared (family, url) to the canvas so the shell can
  fetch + disk-cache it (like an <img>) and make the family name resolvable.
  Registration is idempotent per family — the shell caches the file, and we
  skip families already handed over this session. }
procedure LoadFontFaces;
var
  i: Integer;
  fam, url, key: string;
begin
  if (GSheet = nil) or (GCanvas = nil) then Exit;
  if GFontsDone = nil then
  begin
    GFontsDone := TStringList.Create;
    GFontsDone.Sorted := True;
    GFontsDone.Duplicates := dupIgnore;
  end;
  for i := 0 to GSheet.FontFaceCount - 1 do
  begin
    GSheet.GetFontFace(i, fam, url);
    if (fam = '') or (url = '') then Continue;
    key := LowerCase(fam) + '|' + url;
    if GFontsDone.IndexOf(key) >= 0 then Continue;
    GFontsDone.Add(key);
    GCanvas.RegisterFont(fam, url);   // shell fetches/caches + registers
  end;
end;

procedure ParseDoc(W: Single);
var i: Integer;
begin
  BlurAll;
  GActiveTag := nil; GHoverTag := nil;   // old DOM about to be freed — drop refs
  if GParser <> nil then FreeAndNil(GParser);
  if GSheet <> nil then FreeAndNil(GSheet);
  if GEngine <> nil then FreeAndNil(GEngine);
  if GRoot <> nil then FreeAndNil(GRoot);
  GParser := THTMLParser.Create;
  GParser.Parse(GHtml);
  GSheet := TCSSStyleSheet.Create;
  for i := 0 to GParser.StyleBlocks.Count - 1 do
    GSheet.AddCSS(GParser.StyleBlocks[i]);
  GSheet.SetMediaContext(W, GDarkMode);   // @media: viewport width + dark scheme
  LoadFontFaces;                          // @font-face: register downloadable fonts
  GEngine := TLayoutEngine.Create(GCanvas, GSheet);
  GRoot := GEngine.Build(GParser.Root, W);
  GLayoutW := W;
  GDocDirty := False; GLayoutDirty := False;
  if AutofocusFirst(GParser.Root) then GAutoKeyboard := True;
  LoadIncludes(GParser.Root);            // fetch + splice any <include src="…">
end;

{ Layout-only rebuild: keep the (mutated) DOM, rebuild boxes from it. }
procedure LayoutDoc(W: Single);
begin
  if GParser = nil then begin ParseDoc(W); Exit; end;
  if GEngine <> nil then FreeAndNil(GEngine);
  if GRoot <> nil then FreeAndNil(GRoot);
  GSheet.SetMediaContext(W, GDarkMode);   // @media context may have changed
  GEngine := TLayoutEngine.Create(GCanvas, GSheet);
  GRoot := GEngine.Build(GParser.Root, W);
  GLayoutW := W;
  GLayoutDirty := False;
end;

function MaxScroll: Single;
begin
  if GRoot = nil then Exit(0);
  Result := GRoot.H - GViewH;
  if Result < 0 then Result := 0;
end;

procedure ClampScroll;
begin
  if GScrollY < 0 then GScrollY := 0;
  if GScrollY > MaxScroll then GScrollY := MaxScroll;
end;

{ After a keyboard-driven focus change, nudge the page so the focused field
  sits in the top part of the viewport (above where the keyboard will cover). }
procedure ScrollFocusedIntoView;
var box: TLayoutBox; top, margin: Single;
begin
  if not GScrollToFocus then Exit;
  GScrollToFocus := False;
  if (GFocusedTag = nil) or (GRoot = nil) then Exit;
  box := FindBoxForTag(GRoot, GFocusedTag);
  if box = nil then Exit;
  margin := 24;
  top := box.Y - GScrollY;                       // current screen-y
  if top < margin then
    GScrollY := box.Y - margin
  else if top + box.H > GViewH * 0.45 then        // keep clear of the keyboard
    GScrollY := box.Y - GViewH * 0.45 + box.H;
end;

{ ---- select dropdown overlay ------------------------------------------ }

procedure CloseSelect;
begin
  if GOpenSelect <> nil then GOpenSelect.IsFocused := False;
  GOpenSelect := nil; GOptCount := 0; GLayoutDirty := True;
end;

{ Paint the open <select>'s option list on top of the page. Selected row gets a
  ✓ + indigo label on a tinted panel, matching a native picker. }
procedure PaintSelectOverlay(cssW, cssH: Single);
const
  CHECK = #$E2#$9C#$93;   // ✓
  INK = $FF15162E; BLUE = $FF2B41E6; TINT = $FFEFF1FE; BORDER = $FFE6E5F0;
var
  box: TLayoutBox; opts: Classes.TList; c: THTMLTag; i: Integer;
  bx, by, bw, panelH, rowY, textY, lblX: Single; cur, txt: string; sel: Boolean;
begin
  GOptCount := 0;
  if (GOpenSelect = nil) or (GRoot = nil) then Exit;
  box := FindBoxForTag(GRoot, GOpenSelect);
  if box = nil then begin CloseSelect; Exit; end;
  opts := Classes.TList.Create;
  try
    for c in GOpenSelect.Children do
      if SameText(c.TagName, 'option') then opts.Add(c);
    if opts.Count = 0 then begin CloseSelect; Exit; end;
    GOptCount := opts.Count;
    bx := box.X; by := box.Y - GScrollY + box.H + 6; bw := box.W;
    panelH := opts.Count * GOptRowH + 12;
    if by + panelH > cssH then by := box.Y - GScrollY - panelH - 6;  // flip above
    if by < 6 then by := 6;
    GOverX := bx; GOverY := by; GOverW := bw;
    cur := GOpenSelect.GetAttribute('value');
    if cur = '' then cur := InnerText(THTMLTag(opts[0]));   // default = first
    lblX := bx + 42;
    // soft drop shadow (a couple of translucent, offset rounded rects)
    GCanvas.FillRoundRect(bx - 1, by + 7, bw + 2, panelH, 16, $14000000);
    GCanvas.FillRoundRect(bx, by + 3, bw, panelH, 16, $10000000);
    GCanvas.FillRoundRect(bx, by, bw, panelH, 16, $FFFFFFFF);
    GCanvas.StrokeRoundRect(bx, by, bw, panelH, 16, 1, BORDER);
    for i := 0 to opts.Count - 1 do
    begin
      c := THTMLTag(opts[i]);
      txt := InnerText(c);
      rowY := by + 6 + i * GOptRowH;
      GOptTop[i] := rowY;
      textY := rowY + (GOptRowH - 17) / 2;
      sel := (c.GetAttribute('value') = cur) or (txt = cur);
      if sel then
      begin
        GCanvas.FillRoundRect(bx + 6, rowY, bw - 12, GOptRowH, 9, TINT);
        GCanvas.DrawText(bx + 16, textY, CHECK, 16, [tfsBold], BLUE);
        GCanvas.DrawText(lblX, textY, txt, 17, [tfsBold], BLUE);
      end
      else
        GCanvas.DrawText(lblX, textY, txt, 17, [], INK);
    end;
  finally
    opts.Free;
  end;
end;

{ A tap at (cx,cy) screen px while the dropdown is open: pick a row or dismiss. }
procedure HandleOverlayTap(cx, cy: Single);
var opts: Classes.TList; i: Integer; c: THTMLTag; v: string;
begin
  if (cx >= GOverX) and (cx <= GOverX + GOverW) then
    for i := 0 to GOptCount - 1 do
      if (cy >= GOptTop[i]) and (cy < GOptTop[i] + GOptRowH) then
      begin
        opts := Classes.TList.Create;
        try
          for c in GOpenSelect.Children do
            if SameText(c.TagName, 'option') then opts.Add(c);
          if i < opts.Count then
          begin
            c := THTMLTag(opts[i]);
            if c.HasAttribute('value') then v := c.GetAttribute('value')
            else v := InnerText(c);
            SetAttr(GOpenSelect, 'value', v);
          end;
        finally opts.Free; end;
        Break;
      end;
  CloseSelect;   // any tap closes it
end;

{ ---- <input type=date> calendar overlay ------------------------------- }

function MonName(M: Integer): string;
const N: array[1..12] of string = ('January','February','March','April','May',
  'June','July','August','September','October','November','December');
begin
  if (M >= 1) and (M <= 12) then Result := N[M] else Result := '';
end;

procedure CloseDate;
begin
  if GOpenDate <> nil then GOpenDate.IsFocused := False;
  GOpenDate := nil; GLayoutDirty := True;
end;

{ Open the calendar for a date control, starting on the value's month (or today). }
procedure OpenDate(Ctrl: THTMLTag);
var iso: string; y, mo, d, e: Integer;
begin
  BlurAll;
  GOpenDate := Ctrl; Ctrl.IsFocused := True;
  iso := Trim(Ctrl.GetAttribute('value'));
  if Length(iso) >= 10 then
  begin
    Val(Copy(iso,1,4), y, e); if e <> 0 then y := 0;
    Val(Copy(iso,6,2), mo, e); if (e <> 0) or (mo < 1) or (mo > 12) then mo := 0;
  end
  else begin y := 0; mo := 0; end;
  if (y = 0) or (mo = 0) then begin y := YearOf(Date); mo := MonthOf(Date); end;
  GCalYear := y; GCalMonth := mo;
  GLayoutDirty := True;
end;

{ Paint the month calendar on top of the page. Header ‹ Month YYYY ›, weekday
  row, a 6×7 day grid (today ringed, selected filled), and a Today button. }
procedure PaintDateOverlay(cssW, cssH: Single);
const
  INK=$FF15162E; BLUE=$FF2B41E6; TINT=$FFEFF1FE; BORDER=$FFE6E5F0;
  MUTED=$FF9698B4; PAPER=$FFFFFFFF;
  DOW: array[0..6] of string = ('Su','Mo','Tu','We','Th','Fr','Sa');
var
  box: TLayoutBox; bx, by, pad, w, h, titleY, aY, cx, cy: Single;
  i, col, row, day, selY, selMo, selD, e, tY, tMo, tD: Integer;
  title, iso, cell: string; isToday, isSel: Boolean;
begin
  if (GOpenDate = nil) or (GRoot = nil) then Exit;
  box := FindBoxForTag(GRoot, GOpenDate);
  if box = nil then begin CloseDate; Exit; end;

  pad := 12; GCalCellW := 46; GCalCellH := 44;   // finger-friendly tap targets
  w := 7 * GCalCellW + 2 * pad;                 // 346 (fits a 375px phone)
  GCalHdrH := 52;
  h := GCalHdrH + 26 + 6 * GCalCellH + 48 + pad; // header + dow + 6 rows + footer
  bx := box.X; by := box.Y - GScrollY + box.H + 6;
  if bx + w > cssW then bx := cssW - w - 6;
  if bx < 6 then bx := 6;
  if by + h > cssH then by := box.Y - GScrollY - h - 6;   // flip above
  if by < 6 then by := 6;
  GCalX := bx; GCalW := w;

  GCalDays := DaysInAMonth(GCalYear, GCalMonth);
  GCalFirstDow := DayOfWeek(EncodeDate(GCalYear, GCalMonth, 1)) - 1;  // 0=Sun

  // panel + soft shadow (rounded border to match the rounded fill — no square
  // corners poking out behind it)
  GCanvas.FillRoundRect(bx - 1, by + 8, w + 2, h, 18, $14000000);
  GCanvas.FillRoundRect(bx, by, w, h, 18, PAPER);
  GCanvas.StrokeRoundRect(bx, by, w, h, 18, 1, BORDER);

  // header: « year‹ month  Title  month› year »  (arrows uniform size, all
  // vertically centred on the title's line so they sit level)
  GCalHdrY := by;
  titleY := by + (GCalHdrH - 16) / 2;
  aY := by + (GCalHdrH - 19) / 2;
  GCanvas.DrawText(bx + 14, aY, #$C2#$AB, 19, [tfsBold], BLUE);          // « year prev
  GCanvas.DrawText(bx + 38, aY, #$E2#$80#$B9, 19, [tfsBold], BLUE);      // ‹ month prev
  GCanvas.DrawText(bx + w - 40, aY, #$E2#$80#$BA, 19, [tfsBold], BLUE);  // › month next
  GCanvas.DrawText(bx + w - 26, aY, #$C2#$BB, 19, [tfsBold], BLUE);      // » year next
  title := MonName(GCalMonth) + ' ' + IntToStr(GCalYear);
  GCanvas.DrawText(bx + (w - GCanvas.MeasureText(title, 16, [tfsBold]).Width) / 2,
    titleY, title, 16, [tfsBold], INK);

  // weekday labels
  for i := 0 to 6 do
    GCanvas.DrawText(bx + pad + i * GCalCellW + (GCalCellW - 16) / 2,
      by + GCalHdrH, DOW[i], 12, [tfsBold], MUTED);

  // selected + today
  selY := 0; selMo := 0; selD := 0;
  iso := Trim(GOpenDate.GetAttribute('value'));
  if Length(iso) >= 10 then
  begin
    Val(Copy(iso,1,4), selY, e); Val(Copy(iso,6,2), selMo, e); Val(Copy(iso,9,2), selD, e);
  end;
  tY := YearOf(Date); tMo := MonthOf(Date); tD := DayOf(Date);

  GCalGridY := by + GCalHdrH + 26;
  for day := 1 to GCalDays do
  begin
    i := GCalFirstDow + day - 1;
    col := i mod 7; row := i div 7;
    cx := bx + pad + col * GCalCellW;
    cy := GCalGridY + row * GCalCellH;
    isSel := (selY = GCalYear) and (selMo = GCalMonth) and (selD = day);
    isToday := (tY = GCalYear) and (tMo = GCalMonth) and (tD = day);
    if isSel then
      GCanvas.FillRoundRect(cx + 3, cy + 2, GCalCellW - 6, GCalCellH - 6, 9, BLUE)
    else if isToday then
      GCanvas.StrokeRoundRect(cx + 3, cy + 2, GCalCellW - 6, GCalCellH - 6, 9, 1.5, BLUE);
    cell := IntToStr(day);
    if isSel then
      GCanvas.DrawText(cx + (GCalCellW - GCanvas.MeasureText(cell,15,[tfsBold]).Width)/2,
        cy + 10, cell, 15, [tfsBold], PAPER)
    else
      GCanvas.DrawText(cx + (GCalCellW - GCanvas.MeasureText(cell,15,[]).Width)/2,
        cy + 10, cell, 15, [], INK);
  end;

  // footer: Today
  GCalTodayH := 34;
  GCalTodayY := by + h - GCalTodayH - 8;
  GCanvas.FillRoundRect(bx + pad, GCalTodayY, w - 2 * pad, GCalTodayH, 9, TINT);
  GCanvas.DrawText(bx + (w - GCanvas.MeasureText('Today', 14, [tfsBold]).Width) / 2,
    GCalTodayY + 9, 'Today', 14, [tfsBold], BLUE);
end;

{ A tap while the calendar is open: nav arrows keep it open; a day / Today picks. }
procedure HandleDateOverlayTap(cx, cy: Single);
var i, col, row, day: Integer; iso: string;
begin
  // header arrows: « year- | ‹ month- (left) … month+ › | » year+ (right)
  if (cy >= GCalHdrY) and (cy < GCalHdrY + GCalHdrH) then
  begin
    if (cx >= GCalX) and (cx < GCalX + 28) then
    begin                                                           // « year prev
      if GetTickCount64 - GYearMinusMs < 400 then
        begin GCalYear := GCalYear - 9; GYearMinusMs := 0; end      // 2nd tap → −10 total
      else begin Dec(GCalYear); GYearMinusMs := GetTickCount64; end;
      GLayoutDirty := True; Exit;
    end;
    if (cx >= GCalX + 28) and (cx < GCalX + 56) then
    begin Dec(GCalMonth); if GCalMonth < 1 then begin GCalMonth := 12; Dec(GCalYear); end;
      GLayoutDirty := True; Exit; end;                              // ‹
    if (cx >= GCalX + GCalW - 56) and (cx < GCalX + GCalW - 28) then
    begin Inc(GCalMonth); if GCalMonth > 12 then begin GCalMonth := 1; Inc(GCalYear); end;
      GLayoutDirty := True; Exit; end;                              // ›
    if (cx >= GCalX + GCalW - 28) and (cx < GCalX + GCalW) then
    begin                                                           // » year next
      if GetTickCount64 - GYearPlusMs < 400 then
        begin GCalYear := GCalYear + 9; GYearPlusMs := 0; end       // 2nd tap → +10 total
      else begin Inc(GCalYear); GYearPlusMs := GetTickCount64; end;
      GLayoutDirty := True; Exit;
    end;
  end;
  // Today
  if (cy >= GCalTodayY) and (cy < GCalTodayY + GCalTodayH) and
     (cx >= GCalX) and (cx <= GCalX + GCalW) then
  begin
    SetAttr(GOpenDate, 'value', FormatDateTime('yyyy-mm-dd', Date));
    CloseDate; Exit;
  end;
  // a day cell
  if (cx >= GCalX + 12) and (cx < GCalX + 12 + 7 * GCalCellW) and
     (cy >= GCalGridY) and (cy < GCalGridY + 6 * GCalCellH) then
  begin
    col := Trunc((cx - GCalX - 12) / GCalCellW);
    row := Trunc((cy - GCalGridY) / GCalCellH);
    i := row * 7 + col;
    day := i - GCalFirstDow + 1;
    if (day >= 1) and (day <= GCalDays) then
    begin
      iso := Format('%.4d-%.2d-%.2d', [GCalYear, GCalMonth, day]);
      SetAttr(GOpenDate, 'value', iso);
      CloseDate; Exit;
    end;
  end;
  CloseDate;   // tap elsewhere dismisses
end;

{ ---- public API -------------------------------------------------------- }

procedure TinaInit(Canvas: TTina4Canvas);
begin
  GCanvas := Canvas;
  Tina4ScrollbarsVisible := False;   // mobile: clean edge-to-edge scrolling
  EnsureActions;
end;

procedure TinaSetHtml(const Html: string);
begin
  EnsureActions;
  GHtml := Html;
  if GHtml = '@demo' then begin GDemo := True; GCount := 0; GHtml := BuildDemo; end;
  GScrollY := 0; GFlingVX := 0; GFlingVY := 0; GDragBox := nil;
  GFocusedTag := nil; GOpenSelect := nil; GDocDirty := True;
end;

procedure TinaSetTemplateDir(const Dir: string);
begin
  FreeAndNil(GFrond);
  GFrond := TFrond.Create(Dir);
end;

procedure TinaRenderTemplate(const Template, JsonContext: string);
var ctx: TJSONData; html: string;
begin
  if GFrond = nil then GFrond := TFrond.Create;
  GTemplate := Template;
  ctx := nil;
  if JsonContext <> '' then
    try ctx := GetJSON(JsonContext); except ctx := nil; end;
  try
    if (ctx <> nil) and (ctx is TJSONObject) then
      html := GFrond.RenderString(Template, TJSONObject(ctx))
    else
      html := GFrond.RenderString(Template, nil);
  finally
    ctx.Free;
  end;
  TinaSetHtml(html);
end;

procedure TinaRenderContext(const JsonContext: string);
begin
  TinaRenderTemplate(GTemplate, JsonContext);
end;

procedure TinaFrame(WPx, HPx: Integer; Density: Single);
var cssW, cssH: Single;
begin
  if GCanvas = nil then Exit;
  if Density > 0 then GDensity := Density;
  cssW := WPx / GDensity; cssH := HPx / GDensity;
  GViewH := cssH;
  GCanvas.Scale(GDensity, GDensity);          // CSS px → physical px
  GCanvas.FillRect(0, 0, cssW, cssH, BodyBg);
  if GHtml = '' then Exit;
  if GDocDirty or (Abs(GLayoutW - cssW) > 0.5) then
    ParseDoc(cssW)
  else if GLayoutDirty then
    LayoutDoc(cssW);
  ScrollFocusedIntoView;
  ClampScroll;
  if GRoot <> nil then PaintBox(GCanvas, GRoot, GScrollY);
  PaintSelectOverlay(cssW, cssH);
  PaintDateOverlay(cssW, cssH);
end;

function TinaWantsKeyboard: Integer;
begin
  if GAutoKeyboard then begin GAutoKeyboard := False; Result := 1; end
  else Result := 0;
end;

{ A tap landed on Ctrl (already the control ancestor). Mutate the DOM and
  return the TINA_* keyboard/action signal. }
function HandleControlTap(Ctrl: THTMLTag): Integer;
var kind: TControlKind; wasFocused: Boolean;
begin
  Result := TINA_NONE;
  wasFocused := GFocusedTag <> nil;
  kind := CtrlKind(Ctrl);
  if Ctrl.HasAttribute('disabled') then
  begin // inert: only dismiss a focused text field
    if wasFocused then begin BlurAll; GLayoutDirty := True; Result := TINA_HIDE_KBD; end;
    Exit;
  end;
  case kind of
    ckCheckbox:
      begin
        if Ctrl.HasAttribute('checked') then DelAttr(Ctrl, 'checked')
        else SetAttr(Ctrl, 'checked', '');
        BlurAll; GLayoutDirty := True; Result := TINA_HIDE_KBD;
      end;
    ckRadio:
      begin
        ClearRadioGroup(GParser.Root, Ctrl.GetAttribute('name'));
        SetAttr(Ctrl, 'checked', '');
        BlurAll; GLayoutDirty := True; Result := TINA_HIDE_KBD;
      end;
    ckSelect:
      begin
        BlurAll; GOpenSelect := Ctrl; Ctrl.IsFocused := True;  // ring on the trigger
        GLayoutDirty := True; Result := TINA_HIDE_KBD;         // open dropdown
      end;
    ckDate:
      begin
        OpenDate(Ctrl);                                        // open the calendar
        Result := TINA_HIDE_KBD;
      end;
    ckTextInput, ckTextarea:
      begin
        if Ctrl.HasAttribute('disabled') then Exit;
        FocusTag(Ctrl); GLayoutDirty := True; GScrollToFocus := True;
        Result := TINA_SHOW_KBD;
      end;
    ckFile:
      begin
        BlurAll; GFileTag := Ctrl; GLayoutDirty := True;
        if SameText(Ctrl.TagName, 'camera') then Result := TINA_CAPTURE
        else Result := TINA_PICK_FILE;
      end;
    ckButton:
      begin
        BlurAll; GLayoutDirty := True; Result := TINA_HIDE_KBD;
      end;
  end;
end;

function TinaTouch(Action: Integer; X, Y: Single): Integer;
var
  hit, ctrl: THTMLTag;
  sb: TLayoutBox;
  cx, cy, dx, dy: Single;
begin
  Result := TINA_NONE;
  if GRoot = nil then Exit;
  cx := X / GDensity; cy := Y / GDensity;    // device px → CSS px
  // an open <select> dropdown eats all touches until a row is chosen / dismissed
  if GOpenSelect <> nil then
  begin
    if Action = 1 then HandleOverlayTap(cx, cy);
    Exit;
  end;
  // an open date calendar eats touches too (arrows re-navigate, a day picks)
  if GOpenDate <> nil then
  begin
    if Action = 1 then HandleDateOverlayTap(cx, cy);
    Exit;
  end;
  case Action of
    0: begin
         GDownX := cx; GDownY := cy; GLastX := cx; GLastY := cy;
         GVelX := 0; GVelY := 0; GFlingVX := 0; GFlingVY := 0; GMoved := False;
         // a range slider grabs the gesture (drag the thumb, don't scroll)
         GRangeDrag := RangeAt(cx, cy);
         if GRangeDrag <> nil then
         begin
           GDragBox := nil;
           SetRangeFromX(GRangeDrag, cx);
           GLayoutDirty := True;
           Exit;
         end;
         sb := FindScrollBox(GRoot, cx, cy + GScrollY);
         if (sb <> nil) and (sb <> GRoot) and
            ((sb.ScrollableX and (sb.MaxScrollX > 0)) or
             (sb.Scrollable and (sb.MaxScroll > 0))) then
           GDragBox := sb
         else
           GDragBox := nil;
         SetActiveTag(PressTargetAt(cx, cy));    // :active pseudo-class on press
       end;
    2: begin
         // dragging a range slider tracks the finger, never scrolls the page
         if GRangeDrag <> nil then
         begin
           GLastX := cx; GLastY := cy;
           SetRangeFromX(GRangeDrag, cx);
           GLayoutDirty := True;
           Exit;
         end;
         dx := cx - GLastX; dy := cy - GLastY; GLastX := cx; GLastY := cy;
         if (Abs(cx - GDownX) > 4) or (Abs(cy - GDownY) > 4) then
         begin GMoved := True; SetActiveTag(nil); end;   // a drag cancels :active
         GVelX := GVelX * 0.5 + dx * 0.5;      // responsive velocity
         GVelY := GVelY * 0.5 + dy * 0.5;
         if GDragBox <> nil then
         begin
           if GDragBox.ScrollableX and (GDragBox.MaxScrollX > 0) then
             GDragBox.ScrollLeft := Max(0, Min(GDragBox.MaxScrollX, GDragBox.ScrollLeft - dx));
           if GDragBox.Scrollable and (GDragBox.MaxScroll > 0) then
             GDragBox.ScrollTop := Max(0, Min(GDragBox.MaxScroll, GDragBox.ScrollTop - dy));
         end
         else
         begin
           GScrollY := GScrollY - dy; ClampScroll;
         end;
       end;
    1: begin
         SetActiveTag(nil);               // release: drop :active
         if GRangeDrag <> nil then        // finish a slider drag: commit + fire handler
         begin
           SetRangeFromX(GRangeDrag, cx);
           if GRangeDrag.HasAttribute('onchange') then
             DispatchAction(GRangeDrag.GetAttribute('onchange'))
           else if GRangeDrag.HasAttribute('oninput') then
             DispatchAction(GRangeDrag.GetAttribute('oninput'));
           GRangeDrag := nil; GLayoutDirty := True;
           Exit;
         end;
         if GMoved then
         begin
           if (Abs(GVelX) > 1) or (Abs(GVelY) > 1) then
           begin GFlingVX := GVelX; GFlingVY := GVelY; Result := TINA_FLING; end;
           Exit;
         end;
         // a tap: a <label> activates its control; otherwise walk up to the
         // nearest control or onclick handler under the finger
         hit := HitTest(GRoot, cx, cy + GScrollY);
         // <summary> toggles its parent <details> open/closed
         ctrl := hit;
         while (ctrl <> nil) and not SameText(ctrl.TagName, 'summary') do ctrl := ctrl.Parent;
         if (ctrl <> nil) and (ctrl.Parent <> nil)
            and SameText(ctrl.Parent.TagName, 'details') then
         begin
           if ctrl.Parent.HasAttribute('open') then DelAttr(ctrl.Parent, 'open')
           else SetAttr(ctrl.Parent, 'open', '');
           GLayoutDirty := True; Exit;
         end;
         ctrl := LabelTarget(hit);
         if ctrl = nil then
         begin
           ctrl := hit;
           while (ctrl <> nil) and (CtrlKind(ctrl) = ckNone) and
                 not ctrl.HasAttribute('onclick') do
             ctrl := ctrl.Parent;
         end;
         if ctrl = nil then
         begin
           if GFocusedTag <> nil then begin BlurAll; GLayoutDirty := True; Result := TINA_HIDE_KBD; end;
           Exit;
         end;
         if CtrlKind(ctrl) <> ckNone then
           Result := HandleControlTap(ctrl)
         else if ctrl.HasAttribute('onclick') then
         begin
           if GFocusedTag <> nil then begin BlurAll; GLayoutDirty := True; Result := TINA_HIDE_KBD; end;
           DispatchAction(ctrl.GetAttribute('onclick'));
         end;
       end;
  end;
end;

procedure TinaHover(X, Y: Single);
var cx, cy: Single;
begin
  if GRoot = nil then Exit;
  if (GSheet = nil) or not GSheet.HasInteractiveSelectors then Exit;  // nothing hovers
  cx := X / GDensity; cy := Y / GDensity;
  SetHoverTag(HitTest(GRoot, cx, cy + GScrollY));
end;

procedure TinaScrollBy(X, Y, DX, DY: Single);
var cx, cy: Single; sb: TLayoutBox;
begin
  if GRoot = nil then Exit;
  cx := X / GDensity; cy := Y / GDensity;
  sb := FindScrollBox(GRoot, cx, cy + GScrollY);
  if (sb <> nil) and (sb <> GRoot) and
     ((sb.ScrollableX and (sb.MaxScrollX > 0)) or (sb.Scrollable and (sb.MaxScroll > 0))) then
  begin
    if sb.ScrollableX and (sb.MaxScrollX > 0) then
      sb.ScrollLeft := Max(0, Min(sb.MaxScrollX, sb.ScrollLeft - DX));
    if sb.Scrollable and (sb.MaxScroll > 0) then
      sb.ScrollTop := Max(0, Min(sb.MaxScroll, sb.ScrollTop - DY));
  end
  else
  begin
    GScrollY := GScrollY - DY;
    ClampScroll;
  end;
end;

function TinaTick: Integer;
const FRICTION = 0.95; STOPV = 0.3;
var nx, ny: Single;
begin
  Result := 0;
  if (GFlingVX = 0) and (GFlingVY = 0) then Exit;
  if GDragBox <> nil then
  begin
    if (GFlingVX <> 0) and GDragBox.ScrollableX and (GDragBox.MaxScrollX > 0) then
    begin
      nx := GDragBox.ScrollLeft - GFlingVX;
      if (nx <= 0) or (nx >= GDragBox.MaxScrollX) then GFlingVX := 0;
      GDragBox.ScrollLeft := Max(0, Min(GDragBox.MaxScrollX, nx));
    end
    else GFlingVX := 0;
    if (GFlingVY <> 0) and GDragBox.Scrollable and (GDragBox.MaxScroll > 0) then
    begin
      ny := GDragBox.ScrollTop - GFlingVY;
      if (ny <= 0) or (ny >= GDragBox.MaxScroll) then GFlingVY := 0;
      GDragBox.ScrollTop := Max(0, Min(GDragBox.MaxScroll, ny));
    end
    else GFlingVY := 0;
  end
  else
  begin
    GFlingVX := 0;
    GScrollY := GScrollY - GFlingVY;
    if (GScrollY <= 0) or (GScrollY >= MaxScroll) then GFlingVY := 0;
    ClampScroll;
  end;
  GFlingVX := GFlingVX * FRICTION;
  GFlingVY := GFlingVY * FRICTION;
  if Abs(GFlingVX) < STOPV then GFlingVX := 0;
  if Abs(GFlingVY) < STOPV then GFlingVY := 0;
  if (GFlingVX <> 0) or (GFlingVY <> 0) then Result := 1;
end;

procedure TinaBlurInput;
begin
  if GFocusedTag <> nil then begin BlurAll; GLayoutDirty := True; end;
end;

function TinaBlinkCaret: Integer;
begin
  if GFocusedTag = nil then begin Tina4CaretVisible := True; Exit(0); end;
  Tina4CaretVisible := not Tina4CaretVisible;
  Result := 1;
end;

procedure TinaKey(Codepoint: Integer);
var val: string;
begin
  if GFocusedTag = nil then Exit;
  val := GFocusedTag.GetAttribute('value');
  if Codepoint = 8 then
  begin
    if Length(val) > 0 then Delete(val, Length(val), 1);
  end
  else if Codepoint = 10 then
  begin // newline: only a textarea keeps it; a single-line input ignores it
    if CtrlKind(GFocusedTag) = ckTextarea then val := val + #10;
  end
  else if Codepoint >= 32 then
    val := val + Char(Codepoint);
  SetAttr(GFocusedTag, 'value', val);
  Tina4CaretVisible := True;
  GLayoutDirty := True;
end;

function TinaFocusKind: Integer;
begin
  Result := FocusKindOf;
end;

function TinaFocusNext: Integer;
var list: Classes.TList; idx: Integer;
begin
  Result := 0;
  if GParser = nil then Exit;
  list := Classes.TList.Create;
  try
    CollectInputs(GParser.Root, list);
    idx := list.IndexOf(GFocusedTag);
    if (idx >= 0) and (idx + 1 < list.Count) then
    begin
      FocusTag(THTMLTag(list[idx + 1]));
      GLayoutDirty := True; GScrollToFocus := True;
      Result := FocusKindOf;
    end;
  finally
    list.Free;
  end;
end;

procedure TinaSetFile(const Name: string);
begin
  if (GFileTag = nil) or (Name = '') then Exit;
  SetAttr(GFileTag, 'value', Name);
  GFileTag := nil; GLayoutDirty := True;
end;

procedure TinaSetPhoto(const Path: string);
var img: THTMLTag;
begin
  if (Path = '') or (GParser = nil) then Exit;
  img := FindById(GParser.Root, 'shot');
  if img <> nil then SetAttr(img, 'src', Path);
  if GFileTag <> nil then begin SetAttr(GFileTag, 'value', ExtractFileName(Path)); GFileTag := nil; end;
  GLayoutDirty := True;
end;

procedure TinaSetHeader(const Name, Value: string);
begin
  HttpSetHeader(Name, Value);
end;

procedure TinaInvalidateLayout;
begin
  GLayoutDirty := True;
end;

procedure TinaSetCaptureProtected(Protect: Boolean);
begin
  SetCaptureProtected(Protect);   // paint-time redaction of class="sensitive"
end;

procedure TinaSetColorScheme(Dark: Boolean);
begin
  if Dark = GDarkMode then Exit;
  GDarkMode := Dark;
  GLayoutDirty := True;   // re-cascade: @media prefers-color-scheme rules change
end;

finalization
  GFrond.Free;
  GIncPending.Free;

end.
