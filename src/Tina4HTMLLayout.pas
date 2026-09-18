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
  Tina4Lottie, Tina4RasterCanvas, Tina4Elements, Tina4Hyphen;

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
    // decoration painted by hand (non-solid style or a distinct color); the
    // font-drawn underline is suppressed in that case. DecorLines bitmask:
    // 1=underline 2=line-through 4=overline. DecorStyle: 0 solid 1 double
    // 2 dotted 3 dashed 4 wavy. DecorColor 0 => use text color.
    DecorLines, DecorStyle: Byte; DecorColor: TTina4Color;
    DecorThickness, DecorOffset: Single;  // text-decoration-thickness / underline-offset (0 = auto)
  end;

  { Form controls are DRAWN by the renderer (no native widgets); their state
    lives in the DOM: input/textarea in 'value', checkbox/radio in 'checked',
    select in 'value'. The app mutates attributes and rebuilds. }
  TControlKind = (ckNone, ckTextInput, ckTextarea, ckCheckbox, ckRadio,
    ckSelect, ckButton, ckFile, ckDate, ckRange, ckColor, ckProgress, ckMeter,
    ckAudio);

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
    RubyBaseline: Single;          // <ruby> atom: base baseline offset from box top (0 = not ruby)
    VerticalRL: Boolean;           // writing-mode:vertical-rl — content laid out against the
                                   // height, painted rotated 90° CW into right-to-left columns
    VerticalLR: Boolean;           // writing-mode:vertical-lr — same CW rotation, but the
                                   // column order is reversed in layout so columns read L→R
    ColRuleGaps: Integer;          // multicol: number of column gaps (ncols-1); 0 = no rule
    ColRuleColW, ColRuleGap: Single;   // column width and gap, for placing column-rules
    ColRuleX0, ColRuleY0, ColRuleH: Single;  // content origin + tallest column height
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
    FViewportH: Single;            // initial containing block height — position:fixed anchor
    FContainingH: Single;          // containing block's definite content height, or -1
                                   // (auto) — the % base for a child's height:NN%
    FSynthTags: TList<THTMLTag>;   // anonymous flex-item wrappers (freed each layout)
    FFloats: array of TFloatBand;  // active float context (absolute coords)
    FCounters: TDictionary<string, TList<Integer>>;  // CSS counters: name -> nesting stack
    function FontStylesOf(const St: TComputedStyle): TTina4FontStyles;
    procedure ComputeDecor(const St: TComputedStyle; var FS: TTina4FontStyles;
      out Lines, Sty: Byte; out Col: TTina4Color; out Th, Off: Single);
    function LineHeightOf(const St: TComputedStyle): Single;
    procedure LayoutChildren(Box: TLayoutBox; Tag: THTMLTag;
      const ParentStyle: TComputedStyle; CX, CY, CW: Single; out UsedH: Single);
    function LayoutBlock(Parent: TLayoutBox; Tag: THTMLTag;
      const ParentStyle: TComputedStyle; X, Y, AvailW: Single): Single;
    function LayoutTable(Parent: TLayoutBox; Tag: THTMLTag;
      const Style: TComputedStyle; X, Y, AvailW: Single): Single;
    function MakeInlineBlock(Tag: THTMLTag; const St: TComputedStyle): TLayoutBox;
    function MakeRubyBox(Tag: THTMLTag; const St: TComputedStyle): TLayoutBox;
    function MakeInlineContainer(Tag: THTMLTag; const St: TComputedStyle;
      AvailW: Single): TLayoutBox;
    function MakeContainerBox(Tag: THTMLTag; const ParentStyle: TComputedStyle;
      AvailW: Single; const d: string; ForceH: Single = -1): TLayoutBox;
    { A replaced element (img/svg/qrcode) used directly as a block or flex
      item — build it as an atom instead of laying out its children. Returns
      nil when Tag is not a replaced element. }
    function MakeReplacedBox(T: THTMLTag; const cs: TComputedStyle;
      CW: Single): TLayoutBox;
    function MakeControl(Tag: THTMLTag; St: TComputedStyle; AvailW: Single): TLayoutBox;
    function LayoutControlBlock(Parent: TLayoutBox; Tag: THTMLTag;
      const St: TComputedStyle; X, Y, AvailW: Single): Single;
    function LayoutFlex(Parent: TLayoutBox; Tag: THTMLTag;
      const ParentStyle: TComputedStyle; X, Y, AvailW: Single;
      ForceContentH: Single = -1): Single;
    function LayoutGrid(Parent: TLayoutBox; Tag: THTMLTag;
      const ParentStyle: TComputedStyle; X, Y, AvailW: Single): Single;
    { CSS multi-column: lay children into one narrow column, then balance them
      across N columns. Returns the used height (the tallest column). }
    function LayoutColumns(box: TLayoutBox; Tag: THTMLTag;
      const st: TComputedStyle; contentX, contentY, contentW: Single): Single;
    procedure CollectInlineText(Tag: THTMLTag; SB: TStringBuilder);
    procedure FreeSynthTags;
    function MakeAnonTextItem(Parent: THTMLTag; const S: string): THTMLTag;
    function PseudoTag(Tag: THTMLTag; const Which: string): THTMLTag;
    procedure InjectPseudo(Tag: THTMLTag);
    { ::first-letter: slice the first letter of Tag's first text into a synthetic
      floated/inline pseudo carrying the rule's style (the drop-cap pattern). }
    procedure InjectFirstLetter(Tag: THTMLTag);
    { CSS counters. FCounters holds a nesting stack per name; document-order
      traversal in InjectPseudo pushes on counter-reset, adds on
      counter-increment, and pops the element's resets on exit. }
    procedure ResetCounterState;
    function CounterStack(const Name: string): TList<Integer>;
    function CounterApplyReset(const Spec: string): TStringList;
    function CounterApplySet(const Spec: string): TStringList;
    procedure CounterApplyIncrement(const Spec: string);
    procedure CounterPop(Names: TStringList);
    function ResolveContentValue(Tag: THTMLTag; const CV: string): string;
    function ResolveContentFunc(Tag: THTMLTag; const Fn, Arg: string): string;
  public
    constructor Create(Canvas: TTina4Canvas; Sheet: TCSSStyleSheet);
    destructor Destroy; override;
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
  { Device pixels per CSS px for the current frame. The host (Tina4Interact) sets
    this each frame from its density so the core can rasterize time-driven canvas
    content (<lottie>) at native resolution before a single DrawRGBA blit. }
  PaintDeviceScale: Single = 1;
  { Paint-clip for the retained backing-store: when active, PaintBox culls any box
    whose screen rect (CSS px) lies wholly outside [X0,Y0]-[X1,Y1], so an
    animation-only frame issues draw calls for the animated region only. }
  PaintClipActive: Boolean = False;
  PaintClipX0, PaintClipY0, PaintClipX1, PaintClipY1: Single;

procedure PaintBox(Canvas: TTina4Canvas; Box: TLayoutBox; OffsetY: Single);
function HitTest(Box: TLayoutBox; X, Y: Single): THTMLTag;
{ Deepest overflow-scrollable box containing the point (doc coords). }
function FindScrollBox(Box: TLayoutBox; X, Y: Single): TLayoutBox;
{ Box whose Tag = T (first match). }
function FindBoxForTag(Box: TLayoutBox; T: THTMLTag): TLayoutBox;
{ Text selection (document CSS px), driven by Tina4Interact, painted + read by
  the core. SetTextSelection(False,...) clears it. }
procedure SetTextSelection(Active: Boolean; ax, ay, fx, fy: Single);
{ The currently-selected text, accumulated during the last paint (paint order,
  user-select:none subtrees skipped, lines joined with LF); '' if none. }
function SelectedText: string;
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

var
  { Reused across frames/elements so a <lottie> repaint allocates no buffer once
    its size settles (Resize is a no-op when unchanged). Freed at finalization. }
  GLottieRaster: TTina4RasterCanvas = nil;

  { Active text selection, in document CSS px. Anchor is where the drag began,
    Focus is the current end. Selection lives in the core (not the interaction
    unit) so PaintBoxEx can paint the highlight and CollectSelectedText can read
    it, while Tina4Interact only drives it via SetTextSelection. }
  GSelActive: Boolean = False;
  GSelAX: Single = 0; GSelAY: Single = 0;   // anchor (drag start)
  GSelFX: Single = 0; GSelFY: Single = 0;   // focus (drag end)
  GSelText: string = '';                    // selected text, gathered during paint
  GSelLastY: Single = -1;                   // last selected glyph's line Y (for LF breaks)

  { Active perspective context (transform-style:preserve-3d scenes). Set while
    painting the subtree of an element with the `perspective` property; a
    preserve-3d container inside it projects its children through this. }
  G3DPerspD: Single = 0;                     // perspective distance px, 0 = none
  G3DPerspOX: Single = 0; G3DPerspOY: Single = 0;   // perspective origin, paint coords

{ Normalise anchor/focus into reading order: lo is the earlier point (smaller Y,
  or same line and smaller X), hi the later. }
procedure SelOrder(out loX, loY, hiX, hiY: Single);
begin
  if (GSelAY < GSelFY) or ((Abs(GSelAY - GSelFY) < 0.5) and (GSelAX <= GSelFX)) then
  begin loX := GSelAX; loY := GSelAY; hiX := GSelFX; hiY := GSelFY; end
  else
  begin loX := GSelFX; loY := GSelFY; hiX := GSelAX; hiY := GSelAY; end;
end;

{ Is a glyph whose centre is (gcx, gcy) inside the current selection, given a
  half-line tolerance for deciding same-line membership? }
function GlyphSelected(gcx, gcy, halfLine: Single): Boolean;
var loX, loY, hiX, hiY: Single; afterLo, beforeHi: Boolean;
begin
  SelOrder(loX, loY, hiX, hiY);
  afterLo := (gcy - loY > halfLine) or
             ((Abs(gcy - loY) <= halfLine) and (gcx >= loX));
  beforeHi := (hiY - gcy > halfLine) or
              ((Abs(gcy - hiY) <= halfLine) and (gcx <= hiX));
  Result := afterLo and beforeHi;
end;

{ Drive the selection from the interaction unit. }
procedure SetTextSelection(Active: Boolean; ax, ay, fx, fy: Single);
begin
  GSelActive := Active; GSelAX := ax; GSelAY := ay; GSelFX := fx; GSelFY := fy;
end;

function SelectedText: string;
begin
  Result := GSelText;
end;

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

{ True when the element establishes a flex or grid formatting context. }
function IsFlexOrGrid(const cs: TComputedStyle): Boolean;
var d: string;
begin
  d := LowerCase(cs.Display);
  Result := (d = 'flex') or (d = 'inline-flex') or (d = 'grid') or (d = 'inline-grid');
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
    SameText(Name, 'camera') or SameText(Name, 'recorder') or
    SameText(Name, 'progress') or SameText(Name, 'meter') or
    SameText(Name, 'audio');
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
{ n-th lowercase Greek letter (1-based) for list-style-type: lower-greek —
  α..ω, skipping final sigma (ς), wrapping after 24. UTF-8 (2-byte) encoded. }
function LowerGreekLetter(Idx: Integer): string;
var pos, cp: Integer;
begin
  if Idx < 1 then Exit(IntToStr(Idx));
  pos := (Idx - 1) mod 24;
  cp := $03B1 + pos;
  if cp >= $03C2 then Inc(cp);          // step over ς (final sigma)
  Result := Chr($C0 or (cp shr 6)) + Chr($80 or (cp and $3F));
end;

function MarkerFor(const ListStyleType: string; Idx: Integer): string;
var t: string;
begin
  t := LowerCase(ListStyleType);
  if t = 'none' then Exit('');
  if t = 'circle' then Exit(#$E2#$97#$A6)         // ◦
  else if t = 'square' then Exit(#$E2#$96#$AA)    // ▪
  else if t = 'decimal' then Exit(IntToStr(Idx) + '.')
  else if t = 'decimal-leading-zero' then
  begin
    if (Idx >= 0) and (Idx < 10) then Exit('0' + IntToStr(Idx) + '.') else Exit(IntToStr(Idx) + '.');
  end
  else if (t = 'lower-alpha') or (t = 'lower-latin') then Exit(Chr(Ord('a') + (Idx - 1) mod 26) + '.')
  else if (t = 'upper-alpha') or (t = 'upper-latin') then Exit(Chr(Ord('A') + (Idx - 1) mod 26) + '.')
  else if t = 'lower-roman' then Exit(ToRoman(Idx) + '.')
  else if t = 'upper-roman' then Exit(UpperCase(ToRoman(Idx)) + '.')
  else if t = 'lower-greek' then Exit(LowerGreekLetter(Idx) + '.')
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

{ Remove the invisible Unicode bidi control characters (marks, embeddings,
  overrides, isolates) so they never render as tofu. Their full embedding effect
  isn't modelled (the per-item bidi resolves from strong characters), so dropping
  them is strictly better than painting a missing-glyph box. Covers LRM/RLM/ALM,
  LRE/RLE/PDF/LRO/RLO, and LRI/RLI/FSI/PDI. }
function StripBidiControls(const S: string): string;
begin
  Result := S;
  if Pos(#$E2, Result) > 0 then
  begin
    // U+200E..200F (E2 80 8E/8F) and U+202A..202E (E2 80 AA..AE)
    Result := StringReplace(Result, #$E2#$80#$8E, '', [rfReplaceAll]);
    Result := StringReplace(Result, #$E2#$80#$8F, '', [rfReplaceAll]);
    Result := StringReplace(Result, #$E2#$80#$AA, '', [rfReplaceAll]);
    Result := StringReplace(Result, #$E2#$80#$AB, '', [rfReplaceAll]);
    Result := StringReplace(Result, #$E2#$80#$AC, '', [rfReplaceAll]);
    Result := StringReplace(Result, #$E2#$80#$AD, '', [rfReplaceAll]);
    Result := StringReplace(Result, #$E2#$80#$AE, '', [rfReplaceAll]);
    // U+2066..2069 (E2 81 A6..A9)
    Result := StringReplace(Result, #$E2#$81#$A6, '', [rfReplaceAll]);
    Result := StringReplace(Result, #$E2#$81#$A7, '', [rfReplaceAll]);
    Result := StringReplace(Result, #$E2#$81#$A8, '', [rfReplaceAll]);
    Result := StringReplace(Result, #$E2#$81#$A9, '', [rfReplaceAll]);
  end;
  if Pos(#$D8, Result) > 0 then
    Result := StringReplace(Result, #$D8#$9C, '', [rfReplaceAll]);   // U+061C ALM
end;

{ ---- Unicode bidi (UBA) — enough for mixed LTR/RTL paragraphs ---------------
  A pragmatic subset: classify each item by its first strong character (or its
  digits), resolve a display level, and reorder a line's items by the UBA L2
  rule. The native text backends shape each run (Arabic/Hebrew) themselves; this
  supplies the run *ordering* the layout must get right. Level resolution is
  per-item (words are single-direction in the common case), not per-character. }
type TBidiKind = (bkL, bkR, bkEN, bkAN, bkNeutral);

function BidiKindOfCP(cp: Cardinal): TBidiKind;
begin
  // strong RTL: Hebrew, Arabic, Syriac, Thaana, NKo, + presentation forms
  if ((cp >= $0590) and (cp <= $05FF)) or ((cp >= $0600) and (cp <= $06FF)) or
     ((cp >= $0700) and (cp <= $074F)) or ((cp >= $0750) and (cp <= $077F)) or
     ((cp >= $0780) and (cp <= $07BF)) or ((cp >= $07C0) and (cp <= $07FF)) or
     ((cp >= $08A0) and (cp <= $08FF)) or ((cp >= $FB1D) and (cp <= $FB4F)) or
     ((cp >= $FB50) and (cp <= $FDFF)) or ((cp >= $FE70) and (cp <= $FEFF)) then
    Exit(bkR);
  if (cp >= $0660) and (cp <= $0669) then Exit(bkAN);          // Arabic-Indic digits
  if ((cp >= $0030) and (cp <= $0039)) or
     ((cp >= $06F0) and (cp <= $06F9)) then Exit(bkEN);        // European / ext-Arabic digits
  // strong LTR: Latin, Greek, Cyrillic, CJK, Kana, Hangul
  if ((cp >= $0041) and (cp <= $005A)) or ((cp >= $0061) and (cp <= $007A)) or
     ((cp >= $00C0) and (cp <= $024F)) or ((cp >= $0370) and (cp <= $03FF)) or
     ((cp >= $0400) and (cp <= $04FF)) or ((cp >= $3040) and (cp <= $30FF)) or
     ((cp >= $4E00) and (cp <= $9FFF)) or ((cp >= $AC00) and (cp <= $D7AF)) then
    Exit(bkL);
  Result := bkNeutral;   // spaces, punctuation, symbols
end;

{ Decode the codepoint at byte P (1-based) of a UTF-8 string; advance P past it. }
function NextCP(const S: string; var P: Integer): Cardinal;
var b: Byte; n, i: Integer;
begin
  b := Ord(S[P]);
  if b < $80 then begin Result := b; Inc(P); Exit; end;
  if b < $E0 then begin Result := b and $1F; n := 1; end
  else if b < $F0 then begin Result := b and $0F; n := 2; end
  else begin Result := b and $07; n := 3; end;
  Inc(P);
  for i := 1 to n do
  begin
    if (P > Length(S)) or ((Ord(S[P]) and $C0) <> $80) then Break;
    Result := (Result shl 6) or (Ord(S[P]) and $3F); Inc(P);
  end;
end;

{ UBA L4 mirroring: a bracket/quote/operator paints as its mirror in an RTL run
  (Bidi_Mirrored). Common pairs; returns cp unchanged when not mirrorable. }
function BidiMirrorCP(cp: Cardinal): Cardinal;
begin
  case cp of
    $0028: Result := $0029; $0029: Result := $0028;   // ( )
    $005B: Result := $005D; $005D: Result := $005B;   // [ ]
    $007B: Result := $007D; $007D: Result := $007B;   // { }
    $003C: Result := $003E; $003E: Result := $003C;   // < >
    $00AB: Result := $00BB; $00BB: Result := $00AB;   // « »
    $2039: Result := $203A; $203A: Result := $2039;   // ‹ ›
    $2264: Result := $2265; $2265: Result := $2264;   // ≤ ≥
    $230A: Result := $230B; $230B: Result := $230A;   // ⌊ ⌋
    $2308: Result := $2309; $2309: Result := $2308;   // ⌈ ⌉
  else Result := cp;
  end;
end;

{ Encode a codepoint as UTF-8. }
function CPToU8(cp: Cardinal): string;
begin
  if cp < $80 then Result := Chr(cp)
  else if cp < $800 then Result := Chr($C0 or (cp shr 6)) + Chr($80 or (cp and $3F))
  else if cp < $10000 then Result := Chr($E0 or (cp shr 12)) + Chr($80 or ((cp shr 6) and $3F)) + Chr($80 or (cp and $3F))
  else Result := Chr($F0 or (cp shr 18)) + Chr($80 or ((cp shr 12) and $3F)) + Chr($80 or ((cp shr 6) and $3F)) + Chr($80 or (cp and $3F));
end;

{ Reverse the characters of a pure-punctuation token and mirror each — the visual
  form of a neutral run at an RTL (odd) level. Applied only to items with no
  strong character (strong-char runs are shaped by the native backend, which
  mirrors them itself; doing it here too would double-mirror). }
function MirrorNeutralRTL(const S: string): string;
var p: Integer; cps: array of Cardinal; n, i: Integer;
begin
  SetLength(cps, Length(S)); n := 0; p := 1;
  while p <= Length(S) do begin cps[n] := BidiMirrorCP(NextCP(S, p)); Inc(n); end;
  Result := '';
  for i := n - 1 downto 0 do Result := Result + CPToU8(cps[i]);   // reverse + mirror
end;

{ An item's bidi kind: its first strong character (L or R) decides; failing that,
  a digit makes it a number; otherwise it is neutral (resolved from context). }
function ItemBidiKind(const S: string): TBidiKind;
var p: Integer; k: TBidiKind; sawNum: Boolean;
begin
  p := 1; sawNum := False;
  while p <= Length(S) do
  begin
    k := BidiKindOfCP(NextCP(S, p));
    if (k = bkL) or (k = bkR) then Exit(k);
    if (k = bkEN) or (k = bkAN) then sawNum := True;
  end;
  if sawNum then Result := bkEN else Result := bkNeutral;
end;

{ font-stretch as a horizontal scale factor (bucketed so the measured advance and
  the painted glyph scale always agree — a coarse but consistent synthetic). }
function StretchFactorOf(const fs: TTina4FontStyles): Single;
begin
  if tfsStretchC in fs then Result := 0.78
  else if tfsStretchE in fs then Result := 1.28
  else Result := 1.0;
end;

{ True if the first strong character of S is RTL (UBA P2/P3, for dir=auto/<bdi>). }
function FirstStrongRTL(const S: string): Boolean;
var p: Integer; k: TBidiKind;
begin
  p := 1;
  while p <= Length(S) do
  begin
    k := BidiKindOfCP(NextCP(S, p));
    if k = bkR then Exit(True) else if k = bkL then Exit(False);
  end;
  Result := False;
end;

{ TLayoutEngine }

constructor TLayoutEngine.Create(Canvas: TTina4Canvas; Sheet: TCSSStyleSheet);
begin
  FCanvas := Canvas;
  FSheet := Sheet;
  FSynthTags := TList<THTMLTag>.Create;
  FCounters := TDictionary<string, TList<Integer>>.Create;
end;

destructor TLayoutEngine.Destroy;
begin
  FreeSynthTags;
  FSynthTags.Free;
  ResetCounterState;
  FCounters.Free;
  inherited Destroy;
end;

{ Free the anonymous flex-item wrapper tags from the previous layout. Safe here
  because the box tree that referenced them has been rebuilt/discarded. Each
  wrapper owns a private #text copy, so this never touches real DOM nodes. }
procedure TLayoutEngine.FreeSynthTags;
var i: Integer;
begin
  if FSynthTags = nil then Exit;
  for i := 0 to FSynthTags.Count - 1 do FSynthTags[i].Free;
  FSynthTags.Clear;
end;

{ Wrap a text run in an anonymous inline element so it becomes an anonymous flex
  item (CSS: contiguous text in a flex container). Owns a private #text copy and
  is freed on the next layout, so it never touches real DOM nodes. }
function TLayoutEngine.MakeAnonTextItem(Parent: THTMLTag; const S: string): THTMLTag;
var tx: THTMLTag;
begin
  Result := THTMLTag.Create;
  Result.TagName := 'span';
  Result.Parent := Parent;
  tx := THTMLTag.Create;
  tx.TagName := '#text';
  tx.Text := S;
  tx.Parent := Result;
  Result.Children.Add(tx);
  FSynthTags.Add(Result);
end;

{ Strip the CSS content quotes; empty for the non-generating keywords. }
function UnquoteContent(const S: string): string;
var t: string;
begin
  t := Trim(S);
  if (t = '') or SameText(t, 'none') or SameText(t, 'normal') then Exit('');
  if (Length(t) >= 2) and (t[1] = '"') and (t[Length(t)] = '"') then
    Exit(Copy(t, 2, Length(t) - 2));
  if (Length(t) >= 2) and (t[1] = '''') and (t[Length(t)] = '''') then
    Exit(Copy(t, 2, Length(t) - 2));
  Result := t;
end;

{ Strip a single/double quote pair from a token (for counters() separators). }
function StripQuotes(const S: string): string;
var t: string;
begin
  t := Trim(S);
  if (Length(t) >= 2) and ((t[1] = '"') and (t[Length(t)] = '"')) then
    Exit(Copy(t, 2, Length(t) - 2));
  if (Length(t) >= 2) and ((t[1] = '''') and (t[Length(t)] = '''')) then
    Exit(Copy(t, 2, Length(t) - 2));
  Result := t;
end;

{ Roman numerals (1..3999 practical range); <=0 falls back to decimal. }
function CounterToRoman(N: Integer; Upper: Boolean): string;
const
  Vals: array[0..12] of Integer =
    (1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1);
  Syms: array[0..12] of string =
    ('m', 'cm', 'd', 'cd', 'c', 'xc', 'l', 'xl', 'x', 'ix', 'v', 'iv', 'i');
var i: Integer;
begin
  if N <= 0 then Exit(IntToStr(N));
  Result := '';
  for i := 0 to 12 do
    while N >= Vals[i] do begin Result := Result + Syms[i]; N := N - Vals[i]; end;
  if Upper then Result := UpperCase(Result);
end;

{ Bijective base-26 alpha (a..z, aa..); <=0 falls back to decimal. }
function CounterToAlpha(N: Integer; Upper: Boolean): string;
var base: Integer; c: Char;
begin
  if N <= 0 then Exit(IntToStr(N));
  Result := '';
  while N > 0 do
  begin
    Dec(N);
    base := N mod 26;
    if Upper then c := Chr(Ord('A') + base) else c := Chr(Ord('a') + base);
    Result := c + Result;
    N := N div 26;
  end;
end;

{ Render a counter value per a list-style keyword (decimal is the default). }
function FormatCounter(V: Integer; const Style: string): string;
var s: string;
begin
  s := LowerCase(Trim(Style));
  if (s = '') or (s = 'decimal') then Exit(IntToStr(V));
  if s = 'decimal-leading-zero' then
  begin
    if (V >= 0) and (V < 10) then Exit('0' + IntToStr(V)) else Exit(IntToStr(V));
  end;
  if s = 'lower-roman' then Exit(CounterToRoman(V, False));
  if s = 'upper-roman' then Exit(CounterToRoman(V, True));
  if (s = 'lower-alpha') or (s = 'lower-latin') then Exit(CounterToAlpha(V, False));
  if (s = 'upper-alpha') or (s = 'upper-latin') then Exit(CounterToAlpha(V, True));
  if s = 'none' then Exit('');
  Result := IntToStr(V);
end;

{ Parse a `counter-reset`/`counter-increment` value into name/value pairs.
  Each name may be followed by an integer; a bare name uses DefVal. }
procedure ParseCounterPairs(const Spec: string; DefVal: Integer;
  Names: TStringList; Vals: TList<Integer>);
var parts: TArray<string>; i, n: Integer;
begin
  parts := Trim(Spec).Split([' '], TStringSplitOptions.ExcludeEmpty);
  i := 0;
  while i < Length(parts) do
  begin
    if (parts[i] = 'none') or (parts[i] = '') then begin Inc(i); Continue; end;
    Names.Add(parts[i]);
    if (i + 1 < Length(parts)) and TryStrToInt(parts[i + 1], n) then
    begin Vals.Add(n); Inc(i, 2); end
    else begin Vals.Add(DefVal); Inc(i); end;
  end;
end;

{ Clear all counter stacks (start of each Build). }
procedure TLayoutEngine.ResetCounterState;
var v: TList<Integer>;
begin
  if FCounters = nil then Exit;
  for v in FCounters.Values do v.Free;
  FCounters.Clear;
end;

{ The nesting stack for a counter name, created empty on first use. }
function TLayoutEngine.CounterStack(const Name: string): TList<Integer>;
begin
  if not FCounters.TryGetValue(Name, Result) then
  begin
    Result := TList<Integer>.Create;
    FCounters.AddOrSetValue(Name, Result);
  end;
end;

{ counter-reset: push a new nested level per named counter. Returns the names
  pushed so the caller can pop them when the element's scope ends. }
function TLayoutEngine.CounterApplyReset(const Spec: string): TStringList;
var names: TStringList; vals: TList<Integer>; i: Integer;
begin
  Result := TStringList.Create;
  names := TStringList.Create; vals := TList<Integer>.Create;
  try
    ParseCounterPairs(Spec, 0, names, vals);
    for i := 0 to names.Count - 1 do
    begin
      CounterStack(names[i]).Add(vals[i]);   // push new level
      Result.Add(names[i]);
    end;
  finally names.Free; vals.Free; end;
end;

{ counter-set: set the innermost value of each named counter. If the counter
  has no level yet one is created (and returned so the caller pops it when the
  element scope ends); an existing level is overwritten in place. }
function TLayoutEngine.CounterApplySet(const Spec: string): TStringList;
var names: TStringList; vals: TList<Integer>; i: Integer; st: TList<Integer>;
begin
  Result := TStringList.Create;
  names := TStringList.Create; vals := TList<Integer>.Create;
  try
    ParseCounterPairs(Spec, 0, names, vals);
    for i := 0 to names.Count - 1 do
    begin
      st := CounterStack(names[i]);
      if st.Count = 0 then begin st.Add(vals[i]); Result.Add(names[i]); end
      else st[st.Count - 1] := vals[i];
    end;
  finally names.Free; vals.Free; end;
end;

{ counter-increment: add to the innermost value (auto-creating at 0). }
procedure TLayoutEngine.CounterApplyIncrement(const Spec: string);
var names: TStringList; vals: TList<Integer>; i: Integer; st: TList<Integer>;
begin
  names := TStringList.Create; vals := TList<Integer>.Create;
  try
    ParseCounterPairs(Spec, 1, names, vals);
    for i := 0 to names.Count - 1 do
    begin
      st := CounterStack(names[i]);
      if st.Count = 0 then st.Add(0);
      st[st.Count - 1] := st[st.Count - 1] + vals[i];
    end;
  finally names.Free; vals.Free; end;
end;

{ Pop the innermost level of each named counter (element scope ended). }
procedure TLayoutEngine.CounterPop(Names: TStringList);
var i: Integer; st: TList<Integer>;
begin
  if Names = nil then Exit;
  for i := 0 to Names.Count - 1 do
    if FCounters.TryGetValue(Names[i], st) and (st.Count > 0) then
      st.Delete(st.Count - 1);
end;

{ Resolve one content function: counter(), counters() or attr(). }
function TLayoutEngine.ResolveContentFunc(Tag: THTMLTag; const Fn, Arg: string): string;
var parts: TArray<string>; nm, sty, sep: string; st: TList<Integer>; i: Integer;
begin
  Result := '';
  if Fn = 'attr' then
  begin
    if Tag <> nil then Result := Tag.GetAttribute(Trim(Arg), '');
  end
  else if Fn = 'counter' then
  begin
    parts := Arg.Split([',']);
    nm := Trim(parts[0]);
    if Length(parts) >= 2 then sty := Trim(parts[1]) else sty := 'decimal';
    if FCounters.TryGetValue(nm, st) and (st.Count > 0) then
      Result := FormatCounter(st[st.Count - 1], sty)
    else
      Result := FormatCounter(0, sty);
  end
  else if Fn = 'counters' then
  begin
    parts := Arg.Split([',']);
    nm := Trim(parts[0]);
    if Length(parts) >= 2 then sep := StripQuotes(parts[1]) else sep := '';
    if Length(parts) >= 3 then sty := Trim(parts[2]) else sty := 'decimal';
    if FCounters.TryGetValue(nm, st) then
      for i := 0 to st.Count - 1 do
      begin
        if i > 0 then Result := Result + sep;
        Result := Result + FormatCounter(st[i], sty);
      end;
  end;
end;

{ Resolve a full `content` value into display text: concatenates quoted string
  literals with counter()/counters()/attr() results; unknown keywords add
  nothing. This supersedes UnquoteContent when counters are in play. }
function TLayoutEngine.ResolveContentValue(Tag: THTMLTag; const CV: string): string;
var
  s, ident, arg: string; i, L: Integer; ch, q: Char; res: TStringBuilder;
begin
  Result := '';
  s := Trim(CV);
  if (s = '') or SameText(s, 'none') or SameText(s, 'normal') then Exit;
  L := Length(s);
  res := TStringBuilder.Create;
  try
    i := 1;
    while i <= L do
    begin
      ch := s[i];
      if (ch = '"') or (ch = '''') then
      begin
        q := ch; Inc(i);
        while (i <= L) and (s[i] <> q) do
        begin
          if (s[i] = '\') and (i < L) then Inc(i);   // simple escape
          res.Append(s[i]); Inc(i);
        end;
        if i <= L then Inc(i);   // closing quote
      end
      else if ch = ' ' then Inc(i)
      else
      begin
        ident := '';
        while (i <= L) and (s[i] <> '(') and (s[i] <> ' ') do
        begin ident := ident + s[i]; Inc(i); end;
        if (i <= L) and (s[i] = '(') then
        begin
          Inc(i); arg := '';
          while (i <= L) and (s[i] <> ')') do begin arg := arg + s[i]; Inc(i); end;
          if i <= L then Inc(i);   // ')'
          res.Append(ResolveContentFunc(Tag, LowerCase(ident), arg));
        end;
        // a bare keyword (open-quote/etc.) contributes nothing
      end;
    end;
    Result := res.ToString;
  finally
    res.Free;
  end;
end;

{ Build a synthetic ::before/::after element for Tag if a matching rule sets a
  generating `content`. The pseudo's declarations are baked into .Style (applied
  last by ForTag), and the unquoted content becomes a #text child. Returns nil
  when no pseudo is generated. Marked 'tina4::<which>' so InjectPseudo can find
  and free it on the next layout. }
function TLayoutEngine.PseudoTag(Tag: THTMLTag; const Which: string): THTMLTag;
var
  decls: TCSSDeclarations;
  cv, txt, k, v, pos: string;
  p, tx: THTMLTag;
begin
  Result := nil;
  if FSheet = nil then Exit;
  decls := TCSSDeclarations.Create;
  try
    if not FSheet.CollectPseudoStyle(Tag, Which, decls) then Exit;
    if not decls.TryGetValue('content', cv) then Exit;   // no content => no box
    if SameText(Trim(cv), 'none') or SameText(Trim(cv), 'normal') then Exit;
    // The pseudo's own counter-increment applies as it is generated (document
    // order: ::before sits at the start of its element's content), before its
    // content's counter() references are resolved. A pseudo is a leaf with no
    // descendant scope, so counter-reset on it is left to the host element.
    if decls.TryGetValue('counter-increment', k) then CounterApplyIncrement(k);
    p := THTMLTag.Create;
    p.TagName := 'tina4::' + Which;
    p.Parent := Tag;
    // CSS default display for ::before/::after is inline; an absolutely
    // positioned pseudo with no explicit display gets a block box so width/
    // height apply (the ::after badge dot).
    if not decls.ContainsKey('display') then
    begin
      if decls.TryGetValue('position', pos) and
         (SameText(Trim(pos), 'absolute') or SameText(Trim(pos), 'fixed')) then
        p.Style.AddOrSetValue('display', 'block')
      else
        p.Style.AddOrSetValue('display', 'inline');
    end;
    for k in decls.Keys do
      if decls.TryGetValue(k, v) then p.Style.AddOrSetValue(k, v);
    txt := ResolveContentValue(Tag, cv);
    if txt <> '' then
    begin
      tx := THTMLTag.Create;
      tx.TagName := '#text';
      tx.Text := txt;
      tx.Parent := p;
      p.Children.Add(tx);
    end;
    Result := p;
  finally
    decls.Free;
  end;
end;

{ Byte length of the UTF-8 codepoint starting at byte B. }
function UTF8Len(B: Byte): Integer;
begin
  if B < $80 then Result := 1
  else if B >= $F0 then Result := 4
  else if B >= $E0 then Result := 3
  else if B >= $C0 then Result := 2
  else Result := 1;
end;

{ First #text descendant of Tag with a non-whitespace character (document order,
  skipping already-injected tina4:: nodes). Nil if the subtree has no real text. }
function FirstFlowTextNode(Tag: THTMLTag): THTMLTag;
var c, r: THTMLTag;
begin
  Result := nil;
  for c in Tag.Children do
  begin
    if c.TagName.StartsWith('tina4::') then Continue;
    if c.TagName = '#text' then
    begin
      if Trim(c.Text) <> '' then Exit(c);
    end
    else
    begin
      r := FirstFlowTextNode(c);
      if r <> nil then Exit(r);
    end;
  end;
end;

{ Split S into its ::first-letter slice (leading opening punctuation + the first
  letter grapheme, leading whitespace dropped) and the remainder. False when S
  has no letter. }
function SliceFirstLetter(const S: string; out Letter, Rest: string): Boolean;
const PUNCT = ['(', ')', '[', ']', '{', '}', '"', '''', '`', '<', '>', '*', '_', '#'];
var p, q, n: Integer;
begin
  Result := False; Letter := ''; Rest := S;
  n := Length(S);
  p := 1;
  while (p <= n) and ((S[p] = ' ') or (S[p] = #9) or (S[p] = #10) or (S[p] = #13)) do Inc(p);
  if p > n then Exit;
  q := p;
  while (q <= n) and (Ord(S[q]) < $80) and CharInSet(S[q], PUNCT) do Inc(q);   // leading punctuation
  if q > n then Exit;
  q := q + UTF8Len(Ord(S[q]));    // one grapheme (the letter)
  Letter := Copy(S, p, q - p);
  Rest := Copy(S, q, n);
  Result := Letter <> '';
end;

{ Inject a synthetic floated/inline pseudo carrying the ::first-letter style,
  holding Tag's first letter sliced out of its first text node. Idempotent: the
  strip phase in InjectPseudo restores the letter before the next injection. }
procedure TLayoutEngine.InjectFirstLetter(Tag: THTMLTag);
var
  decls: TCSSDeclarations;
  cv, k, v, letter, rest: string;
  src, synth, tx: THTMLTag;
  idx: Integer;
begin
  if FSheet = nil then Exit;
  decls := TCSSDeclarations.Create;
  try
    if not FSheet.CollectPseudoStyle(Tag, 'first-letter', decls) then Exit;
    src := FirstFlowTextNode(Tag);
    if (src = nil) or (src.Parent = nil) then Exit;
    if not SliceFirstLetter(src.Text, letter, rest) then Exit;

    synth := THTMLTag.Create;
    synth.TagName := 'tina4::first-letter';
    synth.Parent := src.Parent;
    synth.FLetterSrc := src;
    // ::first-letter with no display defaults to inline; a float makes it a block
    if not decls.ContainsKey('display') then
    begin
      if decls.TryGetValue('float', cv) and
         (SameText(Trim(cv), 'left') or SameText(Trim(cv), 'right')) then
        synth.Style.AddOrSetValue('display', 'block')
      else
        synth.Style.AddOrSetValue('display', 'inline-block');
    end;
    for k in decls.Keys do
      if decls.TryGetValue(k, v) then synth.Style.AddOrSetValue(k, v);

    tx := THTMLTag.Create;
    tx.TagName := '#text'; tx.Text := letter; tx.Parent := synth;
    synth.Children.Add(tx);

    idx := src.Parent.Children.IndexOf(src);
    if idx < 0 then begin synth.Free; Exit; end;
    src.Parent.Children.Insert(idx, synth);
    src.Text := rest;
  finally
    decls.Free;
  end;
end;

{ Recursively inject ::before/::after generated-content elements into the real
  DOM tree. Runs every layout: previously injected 'tina4::' children are freed
  first so re-layout stays idempotent, then real children are recursed, then
  this tag's own pseudos are inserted (before at index 0, after appended). }
procedure TLayoutEngine.InjectPseudo(Tag: THTMLTag);
var
  i: Integer;
  c, pb, pa: THTMLTag;
  kids: TList<THTMLTag>;
  edecls: TCSSDeclarations;
  spec: string;
  pushed, setPushed: TStringList;
  isElem: Boolean;
begin
  if Tag = nil then Exit;
  // strip previously-injected pseudo children. THTMLTag.Destroy self-detaches
  // from its parent's Children (Parent.Children.Remove), so Free already removes
  // it from this list — an extra Delete(i) would double-remove (out of range).
  // A ::first-letter synth first hands its letter back to the text it sliced,
  // so the split does not compound across rebuilds.
  for i := Tag.Children.Count - 1 downto 0 do
    if Tag.Children[i].TagName.StartsWith('tina4::') then
    begin
      if (Tag.Children[i].TagName = 'tina4::first-letter') and
         (Tag.Children[i].FLetterSrc <> nil) and (Tag.Children[i].Children.Count > 0) then
        Tag.Children[i].FLetterSrc.Text :=
          Tag.Children[i].Children[0].Text + Tag.Children[i].FLetterSrc.Text;
      Tag.Children[i].Free;
    end;

  isElem := (Tag.TagName <> '#text') and (Tag.TagName <> 'root');
  pushed := nil;

  // Element-level counter-reset / -increment, applied in document order before
  // this element's ::before and children (only for pages that use counters, so
  // the extra per-element match is never paid on a plain ::before page).
  if isElem and (FSheet <> nil) and FSheet.HasCounters then
  begin
    edecls := TCSSDeclarations.Create;
    try
      FSheet.ApplyTo(Tag, edecls);
      if edecls.TryGetValue('counter-reset', spec) then pushed := CounterApplyReset(spec);
      if edecls.TryGetValue('counter-set', spec) then
      begin
        setPushed := CounterApplySet(spec);
        if pushed = nil then pushed := setPushed
        else begin pushed.AddStrings(setPushed); setPushed.Free; end;
      end;
      if edecls.TryGetValue('counter-increment', spec) then CounterApplyIncrement(spec);
    finally
      edecls.Free;
    end;
  end;

  // ::before — generated at the start of the element's content
  if isElem then
  begin
    pb := PseudoTag(Tag, 'before');
    if pb <> nil then Tag.Children.Insert(0, pb);
  end;

  // recurse real children in document order (pseudos already present are skipped)
  kids := TList<THTMLTag>.Create;
  try
    for c in Tag.Children do kids.Add(c);
    for c in kids do
      if (c.TagName <> '#text') and not c.TagName.StartsWith('tina4::') then
        InjectPseudo(c);
  finally
    kids.Free;
  end;

  // ::after, then release the counters this element reset (scope ends)
  if isElem then
  begin
    pa := PseudoTag(Tag, 'after');
    if pa <> nil then Tag.Children.Add(pa);
    if pushed <> nil then begin CounterPop(pushed); pushed.Free; end;
    // ::first-letter last: children are already recursed (their strip phase ran),
    // so the synth we insert into a descendant survives until the next rebuild.
    if (FSheet <> nil) and FSheet.HasFirstLetter then InjectFirstLetter(Tag);
  end;
end;

function TLayoutEngine.FontStylesOf(const St: TComputedStyle): TTina4FontStyles;
var td: string;
begin
  Result := [];
  if St.Bold then Include(Result, tfsBold);
  if St.Italic then Include(Result, tfsItalic);
  if St.SmallCaps then Include(Result, tfsSmallCaps);   // layout-level marker
  if St.FontStretch < 0.9 then Include(Result, tfsStretchC)      // font-stretch condensed
  else if St.FontStretch > 1.1 then Include(Result, tfsStretchE); // expanded
  td := LowerCase(St.TextDecoration);
  if Pos('underline', td) > 0 then Include(Result, tfsUnderline);
  if Pos('line-through', td) > 0 then Include(Result, tfsStrike);
  if Pos('overline', td) > 0 then Include(Result, tfsOverline);
end;

function DecorStyleByte(const S: string): Byte;
begin
  if SameText(S, 'double') then Result := 1
  else if SameText(S, 'dotted') then Result := 2
  else if SameText(S, 'dashed') then Result := 3
  else if SameText(S, 'wavy') then Result := 4
  else Result := 0;   // solid
end;

{ Fill a run/item's hand-painted decoration fields from a style. Only a
  non-solid decoration style or a decoration-color distinct from the text
  colour needs manual painting; the plain solid case stays on the cheap
  font-drawn underline/strike, so FS is left untouched and Lines stays 0. }
procedure TLayoutEngine.ComputeDecor(const St: TComputedStyle;
  var FS: TTina4FontStyles; out Lines, Sty: Byte; out Col: TTina4Color;
  out Th, Off: Single);
var td: string;
begin
  Lines := 0; Th := St.UnderThickness; Off := St.UnderOffset;
  Sty := DecorStyleByte(St.TextDecorationStyle);
  Col := St.TextDecorationColor;
  // font-drawn path only when nothing needs hand painting — a non-solid style, a
  // distinct colour, or a custom thickness / underline-offset all force it.
  if (Sty = 0) and (Col = 0) and (St.UnderThickness <= 0) and (St.UnderOffset = 0) then Exit;
  td := LowerCase(St.TextDecoration);
  if Pos('underline', td) > 0 then Lines := Lines or 1;
  if Pos('line-through', td) > 0 then Lines := Lines or 2;
  if Pos('overline', td) > 0 then Lines := Lines or 4;
  if Lines = 0 then begin Sty := 0; Col := 0; Th := 0; Off := 0; Exit; end;  // style/thickness but no line
  Exclude(FS, tfsUnderline); Exclude(FS, tfsStrike); Exclude(FS, tfsOverline);
end;

function TLayoutEngine.LineHeightOf(const St: TComputedStyle): Single;
begin
  // LineHeight is stored by the CSS parser as a unitless multiple of the
  // element's font-size (px/rem/% are all normalised to that at parse time), so
  // it is ALWAYS multiplied back out here. The old ">4 means absolute px"
  // heuristic mis-read a legitimate large multiple — e.g. line-height:80px at a
  // 16px font is stored as 5.0 — as a 5px line, which collapsed a tall box's
  // line and top-aligned text that should have been vertically centred.
  if St.LineHeight > 0 then
    Result := St.FontSize * St.LineHeight
  else
    Result := St.FontSize * 1.2;
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
    // An inline element's background/padding box is sized by the font's content
    // box (ascent+descent), NOT the author line-height — a `line-height:1.5`
    // ancestor must not inflate a padded <span>/badge. Fall back to the line
    // height only when there is no text metric.
    if m.LineHeight > 0 then Result.H := m.LineHeight + padV
    else Result.H := LineHeightOf(St) + padV;
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
    ComputeDecor(St, run.Styles, run.DecorLines, run.DecorStyle, run.DecorColor, run.DecorThickness, run.DecorOffset);
    Result.Runs.Add(run);
  end;
end;

{ <ruby> stacked annotation: the base text on the baseline with its <rt>
  annotation centred above in a smaller font. Built as one atomic inline box
  (base run + rt run) so it flows inline and reserves space above the line for
  the annotation. <rp> fallback parens are dropped (ruby is supported). The whole
  ruby is treated as one base+annotation pair — correct for a single ruby and for
  a multi-character base under one annotation; per-character pairing isn't split. }
function TLayoutEngine.MakeRubyBox(Tag: THTMLTag; const St: TComputedStyle): TLayoutBox;
var
  c: THTMLTag; baseTxt, rtTxt: string;
  baseFS, rtFS, baseW, rtW, baseH, rtH: Single;
  bm, rm: TTina4TextMetrics;
  run: TTextRun;
begin
  Result := TLayoutBox.Create;
  Result.Tag := Tag; Result.Style := St;
  baseTxt := ''; rtTxt := '';
  for c in Tag.Children do
    if IsTextNode(c) then baseTxt := baseTxt + c.Text
    else if SameText(c.TagName, 'rt') then rtTxt := rtTxt + InnerText(c)
    else if SameText(c.TagName, 'rp') then {skip fallback parens}
    else baseTxt := baseTxt + InnerText(c);
  baseTxt := Trim(CollapseWS(baseTxt));
  rtTxt := Trim(CollapseWS(rtTxt));

  baseFS := St.FontSize;
  rtFS := Max(St.FontSize * 0.5, 7);
  bm := FCanvas.MeasureText(baseTxt, baseFS, FontStylesOf(St));
  rm := FCanvas.MeasureText(rtTxt, rtFS, FontStylesOf(St));
  baseW := bm.Width; rtW := rm.Width;
  baseH := LineHeightOf(St);
  if rtTxt = '' then rtH := 0 else rtH := rtFS * 1.2;   // no annotation ⇒ flows as plain text
  Result.W := Max(baseW, rtW);
  Result.H := rtH + baseH;
  // base baseline measured from the box top (used for inline baseline alignment)
  Result.RubyBaseline := rtH + (baseH - (bm.Ascent + bm.Descent)) / 2 + bm.Ascent;

  if rtTxt <> '' then
  begin
    run.Text := rtTxt; run.X := (Result.W - rtW) / 2; run.Y := (rtH - rtFS) / 2;
    run.FontSize := rtFS; run.Styles := FontStylesOf(St); run.Color := St.Color;
    run.LetterSpacing := 0; run.FontFamily := St.FontFamily; run.FontWeight := St.FontWeight;
    run.ShadowColor := 0; run.ShadowDX := 0; run.ShadowDY := 0;
    run.DecorLines := 0; run.DecorStyle := 0; run.DecorColor := 0; run.DecorThickness := 0; run.DecorOffset := 0;
    Result.Runs.Add(run);
  end;
  if baseTxt <> '' then
  begin
    run.Text := baseTxt; run.X := (Result.W - baseW) / 2;
    run.Y := rtH + (baseH - baseFS) / 2;
    run.FontSize := baseFS; run.Styles := FontStylesOf(St); run.Color := St.Color;
    run.LetterSpacing := St.LetterSpacing; run.FontFamily := St.FontFamily; run.FontWeight := St.FontWeight;
    run.ShadowColor := 0; run.ShadowDX := 0; run.ShadowDY := 0;
    ComputeDecor(St, run.Styles, run.DecorLines, run.DecorStyle, run.DecorColor, run.DecorThickness, run.DecorOffset);
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
  else if SameText(Tag.TagName, 'audio') then Result := ckAudio
  else if typ = 'checkbox' then Result := ckCheckbox
  else if typ = 'radio' then Result := ckRadio
  else if (typ = 'file') or SameText(Tag.TagName, 'camera')
       or SameText(Tag.TagName, 'recorder') then Result := ckFile
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

{ Apply a row-major 4x4 (point as column vector p' = M·p) to a 3D point, with the
  perspective divide when the matrix has a non-affine w row. }
procedure Xform3D(const M: array of Single; x, y, z: Single; out ox, oy, oz: Single);
var w: Single;
begin
  ox := M[0]*x + M[1]*y + M[2]*z + M[3];
  oy := M[4]*x + M[5]*y + M[6]*z + M[7];
  oz := M[8]*x + M[9]*y + M[10]*z + M[11];
  w  := M[12]*x + M[13]*y + M[14]*z + M[15];
  if (Abs(w) > 1e-6) and (Abs(w - 1) > 1e-6) then
  begin ox := ox / w; oy := oy / w; oz := oz / w; end;
end;

{ Resolve a transform-origin component (the <-1.5 = percentage marker) to px. }
function ResolveOrigin(v, extent: Single): Single;
begin
  if v < -1.5 then Result := extent * (-v) / 100 else Result := v;
end;

{ transform-style:preserve-3d — paint the container's children as flat textures
  warped onto their perspective-projected quads in the container's shared 3D
  space (its own transform + the active perspective), z-sorted back-to-front and
  backface-culled. Reuses the single-element layer+quad-warp machinery per face. }
procedure PaintBoxEx(Canvas: TTina4Canvas; Box: TLayoutBox; OffsetY: Single;
  Opacity: Single; Hidden: Boolean); forward;
procedure Paint3DScene(Canvas: TTina4Canvas; Container: TLayoutBox; innerOfs, op: Single; Hidden: Boolean);
var
  n, i, j, layer: Integer;
  ocx, ocy, ocX0, ocY0: Single;                    // container transform-origin (paint coords)
  ci: Integer;
  face: TLayoutBox;
  ofx, ofy, ofX0, ofY0, fyp: Single;               // per-face origin
  corner: Integer;
  cxd, cyd, lx, ly, lz, fxo, fyo, fzo: Single;
  cxr, cyr, czr, oxo, oyo, ozo, absX, absY, depth, scale: Single;
  scr: array[0..7] of Single;                      // face screen corners TL,TR,BR,BL
  e1x, e1y, e2x, e2y, crossz: Single;
  savedT3D: Boolean;
  order: array of Integer;
  avgZ: array of Single;
  corners: array of array of Single;
  tmpI: Integer; tmpZ: Single;
begin
  n := Container.Children.Count;
  if n = 0 then Exit;
  SetLength(order, n); SetLength(avgZ, n); SetLength(corners, n);
  // container transform-origin in paint coords
  ocX0 := ResolveOrigin(Container.Style.TransformOriginX, Container.W);
  ocY0 := ResolveOrigin(Container.Style.TransformOriginY, Container.H);
  ocx := Container.X + ocX0;
  ocy := (Container.Y - innerOfs) + ocY0;
  for ci := 0 to n - 1 do
  begin
    face := Container.Children[ci];
    SetLength(corners[ci], 8);
    order[ci] := ci;
    ofX0 := ResolveOrigin(face.Style.TransformOriginX, face.W);
    ofY0 := ResolveOrigin(face.Style.TransformOriginY, face.H);
    fyp := face.Y - innerOfs;
    ofx := face.X + ofX0; ofy := fyp + ofY0;
    avgZ[ci] := 0;
    for corner := 0 to 3 do
    begin
      case corner of
        0: begin cxd := face.X;          cyd := fyp; end;            // TL
        1: begin cxd := face.X + face.W; cyd := fyp; end;            // TR
        2: begin cxd := face.X + face.W; cyd := fyp + face.H; end;   // BR
      else   begin cxd := face.X;          cyd := fyp + face.H; end; // BL
      end;
      // relative to the face's own transform-origin, then apply the face matrix
      lx := cxd - ofx; ly := cyd - ofy; lz := 0;
      if face.Style.Transform3DSet then Xform3D(face.Style.TransformM3D, lx, ly, lz, fxo, fyo, fzo)
      else begin fxo := lx; fyo := ly; fzo := lz; end;
      // move into the container's origin frame, then apply the container matrix
      cxr := fxo + (ofx - ocx); cyr := fyo + (ofy - ocy); czr := fzo;
      if Container.Style.Transform3DSet then Xform3D(Container.Style.TransformM3D, cxr, cyr, czr, oxo, oyo, ozo)
      else begin oxo := cxr; oyo := cyr; ozo := czr; end;
      // perspective projection about the active perspective origin
      absX := ocx + oxo; absY := ocy + oyo; depth := ozo;
      if (G3DPerspD > 0) and (G3DPerspD - depth > 1) then scale := G3DPerspD / (G3DPerspD - depth)
      else scale := 1;
      scr[corner*2]     := G3DPerspOX + (absX - G3DPerspOX) * scale;
      scr[corner*2 + 1] := G3DPerspOY + (absY - G3DPerspOY) * scale;
      avgZ[ci] := avgZ[ci] + depth;
    end;
    avgZ[ci] := avgZ[ci] / 4;
    for i := 0 to 7 do corners[ci][i] := scr[i];
  end;
  // z-sort back-to-front (smaller depth first — further from the viewer)
  for i := 1 to n - 1 do
  begin
    tmpI := order[i]; j := i;
    while (j > 0) and (avgZ[order[j-1]] > avgZ[tmpI]) do begin order[j] := order[j-1]; Dec(j); end;
    order[j] := tmpI;
  end;
  for i := 0 to n - 1 do
  begin
    ci := order[i];
    face := Container.Children[ci];
    // backface cull: screen winding flips when the face turns away
    e1x := corners[ci][2] - corners[ci][0]; e1y := corners[ci][3] - corners[ci][1];   // TR-TL
    e2x := corners[ci][6] - corners[ci][0]; e2y := corners[ci][7] - corners[ci][1];   // BL-TL
    crossz := e1x*e2y - e1y*e2x;
    if face.Style.BackfaceHidden and (crossz <= 0) then Continue;
    // paint the face flat into a layer, then warp it onto its projected quad
    layer := Canvas.BeginLayer(face.X, face.Y - innerOfs, face.W, face.H, 0);
    if layer < 0 then Continue;
    savedT3D := face.Style.Transform3DSet;
    face.Style.Transform3DSet := False;   // flat — the transform is in the quad
    PaintBoxEx(Canvas, face, innerOfs, op, Hidden);
    face.Style.Transform3DSet := savedT3D;
    Canvas.EndLayer3D(layer, corners[ci]);
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
        if ((St.BackgroundColor shr 24) = 0) and (not St.BgGradientActive) then St.BackgroundColor := TC_SURFACE;
        if St.Color = TAlphaColors.Black then St.Color := TC_INK;
        if St.BorderRadius < 0 then St.BorderRadius := TC_RADIUS;
      end;
    ckButton, ckFile:
      begin
        // a CSS background gradient on the control wins over the UA default fill
        if ((St.BackgroundColor shr 24) = 0) and (not St.BgGradientActive) then
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
    // Focus: keep the border WIDTH (no layout shift / bounce) — only recolour it
    // to the accent — and add an outside focus ring as a zero-blur spread shadow
    // (like a browser's box-shadow focus ring), which never affects layout.
    St.SetBorderColor(TC_ACCENT);
    if St.BoxShadowCount < Length(St.BoxShadows) then
    begin
      St.BoxShadows[St.BoxShadowCount].OffsetX := 0;
      St.BoxShadows[St.BoxShadowCount].OffsetY := 0;
      St.BoxShadows[St.BoxShadowCount].BlurRadius := 0;
      St.BoxShadows[St.BoxShadowCount].SpreadRadius := 3;
      St.BoxShadows[St.BoxShadowCount].Color := (TC_ACCENT and $00FFFFFF) or $40000000; // 25% accent ring
      St.BoxShadows[St.BoxShadowCount].Inset := False;
      St.BoxShadows[St.BoxShadowCount].Active := True;
      Inc(St.BoxShadowCount);
    end;
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
        // native 16px glyph (matches a browser's default control); at least as
        // tall as the text line box so it centres against the label.
        Result.W := 16;
        Result.H := Max(16, lineH);
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
        if SameText(Tag.TagName, 'recorder') then
        begin
          // stateful: ⏹ Stop while armed, 🎙 <file> once captured, else 🎙 Record
          if Tag.HasAttribute('recording') then txt := #$E2#$8F#$B9' Stop'          // ⏹
          else if txt <> '' then txt := #$F0#$9F#$8E#$99' ' + ExtractFileName(txt)   // 🎙 file
          else txt := #$F0#$9F#$8E#$99' Record';                                     // 🎙
        end
        else if txt <> '' then txt := #$F0#$9F#$93#$8E' ' + ExtractFileName(txt)
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
    ckAudio:
      begin
        // <audio controls>: an engine-drawn play/pause bar (PaintAudioControl).
        // The shell owns playback; a bare <audio> (no controls) is display:none.
        ew := ResolveSize(St.ExplicitWidth, AvailW);
        if ew >= 0 then Result.W := ew else Result.W := Min(300, AvailW);
        Result.H := ResolveSize(St.ExplicitHeight, 0);
        if Result.H < 0 then Result.H := 54;
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
    // shrink-to-fit = text + padding + border (CSS), no extra fudge
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
      run.FontWeight := St.FontWeight; run.ShadowColor := 0; run.ShadowDX := 0; run.ShadowDY := 0;
    ComputeDecor(St, run.Styles, run.DecorLines, run.DecorStyle, run.DecorColor, run.DecorThickness, run.DecorOffset);
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
    ComputeDecor(St, run.Styles, run.DecorLines, run.DecorStyle, run.DecorColor, run.DecorThickness, run.DecorOffset);
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
    ComputeDecor(St, run.Styles, run.DecorLines, run.DecorStyle, run.DecorColor, run.DecorThickness, run.DecorOffset);
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

{ Reverse the column (block-progression) order of a vertical writing-mode box's
  content in place. The vertical-rl paint rotates content 90° CW, so the first
  laid-out column (fy=0) lands rightmost — that is `vertical-rl`. For
  `vertical-lr` the columns must read left-to-right, so each line is reflected
  about the content's vertical centre before that same rotation runs: line k
  (top-to-bottom) trades places with line N-1-k, its glyphs untouched. A run's
  Y is the text top — line top plus the half-leading — so the line box is
  reflected and the half-leading (derived from the first line, so glyphs keep
  their place inside the line box) is re-added; reflecting the raw Y instead
  would flip the half-leading to the wrong side and shift every column. A child
  box reflects by its own height and its whole subtree moves with it. CTop is
  the content top, Extent the column-axis span (the block extent the lines used). }
procedure ReverseVColumns(B: TLayoutBox; CTop, Extent, LineH: Single);
var
  i: Integer;
  r: TTextRun;
  ch: TLayoutBox;
  halfLead, lineTop: Single;
begin
  halfLead := 1.0e30;                       // offset of text within its line box
  for i := 0 to B.Runs.Count - 1 do
    if B.Runs[i].Y - CTop < halfLead then halfLead := B.Runs[i].Y - CTop;
  if halfLead > 1.0e29 then halfLead := 0;  // no runs
  for i := 0 to B.Runs.Count - 1 do
  begin
    r := B.Runs[i];
    lineTop := r.Y - halfLead;
    r.Y := (CTop + (Extent - LineH) - (lineTop - CTop)) + halfLead;
    B.Runs[i] := r;
  end;
  for i := 0 to B.Children.Count - 1 do
  begin
    ch := B.Children[i];
    ShiftBoxTree(ch, 0, (CTop + (Extent - ch.H) - (ch.Y - CTop)) - ch.Y);
  end;
end;

{ Full inner layout for an inline-block CONTAINER (block children, explicit
  width) — e.g. side-by-side panels. Built at origin, shifted by FlushLine. }
function TLayoutEngine.MakeInlineContainer(Tag: THTMLTag; const St: TComputedStyle;
  AvailW: Single): TLayoutBox;
var
  edgeL, edgeT, edgeR, edgeB, w, usedH, eh, savedCH: Single;
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
  // resolve this box's definite height first, expose it as the containing height
  // so children resolve height:NN% against it (see LayoutBlock for the rationale)
  eh := ResolveSize(St.ExplicitHeight, FContainingH);
  savedCH := FContainingH;
  if eh >= 0 then
  begin
    if SameText(St.BoxSizing, 'border-box') then FContainingH := Max(0, eh - edgeT - edgeB)
    else FContainingH := eh;
  end
  else FContainingH := -1;
  if SameText(Tag.TagName, 'lottie') or SameText(Tag.TagName, 'canvas') then
    usedH := 0
  else
    LayoutChildren(Result, Tag, St, edgeL, edgeT, Result.W - edgeL - edgeR, usedH);
  FContainingH := savedCH;
  if eh >= 0 then
  begin
    if SameText(St.BoxSizing, 'border-box') then usedH := Max(0, eh - edgeT - edgeB)
    else usedH := eh;
  end
  // aspect-ratio with an auto height: derive the height from the width (the same
  // rule LayoutBlock applies, but for a flex/inline-block item like a media box)
  else if (St.AspectRatio > 0) and (Result.W > 0) then
    usedH := Max(usedH, Max(0, Result.W / St.AspectRatio - edgeT - edgeB));
  Result.H := usedH + edgeT + edgeB;
end;

{ Build a flex/grid item box that is ITSELF a flex/grid container, so its own
  display is honoured (a card in a grid still centres its label). LayoutFlex/Grid
  create + parent the box themselves, so we catch it under a throwaway parent and
  extract it; the outer flex then ShiftBoxTree's it into place. Laid out at the
  origin. `d` is the lower-cased display. }
function TLayoutEngine.MakeContainerBox(Tag: THTMLTag; const ParentStyle: TComputedStyle;
  AvailW: Single; const d: string; ForceH: Single = -1): TLayoutBox;
var tmp: TLayoutBox;
begin
  Result := nil;
  tmp := TLayoutBox.Create;
  try
    if (d = 'flex') or (d = 'inline-flex') then LayoutFlex(tmp, Tag, ParentStyle, 0, 0, AvailW, ForceH)
    else if SameText(Tag.TagName, 'table') or (d = 'table') or (d = 'inline-table') then
      // a table flex/grid item keeps its internal table formatting (rows→columns),
      // not the inline stacking MakeInlineContainer would give it. LayoutTable uses
      // its Style argument AS the table's own style (unlike LayoutFlex/Grid, which
      // recompute from the parent), so pass the table's computed style — otherwise
      // its width/table-layout come from the flex/grid parent and `width:100%`
      // (and other table properties) are lost.
      LayoutTable(tmp, Tag, TComputedStyle.ForTag(Tag, ParentStyle, FSheet), 0, 0, AvailW)
    else LayoutGrid(tmp, Tag, ParentStyle, 0, 0, AvailW);
    if tmp.Children.Count > 0 then Result := tmp.Children.Extract(tmp.Children[0]);
  finally
    tmp.Free;   // owns no real box now (extracted)
  end;
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
  const ParentStyle: TComputedStyle; X, Y, AvailW: Single;
  ForceContentH: Single = -1): Single;
var
  st, cs: TComputedStyle;
  box, cb, relaid: TLayoutBox;
  items: TObjectList<TLayoutBox>;
  itemTags: TList<THTMLTag>;
  c: THTMLTag;
  ridx: Integer;
  runText: string;   // accumulates a contiguous text run → anonymous flex item
  mL, mR, mT, mB, availInner, ew, eh, mnh: Single;
  edgeL, edgeT, edgeR, edgeB, contentX, contentY, contentW, contentH: Single;
  isCol: Boolean;
  dir, jc, ai, ia: string;
  sumMain, freeMain, curr, gap, crossOff, usedFixed, sumGrow, targetW, autoShare: Single;
  autoCount: Integer;
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
  wrapH: Single;   // column-wrap: the definite height items wrap against
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
  // A reverse main axis moves the main-start to the FAR edge, so justify-content
  // flex-start packs the (already order-reversed) items there — Chrome right-
  // aligns a default row-reverse. Swap the two edge keywords; centre/space-* are
  // symmetric and unaffected.
  if (dir = 'row-reverse') or (dir = 'column-reverse') then
  begin
    if (jc = 'flex-start') or (jc = 'start') then jc := 'flex-end'
    else if (jc = 'flex-end') or (jc = 'end') then jc := 'flex-start';
  end;

  // build flex items. For a row we resolve flex-basis + flex-grow first so
  // items share the free space (the common flex:1 layout); a column keeps
  // each item at content width.
  items := TObjectList<TLayoutBox>.Create(False);
  itemTags := TList<THTMLTag>.Create;
  try
    runText := '';
    for c in Tag.Children do
    begin
      if IsTextNode(c) then begin runText := runText + c.Text; Continue; end;
      cs := TComputedStyle.ForTag(c, st, FSheet);
      if LowerCase(cs.Display) = 'none' then Continue;
      // a contiguous text run before this element is its own anonymous flex item
      if Trim(runText) <> '' then itemTags.Add(MakeAnonTextItem(Tag, runText));
      runText := '';
      itemTags.Add(c);
    end;
    if Trim(runText) <> '' then itemTags.Add(MakeAnonTextItem(Tag, runText));   // trailing run
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
        if (cb = nil) and (IsFlexOrGrid(cs) or SameText(itemTags[i].TagName, 'table')) then  // flex/grid/table item keeps its own formatting
          cb := MakeContainerBox(itemTags[i], st, contentW, LowerCase(cs.Display));
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
        else if (cs.FlexBasis <> -1) and (ResolveSize(cs.FlexBasis, contentW) >= 0) then
        begin
          // flex-basis is the item's base main size (content-box), taking
          // precedence over width — px OR a percentage of the container (`25%`).
          // auto (-1) falls through to width / content.
          baseW[i] := ResolveSize(cs.FlexBasis, contentW);
          if not SameText(cs.BoxSizing, 'border-box') then
            baseW[i] := baseW[i] + cs.Padding.Horz + cs.BorderWidths.Horz;
        end
        else if ew >= 0 then
        begin
          if not SameText(cs.BoxSizing, 'border-box') then
            ew := ew + cs.Padding.Horz + cs.BorderWidths.Horz;
          baseW[i] := ew;
        end
        else if growF[i] > 0 then
          baseW[i] := 0                        // flex-grow with basis:auto → 0 base
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
        // shrink FIRST: on overflow, items shrink even when they also flex-grow
        // (grow only ever adds positive free space, which overflow has none of).
        if (overflowMain > 0) and (scaledShrink > 0) and (shrinkF[i] > 0) then
        begin
          targetW := baseW[i] - overflowMain * (shrinkF[i] * baseW[i]) / scaledShrink;
          if targetW < 0 then targetW := 0;
        end
        // grow only when NOT wrapping (wrapped items keep their base size)
        else if (growF[i] > 0) and (sumGrow > 0) and
           not ((LowerCase(st.FlexWrap) = 'wrap') or (LowerCase(st.FlexWrap) = 'wrap-reverse')) then
          targetW := targetW + freeMain * growF[i] / sumGrow;
        cs.ExplicitWidth := targetW;    // force the resolved main size
        cs.BoxSizing := 'border-box';
        cb := MakeReplacedBox(itemTags[i], cs, contentW);
        if (cb = nil) and IsFormControlTag(itemTags[i].TagName) then
          cb := MakeControl(itemTags[i], cs, contentW)   // control, not a box
        // item is itself a flex/grid container AND was NOT grown/shrunk (so
        // LayoutFlex's natural size matches the flex main size) → honour its display.
        // Pass targetW (the item's flex basis) as the available width so a width-less
        // flex item stays content-sized instead of filling the row like a block.
        else if (cb = nil) and (SameText(itemTags[i].TagName, 'table') or
                (IsFlexOrGrid(cs) and (targetW = baseW[i]))) then
          cb := MakeContainerBox(itemTags[i], st, targetW, LowerCase(cs.Display))
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
      for i := 0 to items.Count - 1 do contentH := contentH + items[i].H;
      // include the row-gaps between stacked items — items are POSITIONED with
      // them (curr += cb.H + flexGap), so omitting them left the container short
      // and the last item overflowed (clipped) its box.
      if items.Count > 1 then contentH := contentH + flexGap * (items.Count - 1);
    end
    else
    begin
      contentH := 0;
      for i := 0 to items.Count - 1 do contentH := Max(contentH, items[i].H);
    end;
    // the definite content-height a column wraps against (before contentH grows
    // to the content sum below) — column-wrap needs it, and only works with one.
    if eh >= 0 then
    begin
      if SameText(st.BoxSizing, 'border-box') then wrapH := Max(0, eh - edgeT - edgeB)
      else wrapH := eh;
    end
    else wrapH := -1;
    if eh >= 0 then
    begin
      if SameText(st.BoxSizing, 'border-box') then contentH := Max(contentH, eh - edgeT - edgeB)
      else contentH := Max(contentH, eh);
    end;
    // min-height grows the container's main/cross extent too — without this a
    // `min-height` column flex stays at content height, so flex-grow children get
    // no free space and align-items:center has nothing to centre within (content
    // sticks to the top). Mirrors the block path's min-height clamp.
    mnh := ResolveSize(st.MinHeight, 0);
    if mnh >= 0 then
    begin
      if SameText(st.BoxSizing, 'border-box') then contentH := Max(contentH, mnh - edgeT - edgeB)
      else contentH := Max(contentH, mnh);
    end;
    // a flex-grow item is re-laid-out by its parent at its final content height so
    // its own align-items/justify-content can centre against that height (see the
    // column re-flow pass below). ForceContentH is that definite content height.
    if ForceContentH >= 0 then contentH := Max(contentH, ForceContentH);

    // flex-wrap (column): pack items down each column until the definite height
    // is exceeded, then stack columns across the cross (horizontal) axis — the
    // mirror of the row-wrap pass below (main=vertical, cross=horizontal). Needs
    // a definite height; without one a column can't wrap.
    fw := LowerCase(st.FlexWrap);
    if isCol and (wrapH >= 0) and ((fw = 'wrap') or (fw = 'wrap-reverse')) then
    begin
      // pass 1: column boundaries; lineHA[] holds each column's WIDTH (max item W)
      SetLength(lineStartA, 0); SetLength(lineEndA, 0); SetLength(lineHA, 0);
      i := 0;
      while i < items.Count do
      begin
        lineW := 0; lineEnd := i;            // lineW accumulates HEIGHT down the column
        while (lineEnd < items.Count) and
              ((lineEnd = i) or
               (lineW + flexGap + items[lineEnd].H <= wrapH + 0.5)) do
        begin
          if lineEnd > i then lineW := lineW + flexGap;
          lineW := lineW + items[lineEnd].H;
          Inc(lineEnd);
        end;
        lineH := 0;
        for k := i to lineEnd - 1 do lineH := Max(lineH, items[k].W);   // column width
        nlines := Length(lineHA);
        SetLength(lineStartA, nlines + 1); SetLength(lineEndA, nlines + 1); SetLength(lineHA, nlines + 1);
        lineStartA[nlines] := i; lineEndA[nlines] := lineEnd; lineHA[nlines] := lineH;
        i := lineEnd;
      end;
      nlines := Length(lineHA);
      totalH := 0;                            // total WIDTH of all columns
      for k := 0 to nlines - 1 do totalH := totalH + lineHA[k];
      totalH := totalH + flexGap * Max(0, nlines - 1);
      crossAvail := contentW; if crossAvail < totalH then crossAvail := totalH;
      freeCross := crossAvail - totalH;
      ac := LowerCase(st.AlignContent); if ac = '' then ac := 'stretch';
      startY := contentX; lineGap := flexGap;   // startY = starting X (cross axis)
      if freeCross > 0 then
      begin
        if ac = 'center' then startY := startY + freeCross / 2
        else if (ac = 'flex-end') or (ac = 'end') then startY := startY + freeCross
        else if (ac = 'space-between') and (nlines > 1) then lineGap := flexGap + freeCross / (nlines - 1)
        else if (ac = 'space-around') and (nlines > 0) then
        begin startY := startY + freeCross / (nlines * 2); lineGap := flexGap + freeCross / nlines; end;
      end;
      lineY := startY;                          // running X across columns
      for li := 0 to nlines - 1 do
      begin
        if fw = 'wrap-reverse' then
        begin
          crossOff := startY;
          for k := 0 to nlines - 1 do
            if k > li then crossOff := crossOff + lineHA[k] + lineGap;
        end
        else crossOff := lineY;                 // this column's X
        lineFree := wrapH; for k := lineStartA[li] to lineEndA[li] - 1 do lineFree := lineFree - items[k].H;
        lineFree := lineFree - flexGap * Max(0, (lineEndA[li] - lineStartA[li]) - 1);
        if lineFree < 0 then lineFree := 0;
        lx := 0; lgap := 0;                      // running Y within the column
        if jc = 'center' then lx := lineFree / 2
        else if (jc = 'flex-end') or (jc = 'end') then lx := lineFree
        else if (jc = 'space-between') and (lineEndA[li] - lineStartA[li] > 1) then lgap := lineFree / (lineEndA[li] - lineStartA[li] - 1)
        else if (jc = 'space-around') and (lineEndA[li] - lineStartA[li] > 0) then
        begin lx := lineFree / ((lineEndA[li] - lineStartA[li]) * 2); lgap := lineFree / (lineEndA[li] - lineStartA[li]); end;
        for k := lineStartA[li] to lineEndA[li] - 1 do
        begin
          cb := items[k];
          if (ai = 'stretch') and not crossFixed[k] and (cb.W < lineHA[li]) then cb.W := lineHA[li];
          if ai = 'center' then ShiftBoxTree(cb, crossOff + (lineHA[li] - cb.W) / 2, contentY + lx)
          else if (ai = 'flex-end') or (ai = 'end') then ShiftBoxTree(cb, crossOff + lineHA[li] - cb.W, contentY + lx)
          else ShiftBoxTree(cb, crossOff, contentY + lx);
          lx := lx + cb.H + lgap + flexGap;
        end;
        lineY := lineY + lineHA[li] + lineGap;
      end;
      box.H := wrapH + edgeT + edgeB;
      Result := box.H + mT + mB;
      Exit;   // finally frees items/itemTags
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
        // per-line grow: within a wrapped line, flex-grow items still fill its
        // free space (CSS resolves grow per flex line, not just single-line).
        sumGrow := 0;
        for k := lineStartA[li] to lineEndA[li] - 1 do sumGrow := sumGrow + items[k].Style.FlexGrow;
        if (sumGrow > 0) and (lineFree > 0) then
        begin
          for k := lineStartA[li] to lineEndA[li] - 1 do
            if items[k].Style.FlexGrow > 0 then
              items[k].W := items[k].W + lineFree * items[k].Style.FlexGrow / sumGrow;
          lineFree := 0;
        end;
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

    // column main axis = height: flex-basis sets the base height (as width does
    // for a row) before grow/shrink distribute the container's content height.
    if isCol then
      for i := 0 to items.Count - 1 do
        if (items[i].Style.FlexBasis <> -1) and (ResolveSize(items[i].Style.FlexBasis, contentH) >= 0) then
          items[i].H := ResolveSize(items[i].Style.FlexBasis, contentH);
    // main-axis packing (single line)
    sumMain := 0;
    for i := 0 to items.Count - 1 do
      if isCol then sumMain := sumMain + items[i].H
      else sumMain := sumMain + items[i].W;
    if isCol then freeMain := contentH - sumMain
    else freeMain := contentW - sumMain;
    freeMain := freeMain - flexGap * Max(0, items.Count - 1);   // reserve gaps
    if freeMain < 0 then freeMain := 0;
    // column: grow (fill) / shrink (overflow) items along the vertical main axis
    // — the row path already resolves this into baseW; do the height analogue.
    if isCol and (contentH > 0) and (items.Count > 0) then
    begin
      sumGrow := 0; scaledShrink := 0;
      for i := 0 to items.Count - 1 do
      begin
        sumGrow := sumGrow + items[i].Style.FlexGrow;
        scaledShrink := scaledShrink + items[i].Style.FlexShrink * items[i].H;
      end;
      overflowMain := sumMain + flexGap * Max(0, items.Count - 1) - contentH;
      if (freeMain > 0) and (sumGrow > 0) then
      begin
        for i := 0 to items.Count - 1 do
          if items[i].Style.FlexGrow > 0 then
            items[i].H := items[i].H + freeMain * items[i].Style.FlexGrow / sumGrow;
        freeMain := 0;
      end
      else if (overflowMain > 0.5) and (scaledShrink > 0) then
        for i := 0 to items.Count - 1 do
          if items[i].Style.FlexShrink > 0 then
          begin
            items[i].H := items[i].H - overflowMain * (items[i].Style.FlexShrink * items[i].H) / scaledShrink;
            if items[i].H < 0 then items[i].H := 0;
          end;
    end;

    // Re-flow grown flex items at their final height. A flex item is laid out at
    // its NATURAL height during item-build; growing its box afterwards leaves the
    // item's own content stuck to the top (align-items:center had no spare height
    // to centre within). Re-lay-out each grown nested flex container with its final
    // content height so its own align/justify re-centre. Grid/block items stack
    // top-down, so they need no re-flow.
    if isCol then
      for i := 0 to items.Count - 1 do
      begin
        cb := items[i];
        if (cb.Tag <> nil) and (cb.Style.FlexGrow > 0)
           and ((LowerCase(cb.Style.Display) = 'flex') or (LowerCase(cb.Style.Display) = 'inline-flex'))
           and (cb.H - cb.Style.Padding.Vert - cb.Style.BorderWidths.Vert > 0) then
        begin
          relaid := MakeContainerBox(cb.Tag, st, cb.W, 'flex',
            cb.H - cb.Style.Padding.Vert - cb.Style.BorderWidths.Vert);
          if relaid <> nil then
          begin
            relaid.W := cb.W;                 // keep the resolved cross-axis width
            ridx := box.Children.IndexOf(cb);
            if ridx >= 0 then box.Children[ridx] := relaid   // Children owns → frees old cb
            else relaid.Free;
            if ridx >= 0 then items[i] := relaid;
          end;
        end;
      end;

    // auto margins on the main axis absorb the free space (margin-left:auto pushes
    // an item to the end) and override justify-content's distribution.
    autoCount := 0;
    for i := 0 to items.Count - 1 do
      if isCol then
      begin
        if items[i].Style.Margin.Top = -1 then Inc(autoCount);
        if items[i].Style.Margin.Bottom = -1 then Inc(autoCount);
      end
      else
      begin
        if items[i].Style.Margin.Left = -1 then Inc(autoCount);
        if items[i].Style.Margin.Right = -1 then Inc(autoCount);
      end;
    autoShare := 0;
    if (autoCount > 0) and (freeMain > 0) then
    begin autoShare := freeMain / autoCount; freeMain := 0; end;   // consumed; none left for jc

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
        if cb.Style.Margin.Top = -1 then curr := curr + autoShare;   // leading auto margin
        // cross axis = horizontal
        if (ia = 'stretch') and not crossFixed[i] and (cb.W < contentW) then
          cb.W := contentW;                       // stretch: fill the cross axis
        if (ia = 'center') then crossOff := (contentW - cb.W) / 2
        else if (ia = 'flex-end') or (ia = 'end') then crossOff := contentW - cb.W
        else crossOff := 0;
        ShiftBoxTree(cb, contentX + crossOff, contentY + curr);
        curr := curr + cb.H + gap + flexGap;
        if cb.Style.Margin.Bottom = -1 then curr := curr + autoShare;   // trailing auto margin
      end
      else
      begin
        if cb.Style.Margin.Left = -1 then curr := curr + autoShare;   // leading auto margin
        // cross axis = vertical
        if (ia = 'stretch') and not crossFixed[i] and (cb.H < contentH) then
          cb.H := contentH;                       // stretch: equal-height items
        if (ia = 'center') then crossOff := (contentH - cb.H) / 2
        else if (ia = 'flex-end') or (ia = 'end') then crossOff := contentH - cb.H
        else crossOff := 0;
        ShiftBoxTree(cb, contentX + curr, contentY + crossOff);
        curr := curr + cb.W + gap + flexGap;
        if cb.Style.Margin.Right = -1 then curr := curr + autoShare;   // trailing auto margin
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
{ The min track size of a repeat() list item, for auto-fit/auto-fill counting —
  a minmax(min,…) floor or a plain length. 0 when it can't be sized here. }
function GridTrackMin(const Spec: string): Single;
var s: string; c: Integer;
begin
  s := Trim(Spec);
  if LowerCase(s).StartsWith('minmax(') then
  begin
    s := Copy(s, 8, Length(s) - 8);
    c := Pos(',', s); if c > 0 then s := Copy(s, 1, c - 1);
    s := Trim(s);
  end;
  if s.EndsWith('px') then Result := StrToFloatDef(Copy(s, 1, Length(s) - 2), 0)
  else if (s <> '') and CharInSet(s[1], ['0'..'9', '.']) and (not s.EndsWith('%')) and (not s.EndsWith('fr')) then
    Result := StrToFloatDef(s, 0)
  else Result := 0;   // %, fr, auto, content — not countable without more context
end;

function ExpandGridRepeat(const Spec: string; AvailW: Single = 0; Gap: Single = 0): string;
var
  p, depth, comma, close, n, j: Integer;
  head, inner, cntStr, listStr, tail: string;
  minSz: Single;
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
    if LowerCase(cntStr).StartsWith('auto-f') and (AvailW > 0) then
    begin
      // auto-fit / auto-fill: as many tracks of the min size as fit the row
      minSz := GridTrackMin(listStr);
      if minSz > 0 then n := Max(1, Floor((AvailW + Gap) / (minSz + Gap))) else n := 1;
    end
    else n := StrToIntDef(cntStr, 1);
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
  rowGap, colGap, frUnit, fixedSum, frSum, cellW, cellH, colXk, rowYr, defH, jOff, aOff, freeRows: Single;
  jsx, asx: string;   // resolved grid item justify / align (inline / block)
  runText: string;    // contiguous text runs → anonymous grid items
  trackW, trackFr, colX, rowH, rowFr: array of Single;
  trackFixed: array of Boolean;
  rowIsFr: array of Boolean;
  ncols, nrows, i, curRow, curCol, span, k, spanRows, tplRows, ci: Integer;
  colStart, rowStart, rowSpan, autoRow, autoCol: Integer;
  autoRowH: Single;
  toks: TStringArray;
  tk: string;
  iRow, iCol, iSpan, iRowSpan: array of Integer;
  occ: array of array of Boolean;   // cell occupancy for auto-placement
  areaGrid: array of TStringArray;  // grid-template-areas name per cell
  areaR0, areaC0, areaRS, areaCS: Integer;

  procedure ParseColumns(const Spec: string);
  var s: string; t: string; v: Single;
    inner, maxTok: string; mmParts: TArray<string>;
    function TrackLen(const tk: string): Single;   // px / % / 0 for a track length
    var q: string;
    begin
      q := Trim(tk);
      if (q = '') or (q = 'auto') or q.Contains('content') then Exit(0);
      if q.EndsWith('%') then Result := contentW * StrToFloatDef(Copy(q, 1, Length(q) - 1), 0) / 100
      else Result := StrToFloatDef(StringReplace(q, 'px', '', [rfReplaceAll, rfIgnoreCase]), 0);
    end;
  begin
    ncols := 0;
    SetLength(trackFixed, 0); SetLength(trackW, 0); SetLength(trackFr, 0);
    s := Trim(ExpandGridRepeat(Spec, contentW, colGap));
    if s = '' then Exit;
    s := StringReplace(s, ', ', ',', [rfReplaceAll]);   // keep minmax(0, 1fr) one token
    while Pos('  ', s) > 0 do s := StringReplace(s, '  ', ' ', [rfReplaceAll]);
    toks := s.Split([' ']);
    for t in toks do
    begin
      if Trim(t) = '' then Continue;
      SetLength(trackFixed, ncols + 1); SetLength(trackW, ncols + 1); SetLength(trackFr, ncols + 1);
      if t.ToLower.StartsWith('minmax(') then
      begin
        // minmax(min, max): min is the track's floor; max drives sizing — an fr
        // max makes it flexible (floored at min), a length max pins it.
        inner := Copy(t, 8, Length(t) - 7);
        if inner.EndsWith(')') then Delete(inner, Length(inner), 1);
        mmParts := inner.Split([',']);
        if Length(mmParts) >= 1 then trackW[ncols] := TrackLen(mmParts[0]) else trackW[ncols] := 0;
        if Length(mmParts) >= 2 then maxTok := Trim(mmParts[1]) else maxTok := '1fr';
        if maxTok.ToLower.EndsWith('fr') then
        begin
          trackFixed[ncols] := False;
          trackFr[ncols] := StrToFloatDef(Copy(maxTok, 1, Length(maxTok) - 2), 1);
        end
        else
        begin
          trackFixed[ncols] := True; trackFr[ncols] := 0;
          trackW[ncols] := Max(trackW[ncols], TrackLen(maxTok));
        end;
      end
      else if t.EndsWith('fr') then
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
    if not trackFixed[k] then trackW[k] := Max(trackW[k], trackFr[k] * frUnit);  // minmax floor

  // column X positions
  SetLength(colX, ncols);
  colXk := contentX;
  for k := 0 to ncols - 1 do
  begin colX[k] := colXk; colXk := colXk + trackW[k] + colGap; end;

  // collect grid items
  itemTags := TList<THTMLTag>.Create;
  try
    // Text directly inside a grid container is an anonymous grid item (CSS);
    // wrap contiguous text runs like flex does, so `<div style=grid>A</div>`
    // (a leaf grid item with text) renders instead of dropping the text.
    runText := '';
    for c in Tag.Children do
    begin
      if IsTextNode(c) then begin runText := runText + c.Text; Continue; end;
      cs := TComputedStyle.ForTag(c, st, FSheet);
      if LowerCase(cs.Display) = 'none' then Continue;
      if Trim(runText) <> '' then begin itemTags.Add(MakeAnonTextItem(Tag, runText)); runText := ''; end
      else runText := '';
      itemTags.Add(c);
    end;
    if Trim(runText) <> '' then itemTags.Add(MakeAnonTextItem(Tag, runText));

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

      // justify-self (item) / justify-items (container), default stretch. Only an
      // auto-width item stretches to the cell; an explicit width is kept and the
      // item is aligned within the cell at paint (below).
      jsx := cs.JustifySelf; if (jsx = '') or (jsx = 'auto') then jsx := st.JustifyItems;
      if jsx = '' then jsx := 'stretch';
      if (jsx = 'stretch') and (cs.ExplicitWidth = -1) then cs.ExplicitWidth := cellW;
      cs.BoxSizing := 'border-box';
      cb := MakeReplacedBox(itemTags[i], cs, cellW);
      if (cb = nil) and IsFormControlTag(itemTags[i].TagName) then
        cb := MakeControl(itemTags[i], cs, cellW)
      else if (cb = nil) and (IsFlexOrGrid(cs) or SameText(itemTags[i].TagName, 'table')) then
        cb := MakeContainerBox(itemTags[i], st, cellW, LowerCase(cs.Display))  // nested flex/grid/table keeps its formatting
      else if cb = nil then
        cb := MakeInlineContainer(itemTags[i], cs, cellW);
      box.Children.Add(cb);
      // A non-stretch item (justify-items/self center|start|end) shrinks to its
      // content so it can actually be offset within the cell — otherwise a text
      // item fills the track and `place-items:center` has nothing to centre.
      if (jsx <> 'stretch') and (ResolveSize(cs.ExplicitWidth, cellW) < 0) and
         (cb.NaturalW > 0) and (cb.NaturalW < cb.W) then
        cb.W := cb.NaturalW;

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

    // grid-auto-rows: implicit rows (beyond the explicit template, or all rows
    // when there is none) take this track size — a px length or a minmax floor.
    if Trim(st.GridAutoRows) <> '' then
    begin
      autoRowH := GridTrackMin(st.GridAutoRows);
      if autoRowH > 0 then
      begin
        if Trim(st.GridTemplateRows) <> '' then
          tplRows := Length(Trim(st.GridTemplateRows).Split([' '], TStringSplitOptions.ExcludeEmpty))
        else tplRows := 0;
        for k := tplRows to nrows - 1 do rowH[k] := Max(rowH[k], autoRowH);
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
    // align-content: stretch (default) — a definite height taller than the auto
    // rows grows them to fill it, so cells give align-self room to centre/end.
    if (nrows > 0) and (Trim(st.GridTemplateRows) = '') and (Trim(st.GridAutoRows) = '')
       and ((LowerCase(st.AlignContent) = '') or (LowerCase(st.AlignContent) = 'stretch')) then
    begin
      freeRows := contentH - rowGap * Max(0, nrows - 1);
      for k := 0 to nrows - 1 do freeRows := freeRows - rowH[k];
      if freeRows > 0 then
        for k := 0 to nrows - 1 do rowH[k] := rowH[k] + freeRows / nrows;
    end;

    for i := 0 to itemTags.Count - 1 do
    begin
      cb := box.Children[i];
      rowYr := contentY;
      for k := 0 to iRow[i] - 1 do rowYr := rowYr + rowH[k] + rowGap;
      // cell height: one row, or the sum of spanned rows (+ inner gaps)
      cellH := rowGap * (iRowSpan[i] - 1);
      for k := iRow[i] to Min(iRow[i] + iRowSpan[i] - 1, nrows - 1) do cellH := cellH + rowH[k];
      // cell width: spanned columns (+ their gaps)
      cellW := colGap * (iSpan[i] - 1);
      for k := iCol[i] to Min(iCol[i] + iSpan[i] - 1, ncols - 1) do cellW := cellW + trackW[k];
      // align-self (item) / align-items (container), block axis; default stretch
      asx := cb.Style.AlignSelf; if (asx = '') or (asx = 'auto') then asx := st.AlignItems;
      if asx = '' then asx := 'stretch';
      if (asx = 'stretch') and (ResolveSize(cb.Style.ExplicitHeight, 0) < 0) then
      begin
        if cb.H < cellH then
        begin
          // A nested flex/grid that centres its own content laid it out at the
          // shorter content height; now that we stretch it to the taller cell,
          // shift that content down so it stays centred (the tile-with-a-label
          // case: place-items:center in a grid-auto-rows cell).
          if IsFlexOrGrid(cb.Style) and
             ((LowerCase(cb.Style.AlignItems) = 'center') or
              (LowerCase(cb.Style.AlignContent) = 'center')) then
            for ci := 0 to cb.Children.Count - 1 do
              ShiftBoxTree(cb.Children[ci], 0, (cellH - cb.H) / 2);
          cb.H := cellH;
        end;
        aOff := 0;
      end
      else if asx = 'center' then aOff := (cellH - cb.H) / 2
      else if (asx = 'end') or (asx = 'flex-end') or (asx = 'self-end') then aOff := cellH - cb.H
      else aOff := 0;   // start
      // justify (inline axis): resolved earlier as jsx during build
      jsx := cb.Style.JustifySelf; if (jsx = '') or (jsx = 'auto') then jsx := st.JustifyItems;
      if jsx = '' then jsx := 'stretch';
      if jsx = 'center' then jOff := (cellW - cb.W) / 2
      else if (jsx = 'end') or (jsx = 'flex-end') or (jsx = 'self-end') then jOff := cellW - cb.W
      else jOff := 0;   // start / stretch (already filled)
      if jOff < 0 then jOff := 0;
      if aOff < 0 then aOff := 0;
      ShiftBoxTree(cb, colX[iCol[i]] + jOff - cb.X, rowYr + aOff - cb.Y);
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
    DecorLines, DecorStyle: Byte; DecorColor: TTina4Color;
    DecorThickness, DecorOffset: Single;   // text-decoration-thickness / underline-offset
    SpaceBefore: Boolean;
    LineBreak: Boolean;    // <br>
    LeadMargin: Boolean;   // a margin-LEFT spacer (belongs to the NEXT item; carry it on wrap)
  end;

{ Lay out the mixed inline/block children of Tag into Box.
  CX,CY = content origin (absolute), CW = content width. }
procedure TLayoutEngine.LayoutChildren(Box: TLayoutBox; Tag: THTMLTag;
  const ParentStyle: TComputedStyle; CX, CY, CW: Single; out UsedH: Single);
var
  y: Single;
  items: TList<TInlineItem>;
  hyphenIdx: TList<Integer>;  // item indices that are soft-hyphen break points
                              // (render a '-' when one ends a wrapped line)
  bidiForce: TDictionary<Integer, string>;  // item index → 'o'/'i' + 'rtl'/'ltr'
                              // (<bdo> override / <bdi> isolate forced direction)
  pendingSpace: Boolean;   // trailing whitespace carried across inline nodes
  noWrapFlow: Boolean;     // white-space:nowrap → keep inline items on one line
  firstInlineLine: Boolean; // text-indent applies to the first formatted line only
  flHasColor, flUnderline, flStrike, flOverline: Boolean;  // ::first-line overrides
  flColor: TTina4Color;
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
    ComputeDecor(St, qi.Styles, qi.DecorLines, qi.DecorStyle, qi.DecorColor, qi.DecorThickness, qi.DecorOffset);
    qi.SpaceBefore := SpaceBefore and (items.Count > 0); qi.LineBreak := False;
    items.Add(qi);
  end;

  { ---- font-variant: small-caps ---------------------------------------------
    A small-caps run is one atomic inline item (so it wraps like a normal word),
    but at paint time it splits into per-case sub-runs: a maximal run of ASCII
    lowercase letters is UPPERCASED and drawn at SC_SCALE of the font size; every
    other char (real capitals, digits, punctuation, non-ASCII) is drawn full size.
    Both baselines share the line baseline. (Non-ASCII lowercase stays full size —
    a documented degrade; docs/OUTSTANDING.md B.) }
  function U8CharLen(const S: string; P: Integer): Integer;
  begin
    case Ord(S[P]) of
      $00..$7F: Result := 1; $C0..$DF: Result := 2; $E0..$EF: Result := 3;
    else Result := 4; end;
  end;

  function SmallCapsWidth(const T: string; const St: TComputedStyle): Single;
  const SC_SCALE = 0.78;
  var i, cl: Integer; ch, runTxt: string; lower, runLower, started: Boolean; w: Single;
    procedure AddRun(const s: string; isLo: Boolean);
    begin
      if s = '' then Exit;
      if isLo then w := w + FCanvas.MeasureText(UpperCase(s), St.FontSize * SC_SCALE, FontStylesOf(St) - [tfsSmallCaps]).Width
      else       w := w + FCanvas.MeasureText(s, St.FontSize, FontStylesOf(St) - [tfsSmallCaps]).Width;
    end;
  begin
    w := 0; runTxt := ''; runLower := False; started := False;
    FCanvas.FontFamily := St.FontFamily; FCanvas.FontWeight := St.FontWeight; FCanvas.LetterSpacing := St.LetterSpacing;
    i := 1;
    while i <= Length(T) do
    begin
      cl := U8CharLen(T, i); ch := Copy(T, i, cl);
      lower := (cl = 1) and (ch >= 'a') and (ch <= 'z');
      if (not started) or (lower = runLower) then begin runTxt := runTxt + ch; runLower := lower; started := True; end
      else begin AddRun(runTxt, runLower); runTxt := ch; runLower := lower; end;
      i := i + cl;
    end;
    AddRun(runTxt, runLower);
    FCanvas.FontFamily := ''; FCanvas.FontWeight := 0; FCanvas.LetterSpacing := 0;
    Result := w;
  end;

  { Paint a small-caps item as per-case sub-runs starting at startX. }
  procedure EmitSmallCapsRuns(const it: TInlineItem; startX, lineTop, maxAscent: Single);
  const SC_SCALE = 0.78;
  var i, cl: Integer; ch, runTxt: string; lower, runLower, started: Boolean; cx: Single;
    procedure Emit(const s: string; isLo: Boolean);
    var r: TTextRun; disp: string; sz: Single; m: TTina4TextMetrics;
    begin
      if s = '' then Exit;
      if isLo then begin disp := UpperCase(s); sz := it.FontSize * SC_SCALE; end
      else       begin disp := s; sz := it.FontSize; end;
      FCanvas.FontFamily := it.FontFamily; FCanvas.FontWeight := it.FontWeight; FCanvas.LetterSpacing := it.LetterSpacing;
      m := FCanvas.MeasureText(disp, sz, it.Styles - [tfsSmallCaps]);
      FCanvas.FontFamily := ''; FCanvas.FontWeight := 0; FCanvas.LetterSpacing := 0;
      r.Text := disp; r.X := cx; r.Y := lineTop + maxAscent - m.Ascent;
      r.FontSize := sz; r.Styles := it.Styles - [tfsSmallCaps]; r.Color := it.Color;
      r.LetterSpacing := it.LetterSpacing; r.FontFamily := it.FontFamily; r.FontWeight := it.FontWeight;
      r.ShadowDX := it.ShadowDX; r.ShadowDY := it.ShadowDY; r.ShadowColor := it.ShadowColor;
      r.DecorLines := it.DecorLines; r.DecorStyle := it.DecorStyle; r.DecorColor := it.DecorColor; r.DecorThickness := it.DecorThickness; r.DecorOffset := it.DecorOffset;
      Box.Runs.Add(r);
      cx := cx + m.Width;
    end;
  begin
    cx := startX; runTxt := ''; runLower := False; started := False;
    i := 1;
    while i <= Length(it.Text) do
    begin
      cl := U8CharLen(it.Text, i); ch := Copy(it.Text, i, cl);
      lower := (cl = 1) and (ch >= 'a') and (ch <= 'z');
      if (not started) or (lower = runLower) then begin runTxt := runTxt + ch; runLower := lower; started := True; end
      else begin Emit(runTxt, runLower); runTxt := ch; runLower := lower; end;
      i := i + cl;
    end;
    Emit(runTxt, runLower);
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
    if St.SmallCaps then ti.W := SmallCapsWidth(W, St);   // composite width of the case-runs
    ti.W := ti.W * StretchFactorOf(FontStylesOf(St));     // font-stretch advance
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
    ComputeDecor(St, ti.Styles, ti.DecorLines, ti.DecorStyle, ti.DecorColor, ti.DecorThickness, ti.DecorOffset);
    ti.SpaceBefore := SpaceBefore and (items.Count > 0);
    ti.LineBreak := False;
    items.Add(ti);
    if St.BidiForce <> '' then       // <bdo>/<bdi> forced direction on this item
    begin
      if St.BidiOverride then bidiForce.AddOrSetValue(items.Count - 1, 'o' + St.BidiForce)
      else bidiForce.AddOrSetValue(items.Count - 1, 'i' + St.BidiForce);
    end;
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
    bi.FontSize := St.FontSize; bi.Styles := []; bi.Color := 0; bi.DecorLines := 0; bi.DecorStyle := 0; bi.DecorColor := 0;
    bi.LetterSpacing := 0; bi.FontFamily := '';
    bi.SpaceBefore := False; bi.LineBreak := True;
    items.Add(bi);
  end;

  { hyphens: manual/auto — split a word at its soft hyphens (U+00AD, UTF-8 C2 AD)
    into fragments, each its own inline item so the wrapper may break between them.
    A fragment that ends a wrapped line renders a trailing '-' (FlushLine, via the
    hyphenIdx set). Fragments that stay together render contiguous with no hyphen.
    'auto' has no dictionary here, so it behaves like 'manual' (breaks only at the
    explicit soft hyphens the author placed). }
  { hyphens:auto — insert soft hyphens (U+00AD) into a plain ASCII word at the
    dictionary hyphenation points, so EmitSoftHyphenWord then breaks it there. }
  function AutoHyphenate(const W: string): string;
  var pts: TBoundArray; i, k: Integer;
  begin
    Result := W;
    if Length(W) < 5 then Exit;
    for i := 1 to Length(W) do
      if not (((W[i] >= 'a') and (W[i] <= 'z')) or ((W[i] >= 'A') and (W[i] <= 'Z'))) then Exit;
    pts := HyphenPoints(W);
    if Length(pts) = 0 then Exit;
    Result := ''; k := 0;
    for i := 1 to Length(W) do
    begin
      Result := Result + W[i];
      if (k <= High(pts)) and (pts[k] = i) then begin Result := Result + #$C2#$AD; Inc(k); end;
    end;
  end;

  procedure EmitSoftHyphenWord(const W: string; const St: TComputedStyle; SpaceBefore: Boolean);
  var p, q: Integer; frag: string; sp, last: Boolean;
  begin
    sp := SpaceBefore; p := 1;
    while p <= Length(W) do
    begin
      q := Pos(#$C2#$AD, W, p);
      if q = 0 then begin frag := Copy(W, p, MaxInt); last := True; p := Length(W) + 1; end
      else begin frag := Copy(W, p, q - p); last := False; p := q + 2; end;  // step past the 2-byte U+00AD
      if frag <> '' then
      begin
        AddTextItem(frag, St, sp);
        if not last then hyphenIdx.Add(items.Count - 1);   // break point → '-' if it ends a line
        sp := False;
      end;
    end;
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
    { A tab advances to the next tab STOP — the next column that is a multiple of
      TabW — not to N literal spaces. Per line so stops reset at each newline and
      columns line up (CSS `tab-size`). Column is counted in characters, exact for
      the monospace text tabs are used with. }
    function ExpandTabStops(const Line: string; TabW: Integer): string;
    var i, col, n: Integer;
    begin
      if TabW < 1 then TabW := 1;
      Result := ''; col := 0;
      for i := 1 to Length(Line) do
        if Line[i] = #9 then
        begin
          n := TabW - (col mod TabW);
          Result := Result + StringOfChar(' ', n); Inc(col, n);
        end
        else begin Result := Result + Line[i]; Inc(col); end;
    end;
  begin
    s := StringReplace(Raw, #13#10, #10, [rfReplaceAll]);
    s := StringReplace(s, #13, #10, [rfReplaceAll]);
    lines := s.Split([#10]);
    for li := 0 to High(lines) do
    begin
      if li > 0 then AddHardBreak(St);
      seg := lines[li];
      // tab-size: expand each tab to the next tab stop (default 8). pre-line/normal
      // collapse the resulting spaces anyway; pre / pre-wrap keep the alignment.
      if Pos(#9, seg) > 0 then seg := ExpandTabStops(seg, St.TabSize);
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

  { Trailing margin-right on an inline/inline-block element becomes a zero-height
    spacer in the flow — the horizontal mirror of the margin-left spacer above,
    so e.g. inline-block chips with margin-right actually sit apart. }
  procedure EmitInlineMarginRight(const MS: TComputedStyle);
  var sp: TInlineItem;
  begin
    if MS.Margin.Right <= 0 then Exit;
    sp.Text := ''; sp.Box := nil; sp.W := MS.Margin.Right; sp.H := 0;
    sp.Ascent := 0; sp.FontAscent := 0; sp.FontSize := MS.FontSize;
    sp.Styles := []; sp.Color := 0; sp.LetterSpacing := 0;
    sp.FontFamily := ''; sp.FontWeight := 400;
    sp.ShadowDX := 0; sp.ShadowDY := 0; sp.ShadowColor := 0;
    sp.DecorLines := 0; sp.DecorStyle := 0; sp.DecorColor := 0;
    sp.DecorThickness := 0; sp.DecorOffset := 0;
    sp.SpaceBefore := False; sp.LineBreak := False;
    sp.LeadMargin := False;   // margin-RIGHT: belongs to the PREVIOUS item, don't carry
    items.Add(sp);
  end;

  procedure GatherInline(T: THTMLTag; const St: TComputedStyle);
  var
    c: THTMLTag;
    cs: TComputedStyle;
    words: TStringList;
    i, qDepth, qPi: Integer;
    it: TInlineItem;
    m: TTina4TextMetrics;
    disp, txt, qrText, wsMode, qOpen, qClose: string;
    qParts: TStringArray;
    anc: THTMLTag;
    leadingSpace: Boolean;
    iw, ih: Single;
  begin
    it.LineBreak := False;
    if SameText(T.TagName, 'br') then
    begin
      it.Text := ''; it.Box := nil; it.W := 0;
      it.H := LineHeightOf(St);
      it.Ascent := it.H;
      it.FontSize := St.FontSize; it.Styles := []; it.Color := 0; it.DecorLines := 0; it.DecorStyle := 0; it.DecorColor := 0;
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
      txt := StripBidiControls(CollapseWS(T.Text));   // drop invisible bidi controls (no tofu)
      // soft hyphen U+00AD (UTF-8 $C2$AD): a break opportunity, invisible unless
      // a line breaks there. With hyphens:none we strip it (no artifact); with
      // manual/auto (the CSS default) it is kept and handled per-word below.
      if (Pos(#$C2#$AD, txt) > 0) and SameText(St.Hyphens, 'none') then
        txt := StringReplace(txt, #$C2#$AD, '', [rfReplaceAll]);
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
          // hyphens:auto — insert dictionary soft hyphens; then the manual path breaks them
          if SameText(St.Hyphens, 'auto') and (Pos(#$C2#$AD, words[i]) = 0) then
            words[i] := AutoHyphenate(words[i]);
          // hyphens: manual/auto — a word carrying soft hyphens becomes a chain of
          // breakable fragments; prefer this to arbitrary char-breaking.
          if (Pos(#$C2#$AD, words[i]) > 0) and not SameText(St.Hyphens, 'none') then
          begin
            EmitSoftHyphenWord(words[i], St, (items.Count > 0) and ((i > 0) or leadingSpace));
            FCanvas.LetterSpacing := St.LetterSpacing;   // restore loop measure context
            FCanvas.FontFamily := St.FontFamily; FCanvas.FontWeight := St.FontWeight;
            Continue;
          end;
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
          if St.SmallCaps then it.W := SmallCapsWidth(words[i], St);   // case-run composite width
          it.W := it.W * StretchFactorOf(FontStylesOf(St));            // font-stretch advance
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
          ComputeDecor(St, it.Styles, it.DecorLines, it.DecorStyle, it.DecorColor, it.DecorThickness, it.DecorOffset);
          it.SpaceBefore := (items.Count > 0) and ((i > 0) or leadingSpace);
          items.Add(it);
          if St.BidiForce <> '' then       // <bdo>/<bdi> forced direction
          begin
            if St.BidiOverride then bidiForce.AddOrSetValue(items.Count - 1, 'o' + St.BidiForce)
            else bidiForce.AddOrSetValue(items.Count - 1, 'i' + St.BidiForce);
          end;
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
    // <bdo> = bidi override (force a direction + reverse chars); <bdi> = isolate
    // (auto-detect its own direction). Both force BidiForce on descendant text.
    if SameText(T.TagName, 'bdo') then
    begin
      cs.BidiForce := LowerCase(T.GetAttribute('dir')); cs.BidiOverride := True;
      if (cs.BidiForce <> 'rtl') and (cs.BidiForce <> 'ltr') then cs.BidiForce := '';
    end
    else if SameText(T.TagName, 'bdi') then
    begin
      cs.BidiOverride := False;
      cs.BidiForce := LowerCase(T.GetAttribute('dir'));
      if (cs.BidiForce <> 'rtl') and (cs.BidiForce <> 'ltr') then   // default/auto
        if FirstStrongRTL(InnerText(T)) then cs.BidiForce := 'rtl' else cs.BidiForce := 'ltr';
    end;
    if cs.Margin.Left > 0 then
    begin // inline margin-left becomes a spacer in the flow
      it.Text := ''; it.Box := nil;
      it.W := cs.Margin.Left; it.H := 0; it.Ascent := 0;
      it.FontSize := cs.FontSize; it.Styles := []; it.DecorLines := 0; it.DecorStyle := 0; it.DecorColor := 0; it.Color := 0;
      it.SpaceBefore := False; it.LineBreak := False;
      it.LeadMargin := True;   // margin-LEFT: belongs to this item, carry it on wrap
      items.Add(it);
    end;
    if SameText(T.TagName, 'ruby') then
    begin
      it.Text := '';
      it.Box := MakeRubyBox(T, cs);
      it.W := it.Box.W; it.H := it.Box.H;
      it.FontSize := cs.FontSize; it.Styles := []; it.DecorLines := 0; it.DecorStyle := 0; it.DecorColor := 0; it.Color := 0;
      it.Ascent := it.Box.RubyBaseline;   // base baseline on the line baseline; rt sits above
      it.SpaceBefore := (items.Count > 0) and pendingSpace;
      pendingSpace := False;
      Box.Children.Add(it.Box);
      items.Add(it);
      EmitInlineMarginRight(cs);
      Exit;
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
      it.FontSize := cs.FontSize; it.Styles := []; it.DecorLines := 0; it.DecorStyle := 0; it.DecorColor := 0;
      it.Ascent := it.Box.H;
      it.SpaceBefore := (items.Count > 0) and pendingSpace;
      pendingSpace := False;
      Box.Children.Add(it.Box);
      items.Add(it);
      EmitInlineMarginRight(cs);
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
      it.FontSize := cs.FontSize; it.Styles := []; it.DecorLines := 0; it.DecorStyle := 0; it.DecorColor := 0;
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
      it.W := it.Box.W;
      it.H := it.Box.H + Max(0, cs.Margin.Top) + Max(0, cs.Margin.Bottom);   // vertical margins join the line box
      it.FontSize := cs.FontSize; it.Styles := []; it.DecorLines := 0; it.DecorStyle := 0; it.DecorColor := 0;
      it.Ascent := Max(0, cs.Margin.Top) + it.Box.H + Max(0, cs.Margin.Bottom);
      it.SpaceBefore := (items.Count > 0) and pendingSpace;
      pendingSpace := False;
      Box.Children.Add(it.Box);
      items.Add(it);
      EmitInlineMarginRight(cs);
      Exit;
    end;
    if IsFormControlTag(T.TagName) then
    begin
      it.Text := '';
      it.Box := MakeControl(T, cs, CW);
      it.W := it.Box.W; it.H := it.Box.H;
      it.FontSize := cs.FontSize; it.Styles := []; it.DecorLines := 0; it.DecorStyle := 0; it.DecorColor := 0;
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
      EmitInlineMarginRight(cs);
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
      it.W := it.Box.W;
      // vertical margins join the line box: they grow the line height (it.H) and
      // sit above/below the baseline (bottom margin edge, the content-less case).
      it.H := it.Box.H + Max(0, cs.Margin.Top) + Max(0, cs.Margin.Bottom);
      it.FontSize := cs.FontSize; it.Styles := []; it.DecorLines := 0; it.DecorStyle := 0; it.DecorColor := 0;
      // baseline of an inline-block WITH text content is its last line's text
      // baseline (CSS); a content-less box (coloured badge) falls to its bottom.
      if it.Box.Runs.Count > 0 then
        it.Ascent := Max(0, cs.Margin.Top) + it.Box.Runs[0].Y
                   + FCanvas.MeasureText('x', cs.FontSize, FontStylesOf(cs)).Ascent
      else
        it.Ascent := Max(0, cs.Margin.Top) + it.Box.H + Max(0, cs.Margin.Bottom);
      it.SpaceBefore := (items.Count > 0) and pendingSpace;
      pendingSpace := False;
      Box.Children.Add(it.Box);
      items.Add(it);
      EmitInlineMarginRight(cs);
      Exit;
    end;
    // <q> gets automatic quotation marks; nested <q> switch to the inner pair,
    // or the pairs from the CSS `quotes` property when set (none => no marks)
    if SameText(T.TagName, 'q') then
    begin
      qDepth := 0; anc := T.Parent;
      while anc <> nil do
      begin
        if SameText(anc.TagName, 'q') then Inc(qDepth);
        anc := anc.Parent;
      end;
      qOpen := ''; qClose := '';
      if SameText(cs.Quotes, 'none') then
      begin
        for c in T.Children do GatherInline(c, cs);   // quotes:none → content only
        Exit;
      end;
      if (cs.Quotes <> '') and not SameText(cs.Quotes, 'auto') then
      begin
        qParts := cs.Quotes.Split([' '], TStringSplitOptions.ExcludeEmpty);
        if Length(qParts) >= 2 then
        begin
          qPi := (qDepth mod (Length(qParts) div 2)) * 2;
          qOpen := StripQuotes(qParts[qPi]); qClose := StripQuotes(qParts[qPi + 1]);
        end;
      end;
      if qOpen = '' then
        if Odd(qDepth) then
        begin qOpen := #$E2#$80#$98; qClose := #$E2#$80#$99; end   // ‘ ’ (inner)
        else
        begin qOpen := #$E2#$80#$9C; qClose := #$E2#$80#$9D; end;  // “ ” (outer)
      AddQuoteWord(qOpen, cs, pendingSpace);
      pendingSpace := False;
      for c in T.Children do GatherInline(c, cs);
      AddQuoteWord(qClose, cs, False);
      Exit;
    end;
    // plain inline (b, i, span, a, small...) — recurse with its style
    for c in T.Children do
      GatherInline(c, cs);
  end;

  { UBA reordering of one line's items (logical → visual). Assigns each item a
    resolved level (base from `direction`; R/numbers/neutrals per a per-item
    simplification of the W/N/I rules) and applies the L2 reversal. A no-op for a
    pure-LTR line, so LTR content is untouched. }
  procedure BidiReorder(li: TList<Integer>);
  var
    n, i, j, lvl, maxLvl, base, s, e, la, lb: Integer;
    lv, res: array of Integer;
    logical: array of Integer;
    kind: TBidiKind; anyRTL: Boolean; t: Integer; itm: TInlineItem; forceCode: string;
  begin
    n := li.Count;
    if n < 1 then Exit;
    if SameText(ParentStyle.Direction, 'rtl') then base := 1
    else if SameText(ParentStyle.Direction, 'auto') then
    begin
      base := 0;   // first strong character decides (UBA P2/P3)
      for i := 0 to n - 1 do
      begin
        kind := ItemBidiKind(items[li[i]].Text);
        if kind = bkR then begin base := 1; Break; end
        else if kind = bkL then Break;
      end;
    end
    else base := 0;
    SetLength(lv, n);
    anyRTL := (base = 1);
    for i := 0 to n - 1 do
    begin
      // <bdo>/<bdi> force this item's direction, overriding its content
      if bidiForce.TryGetValue(li[i], forceCode) then
      begin
        if Copy(forceCode, 2, 3) = 'ltr' then         // 'o'/'i' + 'ltr' → force even level
        begin
          if Odd(base) then lv[i] := base + 1 else lv[i] := base;
        end
        else                                          // ...'rtl' → force odd level
        begin
          if Odd(base) then lv[i] := base else lv[i] := base + 1;
          anyRTL := True;
          if forceCode[1] = 'o' then   // <bdo> override: reverse + mirror the glyphs
          begin
            itm := items[li[i]]; itm.Text := MirrorNeutralRTL(itm.Text); items[li[i]] := itm;
          end;
        end;
        Continue;
      end;
      kind := ItemBidiKind(items[li[i]].Text);
      case kind of
        bkR: begin if Odd(base) then lv[i] := base else lv[i] := base + 1; anyRTL := True; end;
        bkL:        if Odd(base) then lv[i] := base + 1 else lv[i] := base;
        bkEN, bkAN: if Odd(base) then lv[i] := base + 1 else lv[i] := base;   // numbers read LTR
      else lv[i] := -1;   // neutral — resolved from neighbours below
      end;
    end;
    if not anyRTL then Exit;   // pure-LTR line: fast path, no reordering
    for i := 0 to n - 1 do
      if lv[i] < 0 then
      begin
        la := base; for j := i - 1 downto 0 do if lv[j] >= 0 then begin la := lv[j]; Break; end;
        lb := base; for j := i + 1 to n - 1 do if lv[j] >= 0 then begin lb := lv[j]; Break; end;
        if la = lb then lv[i] := la else lv[i] := base;   // N1/N2 (simplified)
      end;
    // L4 mirroring: a pure-punctuation item that resolved to an RTL (odd) level
    // paints reversed + mirrored. Strong-char items are left for the backend.
    for i := 0 to n - 1 do
      if Odd(lv[i]) and (not bidiForce.ContainsKey(li[i]))
         and (ItemBidiKind(items[li[i]].Text) = bkNeutral) then
      begin
        itm := items[li[i]]; itm.Text := MirrorNeutralRTL(itm.Text); items[li[i]] := itm;
      end;
    // L2: reverse a permutation mapping over runs with level >= lvl, highest first
    SetLength(res, n); for i := 0 to n - 1 do res[i] := i;
    maxLvl := base; for i := 0 to n - 1 do if lv[i] > maxLvl then maxLvl := lv[i];
    for lvl := maxLvl downto 1 do
    begin
      i := 0;
      while i < n do
        if lv[i] >= lvl then
        begin
          s := i; while (i < n) and (lv[i] >= lvl) do Inc(i); e := i - 1;
          while s < e do begin t := res[s]; res[s] := res[e]; res[e] := t; Inc(s); Dec(e); end;
        end
        else Inc(i);
    end;
    SetLength(logical, n); for i := 0 to n - 1 do logical[i] := li[i];
    for i := 0 to n - 1 do li[i] := logical[res[i]];
    // Spaces are neutrals that belong to word boundaries, not to a fixed item, so
    // reversing runs drops them. Re-derive: every visual boundary between two
    // words carries one space (the common prose case); the first item has none.
    for i := 0 to n - 1 do
    begin
      itm := items[li[i]];
      itm.SpaceBefore := (i > 0) and (itm.Box = nil) and (itm.Text <> '')
        and (items[li[i - 1]].Box = nil) and (items[li[i - 1]].Text <> '');
      items[li[i]] := itm;
    end;
  end;

  procedure FlushLine(startIdx: Integer; var lineItems: TList<Integer>;
    lineTop, lineH: Single; justify: Boolean = False; isLast: Boolean = False);
  var
    idx, k: Integer;
    lineW, xShift, x, maxAscent, gapExtra, flx0, flx1, availW, mt: Single;
    gaps: Integer;
    it: TInlineItem;
    run: TTextRun;
    r: TTextRun;
    j: Integer;
    effAlign: TTextAlign;
    tal: string;
    wasFirstLine: Boolean;
  begin
    if lineItems.Count = 0 then Exit;
    // hyphens: if the last item on this line is a soft-hyphen break point, the
    // line broke there — render the trailing '-'. (Fragments that stayed together
    // never end a line on a break point, so they show no hyphen.)
    idx := lineItems[lineItems.Count - 1];
    if hyphenIdx.IndexOf(idx) >= 0 then
    begin
      it := items[idx];
      FCanvas.FontFamily := it.FontFamily; FCanvas.FontWeight := it.FontWeight;
      FCanvas.LetterSpacing := it.LetterSpacing;
      it.W := it.W + FCanvas.MeasureText('-', it.FontSize, it.Styles).Width;
      FCanvas.FontFamily := ''; FCanvas.FontWeight := 0; FCanvas.LetterSpacing := 0;
      it.Text := it.Text + '-';
      items[idx] := it;
      hyphenIdx.Remove(idx);   // idempotent if FlushLine ever revisits
    end;
    // bidi: reorder this line's items from logical to visual order (no-op for LTR)
    BidiReorder(lineItems);
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
    // direction:rtl makes the block's default (start) alignment right — an
    // explicit text-align still wins. Full bidi (mixed-direction inline runs,
    // mirrored punctuation) is out of scope; this covers the common RTL block.
    effAlign := ParentStyle.TextAlign;
    if (ParentStyle.Direction = 'rtl') and (not ParentStyle.TextAlignSet) and
       (effAlign = TTextAlign.Leading) then
      effAlign := TTextAlign.Trailing;
    tal := ParentStyle.TextAlignLast;
    if isLast and (tal <> '') and (tal <> 'auto') then
    begin
      if tal = 'center' then effAlign := TTextAlign.Center
      else if (tal = 'right') or (tal = 'end') then effAlign := TTextAlign.Trailing
      else if (tal = 'left') or (tal = 'start') then effAlign := TTextAlign.Leading
      else if tal = 'justify' then begin effAlign := TTextAlign.Leading; justify := True; end;
    end;
    case effAlign of
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
      if (it.Box <> nil) and (SameText(it.Box.Style.VerticalAlign, 'top') or
         SameText(it.Box.Style.VerticalAlign, 'text-top') or
         SameText(it.Box.Style.VerticalAlign, 'bottom') or
         SameText(it.Box.Style.VerticalAlign, 'text-bottom')) then Continue;
      if it.Ascent > maxAscent then maxAscent := it.Ascent;
    end;
    x := flx0 + xShift;
    // ::first-line applies to this line only when it is the block's first
    wasFirstLine := firstInlineLine;
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
        // the box's own top margin offsets it below the margin-box top that
        // it.H / it.Ascent (which include the vertical margins) reserve for it.
        mt := Max(0, it.Box.Style.Margin.Top);
        if SameText(it.Box.Style.VerticalAlign, 'top') or
           SameText(it.Box.Style.VerticalAlign, 'text-top') then
          // top / text-top: box top at the line's top (text-top ignores half-leading)
          ShiftBoxTree(it.Box, x, lineTop + mt)
        else if SameText(it.Box.Style.VerticalAlign, 'bottom') or
                SameText(it.Box.Style.VerticalAlign, 'text-bottom') then
          // bottom / text-bottom: margin box bottom at the line's bottom
          ShiftBoxTree(it.Box, x, lineTop + Max(0, lineH - it.H) + mt)
        else if SameText(it.Box.Style.VerticalAlign, 'middle') then
          // centre the margin box within the line box (matches browsers for the
          // common case of same-height inline-blocks filling the line)
          ShiftBoxTree(it.Box, x, lineTop + (lineH - it.H) / 2 + mt)
        else // baseline: margin box bottom on the baseline
          ShiftBoxTree(it.Box, x, lineTop + maxAscent - it.Ascent + mt);
      end
      else if (tfsSmallCaps in it.Styles) and (it.Text <> '') then
        // font-variant:small-caps — paint per-case sub-runs; x advances by it.W below
        EmitSmallCapsRuns(it, x, lineTop, maxAscent)
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
        run.DecorLines := it.DecorLines; run.DecorStyle := it.DecorStyle; run.DecorColor := it.DecorColor; run.DecorThickness := it.DecorThickness; run.DecorOffset := it.DecorOffset;
        // ::first-line — recolour / decorate the first line's runs (non-metric)
        if wasFirstLine then
        begin
          if flHasColor then run.Color := flColor;
          if flUnderline then Include(run.Styles, tfsUnderline);
          if flStrike then Include(run.Styles, tfsStrike);
          if flOverline then Include(run.Styles, tfsOverline);
        end;
        Box.Runs.Add(run);
      end;
      x := x + it.W;
    end;
    lineItems.Clear;
  end;

  { Simulate wrapping over `items` at width w (no painting) and return the line
    count — used by text-wrap:balance to find the balanced width. }
  function CountLinesAt(w: Single): Integer;
  var j: Integer; cw, sw: Single; it2: TInlineItem;
  begin
    Result := 1; cw := 0;
    for j := 0 to items.Count - 1 do
    begin
      it2 := items[j];
      if it2.LineBreak then begin Inc(Result); cw := 0; Continue; end;
      sw := 0;
      if it2.SpaceBefore and (cw > 0) then
        sw := FCanvas.MeasureText(' ', it2.FontSize, it2.Styles).Width + ParentStyle.WordSpacing;
      if (cw > 0) and (cw + sw + it2.W > w) then begin Inc(Result); cw := it2.W; end
      else cw := cw + sw + it2.W;
    end;
  end;

  procedure FlowInlineItems;
  var
    i, carrySpacer, spIdx, fullLines, bIter: Integer;
    it: TInlineItem;
    curW, lineH, spaceW, lineW, flw0, flw1, balancedW, blo, bhi, bmid: Single;
    lineItems: TList<Integer>;
  begin
    if items.Count = 0 then Exit;
    // text-wrap:balance — find the narrowest width that keeps the full-width line
    // count, so the lines end up roughly even (headings, short paragraphs).
    balancedW := 0;
    if SameText(ParentStyle.TextWrap, 'balance') and (not noWrapFlow) then
    begin
      fullLines := CountLinesAt(CW);
      if (fullLines >= 2) and (fullLines <= 8) then
      begin
        blo := 0; bhi := CW;
        for bIter := 1 to 24 do
        begin
          bmid := (blo + bhi) / 2;
          if CountLinesAt(bmid) <= fullLines then bhi := bmid else blo := bmid;
        end;
        balancedW := bhi;
      end;
    end;
    lineItems := TList<Integer>.Create;
    try
      curW := 0; lineH := 0;
      for i := 0 to items.Count - 1 do
      begin
        it := items[i];
        if it.LineBreak then
        begin // <br> or a preformatted \n: hard break even in nowrap/pre
          FlushLine(i, lineItems, y, Max(lineH, it.H), False, True);  // line before <br> = last of paragraph
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
        // text-wrap:balance caps the usable width to the balanced width
        if (balancedW > 0) and (balancedW < lineW) then lineW := balancedW;
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
               not items[spIdx].LineBreak and items[spIdx].LeadMargin then
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
      FlushLine(items.Count, lineItems, y, lineH, False, True);  // block's last line
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
  flDecls: TCSSDeclarations;
  flVal: string;
begin
  y := CY;
  prevMB := 0;
  hadInline := False;
  pendingSpace := False;
  firstInlineLine := True;
  // ::first-line — collect the non-metric properties (colour + text-decoration
  // line) applied to the block's first formatted line. Font/size changes are
  // deliberately not applied: they would alter line breaking after the fact.
  flHasColor := False; flUnderline := False; flStrike := False; flOverline := False;
  if (FSheet <> nil) and FSheet.HasFirstLine then
  begin
    flDecls := TCSSDeclarations.Create;
    try
      if FSheet.CollectPseudoStyle(Tag, 'first-line', flDecls) then
      begin
        if flDecls.TryGetValue('color', flVal) then
        begin flColor := TComputedStyle.ParseColor(flVal); flHasColor := True; end;
        if flDecls.TryGetValue('text-decoration', flVal) or
           flDecls.TryGetValue('text-decoration-line', flVal) then
        begin
          flVal := LowerCase(flVal);
          flUnderline := Pos('underline', flVal) > 0;
          flStrike := Pos('line-through', flVal) > 0;
          flOverline := Pos('overline', flVal) > 0;
        end;
      end;
    finally
      flDecls.Free;
    end;
  end;
  FloatBase := Length(FFloats); MaxFloatY := CY;   // this container's floats append here
  noWrapFlow := SameText(ParentStyle.WhiteSpace, 'nowrap') or
                SameText(ParentStyle.WhiteSpace, 'pre') or
                SameText(ParentStyle.TextWrap, 'nowrap');
  items := TList<TInlineItem>.Create;
  hyphenIdx := TList<Integer>.Create;
  bidiForce := TDictionary<Integer, string>.Create;
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
        // Replaced elements (img/svg/qrcode) are set up by MakeReplacedBox, which
        // LayoutBlock never calls — so an absolutely-positioned <img> would never
        // load or paint its image. Build it here (nil for ordinary elements, which
        // then take the normal block path).
        absBox := MakeReplacedBox(c, cs, CW);
        if absBox <> nil then
          Box.Children.Add(absBox)
        else
        begin
          LayoutBlock(Box, c, ParentStyle, CX, CY, CW);
          absBox := Box.Children[Box.Children.Count - 1];
        end;
        // left+right both pinned with no explicit width → stretch to fill the gap
        // (CSS: the width resolves to containing-block − left − right). Same for
        // top+bottom → stretch the height. This is what `inset:Npx` relies on.
        if (ResolveSize(cs.ExplicitWidth, CW) < 0) and (cs.CSSLeft > -9998) and (cs.CSSRight > -9998) then
          // stretch across the containing block's PADDING box (content + padding)
          absBox.W := Max(0, (CW + ParentStyle.Padding.Left + ParentStyle.Padding.Right)
                             - cs.CSSLeft - cs.CSSRight)
        // Shrink-to-fit: an out-of-flow box with no explicit width sizes to its
        // content (CSS "shrink-to-fit"), not the full container — e.g. a pill
        // pinned with `right` only should hug its text, not span the row.
        else if (ResolveSize(cs.ExplicitWidth, CW) < 0) and (absBox.NaturalW > 0) then
        begin
          absCH := absBox.NaturalW + cs.Padding.Horz + cs.BorderWidths.Horz;
          if absCH < absBox.W then absBox.W := absCH;
        end;
        if (ResolveSize(cs.ExplicitHeight, 0) < 0) and (cs.CSSTop > -9998) and (cs.CSSBottom > -9998) then
        begin
          absCH := ResolveSize(ParentStyle.ExplicitHeight, 0);
          if absCH < 0 then absCH := Box.NaturalH;
          absBox.H := Max(0, (absCH + ParentStyle.Padding.Top + ParentStyle.Padding.Bottom)
                             - cs.CSSTop - cs.CSSBottom);
        end;
        // fixed is viewport-relative (origin 0,0); absolute is container-relative.
        // Paint (PaintBoxEx) drops the scroll offset for fixed so it stays put.
        if SameText(cs.CSSPosition, 'fixed') then
        begin
          absX := 0; absY := 0;
          if cs.CSSLeft > -9998 then absX := cs.CSSLeft
          else if cs.CSSRight > -9998 then absX := CX + CW - absBox.W - cs.CSSRight;
          if cs.CSSTop > -9998 then absY := cs.CSSTop
          else if cs.CSSBottom > -9998 then          // pin to the viewport bottom
            absY := FViewportH - absBox.H - cs.CSSBottom;
          ShiftBoxTree(absBox, absX - absBox.X, absY - absBox.Y);
          Continue;
        end;
        // An absolute box is positioned against its containing block's PADDING
        // box (CSS), not its content box — so `left:0`/`top:0` sit at the inner
        // border edge, clearing the padding (the common badge-in-a-padded-card
        // pattern). CX/CY/CW are the content box; back out the padding to reach
        // the padding box. Auto left/top keep the static-position approximation.
        absX := CX; absY := CY;
        if cs.CSSLeft > -9998 then absX := (CX - ParentStyle.Padding.Left) + cs.CSSLeft
        else if cs.CSSRight > -9998 then
          absX := (CX + CW + ParentStyle.Padding.Right) - absBox.W - cs.CSSRight;
        if cs.CSSTop > -9998 then absY := (CY - ParentStyle.Padding.Top) + cs.CSSTop
        else if cs.CSSBottom > -9998 then
        begin
          // bottom needs the container content height — use its explicit
          // height (known now via the container's own style)
          absCH := ResolveSize(ParentStyle.ExplicitHeight, 0);
          if absCH < 0 then absCH := Box.NaturalH;
          absY := (CY + absCH + ParentStyle.Padding.Bottom) - absBox.H - cs.CSSBottom;
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
    hyphenIdx.Free;
    bidiForce.Free;
  end;
  // the container encloses its own floats (clearfix-style) so a tall float isn't
  // clipped, then drops them from the active context (they don't escape this BFC)
  if MaxFloatY > y then y := MaxFloatY;
  SetLength(FFloats, FloatBase);
  UsedH := y - CY;
end;

function TLayoutEngine.LayoutColumns(box: TLayoutBox; Tag: THTMLTag;
  const st: TComputedStyle; contentX, contentY, contentW: Single): Single;
var
  ncols, i, k, fcount, segLo, oldIdx: Integer;
  colW, gap, usedH, maxColH, runY: Single;
  flow: array of TLayoutBox;
  childH: array of Single;
  isSpan: array of Boolean;
  hasSpan: Boolean;
  oldBox, newBox: TLayoutBox;
  pos: string;

  { Outer height of a flow child (border box + non-negative vertical margins). }
  function OuterH(b: TLayoutBox): Single;
  begin
    Result := b.H + Max(0, b.Style.Margin.Top) + Max(0, b.Style.Margin.Bottom);
  end;

  { Balance flow[lo..hi-1] into ncols columns starting at topY; shift each into
    its column and return the bottom Y (topY + the tallest column). }
  function BalanceRange(lo, hi: Integer; topY: Single): Single;
  var kk, cc, ac: Integer; tot, tgt, cur, mT, dxb, dyb: Single;
      colBottom: array of Single;
  begin
    if hi <= lo then Exit(topY);
    tot := 0; for kk := lo to hi - 1 do tot := tot + childH[kk];
    tgt := tot / ncols;
    SetLength(colBottom, ncols);
    for cc := 0 to ncols - 1 do colBottom[cc] := topY;
    cur := 0; ac := 0;
    for kk := lo to hi - 1 do
    begin
      mT := Max(0, flow[kk].Style.Margin.Top);
      dxb := (contentX + ac * (colW + gap)) - (flow[kk].X - Max(0, flow[kk].Style.Margin.Left));
      dyb := (colBottom[ac] + mT) - flow[kk].Y;
      ShiftBoxTree(flow[kk], dxb, dyb);
      colBottom[ac] := colBottom[ac] + childH[kk];
      cur := cur + childH[kk];
      if (ac < ncols - 1) and (cur >= tgt * (ac + 1)) then Inc(ac);
    end;
    Result := topY;
    for cc := 0 to ncols - 1 do if colBottom[cc] > Result then Result := colBottom[cc];
  end;

  { A plain multi-line text paragraph the balancer may split BETWEEN lines
    (no border / background / vertical padding / nested boxes to break). }
  function Fragmentable(ch: TLayoutBox): Boolean;
  begin
    Result := (ch.Tag <> nil) and (ch.Runs.Count >= 2) and (ch.Children.Count = 0)
      and (ch.Style.BorderWidths.Top < 0.5) and (ch.Style.BorderWidths.Bottom < 0.5)
      and (ch.Style.BorderWidths.Left < 0.5) and (ch.Style.BorderWidths.Right < 0.5)
      and ((ch.Style.BackgroundColor shr 24) = 0)
      and (ch.Style.Padding.Top < 0.5) and (ch.Style.Padding.Bottom < 0.5)
      and (LowerCase(ch.Style.CSSPosition) <> 'absolute')
      and (LowerCase(ch.Style.CSSPosition) <> 'fixed')
      and (LowerCase(ch.Style.ColumnSpan) <> 'all') and (ch.H > 1);
  end;

  { Line-level fragmentation: replace each fragmentable paragraph in box.Children
    with one anonymous box per text line, so BalanceRange distributes LINES across
    columns (a tall paragraph then flows across the column break like Chrome). }
  procedure FragmentChildren;
  var i, li, ri, nlines, idx: Integer; ch, lb: TLayoutBox;
      lineY: array of Single; lineBox: array of TLayoutBox;
      r: TTextRun; lineH, tmp: Single; found: Boolean;
  begin
    i := 0;
    while i < box.Children.Count do
    begin
      ch := box.Children[i];
      if not Fragmentable(ch) then begin Inc(i); Continue; end;
      // distinct line Y values
      SetLength(lineY, 0);
      for ri := 0 to ch.Runs.Count - 1 do
      begin
        r := ch.Runs[ri]; found := False;
        for li := 0 to High(lineY) do
          if Abs(lineY[li] - r.Y) < r.FontSize * 0.5 then begin found := True; Break; end;
        if not found then begin SetLength(lineY, Length(lineY) + 1); lineY[High(lineY)] := r.Y; end;
      end;
      nlines := Length(lineY);
      if nlines < 2 then begin Inc(i); Continue; end;
      for li := 0 to nlines - 2 do   // sort ascending (small n, bubble)
        for ri := 0 to nlines - 2 - li do
          if lineY[ri] > lineY[ri + 1] then
          begin tmp := lineY[ri]; lineY[ri] := lineY[ri + 1]; lineY[ri + 1] := tmp; end;
      SetLength(lineBox, nlines);
      for li := 0 to nlines - 1 do
      begin
        lb := TLayoutBox.Create;
        lb.Style := ch.Style;
        if li > 0 then lb.Style.Margin.Top := 0;            // interior lines carry no margin
        if li < nlines - 1 then lb.Style.Margin.Bottom := 0;
        lb.Tag := nil;
        lb.X := ch.X; lb.W := ch.W;
        // tile the child at the midpoints between consecutive lines so the boxes
        // cover [ch.Y .. ch.Y+ch.H] exactly and each run keeps its position
        if li = 0 then lb.Y := ch.Y
        else lb.Y := (lineY[li - 1] + lineY[li]) / 2;
        if li = nlines - 1 then lb.H := (ch.Y + ch.H) - lb.Y
        else lb.H := (lineY[li] + lineY[li + 1]) / 2 - lb.Y;
        lineBox[li] := lb;
      end;
      for ri := 0 to ch.Runs.Count - 1 do
      begin
        r := ch.Runs[ri]; idx := 0;
        for li := 1 to nlines - 1 do
          if Abs(lineY[li] - r.Y) < Abs(lineY[idx] - r.Y) then idx := li;
        lineBox[idx].Runs.Add(r);
      end;
      box.Children.Extract(ch);                 // detach without freeing its children
      for li := 0 to nlines - 1 do box.Children.Insert(i + li, lineBox[li]);
      ch.Free;                                  // runs were copied out
      Inc(i, nlines);
    end;
  end;

begin
  gap := st.ColGap; if gap < 0 then gap := 0;
  if st.ColumnCount > 0 then ncols := st.ColumnCount
  else if st.ColumnWidth > 0 then
    ncols := Max(1, Floor((contentW + gap) / (st.ColumnWidth + gap)))
  else ncols := 1;
  if ncols < 1 then ncols := 1;
  colW := (contentW - gap * (ncols - 1)) / ncols;
  if colW < 1 then colW := 1;

  // lay every child into a single column of the reduced width
  usedH := 0;
  LayoutChildren(box, Tag, st, contentX, contentY, colW, usedH);
  if (ncols = 1) or (box.Children.Count = 0) then Exit(usedH);

  // line-level fragmentation: split plain paragraphs into per-line boxes so a
  // tall paragraph flows across the column break (not balanced as one unit)
  FragmentChildren;

  // collect in-flow children (absolutely-positioned / fixed ones stay put)
  SetLength(flow, box.Children.Count);
  fcount := 0;
  for i := 0 to box.Children.Count - 1 do
  begin
    pos := LowerCase(box.Children[i].Style.CSSPosition);
    if (pos = 'absolute') or (pos = 'fixed') then Continue;
    flow[fcount] := box.Children[i]; Inc(fcount);
  end;
  if fcount = 0 then Exit(usedH);
  SetLength(flow, fcount);

  // column-span:all — a child that breaks out to span every column. Re-lay each
  // spanning child at the full content width (it was laid out at colW), then
  // balance the runs of ordinary children between spanning ones as segments.
  SetLength(isSpan, fcount);
  hasSpan := False;
  for k := 0 to fcount - 1 do
  begin
    isSpan[k] := (LowerCase(flow[k].Style.ColumnSpan) = 'all');
    if isSpan[k] then hasSpan := True;
  end;
  if hasSpan then
    for k := 0 to fcount - 1 do
      if isSpan[k] and (flow[k].Tag <> nil) then
      begin
        oldBox := flow[k];
        oldIdx := box.Children.IndexOf(oldBox);
        LayoutBlock(box, oldBox.Tag, st, contentX, contentY, contentW);  // appends the wide box
        newBox := box.Children[box.Children.Count - 1];
        box.Children.Extract(newBox);           // detach without freeing
        if oldIdx >= 0 then box.Children[oldIdx] := newBox;   // frees the old colW box, stores the wide one
        flow[k] := newBox;
      end;

  // outer height of every flow child (after any re-layout above)
  SetLength(childH, fcount);
  for k := 0 to fcount - 1 do childH[k] := OuterH(flow[k]);

  if not hasSpan then
    maxColH := BalanceRange(0, fcount, contentY) - contentY
  else
  begin
    // segmented: balance each run of ordinary children, place each spanning
    // child full-width between the runs, stacking down the block.
    runY := contentY; segLo := 0;
    for k := 0 to fcount - 1 do
      if isSpan[k] then
      begin
        if k > segLo then runY := BalanceRange(segLo, k, runY);
        ShiftBoxTree(flow[k],
          (contentX + Max(0, flow[k].Style.Margin.Left)) - flow[k].X,
          (runY + Max(0, flow[k].Style.Margin.Top)) - flow[k].Y);
        runY := runY + childH[k];
        segLo := k + 1;
      end;
    if fcount > segLo then runY := BalanceRange(segLo, fcount, runY);
    maxColH := runY - contentY;
  end;

  // record geometry so PaintBoxEx can draw column-rules in the gaps. Store the
  // content origin as an OFFSET from box.X/Y (not absolute) so it survives a
  // later ShiftBoxTree — e.g. this container being positioned as a flex item.
  if (st.ColumnRuleWidth > 0) and (LowerCase(st.ColumnRuleStyle) <> 'none') then
  begin
    box.ColRuleGaps := ncols - 1;
    box.ColRuleColW := colW; box.ColRuleGap := gap;
    box.ColRuleX0 := contentX - box.X; box.ColRuleY0 := contentY - box.Y; box.ColRuleH := maxColH;
  end;
  Result := maxColH;
end;

function TLayoutEngine.LayoutBlock(Parent: TLayoutBox; Tag: THTMLTag;
  const ParentStyle: TComputedStyle; X, Y, AvailW: Single): Single;
var
  st: TComputedStyle;
  box: TLayoutBox;
  contentX, contentY, contentW, usedH: Single;
  edgeL, edgeT, edgeR, edgeB: Single;
  mL, mR, mT, mB, ew, eh, availInner, naturalH, mnw, mxw, mnh, mxh, relDX, relDY: Single;
  savedCH: Single;
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

  // Resolve THIS box's definite content height BEFORE laying out children, and
  // expose it as the containing height so a child's height:NN% resolves against it
  // (CSS: a % height needs a definite containing block; else it's auto).
  eh := ResolveSize(st.ExplicitHeight, FContainingH);
  savedCH := FContainingH;
  if eh >= 0 then
  begin
    if SameText(st.BoxSizing, 'border-box') then FContainingH := Max(0, eh - edgeT - edgeB)
    else FContainingH := eh;
  end
  else FContainingH := -1;
  // writing-mode: vertical-rl with a definite height — lay the inline content out
  // against the HEIGHT (so it wraps into columns), then paint it rotated 90° CW
  // into right-to-left columns (see PaintBoxEx). Needs an explicit height to wrap
  // against; without one it falls through to the flat 90° single-line rotation.
  box.VerticalRL := (eh >= 0)
    and ((Pos('vertical', st.WritingMode) > 0) or (Pos('sideways', st.WritingMode) > 0))
    and (Pos('lr', st.WritingMode) = 0);
  // vertical-lr shares the layout (against the height) and the CW rotation; only
  // the column order differs, reversed after LayoutChildren so columns read L→R.
  box.VerticalLR := (eh >= 0)
    and ((Pos('vertical', st.WritingMode) > 0) or (Pos('sideways', st.WritingMode) > 0))
    and (Pos('lr', st.WritingMode) > 0);
  if box.VerticalRL or box.VerticalLR then contentW := Max(1, FContainingH);  // wrap against the content height
  // CSS multi-column: balance block children across N columns (column-count /
  // column-width / columns). Falls back to normal flow for a single column.
  if ((st.ColumnCount > 0) or (st.ColumnWidth > 0)) and
     not (box.VerticalRL or box.VerticalLR) then
    usedH := LayoutColumns(box, Tag, st, contentX, contentY, contentW)
  else
    LayoutChildren(box, Tag, st, contentX, contentY, contentW, usedH);
  FContainingH := savedCH;
  // width: fit-content / min-content / max-content (the -3 sentinel from
  // ParseLength) → shrink the block to its content width (approximated by
  // NaturalW, the widest laid-out line) instead of filling the container.
  if (st.ExplicitWidth = -3) and (box.NaturalW > 0) then
    box.W := Min(box.W, box.NaturalW + edgeL + edgeR);
  // -webkit-line-clamp: cap the content to N lines and clip the rest — the box
  // becomes a (non-scrolling) clip container. Ellipsis on the clamped line is
  // not synthesised. Its own clip is needed since line-clamp has no explicit
  // height, so the overflow-y block below (gated on eh>=0) doesn't run.
  if (st.LineClamp > 0) and (usedH > st.LineClamp * LineHeightOf(st) + 0.5) then
  begin
    box.MaxScroll := usedH - st.LineClamp * LineHeightOf(st);   // excess → clipped
    box.Scrollable := False;
    usedH := st.LineClamp * LineHeightOf(st);
  end;
  if box.VerticalRL or box.VerticalLR then
  begin
    if box.VerticalLR then
      ReverseVColumns(box, contentY, usedH, LineHeightOf(st));
    box.W := usedH + edgeL + edgeR;   // physical width = content's inline extent (from usedH)
    box.H := eh;                      // physical height = the specified height
    usedH := Max(0, eh - edgeT - edgeB);  // keep the tail's box.H := usedH+edges == eh
  end;
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
  // aspect-ratio: derive the auto axis from the definite one. Width + auto height
  // → height from the ratio (the common media-box case); a definite height with
  // auto width → width from the ratio (the block stops stretching to full width,
  // matching Chrome). Content overflowing is handled as in browsers.
  if (st.AspectRatio > 0) and (ResolveSize(st.ExplicitHeight, 0) < 0) and (box.W > 0) then
    box.H := box.W / st.AspectRatio
  else if (st.AspectRatio > 0) and (ResolveSize(st.ExplicitWidth, contentW) < 0)
       and (ResolveSize(st.ExplicitHeight, 0) >= 0) and (box.H > 0) then
    box.W := box.H * st.AspectRatio;
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
  base.LineHeight := 1.2;    // bootstrap body line-height (CSS normal ~1.2)
  FBaseStyle := base;
  FViewportW := ViewportW;
  SetLength(FFloats, 0);   // fresh float context per layout
  if ViewportH <= 0 then ViewportH := ViewportW * 0.66;   // rough default when unknown
  FViewportH := ViewportH;     // position:fixed bottom/right anchor (stays the viewport)
  FContainingH := ViewportH;   // the initial containing block (viewport) height for height:NN%
  FreeSynthTags;               // discard last layout's anonymous flex-item wrappers
  SetCalcContext(ViewportW, ViewportH);   // vw/vh + reset deferred calc() table
  GAnimSheet := FSheet;                    // @keyframes lookup for paint-time animation
  body := FindBody(Root);
  if body = nil then body := Root;
  // Tier-1 custom elements: expand registered template tags into their markup
  // BEFORE pseudos/layout, idempotently each Build (same pattern as InjectPseudo).
  if HasCustomElements(body) then ExpandCustomElements(body);
  if (FSheet <> nil) and (FSheet.HasPseudo or FSheet.HasCounters) then
  begin
    ResetCounterState;   // counters restart each Build (document-order traversal)
    InjectPseudo(body);
  end;
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

{ Hand-paint a text-decoration line at Y across [X, X+W] in the given style
  (0 solid, 1 double, 2 dotted, 3 dashed, 4 wavy). Used when the decoration
  has a non-default style or a colour distinct from the text, since the
  font-drawn underline only does the plain solid same-colour case. }
procedure PaintDecorLine(Canvas: TTina4Canvas; X, Y, W, Th: Single;
  Sty: Byte; Col: TTina4Color);
var xx, ex, seg, amp, dash: Single; up: Boolean;
begin
  if W <= 0 then Exit;
  case Sty of
    1: begin   // double
         Canvas.FillRect(X, Y - Th, W, Max(1, Th * 0.7), Col);
         Canvas.FillRect(X, Y + Th, W, Max(1, Th * 0.7), Col);
       end;
    2: begin   // dotted
         dash := Max(1, Th); xx := X;
         while xx < X + W do
         begin
           Canvas.FillRect(xx, Y, Min(dash, X + W - xx), dash, Col);
           xx := xx + dash * 2;
         end;
       end;
    3: begin   // dashed
         dash := Max(2, Th * 3); xx := X;
         while xx < X + W do
         begin
           Canvas.FillRect(xx, Y, Min(dash, X + W - xx), Max(1, Th), Col);
           xx := xx + dash * 1.8;
         end;
       end;
    4: begin   // wavy — connected zig-zag segments
         amp := Max(1.2, Th * 1.6);
         seg := Max(2, amp * 1.3);
         xx := X; up := True;
         while xx < X + W do
         begin
           ex := Min(xx + seg, X + W);
           if up then Canvas.DrawLine(xx, Y + amp * 0.5, ex, Y - amp * 0.5, Max(1, Th), Col)
           else Canvas.DrawLine(xx, Y - amp * 0.5, ex, Y + amp * 0.5, Max(1, Th), Col);
           up := not up;
           xx := ex;
         end;
       end;
  else
    Canvas.FillRect(X, Y, W, Max(1, Th), Col);   // solid
  end;
end;

{ Resolve a text-emphasis-style value to its mark glyph (UTF-8). A quoted custom
  string wins; otherwise fill (filled/open) + shape (dot/circle/double-circle/
  triangle/sesame) select the mark. Default shape is a filled circle. }
function EmphasisMark(const Spec: string): string;
var s, q: string; a, b: Integer;
begin
  Result := '';
  if Spec = '' then Exit;
  // custom string: return its content (a single grapheme in practice)
  a := Pos('"', Spec); if a = 0 then a := Pos('''', Spec);
  if a > 0 then
  begin
    q := Copy(Spec, a + 1, Length(Spec));
    b := Pos(Spec[a], q);
    if b > 0 then q := Copy(q, 1, b - 1);
    Result := q; Exit;
  end;
  s := LowerCase(Spec);
  if Pos('open', s) > 0 then
  begin
    if Pos('double-circle', s) > 0 then Result := #$E2#$97#$8E        // ◎ U+25CE
    else if Pos('triangle', s) > 0 then Result := #$E2#$96#$B3        // △ U+25B3
    else if Pos('sesame', s) > 0 then Result := #$EF#$B9#$86          // ﹆ U+FE46
    else if Pos('dot', s) > 0 then Result := #$E2#$97#$A6             // ◦ U+25E6
    else Result := #$E2#$97#$8B;                                     // ○ U+25CB (circle)
  end
  else
  begin
    if Pos('double-circle', s) > 0 then Result := #$E2#$97#$89        // ◉ U+25C9
    else if Pos('triangle', s) > 0 then Result := #$E2#$96#$B2        // ▲ U+25B2
    else if Pos('sesame', s) > 0 then Result := #$EF#$B9#$85          // ﹅ U+FE45
    else if Pos('dot', s) > 0 then Result := #$E2#$80#$A2             // • U+2022
    else Result := #$E2#$97#$8F;                                     // ● U+25CF (circle)
  end;
end;

procedure PaintBox(Canvas: TTina4Canvas; Box: TLayoutBox; OffsetY: Single);
begin
  // start a fresh gather of the selected text for this frame's paint walk
  GSelText := ''; GSelLastY := -1;
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

{ <audio controls>: a light rounded bar with a round play/pause button on the
  left and a progress track. The shell owns playback and pushes state back into
  two attributes read here — 'playing' (present while sounding) and 'progress'
  (0..1 of the clip elapsed). With neither, it paints an idle ready-to-play bar. }
procedure PaintAudioControl(Canvas: TTina4Canvas; Box: TLayoutBox; y: Single);
var
  d, bx, by, cx, cy, tx, tw, ty, frac, gw, gh: Single;
  accent, glyph: TTina4Color;
  playing: Boolean;
  tri: TTina4PointArray;
begin
  accent := AccentOf(Box);
  glyph := $FFFFFFFF;
  playing := Box.Tag.HasAttribute('playing');
  frac := StrToFloatDef(Box.Tag.GetAttribute('progress'), 0);
  if frac < 0 then frac := 0; if frac > 1 then frac := 1;

  // light bar backing
  Canvas.FillRoundRect(Box.X, y, Box.W, Box.H, Min(Box.H / 2, 12), $FFEFF1F4);

  // round button, left, vertically centred
  d := Box.H - 12; if d > 40 then d := 40; if d < 20 then d := 20;
  bx := Box.X + 6; by := y + (Box.H - d) / 2;
  cx := bx + d / 2; cy := by + d / 2;
  Canvas.FillRoundRect(bx, by, d, d, d / 2, accent);
  if playing then
  begin                                   // two pause bars
    gw := d * 0.12; gh := d * 0.36;
    Canvas.FillRect(cx - d * 0.18, cy - gh / 2, gw, gh, glyph);
    Canvas.FillRect(cx + d * 0.06, cy - gh / 2, gw, gh, glyph);
  end
  else
  begin                                   // play triangle (nudged right to look centred)
    SetLength(tri, 3);
    tri[0].X := cx - d * 0.16; tri[0].Y := cy - d * 0.20;
    tri[1].X := cx - d * 0.16; tri[1].Y := cy + d * 0.20;
    tri[2].X := cx + d * 0.22; tri[2].Y := cy;
    Canvas.FillPolygon([tri], glyph);
  end;

  // progress track to the right of the button
  tx := bx + d + 12; tw := Box.X + Box.W - 12 - tx;
  if tw > 8 then
  begin
    ty := y + Box.H / 2 - 2;
    Canvas.FillRoundRect(tx, ty, tw, 4, 2, TC_BORDER);
    if frac > 0 then Canvas.FillRoundRect(tx, ty, tw * frac, 4, 2, accent);
  end;
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
  wT, wR, wB, wL, x0, y0, x1, y1: Single;
  style: string;
  function Quad(ax, ay, bx, by, cx, cy, dx, dy: Single): TTina4PointArray;
  begin
    SetLength(Result, 4);
    Result[0].X:=ax; Result[0].Y:=ay; Result[1].X:=bx; Result[1].Y:=by;
    Result[2].X:=cx; Result[2].Y:=cy; Result[3].X:=dx; Result[3].Y:=dy;
  end;
begin
  wT := st.BorderWidths.Top;    wR := st.BorderWidths.Right;
  wB := st.BorderWidths.Bottom; wL := st.BorderWidths.Left;
  style := LowerCase(st.BorderStyle);
  if style = 'none' then Exit;
  // dashed/dotted/double keep the per-edge stepped painter (no diagonal miters)
  if (style = 'dashed') or (style = 'dotted') or (style = 'double') then
  begin
    if wT > 0 then PaintBorderEdge(Canvas, Box.X, y, Box.W, wT, True, style, ScaleAlpha(st.BorderColors[0], op));
    if wB > 0 then PaintBorderEdge(Canvas, Box.X, y + Box.H - wB, Box.W, wB, True, style, ScaleAlpha(st.BorderColors[2], op));
    if wL > 0 then PaintBorderEdge(Canvas, Box.X, y, wL, Box.H, False, style, ScaleAlpha(st.BorderColors[3], op));
    if wR > 0 then PaintBorderEdge(Canvas, Box.X + Box.W - wR, y, wR, Box.H, False, style, ScaleAlpha(st.BorderColors[1], op));
    Exit;
  end;
  // solid: each side is a TRAPEZOID meeting adjacent sides at a 45° miter, so a
  // 0-size box with thick borders forms the classic CSS triangle/arrow.
  x0 := Box.X; y0 := y; x1 := Box.X + Box.W; y1 := y + Box.H;
  if (wT > 0) and ((st.BorderColors[0] shr 24) > 0) then
    Canvas.FillPolygon([Quad(x0,y0, x1,y0, x1-wR,y0+wT, x0+wL,y0+wT)], ScaleAlpha(st.BorderColors[0], op), False);
  if (wR > 0) and ((st.BorderColors[1] shr 24) > 0) then
    Canvas.FillPolygon([Quad(x1,y0, x1,y1, x1-wR,y1-wB, x1-wR,y0+wT)], ScaleAlpha(st.BorderColors[1], op), False);
  if (wB > 0) and ((st.BorderColors[2] shr 24) > 0) then
    Canvas.FillPolygon([Quad(x0,y1, x1,y1, x1-wR,y1-wB, x0+wL,y1-wB)], ScaleAlpha(st.BorderColors[2], op), False);
  if (wL > 0) and ((st.BorderColors[3] shr 24) > 0) then
    Canvas.FillPolygon([Quad(x0,y0, x0,y1, x0+wL,y1-wB, x0+wL,y0+wT)], ScaleAlpha(st.BorderColors[3], op), False);
end;

{ Paint a box's background-image. Handles background-size cover/contain/auto,
  background-position (px or the left/center/right · top/center/bottom
  percentage sentinels), and background-repeat (default tile vs no-repeat).
  The image comes from the canvas's cached/async LoadImage; if it's not ready
  yet (handle < 0) nothing is drawn and the next relayout retries. }
{ True when overflow (x or y) is hidden/clip — such a box establishes a clip for
  its subtree even if nothing is scrollable. (auto/scroll go through the scroller
  path and set Box.Scrollable.) }
function ClipsOverflow(const st: TComputedStyle): Boolean;
  function H(const s: string): Boolean;
  begin Result := SameText(s, 'hidden') or SameText(s, 'clip'); end;
begin
  Result := H(st.Overflow) or H(st.OverflowX) or H(st.OverflowY);
end;

{ Resolve one corner's border-radius for a box bw×bh: a % (e.g. 50% → circle)
  resolves against the box, a px value passes through. }
function ResolvedCornerR(const st: TComputedStyle; i: Integer; bw, bh: Single): Single;
begin
  if st.BorderRadii[i] < 0 then Exit(0);              // unset
  if st.BorderRadiiPct[i] then Result := st.BorderRadii[i] / 100 * Min(bw, bh)
  else Result := st.BorderRadii[i];
  if Result < 0 then Result := 0;
end;

{ The largest resolved corner radius (used for the uniform fast paths + clips). }
function ResolvedMaxR(const st: TComputedStyle; bw, bh: Single): Single;
var i: Integer; v: Single;
begin
  Result := 0;
  for i := 0 to 3 do begin v := ResolvedCornerR(st, i, bw, bh); if v > Result then Result := v; end;
end;

{ True when all four resolved corners are equal (→ single-radius fast path). }
function ResolvedUniformR(const st: TComputedStyle; bw, bh: Single): Boolean;
var r0: Single;
begin
  r0 := ResolvedCornerR(st, 0, bw, bh);
  Result := SameValue(r0, ResolvedCornerR(st, 1, bw, bh))
        and SameValue(r0, ResolvedCornerR(st, 2, bw, bh))
        and SameValue(r0, ResolvedCornerR(st, 3, bw, bh));
end;

{ Resolve an explicit `background-size` ("W", "W H", "W auto", %s) to device
  pixels. -1 from ValOf means `auto`, which takes the aspect ratio from the
  other axis (both auto → natural size). }
procedure ExplicitBgSize(const Sz: string; iw, ih, boxW, boxH: Single; var dw, dh: Single);
var
  toks: TArray<string>;
  wv, hv: Single;
  function ValOf(const t: string; ref: Single): Single;
  var s: string;
  begin
    s := Trim(t);
    if (s = '') or (s = 'auto') then Exit(-1);
    if (s <> '') and (s[Length(s)] = '%') then
      Result := StrToFloatDef(Copy(s, 1, Length(s) - 1), 0) / 100 * ref
    else if s.EndsWith('px') then Result := StrToFloatDef(Copy(s, 1, Length(s) - 2), ref)
    else Result := StrToFloatDef(s, ref);
  end;
begin
  dw := iw; dh := ih;
  toks := Sz.Split([' '], TStringSplitOptions.ExcludeEmpty);
  if Length(toks) = 0 then Exit;
  wv := ValOf(toks[0], boxW);
  if Length(toks) >= 2 then hv := ValOf(toks[1], boxH) else hv := -1;
  if (wv < 0) and (hv < 0) then Exit;
  if wv < 0 then begin dh := hv; if ih > 0 then dw := iw * (hv / ih); end
  else if hv < 0 then begin dw := wv; if iw > 0 then dh := ih * (wv / iw); end
  else begin dw := wv; dh := hv; end;
end;

procedure PaintBackgroundImage(Canvas: TTina4Canvas; Box: TLayoutBox;
  const st: TComputedStyle; y: Single);
var
  h, bpW, bpH, bi: Integer;
  iw, ih, dw, dh, scale, px, py, tileX, tileY: Single;
  sz, rep, blend: string;
  noRepeat, useBlend: Boolean;
  bgOpaque: TTina4Color;
  imgPix, blendBuf: TTina4Pixels;

  procedure DrawBg(hh: Integer; dx, dy, dww, dhh: Single);
  begin
    if useBlend then Canvas.DrawRGBA(@blendBuf[0], bpW, bpH, dx, dy, dww, dhh)
    else Canvas.DrawImage(hh, dx, dy, dww, dhh);
  end;

begin
  h := Canvas.LoadImage(st.BackgroundImage);
  if h < 0 then Exit;                          // not decoded yet (async) — retry
  if not Canvas.ImageSize(h, iw, ih) then Exit;
  if (iw <= 0) or (ih <= 0) then Exit;
  // background-blend-mode: blend the image against the solid background-colour
  // beneath it, per-pixel in software (BlendRGB) so the result matches Chrome's
  // sRGB blend. Source-over when unset/normal or the image can't be decoded.
  blend := LowerCase(Trim(st.BackgroundBlendMode));
  if blend = 'normal' then blend := '';
  useBlend := False;
  if (blend <> '') and ((st.BackgroundColor shr 24) > 0) and
     Canvas.DecodeImagePixels(st.BackgroundImage, bpW, bpH, imgPix) and
     (bpW > 0) and (bpH > 0) then
  begin
    bgOpaque := st.BackgroundColor or $FF000000;
    SetLength(blendBuf, bpW * bpH);
    for bi := 0 to bpW * bpH - 1 do
      blendBuf[bi] := (imgPix[bi] and $FF000000) or
        (BlendRGB(imgPix[bi] or $FF000000, bgOpaque, blend) and $00FFFFFF);
    useBlend := True;
  end;

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
  end
  else if (sz <> '') and (sz <> 'auto') then
  begin
    // explicit `background-size: W [H]` — lengths absolute, % of the box, `auto`
    // keeps the aspect ratio from the other axis. One value → height auto.
    ExplicitBgSize(sz, iw, ih, Box.W, Box.H, dw, dh);
  end;

  // position: negative sentinel = percentage (center=-50, right/bottom=-100);
  // >= 0 = px offset from the top-left.
  if st.BgPosX < 0 then px := (Box.W - dw) * (-st.BgPosX) / 100 else px := st.BgPosX;
  if st.BgPosY < 0 then py := (Box.H - dh) * (-st.BgPosY) / 100 else py := st.BgPosY;

  rep := LowerCase(Trim(st.BgRepeat));
  noRepeat := (rep = 'no-repeat') or (sz = 'cover') or (sz = 'contain');

  Canvas.ClipRoundRect(Box.X, y, Box.W, Box.H, ResolvedMaxR(st, Box.W, Box.H));   // honour border-radius (incl %)
  if noRepeat then
    DrawBg(h, Box.X + px, y + py, dw, dh)
  else
  begin
    // tile from the positioned origin, back-filling to cover the whole box
    tileY := y + py; while tileY > y do tileY := tileY - dh;
    while tileY < y + Box.H do
    begin
      tileX := Box.X + px; while tileX > Box.X do tileX := tileX - dw;
      while tileX < Box.X + Box.W do
      begin
        DrawBg(h, tileX, tileY, dw, dh);
        tileX := tileX + dw;
      end;
      tileY := tileY + dh;
    end;
  end;
  Canvas.ClearClip;
end;

{ Parse object-position into x/y alignment fractions (0=left/top, 1=right/
  bottom). Keywords (left/right/top/bottom/center) resolve to their axis in any
  order; positional percentages fill x then y; '' / center => 0.5, 0.5. }
procedure ParseObjectPosition(const S: string; out fx, fy: Single);
var
  parts: TArray<string>; i, posIdx: Integer; t: string; fs: TFormatSettings;
begin
  fx := 0.5; fy := 0.5;
  if Trim(S) = '' then Exit;
  fs := DefaultFormatSettings; fs.DecimalSeparator := '.';
  parts := Trim(S).Split([' '], TStringSplitOptions.ExcludeEmpty);
  posIdx := 0;
  for i := 0 to High(parts) do
  begin
    t := parts[i];
    if t = 'left' then fx := 0
    else if t = 'right' then fx := 1
    else if t = 'top' then fy := 0
    else if t = 'bottom' then fy := 1
    else if t = 'center' then Inc(posIdx)
    else if (Length(t) > 0) and (t[Length(t)] = '%') then
    begin
      if posIdx = 0 then fx := StrToFloatDef(Copy(t, 1, Length(t) - 1), 50, fs) / 100
      else fy := StrToFloatDef(Copy(t, 1, Length(t) - 1), 50, fs) / 100;
      Inc(posIdx);
    end
    else Inc(posIdx);   // px / unknown: leave the axis centred, consume a slot
  end;
end;

{ Destination rect for drawing an image of intrinsic IntrW×IntrH into the box
  [BX,BY,BW,BH] under object-fit + object-position. 'fill' (and any unknown)
  stretches to the box; contain/cover/none/scale-down scale uniformly and
  object-position places the result (which may overflow, for cover/none). }
procedure ComputeObjectFitRect(const Fit, Position: string;
  BX, BY, BW, BH: Single; IntrW, IntrH: Single; out DX, DY, DW, DH: Single);
var scale, sContain, fx, fy: Single;
begin
  DX := BX; DY := BY; DW := BW; DH := BH;
  if (IntrW <= 0) or (IntrH <= 0) or (BW <= 0) or (BH <= 0) then Exit;
  if (Fit = '') or (Fit = 'fill') then Exit;   // non-uniform stretch to the box

  sContain := BW / IntrW; if BH / IntrH < sContain then sContain := BH / IntrH;
  if Fit = 'contain' then scale := sContain
  else if Fit = 'cover' then
  begin
    scale := BW / IntrW; if BH / IntrH > scale then scale := BH / IntrH;
  end
  else if Fit = 'none' then scale := 1
  else if Fit = 'scale-down' then
  begin
    scale := sContain; if scale > 1 then scale := 1;
  end
  else Exit;   // unknown keyword: leave as fill

  DW := IntrW * scale; DH := IntrH * scale;
  ParseObjectPosition(Position, fx, fy);
  DX := BX + (BW - DW) * fx;   // free space (negative when the image overflows)
  DY := BY + (BH - DH) * fy;
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
  decCol: TTina4Color; decW, decTh, dbx, dby: Single;
  bcTextRad, bcTextDX, bcTextDenom, bcGX, bcFrac, bcCW: Single;
  bcCi, bcCl: Integer; bcCh: string;
  emMark, emCh: string; emCol: TTina4Color;
  emSize, emX, emY, emCW, emMW: Single; emCi, emCl: Integer;
  rgX, rgY: Single; rgI: Integer;   // resize grip corner
  selCi, selCl: Integer; selRunX, selCW, selBandS, selBandE: Single;   // selection highlight
  upx, upcw: Single; upci, upcl: Integer; upch: string;   // text-orientation:upright per-glyph
  savedPerspD, savedPerspOX, savedPerspOY: Single;   // perspective context save/restore
  stretchF: Single;   // font-stretch horizontal scale for this run
  vAx, vAy, vWc: Single;   // writing-mode:vertical-rl paint frame (top-left + content width)
  vRotSaved: Boolean;      // a vertical-rl content rotation is open (balance the restore)
  wmRot: Single;
  drawTxt: string;
  zorder: array of Integer;
  zi, zj, ztmp, gi: Integer;
  gcol: array of TTina4Color;
  gpos: array of Single;
  bg, bd, fg: TTina4Color;
  bgBlend: Boolean; bgBlendMode: string;
  cv2d: TTina4Canvas2D;
  cvPaint: TCanvasPaintProc;
  elemPaint: TElemPaintProc;   // Tier-2 registered native-element painter
  lot: TTina4Lottie;
  lotF: Double;
  lotTotal, lotFrame, lotFit, lsc: Single;
  lpw, lph: Integer;
  mcr: Single;   // resolved max border-radius (px; % resolved against this box)
  olStyle: string; olw, olx, oly, olrw, olrh: Single;   // dashed/dotted/double outline edges
  shi: Integer;   // box-shadow list index
  ofIW, ofIH: Single;                  // intrinsic image size for object-fit
  ofDX, ofDY, ofDW, ofDH: Single;      // object-fit destination rect
  ofClipped: Boolean;                  // did we set a clip for the fitted image?
  crI: Integer; crX, crTop: Single; crCol: TTina4Color;   // column-rule painting
begin
  st := Box.Style;
  vRotSaved := False;
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
  mcr := ResolvedMaxR(st, Box.W, Box.H);   // border-radius resolved for THIS box (handles %)
  // Retained backing-store cull: on an animation-only frame the shell repaints
  // only the animated region — skip any box (and its subtree) wholly outside it,
  // so the far side of the page costs no draw calls. (Full frames leave this off.)
  if PaintClipActive and
     ((Box.X >= PaintClipX1) or (Box.X + Box.W <= PaintClipX0) or
      (y >= PaintClipY1) or (y + Box.H <= PaintClipY0)) then
    Exit;
  // CSS 3D transform: capture the element into an offscreen layer, then map that
  // texture onto its perspective-projected quad (EndLayer3D). Takes precedence
  // over the 2D transform / filter paths for this element.
  // a preserve-3d container does NOT flatten to one quad — its children are each
  // projected in the shared 3D space (Paint3DScene) once inside a perspective.
  use3D := st.Transform3DSet and not (st.Preserve3D and (G3DPerspD > 0));
  layer3D := -1;
  if use3D then
  begin
    Compute3DCorners(st, Box.X, y, Box.W, Box.H, corners3d);
    layer3D := Canvas.BeginLayer(Box.X, y, Box.W, Box.H, 0);
    if layer3D < 0 then use3D := False;   // no offscreen: fall back to a flat paint
  end;
  // transform: rotate/scale — wrap the subtree paint in a canvas transform
  // about the box centre (default transform-origin)
  // vertical writing-mode: Latin runs (mixed orientation) are set sideways —
  // the whole line rotates 90° clockwise about the box centre. Full block-flow
  // reordering is out of scope; a single centred line reads correctly this way.
  wmRot := 0;
  // vertical-rl with a definite height uses the real column layout (Box.VerticalRL);
  // any other vertical/sideways box keeps the flat single-line 90° rotation.
  if (not Box.VerticalRL) and (not Box.VerticalLR) and
     ((Pos('vertical', st.WritingMode) > 0) or (Pos('sideways', st.WritingMode) > 0)) then
    wmRot := 90;
  hasRS := (not use3D) and ((st.TransformRotate <> 0) or (st.TransformScaleX <> 1) or (st.TransformScaleY <> 1)
    or (st.TransformSkewX <> 0) or (st.TransformSkewY <> 0) or st.TransformMatrixSet
    or (wmRot <> 0) or (st.ClipPath <> ''));
  if hasRS then
  begin
    Canvas.SaveState;
    // pivot at transform-origin (px or %-marker; default 50% 50% = centre)
    if st.TransformOriginX < -1.5 then rcx := Box.X + Box.W * (-st.TransformOriginX) / 100
    else rcx := Box.X + st.TransformOriginX;
    if st.TransformOriginY < -1.5 then rcy := y + Box.H * (-st.TransformOriginY) / 100
    else rcy := y + st.TransformOriginY;
    Canvas.Translate(rcx, rcy);
    if (st.TransformRotate + wmRot) <> 0 then Canvas.Rotate(st.TransformRotate + wmRot); // +deg = CSS clockwise (flipped canvas)
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
    if mcr > 0 then
      Canvas.FillRoundRect(Box.X, y, Box.W, Box.H, mcr, TC_REDACT)
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
      // object-fit: scale the photo uniformly (cover/contain/none/scale-down)
      // inside its box and place it per object-position, instead of stretching.
      ofDX := Box.X; ofDY := y; ofDW := Box.W; ofDH := Box.H;
      if (st.ObjectFit <> '') and (st.ObjectFit <> 'fill') and
         Canvas.ImageSize(Box.ImageHandle, ofIW, ofIH) and (ofIW > 0) and (ofIH > 0) then
        ComputeObjectFitRect(st.ObjectFit, st.ObjectPosition,
          Box.X, y, Box.W, Box.H, ofIW, ofIH, ofDX, ofDY, ofDW, ofDH);
      // border-radius clips to the rounded box; otherwise clip only when the
      // fitted image overflows (cover/none), so contain/fill draw unclipped.
      ofClipped := True;
      if mcr > 0 then
        Canvas.ClipRoundRect(Box.X, y, Box.W, Box.H, mcr)
      else if (ofDX < Box.X - 0.5) or (ofDY < y - 0.5) or
              (ofDX + ofDW > Box.X + Box.W + 0.5) or (ofDY + ofDH > y + Box.H + 0.5) then
        Canvas.ClipRoundRect(Box.X, y, Box.W, Box.H, 0)   // rectangular clip
      else
        ofClipped := False;
      Canvas.DrawImage(Box.ImageHandle, ofDX, ofDY, ofDW, ofDH);
      if ofClipped then Canvas.ClearClip;
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
    gy := y + (Box.H - 16) / 2;
    if Box.ControlKind = ckRadio then
    begin
      Canvas.FillRoundRect(Box.X, gy, 16, 16, 8, $FFFFFFFF);
      if (Box.Tag <> nil) and Box.Tag.HasAttribute('checked') then
      begin
        Canvas.StrokeRoundRect(Box.X, gy, 16, 16, 8, 1, AccentOf(Box));   // accent ring when on
        Canvas.FillRoundRect(Box.X + 4, gy + 4, 8, 8, 4, AccentOf(Box));  // centred dot
      end
      else
        Canvas.StrokeRoundRect(Box.X, gy, 16, 16, 8, 1, TC_BORDER);
    end
    else
    begin
      if (Box.Tag <> nil) and Box.Tag.HasAttribute('checked') then
      begin
        Canvas.FillRoundRect(Box.X, gy, 16, 16, 3, AccentOf(Box));
        Canvas.DrawText(Box.X + 2.5, gy + 0.5, '✓', 12, [tfsBold], $FFFFFFFF);
      end
      else
      begin
        Canvas.FillRoundRect(Box.X, gy, 16, 16, 3, $FFFFFFFF);
        Canvas.StrokeRoundRect(Box.X, gy, 16, 16, 3, 1, TC_BORDER);
      end;
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
  // audio: a light bar with a round play/pause button and a progress track. The
  // shell owns playback; it pushes the played fraction ('progress' attr) and the
  // playing state ('playing' attr), both read here at paint time.
  if (Box.ControlKind = ckAudio) and (Box.Tag <> nil) then
  begin
    PaintAudioControl(Canvas, Box, y);
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

  // box-shadow (drawn under the box). Each comma-separated shadow; the first
  // listed paints ON TOP, so draw the list back-to-front (last index first). A
  // blurred shadow uses the backend blur primitive; a zero-blur one is a hard
  // rounded rect. Follows the box's corner radius so it never peeks past a card.
  if not Hidden then
    for shi := st.BoxShadowCount - 1 downto 0 do
      if not st.BoxShadows[shi].Inset then
        with st.BoxShadows[shi] do
          if BlurRadius > 0 then
            Canvas.FillSoftShadow(
              Box.X + OffsetX - SpreadRadius, y + OffsetY - SpreadRadius,
              Box.W + 2 * SpreadRadius, Box.H + 2 * SpreadRadius,
              mcr, BlurRadius, ScaleAlpha(Color, op))
          else if mcr > 0 then
            Canvas.FillRoundRect(
              Box.X + OffsetX - SpreadRadius, y + OffsetY - SpreadRadius,
              Box.W + 2 * SpreadRadius, Box.H + 2 * SpreadRadius,
              mcr, ScaleAlpha(Color, op))
          else
            Canvas.FillRect(
              Box.X + OffsetX - SpreadRadius, y + OffsetY - SpreadRadius,
              Box.W + 2 * SpreadRadius, Box.H + 2 * SpreadRadius,
              ScaleAlpha(Color, op));

  bg := ScaleAlpha(st.BackgroundColor, op);
  bd := ScaleAlpha(st.BorderColor, op);
  // real gradient background (linear or radial, multi-stop), when no solid
  // background-color covers it. Stops are opacity-scaled; the backend clips to
  // the corner radius and falls back to a flat fill if it can't gradient.
  // background-blend-mode: blend the gradient with the background-color beneath
  // it (needs BOTH a colour and a gradient — the normal path skips the gradient
  // when a solid colour is present, so route through the blend-aware soft path).
  bgBlend := (st.BackgroundBlendMode <> '') and st.BgGradientActive and (st.GradStopCount >= 2) and ((bg shr 24) > 0);
  if (not Hidden) and (not st.BackgroundClipText) and st.BgGradientActive and (st.GradStopCount >= 2) then
  begin
    // Multi-layer / blend: paint the bottom colour layer first, then the
    // gradient over it — so `background: <gradient>, <colour>` shows the colour
    // through a translucent gradient, and the blend-mode case has its backdrop.
    if (bg shr 24) > 0 then
    begin
      if mcr <= 0 then Canvas.FillRect(Box.X, y, Box.W, Box.H, bg)
      else Canvas.FillRoundRect(Box.X, y, Box.W, Box.H, mcr, bg);
    end;
    if bgBlend then bgBlendMode := st.BackgroundBlendMode
    else bgBlendMode := '';
    SetLength(gcol, st.GradStopCount); SetLength(gpos, st.GradStopCount);
    for gi := 0 to st.GradStopCount - 1 do
    begin
      gcol[gi] := ScaleAlpha(st.GradStopColors[gi], op);
      // repeating stripes: stop positions are px within one period → 0..1 within-period
      if st.BgGradientRepeating and (st.BgGradientPeriodPx > 0) and (st.GradStopPosPx[gi] >= 0) then
        gpos[gi] := st.GradStopPosPx[gi] / st.BgGradientPeriodPx
      else
        gpos[gi] := st.GradStopPos[gi];
    end;
    if st.BgGradientConic then
      Canvas.FillGradientSoft(Box.X, y, Box.W, Box.H, mcr, st.BgGradientAngle, 0, 2, gcol, gpos, bgBlendMode, bg)
    else if st.BgGradientRepeating and (st.BgGradientPeriodPx > 0) then
      Canvas.FillGradientSoft(Box.X, y, Box.W, Box.H, mcr, st.BgGradientAngle, st.BgGradientPeriodPx, 0, gcol, gpos, bgBlendMode, bg)
    else if st.BgGradientRadial and not bgBlend then
      Canvas.FillRadialGradient(Box.X, y, Box.W, Box.H, mcr, gcol, gpos)
    else if bgBlend then   // blend needs the soft path (linear; radial approximated as linear)
      Canvas.FillGradientSoft(Box.X, y, Box.W, Box.H, mcr, st.BgGradientAngle, 0, 0, gcol, gpos, bgBlendMode, bg)
    else
      Canvas.FillLinearGradient(Box.X, y, Box.W, Box.H, mcr,
        st.BgGradientAngle, gcol, gpos);
  end
  else if (not Hidden) and (not st.BackgroundClipText) and ((bg shr 24) > 0) then
  begin
    if mcr <= 0 then
      Canvas.FillRect(Box.X, y, Box.W, Box.H, bg)
    else if ResolvedUniformR(st, Box.W, Box.H) then
      Canvas.FillRoundRect(Box.X, y, Box.W, Box.H, mcr, bg)
    else
      // per-corner radius (e.g. 6px 30px 6px 30px): fill the exact rounded polygon
      Canvas.FillPolygon([RoundRectPolygon4(Box.X, y, Box.W, Box.H,
        ResolvedCornerR(st, 0, Box.W, Box.H), ResolvedCornerR(st, 1, Box.W, Box.H),
        ResolvedCornerR(st, 2, Box.W, Box.H), ResolvedCornerR(st, 3, Box.W, Box.H))], bg, False);
  end;
  // background-image: url() — loaded via the cached/async image path, sized by
  // background-size (cover/contain/auto), positioned by background-position,
  // tiled per background-repeat, and clipped to the box.
  if (not Hidden) and (st.BackgroundImage <> '') and (Box.W > 0) and (Box.H > 0) then
    PaintBackgroundImage(Canvas, Box, st, y);
  // inset box-shadows: cast inward from the edges, over the background, under the
  // border/content (CSS paint order); first-listed on top → draw back-to-front.
  if (not Hidden) and (Box.W > 0) and (Box.H > 0) then
    for shi := st.BoxShadowCount - 1 downto 0 do
      if st.BoxShadows[shi].Inset then
        with st.BoxShadows[shi] do
          Canvas.FillInsetShadow(Box.X, y, Box.W, Box.H, mcr,
            OffsetX, OffsetY, BlurRadius, SpreadRadius, ScaleAlpha(Color, op));
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
  // Tier-2 custom element: a registered native element paints itself here, into
  // its content box (clipped, save/restore balanced), through the canvas contract
  // — so it renders on every shell exactly like <canvas>. Registered once via
  // RegisterNativeElement; no core edit per element.
  if (not Hidden) and (Box.Tag <> nil) and (Box.W > 0) and (Box.H > 0) then
  begin
    elemPaint := ElementPaintProc(Box.Tag.TagName);
    if Assigned(elemPaint) then
    begin
      Canvas.SaveState;
      Canvas.SetClip(Box.X, y, Box.W, Box.H);
      try elemPaint(Box.Tag, Box.X, y, Box.W, Box.H, Canvas, st); except end;
      Canvas.ClearClip;
      Canvas.RestoreState;
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
      lotFit := Min(Box.W / lot.Width, Box.H / lot.Height);   // contain-fit + centre
      if Canvas.SupportsRGBA then
      begin
        // Fast path: rasterize every Lottie shape in PURE PASCAL into an in-process
        // ARGB buffer (Tina4RasterCanvas — no OS calls), then hand the shell ONE
        // composited image (DrawRGBA). A rich animation is dozens–hundreds of filled
        // paths; proxying each to the native canvas is one draw call per shape, and
        // on Android every call crosses JNI. This collapses it to a single blit.
        lsc := PaintDeviceScale; if lsc <= 0 then lsc := 1;
        lpw := Max(1, Round(Box.W * lsc)); lph := Max(1, Round(Box.H * lsc));
        if GLottieRaster = nil then GLottieRaster := TTina4RasterCanvas.Create(lpw, lph)
        else GLottieRaster.Resize(lpw, lph);
        GLottieRaster.Clear(0);                    // transparent; blit over the box bg
        cv2d := TTina4Canvas2D.Create(GLottieRaster, Box.W, Box.H, 0);
        try
          cv2d.Scale(lsc, lsc);                    // CSS px → device px (raster space)
          cv2d.Translate((Box.W - lot.Width * lotFit) / 2,
                         (Box.H - lot.Height * lotFit) / 2);
          cv2d.Scale(lotFit, lotFit);
          try lot.Render(cv2d, lotFrame); except end;
        finally cv2d.Free; end;
        Canvas.DrawRGBA(GLottieRaster.Bits, lpw, lph, Box.X, y, Box.W, Box.H);
      end
      else
      begin
        // Fallback: proxy each shape straight to the shell canvas (works everywhere,
        // used by backends that don't implement DrawRGBA yet).
        Canvas.SaveState;
        Canvas.SetClip(Box.X, y, Box.W, Box.H);
        cv2d := TTina4Canvas2D.Create(Canvas, Box.W, Box.H, bg);
        try
          cv2d.Translate(Box.X + (Box.W - lot.Width * lotFit) / 2,
                         y + (Box.H - lot.Height * lotFit) / 2);
          cv2d.Scale(lotFit, lotFit);
          try lot.Render(cv2d, lotFrame); except end;
        finally
          cv2d.Free;
          Canvas.ClearClip;
          Canvas.RestoreState;
        end;
      end;
      AnimMarkRegion(Box.X, y, Box.W, Box.H);   // animate + record region for the backing-store
    end;
  end;
  if (not Hidden) and ((st.BorderWidths.Top > 0) or (st.BorderWidths.Right > 0) or
     (st.BorderWidths.Bottom > 0) or (st.BorderWidths.Left > 0)) then
  begin
    if mcr > 0 then
      // rounded: uniform stroke (per-side / dashed on a rounded box is out of scope)
      Canvas.StrokeRoundRect(Box.X, y, Box.W, Box.H, mcr,
        st.BorderWidths.Top, bd)
    else
      // rectangular: each side with its own width, colour and style
      PaintBorders(Canvas, Box, st, y, op);
  end;
  // resize grip: three diagonal hairlines in the bottom-right corner, like a
  // textarea. CSS only shows it when overflow is not visible.
  if (not Hidden) and (st.Resize <> '') and (st.Resize <> 'none')
     and (st.Overflow <> '') and (st.Overflow <> 'visible') then
  begin
    rgX := Box.X + Box.W - Max(0, st.BorderWidths.Right);
    rgY := y + Box.H - Max(0, st.BorderWidths.Bottom);
    for rgI := 1 to 3 do
      Canvas.DrawLine(rgX - rgI * 4, rgY, rgX, rgY - rgI * 4,
        Max(1, st.FontSize / 18), ScaleAlpha($FF808080, op));
  end;
  // outline: a stroke OUTSIDE the border box, offset by outline-offset. Sits in
  // the margin, doesn't affect layout.
  if (not Hidden) and (st.OutlineWidth > 0)
     and ((st.OutlineColor shr 24) > 0)
     and not SameText(st.OutlineStyle, 'none') then
  begin
    olStyle := LowerCase(st.OutlineStyle);
    if (mcr <= 0) and ((olStyle = 'dashed') or (olStyle = 'dotted') or (olStyle = 'double')) then
    begin
      // rectangular non-solid outline: draw the 4 edges as styled bars (reusing the
      // border edge painter). Rounded dashed/dotted is out of scope → falls to solid.
      olw := st.OutlineWidth;
      olx := Box.X - st.OutlineOffset - olw;
      oly := y - st.OutlineOffset - olw;
      olrw := Box.W + 2 * (st.OutlineOffset + olw);
      olrh := Box.H + 2 * (st.OutlineOffset + olw);
      PaintBorderEdge(Canvas, olx, oly, olrw, olw, True, olStyle, ScaleAlpha(st.OutlineColor, op));                // top
      PaintBorderEdge(Canvas, olx, oly + olrh - olw, olrw, olw, True, olStyle, ScaleAlpha(st.OutlineColor, op));   // bottom
      PaintBorderEdge(Canvas, olx, oly, olw, olrh, False, olStyle, ScaleAlpha(st.OutlineColor, op));              // left
      PaintBorderEdge(Canvas, olx + olrw - olw, oly, olw, olrh, False, olStyle, ScaleAlpha(st.OutlineColor, op)); // right
    end
    else
    begin
      ox := st.OutlineOffset + st.OutlineWidth / 2;
      if mcr > 0 then
        Canvas.StrokeRoundRect(Box.X - ox, y - ox, Box.W + 2 * ox, Box.H + 2 * ox,
          mcr + ox, st.OutlineWidth, ScaleAlpha(st.OutlineColor, op))
      else
        Canvas.StrokeRect(Box.X - ox, y - ox, Box.W + 2 * ox, Box.H + 2 * ox,
          st.OutlineWidth, ScaleAlpha(st.OutlineColor, op));
    end;
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

  // writing-mode:vertical-rl — rotate ONLY the inline content (runs + child boxes)
  // into right-to-left columns; the box background/border above stay upright.
  // 90° CW visual rotation about the content's top-right corner: a laid-out frame
  // point (fx,fy) maps to (A.x + Wc - fy, A.y + fx) — inline fx runs down, the
  // columns fy advance leftward.
  if Box.VerticalRL or Box.VerticalLR then
  begin
    Canvas.SaveState; vRotSaved := True;
    vAx := Box.X + st.BorderWidths.Left + st.Padding.Left;
    vAy := y + st.BorderWidths.Top + st.Padding.Top;
    vWc := Box.W - st.BorderWidths.Horz - st.Padding.Horz;
    Canvas.Translate(vAx + vWc, vAy); Canvas.Rotate(90); Canvas.Translate(-vAx, -vAy);
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
             or ((Box.MaxScrollX > 0) and not Box.ScrollableX)
             // overflow:hidden/clip ALWAYS establishes a clip (CSS), even when nothing
             // scrolls — otherwise an oversized child escapes its box (e.g. a
             // width/height:100% background painting across the whole page).
             or ClipsOverflow(st);
  if didClip then
  begin
    // honour border-radius on the clip: an overflow:hidden rounded box clips its
    // subtree to the rounding (the inner radius, inset by the border width).
    Canvas.ClipRoundRect(Box.X + st.BorderWidths.Left, y + st.BorderWidths.Top,
      Box.W - st.BorderWidths.Horz, Box.H - st.BorderWidths.Vert,
      Max(0, mcr - Max(st.BorderWidths.Left, st.BorderWidths.Top)));
    innerOfs := OffsetY + Box.ScrollTop;
  end;

  // text-overflow: ellipsis — a single non-wrapping line (CSS requires
  // white-space:nowrap). Words are separate runs, so we truncate the run that
  // crosses the content edge, append '…', and drop every run after it.
  ellip := SameText(st.TextOverflow, 'ellipsis') and SameText(st.WhiteSpace, 'nowrap');
  rightEdge := Box.X + Box.W - st.BorderWidths.Right - st.Padding.Right;
  ellipDone := False;
  // background-clip:text — the gradient/solid background is suppressed above and
  // instead painted INTO the glyphs. Precompute the stop arrays once; the run
  // loop colours each glyph by the gradient sample at its position.
  if st.BackgroundClipText and st.BgGradientActive and (st.GradStopCount >= 2) then
  begin
    SetLength(gcol, st.GradStopCount); SetLength(gpos, st.GradStopCount);
    for gi := 0 to st.GradStopCount - 1 do
    begin
      gcol[gi] := st.GradStopColors[gi];
      gpos[gi] := st.GradStopPos[gi];
    end;
  end;
  if not Hidden then
    for i := 0 to Box.Runs.Count - 1 do
    begin
      r := Box.Runs[i];
      drawTxt := r.Text;
      // text selection highlight: paint a blue band behind the selected glyphs
      // (before the text). user-select:none subtrees are never selectable.
      if GSelActive and (st.UserSelect <> 'none') and (drawTxt <> '') then
      begin
        selCi := 1; selRunX := r.X; selBandS := -1; selBandE := -1;
        while selCi <= Length(drawTxt) do
        begin
          selCl := 1;
          while (selCi + selCl <= Length(drawTxt)) and
                ((Ord(drawTxt[selCi + selCl]) and $C0) = $80) do Inc(selCl);
          selCW := Canvas.MeasureText(Copy(drawTxt, selCi, selCl), r.FontSize, r.Styles).Width;
          if GlyphSelected(selRunX + selCW / 2, r.Y + r.FontSize * 0.5, r.FontSize * 0.7) then
          begin
            if selBandS < 0 then selBandS := selRunX;
            selBandE := selRunX + selCW;
            // gather the text (LF between glyphs on different lines)
            if (GSelLastY >= 0) and (Abs(r.Y - GSelLastY) > r.FontSize * 0.5) then
              GSelText := GSelText + #10;
            GSelText := GSelText + Copy(drawTxt, selCi, selCl);
            GSelLastY := r.Y;
          end
          else if selBandS >= 0 then
          begin
            Canvas.FillRect(selBandS - sx, r.Y - innerOfs - r.FontSize * 0.1,
              selBandE - selBandS, r.FontSize * 1.25, ScaleAlpha($663B82F6, op));
            selBandS := -1;
          end;
          selRunX := selRunX + selCW;
          selCi := selCi + selCl;
        end;
        if selBandS >= 0 then
          Canvas.FillRect(selBandS - sx, r.Y - innerOfs - r.FontSize * 0.1,
            selBandE - selBandS, r.FontSize * 1.25, ScaleAlpha($663B82F6, op));
      end;
      // per-glyph gradient fill for background-clip:text (approximates the CSS
      // text mask: each glyph is a solid sample of the gradient at its centre).
      if st.BackgroundClipText and st.BgGradientActive and (st.GradStopCount >= 2)
         and (drawTxt <> '') then
      begin
        Canvas.LetterSpacing := r.LetterSpacing;
        Canvas.FontFamily := r.FontFamily;
        Canvas.FontWeight := r.FontWeight;
        bcTextRad := st.BgGradientAngle * Pi / 180;
        bcTextDX := Sin(bcTextRad);
        bcTextDenom := Abs(bcTextDX) * Box.W + Abs(Cos(bcTextRad)) * Box.H;
        if bcTextDenom <= 0 then bcTextDenom := Box.W;
        bcGX := r.X - sx;
        bcCi := 1;
        while bcCi <= Length(drawTxt) do
        begin
          bcCl := 1;   // group UTF-8 continuation bytes into one glyph
          while (bcCi + bcCl <= Length(drawTxt)) and
                ((Ord(drawTxt[bcCi + bcCl]) and $C0) = $80) do Inc(bcCl);
          bcCh := Copy(drawTxt, bcCi, bcCl);
          bcCW := Canvas.MeasureText(bcCh, r.FontSize, r.Styles).Width;
          bcFrac := 0.5 + (((bcGX - (Box.X - sx)) + bcCW / 2) - Box.W / 2) * bcTextDX / bcTextDenom;
          if bcFrac < 0 then bcFrac := 0 else if bcFrac > 1 then bcFrac := 1;
          Canvas.DrawText(bcGX, r.Y - innerOfs, bcCh, r.FontSize, r.Styles,
            ScaleAlpha(GradSample(bcFrac, gcol, gpos), op));
          bcGX := bcGX + bcCW;
          bcCi := bcCi + bcCl;
        end;
        Canvas.LetterSpacing := 0; Canvas.FontFamily := ''; Canvas.FontWeight := 0;
        Continue;
      end;
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
      // font-stretch: scale the glyphs horizontally about the run's left edge
      stretchF := StretchFactorOf(r.Styles);
      if stretchF <> 1.0 then
      begin
        Canvas.SaveState;
        Canvas.Translate(r.X - sx, 0); Canvas.Scale(stretchF, 1); Canvas.Translate(-(r.X - sx), 0);
      end;
      // text-orientation:upright — in a vertical column, stand each glyph up by
      // counter-rotating it -90° about its own centre (cancelling the column's
      // +90° rotation), so CJK reads top-to-bottom upright instead of on its side.
      if (Box.VerticalRL or Box.VerticalLR) and (st.TextOrientation = 'upright')
         and (drawTxt <> '') then
      begin
        upx := r.X - sx;
        upci := 1;
        while upci <= Length(drawTxt) do
        begin
          upcl := 1;
          while (upci + upcl <= Length(drawTxt)) and
                ((Ord(drawTxt[upci + upcl]) and $C0) = $80) do Inc(upcl);
          upch := Copy(drawTxt, upci, upcl);
          upcw := Canvas.MeasureText(upch, r.FontSize, r.Styles).Width;
          Canvas.SaveState;
          Canvas.Translate(upx + upcw * 0.5, r.Y - innerOfs + r.FontSize * 0.5);
          Canvas.Rotate(-90);
          Canvas.DrawText(-upcw * 0.5, -r.FontSize * 0.5, upch, r.FontSize, r.Styles, fg);
          Canvas.RestoreState;
          upx := upx + upcw;
          upci := upci + upcl;
        end;
      end
      else
      begin
        if (r.ShadowColor shr 24) > 0 then
          Canvas.DrawText(r.X - sx + r.ShadowDX, r.Y - innerOfs + r.ShadowDY, drawTxt,
            r.FontSize, r.Styles, ScaleAlpha(r.ShadowColor, op));
        Canvas.DrawText(r.X - sx, r.Y - innerOfs, drawTxt, r.FontSize, r.Styles, fg);
      end;
      if stretchF <> 1.0 then Canvas.RestoreState;
      // overline: no native font attribute, so rule it by hand across the run,
      // just inside the top of the em box (matches Chrome's placement closely).
      if tfsOverline in r.Styles then
        Canvas.FillRect(r.X - sx, r.Y - innerOfs + r.FontSize * 0.06,
          Canvas.MeasureText(drawTxt, r.FontSize, r.Styles).Width,
          Max(1, r.FontSize / 14), fg);
      // hand-painted decoration (wavy/dotted/dashed/double or a distinct
      // colour): the font underline/strike were suppressed for this run.
      if r.DecorLines <> 0 then
      begin
        if r.DecorColor <> 0 then decCol := ScaleAlpha(r.DecorColor, op)
        else decCol := fg;
        decW := Canvas.MeasureText(drawTxt, r.FontSize, r.Styles).Width;
        // text-decoration-thickness overrides the auto ~font/14 stroke
        if r.DecorThickness > 0 then decTh := r.DecorThickness
        else decTh := Max(1, r.FontSize / 14);
        dbx := r.X - sx; dby := r.Y - innerOfs;
        if (r.DecorLines and 4) <> 0 then
          PaintDecorLine(Canvas, dbx, dby + r.FontSize * 0.10, decW, decTh, r.DecorStyle, decCol);
        if (r.DecorLines and 2) <> 0 then
          PaintDecorLine(Canvas, dbx, dby + r.FontSize * 0.56, decW, decTh, r.DecorStyle, decCol);
        // text-underline-offset pushes the underline further below the baseline
        if (r.DecorLines and 1) <> 0 then
          PaintDecorLine(Canvas, dbx, dby + r.FontSize * 0.98 + r.DecorOffset, decW, decTh, r.DecorStyle, decCol);
      end;
      // text-emphasis: a small mark centred over (or under) each non-space glyph.
      // Emphasis is taken from the box style (inherited) — the common case of the
      // property set on a block and applying to all its text.
      if st.TextEmphasisStyle <> '' then
      begin
        emMark := EmphasisMark(st.TextEmphasisStyle);
        if emMark <> '' then
        begin
          if st.TextEmphasisColor <> 0 then emCol := ScaleAlpha(st.TextEmphasisColor, op)
          else emCol := fg;
          emSize := r.FontSize * 0.5;
          emMW := Canvas.MeasureText(emMark, emSize, []).Width;
          emX := r.X - sx;
          emCi := 1;
          while emCi <= Length(drawTxt) do
          begin
            emCl := 1;
            while (emCi + emCl <= Length(drawTxt)) and
                  ((Ord(drawTxt[emCi + emCl]) and $C0) = $80) do Inc(emCl);
            emCh := Copy(drawTxt, emCi, emCl);
            emCW := Canvas.MeasureText(emCh, r.FontSize, r.Styles).Width;
            if Trim(emCh) <> '' then
            begin
              if st.TextEmphasisOver then emY := (r.Y - innerOfs) - emSize * 0.95
              else emY := (r.Y - innerOfs) + r.FontSize * 0.98;
              Canvas.DrawText(emX + (emCW - emMW) / 2, emY, emMark, emSize, [], emCol);
            end;
            emX := emX + emCW;
            Inc(emCi, emCl);
          end;
        end;
      end;
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
  // multicol column-rule: a vertical line centred in each column gap
  if Box.ColRuleGaps > 0 then
  begin
    crCol := st.ColumnRuleColor;
    if (crCol and $FF000000) = 0 then crCol := st.Color;   // unset → currentColor
    for crI := 0 to Box.ColRuleGaps - 1 do
    begin
      crX := Box.X + Box.ColRuleX0 + (crI + 1) * Box.ColRuleColW
             + crI * Box.ColRuleGap + Box.ColRuleGap / 2;
      crTop := Box.Y + Box.ColRuleY0 - innerOfs;
      if LowerCase(st.ColumnRuleStyle) = 'double' then
      begin
        Canvas.FillRect(crX - st.ColumnRuleWidth / 2, crTop,
          Max(1, st.ColumnRuleWidth / 3), Box.ColRuleH, crCol);
        Canvas.FillRect(crX + st.ColumnRuleWidth / 2 - Max(1, st.ColumnRuleWidth / 3), crTop,
          Max(1, st.ColumnRuleWidth / 3), Box.ColRuleH, crCol);
      end
      else
        Canvas.FillRect(crX - st.ColumnRuleWidth / 2, crTop,
          Max(1, st.ColumnRuleWidth), Box.ColRuleH, crCol);
    end;
  end;

  // the `perspective` property establishes a 3D viewing context for the children
  savedPerspD := G3DPerspD; savedPerspOX := G3DPerspOX; savedPerspOY := G3DPerspOY;
  if st.Perspective > 0 then
  begin
    G3DPerspD := st.Perspective;
    G3DPerspOX := Box.X + ResolveOrigin(st.PerspectiveOriginX, Box.W);
    G3DPerspOY := (Box.Y - innerOfs) + ResolveOrigin(st.PerspectiveOriginY, Box.H);
  end;
  // a preserve-3d container inside a perspective projects each child as a 3D plane
  if st.Preserve3D and (G3DPerspD > 0) then
    Paint3DScene(Canvas, Box, innerOfs, op, Hidden)
  else
    for zi := 0 to High(zorder) do
    begin
      i := zorder[zi];
      if sx <> 0 then ShiftBoxTree(Box.Children[i], -sx, 0);
      PaintBoxEx(Canvas, Box.Children[i], innerOfs, op, Hidden);
      if sx <> 0 then ShiftBoxTree(Box.Children[i], sx, 0);
    end;
  G3DPerspD := savedPerspD; G3DPerspOX := savedPerspOX; G3DPerspOY := savedPerspOY;

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
    if vRotSaved then Canvas.RestoreState;   // close the vertical content rotation
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

finalization
  FreeAndNil(GLottieRaster);

end.
