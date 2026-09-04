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

implementation

uses
  SysUtils, Classes, Math,
  Tina4HTMLDom, Tina4HTMLLayout, Tina4Events;

var
  GCanvas: TTina4Canvas = nil;
  GParser: THTMLParser = nil;
  GSheet: TCSSStyleSheet = nil;
  GEngine: TLayoutEngine = nil;
  GRoot: TLayoutBox = nil;
  GHtml: string = '';
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
  GFileTag: THTMLTag = nil;            // <input type=file>/<camera> awaiting a result
  GOptCount: Integer = 0;
  GOptTop: array[0..63] of Single;    // screen-y of each option row
  GOptRowH: Single = 44;
  GOverX, GOverY, GOverW: Single;
  GScrollToFocus: Boolean = False;    // bring the focused field on-screen next paint

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
procedure CollectInputs(Node: THTMLTag; List: TList);
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

procedure EnsureActions;
begin
  if GActionsReady then Exit;
  RegisterAction('Counter:Inc', @ActInc);
  RegisterAction('Counter:Dec', @ActDec);
  RegisterAction('Counter:Reset', @ActReset);
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

{ Full re-parse: build DOM + stylesheet + engine + layout. }
procedure ParseDoc(W: Single);
var i: Integer;
begin
  BlurAll;
  if GParser <> nil then FreeAndNil(GParser);
  if GSheet <> nil then FreeAndNil(GSheet);
  if GEngine <> nil then FreeAndNil(GEngine);
  if GRoot <> nil then FreeAndNil(GRoot);
  GParser := THTMLParser.Create;
  GParser.Parse(GHtml);
  GSheet := TCSSStyleSheet.Create;
  for i := 0 to GParser.StyleBlocks.Count - 1 do
    GSheet.AddCSS(GParser.StyleBlocks[i]);
  GEngine := TLayoutEngine.Create(GCanvas, GSheet);
  GRoot := GEngine.Build(GParser.Root, W);
  GLayoutW := W;
  GDocDirty := False; GLayoutDirty := False;
  if AutofocusFirst(GParser.Root) then GAutoKeyboard := True;
end;

{ Layout-only rebuild: keep the (mutated) DOM, rebuild boxes from it. }
procedure LayoutDoc(W: Single);
begin
  if GParser = nil then begin ParseDoc(W); Exit; end;
  if GEngine <> nil then FreeAndNil(GEngine);
  if GRoot <> nil then FreeAndNil(GRoot);
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
  box: TLayoutBox; opts: TList; c: THTMLTag; i: Integer;
  bx, by, bw, panelH, rowY, textY, lblX: Single; cur, txt: string; sel: Boolean;
begin
  GOptCount := 0;
  if (GOpenSelect = nil) or (GRoot = nil) then Exit;
  box := FindBoxForTag(GRoot, GOpenSelect);
  if box = nil then begin CloseSelect; Exit; end;
  opts := TList.Create;
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
    GCanvas.StrokeRect(bx, by, bw, panelH, 1, BORDER);
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
var opts: TList; i: Integer; c: THTMLTag; v: string;
begin
  if (cx >= GOverX) and (cx <= GOverX + GOverW) then
    for i := 0 to GOptCount - 1 do
      if (cy >= GOptTop[i]) and (cy < GOptTop[i] + GOptRowH) then
      begin
        opts := TList.Create;
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
  case Action of
    0: begin
         GDownX := cx; GDownY := cy; GLastX := cx; GLastY := cy;
         GVelX := 0; GVelY := 0; GFlingVX := 0; GFlingVY := 0; GMoved := False;
         sb := FindScrollBox(GRoot, cx, cy + GScrollY);
         if (sb <> nil) and (sb <> GRoot) and
            ((sb.ScrollableX and (sb.MaxScrollX > 0)) or
             (sb.Scrollable and (sb.MaxScroll > 0))) then
           GDragBox := sb
         else
           GDragBox := nil;
       end;
    2: begin
         dx := cx - GLastX; dy := cy - GLastY; GLastX := cx; GLastY := cy;
         if (Abs(cx - GDownX) > 4) or (Abs(cy - GDownY) > 4) then GMoved := True;
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
         if GMoved then
         begin
           if (Abs(GVelX) > 1) or (Abs(GVelY) > 1) then
           begin GFlingVX := GVelX; GFlingVY := GVelY; Result := TINA_FLING; end;
           Exit;
         end;
         // a tap: a <label> activates its control; otherwise walk up to the
         // nearest control or onclick handler under the finger
         hit := HitTest(GRoot, cx, cy + GScrollY);
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
var list: TList; idx: Integer;
begin
  Result := 0;
  if GParser = nil then Exit;
  list := TList.Create;
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

end.
