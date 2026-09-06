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
  Tina4HTMLDom, Tina4RenderBackend, Tina4Theme, Tina4QR, Tina4SVG, Tina4Canvas2D,
  Tina4Lottie;

type
  TTextRun = record
    Text: string;
    X, Y: Single; // absolute document coords, top-left of text
    FontSize: Single;
    Styles: TTina4FontStyles;
    Color: TTina4Color;
    LetterSpacing: Single;
    FontFamily: string;
    FontWeight: Integer;
    ShadowDX, ShadowDY: Single; ShadowColor: TTina4Color;  // text-shadow
  end;

  { Form controls are DRAWN by the renderer (no native widgets); their state
    lives in the DOM: input/textarea in 'value', checkbox/radio in 'checked',
    select in 'value'. The app mutates attributes and rebuilds. }
  TControlKind = (ckNone, ckTextInput, ckTextarea, ckCheckbox, ckRadio,
    ckSelect, ckButton, ckFile, ckDate, ckRange, ckColor, ckProgress, ckMeter);

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
    MarkerImage: Integer;          // list-style-image handle, -1 = none
    constructor Create;
    destructor Destroy; override;
  end;

  // A floated box's occupied region in absolute document coords. Shared on the
  // engine so a container's floats also narrow inline lines inside its nested
  // block descendants (same block formatting context).
  TFloatBand = record Side: Integer; X0, X1, Y0, Y1: Single; end;  // Side 0=left 1=right

  TLayoutEngine = class
  private
    FCanvas: TTina4Canvas;
    FSheet: TCSSStyleSheet;
    FBaseStyle: TComputedStyle;
    FViewportW: Single;            // for <picture>/srcset media + sizes eval
    FFloats: array of TFloatBand;  // active float context (absolute coords)
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
    function LayoutGrid(Parent: TLayoutBox; Tag: THTMLTag;
      const ParentStyle: TComputedStyle; X, Y, AvailW: Single): Single;
    procedure CollectInlineText(Tag: THTMLTag; SB: TStringBuilder);
  public
    constructor Create(Canvas: TTina4Canvas; Sheet: TCSSStyleSheet);
    function Build(Root: THTMLTag; ViewportW: Single; ViewportH: Single = 0): TLayoutBox;
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

{ Format an ISO date (yyyy-mm-dd) for display per a token pattern:
  yyyy/yy year · MMMM/MMM/MM/M month · dd/d day. Falls back to the raw string. }
function FormatDateDisplay(const ISO, Fmt: string): string;

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

{ A modal <dialog> (opened via dialog.showModal → has `open`+`_modal`) is skipped
  in the normal paint pass and drawn last, centred over a backdrop, by
  PaintModalOverlay. Returns the modal dialog's box, or nil. }
function FindModalDialog(Box: TLayoutBox): TLayoutBox;
{ Paint the dimmed backdrop + the centred modal dialog as a top layer. Call
  after PaintBox with the viewport size. No-op when no modal dialog is open. }
procedure PaintModalOverlay(Canvas: TTina4Canvas; Root: TLayoutBox; W, H: Single);

{ Map a CSS `cursor` keyword to the shell's pointer-shape enum. }
function CursorKindFor(const CSS: string): TTina4Cursor;
{ Pointer shape for the element at (docX, docY) in the given tree, honouring
  `cursor` inheritance up the DOM. tcDefault when nothing sets one. }
function CursorAt(Root: TLayoutBox; DocX, DocY: Single): TTina4Cursor;

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
  MarkerImage := -1;
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
  if V <= -99999 then Result := ResolveCalc(V, Avail)   // deferred %-bearing calc()
  else if V >= 0 then Result := V
  else if (V < -1.5) and (V > -1000) and (V <> -3) then Result := Avail * (-V) / 100
  else Result := -1; // auto
end;

function IsFormControlTag(const Name: string): Boolean;
begin
  Result := SameText(Name, 'input') or SameText(Name, 'textarea') or
    SameText(Name, 'select') or SameText(Name, 'button') or
    SameText(Name, 'camera') or SameText(Name, 'progress') or
    SameText(Name, 'meter');
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
  if Pos('overline', td) > 0 then Include(Result, tfsOverline);
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
    run.FontFamily := St.FontFamily; run.FontWeight := St.FontWeight;
    run.ShadowColor := 0; run.ShadowDX := 0; run.ShadowDY := 0;
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
  else if SameText(Tag.TagName, 'progress') then Result := ckProgress
  else if SameText(Tag.TagName, 'meter') then Result := ckMeter
  else if typ = 'checkbox' then Result := ckCheckbox
  else if typ = 'radio' then Result := ckRadio
  else if (typ = 'file') or SameText(Tag.TagName, 'camera') then Result := ckFile
  else if (typ = 'submit') or (typ = 'button') then Result := ckButton
  else if typ = 'date' then Result := ckDate
  else if typ = 'range' then Result := ckRange
  else if typ = 'color' then Result := ckColor
  else Result := ckTextInput;
end;

const
  MON_ABBR: array[1..12] of string = ('Jan','Feb','Mar','Apr','May','Jun',
    'Jul','Aug','Sep','Oct','Nov','Dec');
  MON_FULL: array[1..12] of string = ('January','February','March','April',
    'May','June','July','August','September','October','November','December');

function FormatDateDisplay(const ISO, Fmt: string): string;
var
  y, mo, d, e, i, n: Integer;
  { true if Fmt has token `tok` (case-insensitive) at position i }
  function At(const tok: string): Boolean;
  begin
    Result := (i + Length(tok) - 1 <= Length(Fmt)) and
      SameText(Copy(Fmt, i, Length(tok)), tok);
  end;
begin
  Result := ISO;
  if Length(ISO) < 10 then Exit;
  Val(Copy(ISO, 1, 4), y, e);  if e <> 0 then Exit;
  Val(Copy(ISO, 6, 2), mo, e); if (e <> 0) or (mo < 1) or (mo > 12) then Exit;
  Val(Copy(ISO, 9, 2), d, e);  if (e <> 0) or (d < 1) or (d > 31) then Exit;
  // Scan tokens left→right, emitting substitutions so they're never re-scanned
  // (a naive StringReplace would corrupt month names, e.g. the 'M' in "March").
  // Longest token wins. Month is case-insensitive so dd/mm/yyyy and dd/MM/yyyy
  // both mean month (no time component in a date field).
  Result := ''; i := 1; n := Length(Fmt);
  while i <= n do
  begin
    if At('yyyy') then begin Result := Result + Format('%.4d', [y]); Inc(i, 4); end
    else if At('yy') then begin Result := Result + Format('%.2d', [y mod 100]); Inc(i, 2); end
    else if At('MMMM') then begin Result := Result + MON_FULL[mo]; Inc(i, 4); end
    else if At('MMM') then begin Result := Result + MON_ABBR[mo]; Inc(i, 3); end
    else if At('MM') then begin Result := Result + Format('%.2d', [mo]); Inc(i, 2); end
    else if At('dd') then begin Result := Result + Format('%.2d', [d]); Inc(i, 2); end
    else if At('M') then begin Result := Result + IntToStr(mo); Inc(i); end
    else if At('d') then begin Result := Result + IntToStr(d); Inc(i); end
    else begin Result := Result + Fmt[i]; Inc(i); end;
  end;
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

function CursorKindFor(const CSS: string): TTina4Cursor;
var c: string;
begin
  c := LowerCase(Trim(CSS));
  if c = 'pointer' then Result := tcPointer
  else if c = 'text' then Result := tcText
  else if c = 'move' then Result := tcMove
  else if c = 'grab' then Result := tcGrab
  else if c = 'grabbing' then Result := tcGrabbing
  else if c = 'crosshair' then Result := tcCrosshair
  else if (c = 'not-allowed') or (c = 'no-drop') then Result := tcNotAllowed
  else if (c = 'col-resize') or (c = 'ew-resize') or (c = 'e-resize') or (c = 'w-resize') then Result := tcColResize
  else if (c = 'row-resize') or (c = 'ns-resize') or (c = 'n-resize') or (c = 's-resize') then Result := tcRowResize
  else if (c = 'wait') or (c = 'progress') then Result := tcWait
  else if c = 'help' then Result := tcHelp
  else if c = 'none' then Result := tcNone
  else Result := tcDefault;   // auto / default / unknown
end;

function CursorAt(Root: TLayoutBox; DocX, DocY: Single): TTina4Cursor;
var t: THTMLTag; b: TLayoutBox;
begin
  Result := tcDefault;
  if Root = nil then Exit;
  t := HitTest(Root, DocX, DocY);
  while t <> nil do          // cursor inherits — walk up until one is set
  begin
    b := FindBoxForTag(Root, t);
    if (b <> nil) and (b.Style.CSSCursor <> '') then
      Exit(CursorKindFor(b.Style.CSSCursor));
    t := t.Parent;
  end;
end;

var
  GInModalPaint: Boolean = False;   // true while PaintModalOverlay draws the dialog
  GAnimSheet: TCSSStyleSheet = nil;  // sheet for @keyframes lookup during paint

{ Timing-function easing for a progress fraction (polynomial approximations). }
function AnimEase(const Fn: string; t: Single): Single;
begin
  if (Fn = 'linear') or (Fn = 'step') then Result := t
  else if Fn = 'ease-in' then Result := t * t
  else if Fn = 'ease-out' then Result := t * (2 - t)
  else Result := t * t * (3 - 2 * t);   // ease / ease-in-out ≈ smoothstep
end;

{ Tessellate a CSS clip-path basic shape into a polygon in box coordinates.
  Supports inset()/circle()/ellipse()/polygon(); returns [] for anything else
  (the caller then skips clipping). BX,BY = border-box origin; BW,BH = its size. }
function ClipPathPolygon(const Spec: string; BX, BY, BW, BH: Single): TTina4PointArray;
var
  s, inner, kw, radPart, cenPart: string;
  args, xy: TStringArray;
  i, n, seg: Integer;
  t, r, b, l, cx, cy, rx, ry, ang: Single;

  // resolve a length token against a reference dimension (px default, % of ref)
  function LenOf(const Tok: string; Ref: Single): Single;
  var v: string;
  begin
    v := Trim(Tok);
    if v = '' then Exit(0);
    if v.EndsWith('%') then Result := Ref * StrToFloatDef(Copy(v, 1, Length(v) - 1), 0) / 100
    else Result := StrToFloatDef(StringReplace(v, 'px', '', [rfReplaceAll, rfIgnoreCase]), 0);
  end;

begin
  SetLength(Result, 0);
  s := Trim(Spec);
  i := Pos('(', s);
  if i = 0 then Exit;
  kw := LowerCase(Trim(Copy(s, 1, i - 1)));
  inner := Copy(s, i + 1, MaxInt);
  n := LastDelimiter(')', inner); if n > 0 then inner := Copy(inner, 1, n - 1);
  inner := Trim(inner);

  if kw = 'inset' then
  begin
    // inset( t [r [b [l]]] [round ...] ) — drop any 'round' remainder
    n := Pos('round', LowerCase(inner));
    if n > 0 then inner := Trim(Copy(inner, 1, n - 1));
    args := inner.Split([' '], TStringSplitOptions.ExcludeEmpty);
    t := 0; r := 0; b := 0; l := 0;
    if Length(args) = 1 then begin t := LenOf(args[0], BH); r := LenOf(args[0], BW); b := t; l := r; end
    else if Length(args) = 2 then begin t := LenOf(args[0], BH); b := t; r := LenOf(args[1], BW); l := r; end
    else if Length(args) = 3 then begin t := LenOf(args[0], BH); r := LenOf(args[1], BW); l := r; b := LenOf(args[2], BH); end
    else if Length(args) >= 4 then begin t := LenOf(args[0], BH); r := LenOf(args[1], BW); b := LenOf(args[2], BH); l := LenOf(args[3], BW); end;
    SetLength(Result, 4);
    Result[0].X := BX + l;      Result[0].Y := BY + t;
    Result[1].X := BX + BW - r; Result[1].Y := BY + t;
    Result[2].X := BX + BW - r; Result[2].Y := BY + BH - b;
    Result[3].X := BX + l;      Result[3].Y := BY + BH - b;
  end
  else if (kw = 'circle') or (kw = 'ellipse') then
  begin
    // split "<radius> at <center>"; center defaults to 50% 50%
    n := Pos(' at ', ' ' + LowerCase(inner) + ' ');
    if n > 0 then begin radPart := Trim(Copy(inner, 1, n - 1)); cenPart := Trim(Copy(inner, n + 3, MaxInt)); end
    else begin radPart := Trim(inner); cenPart := ''; end;
    cx := BW / 2; cy := BH / 2;
    if cenPart <> '' then
    begin
      args := cenPart.Split([' '], TStringSplitOptions.ExcludeEmpty);
      if Length(args) >= 1 then cx := LenOf(args[0], BW);
      if Length(args) >= 2 then cy := LenOf(args[1], BH);
    end;
    args := radPart.Split([' '], TStringSplitOptions.ExcludeEmpty);
    if kw = 'ellipse' then
    begin
      if Length(args) >= 1 then rx := LenOf(args[0], BW) else rx := BW / 2;
      if Length(args) >= 2 then ry := LenOf(args[1], BH) else ry := BH / 2;
    end
    else
    begin
      // circle: one radius, px/% (% of sqrt(W²+H²)/√2) or closest/farthest-side
      if (Length(args) >= 1) and (LowerCase(args[0]) = 'closest-side') then
        rx := Min(Min(cx, BW - cx), Min(cy, BH - cy))
      else if (Length(args) >= 1) and (LowerCase(args[0]) = 'farthest-side') then
        rx := Max(Max(cx, BW - cx), Max(cy, BH - cy))
      else if Length(args) >= 1 then rx := LenOf(args[0], Sqrt(BW * BW + BH * BH) / Sqrt(2))
      else rx := Min(Min(cx, BW - cx), Min(cy, BH - cy)); // default closest-side
      ry := rx;
    end;
    seg := 48;
    SetLength(Result, seg);
    for i := 0 to seg - 1 do
    begin
      ang := 2 * Pi * i / seg;
      Result[i].X := BX + cx + rx * Cos(ang);
      Result[i].Y := BY + cy + ry * Sin(ang);
    end;
  end
  else if kw = 'polygon' then
  begin
    // polygon( [<fill-rule>,] x1 y1, x2 y2, ... ) — fill-rule prefix ignored
    n := Pos(',', inner);
    if n > 0 then
    begin
      kw := LowerCase(Trim(Copy(inner, 1, n - 1)));
      if (kw = 'nonzero') or (kw = 'evenodd') then inner := Trim(Copy(inner, n + 1, MaxInt));
    end;
    args := inner.Split([',']);
    for i := 0 to High(args) do
    begin
      xy := Trim(args[i]).Split([' '], TStringSplitOptions.ExcludeEmpty);
      if Length(xy) < 2 then Continue;
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)].X := BX + LenOf(xy[0], BW);
      Result[High(Result)].Y := BY + LenOf(xy[1], BH);
    end;
  end;
end;

{ Parse a `vertical-align: <length>` value to a baseline shift in px (positive =
  raise). Returns False for keywords / non-lengths. Bare numbers are invalid in
  CSS vertical-align except 0. }
function VAlignLength(const VA: string; EmSize: Single; out Shift: Single): Boolean;
var t: string;
begin
  Result := False; Shift := 0;
  t := LowerCase(Trim(VA));
  if t = '' then Exit;
  if t.EndsWith('px') then begin Shift := StrToFloatDef(Copy(t, 1, Length(t) - 2), 0); Result := True; end
  else if t.EndsWith('rem') then begin Shift := StrToFloatDef(Copy(t, 1, Length(t) - 3), 0) * 16; Result := True; end
  else if t.EndsWith('em') then begin Shift := StrToFloatDef(Copy(t, 1, Length(t) - 2), 0) * EmSize; Result := True; end
  else if (t[1] in ['0'..'9', '-', '+', '.']) then
  begin Shift := StrToFloatDef(t, 0); Result := (Shift = 0); end;  // only 0 is a valid bare number
end;

{ Extra padding (px) an offscreen filter layer needs so a blur/drop-shadow isn't
  clipped at the box edge. Reads the blur radius and any drop-shadow blur+offset. }
function FilterLayerPad(const Spec: string): Single;
var s, num: string; p, q, i: Integer; r: Single;
begin
  Result := 0;
  s := LowerCase(Spec);
  // blur(<len>)
  p := Pos('blur(', s);
  if p > 0 then
  begin
    q := p + 5; num := '';
    while (q <= Length(s)) and (s[q] in ['0'..'9', '.']) do begin num := num + s[q]; Inc(q); end;
    r := StrToFloatDef(num, 0);
    if r * 3 + 2 > Result then Result := r * 3 + 2;   // ~3σ Gaussian reach
  end;
  // drop-shadow(<x> <y> <blur> <color>) — pad by |offset| + blur reach
  p := Pos('drop-shadow(', s);
  if p > 0 then
  begin
    q := p + 12;
    for i := 1 to 3 do
    begin
      while (q <= Length(s)) and (s[q] = ' ') do Inc(q);
      num := '';
      while (q <= Length(s)) and (s[q] in ['0'..'9', '.', '-']) do begin num := num + s[q]; Inc(q); end;
      while (q <= Length(s)) and (s[q] in ['a'..'z', '%']) do Inc(q); // skip unit
      r := Abs(StrToFloatDef(num, 0));
      if i = 3 then r := r * 3;   // the 3rd value is blur
      if r + 2 > Result then Result := r + 2;
    end;
  end;
end;

{ Project the four corners of a box through its 3D transform matrix and
  perspective divide, into doc-space (x,y) pairs [TL,TR,BR,BL]. }
procedure Compute3DCorners(const st: TComputedStyle; BX, BY, BW, BH: Single;
  out C: array of Single);
var
  ox, oy, pivotX, pivotY, cx, cy, X, Y, W4: Single;
  i: Integer;
  lx, ly: array[0..3] of Single;
begin
  // transform-origin in px within the box
  if st.TransformOriginX < -1.5 then ox := BW * (-st.TransformOriginX) / 100 else ox := st.TransformOriginX;
  if st.TransformOriginY < -1.5 then oy := BH * (-st.TransformOriginY) / 100 else oy := st.TransformOriginY;
  pivotX := BX + ox; pivotY := BY + oy;
  lx[0] := -ox;      ly[0] := -oy;       // TL
  lx[1] := BW - ox;  ly[1] := -oy;       // TR
  lx[2] := BW - ox;  ly[2] := BH - oy;   // BR
  lx[3] := -ox;      ly[3] := BH - oy;   // BL
  for i := 0 to 3 do
  begin
    cx := lx[i]; cy := ly[i];
    X  := st.TransformM3D[0]*cx + st.TransformM3D[1]*cy + st.TransformM3D[3];
    Y  := st.TransformM3D[4]*cx + st.TransformM3D[5]*cy + st.TransformM3D[7];
    W4 := st.TransformM3D[12]*cx + st.TransformM3D[13]*cy + st.TransformM3D[15];
    if W4 < 0.0001 then W4 := 0.0001;    // clamp corners at/behind the camera
    C[i*2]     := pivotX + X / W4;
    C[i*2 + 1] := pivotY + Y / W4;
  end;
end;

{ Interpolate two colours (ARGB) by t. }
function LerpColor(A, B: TTina4Color; t: Single): TTina4Color;
  function Ch(sh: Integer): Cardinal;
  var ca, cb: Integer;
  begin
    ca := (A shr sh) and $FF; cb := (B shr sh) and $FF;
    Result := Cardinal(Round(ca + (cb - ca) * t)) and $FF;
  end;
begin
  Result := (Ch(24) shl 24) or (Ch(16) shl 16) or (Ch(8) shl 8) or Ch(0);
end;

{ Animate one scalar toward Target when it changes: stores per-element from/start
  on the tag (attributes), returns the current value and whether it's still moving. }
function TransScalar(Tag: THTMLTag; const Key: string; Target, Dur, Delay: Single;
  const Timing: string; out Cur: Single): Boolean;
var storedTgt, fromV, t0, elapsed, frac: Single;
begin
  Result := False; Cur := Target;
  if not Tag.HasAttribute('_trt_' + Key) then
  begin
    Tag.Attributes.AddOrSetValue('_trt_' + Key, FloatToStr(Target));
    Tag.Attributes.AddOrSetValue('_trc_' + Key, FloatToStr(Target));
    Exit;
  end;
  storedTgt := StrToFloatDef(Tag.GetAttribute('_trt_' + Key), Target);
  if Abs(storedTgt - Target) > 1e-4 then   // target changed → start from the shown value
  begin
    Tag.Attributes.AddOrSetValue('_trf_' + Key, Tag.GetAttribute('_trc_' + Key));
    Tag.Attributes.AddOrSetValue('_trt_' + Key, FloatToStr(Target));
    Tag.Attributes.AddOrSetValue('_tr0_' + Key, FloatToStr(AnimClock));
  end;
  fromV := StrToFloatDef(Tag.GetAttribute('_trf_' + Key), Target);
  t0 := StrToFloatDef(Tag.GetAttribute('_tr0_' + Key), AnimClock);
  elapsed := AnimClock - t0 - Delay;
  if elapsed < 0 then begin Cur := fromV; Result := True; end
  else if elapsed >= Dur then Cur := Target
  else begin frac := AnimEase(Timing, elapsed / Dur); Cur := fromV + (Target - fromV) * frac; Result := True; end;
  Tag.Attributes.AddOrSetValue('_trc_' + Key, FloatToStr(Cur));
end;

{ CSS transition: animate transform/opacity/colours toward the current computed
  value when it changes (hover/focus/DOM). Per-element state lives on the tag. }
procedure ApplyTransition(Box: TLayoutBox; var st: TComputedStyle);
var tag: THTMLTag; dur, del: Single; ti: string; cf: Single; pc: Cardinal;

  function Wants(const Name: string): Boolean;
  begin
    Result := (st.TransitionProp = 'all') or (st.TransitionProp = Name) or
      ((Name = 'background-color') and (st.TransitionProp = 'background'));
  end;

begin
  tag := Box.Tag;
  if (tag = nil) or (st.TransitionDuration <= 0) then Exit;
  dur := st.TransitionDuration; del := st.TransitionDelay; ti := st.TransitionTiming;
  if Wants('opacity') then
  begin if TransScalar(tag, 'op', st.Opacity, dur, del, ti, cf) then AnimMarkActive; st.Opacity := cf; end;
  if Wants('background-color') then
  begin
    // interpolate each ARGB channel so colours cross-fade smoothly
    if TransScalar(tag, 'bga', (st.BackgroundColor shr 24) and $FF, dur, del, ti, cf) then AnimMarkActive;
    pc := Cardinal(Round(cf)) shl 24;
    TransScalar(tag, 'bgr', (st.BackgroundColor shr 16) and $FF, dur, del, ti, cf); pc := pc or (Cardinal(Round(cf)) shl 16);
    TransScalar(tag, 'bgg', (st.BackgroundColor shr 8) and $FF, dur, del, ti, cf); pc := pc or (Cardinal(Round(cf)) shl 8);
    TransScalar(tag, 'bgb', st.BackgroundColor and $FF, dur, del, ti, cf); pc := pc or Cardinal(Round(cf));
    st.BackgroundColor := pc;
  end;
  if Wants('transform') then
  begin
    if TransScalar(tag, 'ttx', st.TransformTranslateX, dur, del, ti, cf) then AnimMarkActive; st.TransformTranslateX := cf;
    if TransScalar(tag, 'tty', st.TransformTranslateY, dur, del, ti, cf) then AnimMarkActive; st.TransformTranslateY := cf;
    if TransScalar(tag, 'trot', st.TransformRotate, dur, del, ti, cf) then AnimMarkActive; st.TransformRotate := cf;
    if TransScalar(tag, 'tsx', st.TransformScaleX, dur, del, ti, cf) then AnimMarkActive; st.TransformScaleX := cf;
    if TransScalar(tag, 'tsy', st.TransformScaleY, dur, del, ti, cf) then AnimMarkActive; st.TransformScaleY := cf;
  end;
end;

{ Apply the element's @keyframes animation to its style for the current clock —
  mutates transform/opacity/colours in-place, keeping the ticker alive. }
procedure ApplyKeyframeAnim(var st: TComputedStyle);
var
  offs: TArray<Single>; blocks: TArray<string>;
  t, frac, o0, o1, lt: Single;
  iter, i, i0, i1: Integer;
  s0, s1: TComputedStyle; rev: Boolean;
begin
  if (GAnimSheet = nil) or (st.AnimName = '') or (st.AnimDuration <= 0) then Exit;
  if not GAnimSheet.KeyframeStops(st.AnimName, offs, blocks) then Exit;
  t := (AnimClock - st.AnimDelay) / st.AnimDuration;
  if t < 0 then t := 0;
  iter := Trunc(t);
  frac := t - iter;
  if (st.AnimIterCount >= 0) and (t >= st.AnimIterCount) then
  begin frac := 1; iter := Trunc(st.AnimIterCount); end;
  rev := False;
  if st.AnimDirection = 'reverse' then rev := True
  else if st.AnimDirection = 'alternate' then rev := Odd(iter)
  else if st.AnimDirection = 'alternate-reverse' then rev := not Odd(iter);
  if rev then frac := 1 - frac;
  frac := AnimEase(st.AnimTiming, frac);
  // surrounding stops
  i0 := 0; i1 := High(offs);
  for i := 0 to High(offs) do if offs[i] <= frac then i0 := i;
  for i := High(offs) downto 0 do if offs[i] >= frac then i1 := i;
  o0 := offs[i0]; o1 := offs[i1];
  if o1 > o0 then lt := (frac - o0) / (o1 - o0) else lt := 0;
  s0 := TComputedStyle.ResolveBlock(blocks[i0], st);
  s1 := TComputedStyle.ResolveBlock(blocks[i1], st);
  st.TransformTranslateX := s0.TransformTranslateX + (s1.TransformTranslateX - s0.TransformTranslateX) * lt;
  st.TransformTranslateY := s0.TransformTranslateY + (s1.TransformTranslateY - s0.TransformTranslateY) * lt;
  st.TransformRotate := s0.TransformRotate + (s1.TransformRotate - s0.TransformRotate) * lt;
  st.TransformScaleX := s0.TransformScaleX + (s1.TransformScaleX - s0.TransformScaleX) * lt;
  st.TransformScaleY := s0.TransformScaleY + (s1.TransformScaleY - s0.TransformScaleY) * lt;
  st.Opacity := s0.Opacity + (s1.Opacity - s0.Opacity) * lt;
  if (s0.BackgroundColor <> st.BackgroundColor) or (s1.BackgroundColor <> st.BackgroundColor) then
    st.BackgroundColor := LerpColor(s0.BackgroundColor, s1.BackgroundColor, lt);
  if (s0.Color <> st.Color) or (s1.Color <> st.Color) then
    st.Color := LerpColor(s0.Color, s1.Color, lt);
  AnimMarkActive;
end;

function IsModalDialogBox(Box: TLayoutBox): Boolean;
begin
  Result := (Box <> nil) and (Box.Tag <> nil) and
    SameText(Box.Tag.TagName, 'dialog') and
    Box.Tag.HasAttribute('open') and Box.Tag.HasAttribute('_modal');
end;

function FindModalDialog(Box: TLayoutBox): TLayoutBox;
var c: TLayoutBox;
begin
  Result := nil;
  if Box = nil then Exit;
  if IsModalDialogBox(Box) then Exit(Box);
  for c in Box.Children do
  begin
    Result := FindModalDialog(c);
    if Result <> nil then Exit;
  end;
end;
// PaintModalOverlay is defined after PaintBox/ShiftBoxTree (below).

{ UA fallback chrome for controls the stylesheet didn't style; also the
  focus ring. Shared by MakeControl and RefreshStyles. }
procedure ApplyControlChrome(var St: TComputedStyle; Kind: TControlKind;
  Focused: Boolean; Primary: Boolean = False; Disabled: Boolean = False);
begin
  case Kind of
    ckTextInput, ckTextarea, ckSelect, ckDate:
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
  if Focused and (Kind in [ckTextInput, ckTextarea, ckSelect, ckDate]) then
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

{ The text a closed <select> shows: the option whose value (or text) matches the
  select's 'value', else the first option. Options may be nested in <optgroup>. }
function SelectedOptionText(Sel: THTMLTag): string;
var firstTxt, selTxt, vv, t: string; hasV: Boolean;

  procedure Consider(opt: THTMLTag);
  begin
    t := InnerText(opt);
    if firstTxt = '' then firstTxt := t;
    if hasV and ((opt.GetAttribute('value') = vv) or (t = vv)) then selTxt := t;
  end;

var c, gc: THTMLTag;
begin
  firstTxt := ''; selTxt := '';
  hasV := Sel.HasAttribute('value'); vv := Sel.GetAttribute('value');
  for c in Sel.Children do
    if SameText(c.TagName, 'option') then Consider(c)
    else if SameText(c.TagName, 'optgroup') then
      for gc in c.Children do
        if SameText(gc.TagName, 'option') then Consider(gc);
  if selTxt <> '' then Result := selTxt else Result := firstTxt;
end;

{ Build a layout box for a form control. Runs are stored relative to the
  box origin (FlushLine shifts them to absolute, same as inline-blocks). }
function TLayoutEngine.MakeControl(Tag: THTMLTag; St: TComputedStyle; AvailW: Single): TLayoutBox;
var
  kind: TControlKind;
  txt, ph, val: string;
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
        // show the option matching 'value', else the first option's text;
        // options may be nested inside <optgroup>
        txt := SelectedOptionText(Tag);
      end;
    ckTextarea:
      txt := Tag.GetAttribute('value', InnerText(Tag));
    ckDate:
      begin
        // a native-quality date field: 📅 + the value formatted per `format`
        // (default "dd MMM yyyy"), or the placeholder. The calendar overlay
        // edits the ISO `value`.
        val := Trim(Tag.GetAttribute('value'));
        if val <> '' then
          txt := #$F0#$9F#$93#$85' ' +
            FormatDateDisplay(val, Tag.GetAttribute('format', 'dd MMM yyyy'))
        else
          txt := #$F0#$9F#$93#$85' ' + Tag.GetAttribute('placeholder', 'Select date');
      end;
    ckProgress, ckMeter:
      begin
        // a horizontal bar; painted from value/max in PaintBoxEx
        ew := ResolveSize(St.ExplicitWidth, AvailW);
        if ew >= 0 then Result.W := ew else Result.W := Min(160, AvailW);
        Result.H := ResolveSize(St.ExplicitHeight, 0);
        if Result.H < 0 then Result.H := 12;
        Exit;
      end;
    ckRange:
      begin
        // a slider track + thumb; painted from value/min/max in PaintBoxEx
        ew := ResolveSize(St.ExplicitWidth, AvailW);
        if ew >= 0 then Result.W := ew else Result.W := Min(180, AvailW);
        Result.H := Max(20, lineH);
        Exit;
      end;
    ckColor:
      begin
        // a colour swatch showing the value
        ew := ResolveSize(St.ExplicitWidth, AvailW);
        if ew >= 0 then Result.W := ew else Result.W := 48;
        Result.H := ResolveSize(St.ExplicitHeight, 0);
        if Result.H < 0 then Result.H := Max(24, lineH);
        Exit;
      end;
  else // ckTextInput
    txt := Tag.GetAttribute('value');
    if (LowerCase(Tag.GetAttribute('type')) = 'password') and (txt <> '') then
    begin
      seg := '';
      for i := 1 to Length(txt) do seg := seg + #$E2#$80#$A2;  // • per byte (ASCII pw)
      txt := seg;
    end;
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
  else if (kind = ckButton) or (kind = ckDate) or St.AppearanceNone then
    Result.W := FCanvas.MeasureText(txt, St.FontSize, FontStylesOf(St)).Width + padH + 8
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
      run.FontWeight := St.FontWeight; run.ShadowColor := 0; run.ShadowDX := 0; run.ShadowDY := 0;
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
        run.FontWeight := St.FontWeight; run.ShadowColor := 0; run.ShadowDX := 0; run.ShadowDY := 0;
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
    run.FontWeight := St.FontWeight; run.ShadowColor := 0; run.ShadowDX := 0; run.ShadowDY := 0;
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
  // <lottie>/<canvas> are painted by the core; their children are data/fallback
  // (e.g. the inline Lottie JSON), never laid out as visible text.
  if SameText(Tag.TagName, 'lottie') or SameText(Tag.TagName, 'canvas') then
    usedH := 0
  else
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
  dir, jc, ai, ia: string;
  sumMain, freeMain, curr, gap, crossOff, usedFixed, sumGrow, targetW: Single;
  lineW, lineH, lineFree, lx, lgap, lineY, totalH, flexGap: Single;
  baseW, growF, shrinkF: array of Single;
  overflowMain, scaledShrink: Single;   // flex-shrink distribution (row, single-line)
  crossFixed: array of Boolean;   // item has an explicit cross-axis size (skip stretch)
  sb: TStringBuilder;
  m: TTina4TextMetrics;
  i, k, lineEnd, oi, nlines, li: Integer;
  fw, ac: string;
  fcTag: THTMLTag;
  lineStartA, lineEndA: array of Integer;
  lineHA: array of Single;
  crossAvail, freeCross, startY, lineGap: Single;
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
    // `order`: stable insertion-sort by the item's order (default 0)
    for i := 1 to itemTags.Count - 1 do
    begin
      fcTag := itemTags[i];
      oi := TComputedStyle.ForTag(fcTag, st, FSheet).CSSOrder;
      k := i;
      while (k > 0) and
            (TComputedStyle.ForTag(itemTags[k - 1], st, FSheet).CSSOrder > oi) do
      begin itemTags[k] := itemTags[k - 1]; Dec(k); end;
      itemTags[k] := fcTag;
    end;
    // flex-direction: *-reverse places items in reverse main-axis order
    if (dir = 'row-reverse') or (dir = 'column-reverse') then
      for i := 0 to itemTags.Count div 2 - 1 do
      begin
        fcTag := itemTags[i];
        itemTags[i] := itemTags[itemTags.Count - 1 - i];
        itemTags[itemTags.Count - 1 - i] := fcTag;
      end;
    // per-axis gap: the main-axis gap is column-gap for a row, row-gap for a column
    if isCol then flexGap := st.RowGap else flexGap := st.ColGap;
    if flexGap < 0 then flexGap := 0;

    SetLength(crossFixed, itemTags.Count);
    if isCol then
    begin
      for i := 0 to itemTags.Count - 1 do
      begin
        cs := TComputedStyle.ForTag(itemTags[i], st, FSheet);
        // column cross axis = horizontal → an explicit width opts out of stretch
        crossFixed[i] := ResolveSize(cs.ExplicitWidth, contentW) >= 0;
        cb := MakeReplacedBox(itemTags[i], cs, contentW);
        if (cb = nil) and IsFormControlTag(itemTags[i].TagName) then
          cb := MakeControl(itemTags[i], cs, contentW);
        if cb = nil then cb := MakeInlineContainer(itemTags[i], cs, contentW);
        box.Children.Add(cb); items.Add(cb);
      end;
    end
    else
    begin
      // row: base widths + grow/shrink factors
      SetLength(baseW, itemTags.Count);
      SetLength(growF, itemTags.Count);
      SetLength(shrinkF, itemTags.Count);
      usedFixed := 0; sumGrow := 0;
      for i := 0 to itemTags.Count - 1 do
      begin
        cs := TComputedStyle.ForTag(itemTags[i], st, FSheet);
        // row cross axis = vertical → an explicit height opts out of stretch
        crossFixed[i] := ResolveSize(cs.ExplicitHeight, 0) >= 0;
        growF[i] := cs.FlexGrow;
        shrinkF[i] := cs.FlexShrink;
        ew := ResolveSize(cs.ExplicitWidth, contentW);
        // checkbox/radio have a fixed intrinsic size — CSS width doesn't grow
        // them, so don't let it reserve flex space either
        if ControlKindOf(itemTags[i]) in [ckCheckbox, ckRadio] then
        begin
          baseW[i] := 18; growF[i] := 0; shrinkF[i] := 0;
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
      // flex-shrink: when items overflow a non-wrapping row, shrink each by
      // its (flex-shrink × base) share of the overflow (CSS weighted shrink).
      overflowMain := 0; scaledShrink := 0;
      if (freeMain < 0) and
         not ((LowerCase(st.FlexWrap) = 'wrap') or (LowerCase(st.FlexWrap) = 'wrap-reverse')) then
      begin
        overflowMain := -freeMain;
        for i := 0 to itemTags.Count - 1 do
          scaledShrink := scaledShrink + shrinkF[i] * baseW[i];
      end;
      if freeMain < 0 then freeMain := 0;
      for i := 0 to itemTags.Count - 1 do
      begin
        cs := TComputedStyle.ForTag(itemTags[i], st, FSheet);
        targetW := baseW[i];
        // grow only when NOT wrapping (wrapped items keep their base size)
        if (growF[i] > 0) and (sumGrow > 0) and
           not ((LowerCase(st.FlexWrap) = 'wrap') or (LowerCase(st.FlexWrap) = 'wrap-reverse')) then
          targetW := targetW + freeMain * growF[i] / sumGrow
        else if (overflowMain > 0) and (scaledShrink > 0) and (shrinkF[i] > 0) then
        begin
          targetW := baseW[i] - overflowMain * (shrinkF[i] * baseW[i]) / scaledShrink;
          if targetW < 0 then targetW := 0;
        end;
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

    // flex-wrap (row): pack items into lines (pass 1), then stack them on the
    // cross axis honouring align-content + wrap-reverse (pass 2).
    fw := LowerCase(st.FlexWrap);
    if (not isCol) and ((fw = 'wrap') or (fw = 'wrap-reverse')) then
    begin
      // pass 1: line boundaries + heights
      SetLength(lineStartA, 0); SetLength(lineEndA, 0); SetLength(lineHA, 0);
      i := 0; totalH := 0;
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
        nlines := Length(lineHA);
        SetLength(lineStartA, nlines + 1); SetLength(lineEndA, nlines + 1); SetLength(lineHA, nlines + 1);
        lineStartA[nlines] := i; lineEndA[nlines] := lineEnd; lineHA[nlines] := lineH;
        totalH := totalH + lineH;
        i := lineEnd;
      end;
      nlines := Length(lineHA);
      totalH := totalH + flexGap * Max(0, nlines - 1);
      // available cross size (grow to fit content) + align-content distribution
      crossAvail := contentH; if crossAvail < totalH then crossAvail := totalH;
      freeCross := crossAvail - totalH;
      ac := LowerCase(st.AlignContent); if ac = '' then ac := 'stretch';
      startY := contentY; lineGap := flexGap;
      if freeCross > 0 then
      begin
        if ac = 'center' then startY := startY + freeCross / 2
        else if (ac = 'flex-end') or (ac = 'end') then startY := startY + freeCross
        else if (ac = 'space-between') and (nlines > 1) then lineGap := flexGap + freeCross / (nlines - 1)
        else if (ac = 'space-around') and (nlines > 0) then
        begin startY := startY + freeCross / (nlines * 2); lineGap := flexGap + freeCross / nlines; end;
      end;
      // pass 2: place each line (wrap-reverse flips the cross stacking order)
      lineY := startY;
      for li := 0 to nlines - 1 do
      begin
        if fw = 'wrap-reverse' then
        begin
          // this line sits mirrored within [startY, startY+totalH]
          crossOff := startY;
          for k := 0 to nlines - 1 do
            if k > li then crossOff := crossOff + lineHA[k] + lineGap;
        end
        else crossOff := lineY;
        lineFree := contentW; for k := lineStartA[li] to lineEndA[li] - 1 do lineFree := lineFree - items[k].W;
        lineFree := lineFree - flexGap * Max(0, (lineEndA[li] - lineStartA[li]) - 1);
        if lineFree < 0 then lineFree := 0;
        lx := 0; lgap := 0;
        if jc = 'center' then lx := lineFree / 2
        else if (jc = 'flex-end') or (jc = 'end') then lx := lineFree
        else if (jc = 'space-between') and (lineEndA[li] - lineStartA[li] > 1) then lgap := lineFree / (lineEndA[li] - lineStartA[li] - 1)
        else if (jc = 'space-around') and (lineEndA[li] - lineStartA[li] > 0) then
        begin lx := lineFree / ((lineEndA[li] - lineStartA[li]) * 2); lgap := lineFree / (lineEndA[li] - lineStartA[li]); end;
        for k := lineStartA[li] to lineEndA[li] - 1 do
        begin
          cb := items[k];
          if (ai = 'stretch') and not crossFixed[k] and (cb.H < lineHA[li]) then cb.H := lineHA[li];
          if ai = 'center' then ShiftBoxTree(cb, contentX + lx, crossOff + (lineHA[li] - cb.H) / 2)
          else if (ai = 'flex-end') or (ai = 'end') then ShiftBoxTree(cb, contentX + lx, crossOff + lineHA[li] - cb.H)
          else ShiftBoxTree(cb, contentX + lx, crossOff);
          lx := lx + cb.W + lgap + flexGap;
        end;
        lineY := lineY + lineHA[li] + lineGap;
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
      // align-self overrides the container's align-items for this item
      ia := LowerCase(cb.Style.AlignSelf);
      if (ia = '') or (ia = 'auto') then ia := ai;
      if isCol then
      begin
        // cross axis = horizontal
        if (ia = 'stretch') and not crossFixed[i] and (cb.W < contentW) then
          cb.W := contentW;                       // stretch: fill the cross axis
        if (ia = 'center') then crossOff := (contentW - cb.W) / 2
        else if (ia = 'flex-end') or (ia = 'end') then crossOff := contentW - cb.W
        else crossOff := 0;
        ShiftBoxTree(cb, contentX + crossOff, contentY + curr);
        curr := curr + cb.H + gap + flexGap;
      end
      else
      begin
        // cross axis = vertical
        if (ia = 'stretch') and not crossFixed[i] and (cb.H < contentH) then
          cb.H := contentH;                       // stretch: equal-height items
        if (ia = 'center') then crossOff := (contentH - cb.H) / 2
        else if (ia = 'flex-end') or (ia = 'end') then crossOff := contentH - cb.H
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

{ Expand repeat(n, tracklist) in a grid-template track spec into the flat list. }
function ExpandGridRepeat(const Spec: string): string;
var
  p, depth, comma, close, n, j: Integer;
  head, inner, cntStr, listStr, tail: string;
begin
  Result := Spec;
  p := Pos('repeat(', LowerCase(Result));
  while p > 0 do
  begin
    head := Copy(Result, 1, p - 1);
    // find the matching ')'
    depth := 0; close := 0; comma := 0;
    for j := p + 6 to Length(Result) do   // p+6 is the '(' of repeat(
    begin
      if Result[j] = '(' then Inc(depth)
      else if Result[j] = ')' then
      begin Dec(depth); if depth = 0 then begin close := j; Break; end; end
      else if (Result[j] = ',') and (depth = 1) and (comma = 0) then comma := j;
    end;
    if (close = 0) or (comma = 0) then Break;   // malformed — leave as-is
    cntStr := Trim(Copy(Result, p + 7, comma - (p + 7)));
    listStr := Trim(Copy(Result, comma + 1, close - comma - 1));
    tail := Copy(Result, close + 1, MaxInt);
    n := StrToIntDef(cntStr, 1);
    inner := '';
    for j := 1 to n do inner := inner + ' ' + listStr;
    Result := head + inner + ' ' + tail;
    p := Pos('repeat(', LowerCase(Result));
  end;
end;

{ CSS Grid (subset): grid-template-columns (px/%/fr/auto/repeat), row/column
  gaps, row-major auto-placement, grid-column/grid-row: span N. Rows are auto
  (sized to the tallest item). Items stretch to fill their cell. }
function TLayoutEngine.LayoutGrid(Parent: TLayoutBox; Tag: THTMLTag;
  const ParentStyle: TComputedStyle; X, Y, AvailW: Single): Single;
var
  st, cs: TComputedStyle;
  box, cb: TLayoutBox;
  c: THTMLTag;
  itemTags: TList<THTMLTag>;
  mL, mR, mT, mB, availInner, ew, eh: Single;
  edgeL, edgeT, edgeR, edgeB, contentX, contentY, contentW, contentH: Single;
  rowGap, colGap, frUnit, fixedSum, frSum, cellW, cellH, colXk, rowYr, defH: Single;
  trackW, trackFr, colX, rowH, rowFr: array of Single;
  trackFixed: array of Boolean;
  rowIsFr: array of Boolean;
  ncols, nrows, i, curRow, curCol, span, k, spanRows: Integer;
  colStart, rowStart, rowSpan, autoRow, autoCol: Integer;
  toks: TStringArray;
  tk: string;
  iRow, iCol, iSpan, iRowSpan: array of Integer;
  occ: array of array of Boolean;   // cell occupancy for auto-placement
  areaGrid: array of TStringArray;  // grid-template-areas name per cell
  areaR0, areaC0, areaRS, areaCS: Integer;

  procedure ParseColumns(const Spec: string);
  var s: string; t: string; v: Single;
  begin
    ncols := 0;
    SetLength(trackFixed, 0); SetLength(trackW, 0); SetLength(trackFr, 0);
    s := Trim(ExpandGridRepeat(Spec));
    if s = '' then Exit;
    while Pos('  ', s) > 0 do s := StringReplace(s, '  ', ' ', [rfReplaceAll]);
    toks := s.Split([' ']);
    for t in toks do
    begin
      if Trim(t) = '' then Continue;
      SetLength(trackFixed, ncols + 1); SetLength(trackW, ncols + 1); SetLength(trackFr, ncols + 1);
      if t.EndsWith('fr') then
      begin
        trackFixed[ncols] := False;
        trackFr[ncols] := StrToFloatDef(Copy(t, 1, Length(t) - 2), 1);
        trackW[ncols] := 0;
      end
      else if t = 'auto' then
      begin // treat auto as a flexible 1fr track (content-sizing not modelled)
        trackFixed[ncols] := False; trackFr[ncols] := 1; trackW[ncols] := 0;
      end
      else if t.EndsWith('%') then
      begin
        v := StrToFloatDef(Copy(t, 1, Length(t) - 1), 0);
        trackFixed[ncols] := True; trackW[ncols] := contentW * v / 100; trackFr[ncols] := 0;
      end
      else
      begin
        trackFixed[ncols] := True;
        trackW[ncols] := StrToFloatDef(StringReplace(t, 'px', '', [rfReplaceAll, rfIgnoreCase]), 0);
        trackFr[ncols] := 0;
      end;
      Inc(ncols);
    end;
  end;

  function SpanOf(const Val: string): Integer;
  var pS: Integer; nStr: string;
  begin
    Result := 1;
    pS := Pos('span', LowerCase(Val));
    if pS > 0 then
    begin
      nStr := Trim(Copy(Val, pS + 4, MaxInt));
      Result := Max(1, StrToIntDef(Trim(nStr), 1));
    end;
  end;

  { grid-column / grid-row: parse an explicit start line (1-based, -1 = auto) and
    a span. Handles "N", "N / M", "N / span S", "span S". }
  procedure GridPlacement(const Val: string; out StartLine, Span: Integer);
  var v, a, b: string; sp: Integer;
  begin
    StartLine := -1; Span := 1;
    v := Trim(LowerCase(Val));
    if v = '' then Exit;
    sp := Pos('/', v);
    if sp > 0 then
    begin
      a := Trim(Copy(v, 1, sp - 1)); b := Trim(Copy(v, sp + 1, MaxInt));
      if a.StartsWith('span') then Span := Max(1, StrToIntDef(Trim(Copy(a, 5, MaxInt)), 1))
      else StartLine := StrToIntDef(a, -1);
      if b.StartsWith('span') then Span := Max(1, StrToIntDef(Trim(Copy(b, 5, MaxInt)), 1))
      else if (StartLine >= 1) and (StrToIntDef(b, -999) <> -999) then
        Span := Max(1, StrToIntDef(b, StartLine + 1) - StartLine);
    end
    else if v.StartsWith('span') then Span := Max(1, StrToIntDef(Trim(Copy(v, 5, MaxInt)), 1))
    else StartLine := StrToIntDef(v, -1);
  end;

  { Parse grid-template-areas ("a a b" "a a c") into a name-per-cell grid. }
  procedure ParseAreas(const Spec: string);
  var quoted: TStringArray; row: string; rr: Integer;
  begin
    SetLength(areaGrid, 0);
    if Trim(Spec) = '' then Exit;
    quoted := StringReplace(Spec, '''', '"', [rfReplaceAll]).Split(['"']);
    // odd-indexed segments are the quoted row strings
    rr := 1;
    while rr <= High(quoted) do
    begin
      row := Trim(quoted[rr]);
      if row <> '' then
      begin
        SetLength(areaGrid, Length(areaGrid) + 1);
        areaGrid[High(areaGrid)] := row.Split([' '], TStringSplitOptions.ExcludeEmpty);
      end;
      Inc(rr, 2);
    end;
  end;

  { Bounding cell rect of a named area (out row/col start + spans). False if unknown. }
  function AreaRect(const Name: string; out R0, C0, RS, CS: Integer): Boolean;
  var rr, cc, r1, c1: Integer;
  begin
    Result := False; R0 := 999; C0 := 999; r1 := -1; c1 := -1;
    for rr := 0 to High(areaGrid) do
      for cc := 0 to High(areaGrid[rr]) do
        if areaGrid[rr][cc] = Name then
        begin
          Result := True;
          if rr < R0 then R0 := rr; if rr > r1 then r1 := rr;
          if cc < C0 then C0 := cc; if cc > c1 then c1 := cc;
        end;
    if Result then begin RS := r1 - R0 + 1; CS := c1 - C0 + 1; end;
  end;

  procedure EnsureRows(r: Integer);
  var old: Integer;
  begin
    old := Length(occ);
    if r >= old then
    begin
      SetLength(occ, r + 1);
      while old <= r do begin SetLength(occ[old], ncols); Inc(old); end;
    end;
  end;

  function CellsFree(r, c, sp, rs: Integer): Boolean;
  var rr, cc: Integer;
  begin
    Result := (c >= 0) and (c + sp <= ncols);
    if not Result then Exit;
    for rr := r to r + rs - 1 do
    begin
      if rr >= Length(occ) then Continue;   // unallocated rows are free
      for cc := c to c + sp - 1 do
        if occ[rr][cc] then Exit(False);
    end;
  end;

  procedure MarkCells(r, c, sp, rs: Integer);
  var rr, cc: Integer;
  begin
    for rr := r to r + rs - 1 do
    begin
      EnsureRows(rr);
      for cc := c to Min(c + sp - 1, ncols - 1) do occ[rr][cc] := True;
    end;
  end;

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

  colGap := st.ColGap; if colGap < 0 then colGap := 0;
  rowGap := st.RowGap; if rowGap < 0 then rowGap := 0;

  ParseColumns(st.GridTemplateColumns);
  ParseAreas(st.GridTemplateAreas);
  if ncols = 0 then
  begin
    ncols := 1; SetLength(trackFixed, 1); SetLength(trackW, 1); SetLength(trackFr, 1);
    trackFixed[0] := False; trackFr[0] := 1; trackW[0] := 0;
  end;

  // resolve fr tracks against the free space after fixed tracks + column gaps
  fixedSum := 0; frSum := 0;
  for k := 0 to ncols - 1 do
    if trackFixed[k] then fixedSum := fixedSum + trackW[k] else frSum := frSum + trackFr[k];
  frUnit := 0;
  if frSum > 0 then
    frUnit := Max(0, (contentW - fixedSum - colGap * (ncols - 1))) / frSum;
  for k := 0 to ncols - 1 do
    if not trackFixed[k] then trackW[k] := trackFr[k] * frUnit;

  // column X positions
  SetLength(colX, ncols);
  colXk := contentX;
  for k := 0 to ncols - 1 do
  begin colX[k] := colXk; colXk := colXk + trackW[k] + colGap; end;

  // collect grid items
  itemTags := TList<THTMLTag>.Create;
  try
    for c in Tag.Children do
    begin
      if IsTextNode(c) then Continue;
      cs := TComputedStyle.ForTag(c, st, FSheet);
      if LowerCase(cs.Display) = 'none' then Continue;
      itemTags.Add(c);
    end;

    SetLength(iRow, itemTags.Count); SetLength(iCol, itemTags.Count);
    SetLength(iSpan, itemTags.Count); SetLength(iRowSpan, itemTags.Count);
    SetLength(rowH, 0);
    autoRow := 0; autoCol := 0; nrows := 0; SetLength(occ, 0);

    for i := 0 to itemTags.Count - 1 do
    begin
      cs := TComputedStyle.ForTag(itemTags[i], st, FSheet);
      // grid-area naming a template area places the item at that area's rect
      if (cs.GridArea <> '') and (Length(areaGrid) > 0)
         and AreaRect(cs.GridArea, areaR0, areaC0, areaRS, areaCS) then
      begin
        colStart := areaC0 + 1; span := areaCS; rowStart := areaR0 + 1; rowSpan := areaRS;
      end
      else
      begin
        GridPlacement(cs.GridColumn, colStart, span);
        GridPlacement(cs.GridRow, rowStart, rowSpan);
      end;
      span := Max(1, Min(span, ncols)); rowSpan := Max(1, rowSpan);
      // resolve the item's cell, skipping cells already taken (auto-placement)
      if (colStart >= 1) and (rowStart >= 1) then
      begin curCol := Min(colStart - 1, ncols - 1); curRow := rowStart - 1; end
      else if colStart >= 1 then
      begin
        curCol := Min(colStart - 1, ncols - span); if curCol < 0 then curCol := 0;
        curRow := 0; while not CellsFree(curRow, curCol, span, rowSpan) do Inc(curRow);
      end
      else if rowStart >= 1 then
      begin
        curRow := rowStart - 1; curCol := 0;
        while (curCol + span <= ncols) and not CellsFree(curRow, curCol, span, rowSpan) do Inc(curCol);
        if curCol + span > ncols then curCol := 0;
      end
      else
      begin
        // fully auto: scan forward from the cursor for the first free run
        curRow := autoRow; curCol := autoCol;
        while True do
        begin
          if curCol + span > ncols then begin curCol := 0; Inc(curRow); Continue; end;
          if CellsFree(curRow, curCol, span, rowSpan) then Break;
          Inc(curCol);
        end;
        autoRow := curRow; autoCol := curCol + span;
        if autoCol >= ncols then begin autoCol := 0; Inc(autoRow); end;
      end;
      MarkCells(curRow, curCol, span, rowSpan);
      // cell width across the spanned columns (+ the gaps they swallow)
      cellW := colGap * (span - 1);
      for k := curCol to Min(curCol + span - 1, ncols - 1) do cellW := cellW + trackW[k];

      cs.ExplicitWidth := cellW; cs.BoxSizing := 'border-box';
      cb := MakeReplacedBox(itemTags[i], cs, cellW);
      if (cb = nil) and IsFormControlTag(itemTags[i].TagName) then
        cb := MakeControl(itemTags[i], cs, cellW)
      else if cb = nil then
        cb := MakeInlineContainer(itemTags[i], cs, cellW);
      box.Children.Add(cb);

      iRow[i] := curRow; iCol[i] := curCol; iSpan[i] := span; iRowSpan[i] := rowSpan;
      if curRow + rowSpan > nrows then
      begin
        k := nrows; nrows := curRow + rowSpan; SetLength(rowH, nrows);
        while k < nrows do begin rowH[k] := 0; Inc(k); end;
      end;
      // single-row items size their row; a row-spanning item's height is spread
      if (rowSpan <= 1) and (cb.H > rowH[curRow]) then rowH[curRow] := cb.H
      else if rowSpan > 1 then
        for k := curRow to curRow + rowSpan - 1 do
          if cb.H / rowSpan > rowH[k] then rowH[k] := cb.H / rowSpan;
    end;

    // grid-template-rows: px / % / fr / auto row-track heights override auto size.
    // fr and % resolve against the container's definite inner height; with an
    // indefinite height they fall back to the content (auto) size — matching Chrome.
    eh := ResolveSize(st.ExplicitHeight, 0);
    if Trim(st.GridTemplateRows) <> '' then
    begin
      toks := Trim(st.GridTemplateRows).ToLower.Split([' '], TStringSplitOptions.ExcludeEmpty);
      // definite inner height available to distribute across % / fr rows, else -1
      if eh >= 0 then
      begin
        if SameText(st.BoxSizing, 'border-box') then defH := eh - edgeT - edgeB
        else defH := eh;
      end
      else defH := -1;
      SetLength(rowIsFr, nrows); SetLength(rowFr, nrows);
      frSum := 0; fixedSum := 0;
      for k := 0 to nrows - 1 do begin rowIsFr[k] := False; rowFr[k] := 0; end;
      for k := 0 to Min(High(toks), nrows - 1) do
      begin
        tk := Trim(toks[k]);
        if tk.EndsWith('px') then
          rowH[k] := StrToFloatDef(Copy(tk, 1, Length(tk) - 2), rowH[k])
        else if tk.EndsWith('fr') then
        begin
          if defH >= 0 then
          begin
            rowIsFr[k] := True;
            rowFr[k] := StrToFloatDef(Copy(tk, 1, Length(tk) - 2), 1);
            frSum := frSum + rowFr[k];
          end; // indefinite height: leave rowH[k] as content size
        end
        else if tk.EndsWith('%') then
        begin
          if defH >= 0 then
            rowH[k] := defH * StrToFloatDef(Copy(tk, 1, Length(tk) - 1), 0) / 100;
        end;
        // 'auto' (and indefinite fr) keep the content-derived rowH[k]
      end;
      // distribute the leftover definite height across fr tracks
      if (defH >= 0) and (frSum > 0) then
      begin
        for k := 0 to nrows - 1 do
          if not rowIsFr[k] then fixedSum := fixedSum + rowH[k];
        frUnit := (defH - fixedSum - rowGap * Max(0, nrows - 1)) / frSum;
        if frUnit < 0 then frUnit := 0;
        for k := 0 to nrows - 1 do
          if rowIsFr[k] then rowH[k] := frUnit * rowFr[k];
      end;
    end;

    // place items: cell origin + stretch to the row height
    contentH := 0;
    for k := 0 to nrows - 1 do contentH := contentH + rowH[k];
    contentH := contentH + rowGap * Max(0, nrows - 1);
    if eh >= 0 then
    begin
      if SameText(st.BoxSizing, 'border-box') then contentH := Max(contentH, eh - edgeT - edgeB)
      else contentH := Max(contentH, eh);
    end;

    for i := 0 to itemTags.Count - 1 do
    begin
      cb := box.Children[i];
      rowYr := contentY;
      for k := 0 to iRow[i] - 1 do rowYr := rowYr + rowH[k] + rowGap;
      // stretch to the cell: one row, or the sum of spanned rows (+ inner gaps)
      cellH := rowGap * (iRowSpan[i] - 1);
      for k := iRow[i] to Min(iRow[i] + iRowSpan[i] - 1, nrows - 1) do cellH := cellH + rowH[k];
      if cb.H < cellH then cb.H := cellH;
      ShiftBoxTree(cb, colX[iCol[i]] - cb.X, rowYr - cb.Y);
    end;

    box.H := contentH + edgeT + edgeB;
    Result := box.H + mT + mB;
  finally
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
    FontFamily: string;
    FontWeight: Integer;
    ShadowDX, ShadowDY: Single; ShadowColor: TTina4Color;
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
  firstInlineLine: Boolean; // text-indent applies to the first formatted line only
  FloatBase: Integer;      // index in FFloats where this container's floats begin
  MaxFloatY: Single;       // lowest float bottom, so the container can enclose them

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

  { The available x-span for content across a vertical range, after left floats
    push the left edge right and right floats pull the right edge left. Consults
    the whole active float context (this container's floats AND its ancestors',
    all in absolute coords), clamped to this container's content box. }
  procedure LineBounds(YTop, YBot: Single; out LX0, LX1: Single);
  var k: Integer;
  begin
    LX0 := CX; LX1 := CX + CW;
    for k := 0 to High(FFloats) do
      if (FFloats[k].Y1 > YTop) and (FFloats[k].Y0 < YBot) then   // vertically overlaps
      begin
        if (FFloats[k].Side = 0) and (FFloats[k].X1 > LX0) and (FFloats[k].X0 < LX1) then
          LX0 := FFloats[k].X1;
        if (FFloats[k].Side = 1) and (FFloats[k].X0 < LX1) and (FFloats[k].X1 > LX0) then
          LX1 := FFloats[k].X0;
      end;
    if LX1 < LX0 then LX1 := LX0;
  end;

  { `clear`: the y at/below FromY where no float of the cleared side remains
    (this container's own floats only — clearance is per formatting context). }
  function ClearBelowFloats(const Mode: string; FromY: Single): Single;
  var k: Integer;
  begin
    Result := FromY;
    for k := FloatBase to High(FFloats) do
      if (Mode = 'both') or ((Mode = 'left') and (FFloats[k].Side = 0))
         or ((Mode = 'right') and (FFloats[k].Side = 1)) then
        if FFloats[k].Y1 > Result then Result := FFloats[k].Y1;
  end;

  { Position an already-laid-out float box at the left/right edge (accounting for
    its margins), dropping it below earlier floats when it doesn't fit, and record
    its band. FB is a border box already added to Box.Children. }
  procedure PlaceFloat(FB: TLayoutBox; Side: Integer; MT, MR, MB, ML: Single);
  var atY, lx0, lx1, fx, fw, fh, nextDrop: Single; band: TFloatBand; n, k, guard: Integer;
  begin
    fw := FB.W + ML + MR;                 // margin box
    fh := FB.H + MT + MB;
    atY := y;                             // float starts at the current flow y
    guard := 0;
    repeat
      LineBounds(atY, atY + fh, lx0, lx1);
      if (lx1 - lx0 + 0.5 >= fw) or (guard > 500) then Break;
      // no room here — drop to the nearest float bottom below atY and retry
      nextDrop := atY;
      for k := 0 to High(FFloats) do
        if (FFloats[k].Y1 > atY) and ((nextDrop = atY) or (FFloats[k].Y1 < nextDrop)) then
          nextDrop := FFloats[k].Y1;
      if nextDrop <= atY then Break;
      atY := nextDrop; Inc(guard);
    until False;
    if Side = 0 then fx := lx0 else fx := lx1 - fw;
    ShiftBoxTree(FB, (fx + ML) - FB.X, (atY + MT) - FB.Y);   // content box inside its margin box
    band.Side := Side; band.X0 := fx; band.X1 := fx + fw; band.Y0 := atY; band.Y1 := atY + fh;
    n := Length(FFloats); SetLength(FFloats, n + 1); FFloats[n] := band;
    if band.Y1 > MaxFloatY then MaxFloatY := band.Y1;
  end;

  procedure AddQuoteWord(const Q: string; const St: TComputedStyle; SpaceBefore: Boolean);
  var
    qi: TInlineItem;
    qm: TTina4TextMetrics;
  begin
    FCanvas.FontFamily := St.FontFamily;
    qm := FCanvas.MeasureText(Q, St.FontSize, FontStylesOf(St));
    FCanvas.FontFamily := '';
    qi.Text := Q; qi.Box := nil; qi.W := qm.Width; qi.H := LineHeightOf(St);
    qi.Ascent := (qi.H - (qm.Ascent + qm.Descent)) / 2 + qm.Ascent;
    qi.FontSize := St.FontSize; qi.Styles := FontStylesOf(St); qi.Color := St.Color;
    qi.LetterSpacing := St.LetterSpacing; qi.FontFamily := St.FontFamily; qi.FontWeight := St.FontWeight; qi.ShadowDX := St.TextShadowOffsetX; qi.ShadowDY := St.TextShadowOffsetY; if St.TextShadowActive then qi.ShadowColor := St.TextShadowColor else qi.ShadowColor := 0;
    qi.SpaceBefore := SpaceBefore and (items.Count > 0); qi.LineBreak := False;
    items.Add(qi);
  end;

  { Add one text token (a word, or a run of literal spaces for preformatted
    text) as an inline item, measured in St's font with the shared-baseline
    placement the normal word path uses. }
  procedure AddTextItem(const W: string; const St: TComputedStyle; SpaceBefore: Boolean);
  var ti: TInlineItem; tm: TTina4TextMetrics; vaShift: Single;
  begin
    FCanvas.LetterSpacing := St.LetterSpacing;
    FCanvas.FontFamily := St.FontFamily;
    FCanvas.FontWeight := St.FontWeight;
    tm := FCanvas.MeasureText(W, St.FontSize, FontStylesOf(St));
    FCanvas.LetterSpacing := 0;
    FCanvas.FontFamily := '';
    FCanvas.FontWeight := 0;
    ti.Text := W; ti.Box := nil; ti.W := tm.Width; ti.H := LineHeightOf(St);
    ti.Ascent := (ti.H - (tm.Ascent + tm.Descent)) / 2 + tm.Ascent;
    ti.FontAscent := tm.Ascent;
    if SameText(St.VerticalAlign, 'sub') then
    begin ti.Ascent := ti.Ascent - St.FontSize * 0.28; ti.FontAscent := ti.FontAscent - St.FontSize * 0.28; end
    else if SameText(St.VerticalAlign, 'super') then
    begin ti.Ascent := ti.Ascent + St.FontSize * 0.42; ti.FontAscent := ti.FontAscent + St.FontSize * 0.42; end
    else if VAlignLength(St.VerticalAlign, St.FontSize, vaShift) then
    begin ti.Ascent := ti.Ascent + vaShift; ti.FontAscent := ti.FontAscent + vaShift; end;
    ti.FontSize := St.FontSize; ti.Styles := FontStylesOf(St); ti.Color := St.Color;
    ti.LetterSpacing := St.LetterSpacing; ti.FontFamily := St.FontFamily; ti.FontWeight := St.FontWeight; ti.ShadowDX := St.TextShadowOffsetX; ti.ShadowDY := St.TextShadowOffsetY; if St.TextShadowActive then ti.ShadowColor := St.TextShadowColor else ti.ShadowColor := 0;
    ti.SpaceBefore := SpaceBefore and (items.Count > 0);
    ti.LineBreak := False;
    items.Add(ti);
  end;

  { Break an over-long word (a URL/hash with no spaces) into character-sized
    pieces that each fit AvailW, for overflow-wrap:break-word / word-break:
    break-all. UTF-8 aware so multibyte glyphs are not split mid-sequence. }
  procedure EmitBrokenWord(const W: string; const St: TComputedStyle;
    SpaceBefore: Boolean; AvailW: Single);
  var
    piece, ch: string;
    p, chLen: Integer;
    sp: Boolean;
  begin
    piece := ''; p := 1; sp := SpaceBefore;
    FCanvas.FontFamily := St.FontFamily; FCanvas.LetterSpacing := St.LetterSpacing;
    while p <= Length(W) do
    begin
      case Ord(W[p]) of
        $00..$7F: chLen := 1;
        $C0..$DF: chLen := 2;
        $E0..$EF: chLen := 3;
      else chLen := 4;
      end;
      ch := Copy(W, p, chLen);
      if (piece <> '') and
         (FCanvas.MeasureText(piece + ch, St.FontSize, FontStylesOf(St)).Width > AvailW) then
      begin
        FCanvas.FontFamily := ''; FCanvas.LetterSpacing := 0;
        AddTextItem(piece, St, sp);
        FCanvas.FontFamily := St.FontFamily; FCanvas.LetterSpacing := St.LetterSpacing;
        sp := False; piece := '';
      end;
      piece := piece + ch;
      p := p + chLen;
    end;
    FCanvas.FontFamily := ''; FCanvas.LetterSpacing := 0;
    if piece <> '' then AddTextItem(piece, St, sp);
  end;

  { Emit a hard line break (\n in preformatted text, or <br>). }
  procedure AddHardBreak(const St: TComputedStyle);
  var bi: TInlineItem;
  begin
    bi.Text := ''; bi.Box := nil; bi.W := 0; bi.H := LineHeightOf(St);
    bi.Ascent := bi.H; bi.FontAscent := bi.H;
    bi.FontSize := St.FontSize; bi.Styles := []; bi.Color := 0;
    bi.LetterSpacing := 0; bi.FontFamily := '';
    bi.SpaceBefore := False; bi.LineBreak := True;
    items.Add(bi);
  end;

  { white-space: pre / pre-wrap / pre-line. Newlines become hard breaks; pre and
    pre-wrap also preserve runs of spaces (emitted as their own items); pre-line
    collapses spaces. Wrapping is governed by noWrapFlow (off for pre-wrap/
    pre-line, on for pre). }
  procedure GatherPreText(const Raw: string; const St: TComputedStyle; const Mode: string);
  var
    s, seg, tok: string;
    lines: TStringArray;
    li, p: Integer;
    inSpace: Boolean;
  begin
    s := StringReplace(Raw, #13#10, #10, [rfReplaceAll]);
    s := StringReplace(s, #13, #10, [rfReplaceAll]);
    lines := s.Split([#10]);
    for li := 0 to High(lines) do
    begin
      if li > 0 then AddHardBreak(St);
      seg := lines[li];
      if Mode = 'pre-line' then
      begin
        seg := Trim(CollapseWS(seg));
        if seg <> '' then
        begin
          for tok in seg.Split([' ']) do
            if tok <> '' then AddTextItem(tok, St, False);
        end;
        Continue;
      end;
      // pre / pre-wrap: keep space runs as their own tokens
      if seg = '' then Continue;
      p := 1; tok := '';
      inSpace := seg[1] = ' ';
      while p <= Length(seg) do
      begin
        if (seg[p] = ' ') <> inSpace then
        begin
          AddTextItem(tok, St, False);
          tok := ''; inSpace := seg[p] = ' ';
        end;
        tok := tok + seg[p];
        Inc(p);
      end;
      if tok <> '' then AddTextItem(tok, St, False);
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
    disp, txt, qrText, wsMode: string;
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
      wsMode := LowerCase(St.WhiteSpace);
      if (wsMode = 'pre') or (wsMode = 'pre-wrap') or (wsMode = 'pre-line') then
      begin
        txt := T.Text;
        if (St.TextTransform <> '') and not SameText(St.TextTransform, 'none') then
          txt := ApplyTextTransform(txt, St.TextTransform);
        GatherPreText(txt, St, wsMode);
        Exit;
      end;
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
        FCanvas.FontFamily := St.FontFamily;   // measure in the run's font
        FCanvas.FontWeight := St.FontWeight;
        for i := 0 to words.Count - 1 do
        begin
          if words[i] = '' then Continue;
          m := FCanvas.MeasureText(words[i], St.FontSize, FontStylesOf(St));
          // overflow-wrap / word-break: a single word wider than the line is
          // broken between characters instead of overflowing the box.
          if (m.Width > CW) and (CW > 0) and
             (SameText(St.OverflowWrap, 'break-word') or SameText(St.OverflowWrap, 'anywhere') or
              SameText(St.WordBreak, 'break-all') or SameText(St.WordBreak, 'break-word')) then
          begin
            EmitBrokenWord(words[i], St, (items.Count > 0) and ((i > 0) or leadingSpace), CW);
            FCanvas.LetterSpacing := St.LetterSpacing;   // restore loop measure context
            FCanvas.FontFamily := St.FontFamily;
            Continue;
          end;
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
          it.FontFamily := St.FontFamily;
          it.FontWeight := St.FontWeight;
          it.ShadowDX := St.TextShadowOffsetX; it.ShadowDY := St.TextShadowOffsetY; if St.TextShadowActive then it.ShadowColor := St.TextShadowColor else it.ShadowColor := 0;
          it.SpaceBefore := (items.Count > 0) and ((i > 0) or leadingSpace);
          items.Add(it);
        end;
        FCanvas.LetterSpacing := 0;
        FCanvas.FontFamily := '';
        FCanvas.FontWeight := 0;
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
      // checkbox/radio: centre the glyph on the adjacent text's midline instead
      // of sitting its box-bottom on the baseline (which rides ~6px high).
      if it.Box.ControlKind in [ckCheckbox, ckRadio] then
        it.Ascent := it.Box.H / 2 + cs.FontSize * 0.32
      else
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
    lineTop, lineH: Single; justify: Boolean = False);
  var
    idx, k: Integer;
    lineW, xShift, x, maxAscent, gapExtra, flx0, flx1, availW: Single;
    gaps: Integer;
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
        lineW := lineW + FCanvas.MeasureText(' ', it.FontSize, it.Styles).Width + ParentStyle.WordSpacing;
      lineW := lineW + it.W;
    end;
    // float-aware line box: narrow the available span by any floats overlapping
    // this line's vertical range (left floats push x0 right, right floats x1 left)
    LineBounds(lineTop, lineTop + lineH, flx0, flx1);
    availW := flx1 - flx0;
    case ParentStyle.TextAlign of
      TTextAlign.Center:   xShift := Max(0, (availW - lineW) / 2);
      TTextAlign.Trailing: xShift := Max(0, availW - lineW);
    else
      xShift := 0;
    end;
    // text-align: justify — spread the slack across the line's word gaps (each
    // SpaceBefore boundary). Only non-final wrapped lines are justified; the
    // last line of a block and lines ending in <br> stay left-aligned.
    gapExtra := 0;
    if justify then
    begin
      gaps := 0;
      for k := 1 to lineItems.Count - 1 do
        if items[lineItems[k]].SpaceBefore then Inc(gaps);
      if (gaps > 0) and (availW > lineW) then gapExtra := (availW - lineW) / gaps;
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
    x := flx0 + xShift;
    // text-indent: shift the first formatted line of the block
    if firstInlineLine and (ParentStyle.TextIndent <> 0) and
       (ParentStyle.TextAlign = TTextAlign.Leading) then
      x := x + ParentStyle.TextIndent;
    firstInlineLine := False;
    for k := 0 to lineItems.Count - 1 do
    begin
      it := items[lineItems[k]];
      if it.SpaceBefore and (k > 0) then
        x := x + FCanvas.MeasureText(' ', it.FontSize, it.Styles).Width + gapExtra + ParentStyle.WordSpacing;
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
        run.FontFamily := it.FontFamily;
        run.FontWeight := it.FontWeight;
        run.ShadowDX := it.ShadowDX; run.ShadowDY := it.ShadowDY; run.ShadowColor := it.ShadowColor;
        Box.Runs.Add(run);
      end;
      x := x + it.W;
    end;
    lineItems.Clear;
  end;

  procedure FlowInlineItems;
  var
    i, carrySpacer, spIdx: Integer;
    it: TInlineItem;
    curW, lineH, spaceW, lineW, flw0, flw1: Single;
    lineItems: TList<Integer>;
  begin
    if items.Count = 0 then Exit;
    lineItems := TList<Integer>.Create;
    try
      curW := 0; lineH := 0;
      for i := 0 to items.Count - 1 do
      begin
        it := items[i];
        if it.LineBreak then
        begin // <br> or a preformatted \n: hard break even in nowrap/pre
          FlushLine(i, lineItems, y, Max(lineH, it.H));
          y := y + Max(lineH, it.H);
          curW := 0; lineH := 0;
          Continue;
        end;
        spaceW := 0;
        if it.SpaceBefore and (lineItems.Count > 0) then
          spaceW := FCanvas.MeasureText(' ', it.FontSize, it.Styles).Width + ParentStyle.WordSpacing;
        // float-aware usable width: floats overlapping this line's y-range narrow
        // it (so text wraps beside a floated box).
        LineBounds(y, y + Max(lineH, it.H), flw0, flw1);
        lineW := flw1 - flw0;
        // text-indent narrows the FIRST line's usable width by the indent, so
        // the shifted first line wraps early instead of overflowing the margin.
        if firstInlineLine and (ParentStyle.TextIndent <> 0) and
           (ParentStyle.TextAlign = TTextAlign.Leading) then
          lineW := lineW - ParentStyle.TextIndent;
        if (not noWrapFlow) and (lineItems.Count > 0) and (curW + spaceW + it.W > lineW) then
        begin
          // A trailing margin-left spacer (synthetic: no box, no text, zero
          // height, positive width) belongs to THIS wrapping item — carry it to
          // the new line so the item keeps its left margin instead of hugging
          // the line start.
          carrySpacer := -1;
          if lineItems.Count > 0 then
          begin
            spIdx := lineItems[lineItems.Count - 1];
            if (items[spIdx].Box = nil) and (items[spIdx].Text = '') and
               (items[spIdx].W > 0) and (items[spIdx].H = 0) and
               not items[spIdx].LineBreak then
              carrySpacer := spIdx;
          end;
          if carrySpacer >= 0 then lineItems.Delete(lineItems.Count - 1);
          FlushLine(i, lineItems, y, lineH, ParentStyle.TextJustify);
          y := y + lineH;
          curW := 0; lineH := 0;
          spaceW := 0;
          if carrySpacer >= 0 then
          begin
            lineItems.Add(carrySpacer);
            curW := curW + items[carrySpacer].W;
          end;
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
  prevMB, mTc, absX, absY, absCH, fMT, fMR, fMB, fML: Single;
  hadInline: Boolean;
  absBox, fltBox: TLayoutBox;
  savedFloats: array of TFloatBand;
begin
  y := CY;
  prevMB := 0;
  hadInline := False;
  pendingSpace := False;
  firstInlineLine := True;
  FloatBase := Length(FFloats); MaxFloatY := CY;   // this container's floats append here
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
        // Shrink-to-fit: an out-of-flow box with no explicit width sizes to its
        // content (CSS "shrink-to-fit"), not the full container — e.g. a pill
        // pinned with `right` only should hug its text, not span the row.
        if (ResolveSize(cs.ExplicitWidth, CW) < 0) and (absBox.NaturalW > 0) then
        begin
          absCH := absBox.NaturalW + cs.Padding.Horz + cs.BorderWidths.Horz;
          if absCH < absBox.W then absBox.W := absCH;
        end;
        // fixed is viewport-relative (origin 0,0); absolute is container-relative.
        // Paint (PaintBoxEx) drops the scroll offset for fixed so it stays put.
        if SameText(cs.CSSPosition, 'fixed') then
        begin
          absX := 0; absY := 0;
          if cs.CSSLeft > -9998 then absX := cs.CSSLeft
          else if cs.CSSRight > -9998 then absX := CX + CW - absBox.W - cs.CSSRight;
          if cs.CSSTop > -9998 then absY := cs.CSSTop;
          ShiftBoxTree(absBox, absX - absBox.X, absY - absBox.Y);
          Continue;
        end;
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
      // float: left/right — taken out of normal vertical flow and pinned to the
      // container edge at the current y; following in-flow content wraps beside
      // it (FlushLine/FlowInlineItems consult the float bands). Takes no flow
      // height; the container encloses it via MaxFloatY.
      if not SameText(cs.CSSFloat, 'none') then
      begin
        fMT := cs.Margin.Top;    if fMT < 0 then fMT := 0;
        fMR := cs.Margin.Right;  if fMR < 0 then fMR := 0;
        fMB := cs.Margin.Bottom; if fMB < 0 then fMB := 0;
        fML := cs.Margin.Left;   if fML < 0 then fML := 0;
        // a float establishes its own BFC: its content must not wrap around the
        // ancestor/sibling floats, so lay it out with an empty float context and
        // restore the context afterwards to position it.
        savedFloats := Copy(FFloats, 0, Length(FFloats));
        SetLength(FFloats, 0);
        if SameText(c.TagName, 'img') or SameText(c.TagName, 'svg')
           or SameText(c.TagName, 'qrcode') then
        begin
          fltBox := MakeReplacedBox(c, cs, CW);
          if fltBox <> nil then Box.Children.Add(fltBox);
        end
        else if ResolveSize(cs.ExplicitWidth, CW) < 0 then
        begin
          // auto width → shrink-to-fit: measure max-content, then re-lay-out at it
          LayoutBlock(Box, c, ParentStyle, CX, y, 100000);
          fltBox := Box.Children[Box.Children.Count - 1];
          absCH := Min(fltBox.NaturalW + cs.Padding.Horz + cs.BorderWidths.Horz
                       + fML + fMR, CW);
          Box.Children.Delete(Box.Children.Count - 1);   // discard the wide pass (frees it)
          LayoutBlock(Box, c, ParentStyle, CX, y, absCH);
          fltBox := Box.Children[Box.Children.Count - 1];
        end
        else
        begin
          LayoutBlock(Box, c, ParentStyle, CX, y, CW);
          fltBox := Box.Children[Box.Children.Count - 1];
        end;
        FFloats := savedFloats;   // restore the context for positioning
        if fltBox <> nil then
          if SameText(cs.CSSFloat, 'right') then PlaceFloat(fltBox, 1, fMT, fMR, fMB, fML)
          else PlaceFloat(fltBox, 0, fMT, fMR, fMB, fML);
        Continue;  // out of normal flow — no y advance
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
        // clear: drop this block below the floats of the cleared side(s) first
        if not SameText(cs.CSSClear, 'none') then
        begin
          y := ClearBelowFloats(cs.CSSClear, y);
          prevMB := 0;   // clearance cancels margin collapse across it
        end;
        // collapse adjacent vertical margins: gap = max(prevBottom, thisTop)
        mTc := cs.Margin.Top; if mTc = -1 then mTc := 0;
        if (prevMB > 0) and (mTc > 0) then
          y := y - Min(prevMB, mTc);
        if (disp = 'flex') or (disp = 'inline-flex') then
          y := y + LayoutFlex(Box, c, ParentStyle, CX, y, CW)
        else if (disp = 'grid') or (disp = 'inline-grid') then
          y := y + LayoutGrid(Box, c, ParentStyle, CX, y, CW)
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
  // the container encloses its own floats (clearfix-style) so a tall float isn't
  // clipped, then drops them from the active context (they don't escape this BFC)
  if MaxFloatY > y then y := MaxFloatY;
  SetLength(FFloats, FloatBase);
  UsedH := y - CY;
end;

function TLayoutEngine.LayoutBlock(Parent: TLayoutBox; Tag: THTMLTag;
  const ParentStyle: TComputedStyle; X, Y, AvailW: Single): Single;
var
  st: TComputedStyle;
  box: TLayoutBox;
  contentX, contentY, contentW, usedH: Single;
  edgeL, edgeT, edgeR, edgeB: Single;
  mL, mR, mT, mB, ew, eh, availInner, naturalH, mnw, mxw, mnh, mxh, relDX, relDY: Single;
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
     (SameText(Tag.Parent.TagName, 'ul') or SameText(Tag.Parent.TagName, 'ol') or
      SameText(Tag.Parent.TagName, 'menu')) then
  begin
    liIdx := 0;
    for liSib in Tag.Parent.Children do
    begin
      if SameText(liSib.TagName, 'li') then Inc(liIdx);
      if liSib = Tag then Break;
    end;
    box.MarkerText := MarkerFor(
      TComputedStyle.ForTag(Tag.Parent, ParentStyle, FSheet).ListStyleType, liIdx);
    // list-style-image: url(...) — an image marker replaces the text bullet.
    if st.ListStyleImage <> '' then
    begin
      box.MarkerImage := FCanvas.LoadImage(st.ListStyleImage);
      if box.MarkerImage >= 0 then box.MarkerText := '';   // image wins over the bullet glyph
    end;
    // list-style-position: inside — the marker joins the content flow: reserve
    // room for it at the content start (drawn there instead of outdented).
    if st.ListStyleInside and (box.MarkerText <> '') then
      st.Padding.Left := st.Padding.Left +
        FCanvas.MeasureText(box.MarkerText + ' ', st.FontSize, []).Width;
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
  // aspect-ratio: with a known width and auto height, derive the height from the
  // ratio (the common `width + aspect-ratio` media-box case). Content taller than
  // this is handled by overflow, as in browsers.
  if (st.AspectRatio > 0) and (ResolveSize(st.ExplicitHeight, 0) < 0) and (box.W > 0) then
    box.H := box.W / st.AspectRatio;
  // min-height / max-height clamp (border-box; px resolved, % against 0)
  mnh := ResolveSize(st.MinHeight, 0);
  mxh := ResolveSize(st.MaxHeight, 0);
  if (mxh >= 0) and (box.H > mxh) then box.H := mxh;
  if (mnh >= 0) and (box.H < mnh) then box.H := mnh;

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
  footRows: TList<THTMLTag>;
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
  rowspan, ri, lastRow, nspan: Integer;
  blocked: array of Integer;              // per-column: rows still covered by a rowspan above
  colAuto: array of Boolean;              // table-layout:fixed — column has no specified width
  ecc: THTMLTag;                          // empty-cells scan
  emptyCell: Boolean;
  rowTop, rowHeight: array of Single;     // geometry of each laid-out row
  spanBox: array of TLayoutBox;           // deferred rowspan cells (height set after all rows)
  spanStart, spanRows: array of Integer;
  spanNatH: array of Single;
  spanVA: array of string;
  spanH: Single;
  capTag: THTMLTag;
  capBox: TLayoutBox;
  capCs: TComputedStyle;
  capH, capUsed: Single;
  capBottom: Boolean;
  colW: array of Single;                  // explicit per-column width from <col>/<colgroup>
  colIdx: Integer;
  hsp, vsp: Single;                       // border-spacing (separate model), 0 if collapse

  // Collect <tr> in visual order: thead/tbody/loose rows first, <tfoot> rows
  // last regardless of where the tfoot sits in source (per CSS table model).
  procedure CollectRows(T: THTMLTag; IntoFoot: Boolean);
  var c: THTMLTag;
  begin
    for c in T.Children do
      if SameText(c.TagName, 'tr') then
      begin
        if IntoFoot then footRows.Add(c) else rows.Add(c);
      end
      else if SameText(c.TagName, 'tfoot') then CollectRows(c, True)
      else if SameText(c.TagName, 'thead') or SameText(c.TagName, 'tbody') then
        CollectRows(c, IntoFoot);
  end;

  // Apply one <col>/<colgroup> element's width across the columns it spans.
  procedure OneCol(colTag: THTMLTag);
  var s2, j: Integer; ww: Single; ccs: TComputedStyle;
  begin
    s2 := Max(1, StrToIntDef(colTag.GetAttribute('span', '1'), 1));
    if colTag.HasAttribute('width') then
      ww := TComputedStyle.ParseLength(colTag.GetAttribute('width'), 16)
    else
    begin
      ccs := TComputedStyle.ForTag(colTag, Style, FSheet);
      ww := ResolveSize(ccs.ExplicitWidth, tblAvail);
    end;
    for j := 1 to s2 do
    begin
      if colIdx >= ncols then Break;
      if ww >= 0 then colW[colIdx] := ww;
      Inc(colIdx);
    end;
  end;

  // Walk <col> and <colgroup> children in document order, seeding colW[].
  procedure SeedCols;
  var cg, cc: THTMLTag; hasChild: Boolean; k: Integer;
  begin
    SetLength(colW, ncols);
    for k := 0 to ncols - 1 do colW[k] := -1;
    colIdx := 0;
    for cg in Tag.Children do
      if SameText(cg.TagName, 'col') then OneCol(cg)
      else if SameText(cg.TagName, 'colgroup') then
      begin
        hasChild := False;
        for cc in cg.Children do
          if SameText(cc.TagName, 'col') then begin hasChild := True; OneCol(cc); end;
        if not hasChild then OneCol(cg);   // a bare <colgroup span=.. width=..>
      end;
  end;

begin
  rows := TList<THTMLTag>.Create;
  footRows := TList<THTMLTag>.Create;
  try
    CollectRows(Tag, False);
    for r in footRows do rows.Add(r);   // tfoot rows always at the bottom
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
    SeedCols;   // <col>/<colgroup> explicit widths

    // preferred column widths: an explicit cell width is exact; otherwise
    // content plus padding (+ a little slop for content-sized cells).
    SetLength(prefW, ncols);
    for i := 0 to ncols - 1 do prefW[i] := 0;
    SetLength(blocked, ncols);
    for i := 0 to ncols - 1 do blocked[i] := 0;
    for r in rows do
    begin
      ci := 0;
      for cell in r.Children do
      begin
        if not (SameText(cell.TagName, 'td') or SameText(cell.TagName, 'th')) then Continue;
        // step past columns still covered by a rowspanning cell from a row above
        while (ci < ncols) and (blocked[ci] > 0) do Inc(ci);
        if ci >= ncols then Break;
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
        rowspan := Max(1, StrToIntDef(cell.GetAttribute('rowspan', '1'), 1));
        for i := ci to Min(ci + colspan - 1, ncols - 1) do
        begin
          prefW[i] := Max(prefW[i], cw / colspan);
          if rowspan > 1 then blocked[i] := rowspan;   // reserve these columns downward
        end;
        Inc(ci, colspan);
      end;
      for i := 0 to ncols - 1 do
        if blocked[i] > 0 then Dec(blocked[i]);
    end;
    // a <col> width is authoritative for its column (at least as wide as content)
    for i := 0 to ncols - 1 do
      if colW[i] >= 0 then prefW[i] := Max(prefW[i], colW[i]);
    // border-spacing (separate model only): gaps around and between cells
    if Style.BorderCollapse then begin hsp := 0; vsp := 0; end
    else begin hsp := Style.BorderSpacing; vsp := Style.BorderSpacing; end;
    total := 0;
    for i := 0 to ncols - 1 do total := total + prefW[i];
    if total <= 0 then total := 1;

    if SameText(Style.TableLayout, 'fixed') then
    begin
      // table-layout:fixed — column widths come ONLY from the first row's
      // specified widths and <col> widths; later rows never widen a column, and
      // content is ignored. Auto columns split the leftover table width equally.
      if explW >= 0 then tableW := explW
      else tableW := Min(total + (ncols + 1) * hsp, tblAvail); // auto width: content total
      SetLength(colAuto, ncols);
      for i := 0 to ncols - 1 do begin prefW[i] := 0; colAuto[i] := True; end;
      ci := 0;
      for cell in rows[0].Children do
      begin
        if not (SameText(cell.TagName, 'td') or SameText(cell.TagName, 'th')) then Continue;
        if ci >= ncols then Break;
        cs := TComputedStyle.ForTag(cell, Style, FSheet);
        cw := ResolveSize(cs.ExplicitWidth, tblAvail);
        if cell.HasAttribute('width') then
          cw := TComputedStyle.ParseLength(cell.GetAttribute('width'), cs.FontSize);
        colspan := Max(1, StrToIntDef(cell.GetAttribute('colspan', '1'), 1));
        if cw >= 0 then
        begin
          cw := cw + cs.Padding.Horz + cs.BorderWidths.Horz;   // content-box + edges
          for i := ci to Min(ci + colspan - 1, ncols - 1) do
          begin prefW[i] := cw / colspan; colAuto[i] := False; end;
        end;
        Inc(ci, colspan);
      end;
      for i := 0 to ncols - 1 do
        if colW[i] >= 0 then begin prefW[i] := colW[i]; colAuto[i] := False; end;
      total := 0; nspan := 0;   // reuse nspan as the auto-column count
      for i := 0 to ncols - 1 do
        if colAuto[i] then Inc(nspan) else total := total + prefW[i];
      if nspan > 0 then
      begin
        for i := 0 to ncols - 1 do
          if colAuto[i] then prefW[i] := Max(0, (tableW - (ncols + 1) * hsp - total) / nspan);
      end
      else if total > 0 then
      begin // no auto columns — scale specified widths to fill the table width
        scale := Max(0, tableW - (ncols + 1) * hsp) / total;
        for i := 0 to ncols - 1 do prefW[i] := prefW[i] * scale;
      end;
    end
    else
    begin
      // auto layout: table sizes to content; an explicit width scales columns to
      // fit. The (ncols+1) spacing gaps sit outside the column widths.
      if explW >= 0 then tableW := explW
      else tableW := Min(total + (ncols + 1) * hsp, tblAvail);
      scale := Max(0, tableW - (ncols + 1) * hsp) / total;
      for i := 0 to ncols - 1 do prefW[i] := prefW[i] * scale;
    end;

    tbox := TLayoutBox.Create;
    tbox.Tag := Tag;
    tbox.Style := Style;
    Parent.Children.Add(tbox);
    tbox.X := X + Style.Margin.Left;
    tbox.Y := Y + Style.Margin.Top;
    tbox.W := tableW;

    // <caption> — a full-table-width block above (default) or below the rows
    capTag := nil;
    capH := 0;
    capBottom := False;
    for cell in Tag.Children do
      if SameText(cell.TagName, 'caption') then begin capTag := cell; Break; end;
    if capTag <> nil then
    begin
      capCs := TComputedStyle.ForTag(capTag, Style, FSheet);
      capBottom := SameText(capCs.CaptionSide, 'bottom');
      capBox := TLayoutBox.Create;
      capBox.Tag := capTag;
      capBox.Style := capCs;
      tbox.Children.Add(capBox);
      capBox.X := tbox.X; capBox.Y := tbox.Y; capBox.W := tableW;
      // laid at the table top for now; a bottom caption is repositioned later
      LayoutChildren(capBox, capTag, capCs,
        tbox.X + capCs.BorderWidths.Left + capCs.Padding.Left,
        tbox.Y + capCs.BorderWidths.Top + capCs.Padding.Top,
        tableW - capCs.Padding.Horz - capCs.BorderWidths.Horz, capUsed);
      capH := capUsed + capCs.Padding.Vert + capCs.BorderWidths.Vert;
      capBox.H := capH;
    end;

    for i := 0 to ncols - 1 do blocked[i] := 0;
    SetLength(rowTop, rows.Count);
    SetLength(rowHeight, rows.Count);
    nspan := 0;
    // a top caption pushes the first row (and everything measured off rowY) down
    if (capTag <> nil) and not capBottom then rowY := tbox.Y + capH + vsp
    else rowY := tbox.Y + vsp;
    for ri := 0 to rows.Count - 1 do
    begin
      r := rows[ri];
      rs := TComputedStyle.ForTag(r, Style, FSheet);
      rbox := TLayoutBox.Create;
      rbox.Tag := r;
      rbox.Style := rs;
      tbox.Children.Add(rbox);
      rbox.X := tbox.X; rbox.Y := rowY; rbox.W := tableW;
      cx := tbox.X + hsp;
      rowH := 0;
      ci := 0;
      for cell in r.Children do
      begin
        if not (SameText(cell.TagName, 'td') or SameText(cell.TagName, 'th')) then Continue;
        // a rowspanning cell from an earlier row owns these columns — walk past them
        while (ci < ncols) and (blocked[ci] > 0) do
        begin cx := cx + prefW[ci] + hsp; Inc(ci); end;
        if ci >= ncols then Break;
        cs := TComputedStyle.ForTag(cell, rs, FSheet);
        if hasBorder and (cs.BorderWidths.Top <= 0) then
        begin
          cs.SetBorderWidth(1);
          cs.SetBorderColor(Style.BorderColor);
        end;
        // empty-cells:hide (separate-borders model only) — a cell with neither
        // text nor an element child paints no border or background.
        if SameText(cs.EmptyCells, 'hide') and not Style.BorderCollapse then
        begin
          emptyCell := True;
          for ecc in cell.Children do
            if ecc.TagName <> '#text' then begin emptyCell := False; Break; end;
          if emptyCell then
          begin
            sb := TStringBuilder.Create;
            try
              CollectInlineText(cell, sb);
              if Trim(CollapseWS(sb.ToString)) <> '' then emptyCell := False;
            finally sb.Free; end;
          end;
          if emptyCell then
          begin
            cs.BackgroundColor := TAlphaColors.Null;   // transparent
            cs.SetBorderWidth(0);
          end;
        end;
        cbox := TLayoutBox.Create;
        cbox.Tag := cell;
        cbox.Style := cs;
        rbox.Children.Add(cbox);
        // colspan: this cell spans the next N columns; its width sums them
        colspan := StrToIntDef(cell.GetAttribute('colspan', '1'), 1);
        if colspan < 1 then colspan := 1;
        rowspan := StrToIntDef(cell.GetAttribute('rowspan', '1'), 1);
        if rowspan < 1 then rowspan := 1;
        spanW := 0;
        for i := ci to Min(ci + colspan - 1, ncols - 1) do spanW := spanW + prefW[i];
        spanW := spanW + (Min(ci + colspan - 1, ncols - 1) - ci) * hsp;  // internal gaps
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
        if rowspan <= 1 then
          rowH := Max(rowH, cbox.H)     // single-row cell contributes to this row's height
        else
        begin
          // multi-row cell: reserve its columns downward and resolve height once
          // every spanned row is laid out (below); it must not inflate its start row
          for i := ci to Min(ci + colspan - 1, ncols - 1) do blocked[i] := rowspan;
          if nspan = Length(spanBox) then
          begin
            SetLength(spanBox, nspan + 8); SetLength(spanStart, nspan + 8);
            SetLength(spanRows, nspan + 8); SetLength(spanNatH, nspan + 8);
            SetLength(spanVA, nspan + 8);
          end;
          spanBox[nspan] := cbox; spanStart[nspan] := ri; spanRows[nspan] := rowspan;
          spanNatH[nspan] := cbox.H; spanVA[nspan] := LowerCase(cs.VerticalAlign);
          Inc(nspan);
        end;
        cx := cx + spanW + hsp;
        Inc(ci, colspan);
      end;
      // uniform row height + vertical-align — single-row cells only; rowspan
      // cells get their height after every row is placed (see below)
      for i := 0 to rbox.Children.Count - 1 do
      begin
        cbox := rbox.Children[i];
        if StrToIntDef(cbox.Tag.GetAttribute('rowspan', '1'), 1) > 1 then Continue;
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
      rowTop[ri] := rowY;
      rowHeight[ri] := rowH;
      rowY := rowY + rowH + vsp;
      for i := 0 to ncols - 1 do
        if blocked[i] > 0 then Dec(blocked[i]);
    end;
    // resolve rowspan cell heights: span from their start row to the bottom of
    // the last row they cover, then vertical-align the content within that span
    for i := 0 to nspan - 1 do
    begin
      lastRow := Min(spanStart[i] + spanRows[i] - 1, rows.Count - 1);
      spanH := (rowTop[lastRow] + rowHeight[lastRow]) - rowTop[spanStart[i]];
      cbox := spanBox[i];
      if spanH > cbox.NaturalH then
      begin
        if spanVA[i] = 'middle' then vaShift := (spanH - cbox.NaturalH) / 2
        else if spanVA[i] = 'bottom' then vaShift := spanH - cbox.NaturalH
        else vaShift := 0;
        if vaShift > 0 then
        begin
          ShiftBoxTree(cbox, 0, vaShift);
          cbox.Y := cbox.Y - vaShift;
        end;
      end;
      cbox.H := Max(cbox.H, spanH);
    end;
    // a bottom caption sits just under the last row
    if (capTag <> nil) and capBottom then
    begin
      ShiftBoxTree(capBox, 0, rowY - capBox.Y);
      rowY := rowY + capH;
    end;
    tbox.H := rowY - tbox.Y;
    Result := tbox.H + Style.Margin.Vert;
  finally
    rows.Free;
    footRows.Free;
  end;
end;

function TLayoutEngine.Build(Root: THTMLTag; ViewportW: Single; ViewportH: Single = 0): TLayoutBox;
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
  SetLength(FFloats, 0);   // fresh float context per layout
  if ViewportH <= 0 then ViewportH := ViewportW * 0.66;   // rough default when unknown
  SetCalcContext(ViewportW, ViewportH);   // vw/vh + reset deferred calc() table
  GAnimSheet := FSheet;                    // @keyframes lookup for paint-time animation
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

procedure PaintModalOverlay(Canvas: TTina4Canvas; Root: TLayoutBox; W, H: Single);
var d: TLayoutBox; cx, cy, dx, dy: Single;
begin
  d := FindModalDialog(Root);
  if d = nil then Exit;
  Canvas.FillRect(0, 0, W, H, $66000000);       // dimmed backdrop over the page
  // Centre the dialog subtree at its viewport-centred spot. The shift is by the
  // delta from where it is now, so re-painting the already-centred box is a
  // no-op — and leaving it centred means hit-testing lands on it too (the box
  // is skipped in the normal pass, so it only exists here).
  cx := (W - d.W) / 2; if cx < 0 then cx := 0;
  cy := (H - d.H) / 2; if cy < 0 then cy := 0;
  dx := cx - d.X; dy := cy - d.Y;
  if (dx <> 0) or (dy <> 0) then ShiftBoxTree(d, dx, dy);
  GInModalPaint := True;
  try
    PaintBox(Canvas, d, 0);                       // OffsetY 0 → viewport-fixed, centred
  finally
    GInModalPaint := False;
  end;
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

{ Parse a #rgb / #rrggbb hex colour to an opaque TTina4Color (for <input color>). }
function ParseHexColor(const S: string): TTina4Color;
var h: string; v: Int64; e: Integer;
begin
  Result := $FF000000;
  h := Trim(S);
  if (h <> '') and (h[1] = '#') then Delete(h, 1, 1);
  if Length(h) = 3 then h := h[1]+h[1]+h[2]+h[2]+h[3]+h[3];
  if Length(h) >= 6 then
  begin
    Val('$' + Copy(h, 1, 6), v, e);
    if e = 0 then Result := TTina4Color($FF000000 or Cardinal(v));
  end;
end;

{ The control accent colour: CSS `accent-color` if set, else the theme indigo. }
function AccentOf(Box: TLayoutBox): TTina4Color;
begin
  if Box.Style.AccentColor <> 0 then Result := Box.Style.AccentColor
  else Result := TC_ACCENT;
end;

{ <progress>/<meter>: a rounded track with a filled portion from value/max. }
procedure PaintBarControl(Canvas: TTina4Canvas; Box: TLayoutBox; y: Single);
var val, mx, frac, r: Single; fill: TTina4Color;
begin
  val := StrToFloatDef(Box.Tag.GetAttribute('value'), 0);
  mx := StrToFloatDef(Box.Tag.GetAttribute('max'), 1);
  if mx <= 0 then mx := 1;
  frac := val / mx;
  if frac < 0 then frac := 0; if frac > 1 then frac := 1;
  r := Box.H / 2;
  Canvas.FillRoundRect(Box.X, y, Box.W, Box.H, r, TC_BORDER);          // track
  if Box.ControlKind = ckMeter then fill := $FF33AA55 else fill := AccentOf(Box);
  if frac > 0 then
    Canvas.FillRoundRect(Box.X, y, Max(Box.H, Box.W * frac), Box.H, r, fill);
end;

{ <input type=range>: a thin track, a filled left portion, and a round thumb. }
procedure PaintRangeControl(Canvas: TTina4Canvas; Box: TLayoutBox; y: Single);
var mn, mx, val, frac, ty, cx, cy: Single;
begin
  mn := StrToFloatDef(Box.Tag.GetAttribute('min'), 0);
  mx := StrToFloatDef(Box.Tag.GetAttribute('max'), 100);
  if mx <= mn then mx := mn + 1;
  val := StrToFloatDef(Box.Tag.GetAttribute('value'), (mn + mx) / 2);
  frac := (val - mn) / (mx - mn);
  if frac < 0 then frac := 0; if frac > 1 then frac := 1;
  ty := y + Box.H / 2 - 2;
  Canvas.FillRoundRect(Box.X, ty, Box.W, 4, 2, TC_BORDER);            // track
  if frac > 0 then Canvas.FillRoundRect(Box.X, ty, Box.W * frac, 4, 2, AccentOf(Box));
  cx := Box.X + Box.W * frac; cy := y + Box.H / 2;
  Canvas.FillRoundRect(cx - 8, cy - 8, 16, 16, 8, $FFFFFFFF);          // thumb
  Canvas.StrokeRoundRect(cx - 8, cy - 8, 16, 16, 8, 1.5, AccentOf(Box));
end;

{ Draw one border edge as a rectangle of the given style. `horiz` = the edge
  runs horizontally (top/bottom); its thickness is rh, length rw. For a vertical
  edge (left/right) thickness is rw, length rh. solid fills; double draws two
  parallel lines with a gap; dashed/dotted step segments along the length. }
procedure PaintBorderEdge(Canvas: TTina4Canvas; rx, ry, rw, rh: Single;
  horiz: Boolean; const style: string; color: TTina4Color);
var
  t, seg, gap, pos, len, endp, dash: Single;
begin
  if (rw <= 0) or (rh <= 0) or ((color shr 24) = 0) then Exit;
  if style = 'double' then
  begin
    if horiz then t := rh else t := rw;
    seg := t / 3;
    if seg < 1 then begin Canvas.FillRect(rx, ry, rw, rh, color); Exit; end;
    if horiz then
    begin
      Canvas.FillRect(rx, ry, rw, seg, color);
      Canvas.FillRect(rx, ry + 2 * seg, rw, seg, color);
    end
    else
    begin
      Canvas.FillRect(rx, ry, seg, rh, color);
      Canvas.FillRect(rx + 2 * seg, ry, seg, rh, color);
    end;
    Exit;
  end;
  if (style = 'dashed') or (style = 'dotted') then
  begin
    if horiz then t := rh else t := rw;
    if style = 'dotted' then begin dash := t; gap := t; end
    else begin dash := t * 2.5; gap := t * 1.5; end;
    if dash < 1 then dash := 1;
    if horiz then begin pos := rx; len := rw; endp := rx + rw; end
    else begin pos := ry; len := rh; endp := ry + rh; end;
    while pos < endp do
    begin
      seg := dash; if pos + seg > endp then seg := endp - pos;
      if horiz then Canvas.FillRect(pos, ry, seg, rh, color)
      else Canvas.FillRect(rx, pos, rw, seg, color);
      pos := pos + dash + gap;
    end;
    Exit;
  end;
  Canvas.FillRect(rx, ry, rw, rh, color);   // solid (and any unhandled style)
end;

{ Paint a rectangular box's four border edges, each with its own width and
  colour (per-side borders) in the box's border-style. Fixes the old behaviour
  where only the top edge's width/colour was used for the whole perimeter. }
procedure PaintBorders(Canvas: TTina4Canvas; Box: TLayoutBox;
  const st: TComputedStyle; y, op: Single);
var
  wT, wR, wB, wL: Single;
  style: string;
begin
  wT := st.BorderWidths.Top;    wR := st.BorderWidths.Right;
  wB := st.BorderWidths.Bottom; wL := st.BorderWidths.Left;
  style := LowerCase(st.BorderStyle);
  if style = 'none' then Exit;
  if wT > 0 then PaintBorderEdge(Canvas, Box.X, y, Box.W, wT, True, style,
    ScaleAlpha(st.BorderColors[0], op));
  if wB > 0 then PaintBorderEdge(Canvas, Box.X, y + Box.H - wB, Box.W, wB, True, style,
    ScaleAlpha(st.BorderColors[2], op));
  if wL > 0 then PaintBorderEdge(Canvas, Box.X, y, wL, Box.H, False, style,
    ScaleAlpha(st.BorderColors[3], op));
  if wR > 0 then PaintBorderEdge(Canvas, Box.X + Box.W - wR, y, wR, Box.H, False, style,
    ScaleAlpha(st.BorderColors[1], op));
end;

{ Paint a box's background-image. Handles background-size cover/contain/auto,
  background-position (px or the left/center/right · top/center/bottom
  percentage sentinels), and background-repeat (default tile vs no-repeat).
  The image comes from the canvas's cached/async LoadImage; if it's not ready
  yet (handle < 0) nothing is drawn and the next relayout retries. }
procedure PaintBackgroundImage(Canvas: TTina4Canvas; Box: TLayoutBox;
  const st: TComputedStyle; y: Single);
var
  h: Integer;
  iw, ih, dw, dh, scale, px, py, tileX, tileY: Single;
  sz, rep: string;
  noRepeat: Boolean;
begin
  h := Canvas.LoadImage(st.BackgroundImage);
  if h < 0 then Exit;                          // not decoded yet (async) — retry
  if not Canvas.ImageSize(h, iw, ih) then Exit;
  if (iw <= 0) or (ih <= 0) then Exit;

  sz := LowerCase(Trim(st.BackgroundSize));
  dw := iw; dh := ih;
  if sz = 'cover' then
  begin
    scale := Max(Box.W / iw, Box.H / ih);
    dw := iw * scale; dh := ih * scale;
  end
  else if sz = 'contain' then
  begin
    scale := Min(Box.W / iw, Box.H / ih);
    dw := iw * scale; dh := ih * scale;
  end;

  // position: negative sentinel = percentage (center=-50, right/bottom=-100);
  // >= 0 = px offset from the top-left.
  if st.BgPosX < 0 then px := (Box.W - dw) * (-st.BgPosX) / 100 else px := st.BgPosX;
  if st.BgPosY < 0 then py := (Box.H - dh) * (-st.BgPosY) / 100 else py := st.BgPosY;

  rep := LowerCase(Trim(st.BgRepeat));
  noRepeat := (rep = 'no-repeat') or (sz = 'cover') or (sz = 'contain');

  Canvas.SetClip(Box.X, y, Box.W, Box.H);
  if noRepeat then
    Canvas.DrawImage(h, Box.X + px, y + py, dw, dh)
  else
  begin
    // tile from the positioned origin, back-filling to cover the whole box
    tileY := y + py; while tileY > y do tileY := tileY - dh;
    while tileY < y + Box.H do
    begin
      tileX := Box.X + px; while tileX > Box.X do tileX := tileX - dw;
      while tileX < Box.X + Box.W do
      begin
        Canvas.DrawImage(h, tileX, tileY, dw, dh);
        tileX := tileX + dw;
      end;
      tileY := tileY + dh;
    end;
  end;
  Canvas.ClearClip;
end;

procedure PaintBoxEx(Canvas: TTina4Canvas; Box: TLayoutBox; OffsetY: Single;
  Opacity: Single; Hidden: Boolean);
var
  i: Integer;
  r: TTextRun;
  st: TComputedStyle;
  y, innerOfs, thumbH, thumbY, thumbW, thumbX, cx, cy, gy: Single;
  mkImgSz, filterPad: Single;
  filterLayer, layer3D: Integer;
  useLayer, use3D: Boolean;
  corners3d: array[0..7] of Single;
  sizeTxt, val: string;
  m: TTina4TextMetrics;
  didClip: Boolean;
  op, tx, ty, sx, rcx, rcy, ox: Single;
  shifted, hasRS, ellip, ellipDone, anyZ: Boolean;
  rightEdge, avail: Single;
  drawTxt: string;
  zorder: array of Integer;
  zi, zj, ztmp, gi: Integer;
  gcol: array of TTina4Color;
  gpos: array of Single;
  bg, bd, fg: TTina4Color;
  cv2d: TTina4Canvas2D;
  cvPaint: TCanvasPaintProc;
  lot: TTina4Lottie;
  lotF: Double;
  lotTotal, lotFrame: Single;
begin
  st := Box.Style;
  // CSS transition: ease transform/opacity/colours toward their computed value
  // when it changes (hover/focus/DOM). Per-element state on the tag.
  if st.TransitionDuration > 0 then ApplyTransition(Box, st);
  // CSS animation: interpolate this frame's transform/opacity/colours from the
  // element's @keyframes (drives the ticker while it runs).
  if st.AnimName <> '' then ApplyKeyframeAnim(st);
  // A modal <dialog> is skipped in the normal pass — PaintModalOverlay draws it
  // last, centred over a backdrop (GInModalPaint is set only during that pass).
  if IsModalDialogBox(Box) and not GInModalPaint then Exit;
  // position: fixed — viewport-pinned: ignore the inherited scroll offset for
  // this box and its subtree so it stays put while the page scrolls.
  if SameText(st.CSSPosition, 'fixed') then OffsetY := 0;
  // position: sticky — flows normally until scrolling would carry the box above
  // its `top` line, then it holds there. Modelled by shrinking the effective
  // scroll offset so the box's screen-top pins at `top` (never pulled upward
  // from its natural spot). `top:auto` (unset) never sticks.
  if SameText(st.CSSPosition, 'sticky') and (st.CSSTop > -9990) then
    if (Box.Y - OffsetY) < st.CSSTop then OffsetY := Box.Y - st.CSSTop;
  // transform: translate — shift this box + subtree, unshift after paint
  tx := st.TransformTranslateX;
  ty := st.TransformTranslateY;
  shifted := (tx <> 0) or (ty <> 0);
  if shifted then ShiftBoxTree(Box, tx, ty);
  try
  y := Box.Y - OffsetY;
  // CSS 3D transform: capture the element into an offscreen layer, then map that
  // texture onto its perspective-projected quad (EndLayer3D). Takes precedence
  // over the 2D transform / filter paths for this element.
  use3D := st.Transform3DSet;
  layer3D := -1;
  if use3D then
  begin
    Compute3DCorners(st, Box.X, y, Box.W, Box.H, corners3d);
    layer3D := Canvas.BeginLayer(Box.X, y, Box.W, Box.H, 0);
    if layer3D < 0 then use3D := False;   // no offscreen: fall back to a flat paint
  end;
  // transform: rotate/scale — wrap the subtree paint in a canvas transform
  // about the box centre (default transform-origin)
  hasRS := (not use3D) and ((st.TransformRotate <> 0) or (st.TransformScaleX <> 1) or (st.TransformScaleY <> 1)
    or (st.TransformSkewX <> 0) or (st.TransformSkewY <> 0) or st.TransformMatrixSet
    or (st.ClipPath <> ''));
  if hasRS then
  begin
    // pivot at transform-origin (px or %-marker; default 50% 50% = centre)
    if st.TransformOriginX < -1.5 then rcx := Box.X + Box.W * (-st.TransformOriginX) / 100
    else rcx := Box.X + st.TransformOriginX;
    if st.TransformOriginY < -1.5 then rcy := y + Box.H * (-st.TransformOriginY) / 100
    else rcy := y + st.TransformOriginY;
    Canvas.SaveState;
    Canvas.Translate(rcx, rcy);
    if st.TransformRotate <> 0 then Canvas.Rotate(st.TransformRotate); // +deg = CSS clockwise (flipped canvas)
    if (st.TransformScaleX <> 1) or (st.TransformScaleY <> 1) then
      Canvas.Scale(st.TransformScaleX, st.TransformScaleY);
    if (st.TransformSkewX <> 0) or (st.TransformSkewY <> 0) then
      Canvas.Skew(st.TransformSkewX, st.TransformSkewY);
    if st.TransformMatrixSet then
      Canvas.TransformMatrix(st.TransformMat[0], st.TransformMat[1], st.TransformMat[2],
                             st.TransformMat[3], st.TransformMat[4], st.TransformMat[5]);
    Canvas.Translate(-rcx, -rcy);
    // clip-path: tessellate the shape to a polygon in box coords and clip the
    // subtree to it (border-box reference; radius/mask etc. still TODO)
    if st.ClipPath <> '' then
      Canvas.ClipPolygon(ClipPathPolygon(st.ClipPath, Box.X, y, Box.W, Box.H));
  end;
  // CSS backdrop-filter: filter the pixels already painted behind this box,
  // before the box's own background draws over them. No-op on backends without
  // read-back. Applied to the border-box region.
  if (not Hidden) and (st.BackdropFilter <> '') and (Box.W > 0) and (Box.H > 0) then
    Canvas.BackdropFilter(Box.X, y, Box.W, Box.H, st.BackdropFilter);
  // CSS filter / mix-blend-mode: render this box + subtree into an offscreen
  // layer, then composite it back with the pixel effect. BeginLayer returns -1
  // on backends without offscreen support, so the effect is simply skipped.
  useLayer := (not use3D) and ((st.Filter <> '') or (st.MixBlendMode <> '') or (st.MaskImage <> ''));
  filterLayer := -1;
  if useLayer then
  begin
    filterPad := FilterLayerPad(st.Filter);
    filterLayer := Canvas.BeginLayer(Box.X, y, Box.W, Box.H, filterPad);
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
        Canvas.FillRoundRect(Box.X + 5, gy + 5, 8, 8, 4, AccentOf(Box));
    end
    else
    begin
      if (Box.Tag <> nil) and Box.Tag.HasAttribute('checked') then
        Canvas.FillRoundRect(Box.X, gy, 18, 18, 4, AccentOf(Box))
      else
        Canvas.FillRoundRect(Box.X, gy, 18, 18, 4, $FFFFFFFF);
      Canvas.StrokeRoundRect(Box.X, gy, 18, 18, 4, 1.5, TC_BORDER);
      if (Box.Tag <> nil) and Box.Tag.HasAttribute('checked') then
        Canvas.DrawText(Box.X + 3, gy + 0.5, '✓', 13, [tfsBold], $FFFFFFFF);
    end;
    Exit;
  end;
  // progress / meter: a rounded track with a filled portion from value/max.
  if (Box.ControlKind in [ckProgress, ckMeter]) and (Box.Tag <> nil) then
  begin
    PaintBarControl(Canvas, Box, y);
    Exit;
  end;
  // range: a track with a filled left portion and a round thumb (value/min/max).
  if (Box.ControlKind = ckRange) and (Box.Tag <> nil) then
  begin
    PaintRangeControl(Canvas, Box, y);
    Exit;
  end;
  // color: a rounded swatch of the value colour with a subtle border.
  if (Box.ControlKind = ckColor) and (Box.Tag <> nil) then
  begin
    Canvas.FillRoundRect(Box.X, y, Box.W, Box.H, 6,
      $FF000000 or (ParseHexColor(Box.Tag.GetAttribute('value', '#000000')) and $FFFFFF));
    Canvas.StrokeRoundRect(Box.X, y, Box.W, Box.H, 6, 1, TC_BORDER);
    Exit;
  end;

  // box-shadow (drawn under the box). A blurred (soft) shadow uses the backend
  // blur primitive; a zero-blur shadow is a hard rounded rect. Follows the box's
  // corner radius so a square shadow never peeks past a rounded card.
  if (not Hidden) and st.BoxShadow.Active and not st.BoxShadow.Inset then
    if st.BoxShadow.BlurRadius > 0 then
      Canvas.FillSoftShadow(
        Box.X + st.BoxShadow.OffsetX - st.BoxShadow.SpreadRadius,
        y + st.BoxShadow.OffsetY - st.BoxShadow.SpreadRadius,
        Box.W + 2 * st.BoxShadow.SpreadRadius,
        Box.H + 2 * st.BoxShadow.SpreadRadius,
        st.MaxCornerRadius, st.BoxShadow.BlurRadius,
        ScaleAlpha(st.BoxShadow.Color, op))
    else if st.MaxCornerRadius > 0 then
      Canvas.FillRoundRect(
        Box.X + st.BoxShadow.OffsetX - st.BoxShadow.SpreadRadius,
        y + st.BoxShadow.OffsetY - st.BoxShadow.SpreadRadius,
        Box.W + 2 * st.BoxShadow.SpreadRadius,
        Box.H + 2 * st.BoxShadow.SpreadRadius,
        st.MaxCornerRadius, ScaleAlpha(st.BoxShadow.Color, op))
    else
      Canvas.FillRect(
        Box.X + st.BoxShadow.OffsetX - st.BoxShadow.SpreadRadius,
        y + st.BoxShadow.OffsetY - st.BoxShadow.SpreadRadius,
        Box.W + 2 * st.BoxShadow.SpreadRadius,
        Box.H + 2 * st.BoxShadow.SpreadRadius,
        ScaleAlpha(st.BoxShadow.Color, op));

  bg := ScaleAlpha(st.BackgroundColor, op);
  bd := ScaleAlpha(st.BorderColor, op);
  // real gradient background (linear or radial, multi-stop), when no solid
  // background-color covers it. Stops are opacity-scaled; the backend clips to
  // the corner radius and falls back to a flat fill if it can't gradient.
  if (not Hidden) and ((bg shr 24) = 0) and st.BgGradientActive and (st.GradStopCount >= 2) then
  begin
    SetLength(gcol, st.GradStopCount); SetLength(gpos, st.GradStopCount);
    for gi := 0 to st.GradStopCount - 1 do
    begin
      gcol[gi] := ScaleAlpha(st.GradStopColors[gi], op);
      gpos[gi] := st.GradStopPos[gi];
    end;
    if st.BgGradientRadial then
      Canvas.FillRadialGradient(Box.X, y, Box.W, Box.H, st.MaxCornerRadius, gcol, gpos)
    else
      Canvas.FillLinearGradient(Box.X, y, Box.W, Box.H, st.MaxCornerRadius,
        st.BgGradientAngle, gcol, gpos);
  end
  else if (not Hidden) and ((bg shr 24) > 0) then
  begin
    if st.MaxCornerRadius > 0 then
      Canvas.FillRoundRect(Box.X, y, Box.W, Box.H, st.MaxCornerRadius, bg)
    else
      Canvas.FillRect(Box.X, y, Box.W, Box.H, bg);
  end;
  // background-image: url() — loaded via the cached/async image path, sized by
  // background-size (cover/contain/auto), positioned by background-position,
  // tiled per background-repeat, and clipped to the box.
  if (not Hidden) and (st.BackgroundImage <> '') and (Box.W > 0) and (Box.H > 0) then
    PaintBackgroundImage(Canvas, Box, st, y);
  // <canvas>: hand a Tina4Canvas2D (origin at the box top-left, clipped to it) to
  // the Pascal painter registered for this canvas id — the no-JS canvas.
  if (not Hidden) and (Box.Tag <> nil) and SameText(Box.Tag.TagName, 'canvas') then
  begin
    cvPaint := FindCanvasPainter(Box.Tag.GetAttribute('id'));
    if Assigned(cvPaint) then
    begin
      Canvas.SaveState;
      Canvas.SetClip(Box.X, y, Box.W, Box.H);
      cv2d := TTina4Canvas2D.Create(Canvas, Box.W, Box.H, bg);
      try
        cv2d.Translate(Box.X, y);
        // a buggy painter must never corrupt the page paint (save/clip balance)
        try cvPaint(cv2d); except end;
      finally
        cv2d.Free;
        Canvas.ClearClip;
        Canvas.RestoreState;
      end;
    end;
  end;
  // <lottie>: parse the inline JSON once, render the current frame (time-driven
  // off the shared anim clock), scaled to fill the box. Core-rendered → every
  // shell, and it animates while it's on screen.
  if (not Hidden) and (Box.Tag <> nil) and SameText(Box.Tag.TagName, 'lottie')
     and (Box.W > 0) and (Box.H > 0) then
  begin
    lot := GetLottieFor(Trim(InnerText(Box.Tag)));
    if (lot <> nil) and (lot.Width > 0) and (lot.Height > 0) then
    begin
      lotTotal := lot.OutPoint - lot.InPoint;
      if lotTotal <= 0 then lotTotal := 1;
      lotF := AnimClock * lot.FrameRate;
      lotFrame := lot.InPoint + (lotF - lotTotal * Floor(lotF / lotTotal));
      Canvas.SaveState;
      Canvas.SetClip(Box.X, y, Box.W, Box.H);
      cv2d := TTina4Canvas2D.Create(Canvas, Box.W, Box.H, bg);
      try
        // contain-fit + centre (fills the box at full composition size)
        lotTotal := Min(Box.W / lot.Width, Box.H / lot.Height);
        cv2d.Translate(Box.X + (Box.W - lot.Width * lotTotal) / 2,
                       y + (Box.H - lot.Height * lotTotal) / 2);
        cv2d.Scale(lotTotal, lotTotal);
        try lot.Render(cv2d, lotFrame); except end;
      finally
        cv2d.Free;
        Canvas.ClearClip;
        Canvas.RestoreState;
      end;
      AnimMarkActive;   // keep repainting so it animates
    end;
  end;
  if (not Hidden) and ((st.BorderWidths.Top > 0) or (st.BorderWidths.Right > 0) or
     (st.BorderWidths.Bottom > 0) or (st.BorderWidths.Left > 0)) then
  begin
    if st.MaxCornerRadius > 0 then
      // rounded: uniform stroke (per-side / dashed on a rounded box is out of scope)
      Canvas.StrokeRoundRect(Box.X, y, Box.W, Box.H, st.MaxCornerRadius,
        st.BorderWidths.Top, bd)
    else
      // rectangular: each side with its own width, colour and style
      PaintBorders(Canvas, Box, st, y, op);
  end;
  // outline: a stroke OUTSIDE the border box, offset by outline-offset. Sits in
  // the margin, doesn't affect layout. (dashed/dotted fall back to solid.)
  if (not Hidden) and (st.OutlineWidth > 0)
     and ((st.OutlineColor shr 24) > 0)
     and not SameText(st.OutlineStyle, 'none') then
  begin
    ox := st.OutlineOffset + st.OutlineWidth / 2;
    if st.MaxCornerRadius > 0 then
      Canvas.StrokeRoundRect(Box.X - ox, y - ox, Box.W + 2 * ox, Box.H + 2 * ox,
        st.MaxCornerRadius + ox, st.OutlineWidth, ScaleAlpha(st.OutlineColor, op))
    else
      Canvas.StrokeRect(Box.X - ox, y - ox, Box.W + 2 * ox, Box.H + 2 * ox,
        st.OutlineWidth, ScaleAlpha(st.OutlineColor, op));
  end;
  // list-style-image marker: a small image box sized to the font, outdented to
  // the left of the content (or in the reserved inside gap).
  if (not Hidden) and (Box.MarkerImage >= 0) then
  begin
    mkImgSz := st.FontSize;
    Canvas.DrawImage(Box.MarkerImage,
      Box.X + st.BorderWidths.Left + st.Padding.Left - 8 - mkImgSz,
      y + st.BorderWidths.Top + st.Padding.Top, mkImgSz, mkImgSz);
  end;
  // list marker: right-aligned so multi-char markers (III., 10.) share the
  // same right edge, sitting just left of the content text.
  if (not Hidden) and (Box.MarkerText <> '') then
  begin
    m := Canvas.MeasureText(Box.MarkerText, st.FontSize, []);
    if st.ListStyleInside then
      // inside: the padding was widened by the marker; draw it in that reserved gap
      Canvas.DrawText(Box.X + st.BorderWidths.Left + st.Padding.Left
        - Canvas.MeasureText(Box.MarkerText + ' ', st.FontSize, []).Width,
        y + st.BorderWidths.Top + st.Padding.Top, Box.MarkerText,
        st.FontSize, [], ScaleAlpha(st.Color, op))
    else
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

  // text-overflow: ellipsis — a single non-wrapping line (CSS requires
  // white-space:nowrap). Words are separate runs, so we truncate the run that
  // crosses the content edge, append '…', and drop every run after it.
  ellip := SameText(st.TextOverflow, 'ellipsis') and SameText(st.WhiteSpace, 'nowrap');
  rightEdge := Box.X + Box.W - st.BorderWidths.Right - st.Padding.Right;
  ellipDone := False;
  if not Hidden then
    for i := 0 to Box.Runs.Count - 1 do
    begin
      r := Box.Runs[i];
      drawTxt := r.Text;
      if ellip then
      begin
        if ellipDone then Continue;                 // line already ended with '…'
        avail := rightEdge - (r.X - sx);
        if avail <= 0 then Continue;                // run starts past the edge
        if Canvas.MeasureText(drawTxt, r.FontSize, r.Styles).Width > avail then
        begin
          while (drawTxt <> '') and
                (Canvas.MeasureText(drawTxt + '…', r.FontSize, r.Styles).Width > avail) do
            Delete(drawTxt, Length(drawTxt), 1);
          drawTxt := drawTxt + '…';
          ellipDone := True;
        end;
      end;
      fg := ScaleAlpha(r.Color, op);
      Canvas.LetterSpacing := r.LetterSpacing;
      Canvas.FontFamily := r.FontFamily;
      Canvas.FontWeight := r.FontWeight;
      if (r.ShadowColor shr 24) > 0 then
        Canvas.DrawText(r.X - sx + r.ShadowDX, r.Y - innerOfs + r.ShadowDY, drawTxt,
          r.FontSize, r.Styles, ScaleAlpha(r.ShadowColor, op));
      Canvas.DrawText(r.X - sx, r.Y - innerOfs, drawTxt, r.FontSize, r.Styles, fg);
      // overline: no native font attribute, so rule it by hand across the run,
      // just inside the top of the em box (matches Chrome's placement closely).
      if tfsOverline in r.Styles then
        Canvas.FillRect(r.X - sx, r.Y - innerOfs + r.FontSize * 0.06,
          Canvas.MeasureText(drawTxt, r.FontSize, r.Styles).Width,
          Max(1, r.FontSize / 14), fg);
      Canvas.LetterSpacing := 0;
      Canvas.FontFamily := '';
      Canvas.FontWeight := 0;
    end;
  // z-index: paint children ordered by z-index (stable — ties keep tree order),
  // so positioned overlays layer correctly. Fast path when nothing sets it.
  SetLength(zorder, Box.Children.Count);
  anyZ := False;
  for i := 0 to Box.Children.Count - 1 do
  begin
    zorder[i] := i;
    if Box.Children[i].Style.ZIndex <> 0 then anyZ := True;
  end;
  if anyZ then
    for zi := 1 to High(zorder) do   // stable insertion sort by z-index
    begin
      zj := zi;
      while (zj > 0) and
            (Box.Children[zorder[zj - 1]].Style.ZIndex > Box.Children[zorder[zj]].Style.ZIndex) do
      begin
        ztmp := zorder[zj - 1]; zorder[zj - 1] := zorder[zj]; zorder[zj] := ztmp;
        Dec(zj);
      end;
    end;
  for zi := 0 to High(zorder) do
  begin
    i := zorder[zi];
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
      if st.CaretColor <> 0 then
        Canvas.FillRect(cx, cy, 1.5, st.FontSize + 2, st.CaretColor)   // caret-color
      else
        Canvas.FillRect(cx, cy, 1.5, st.FontSize + 2, $FF1F2937);
    end;
    if Box.ControlKind = ckSelect then
      Canvas.DrawText(Box.X + Box.W - 18, y + st.BorderWidths.Top + st.Padding.Top,
        '▾', st.FontSize, [], TC_MUTED);
    // <input type=number> spinner: a thin divider + stacked ▴/▾ on the right
    // edge; the viewer routes clicks in this strip to step the value up/down.
    if (Box.ControlKind = ckTextInput) and
       SameText(Box.Tag.GetAttribute('type'), 'number') then
    begin
      Canvas.FillRect(Box.X + Box.W - 20, y + st.BorderWidths.Top, 1,
        Box.H - st.BorderWidths.Vert, TC_BORDER);
      Canvas.DrawText(Box.X + Box.W - 15, y + 2,
        '▴', st.FontSize * 0.85, [], TC_MUTED);
      Canvas.DrawText(Box.X + Box.W - 15, y + Box.H / 2,
        '▾', st.FontSize * 0.85, [], TC_MUTED);
    end;
  end;
  finally
    // composite the filter/blend layer back before undoing the transform
    if use3D and (layer3D >= 0) then
      Canvas.EndLayer3D(layer3D, corners3d);
    if useLayer and (filterLayer >= 0) then
      Canvas.EndLayerFiltered(filterLayer, st.Filter, st.MixBlendMode, st.MaskImage);
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
  // pointer-events:none — the box and its subtree are transparent to hit-testing
  // (clicks pass through to whatever is behind).
  if (Box.Tag <> nil) and Box.Style.PointerEventsNone then Exit;
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
