unit Tina4HTMLLayout;

{ Minimal block/inline/table layout engine over Tina4HTMLDom, painting
  through the TTina4Canvas contract only (see ARCHITECTURE.md).
  Scope: enough to render Example/bootstrap_test.html — block stacking,
  margins/padding/borders, inline text flow with wrapping, inline-blocks
  (.btn, styled spans), tables, image placeholders. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, Math, Generics.Collections,
  Tina4HTMLDom, Tina4RenderBackend, Tina4Theme;

type
  TTextRun = record
    Text: string;
    X, Y: Single; // absolute document coords, top-left of text
    FontSize: Single;
    Styles: TTina4FontStyles;
    Color: TTina4Color;
  end;

  { Form controls are DRAWN by the renderer (no native widgets); their state
    lives in the DOM: input/textarea in 'value', checkbox/radio in 'checked',
    select in 'value'. The app mutates attributes and rebuilds. }
  TControlKind = (ckNone, ckTextInput, ckTextarea, ckCheckbox, ckRadio,
    ckSelect, ckButton);

  TLayoutBox = class
  public
    Tag: THTMLTag;                 // may be nil for anonymous boxes
    Style: TComputedStyle;
    X, Y, W, H: Single;            // border box, absolute document coords
    Children: TObjectList<TLayoutBox>;
    Runs: TList<TTextRun>;
    IsImagePlaceholder: Boolean;
    ImageHandle: Integer;          // canvas image handle, -1 = none/failed
    ControlKind: TControlKind;
    Scrollable: Boolean;           // overflow-y auto/scroll with an explicit height
    ScrollTop: Single;
    MaxScroll: Single;
    ScrollableX: Boolean;          // overflow-x auto/scroll
    ScrollLeft: Single;
    MaxScrollX: Single;
    NaturalW: Single;              // widest line of content (for overflow-x)
    MarkerText: string;            // list-item bullet/number, '' if none
    constructor Create;
    destructor Destroy; override;
  end;

  TLayoutEngine = class
  private
    FCanvas: TTina4Canvas;
    FSheet: TCSSStyleSheet;
    FBaseStyle: TComputedStyle;
    function FontStylesOf(const St: TComputedStyle): TTina4FontStyles;
    function LineHeightOf(const St: TComputedStyle): Single;
    procedure LayoutChildren(Box: TLayoutBox; Tag: THTMLTag;
      const ParentStyle: TComputedStyle; CX, CY, CW: Single; out UsedH: Single);
    function LayoutBlock(Parent: TLayoutBox; Tag: THTMLTag;
      const ParentStyle: TComputedStyle; X, Y, AvailW: Single): Single;
    function LayoutTable(Parent: TLayoutBox; Tag: THTMLTag;
      const Style: TComputedStyle; X, Y, AvailW: Single): Single;
    function MakeInlineBlock(Tag: THTMLTag; const St: TComputedStyle): TLayoutBox;
    function MakeInlineContainer(Tag: THTMLTag; const St: TComputedStyle;
      AvailW: Single): TLayoutBox;
    function MakeControl(Tag: THTMLTag; St: TComputedStyle; AvailW: Single): TLayoutBox;
    function LayoutControlBlock(Parent: TLayoutBox; Tag: THTMLTag;
      const St: TComputedStyle; X, Y, AvailW: Single): Single;
    function LayoutFlex(Parent: TLayoutBox; Tag: THTMLTag;
      const ParentStyle: TComputedStyle; X, Y, AvailW: Single): Single;
    procedure CollectInlineText(Tag: THTMLTag; SB: TStringBuilder);
  public
    constructor Create(Canvas: TTina4Canvas; Sheet: TCSSStyleSheet);
    function Build(Root: THTMLTag; ViewportW: Single): TLayoutBox;
    { Recompute styles only (hover/active/focus flips) without relayout —
      geometry is untouched, so this is cheap enough for mouse-move. }
    procedure RefreshStyles(Box: TLayoutBox); overload;
    procedure RefreshStyles(Box: TLayoutBox; const ParentStyle: TComputedStyle); overload;
  end;

procedure PaintBox(Canvas: TTina4Canvas; Box: TLayoutBox; OffsetY: Single);
function HitTest(Box: TLayoutBox; X, Y: Single): THTMLTag;
{ Deepest overflow-scrollable box containing the point (doc coords). }
function FindScrollBox(Box: TLayoutBox; X, Y: Single): TLayoutBox;
{ Box whose Tag = T (first match). }
function FindBoxForTag(Box: TLayoutBox; T: THTMLTag): TLayoutBox;
{ Concatenated descendant text of a tag (entities already decoded). }
function InnerText(Tag: THTMLTag): string;
function IsFormControlTag(const Name: string): Boolean;

implementation

const
  IMG_PLACEHOLDER_BG: TTina4Color = $FFE9ECEF;
  IMG_PLACEHOLDER_FG: TTina4Color = $FF6C757D;

{ TLayoutBox }

constructor TLayoutBox.Create;
begin
  Children := TObjectList<TLayoutBox>.Create(True);
  Runs := TList<TTextRun>.Create;
  ImageHandle := -1;
end;

destructor TLayoutBox.Destroy;
begin
  Children.Free;
  Runs.Free;
  inherited;
end;

{ helpers }

function IsTextNode(Tag: THTMLTag): Boolean;
begin
  Result := Tag.TagName = '#text';
end;

function DisplayOf(Tag: THTMLTag; const St: TComputedStyle): string;
begin
  if IsTextNode(Tag) then Exit('inline');
  Result := LowerCase(St.Display);
  if Result = '' then Result := 'block';
end;

{ Resolve an ExplicitWidth/Height value against the containing size.
  >=0 absolute px; -1 auto; <-1.5 percentage marker (-50 = 50%); -3 fit-content. }
function ResolveSize(V, Avail: Single): Single;
begin
  if V >= 0 then Result := V
  else if (V < -1.5) and (V > -1000) and (V <> -3) then Result := Avail * (-V) / 100
  else Result := -1; // auto
end;

function IsFormControlTag(const Name: string): Boolean;
begin
  Result := SameText(Name, 'input') or SameText(Name, 'textarea') or
    SameText(Name, 'select') or SameText(Name, 'button');
end;

function ToRoman(N: Integer): string;
const
  V: array[0..12] of Integer = (1000,900,500,400,100,90,50,40,10,9,5,4,1);
  S: array[0..12] of string = ('m','cm','d','cd','c','xc','l','xl','x','ix','v','iv','i');
var i: Integer;
begin
  Result := '';
  if (N < 1) or (N > 3999) then Exit(IntToStr(N));
  for i := 0 to 12 do
    while N >= V[i] do begin Result := Result + S[i]; N := N - V[i]; end;
end;

{ List-item marker text for a given list-style-type and 1-based index. }
function MarkerFor(const ListStyleType: string; Idx: Integer): string;
var t: string;
begin
  t := LowerCase(ListStyleType);
  if t = 'none' then Exit('');
  if t = 'circle' then Exit(#$E2#$97#$A6)         // ◦
  else if t = 'square' then Exit(#$E2#$96#$AA)    // ▪
  else if t = 'decimal' then Exit(IntToStr(Idx) + '.')
  else if t = 'lower-alpha' then Exit(Chr(Ord('a') + (Idx - 1) mod 26) + '.')
  else if t = 'upper-alpha' then Exit(Chr(Ord('A') + (Idx - 1) mod 26) + '.')
  else if t = 'lower-roman' then Exit(ToRoman(Idx) + '.')
  else if t = 'upper-roman' then Exit(UpperCase(ToRoman(Idx)) + '.')
  else Exit(#$E2#$80#$A2);                        // • disc (default)
end;

procedure CollectText(Tag: THTMLTag; SB: TStringBuilder);
var
  c: THTMLTag;
begin
  if Tag.TagName = '#text' then
    SB.Append(Tag.Text)
  else
    for c in Tag.Children do
      CollectText(c, SB);
end;

function InnerText(Tag: THTMLTag): string;
var
  sb: TStringBuilder;
begin
  sb := TStringBuilder.Create;
  try
    CollectText(Tag, sb);
    Result := Trim(sb.ToString);
  finally
    sb.Free;
  end;
end;

function ApplyTextTransform(const S, Transform: string): string;
var
  i: Integer;
  atStart: Boolean;
  t: string;
begin
  t := LowerCase(Transform);
  if t = 'uppercase' then
    Result := UpperCase(S)
  else if t = 'lowercase' then
    Result := LowerCase(S)
  else if t = 'capitalize' then
  begin
    Result := LowerCase(S);
    atStart := True;
    for i := 1 to Length(Result) do
      if Result[i] in [' ', #9, #10, #13] then atStart := True
      else if atStart then
      begin
        Result[i] := UpCase(Result[i]);
        atStart := False;
      end;
  end
  else
    Result := S;
end;

function CollapseWS(const S: string): string;
var
  i: Integer;
  prevSpace: Boolean;
  ch: Char;
  sb: TStringBuilder;
begin
  sb := TStringBuilder.Create;
  try
    prevSpace := False;
    for i := 1 to Length(S) do
    begin
      ch := S[i];
      if ch in [' ', #9, #10, #13] then
      begin
        if not prevSpace then sb.Append(' ');
        prevSpace := True;
      end
      else
      begin
        sb.Append(ch);
        prevSpace := False;
      end;
    end;
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

{ TLayoutEngine }

constructor TLayoutEngine.Create(Canvas: TTina4Canvas; Sheet: TCSSStyleSheet);
begin
  FCanvas := Canvas;
  FSheet := Sheet;
end;

function TLayoutEngine.FontStylesOf(const St: TComputedStyle): TTina4FontStyles;
begin
  Result := [];
  if St.Bold then Include(Result, tfsBold);
  if St.Italic then Include(Result, tfsItalic);
  if Pos('underline', LowerCase(St.TextDecoration)) > 0 then Include(Result, tfsUnderline);
end;

function TLayoutEngine.LineHeightOf(const St: TComputedStyle): Single;
begin
  if St.LineHeight > 4 then       // absolute px
    Result := St.LineHeight
  else if St.LineHeight > 0 then  // multiplier
    Result := St.FontSize * St.LineHeight
  else
    Result := St.FontSize * 1.4;
end;

procedure TLayoutEngine.CollectInlineText(Tag: THTMLTag; SB: TStringBuilder);
var
  c: THTMLTag;
begin
  if IsTextNode(Tag) then
    SB.Append(Tag.Text)
  else
    for c in Tag.Children do
      CollectInlineText(c, SB);
end;

{ Atomic inline-block: measure single-line content, apply padding/border. }
function TLayoutEngine.MakeInlineBlock(Tag: THTMLTag; const St: TComputedStyle): TLayoutBox;
var
  sb: TStringBuilder;
  txt: string;
  m: TTina4TextMetrics;
  run: TTextRun;
  padH, padV: Single;
begin
  Result := TLayoutBox.Create;
  Result.Tag := Tag;
  Result.Style := St;
  sb := TStringBuilder.Create;
  try
    CollectInlineText(Tag, sb);
    txt := Trim(CollapseWS(sb.ToString));
  finally
    sb.Free;
  end;
  m := FCanvas.MeasureText(txt, St.FontSize, FontStylesOf(St));
  padH := St.Padding.Horz + St.BorderWidths.Horz;
  padV := St.Padding.Vert + St.BorderWidths.Vert;
  if ResolveSize(St.ExplicitWidth, 0) >= 0 then
    Result.W := St.ExplicitWidth + padH
  else
    Result.W := m.Width + padH;
  if ResolveSize(St.ExplicitHeight, 0) >= 0 then
    Result.H := St.ExplicitHeight + padV
  else
    Result.H := LineHeightOf(St) + padV;
  if txt <> '' then
  begin
    run.Text := txt;
    run.X := St.BorderWidths.Left + St.Padding.Left; // relative for now
    run.Y := St.BorderWidths.Top + St.Padding.Top;
    run.FontSize := St.FontSize;
    run.Styles := FontStylesOf(St);
    run.Color := St.Color;
    Result.Runs.Add(run);
  end;
end;

function IsPrimaryButton(Tag: THTMLTag): Boolean;
var t: string;
begin
  t := LowerCase(Tag.GetAttribute('type', 'submit'));
  Result := SameText(Tag.TagName, 'button') and (t = 'submit');
  Result := Result or (SameText(Tag.TagName, 'input') and (t = 'submit'));
end;

function ControlKindOf(Tag: THTMLTag): TControlKind;
var
  typ: string;
begin
  typ := LowerCase(Tag.GetAttribute('type', 'text'));
  if SameText(Tag.TagName, 'textarea') then Result := ckTextarea
  else if SameText(Tag.TagName, 'select') then Result := ckSelect
  else if SameText(Tag.TagName, 'button') then Result := ckButton
  else if typ = 'checkbox' then Result := ckCheckbox
  else if typ = 'radio' then Result := ckRadio
  else if (typ = 'submit') or (typ = 'button') then Result := ckButton
  else Result := ckTextInput;
end;

{ UA fallback chrome for controls the stylesheet didn't style; also the
  focus ring. Shared by MakeControl and RefreshStyles. }
procedure ApplyControlChrome(var St: TComputedStyle; Kind: TControlKind;
  Focused: Boolean; Primary: Boolean = False);
begin
  case Kind of
    ckTextInput, ckTextarea, ckSelect:
      begin
        if St.BorderWidths.Top <= 0 then
        begin
          St.SetBorderWidth(TC_BORDER_W);
          St.SetBorderColor(TC_BORDER);
        end;
        if not St.Padding.Any then
        begin
          St.Padding.SetAll(TC_PAD_V);
          St.Padding.Left := TC_PAD_H; St.Padding.Right := TC_PAD_H;
        end;
        if (St.BackgroundColor shr 24) = 0 then St.BackgroundColor := TC_SURFACE;
        if St.Color = TAlphaColors.Black then St.Color := TC_INK;
        if St.BorderRadius < 0 then St.BorderRadius := TC_RADIUS;
      end;
    ckButton:
      begin
        if (St.BackgroundColor shr 24) = 0 then
        begin
          if Primary then
          begin // submit → indigo primary
            St.BackgroundColor := TC_ACCENT;
            St.Color := TC_ON_ACCENT;
          end
          else
          begin // plain button → neutral surface + border
            St.BackgroundColor := TC_SURFACE2;
            St.Color := TC_INK;
            if St.BorderWidths.Top <= 0 then
            begin
              St.SetBorderWidth(TC_BORDER_W);
              St.SetBorderColor(TC_BORDER);
            end;
          end;
        end;
        if not St.Padding.Any then
        begin
          St.Padding.SetAll(TC_PAD_V);
          St.Padding.Left := TC_BTN_PAD_H; St.Padding.Right := TC_BTN_PAD_H;
        end;
        if St.BorderRadius < 0 then St.BorderRadius := TC_RADIUS;
      end;
  end;
  if Focused and (Kind in [ckTextInput, ckTextarea, ckSelect]) then
  begin
    St.SetBorderWidth(TC_FOCUS_W);
    St.SetBorderColor(TC_ACCENT); // indigo focus (ring not paintable yet)
  end;
end;

{ Build a layout box for a form control. Runs are stored relative to the
  box origin (FlushLine shifts them to absolute, same as inline-blocks). }
function TLayoutEngine.MakeControl(Tag: THTMLTag; St: TComputedStyle; AvailW: Single): TLayoutBox;
var
  kind: TControlKind;
  txt, ph: string;
  m: TTina4TextMetrics;
  run: TTextRun;
  padH, padV, lineH, wChars, ew: Single;
  rows, i: Integer;
  lines: TStringList;
  opt: THTMLTag;
begin
  kind := ControlKindOf(Tag);
  Result := TLayoutBox.Create;
  Result.Tag := Tag;
  Result.ControlKind := kind;
  ApplyControlChrome(St, kind, Tag.IsFocused, IsPrimaryButton(Tag));
  Result.Style := St;

  padH := St.Padding.Horz + St.BorderWidths.Horz;
  padV := St.Padding.Vert + St.BorderWidths.Vert;
  lineH := LineHeightOf(St);

  case kind of
    ckCheckbox, ckRadio:
      begin
        Result.W := 16;
        Result.H := 16;
        Exit;
      end;
    ckButton:
      begin
        txt := Trim(Tag.GetAttribute('value'));
        if txt = '' then txt := InnerText(Tag);
        if txt = '' then txt := 'Submit';
      end;
    ckSelect:
      begin
        txt := '';
        // show the option matching 'value', else the first option's text
        for opt in Tag.Children do
          if SameText(opt.TagName, 'option') then
          begin
            if txt = '' then txt := InnerText(opt);
            if Tag.HasAttribute('value') and
               ((opt.GetAttribute('value') = Tag.GetAttribute('value')) or
                (InnerText(opt) = Tag.GetAttribute('value'))) then
            begin
              txt := InnerText(opt);
              Break;
            end;
          end;
      end;
    ckTextarea:
      txt := Tag.GetAttribute('value', InnerText(Tag));
  else // ckTextInput
    txt := Tag.GetAttribute('value');
  end;

  // width: explicit/% (resolved against AvailW) → size attr (chars) → default
  wChars := 0;
  if Tag.HasAttribute('size') then
    wChars := StrToFloatDef(Tag.GetAttribute('size'), 0) * St.FontSize * 0.55;
  ew := ResolveSize(St.ExplicitWidth, AvailW);
  if ew >= 0 then
  begin
    if SameText(St.BoxSizing, 'border-box') then Result.W := ew
    else Result.W := ew + padH;
    if Result.W > AvailW then Result.W := AvailW;
  end
  else if wChars > 0 then
    Result.W := wChars + padH
  else if kind = ckButton then
    Result.W := FCanvas.MeasureText(txt, St.FontSize, FontStylesOf(St)).Width + padH
  else
    Result.W := Min(240 + padH, AvailW);

  if kind = ckTextarea then
  begin
    rows := StrToIntDef(Tag.GetAttribute('rows'), 4);
    Result.H := rows * lineH + padV;
    // naive wrap of the value into lines
    lines := TStringList.Create;
    try
      lines.Text := txt;
      for i := 0 to Min(lines.Count - 1, rows * 4) do
      begin
        run.Text := lines[i];
        run.X := St.BorderWidths.Left + St.Padding.Left;
        run.Y := St.BorderWidths.Top + St.Padding.Top + i * lineH;
        run.FontSize := St.FontSize;
        run.Styles := FontStylesOf(St);
        run.Color := St.Color;
        Result.Runs.Add(run);
      end;
    finally
      lines.Free;
    end;
    Exit;
  end;

  Result.H := lineH + padV;
  ph := '';
  if (txt = '') and (kind = ckTextInput) then ph := Tag.GetAttribute('placeholder');
  run.Text := txt;
  if ph <> '' then run.Text := ph;
  if run.Text <> '' then
  begin
    run.X := St.BorderWidths.Left + St.Padding.Left;
    run.Y := St.BorderWidths.Top + St.Padding.Top;
    run.FontSize := St.FontSize;
    run.Styles := FontStylesOf(St);
    if ph <> '' then run.Color := $FF9CA3AF else run.Color := St.Color;
    if kind = ckButton then
    begin // center button captions
      m := FCanvas.MeasureText(run.Text, St.FontSize, run.Styles);
      run.X := (Result.W - m.Width) / 2;
    end;
    Result.Runs.Add(run);
  end;
end;

{ Move a laid-out subtree (boxes + runs) by a delta — atomic inline items
  are built at origin (0,0) and shifted into place by FlushLine. }
procedure ShiftBoxTree(B: TLayoutBox; DX, DY: Single);
var
  i: Integer;
  r: TTextRun;
begin
  B.X := B.X + DX;
  B.Y := B.Y + DY;
  for i := 0 to B.Runs.Count - 1 do
  begin
    r := B.Runs[i];
    r.X := r.X + DX;
    r.Y := r.Y + DY;
    B.Runs[i] := r;
  end;
  for i := 0 to B.Children.Count - 1 do
    ShiftBoxTree(B.Children[i], DX, DY);
end;

{ Full inner layout for an inline-block CONTAINER (block children, explicit
  width) — e.g. side-by-side panels. Built at origin, shifted by FlushLine. }
function TLayoutEngine.MakeInlineContainer(Tag: THTMLTag; const St: TComputedStyle;
  AvailW: Single): TLayoutBox;
var
  edgeL, edgeT, edgeR, edgeB, w, usedH, eh: Single;
begin
  Result := TLayoutBox.Create;
  Result.Tag := Tag;
  Result.Style := St;
  edgeL := St.BorderWidths.Left + St.Padding.Left;
  edgeT := St.BorderWidths.Top + St.Padding.Top;
  edgeR := St.BorderWidths.Right + St.Padding.Right;
  edgeB := St.BorderWidths.Bottom + St.Padding.Bottom;
  w := ResolveSize(St.ExplicitWidth, AvailW);
  if w < 0 then w := AvailW;
  if not SameText(St.BoxSizing, 'border-box') then w := w + edgeL + edgeR;
  Result.W := Min(w, AvailW);
  LayoutChildren(Result, Tag, St, edgeL, edgeT, Result.W - edgeL - edgeR, usedH);
  eh := ResolveSize(St.ExplicitHeight, 0);
  if eh >= 0 then
  begin
    if SameText(St.BoxSizing, 'border-box') then usedH := Max(0, eh - edgeT - edgeB)
    else usedH := eh;
  end;
  Result.H := usedH + edgeT + edgeB;
end;

{ Flexbox: single-line row/column with justify-content (main axis) and
  align-items (cross axis). No wrap, no grow/shrink resolution yet — items
  keep their own size. Enough for the common row layouts. }
function TLayoutEngine.LayoutFlex(Parent: TLayoutBox; Tag: THTMLTag;
  const ParentStyle: TComputedStyle; X, Y, AvailW: Single): Single;
var
  st, cs: TComputedStyle;
  box, cb: TLayoutBox;
  items: TObjectList<TLayoutBox>;
  c: THTMLTag;
  mL, mR, mT, mB, availInner, ew, eh: Single;
  edgeL, edgeT, edgeR, edgeB, contentX, contentY, contentW, contentH: Single;
  isCol: Boolean;
  dir, jc, ai: string;
  sumMain, freeMain, curr, gap, crossOff: Single;
  i: Integer;
begin
  st := TComputedStyle.ForTag(Tag, ParentStyle, FSheet);
  if LowerCase(st.Display) = 'none' then Exit(0);
  box := TLayoutBox.Create;
  box.Tag := Tag; box.Style := st;
  Parent.Children.Add(box);

  mL := st.Margin.Left;  if mL = -1 then mL := 0;
  mR := st.Margin.Right; if mR = -1 then mR := 0;
  mT := st.Margin.Top;   if mT = -1 then mT := 0;
  mB := st.Margin.Bottom; if mB = -1 then mB := 0;
  availInner := AvailW - mL - mR;
  box.X := X + mL; box.Y := Y + mT;
  ew := ResolveSize(st.ExplicitWidth, availInner);
  if ew >= 0 then
  begin
    if SameText(st.BoxSizing, 'border-box') then box.W := Min(ew, availInner)
    else box.W := Min(ew + st.Padding.Horz + st.BorderWidths.Horz, availInner);
  end
  else box.W := availInner;

  edgeL := st.BorderWidths.Left + st.Padding.Left;
  edgeT := st.BorderWidths.Top + st.Padding.Top;
  edgeR := st.BorderWidths.Right + st.Padding.Right;
  edgeB := st.BorderWidths.Bottom + st.Padding.Bottom;
  contentX := box.X + edgeL; contentY := box.Y + edgeT;
  contentW := box.W - edgeL - edgeR;

  dir := LowerCase(st.FlexDirection); if dir = '' then dir := 'row';
  isCol := (dir = 'column') or (dir = 'column-reverse');
  jc := LowerCase(st.JustifyContent); if jc = '' then jc := 'flex-start';
  ai := LowerCase(st.AlignItems); if ai = '' then ai := 'stretch';

  // build flex items (block children laid out at origin)
  items := TObjectList<TLayoutBox>.Create(False);
  try
    for c in Tag.Children do
    begin
      if IsTextNode(c) then Continue;
      cs := TComputedStyle.ForTag(c, st, FSheet);
      if LowerCase(cs.Display) = 'none' then Continue;
      cb := MakeInlineContainer(c, cs, contentW);
      box.Children.Add(cb);
      items.Add(cb);
    end;

    // cross-axis extent of the container
    eh := ResolveSize(st.ExplicitHeight, 0);
    if isCol then
    begin
      contentH := 0;
      for i := 0 to items.Count - 1 do contentH := contentH + items[i].H
    end
    else
    begin
      contentH := 0;
      for i := 0 to items.Count - 1 do contentH := Max(contentH, items[i].H);
    end;
    if eh >= 0 then
    begin
      if SameText(st.BoxSizing, 'border-box') then contentH := Max(contentH, eh - edgeT - edgeB)
      else contentH := Max(contentH, eh);
    end;

    // main-axis packing
    sumMain := 0;
    for i := 0 to items.Count - 1 do
      if isCol then sumMain := sumMain + items[i].H
      else sumMain := sumMain + items[i].W;
    if isCol then freeMain := contentH - sumMain
    else freeMain := contentW - sumMain;
    if freeMain < 0 then freeMain := 0;

    curr := 0; gap := 0;
    if (jc = 'center') then curr := freeMain / 2
    else if (jc = 'flex-end') or (jc = 'end') then curr := freeMain
    else if (jc = 'space-between') and (items.Count > 1) then gap := freeMain / (items.Count - 1)
    else if (jc = 'space-around') and (items.Count > 0) then
    begin curr := freeMain / (items.Count * 2); gap := freeMain / items.Count; end
    else if (jc = 'space-evenly') and (items.Count > 0) then
    begin curr := freeMain / (items.Count + 1); gap := freeMain / (items.Count + 1); end;

    for i := 0 to items.Count - 1 do
    begin
      cb := items[i];
      if isCol then
      begin
        // cross axis = horizontal
        if (ai = 'center') then crossOff := (contentW - cb.W) / 2
        else if (ai = 'flex-end') or (ai = 'end') then crossOff := contentW - cb.W
        else crossOff := 0;
        ShiftBoxTree(cb, contentX + crossOff, contentY + curr);
        curr := curr + cb.H + gap;
      end
      else
      begin
        // cross axis = vertical
        if (ai = 'center') then crossOff := (contentH - cb.H) / 2
        else if (ai = 'flex-end') or (ai = 'end') then crossOff := contentH - cb.H
        else crossOff := 0;
        ShiftBoxTree(cb, contentX + curr, contentY + crossOff);
        curr := curr + cb.W + gap;
      end;
    end;

    box.H := contentH + edgeT + edgeB;
    Result := box.H + mT + mB;
  finally
    items.Free;
  end;
end;

{ A block-level form control (Bootstrap .form-control): full-width by
  default, honours margins, stacks vertically. }
function TLayoutEngine.LayoutControlBlock(Parent: TLayoutBox; Tag: THTMLTag;
  const St: TComputedStyle; X, Y, AvailW: Single): Single;
var
  box: TLayoutBox;
  mL, mR, mT, mB, availInner: Single;
begin
  mL := St.Margin.Left;  if mL = -1 then mL := 0;
  mR := St.Margin.Right; if mR = -1 then mR := 0;
  mT := St.Margin.Top;   if mT = -1 then mT := 0;
  mB := St.Margin.Bottom; if mB = -1 then mB := 0;
  availInner := AvailW - mL - mR;
  box := MakeControl(Tag, St, availInner);
  // text-like block control with no explicit width fills the line
  if (ResolveSize(St.ExplicitWidth, availInner) < 0) and
     (box.ControlKind in [ckTextInput, ckTextarea, ckSelect]) then
    box.W := availInner;
  ShiftBoxTree(box, X + mL, Y + mT);
  Parent.Children.Add(box);
  Result := box.H + mT + mB;
end;

type
  TInlineItem = record
    Text: string;          // '' for atomic boxes
    Box: TLayoutBox;       // nil for words
    W, H: Single;
    Ascent: Single;        // distance from top of item to its baseline
    FontSize: Single;
    Styles: TTina4FontStyles;
    Color: TTina4Color;
    SpaceBefore: Boolean;
    LineBreak: Boolean;    // <br>
  end;

{ Lay out the mixed inline/block children of Tag into Box.
  CX,CY = content origin (absolute), CW = content width. }
procedure TLayoutEngine.LayoutChildren(Box: TLayoutBox; Tag: THTMLTag;
  const ParentStyle: TComputedStyle; CX, CY, CW: Single; out UsedH: Single);
var
  y: Single;
  items: TList<TInlineItem>;
  pendingSpace: Boolean;   // trailing whitespace carried across inline nodes
  noWrapFlow: Boolean;     // white-space:nowrap → keep inline items on one line

  function HasBlockChild(T: THTMLTag; const St: TComputedStyle): Boolean;
  var
    c: THTMLTag;
    ccs: TComputedStyle;
    d: string;
  begin
    Result := False;
    for c in T.Children do
    begin
      if IsTextNode(c) then Continue;
      ccs := TComputedStyle.ForTag(c, St, FSheet);
      d := LowerCase(ccs.Display);
      if (d = 'block') or (d = 'table') or (d = 'list-item') then Exit(True);
    end;
  end;

  procedure GatherInline(T: THTMLTag; const St: TComputedStyle);
  var
    c: THTMLTag;
    cs: TComputedStyle;
    words: TStringList;
    i: Integer;
    it: TInlineItem;
    m: TTina4TextMetrics;
    disp, txt: string;
    leadingSpace: Boolean;
    iw, ih: Single;
  begin
    it.LineBreak := False;
    if SameText(T.TagName, 'br') then
    begin
      it.Text := ''; it.Box := nil; it.W := 0;
      it.H := LineHeightOf(St);
      it.Ascent := it.H;
      it.FontSize := St.FontSize; it.Styles := []; it.Color := 0;
      it.SpaceBefore := False;
      it.LineBreak := True;
      items.Add(it);
      Exit;
    end;
    if IsTextNode(T) then
    begin
      txt := CollapseWS(T.Text);
      if (St.TextTransform <> '') and not SameText(St.TextTransform, 'none') then
        txt := ApplyTextTransform(txt, St.TextTransform);
      if Trim(txt) = '' then
      begin
        // whitespace-only text node between inline elements is still a space
        if (txt <> '') and (items.Count > 0) then pendingSpace := True;
        Exit;
      end;
      leadingSpace := ((txt <> '') and (txt[1] = ' ')) or pendingSpace;
      pendingSpace := (txt <> '') and (txt[Length(txt)] = ' ');
      words := TStringList.Create;
      try
        words.Delimiter := ' ';
        words.StrictDelimiter := True;
        words.DelimitedText := Trim(txt);
        for i := 0 to words.Count - 1 do
        begin
          if words[i] = '' then Continue;
          m := FCanvas.MeasureText(words[i], St.FontSize, FontStylesOf(St));
          it.Text := words[i];
          it.Box := nil;
          it.W := m.Width;
          it.H := LineHeightOf(St);
          // baseline sits (lineHeight-fontHeight)/2 below the run top, then
          // ascent below that — so text of any size shares one baseline.
          it.Ascent := (it.H - (m.Ascent + m.Descent)) / 2 + m.Ascent;
          it.FontSize := St.FontSize;
          it.Styles := FontStylesOf(St);
          it.Color := St.Color;
          it.SpaceBefore := (items.Count > 0) and ((i > 0) or leadingSpace);
          items.Add(it);
        end;
      finally
        words.Free;
      end;
      Exit;
    end;
    cs := TComputedStyle.ForTag(T, St, FSheet);
    if LowerCase(cs.Display) = 'none' then Exit;
    if cs.Margin.Left > 0 then
    begin // inline margin-left becomes a spacer in the flow
      it.Text := ''; it.Box := nil;
      it.W := cs.Margin.Left; it.H := 0; it.Ascent := 0;
      it.FontSize := cs.FontSize; it.Styles := []; it.Color := 0;
      it.SpaceBefore := False;
      items.Add(it);
    end;
    if SameText(T.TagName, 'img') then
    begin
      it.Text := '';
      it.Box := TLayoutBox.Create;
      it.Box.Tag := T;
      it.Box.Style := cs;
      it.Box.IsImagePlaceholder := True;
      it.Box.ImageHandle := FCanvas.LoadImage(T.GetAttribute('src'));
      if cs.ExplicitWidth >= 0 then it.Box.W := cs.ExplicitWidth else it.Box.W := 120;
      if cs.ExplicitHeight >= 0 then it.Box.H := cs.ExplicitHeight else it.Box.H := 80;
      // no width/height attributes: fall back to the image's intrinsic size
      if ((cs.ExplicitWidth < 0) or (cs.ExplicitHeight < 0)) and
         FCanvas.ImageSize(it.Box.ImageHandle, iw, ih) and (iw > 0) and (ih > 0) then
      begin
        if (cs.ExplicitWidth < 0) and (cs.ExplicitHeight < 0) then
        begin
          it.Box.W := iw; it.Box.H := ih;
        end
        else if cs.ExplicitWidth < 0 then
          it.Box.W := iw * (it.Box.H / ih)   // keep aspect from given height
        else
          it.Box.H := ih * (it.Box.W / iw);  // keep aspect from given width
      end;
      if it.Box.W > CW then
      begin // scale down to fit
        it.Box.H := it.Box.H * (CW / it.Box.W);
        it.Box.W := CW;
      end;
      it.W := it.Box.W; it.H := it.Box.H;
      it.FontSize := cs.FontSize; it.Styles := [];
      it.Ascent := it.Box.H;  // baseline at the box bottom (default vertical-align)
      it.SpaceBefore := (items.Count > 0) and pendingSpace;
      pendingSpace := False;
      Box.Children.Add(it.Box);
      items.Add(it);
      Exit;
    end;
    if IsFormControlTag(T.TagName) then
    begin
      it.Text := '';
      it.Box := MakeControl(T, cs, CW);
      it.W := it.Box.W; it.H := it.Box.H;
      it.FontSize := cs.FontSize; it.Styles := [];
      it.Ascent := it.Box.H;  // baseline at the box bottom (default vertical-align)
      it.SpaceBefore := (items.Count > 0) and pendingSpace;
      pendingSpace := False;
      Box.Children.Add(it.Box);
      items.Add(it);
      Exit;
    end;
    { An inline element with visible box styling (background, border,
      padding) is treated as an atomic inline-block so its box paints —
      covers Bootstrap badges and styled <span>s. True inline-block
      CONTAINERS (block children or an explicit width) get full inner
      layout instead of the single-line fast path. }
    if (LowerCase(cs.Display) = 'inline-block')
      or ((cs.BackgroundColor shr 24 > 0) or cs.Padding.Any or (cs.BorderWidths.Top > 0)) then
    begin
      it.Text := '';
      if (ResolveSize(cs.ExplicitWidth, CW) >= 0) or HasBlockChild(T, cs) then
        it.Box := MakeInlineContainer(T, cs, CW)
      else
        it.Box := MakeInlineBlock(T, cs);
      it.W := it.Box.W; it.H := it.Box.H;
      it.FontSize := cs.FontSize; it.Styles := [];
      it.Ascent := it.Box.H;  // baseline at the box bottom (default vertical-align)
      it.SpaceBefore := (items.Count > 0) and pendingSpace;
      pendingSpace := False;
      Box.Children.Add(it.Box);
      items.Add(it);
      Exit;
    end;
    // plain inline (b, i, span, a, small...) — recurse with its style
    for c in T.Children do
      GatherInline(c, cs);
  end;

  procedure FlushLine(startIdx: Integer; var lineItems: TList<Integer>;
    lineTop, lineH: Single);
  var
    idx, k: Integer;
    lineW, xShift, x, maxAscent: Single;
    it: TInlineItem;
    run: TTextRun;
    r: TTextRun;
    j: Integer;
  begin
    if lineItems.Count = 0 then Exit;
    // width used
    lineW := 0;
    for k := 0 to lineItems.Count - 1 do
    begin
      it := items[lineItems[k]];
      if it.SpaceBefore and (k > 0) then
        lineW := lineW + FCanvas.MeasureText(' ', it.FontSize, it.Styles).Width;
      lineW := lineW + it.W;
    end;
    case ParentStyle.TextAlign of
      TTextAlign.Center:   xShift := Max(0, (CW - lineW) / 2);
      TTextAlign.Trailing: xShift := Max(0, CW - lineW);
    else
      xShift := 0;
    end;
    // shared baseline: the line's baseline sits maxAscent below its top;
    // every baseline-aligned item (text of any size, inline-block) hangs
    // its own ascent above it, so they line up on one baseline.
    maxAscent := 0;
    for k := 0 to lineItems.Count - 1 do
    begin
      it := items[lineItems[k]];
      if (it.Box <> nil) and SameText(it.Box.Style.VerticalAlign, 'top') then Continue;
      if it.Ascent > maxAscent then maxAscent := it.Ascent;
    end;
    x := CX + xShift;
    for k := 0 to lineItems.Count - 1 do
    begin
      it := items[lineItems[k]];
      if it.SpaceBefore and (k > 0) then
        x := x + FCanvas.MeasureText(' ', it.FontSize, it.Styles).Width;
      if it.Box <> nil then
      begin
        if SameText(it.Box.Style.VerticalAlign, 'top') then
          ShiftBoxTree(it.Box, x, lineTop)
        else if SameText(it.Box.Style.VerticalAlign, 'middle') then
          ShiftBoxTree(it.Box, x, lineTop + maxAscent - it.H / 2)
        else // baseline: box bottom on the baseline
          ShiftBoxTree(it.Box, x, lineTop + maxAscent - it.Ascent);
      end
      else
      begin
        run.Text := it.Text;
        run.X := x;
        run.Y := lineTop + maxAscent - it.Ascent;  // top so baseline aligns
        run.FontSize := it.FontSize;
        run.Styles := it.Styles;
        run.Color := it.Color;
        Box.Runs.Add(run);
      end;
      x := x + it.W;
    end;
    lineItems.Clear;
  end;

  procedure FlowInlineItems;
  var
    i: Integer;
    it: TInlineItem;
    curW, lineH, spaceW: Single;
    lineItems: TList<Integer>;
  begin
    if items.Count = 0 then Exit;
    lineItems := TList<Integer>.Create;
    try
      curW := 0; lineH := 0;
      for i := 0 to items.Count - 1 do
      begin
        it := items[i];
        if it.LineBreak and not noWrapFlow then
        begin // <br>: hard break, even mid-line
          FlushLine(i, lineItems, y, Max(lineH, it.H));
          y := y + Max(lineH, it.H);
          curW := 0; lineH := 0;
          Continue;
        end;
        spaceW := 0;
        if it.SpaceBefore and (lineItems.Count > 0) then
          spaceW := FCanvas.MeasureText(' ', it.FontSize, it.Styles).Width;
        if (not noWrapFlow) and (lineItems.Count > 0) and (curW + spaceW + it.W > CW) then
        begin
          FlushLine(i, lineItems, y, lineH);
          y := y + lineH;
          curW := 0; lineH := 0;
          spaceW := 0;
        end;
        lineItems.Add(i);
        curW := curW + spaceW + it.W;
        if curW > Box.NaturalW then Box.NaturalW := curW;
        lineH := Max(lineH, it.H);
      end;
      FlushLine(items.Count, lineItems, y, lineH);
      y := y + lineH;
    finally
      lineItems.Free;
    end;
    items.Clear;
  end;

var
  c: THTMLTag;
  cs: TComputedStyle;
  disp: string;
  prevMB, mTc: Single;
  hadInline: Boolean;
begin
  y := CY;
  prevMB := 0;
  hadInline := False;
  pendingSpace := False;
  noWrapFlow := SameText(ParentStyle.WhiteSpace, 'nowrap') or
                SameText(ParentStyle.WhiteSpace, 'pre');
  items := TList<TInlineItem>.Create;
  try
    for c in Tag.Children do
    begin
      if IsTextNode(c) then
      begin
        GatherInline(c, ParentStyle);
        hadInline := True;
        Continue;
      end;
      cs := TComputedStyle.ForTag(c, ParentStyle, FSheet);
      disp := DisplayOf(c, cs);
      if disp = 'none' then Continue;
      // form control keeps its computed display: inline/inline-block flow inline,
      // block (e.g. Bootstrap .form-control) stacks full-width.
      if (disp = 'inline') or (disp = 'inline-block') or SameText(c.TagName, 'img')
        or (IsFormControlTag(c.TagName) and (disp <> 'block')) then
      begin
        GatherInline(c, ParentStyle);
        hadInline := True;
      end
      else
      begin
        FlowInlineItems; // finish pending inline line(s)
        pendingSpace := False;
        if hadInline then begin prevMB := 0; hadInline := False; end;
        // collapse adjacent vertical margins: gap = max(prevBottom, thisTop)
        mTc := cs.Margin.Top; if mTc = -1 then mTc := 0;
        if (prevMB > 0) and (mTc > 0) then
          y := y - Min(prevMB, mTc);
        if (disp = 'flex') or (disp = 'inline-flex') then
          y := y + LayoutFlex(Box, c, ParentStyle, CX, y, CW)
        else if IsFormControlTag(c.TagName) then
          y := y + LayoutControlBlock(Box, c, cs, CX, y, CW)
        else if SameText(c.TagName, 'table') then
          y := y + LayoutTable(Box, c, cs, CX, y, CW)
        else
          y := y + LayoutBlock(Box, c, ParentStyle, CX, y, CW);
        prevMB := cs.Margin.Bottom; if prevMB = -1 then prevMB := 0;
      end;
    end;
    FlowInlineItems;
  finally
    items.Free;
  end;
  UsedH := y - CY;
end;

function TLayoutEngine.LayoutBlock(Parent: TLayoutBox; Tag: THTMLTag;
  const ParentStyle: TComputedStyle; X, Y, AvailW: Single): Single;
var
  st: TComputedStyle;
  box: TLayoutBox;
  contentX, contentY, contentW, usedH: Single;
  edgeL, edgeT, edgeR, edgeB: Single;
  mL, mR, mT, mB, ew, eh, availInner, naturalH, mnw, mxw: Single;
  autoL, autoR: Boolean;
  ov: string;
  liIdx: Integer;
  liSib: THTMLTag;
begin
  st := TComputedStyle.ForTag(Tag, ParentStyle, FSheet);
  if LowerCase(st.Display) = 'none' then Exit(0);

  box := TLayoutBox.Create;
  box.Tag := Tag;
  box.Style := st;
  Parent.Children.Add(box);

  // list-item marker, honouring the list's list-style-type
  if SameText(Tag.TagName, 'li') and (Tag.Parent <> nil) and
     (SameText(Tag.Parent.TagName, 'ul') or SameText(Tag.Parent.TagName, 'ol')) then
  begin
    liIdx := 0;
    for liSib in Tag.Parent.Children do
    begin
      if SameText(liSib.TagName, 'li') then Inc(liIdx);
      if liSib = Tag then Break;
    end;
    box.MarkerText := MarkerFor(
      TComputedStyle.ForTag(Tag.Parent, ParentStyle, FSheet).ListStyleType, liIdx);
  end;

  // margins: -1 is the 'auto' marker from ParseLength; real negatives pass through
  mL := st.Margin.Left;  autoL := mL = -1; if autoL then mL := 0;
  mR := st.Margin.Right; autoR := mR = -1; if autoR then mR := 0;
  mT := st.Margin.Top;    if mT = -1 then mT := 0;
  mB := st.Margin.Bottom; if mB = -1 then mB := 0;

  availInner := AvailW - mL - mR;
  box.X := X + mL;
  box.Y := Y + mT;
  box.W := availInner;
  ew := ResolveSize(st.ExplicitWidth, availInner);
  if ew >= 0 then
  begin
    if SameText(st.BoxSizing, 'border-box') then
      box.W := Min(ew, availInner)
    else
      box.W := Min(ew + st.Padding.Horz + st.BorderWidths.Horz, availInner);
    if autoL and autoR then
      box.X := X + mL + Max(0, (availInner - box.W) / 2); // margin:0 auto centering
  end;
  // min-width / max-width clamp (px or % resolved against availInner)
  mnw := ResolveSize(st.MinWidth, availInner);
  mxw := ResolveSize(st.MaxWidth, availInner);
  if (mxw >= 0) and (box.W > mxw) then box.W := mxw;
  if (mnw >= 0) and (box.W < mnw) then box.W := mnw;

  edgeL := st.BorderWidths.Left + st.Padding.Left;
  edgeT := st.BorderWidths.Top + st.Padding.Top;
  edgeR := st.BorderWidths.Right + st.Padding.Right;
  edgeB := st.BorderWidths.Bottom + st.Padding.Bottom;
  contentX := box.X + edgeL;
  contentY := box.Y + edgeT;
  contentW := box.W - edgeL - edgeR;

  LayoutChildren(box, Tag, st, contentX, contentY, contentW, usedH);
  eh := ResolveSize(st.ExplicitHeight, 0);
  if eh >= 0 then
  begin
    naturalH := usedH;
    if SameText(st.BoxSizing, 'border-box') then
      usedH := Max(0, eh - edgeT - edgeB)
    else
      usedH := eh;
    // overflow-y: auto/scroll → inner scroller owned by the renderer
    ov := LowerCase(st.OverflowY);
    if ov = '' then ov := LowerCase(st.Overflow);
    if ((ov = 'auto') or (ov = 'scroll') or (ov = 'hidden')) and (naturalH > usedH) then
    begin
      box.Scrollable := (ov <> 'hidden');
      box.MaxScroll := naturalH - usedH;
    end;
  end;
  // overflow-x: auto/scroll/hidden → horizontal scroller / clip
  ov := LowerCase(st.OverflowX);
  if ov = '' then ov := LowerCase(st.Overflow);
  if ((ov = 'auto') or (ov = 'scroll') or (ov = 'hidden')) and (box.NaturalW > contentW + 0.5) then
  begin
    box.ScrollableX := (ov <> 'hidden');
    box.MaxScrollX := box.NaturalW - contentW;
  end;
  box.H := usedH + edgeT + edgeB;

  Result := box.H + mT + mB;
end;

function TLayoutEngine.LayoutTable(Parent: TLayoutBox; Tag: THTMLTag;
  const Style: TComputedStyle; X, Y, AvailW: Single): Single;
var
  rows: TList<THTMLTag>;
  prefW: array of Single;
  ncols, i, ci: Integer;
  r, cell: THTMLTag;
  tbox, rbox, cbox: TLayoutBox;
  cs, rs: TComputedStyle;
  sb: TStringBuilder;
  m: TTina4TextMetrics;
  total, scale, cx, rowY, rowH, usedH, cw, tableW, tblAvail, explW, ch: Single;
  hasBorder: Boolean;

  procedure CollectRows(T: THTMLTag);
  var c: THTMLTag;
  begin
    for c in T.Children do
      if SameText(c.TagName, 'tr') then rows.Add(c)
      else if SameText(c.TagName, 'thead') or SameText(c.TagName, 'tbody') or
              SameText(c.TagName, 'tfoot') then CollectRows(c);
  end;

begin
  rows := TList<THTMLTag>.Create;
  try
    CollectRows(Tag);
    if rows.Count = 0 then Exit(0);
    ncols := 0;
    for r in rows do
    begin
      i := 0;
      for cell in r.Children do
        if SameText(cell.TagName, 'td') or SameText(cell.TagName, 'th') then Inc(i);
      ncols := Max(ncols, i);
    end;
    if ncols = 0 then Exit(0);

    hasBorder := Tag.HasAttribute('border');
    tblAvail := AvailW - Style.Margin.Horz;
    explW := ResolveSize(Style.ExplicitWidth, tblAvail);  // px or % of available

    // preferred column widths: an explicit cell width is exact; otherwise
    // content plus padding (+ a little slop for content-sized cells).
    SetLength(prefW, ncols);
    for i := 0 to ncols - 1 do prefW[i] := 0;
    for r in rows do
    begin
      ci := 0;
      for cell in r.Children do
      begin
        if not (SameText(cell.TagName, 'td') or SameText(cell.TagName, 'th')) then Continue;
        cs := TComputedStyle.ForTag(cell, Style, FSheet);
        cw := ResolveSize(cs.ExplicitWidth, tblAvail);
        if cell.HasAttribute('width') then
          cw := TComputedStyle.ParseLength(cell.GetAttribute('width'), cs.FontSize);
        if cw >= 0 then
          cw := cw + cs.Padding.Horz + cs.BorderWidths.Horz  // content-box + edges
        else
        begin
          sb := TStringBuilder.Create;
          try
            CollectInlineText(cell, sb);
            m := FCanvas.MeasureText(Trim(CollapseWS(sb.ToString)), cs.FontSize, FontStylesOf(cs));
          finally
            sb.Free;
          end;
          cw := m.Width + cs.Padding.Horz + cs.BorderWidths.Horz + 8;
        end;
        if ci < ncols then prefW[ci] := Max(prefW[ci], cw);
        Inc(ci);
      end;
    end;
    total := 0;
    for i := 0 to ncols - 1 do total := total + prefW[i];
    if total <= 0 then total := 1;
    // auto table sizes to content; an explicit width scales columns to fit
    if explW >= 0 then tableW := explW
    else tableW := Min(total, tblAvail);
    scale := tableW / total;
    for i := 0 to ncols - 1 do prefW[i] := prefW[i] * scale;

    tbox := TLayoutBox.Create;
    tbox.Tag := Tag;
    tbox.Style := Style;
    Parent.Children.Add(tbox);
    tbox.X := X + Style.Margin.Left;
    tbox.Y := Y + Style.Margin.Top;
    tbox.W := tableW;

    rowY := tbox.Y;
    for r in rows do
    begin
      rs := TComputedStyle.ForTag(r, Style, FSheet);
      rbox := TLayoutBox.Create;
      rbox.Tag := r;
      rbox.Style := rs;
      tbox.Children.Add(rbox);
      rbox.X := tbox.X; rbox.Y := rowY; rbox.W := tableW;
      cx := tbox.X;
      rowH := 0;
      ci := 0;
      for cell in r.Children do
      begin
        if not (SameText(cell.TagName, 'td') or SameText(cell.TagName, 'th')) then Continue;
        cs := TComputedStyle.ForTag(cell, rs, FSheet);
        if hasBorder and (cs.BorderWidths.Top <= 0) then
        begin
          cs.SetBorderWidth(1);
          cs.SetBorderColor(Style.BorderColor);
        end;
        cbox := TLayoutBox.Create;
        cbox.Tag := cell;
        cbox.Style := cs;
        rbox.Children.Add(cbox);
        cbox.X := cx; cbox.Y := rowY; cbox.W := prefW[ci];
        LayoutChildren(cbox, cell, cs,
          cx + cs.BorderWidths.Left + cs.Padding.Left,
          rowY + cs.BorderWidths.Top + cs.Padding.Top,
          prefW[ci] - cs.Padding.Horz - cs.BorderWidths.Horz, usedH);
        // honour an explicit cell height (content-box)
        ch := ResolveSize(cs.ExplicitHeight, 0);
        if ch >= 0 then usedH := Max(usedH, ch);
        if cell.HasAttribute('height') then
          usedH := Max(usedH, TComputedStyle.ParseLength(cell.GetAttribute('height'), cs.FontSize));
        cbox.H := usedH + cs.Padding.Vert + cs.BorderWidths.Vert;
        rowH := Max(rowH, cbox.H);
        cx := cx + prefW[ci];
        Inc(ci);
      end;
      for i := 0 to rbox.Children.Count - 1 do
        rbox.Children[i].H := rowH; // uniform row height
      rbox.H := rowH;
      rowY := rowY + rowH;
    end;
    tbox.H := rowY - tbox.Y;
    Result := tbox.H + Style.Margin.Vert;
  finally
    rows.Free;
  end;
end;

function TLayoutEngine.Build(Root: THTMLTag; ViewportW: Single): TLayoutBox;
var
  base: TComputedStyle;
  usedH: Single;
  body: THTMLTag;

  function FindBody(T: THTMLTag): THTMLTag;
  var c, r: THTMLTag;
  begin
    if SameText(T.TagName, 'body') then Exit(T);
    for c in T.Children do
    begin
      r := FindBody(c);
      if r <> nil then Exit(r);
    end;
    Result := nil;
  end;

begin
  base := TComputedStyle.Default;
  base.FontFamily := 'Helvetica';
  base.FontSize := 16;       // web default; Delphi default is 14
  base.LineHeight := 1.5;    // bootstrap body line-height
  FBaseStyle := base;
  body := FindBody(Root);
  if body = nil then body := Root;
  Result := TLayoutBox.Create;
  Result.Tag := body;
  Result.Style := TComputedStyle.ForTag(body, base, FSheet);
  Result.X := 0; Result.Y := 0; Result.W := ViewportW;
  LayoutChildren(Result, body, Result.Style,
    Result.Style.Padding.Left + Result.Style.Margin.Left,
    Result.Style.Padding.Top + Result.Style.Margin.Top,
    ViewportW - Result.Style.Padding.Horz - Result.Style.Margin.Horz, usedH);
  Result.H := usedH + Result.Style.Padding.Vert + Result.Style.Margin.Vert;
end;

procedure TLayoutEngine.RefreshStyles(Box: TLayoutBox);
begin
  RefreshStyles(Box, FBaseStyle);
end;

procedure TLayoutEngine.RefreshStyles(Box: TLayoutBox; const ParentStyle: TComputedStyle);
var
  i: Integer;
  st: TComputedStyle;
begin
  if (Box.Tag <> nil) and not IsTextNode(Box.Tag) then
  begin
    st := TComputedStyle.ForTag(Box.Tag, ParentStyle, FSheet);
    if Box.ControlKind <> ckNone then
      ApplyControlChrome(st, Box.ControlKind, Box.Tag.IsFocused, IsPrimaryButton(Box.Tag));
    // keep layout-critical fields from the original pass; only visuals swap
    st.ExplicitWidth := Box.Style.ExplicitWidth;
    st.ExplicitHeight := Box.Style.ExplicitHeight;
    Box.Style := st;
  end;
  for i := 0 to Box.Children.Count - 1 do
    RefreshStyles(Box.Children[i], Box.Style);
end;

{ painting }

{ Midpoint of two ARGB colours (opaque result) — gradient approximation. }
function AvgColor(A, B: TTina4Color): TTina4Color;
begin
  Result := $FF000000
    or (TTina4Color((((A shr 16) and $FF) + ((B shr 16) and $FF)) div 2) shl 16)
    or (TTina4Color((((A shr 8) and $FF) + ((B shr 8) and $FF)) div 2) shl 8)
    or  TTina4Color(((A and $FF) + (B and $FF)) div 2);
end;

{ Scale a colour's alpha channel by factor (0..1) — for CSS opacity. }
function ScaleAlpha(C: TTina4Color; Factor: Single): TTina4Color;
var
  a: Integer;
begin
  if Factor >= 1.0 then Exit(C);
  a := Round(((C shr 24) and $FF) * Factor);
  if a < 0 then a := 0 else if a > 255 then a := 255;
  Result := (TTina4Color(a) shl 24) or (C and $00FFFFFF);
end;

procedure PaintBoxEx(Canvas: TTina4Canvas; Box: TLayoutBox; OffsetY: Single;
  Opacity: Single; Hidden: Boolean); forward;

procedure PaintBox(Canvas: TTina4Canvas; Box: TLayoutBox; OffsetY: Single);
begin
  PaintBoxEx(Canvas, Box, OffsetY, 1.0, False);
end;

procedure PaintBoxEx(Canvas: TTina4Canvas; Box: TLayoutBox; OffsetY: Single;
  Opacity: Single; Hidden: Boolean);
var
  i: Integer;
  r: TTextRun;
  st: TComputedStyle;
  y, innerOfs, thumbH, thumbY, cx, cy: Single;
  sizeTxt, val: string;
  m: TTina4TextMetrics;
  didClip: Boolean;
  op, tx, ty, sx: Single;
  shifted: Boolean;
  bg, bd, fg: TTina4Color;
begin
  st := Box.Style;
  // transform: translate — shift this box + subtree, unshift after paint
  tx := st.TransformTranslateX;
  ty := st.TransformTranslateY;
  shifted := (tx <> 0) or (ty <> 0);
  if shifted then ShiftBoxTree(Box, tx, ty);
  try
  y := Box.Y - OffsetY;
  // CSS opacity multiplies down the subtree; visibility:hidden hides self+subtree
  op := Opacity;
  if (st.Opacity >= 0) and (st.Opacity < 1) then op := op * st.Opacity;
  if SameText(st.Visibility, 'hidden') then Hidden := True;
  if Box.IsImagePlaceholder then
  begin
    if Box.ImageHandle >= 0 then
    begin
      Canvas.DrawImage(Box.ImageHandle, Box.X, y, Box.W, Box.H);
      Exit;
    end;
    Canvas.FillRect(Box.X, y, Box.W, Box.H, IMG_PLACEHOLDER_BG);
    Canvas.StrokeRect(Box.X, y, Box.W, Box.H, 1, IMG_PLACEHOLDER_FG);
    Canvas.DrawLine(Box.X, y, Box.X + Box.W, y + Box.H, 1, IMG_PLACEHOLDER_FG);
    Canvas.DrawLine(Box.X + Box.W, y, Box.X, y + Box.H, 1, IMG_PLACEHOLDER_FG);
    if (Box.Tag <> nil) then
    begin
      sizeTxt := Format('img %dx%d', [Round(Box.W), Round(Box.H)]);
      m := Canvas.MeasureText(sizeTxt, 11, []);
      Canvas.DrawText(Box.X + (Box.W - m.Width) / 2, y + (Box.H - 14) / 2,
        sizeTxt, 11, [], IMG_PLACEHOLDER_FG);
    end;
    Exit;
  end;
  // checkbox / radio: small drawn glyphs, state from the 'checked' attribute
  if Box.ControlKind in [ckCheckbox, ckRadio] then
  begin
    if Box.ControlKind = ckRadio then
    begin
      Canvas.FillRoundRect(Box.X, y, 16, 16, 8, $FFFFFFFF);
      Canvas.StrokeRoundRect(Box.X, y, 16, 16, 8, 1.5, TC_BORDER);
      if (Box.Tag <> nil) and Box.Tag.HasAttribute('checked') then
        Canvas.FillRoundRect(Box.X + 4, y + 4, 8, 8, 4, TC_ACCENT);
    end
    else
    begin
      if (Box.Tag <> nil) and Box.Tag.HasAttribute('checked') then
        Canvas.FillRoundRect(Box.X, y, 16, 16, 3, TC_ACCENT)
      else
        Canvas.FillRoundRect(Box.X, y, 16, 16, 3, $FFFFFFFF);
      Canvas.StrokeRoundRect(Box.X, y, 16, 16, 3, 1.5, TC_BORDER);
      if (Box.Tag <> nil) and Box.Tag.HasAttribute('checked') then
        Canvas.DrawText(Box.X + 2.5, y - 0.5, '✓', 12, [tfsBold], $FFFFFFFF);
    end;
    Exit;
  end;

  // box-shadow (drawn under the box; blur approximated as a hard edge)
  if (not Hidden) and st.BoxShadow.Active and not st.BoxShadow.Inset then
    Canvas.FillRect(
      Box.X + st.BoxShadow.OffsetX - st.BoxShadow.SpreadRadius,
      y + st.BoxShadow.OffsetY - st.BoxShadow.SpreadRadius,
      Box.W + 2 * st.BoxShadow.SpreadRadius,
      Box.H + 2 * st.BoxShadow.SpreadRadius,
      ScaleAlpha(st.BoxShadow.Color, op));

  bg := ScaleAlpha(st.BackgroundColor, op);
  bd := ScaleAlpha(st.BorderColor, op);
  // linear-gradient background approximated by the midpoint of its end stops
  if ((bg shr 24) = 0) and st.BgGradientActive then
    bg := ScaleAlpha(AvgColor(st.BgGradientStart, st.BgGradientEnd), op);
  if (not Hidden) and ((bg shr 24) > 0) then
  begin
    if st.MaxCornerRadius > 0 then
      Canvas.FillRoundRect(Box.X, y, Box.W, Box.H, st.MaxCornerRadius, bg)
    else
      Canvas.FillRect(Box.X, y, Box.W, Box.H, bg);
  end;
  if (not Hidden) and (st.BorderWidths.Top > 0) then
  begin
    if st.MaxCornerRadius > 0 then
      Canvas.StrokeRoundRect(Box.X, y, Box.W, Box.H, st.MaxCornerRadius,
        st.BorderWidths.Top, bd)
    else
      Canvas.StrokeRect(Box.X, y, Box.W, Box.H, st.BorderWidths.Top, bd);
  end;
  // list marker: right-aligned so multi-char markers (III., 10.) share the
  // same right edge, sitting just left of the content text.
  if (not Hidden) and (Box.MarkerText <> '') then
  begin
    m := Canvas.MeasureText(Box.MarkerText, st.FontSize, []);
    Canvas.DrawText(Box.X + st.BorderWidths.Left + st.Padding.Left - 8 - m.Width,
      y + st.BorderWidths.Top + st.Padding.Top, Box.MarkerText,
      st.FontSize, [], ScaleAlpha(st.Color, op));
  end;

  // scrollable / clipped inner box: clip, then draw content shifted by ScrollTop.
  // didClip MUST gate ClearClip (not "innerOfs<>OffsetY") — a scroller sitting
  // at ScrollTop=0 still opened a clip and must close it, else the saved
  // graphics state leaks and swallows everything drawn afterwards (e.g. the
  // dropdown overlay).
  innerOfs := OffsetY;
  sx := Box.ScrollLeft;
  didClip := Box.Scrollable or Box.ScrollableX
             or ((Box.MaxScroll > 0) and not Box.Scrollable)
             or ((Box.MaxScrollX > 0) and not Box.ScrollableX);
  if didClip then
  begin
    Canvas.SetClip(Box.X + st.BorderWidths.Left, y + st.BorderWidths.Top,
      Box.W - st.BorderWidths.Horz, Box.H - st.BorderWidths.Vert);
    innerOfs := OffsetY + Box.ScrollTop;
  end;

  if not Hidden then
    for i := 0 to Box.Runs.Count - 1 do
    begin
      r := Box.Runs[i];
      fg := ScaleAlpha(r.Color, op);
      Canvas.DrawText(r.X - sx, r.Y - innerOfs, r.Text, r.FontSize, r.Styles, fg);
    end;
  for i := 0 to Box.Children.Count - 1 do
  begin
    if sx <> 0 then ShiftBoxTree(Box.Children[i], -sx, 0);
    PaintBoxEx(Canvas, Box.Children[i], innerOfs, op, Hidden);
    if sx <> 0 then ShiftBoxTree(Box.Children[i], sx, 0);
  end;

  if didClip then
  begin
    Canvas.ClearClip;
    if Box.Scrollable and (Box.MaxScroll > 0) then
    begin // slim scrollbar thumb inside the box
      thumbH := Box.H * (Box.H / (Box.H + Box.MaxScroll));
      thumbY := y + (Box.ScrollTop / Box.MaxScroll) * (Box.H - thumbH);
      Canvas.FillRoundRect(Box.X + Box.W - 7, thumbY, 4, thumbH, 2, $50000000);
    end;
  end;

  // caret + select arrow for the focused/dropdown controls
  if (Box.Tag <> nil) then
  begin
    if (Box.ControlKind in [ckTextInput, ckTextarea]) and Box.Tag.IsFocused then
    begin
      if Box.ControlKind = ckTextarea then
        val := Box.Tag.GetAttribute('value', InnerText(Box.Tag))
      else
        val := Box.Tag.GetAttribute('value');
      cx := Box.X + st.BorderWidths.Left + st.Padding.Left + 1;
      cy := y + st.BorderWidths.Top + st.Padding.Top;
      if (Box.Runs.Count > 0) and (val <> '') then
      begin
        r := Box.Runs[Box.Runs.Count - 1];
        if Box.ControlKind = ckTextInput then
        begin
          // caret at the byte offset carried in '_caret' (default: end)
          i := StrToIntDef(Box.Tag.GetAttribute('_caret'), Length(val));
          i := Max(0, Min(i, Length(val)));
          m := Canvas.MeasureText(Copy(val, 1, i), r.FontSize, r.Styles);
        end
        else
          m := Canvas.MeasureText(r.Text, r.FontSize, r.Styles);
        cx := r.X + m.Width + 1;
        cy := r.Y - innerOfs;
      end;
      Canvas.FillRect(cx, cy, 1.5, st.FontSize + 4, $FF1F2937);
    end;
    if Box.ControlKind = ckSelect then
      Canvas.DrawText(Box.X + Box.W - 18, y + st.BorderWidths.Top + st.Padding.Top,
        '▾', st.FontSize, [], TC_MUTED);
  end;
  finally
    if shifted then ShiftBoxTree(Box, -tx, -ty);
  end;
end;

function HitTest(Box: TLayoutBox; X, Y: Single): THTMLTag;
var
  i: Integer;
  r: THTMLTag;
  inside: Boolean;
  childY: Single;
begin
  Result := nil;
  inside := (X >= Box.X) and (X <= Box.X + Box.W) and
            (Y >= Box.Y) and (Y <= Box.Y + Box.H);
  // a clipped scroller swallows anything outside its rect
  if Box.Scrollable and not inside then Exit;
  childY := Y;
  if Box.Scrollable then childY := Y + Box.ScrollTop;
  for i := Box.Children.Count - 1 downto 0 do
  begin
    r := HitTest(Box.Children[i], X, childY);
    if r <> nil then Exit(r);
  end;
  if inside and (Box.Tag <> nil) then Result := Box.Tag;
end;

function FindScrollBox(Box: TLayoutBox; X, Y: Single): TLayoutBox;
var
  i: Integer;
  inside: Boolean;
  childY: Single;
begin
  Result := nil;
  inside := (X >= Box.X) and (X <= Box.X + Box.W) and
            (Y >= Box.Y) and (Y <= Box.Y + Box.H);
  if Box.Scrollable and not inside then Exit;
  childY := Y;
  if Box.Scrollable then childY := Y + Box.ScrollTop;
  for i := Box.Children.Count - 1 downto 0 do
  begin
    Result := FindScrollBox(Box.Children[i], X, childY);
    if Result <> nil then Exit;
  end;
  if inside and ((Box.Scrollable and (Box.MaxScroll > 0)) or
                 (Box.ScrollableX and (Box.MaxScrollX > 0))) then Result := Box;
end;

function FindBoxForTag(Box: TLayoutBox; T: THTMLTag): TLayoutBox;
var
  i: Integer;
begin
  if Box.Tag = T then Exit(Box);
  Result := nil;
  for i := 0 to Box.Children.Count - 1 do
  begin
    Result := FindBoxForTag(Box.Children[i], T);
    if Result <> nil then Exit;
  end;
end;

end.
