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
  Tina4HTMLDom, Tina4RenderBackend, Tina4Theme, Tina4QR, Tina4SVG;

type
  TTextRun = record
    Text: string;
    X, Y: Single; // absolute document coords, top-left of text
    FontSize: Single;
    Styles: TTina4FontStyles;
    Color: TTina4Color;
    LetterSpacing: Single;
  end;

  { Form controls are DRAWN by the renderer (no native widgets); their state
    lives in the DOM: input/textarea in 'value', checkbox/radio in 'checked',
    select in 'value'. The app mutates attributes and rebuilds. }
  TControlKind = (ckNone, ckTextInput, ckTextarea, ckCheckbox, ckRadio,
    ckSelect, ckButton, ckFile);

  TLayoutBox = class
  public
    Tag: THTMLTag;                 // may be nil for anonymous boxes
    Style: TComputedStyle;
    X, Y, W, H: Single;            // border box, absolute document coords
    Children: TObjectList<TLayoutBox>;
    Runs: TList<TTextRun>;
    IsImagePlaceholder: Boolean;
    ImageHandle: Integer;          // canvas image handle, -1 = none/failed
    IsQRCode: Boolean;             // <qrcode> replaced element
    QRMatrix: TQRMatrix;           // pre-encoded module grid, painted as cells
    IsSVG: Boolean;                // <svg> replaced element
    SVGRoot: THTMLTag;             // the <svg> node, painted vector at paint time
    ControlKind: TControlKind;
    Scrollable: Boolean;           // overflow-y auto/scroll with an explicit height
    ScrollTop: Single;
    MaxScroll: Single;
    ScrollableX: Boolean;          // overflow-x auto/scroll
    ScrollLeft: Single;
    MaxScrollX: Single;
    NaturalW: Single;              // widest line of content (for overflow-x)
    NaturalH: Single;              // natural content height (for cell v-align)
    MarkerText: string;            // list-item bullet/number, '' if none
    constructor Create;
    destructor Destroy; override;
  end;

  TLayoutEngine = class
  private
    FCanvas: TTina4Canvas;
    FSheet: TCSSStyleSheet;
    FBaseStyle: TComputedStyle;
    FViewportW: Single;            // for <picture>/srcset media + sizes eval
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
    { A replaced element (img/svg/qrcode) used directly as a block or flex
      item — build it as an atom instead of laying out its children. Returns
      nil when Tag is not a replaced element. }
    function MakeReplacedBox(T: THTMLTag; const cs: TComputedStyle;
      CW: Single): TLayoutBox;
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

{ Caret blink phase for focused text inputs. The shell toggles this on a
  ~500ms timer and repaints; when False the caret is not painted. }
var
  Tina4CaretVisible: Boolean = True;
  { Persistent scrollbar thumbs. Shells can disable them (mobile convention). }
  Tina4ScrollbarsVisible: Boolean = True;

procedure PaintBox(Canvas: TTina4Canvas; Box: TLayoutBox; OffsetY: Single);
function HitTest(Box: TLayoutBox; X, Y: Single): THTMLTag;
{ Deepest overflow-scrollable box containing the point (doc coords). }
function FindScrollBox(Box: TLayoutBox; X, Y: Single): TLayoutBox;
{ Box whose Tag = T (first match). }
function FindBoxForTag(Box: TLayoutBox; T: THTMLTag): TLayoutBox;
{ Concatenated descendant text of a tag (entities already decoded). }
function InnerText(Tag: THTMLTag): string;
function IsFormControlTag(const Name: string): Boolean;
{ Classify a tag as a form control kind (ckNone if not a control). }
function ControlKindOf(Tag: THTMLTag): TControlKind;

{ Capture-protection: when on, any element with class="sensitive" (or a <secure>
  tag) is redacted at paint time — its content and subtree are not drawn. Paint-
  time only, so nothing reflows and the live user is unaffected until the shell
  flips this on a real screen-capture. }
procedure SetCaptureProtected(B: Boolean);

{ Responsive-image selection (exposed for testing). PickFromSrcset chooses the
  best URL from a srcset for a target width; EvalMediaQuery evaluates a source's
  media against the viewport; ResolveImgSrc resolves an <img>'s effective src
  honouring an enclosing <picture>. }
function PickFromSrcset(const Srcset: string; TargetW: Single): string;
function EvalMediaQuery(const MQ: string; ViewportW: Single): Boolean;
function ResolveImgSrc(T: THTMLTag; ViewportW, ElemW: Single): string;

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
    SameText(Name, 'select') or SameText(Name, 'button') or
    SameText(Name, 'camera');
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
var td: string;
begin
  Result := [];
  if St.Bold then Include(Result, tfsBold);
  if St.Italic then Include(Result, tfsItalic);
  td := LowerCase(St.TextDecoration);
  if Pos('underline', td) > 0 then Include(Result, tfsUnderline);
  if Pos('line-through', td) > 0 then Include(Result, tfsStrike);
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
    // centre the single line in the box (matches MakeControl) so a padded
    // inline-block used as a button reads with even top/bottom padding
    run.Y := Max(St.BorderWidths.Top,
      (Result.H - St.FontSize) / 2);
    run.FontSize := St.FontSize;
    run.Styles := FontStylesOf(St);
    run.Color := St.Color; run.LetterSpacing := 0;
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
  else if (typ = 'file') or SameText(Tag.TagName, 'camera') then Result := ckFile
  else if (typ = 'submit') or (typ = 'button') then Result := ckButton
  else Result := ckTextInput;
end;

{ Widest replaced descendant (qrcode/img) with an explicit width, so a
  shrink-to-fit flex/inline-block container reserves room for it instead of
  measuring only its text and letting the graphic overflow. }
function MaxReplacedW(Tag: THTMLTag): Single;
var
  c: THTMLTag;
  w: Single;
begin
  Result := 0;
  if (SameText(Tag.TagName, 'qrcode') or SameText(Tag.TagName, 'img') or
      SameText(Tag.TagName, 'svg')) and Tag.HasAttribute('width') then
    Result := TComputedStyle.ParseLength(Tag.GetAttribute('width'), 16);
  for c in Tag.Children do
  begin
    w := MaxReplacedW(c);
    if w > Result then Result := w;
  end;
end;

{ ---- <picture>/srcset responsive image selection ---------------------- }

{ true if NSImage-decodable raster type; external SVG isn't rasterised }
function ImageTypeSupported(const MimeType: string): Boolean;
var t: string;
begin
  t := LowerCase(Trim(MimeType));
  Result := (t = '') or (t = 'image/jpeg') or (t = 'image/jpg') or
    (t = 'image/png') or (t = 'image/gif') or (t = 'image/webp') or
    (t = 'image/bmp') or (t = 'image/tiff') or (t = 'image/x-icon') or
    (t = 'image/heic') or (t = 'image/heif');
end;

{ evaluate a media-query list against the viewport width. Handles the common
  responsive features (min-/max-width); unknown features are permissive so a
  source is only excluded when a width feature actually fails. }
function EvalMediaQuery(const MQ: string; ViewportW: Single): Boolean;
var
  parts: TArray<string>;
  i, colon: Integer;
  clause, feat, valStr: string;
  n: Single;
begin
  Result := True;
  if Trim(MQ) = '' then Exit;
  parts := LowerCase(MQ).Split([' and ']);
  for i := 0 to High(parts) do
  begin
    clause := Trim(parts[i]);
    clause := StringReplace(clause, '(', '', [rfReplaceAll]);
    clause := StringReplace(clause, ')', '', [rfReplaceAll]);
    colon := Pos(':', clause);
    if colon = 0 then Continue;               // e.g. bare "screen" — permissive
    feat := Trim(Copy(clause, 1, colon - 1));
    valStr := Trim(Copy(clause, colon + 1, MaxInt));
    valStr := StringReplace(LowerCase(valStr), 'px', '', [rfReplaceAll]);
    n := StrToFloatDef(Trim(valStr), -1);
    if n < 0 then Continue;
    if feat = 'max-width' then
      begin if ViewportW > n then Exit(False); end
    else if feat = 'min-width' then
      begin if ViewportW < n then Exit(False); end;
    // other features: ignore (permissive)
  end;
end;

{ resolve `sizes` to a target render width in px (first matching clause),
  falling back to the element width or the viewport }
function ResolveSizes(const Sizes: string; ViewportW, ElemW: Single): Single;
var
  parts: TArray<string>;
  i, sp: Integer;
  clause, cond, lenStr: string;
begin
  if Trim(Sizes) <> '' then
  begin
    parts := Sizes.Split([',']);
    for i := 0 to High(parts) do
    begin
      clause := Trim(parts[i]);
      if clause = '' then Continue;
      // "(max-width: 600px) 480px"  or a bare "800px" default
      if (clause[1] = '(') then
      begin
        sp := Pos(')', clause);
        cond := Copy(clause, 1, sp);
        lenStr := Trim(Copy(clause, sp + 1, MaxInt));
        if not EvalMediaQuery(cond, ViewportW) then Continue;
      end
      else
        lenStr := clause;
      lenStr := StringReplace(LowerCase(lenStr), 'px', '', [rfReplaceAll]);
      Result := StrToFloatDef(Trim(lenStr), -1);
      if Result > 0 then Exit;
    end;
  end;
  if ElemW > 0 then Result := ElemW else Result := ViewportW;
end;

{ pick the best URL from a srcset string for the given target width }
function PickFromSrcset(const Srcset: string; TargetW: Single): string;
var
  cands: TArray<string>;
  i, sp: Integer;
  entry, url, descr: string;
  hasW, isW: Boolean;
  num, dens, bestW, bestDens: Single;
  bestWUrl, bestDensUrl: string;
begin
  Result := '';
  cands := Srcset.Split([',']);
  hasW := False;
  bestW := 1e30; bestWUrl := '';
  bestDens := 1e30; bestDensUrl := '';
  for i := 0 to High(cands) do
  begin
    entry := Trim(cands[i]);
    if entry = '' then Continue;
    sp := Pos(' ', entry);
    if sp = 0 then begin url := entry; descr := ''; end
    else begin url := Trim(Copy(entry, 1, sp - 1)); descr := Trim(Copy(entry, sp + 1, MaxInt)); end;
    if url = '' then Continue;
    descr := LowerCase(Trim(descr));
    isW := (descr <> '') and (descr[Length(descr)] = 'w');
    if isW then
    begin
      hasW := True;
      num := StrToFloatDef(Copy(descr, 1, Length(descr) - 1), 0);
      // smallest candidate width >= target wins; track the largest as fallback
      if (num >= TargetW) and (num < bestW) then begin bestW := num; bestWUrl := url; end;
      if (bestWUrl = '') then
      begin
        // no candidate >= target yet: keep the largest seen
        if (num > 0) and ((bestDensUrl = '') or (num > bestDens)) then
        begin bestDens := num; bestDensUrl := url; end;
      end;
    end
    else
    begin
      // density descriptor (Nx) or none (=1x); prefer the one closest to 1x
      if descr = '' then dens := 1
      else dens := StrToFloatDef(Copy(descr, 1, Length(descr) - 1), 1);
      if Abs(dens - 1) < Abs(bestDens - 1) then
      begin bestDens := dens; bestDensUrl := url; end;
    end;
  end;
  if hasW then
  begin
    if bestWUrl <> '' then Result := bestWUrl
    else Result := bestDensUrl;   // largest fallback
  end
  else
    Result := bestDensUrl;
end;

{ effective src for an <img>, honouring an enclosing <picture>'s <source>s
  and the element's own srcset/sizes, else its plain src }
function ResolveImgSrc(T: THTMLTag; ViewportW, ElemW: Single): string;
var
  s: THTMLTag;
  targetW: Single;
begin
  if (T.Parent <> nil) and SameText(T.Parent.TagName, 'picture') then
    for s in T.Parent.Children do
    begin
      if s = T then Break;   // <source>s precede the <img>
      if not SameText(s.TagName, 'source') then Continue;
      if s.HasAttribute('media') and
         not EvalMediaQuery(s.GetAttribute('media'), ViewportW) then Continue;
      if s.HasAttribute('type') and
         not ImageTypeSupported(s.GetAttribute('type')) then Continue;
      if not s.HasAttribute('srcset') then Continue;
      targetW := ResolveSizes(s.GetAttribute('sizes'), ViewportW, ElemW);
      Result := PickFromSrcset(s.GetAttribute('srcset'), targetW);
      if Result <> '' then Exit;
    end;
  if T.HasAttribute('srcset') then
  begin
    targetW := ResolveSizes(T.GetAttribute('sizes'), ViewportW, ElemW);
    Result := PickFromSrcset(T.GetAttribute('srcset'), targetW);
    if Result <> '' then Exit;
  end;
  Result := T.GetAttribute('src');
end;

{ UA fallback chrome for controls the stylesheet didn't style; also the
  focus ring. Shared by MakeControl and RefreshStyles. }
procedure ApplyControlChrome(var St: TComputedStyle; Kind: TControlKind;
  Focused: Boolean; Primary: Boolean = False; Disabled: Boolean = False);
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
    ckButton, ckFile:
      begin
        if (St.BackgroundColor shr 24) = 0 then
        begin
          if Primary then
          begin // submit → indigo primary
            St.BackgroundColor := TC_ACCENT;
            St.Color := TC_ON_ACCENT;
          end
          else
          begin // plain button / file picker → neutral surface + border
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
  if Disabled then
  begin // greyed background + muted text, like a native disabled control
    St.BackgroundColor := $FFF1F1F4;
    St.Color := $FF9CA3AF;
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
  rows, i, ci, firstLine: Integer;
  lines: TStringList;
  opt: THTMLTag;
  seg: string;
begin
  kind := ControlKindOf(Tag);
  Result := TLayoutBox.Create;
  Result.Tag := Tag;
  Result.ControlKind := kind;
  ApplyControlChrome(St, kind, Tag.IsFocused, IsPrimaryButton(Tag), Tag.HasAttribute('disabled'));
  Result.Style := St;

  padH := St.Padding.Horz + St.BorderWidths.Horz;
  padV := St.Padding.Vert + St.BorderWidths.Vert;
  lineH := LineHeightOf(St);

  case kind of
    ckCheckbox, ckRadio:
      if St.AppearanceNone then
      begin
        // appearance:none → render as a styled button (segmented control / tab),
        // captioned by the value attribute. Selection = the `checked` attribute,
        // stylable with :checked. Falls through to the shared button sizing below.
        txt := Trim(Tag.GetAttribute('value'));
        if txt = '' then txt := InnerText(Tag);
      end
      else
      begin
        // native 18px glyph (comfortable tap target); at least as tall as the
        // text line box so it centres against the label.
        Result.W := 18;
        Result.H := Max(18, lineH);
        Exit;
      end;
    ckButton:
      begin
        txt := Trim(Tag.GetAttribute('value'));
        if txt = '' then txt := InnerText(Tag);
        if txt = '' then txt := 'Submit';
      end;
    ckFile:
      begin
        // "📎 Choose File" or the selected filename; the value holds the path
        txt := Trim(Tag.GetAttribute('value'));
        if txt <> '' then txt := #$F0#$9F#$93#$8E' ' + ExtractFileName(txt)
        else if SameText(Tag.TagName, 'camera') then txt := #$F0#$9F#$93#$B7' Take Photo'
        else txt := #$F0#$9F#$93#$8E' Choose File';
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
  else if (kind = ckButton) or St.AppearanceNone then
    Result.W := FCanvas.MeasureText(txt, St.FontSize, FontStylesOf(St)).Width + padH
  else
    Result.W := Min(240 + padH, AvailW);

  if kind = ckTextarea then
  begin
    rows := StrToIntDef(Tag.GetAttribute('rows'), 4);
    Result.H := rows * lineH + padV;
    if (txt = '') and (Tag.GetAttribute('placeholder') <> '') then
    begin // empty → muted placeholder on the first line
      run.Text := Tag.GetAttribute('placeholder');
      run.X := St.BorderWidths.Left + St.Padding.Left;
      run.Y := St.BorderWidths.Top + St.Padding.Top;
      run.FontSize := St.FontSize; run.Styles := FontStylesOf(St);
      run.Color := $FF9CA3AF; run.LetterSpacing := 0;
      Result.Runs.Add(run);
      Exit;
    end;
    // split on newlines, KEEPING a trailing empty line so the caret can sit on
    // a freshly-opened line (TStringList.Text would drop it). CR stripped first.
    lines := TStringList.Create;
    try
      txt := StringReplace(txt, #13, '', [rfReplaceAll]);
      seg := '';
      for ci := 1 to Length(txt) do
        if txt[ci] = #10 then begin lines.Add(seg); seg := ''; end
        else seg := seg + txt[ci];
      lines.Add(seg);   // final segment (empty if txt ended with a newline)
      // auto-scroll: when the text is taller than the box, show the LAST `rows`
      // lines so the caret line stays visible while typing.
      firstLine := 0;
      if lines.Count > rows then firstLine := lines.Count - rows;
      for i := firstLine to lines.Count - 1 do
      begin
        run.Text := lines[i];
        run.X := St.BorderWidths.Left + St.Padding.Left;
        run.Y := St.BorderWidths.Top + St.Padding.Top + (i - firstLine) * lineH;
        run.FontSize := St.FontSize;
        run.Styles := FontStylesOf(St);
        run.Color := St.Color; run.LetterSpacing := 0;
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
    run.FontSize := St.FontSize;
    run.Styles := FontStylesOf(St);
    m := FCanvas.MeasureText(run.Text, St.FontSize, run.Styles);
    run.X := St.BorderWidths.Left + St.Padding.Left;
    // vertically centre the single-line caption/value in the control box so
    // top/bottom padding read as uniform (buttons, inputs, file, select).
    // Centre the glyph's OWN box (ascent+descent, per the backend's metrics),
    // not a FontSize-tall box — those differ per font, which is what left the
    // "Choose File"/"Take Photo" captions off-centre on Core Text.
    run.Y := Max(St.BorderWidths.Top,
      (Result.H - (m.Ascent + m.Descent)) / 2);
    if ph <> '' then run.Color := $FF9CA3AF else run.Color := St.Color; run.LetterSpacing := 0;
    if (kind = ckButton) or St.AppearanceNone then    // centre the caption
      run.X := (Result.W - m.Width) / 2;
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

function TLayoutEngine.MakeReplacedBox(T: THTMLTag; const cs: TComputedStyle;
  CW: Single): TLayoutBox;
var
  iw, ih: Single;
  qrText: string;
begin
  Result := nil;
  if SameText(T.TagName, 'svg') then
  begin
    Result := TLayoutBox.Create;
    Result.Tag := T; Result.Style := cs;
    Result.IsSVG := True; Result.SVGRoot := T;
    if cs.ExplicitWidth >= 0 then Result.W := cs.ExplicitWidth else Result.W := -1;
    if cs.ExplicitHeight >= 0 then Result.H := cs.ExplicitHeight else Result.H := -1;
    if (Result.W < 0) or (Result.H < 0) then
    begin
      if SVGIntrinsicSize(T, iw, ih) and (iw > 0) and (ih > 0) then
      begin
        if (Result.W < 0) and (Result.H < 0) then begin Result.W := iw; Result.H := ih; end
        else if Result.W < 0 then Result.W := iw * (Result.H / ih)
        else Result.H := ih * (Result.W / iw);
      end
      else begin if Result.W < 0 then Result.W := 150; if Result.H < 0 then Result.H := 150; end;
    end;
  end
  else if SameText(T.TagName, 'qrcode') then
  begin
    Result := TLayoutBox.Create;
    Result.Tag := T; Result.Style := cs; Result.IsQRCode := True;
    qrText := T.GetAttribute('value');
    if qrText = '' then qrText := T.GetAttribute('data');
    if qrText = '' then qrText := Trim(CollapseWS(InnerText(T)));
    if not QREncode(qrText, Result.QRMatrix) then Result.QRMatrix.Size := 0;
    if cs.ExplicitWidth >= 0 then Result.W := cs.ExplicitWidth
    else if cs.ExplicitHeight >= 0 then Result.W := cs.ExplicitHeight
    else Result.W := 120;
    Result.H := Result.W;
  end
  else if SameText(T.TagName, 'img') then
  begin
    Result := TLayoutBox.Create;
    Result.Tag := T; Result.Style := cs; Result.IsImagePlaceholder := True;
    Result.ImageHandle := FCanvas.LoadImage(ResolveImgSrc(T, FViewportW, cs.ExplicitWidth));
    if cs.ExplicitWidth >= 0 then Result.W := cs.ExplicitWidth else Result.W := 120;
    if cs.ExplicitHeight >= 0 then Result.H := cs.ExplicitHeight else Result.H := 80;
    if ((cs.ExplicitWidth < 0) or (cs.ExplicitHeight < 0)) and
       FCanvas.ImageSize(Result.ImageHandle, iw, ih) and (iw > 0) and (ih > 0) then
    begin
      if (cs.ExplicitWidth < 0) and (cs.ExplicitHeight < 0) then begin Result.W := iw; Result.H := ih; end
      else if cs.ExplicitWidth < 0 then Result.W := iw * (Result.H / ih)
      else Result.H := ih * (Result.W / iw);
    end;
  end;
  if Result <> nil then
  begin
    if (CW > 0) and (Result.W > CW) then
    begin Result.H := Result.H * (CW / Result.W); Result.W := CW; end;
  end;
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
  itemTags: TList<THTMLTag>;
  c: THTMLTag;
  mL, mR, mT, mB, availInner, ew, eh: Single;
  edgeL, edgeT, edgeR, edgeB, contentX, contentY, contentW, contentH: Single;
  isCol: Boolean;
  dir, jc, ai: string;
  sumMain, freeMain, curr, gap, crossOff, usedFixed, sumGrow, targetW: Single;
  lineW, lineH, lineFree, lx, lgap, lineY, totalH, flexGap: Single;
  baseW, growF: array of Single;
  sb: TStringBuilder;
  m: TTina4TextMetrics;
  i, k, lineEnd: Integer;
  fw: string;
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
  flexGap := st.FlexGap; if flexGap < 0 then flexGap := 0;   // CSS gap between items
  jc := LowerCase(st.JustifyContent); if jc = '' then jc := 'flex-start';
  ai := LowerCase(st.AlignItems); if ai = '' then ai := 'stretch';

  // build flex items. For a row we resolve flex-basis + flex-grow first so
  // items share the free space (the common flex:1 layout); a column keeps
  // each item at content width.
  items := TObjectList<TLayoutBox>.Create(False);
  itemTags := TList<THTMLTag>.Create;
  try
    for c in Tag.Children do
    begin
      if IsTextNode(c) then Continue;
      cs := TComputedStyle.ForTag(c, st, FSheet);
      if LowerCase(cs.Display) = 'none' then Continue;
      itemTags.Add(c);
    end;

    if isCol then
    begin
      for i := 0 to itemTags.Count - 1 do
      begin
        cs := TComputedStyle.ForTag(itemTags[i], st, FSheet);
        cb := MakeReplacedBox(itemTags[i], cs, contentW);
        if (cb = nil) and IsFormControlTag(itemTags[i].TagName) then
          cb := MakeControl(itemTags[i], cs, contentW);
        if cb = nil then cb := MakeInlineContainer(itemTags[i], cs, contentW);
        box.Children.Add(cb); items.Add(cb);
      end;
    end
    else
    begin
      // row: base widths + grow factors
      SetLength(baseW, itemTags.Count);
      SetLength(growF, itemTags.Count);
      usedFixed := 0; sumGrow := 0;
      for i := 0 to itemTags.Count - 1 do
      begin
        cs := TComputedStyle.ForTag(itemTags[i], st, FSheet);
        growF[i] := cs.FlexGrow;
        ew := ResolveSize(cs.ExplicitWidth, contentW);
        // checkbox/radio have a fixed intrinsic size — CSS width doesn't grow
        // them, so don't let it reserve flex space either
        if ControlKindOf(itemTags[i]) in [ckCheckbox, ckRadio] then
        begin
          baseW[i] := 18; growF[i] := 0;
        end
        else if ew >= 0 then
        begin
          if not SameText(cs.BoxSizing, 'border-box') then
            ew := ew + cs.Padding.Horz + cs.BorderWidths.Horz;
          baseW[i] := ew;
        end
        else if growF[i] > 0 then
          baseW[i] := 0                        // flex:1 → basis 0
        else
        begin                                   // content width (single line)
          sb := TStringBuilder.Create;
          try
            CollectInlineText(itemTags[i], sb);
            m := FCanvas.MeasureText(Trim(CollapseWS(sb.ToString)), cs.FontSize, FontStylesOf(cs));
          finally sb.Free; end;
          // reserve room for any explicitly-sized replaced graphic inside
          baseW[i] := Max(m.Width, MaxReplacedW(itemTags[i])) +
            cs.Padding.Horz + cs.BorderWidths.Horz;
        end;
        usedFixed := usedFixed + baseW[i];
        sumGrow := sumGrow + growF[i];
      end;
      freeMain := contentW - usedFixed - flexGap * Max(0, itemTags.Count - 1);
      if freeMain < 0 then freeMain := 0;
      for i := 0 to itemTags.Count - 1 do
      begin
        cs := TComputedStyle.ForTag(itemTags[i], st, FSheet);
        targetW := baseW[i];
        // grow only when NOT wrapping (wrapped items keep their base size)
        if (growF[i] > 0) and (sumGrow > 0) and
           not ((LowerCase(st.FlexWrap) = 'wrap') or (LowerCase(st.FlexWrap) = 'wrap-reverse')) then
          targetW := targetW + freeMain * growF[i] / sumGrow;
        cs.ExplicitWidth := targetW;    // force the resolved main size
        cs.BoxSizing := 'border-box';
        cb := MakeReplacedBox(itemTags[i], cs, contentW);
        if (cb = nil) and IsFormControlTag(itemTags[i].TagName) then
          cb := MakeControl(itemTags[i], cs, contentW)   // control, not a box
        else if cb = nil then
        begin
          cb := MakeInlineContainer(itemTags[i], cs, contentW);
          cb.W := targetW;
        end;
        box.Children.Add(cb); items.Add(cb);
      end;
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

    // flex-wrap (row): greedy-pack items into lines, stack on the cross axis
    fw := LowerCase(st.FlexWrap);
    if (not isCol) and ((fw = 'wrap') or (fw = 'wrap-reverse')) then
    begin
      lineY := contentY; totalH := 0; i := 0;
      while i < items.Count do
      begin
        lineW := 0; lineEnd := i;
        while (lineEnd < items.Count) and
              ((lineEnd = i) or
               (lineW + flexGap + items[lineEnd].W <= contentW + 0.5)) do
        begin
          if lineEnd > i then lineW := lineW + flexGap;
          lineW := lineW + items[lineEnd].W;
          Inc(lineEnd);
        end;
        lineH := 0;
        for k := i to lineEnd - 1 do lineH := Max(lineH, items[k].H);
        lineFree := contentW - lineW; if lineFree < 0 then lineFree := 0;
        lx := 0; lgap := 0;
        if jc = 'center' then lx := lineFree / 2
        else if (jc = 'flex-end') or (jc = 'end') then lx := lineFree
        else if (jc = 'space-between') and (lineEnd - i > 1) then lgap := lineFree / (lineEnd - i - 1)
        else if (jc = 'space-around') and (lineEnd - i > 0) then
        begin lx := lineFree / ((lineEnd - i) * 2); lgap := lineFree / (lineEnd - i); end;
        for k := i to lineEnd - 1 do
        begin
          cb := items[k];
          if ai = 'center' then crossOff := (lineH - cb.H) / 2
          else if (ai = 'flex-end') or (ai = 'end') then crossOff := lineH - cb.H
          else crossOff := 0;
          ShiftBoxTree(cb, contentX + lx, lineY + crossOff);
          lx := lx + cb.W + lgap + flexGap;
        end;
        lineY := lineY + lineH + flexGap;
        totalH := totalH + lineH + flexGap;
        i := lineEnd;
      end;
      if totalH > contentH then contentH := totalH;
      box.H := contentH + edgeT + edgeB;
      Result := box.H + mT + mB;
      Exit;   // finally frees items/itemTags
    end;

    // main-axis packing (single line)
    sumMain := 0;
    for i := 0 to items.Count - 1 do
      if isCol then sumMain := sumMain + items[i].H
      else sumMain := sumMain + items[i].W;
    if isCol then freeMain := contentH - sumMain
    else freeMain := contentW - sumMain;
    freeMain := freeMain - flexGap * Max(0, items.Count - 1);   // reserve gaps
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
        curr := curr + cb.H + gap + flexGap;
      end
      else
      begin
        // cross axis = vertical
        if (ai = 'center') then crossOff := (contentH - cb.H) / 2
        else if (ai = 'flex-end') or (ai = 'end') then crossOff := contentH - cb.H
        else crossOff := 0;
        ShiftBoxTree(cb, contentX + curr, contentY + crossOff);
        curr := curr + cb.W + gap + flexGap;
      end;
    end;

    box.H := contentH + edgeT + edgeB;
    Result := box.H + mT + mB;
  finally
    items.Free;
    itemTags.Free;
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
    Ascent: Single;        // distance from top of item to its baseline (line sizing)
    FontAscent: Single;    // the font's own ascent (baseline placement for text)
    FontSize: Single;
    Styles: TTina4FontStyles;
    Color: TTina4Color;
    LetterSpacing: Single;
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

  procedure AddQuoteWord(const Q: string; const St: TComputedStyle; SpaceBefore: Boolean);
  var
    qi: TInlineItem;
    qm: TTina4TextMetrics;
  begin
    qm := FCanvas.MeasureText(Q, St.FontSize, FontStylesOf(St));
    qi.Text := Q; qi.Box := nil; qi.W := qm.Width; qi.H := LineHeightOf(St);
    qi.Ascent := (qi.H - (qm.Ascent + qm.Descent)) / 2 + qm.Ascent;
    qi.FontSize := St.FontSize; qi.Styles := FontStylesOf(St); qi.Color := St.Color;
    qi.LetterSpacing := St.LetterSpacing;
    qi.SpaceBefore := SpaceBefore and (items.Count > 0); qi.LineBreak := False;
    items.Add(qi);
  end;

  procedure GatherInline(T: THTMLTag; const St: TComputedStyle);
  var
    c: THTMLTag;
    cs: TComputedStyle;
    words: TStringList;
    i: Integer;
    it: TInlineItem;
    m: TTina4TextMetrics;
    disp, txt, qrText: string;
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
        FCanvas.LetterSpacing := St.LetterSpacing;
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
          // FontAscent is the FONT's own ascent (what the backend adds to a run
          // top to reach the baseline). Placing the run by FontAscent — not by
          // it.Ascent, which also carries the half-leading — makes the glyph
          // baseline land exactly on the line baseline instead of half-leading
          // too high (visible as a label riding high next to a checkbox).
          it.FontAscent := m.Ascent;
          // sub/super shift the item's baseline off the line baseline
          if SameText(St.VerticalAlign, 'sub') then
          begin it.Ascent := it.Ascent - St.FontSize * 0.28; it.FontAscent := it.FontAscent - St.FontSize * 0.28; end
          else if SameText(St.VerticalAlign, 'super') then
          begin it.Ascent := it.Ascent + St.FontSize * 0.42; it.FontAscent := it.FontAscent + St.FontSize * 0.42; end;
          it.FontSize := St.FontSize;
          it.Styles := FontStylesOf(St);
          it.Color := St.Color;
          it.LetterSpacing := St.LetterSpacing;
          it.SpaceBefore := (items.Count > 0) and ((i > 0) or leadingSpace);
          items.Add(it);
        end;
        FCanvas.LetterSpacing := 0;
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
    if SameText(T.TagName, 'svg') then
    begin
      it.Text := '';
      it.Box := TLayoutBox.Create;
      it.Box.Tag := T;
      it.Box.Style := cs;
      it.Box.IsSVG := True;
      it.Box.SVGRoot := T;
      // size: width/height attrs win, else viewBox aspect, else a default box
      if cs.ExplicitWidth >= 0 then it.Box.W := cs.ExplicitWidth else it.Box.W := -1;
      if cs.ExplicitHeight >= 0 then it.Box.H := cs.ExplicitHeight else it.Box.H := -1;
      if (it.Box.W < 0) or (it.Box.H < 0) then
      begin
        if SVGIntrinsicSize(T, iw, ih) and (iw > 0) and (ih > 0) then
        begin
          if (it.Box.W < 0) and (it.Box.H < 0) then
          begin it.Box.W := iw; it.Box.H := ih; end
          else if it.Box.W < 0 then it.Box.W := iw * (it.Box.H / ih)
          else it.Box.H := ih * (it.Box.W / iw);
        end
        else
        begin
          if it.Box.W < 0 then it.Box.W := 150;
          if it.Box.H < 0 then it.Box.H := 150;
        end;
      end;
      if it.Box.W > CW then
      begin it.Box.H := it.Box.H * (CW / it.Box.W); it.Box.W := CW; end;
      it.W := it.Box.W; it.H := it.Box.H;
      it.FontSize := cs.FontSize; it.Styles := [];
      it.Ascent := it.Box.H;
      it.SpaceBefore := (items.Count > 0) and pendingSpace;
      pendingSpace := False;
      Box.Children.Add(it.Box);
      items.Add(it);
      Exit;
    end;
    if SameText(T.TagName, 'qrcode') then
    begin
      it.Text := '';
      it.Box := TLayoutBox.Create;
      it.Box.Tag := T;
      it.Box.Style := cs;
      it.Box.IsQRCode := True;
      qrText := T.GetAttribute('value');
      if qrText = '' then qrText := T.GetAttribute('data');
      if qrText = '' then qrText := Trim(CollapseWS(InnerText(T)));
      if not QREncode(qrText, it.Box.QRMatrix) then
        it.Box.QRMatrix.Size := 0;
      // square, sized by width/height attr or a sensible default
      if cs.ExplicitWidth >= 0 then it.Box.W := cs.ExplicitWidth
      else if cs.ExplicitHeight >= 0 then it.Box.W := cs.ExplicitHeight
      else it.Box.W := 120;
      it.Box.H := it.Box.W;
      // only shrink-to-fit when no explicit size was asked for; an author who
      // wrote width=140 wants 140 even inside a narrow shrink-wrap container
      if (cs.ExplicitWidth < 0) and (cs.ExplicitHeight < 0) and
         (CW > 0) and (it.Box.W > CW) then
      begin it.Box.W := CW; it.Box.H := CW; end;
      it.W := it.Box.W; it.H := it.Box.H;
      it.FontSize := cs.FontSize; it.Styles := [];
      it.Ascent := it.Box.H;
      it.SpaceBefore := (items.Count > 0) and pendingSpace;
      pendingSpace := False;
      Box.Children.Add(it.Box);
      items.Add(it);
      Exit;
    end;
    if SameText(T.TagName, 'img') then
    begin
      it.Text := '';
      it.Box := TLayoutBox.Create;
      it.Box.Tag := T;
      it.Box.Style := cs;
      it.Box.IsImagePlaceholder := True;
      // <picture>/srcset: choose the best source for this viewport + slot
      it.Box.ImageHandle := FCanvas.LoadImage(
        ResolveImgSrc(T, FViewportW, cs.ExplicitWidth));
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
    // <q> gets automatic quotation marks around its content
    if SameText(T.TagName, 'q') then
    begin
      AddQuoteWord(#$E2#$80#$9C, cs, pendingSpace);   // “
      pendingSpace := False;
      for c in T.Children do GatherInline(c, cs);
      AddQuoteWord(#$E2#$80#$9D, cs, False);          // ”
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
          // centre the box within the line box (matches browsers for the
          // common case of same-height inline-blocks filling the line)
          ShiftBoxTree(it.Box, x, lineTop + (lineH - it.H) / 2)
        else // baseline: box bottom on the baseline
          ShiftBoxTree(it.Box, x, lineTop + maxAscent - it.Ascent);
      end
      else
      begin
        run.Text := it.Text;
        run.X := x;
        // place by the font's ascent so the backend's baseline (run.Y + its own
        // ascent) lands on the line baseline — not half-leading above it
        run.Y := lineTop + maxAscent - it.FontAscent;
        run.FontSize := it.FontSize;
        run.Styles := it.Styles;
        run.Color := it.Color;
        run.LetterSpacing := it.LetterSpacing;
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
  prevMB, mTc, absX, absY, absCH: Single;
  hadInline: Boolean;
  absBox: TLayoutBox;
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
      // <details>: when closed, render only the <summary>
      if SameText(Tag.TagName, 'details') and not Tag.HasAttribute('open')
         and not (IsTextNode(c) or SameText(c.TagName, 'summary')) then Continue;
      if IsTextNode(c) then
      begin
        GatherInline(c, ParentStyle);
        hadInline := True;
        Continue;
      end;
      cs := TComputedStyle.ForTag(c, ParentStyle, FSheet);
      disp := DisplayOf(c, cs);
      if disp = 'none' then Continue;
      // position: absolute/fixed — out of flow, positioned in this container's
      // content box (the common case: an absolutely-positioned child of a
      // position:relative parent). Takes no space; siblings ignore it.
      if SameText(cs.CSSPosition, 'absolute') or SameText(cs.CSSPosition, 'fixed') then
      begin
        LayoutBlock(Box, c, ParentStyle, CX, CY, CW);
        absBox := Box.Children[Box.Children.Count - 1];
        absX := CX; absY := CY;
        if cs.CSSLeft > -9998 then absX := CX + cs.CSSLeft
        else if cs.CSSRight > -9998 then absX := CX + CW - absBox.W - cs.CSSRight;
        if cs.CSSTop > -9998 then absY := CY + cs.CSSTop
        else if cs.CSSBottom > -9998 then
        begin
          // bottom needs the container content height — use its explicit
          // height (known now via the container's own style)
          absCH := ResolveSize(ParentStyle.ExplicitHeight, 0);
          if absCH < 0 then absCH := Box.NaturalH;
          absY := CY + absCH - absBox.H - cs.CSSBottom;
        end;
        ShiftBoxTree(absBox, absX - absBox.X, absY - absBox.Y);
        Continue;  // no flow advance
      end;
      // form control keeps its computed display: inline/inline-block flow inline,
      // block (e.g. Bootstrap .form-control) stacks full-width.
      // img/svg/qrcode are replaced elements: always inline-atomic, never
      // laid out as HTML children, whatever their display value
      if SameText(c.TagName, 'img') or SameText(c.TagName, 'svg')
        or SameText(c.TagName, 'qrcode')
        or (disp = 'inline') or (disp = 'inline-block')
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
  mL, mR, mT, mB, ew, eh, availInner, naturalH, mnw, mxw, relDX, relDY: Single;
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
  // <summary> disclosure triangle, reflecting the parent <details> open state
  if SameText(Tag.TagName, 'summary') and (Tag.Parent <> nil) then
  begin
    if Tag.Parent.HasAttribute('open') then box.MarkerText := #$E2#$96#$BE   // ▾
    else box.MarkerText := #$E2#$96#$B8;                                     // ▸
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

  // position: relative — offset visually by top/left (or right/bottom),
  // without changing the space the box occupies in normal flow.
  if SameText(st.CSSPosition, 'relative') then
  begin
    relDX := 0; relDY := 0;
    if st.CSSLeft > -9998 then relDX := st.CSSLeft
    else if st.CSSRight > -9998 then relDX := -st.CSSRight;
    if st.CSSTop > -9998 then relDY := st.CSSTop
    else if st.CSSBottom > -9998 then relDY := -st.CSSBottom;
    if (relDX <> 0) or (relDY <> 0) then ShiftBoxTree(box, relDX, relDY);
  end;

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
  total, scale, cx, rowY, rowH, usedH, cw, tableW, tblAvail, explW, ch, vaShift: Single;
  hasBorder: Boolean;
  va: string;
  colspan: Integer;
  spanW: Single;

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
        if SameText(cell.TagName, 'td') or SameText(cell.TagName, 'th') then
          Inc(i, Max(1, StrToIntDef(cell.GetAttribute('colspan', '1'), 1)));
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
        // a colspan cell spreads its width across the columns it covers
        colspan := Max(1, StrToIntDef(cell.GetAttribute('colspan', '1'), 1));
        for i := ci to Min(ci + colspan - 1, ncols - 1) do
          prefW[i] := Max(prefW[i], cw / colspan);
        Inc(ci, colspan);
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
        // colspan: this cell spans the next N columns; its width sums them
        colspan := StrToIntDef(cell.GetAttribute('colspan', '1'), 1);
        if colspan < 1 then colspan := 1;
        spanW := 0;
        for i := ci to Min(ci + colspan - 1, ncols - 1) do spanW := spanW + prefW[i];
        cbox.X := cx; cbox.Y := rowY; cbox.W := spanW;
        LayoutChildren(cbox, cell, cs,
          cx + cs.BorderWidths.Left + cs.Padding.Left,
          rowY + cs.BorderWidths.Top + cs.Padding.Top,
          spanW - cs.Padding.Horz - cs.BorderWidths.Horz, usedH);
        cbox.NaturalH := usedH + cs.Padding.Vert + cs.BorderWidths.Vert;  // before height honoring
        // honour an explicit cell height (content-box)
        ch := ResolveSize(cs.ExplicitHeight, 0);
        if ch >= 0 then usedH := Max(usedH, ch);
        if cell.HasAttribute('height') then
          usedH := Max(usedH, TComputedStyle.ParseLength(cell.GetAttribute('height'), cs.FontSize));
        cbox.H := usedH + cs.Padding.Vert + cs.BorderWidths.Vert;
        rowH := Max(rowH, cbox.H);
        cx := cx + spanW;
        Inc(ci, colspan);
      end;
      // uniform row height + vertical-align of cell content (middle/bottom)
      for i := 0 to rbox.Children.Count - 1 do
      begin
        cbox := rbox.Children[i];
        va := LowerCase(cbox.Style.VerticalAlign);
        if ((va = 'middle') or (va = 'bottom')) and (rowH > cbox.NaturalH) then
        begin
          if va = 'middle' then vaShift := (rowH - cbox.NaturalH) / 2
          else vaShift := rowH - cbox.NaturalH;
          ShiftBoxTree(cbox, 0, vaShift);   // move content down
          cbox.Y := cbox.Y - vaShift;       // but keep the cell box at row top
        end;
        cbox.H := rowH;
      end;
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
  FViewportW := ViewportW;
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
      ApplyControlChrome(st, Box.ControlKind, Box.Tag.IsFocused, IsPrimaryButton(Box.Tag), Box.Tag.HasAttribute('disabled'));
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
var
  GCaptureProtected: Boolean = False;   // redact class="sensitive" while capturing

const
  TC_REDACT = TTina4Color($FF212529);   // solid slate bar over redacted content

procedure SetCaptureProtected(B: Boolean);
begin
  GCaptureProtected := B;
end;

{ True if this box opts into capture redaction — class="sensitive" or <secure>. }
function IsSensitive(Box: TLayoutBox): Boolean;
begin
  Result := False;
  if (Box = nil) or (Box.Tag = nil) then Exit;
  if SameText(Box.Tag.TagName, 'secure') then Exit(True);
  Result := Pos(' sensitive ',
    ' ' + LowerCase(Box.Tag.GetAttribute('class')) + ' ') > 0;
end;

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

{ Multiply RGB by factor (keep alpha) — the pressed/active feedback for a
  tapped button darkens its fill toward black. Factor 0.85 ≈ a 15% press. }
function Darken(C: TTina4Color; Factor: Single): TTina4Color;
var r, g, b: Integer;
begin
  r := Round(((C shr 16) and $FF) * Factor);
  g := Round(((C shr 8)  and $FF) * Factor);
  b := Round(( C         and $FF) * Factor);
  if r > 255 then r := 255; if g > 255 then g := 255; if b > 255 then b := 255;
  Result := (C and $FF000000) or (TTina4Color(r) shl 16)
            or (TTina4Color(g) shl 8) or TTina4Color(b);
end;

procedure PaintBoxEx(Canvas: TTina4Canvas; Box: TLayoutBox; OffsetY: Single;
  Opacity: Single; Hidden: Boolean); forward;

procedure PaintBox(Canvas: TTina4Canvas; Box: TLayoutBox; OffsetY: Single);
begin
  PaintBoxEx(Canvas, Box, OffsetY, 1.0, False);
end;

{ Paint a <qrcode> box: white quiet-zone ground, dark modules as squares.
  The module grid is snapped to whole pixels so scanners see crisp edges. }
procedure PaintQR(Canvas: TTina4Canvas; Box: TLayoutBox; Y: Single);
const
  QUIET = 4;                       // spec-minimum quiet zone, in modules
var
  n, total, r, c: Integer;
  scale, ox, oy, px, py: Single;
begin
  Canvas.FillRect(Box.X, Y, Box.W, Box.H, $FFFFFFFF);
  n := Box.QRMatrix.Size;
  if n <= 0 then
  begin
    Canvas.StrokeRect(Box.X, Y, Box.W, Box.H, 1, $FFCCCCCC);
    Exit;
  end;
  total := n + 2 * QUIET;
  scale := Box.W / total;          // one module edge in device pixels
  ox := Box.X + QUIET * scale;
  oy := Y + QUIET * scale;
  for r := 0 to n - 1 do
    for c := 0 to n - 1 do
      if Box.QRMatrix.Modules[r][c] then
      begin
        px := ox + c * scale;
        py := oy + r * scale;
        // +1px overdraw closes seams from fractional module sizes
        Canvas.FillRect(px, py, scale + 1, scale + 1, $FF000000);
      end;
end;

procedure PaintBoxEx(Canvas: TTina4Canvas; Box: TLayoutBox; OffsetY: Single;
  Opacity: Single; Hidden: Boolean);
var
  i: Integer;
  r: TTextRun;
  st: TComputedStyle;
  y, innerOfs, thumbH, thumbY, thumbW, thumbX, cx, cy, gy: Single;
  sizeTxt, val: string;
  m: TTina4TextMetrics;
  didClip: Boolean;
  op, tx, ty, sx, rcx, rcy: Single;
  shifted, hasRS: Boolean;
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
  // transform: rotate/scale — wrap the subtree paint in a canvas transform
  // about the box centre (default transform-origin)
  hasRS := (st.TransformRotate <> 0) or (st.TransformScaleX <> 1) or (st.TransformScaleY <> 1);
  if hasRS then
  begin
    rcx := Box.X + Box.W / 2; rcy := y + Box.H / 2;
    Canvas.SaveState;
    Canvas.Translate(rcx, rcy);
    if st.TransformRotate <> 0 then Canvas.Rotate(-st.TransformRotate); // CSS is clockwise
    if (st.TransformScaleX <> 1) or (st.TransformScaleY <> 1) then
      Canvas.Scale(st.TransformScaleX, st.TransformScaleY);
    Canvas.Translate(-rcx, -rcy);
  end;
  // CSS opacity multiplies down the subtree; visibility:hidden hides self+subtree
  op := Opacity;
  if (st.Opacity >= 0) and (st.Opacity < 1) then op := op * st.Opacity;
  if SameText(st.Visibility, 'hidden') then Hidden := True;
  // capture protection: redact a sensitive element (content + subtree) with a
  // solid bar and stop — no relayout, so the on-screen layout is unchanged.
  if GCaptureProtected and (not Hidden) and IsSensitive(Box) then
  begin
    if st.MaxCornerRadius > 0 then
      Canvas.FillRoundRect(Box.X, y, Box.W, Box.H, st.MaxCornerRadius, TC_REDACT)
    else
      Canvas.FillRect(Box.X, y, Box.W, Box.H, TC_REDACT);
    Exit;
  end;
  if Box.IsQRCode then
  begin
    PaintQR(Canvas, Box, y);
    Exit;
  end;
  if Box.IsSVG then
  begin
    if Box.SVGRoot <> nil then PaintSVG(Canvas, Box.SVGRoot, Box.X, y, Box.W, Box.H);
    Exit;
  end;
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
  // checkbox / radio: small drawn glyphs, state from the 'checked' attribute.
  // gy centres the 16px glyph within the (line-height-tall) control box so it
  // lines up with the label text beside it. appearance:none opts out of the
  // native glyph — it paints as a normal styled box (segmented button) below.
  if (Box.ControlKind in [ckCheckbox, ckRadio]) and not st.AppearanceNone then
  begin
    gy := y + (Box.H - 18) / 2;
    if Box.ControlKind = ckRadio then
    begin
      Canvas.FillRoundRect(Box.X, gy, 18, 18, 9, $FFFFFFFF);
      Canvas.StrokeRoundRect(Box.X, gy, 18, 18, 9, 1.5, TC_BORDER);
      if (Box.Tag <> nil) and Box.Tag.HasAttribute('checked') then
        Canvas.FillRoundRect(Box.X + 5, gy + 5, 8, 8, 4, TC_ACCENT);
    end
    else
    begin
      if (Box.Tag <> nil) and Box.Tag.HasAttribute('checked') then
        Canvas.FillRoundRect(Box.X, gy, 18, 18, 4, TC_ACCENT)
      else
        Canvas.FillRoundRect(Box.X, gy, 18, 18, 4, $FFFFFFFF);
      Canvas.StrokeRoundRect(Box.X, gy, 18, 18, 4, 1.5, TC_BORDER);
      if (Box.Tag <> nil) and Box.Tag.HasAttribute('checked') then
        Canvas.DrawText(Box.X + 3, gy + 0.5, '✓', 13, [tfsBold], $FFFFFFFF);
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
      Canvas.LetterSpacing := r.LetterSpacing;
      Canvas.DrawText(r.X - sx, r.Y - innerOfs, r.Text, r.FontSize, r.Styles, fg);
      Canvas.LetterSpacing := 0;
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
    if Tina4ScrollbarsVisible and Box.Scrollable and (Box.MaxScroll > 0) then
    begin // vertical scrollbar thumb, right edge
      thumbH := Box.H * (Box.H / (Box.H + Box.MaxScroll));
      thumbY := y + (Box.ScrollTop / Box.MaxScroll) * (Box.H - thumbH);
      Canvas.FillRoundRect(Box.X + Box.W - 7, thumbY, 4, thumbH, 2, $50000000);
    end;
    if Tina4ScrollbarsVisible and Box.ScrollableX and (Box.MaxScrollX > 0) then
    begin // horizontal scrollbar thumb, bottom edge
      thumbW := Box.W * (Box.W / (Box.W + Box.MaxScrollX));
      thumbX := Box.X + (Box.ScrollLeft / Box.MaxScrollX) * (Box.W - thumbW);
      Canvas.FillRoundRect(thumbX, y + Box.H - 7, thumbW, 4, 2, $50000000);
    end;
  end;

  // caret + select arrow for the focused/dropdown controls
  if (Box.Tag <> nil) then
  begin
    if (Box.ControlKind in [ckTextInput, ckTextarea]) and Box.Tag.IsFocused
       and Tina4CaretVisible then
    begin
      if Box.ControlKind = ckTextarea then
        val := Box.Tag.GetAttribute('value', InnerText(Box.Tag))
      else
        val := Box.Tag.GetAttribute('value');
      cx := Box.X + st.BorderWidths.Left + st.Padding.Left + 1;
      // vertical position matches the (centred) text run, so the caret does
      // not jump when the first character is typed; fall back to the same
      // centring formula when there is no run yet
      if Box.Runs.Count > 0 then
      begin
        r := Box.Runs[Box.Runs.Count - 1];
        cy := r.Y - innerOfs;
        if val <> '' then
        begin
          if Box.ControlKind = ckTextInput then
          begin
            // caret at the byte offset carried in '_caret' (default: end)
            i := StrToIntDef(Box.Tag.GetAttribute('_caret'), Length(val));
            i := Max(0, Min(i, Length(val)));
            m := Canvas.MeasureText(Copy(val, 1, i), r.FontSize, r.Styles);
          end
          else
            m := Canvas.MeasureText(r.Text, r.FontSize, r.Styles);
          cx := r.X + m.Width + 1;   // caret after the text
        end;
        // (empty + placeholder run: caret stays at the start, cx unchanged)
      end
      else
        cy := y + (Box.H - st.FontSize) / 2;
      Canvas.FillRect(cx, cy, 1.5, st.FontSize + 2, $FF1F2937);
    end;
    if Box.ControlKind = ckSelect then
      Canvas.DrawText(Box.X + Box.W - 18, y + st.BorderWidths.Top + st.Padding.Top,
        '▾', st.FontSize, [], TC_MUTED);
  end;
  finally
    if hasRS then Canvas.RestoreState;
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
