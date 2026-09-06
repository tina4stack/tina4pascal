unit Tina4HTMLDom;

{
  Free Pascal port of the framework-agnostic DOM / CSS core of
  Tina4Delphi's Tina4HTMLRender.pas (THTMLTag, THTMLParser, TCSSRule,
  TCSSStyleSheet, TEdgeValues, TBoxShadow, TComputedStyle).

  Ported classes keep the Delphi method names, signatures and behaviour.
  Intentionally NOT ported (renderer / FMX / network side): TFileCache,
  TImageCache, TLayoutBox, TLayoutEngine, TTina4HTMLRender, and
  TCSSStyleSheet.LoadFromURL (System.Net dependency).

  Type substitutions for FPC 3.2.2:
    - TAlphaColor = Cardinal ($AARRGGBB layout preserved)
    - TTextAlign declared locally with FMX ordinal order (Center, Leading, Trailing)
    - String is AnsiString (UTF-8 in practice); entity decoding emits UTF-8
      byte sequences instead of UTF-16 code units.
}

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, Math, Generics.Collections, Generics.Defaults;

type
  /// ARGB colour, $AARRGGBB — substitution for System.UITypes.TAlphaColor.
  TAlphaColor = Cardinal;

  /// Named colour constants (subset used by the DOM/CSS core), matching
  /// System.UITypes.TAlphaColors values exactly.
  TAlphaColors = record
  const
    Null      = TAlphaColor($00000000);
    Black     = TAlphaColor($FF000000);
    White     = TAlphaColor($FFFFFFFF);
    Red       = TAlphaColor($FFFF0000);
    Blue      = TAlphaColor($FF0000FF);
    Green     = TAlphaColor($FF008000);
    Gray      = TAlphaColor($FF808080);
    Silver    = TAlphaColor($FFC0C0C0);
    Fuchsia   = TAlphaColor($FFFF00FF);
    Aqua      = TAlphaColor($FF00FFFF);
    Lime      = TAlphaColor($FF00FF00);
    Orange    = TAlphaColor($FFFFA500);
    Yellow    = TAlphaColor($FFFFFF00);
    Cyan      = TAlphaColor($FF00FFFF);
    Magenta   = TAlphaColor($FFFF00FF);
    Lightgray = TAlphaColor($FFD3D3D3);
    Darkgray  = TAlphaColor($FFA9A9A9);
  end;

const
  claNull  = TAlphaColors.Null;
  claBlack = TAlphaColors.Black;
  claWhite = TAlphaColors.White;

type
  {$SCOPEDENUMS ON}
  /// Substitution for FMX.Types.TTextAlign — same member order.
  TTextAlign = (Center, Leading, Trailing);
  {$SCOPEDENUMS OFF}

  // ─────────────────────────────────────────────────────────────────────────
  // DOM Node
  // ─────────────────────────────────────────────────────────────────────────

  /// <summary>
  /// Represents a single node in the parsed HTML DOM tree. Stores the tag name,
  /// text content, inline styles, HTML attributes, and child nodes.
  /// </summary>
  THTMLTag = class
  public
    /// <summary>The HTML tag name (e.g. 'div', 'p', 'a'). '#text' for text nodes.</summary>
    TagName: string;
    /// <summary>The text content of this node (for text nodes).</summary>
    Text: string;
    /// <summary>Inline CSS styles parsed from the style attribute.</summary>
    Style: TDictionary<string, string>;
    /// <summary>HTML attributes dictionary (e.g. 'id', 'class', 'href', 'onclick').</summary>
    Attributes: TDictionary<string, string>;
    /// <summary>Ordered list of child nodes.</summary>
    Children: TList<THTMLTag>;
    /// <summary>Reference to the parent node. Nil for the root.</summary>
    Parent: THTMLTag;
    /// <summary>Pseudo-class runtime state. The renderer maintains these
    /// flags as the user mouses around / clicks; CSS selectors with
    /// `:hover`, `:active`, or `:focus` consult them at match time.</summary>
    IsHovered: Boolean;
    IsActive: Boolean;
    IsFocused: Boolean;
    /// <summary>Creates an empty tag with initialised dictionaries and child list.</summary>
    constructor Create;
    /// <summary>Frees all children recursively and the internal dictionaries.</summary>
    destructor Destroy; override;
    /// <summary>Returns an attribute value by name, or Default if not found.</summary>
    function GetAttribute(const Name: string; const Default: string = ''): string;
    /// <summary>Returns True if the attribute exists on this element.</summary>
    function HasAttribute(const Name: string): Boolean;
  end;

  // ─────────────────────────────────────────────────────────────────────────
  // HTML Parser
  // ─────────────────────────────────────────────────────────────────────────

  THTMLParser = class
  private
    FRoot: THTMLTag;
    FHTML: string;
    FPos: Integer;
    FLen: Integer;
    FInPre: Boolean;
    FStyleBlocks: TStringList;
    FLinkHrefs: TStringList;
    function Peek: Char;
    function PeekAt(Offset: Integer): Char;
    procedure Advance(Count: Integer = 1);
    function AtEnd: Boolean;
    procedure SkipWhitespace;
    procedure SkipComment;
    procedure SkipDoctype;
    procedure SkipRawContent(const TagName: string);
    function ReadRawContent(const TagName: string): string;
    function ReadTagName: string;
    function ReadAttributeValue: string;
    procedure ParseAttributes(Tag: THTMLTag);
    procedure ParseStyleAttribute(const StyleStr: string; Dict: TDictionary<string, string>);
    procedure ParseChildren(Parent: THTMLTag; const StopTag: string = '');
    class function IsVoidTag(const Name: string): Boolean; static;
    class function IsIgnoredTag(const Name: string): Boolean; static;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Parse(const HTML: string);
    property Root: THTMLTag read FRoot;
    property StyleBlocks: TStringList read FStyleBlocks;
    property LinkHrefs: TStringList read FLinkHrefs;
    class function DecodeEntities(const S: string): string; static;
    class function IsBlockTag(const Name: string): Boolean; static;
  end;

  // ─────────────────────────────────────────────────────────────────────────
  // CSS Stylesheet
  // ─────────────────────────────────────────────────────────────────────────

  TCSSDeclarations = TDictionary<string, string>;

  TCSSRule = class
  public
    Selector: string;
    Declarations: TCSSDeclarations;
    SourceOrder: Integer;  // Order in which rule appeared in CSS (for stable sorting)
    MediaCond: string;     // '' = always; else an @media condition to satisfy
    // Pre-classified routing key set at parse time so the cascade can
    // lookup-instead-of-scan. Determined from the rule's last selector
    // part (the one that targets the tag itself):
    //   '#X'  -> indexed by tag id 'X'
    //   '.X'  -> indexed by tag class 'X' (first class wins for multi-class)
    //   'tag' -> indexed by tag name
    //   ''    -> universal bucket (matched against every tag)
    RoutingKey: string;
    // Selector pre-tokenized at parse time:
    //   SelectorLower    — Selector.Trim.ToLower (cached)
    //   SelectorParts    — descendant-split parts of SelectorLower
    SelectorLower: string;
    SelectorParts: TStringArray;
    constructor Create;
    destructor Destroy; override;
  end;

  TCSSStyleSheetParseError = procedure(Sender: TObject;
    const Selector, Reason: string) of object;

  TCSSStyleSheet = class
  private
    FRules: TObjectList<TCSSRule>;
    FCustomProps: TDictionary<string, string>;
    FOnParseError: TCSSStyleSheetParseError;
    FHasInteractiveSelectors: Boolean;  // any rule uses :hover/:active/:focus?
    // Indexed cascade — rules grouped by their routing key so a tag
    // with class "btn" only checks rules that could plausibly match it.
    // (FPC note: declared as TObjectDictionary because FPC's rtl-generics
    // TObjectDictionary is not assignment-compatible with TDictionary;
    // behaviour — owned value lists — is identical to the Delphi original.)
    FRulesByKey: TObjectDictionary<string, TList<TCSSRule>>;
    FUniversalRules: TList<TCSSRule>;  // rules with empty RoutingKey
    // @media-conditional :root custom props: (condition, name, value)
    FMediaCustom: array of record Cond, Name, Val: string; end;
    // @font-face declarations: (css family name, src url) for the engine to fetch
    FFontFaces: array of record Family, Url: string; end;
    FHasMediaRules: Boolean;
    FMediaW: Single;                   // current viewport width for @media eval
    FMediaDark: Boolean;               // prefers-color-scheme: dark active?
    procedure ParseFontFace(const DeclBlock: string);
    procedure ParseCSS(const CSSText: string); overload;
    procedure ParseBlock(const CSSText, MediaCond: string);
    function SelectorMatches(Rule: TCSSRule; Tag: THTMLTag): Boolean;
    function SelectorSpecificity(const Selector: string): Integer;
    procedure ClassifyRule(Rule: TCSSRule);
    procedure ClearRuleIndex;
  public
    constructor Create;
    destructor Destroy; override;
    procedure AddCSS(const CSSText: string);
    procedure Clear;
    procedure ApplyTo(Tag: THTMLTag; Declarations: TCSSDeclarations);
    { Set the live @media evaluation context (viewport width + dark scheme).
      Call before a cascade pass; rules/vars behind @media react to it. }
    procedure SetMediaContext(ViewportW: Single; Dark: Boolean);
    { Does an @media condition currently hold? min-width/max-width +
      prefers-color-scheme: dark/light. Unknown features are permissive. }
    function MatchesMedia(const Cond: string): Boolean;
    { True if any @media rule was seen — lets the shell skip re-layout on a
      scheme/size change when nothing depends on it. }
    property HasMediaRules: Boolean read FHasMediaRules;
    { Downloadable-font declarations gathered from @font-face rules. The engine
      iterates these after parse, fetches each Url (async, disk-cached like an
      <img>), and calls Canvas.RegisterFont(Family, localPath) so the family
      name resolves to the fetched face. }
    function FontFaceCount: Integer;
    procedure GetFontFace(Index: Integer; out Family, Url: string);
    function ResolveVar(const Value: string): string;
    function ResolveVarWith(const Value: string; Props: TDictionary<string, string>): string;
    property Rules: TObjectList<TCSSRule> read FRules;
    property OnParseError: TCSSStyleSheetParseError read FOnParseError write FOnParseError;
    /// <summary>
    /// True when any rule's selector contains `:hover`, `:active`, or
    /// `:focus`. Lets the renderer short-circuit mouse-tracking when no
    /// stylesheet rule cares about interactive state.
    /// </summary>
    property HasInteractiveSelectors: Boolean read FHasInteractiveSelectors;
    property CustomProps: TDictionary<string, string> read FCustomProps;
  end;

  // ─────────────────────────────────────────────────────────────────────────
  // Computed Style
  // ─────────────────────────────────────────────────────────────────────────

  TEdgeValues = record
    Top, Right, Bottom, Left: Single;
    procedure Clear;
    procedure SetAll(V: Single);
    function Horz: Single;   // Left + Right
    function Vert: Single;   // Top + Bottom
    function Any: Boolean;   // True if any side > 0
  end;

  TBoxShadow = record
    OffsetX: Single;
    OffsetY: Single;
    BlurRadius: Single;
    SpreadRadius: Single;
    Color: TAlphaColor;
    Inset: Boolean;
    Active: Boolean;  // True when a box-shadow has been set
  end;

  TComputedStyle = record
    FontFamily: string;
    FontSize: Single;
    Bold: Boolean;
    FontWeight: Integer;   // 100..900 numeric weight (400 normal, 700 bold)
    Italic: Boolean;
    Color: TAlphaColor;
    BackgroundColor: TAlphaColor;
    TextDecoration: string;
    TextAlign: TTextAlign;
    TextJustify: Boolean;      // text-align: justify (spread slack across gaps)
    LineHeight: Single;
    VerticalAlign: string;
    CaptionSide: string;        // '' | 'top' | 'bottom' (table <caption> placement)
    Margin: TEdgeValues;
    Padding: TEdgeValues;
    BorderColors: array[0..3] of TAlphaColor;  // Top, Right, Bottom, Left
    BorderWidths: TEdgeValues;
    BorderStyle: string;   // solid (default) / dashed / dotted / double
    BorderRadius: Single;
    BorderRadii: array[0..3] of Single;  // TL, TR, BR, BL — -1 means inherit from BorderRadius
    ExplicitWidth: Single;
    ExplicitHeight: Single;
    AspectRatio: Single;   // width/height ratio (0 = none/auto)
    Display: string;
    WhiteSpace: string;
    BoxSizing: string;
    AppearanceNone: Boolean;    // appearance:none — strip native control chrome
    AccentColor: TAlphaColor;   // accent-color for checkboxes/radios/range (0=auto)
    CaretColor: TAlphaColor;    // caret-color for the text caret (0=auto)
    PointerEventsNone: Boolean; // pointer-events:none — transparent to hit-testing
    BorderCollapse: Boolean;    // border-collapse:collapse (default separate)
    BorderSpacing: Single;      // border-spacing (separate model), px
    CSSCursor: string;
    TextTransform: string;
    Opacity: Single;
    MinWidth: Single;
    MaxWidth: Single;
    MinHeight: Single;
    MaxHeight: Single;
    LetterSpacing: Single;
    WordSpacing: Single;        // extra px added to each inter-word space
    ListStyleInside: Boolean;   // list-style-position: inside
    TextIndent: Single;
    Visibility: string;
    ListStyleType: string;
    Overflow: string;
    // overflow-x / overflow-y: per-axis scroll control.
    OverflowX: string;
    OverflowY: string;
    WordBreak: string;
    OverflowWrap: string;
    TextOverflow: string;
    BoxShadow: TBoxShadow;
    ObjectFit: string;     // 'fill' (default), 'cover', 'contain', 'none', 'scale-down'
    BackgroundImage: string; // URL from background-image: url(...)
    BackgroundSize: string;  // 'auto', 'cover', 'contain', or explicit size
    CSSPosition: string;   // 'static', 'relative', 'absolute', 'fixed', 'sticky'
    CSSTop: Single;        // top offset for sticky/absolute positioning
    CSSLeft: Single;
    CSSRight: Single;
    CSSBottom: Single;
    ZIndex: Integer;       // paint order among siblings (0 = auto/default)
    OutlineWidth: Single;
    OutlineColor: TAlphaColor;
    OutlineStyle: string;       // 'solid' | 'dashed' | 'dotted' | 'none'
    OutlineOffset: Single;
    CSSFloat: string;      // 'none' (default) | 'left' | 'right'
    // CSS Flexbox (subset)
    FlexDirection: string;
    FlexWrap: string;
    JustifyContent: string;
    AlignItems: string;
    AlignContent: string;         // cross-axis distribution of wrapped lines
    FlexGrow: Single;
    FlexShrink: Single;
    FlexBasis: Single;
    FlexGap: Single;
    AlignSelf: string;            // per-item cross alignment ('' = inherit align-items)
    CSSOrder: Integer;            // flex/grid `order`
    // CSS Grid (subset)
    GridTemplateColumns: string;  // track list: px / % / fr / repeat(n, size) / auto
    GridTemplateRows: string;
    GridColumn: string;           // item placement: 'span N' (start/end lines TBD)
    GridRow: string;
    RowGap: Single;               // grid row / column gaps (independent)
    ColGap: Single;
    // text-shadow: offsetX offsetY [blur] color
    TextShadowOffsetX: Single;
    TextShadowOffsetY: Single;
    TextShadowBlur: Single;
    TextShadowColor: TAlphaColor;
    TextShadowActive: Boolean;
    // background-position: percentage (negative sentinel) or pixel offset
    BgPosX: Single;
    BgPosY: Single;
    BgRepeat: string;
    // Linear gradient
    BgGradientStart: TAlphaColor;
    BgGradientEnd: TAlphaColor;
    BgGradientAngle: Single;     // degrees clockwise from `to top`
    BgGradientActive: Boolean;
    BgGradientRadial: Boolean;   // radial-gradient() vs linear-gradient()
    GradStopColors: array[0..7] of TAlphaColor;  // up to 8 colour stops
    GradStopPos: array[0..7] of Single;          // stop position 0..1, -1 = auto
    GradStopCount: Integer;
    // CSS transforms (subset)
    TransformActive: Boolean;
    TransformTranslateX: Single;
    TransformTranslateY: Single;
    TransformRotate: Single;       // degrees clockwise
    TransformScaleX: Single;
    TransformScaleY: Single;
    CSSClear: string;   // 'none' (default) | 'left' | 'right' | 'both'
    procedure SetBorderWidth(W: Single);
    procedure SetBorderColor(C: TAlphaColor);
    function BorderColor: TAlphaColor;  // returns Top color (legacy compat)
    function CornerRadius(Index: Integer): Single;  // 0=TL, 1=TR, 2=BR, 3=BL
    function HasUniformRadius: Boolean;
    function MaxCornerRadius: Single;
    class function Default: TComputedStyle; static;
    class function ForTag(Tag: THTMLTag; const ParentStyle: TComputedStyle; StyleSheet: TCSSStyleSheet = nil): TComputedStyle; static;
    class procedure ApplyDeclarations(Decls: TCSSDeclarations; var Style: TComputedStyle; const ParentStyle: TComputedStyle); static;
    class procedure ExtractBgImageUrl(const Value: string; out Url: string); static;
    class function ParseColor(const S: string): TAlphaColor; static;
    class function ParseLength(const S: string; EmSize: Single = 14): Single; static;
    class procedure ParseEdgeShorthand(const S: string; var E: TEdgeValues; EmSize: Single); static;
  end;

{ Reset the deferred-calc table and set the viewport (px) for vw/vh in calc().
  The layout engine calls this before each build. }
procedure SetCalcContext(VpW, VpH: Single);
{ Resolve a ParseLength result: if it was a deferred %-bearing calc() marker,
  evaluate it now against PctBase; otherwise return V unchanged. }
function ResolveCalc(V, PctBase: Single): Single;

implementation

// UTF-8 encoder used by entity decoding (Delphi appended UTF-16 code units;
// FPC strings here are UTF-8 so we emit the byte sequence instead).
function CodePointToUTF8(CodePoint: Cardinal): string;
begin
  if CodePoint < $80 then
    Result := Chr(CodePoint)
  else if CodePoint < $800 then
    Result := Chr($C0 or (CodePoint shr 6)) +
              Chr($80 or (CodePoint and $3F))
  else if CodePoint < $10000 then
    Result := Chr($E0 or (CodePoint shr 12)) +
              Chr($80 or ((CodePoint shr 6) and $3F)) +
              Chr($80 or (CodePoint and $3F))
  else
    Result := Chr($F0 or (CodePoint shr 18)) +
              Chr($80 or ((CodePoint shr 12) and $3F)) +
              Chr($80 or ((CodePoint shr 6) and $3F)) +
              Chr($80 or (CodePoint and $3F));
end;

// ═══════════════════════════════════════════════════════════════════════════
// THTMLTag
// ═══════════════════════════════════════════════════════════════════════════

constructor THTMLTag.Create;
begin
  inherited;
  Style := TDictionary<string, string>.Create;
  Attributes := TDictionary<string, string>.Create;
  Children := TList<THTMLTag>.Create;
  Parent := nil;
end;

destructor THTMLTag.Destroy;
var
  I: Integer;
begin
  // Detach from our parent's Children FIRST so no stale pointer to this node
  // survives in the parent list (see the Delphi source for the incident that
  // motivated the self-detaching destructor).
  if Assigned(Parent) and Assigned(Parent.Children) then
    Parent.Children.Remove(Self);
  Parent := nil;
  // Free our children with an index walk, nulling each child's Parent first so
  // its own (now self-detaching) destructor doesn't Remove itself from this
  // very list mid-teardown — we're discarding the whole list anyway.
  for I := Children.Count - 1 downto 0 do
  begin
    Children[I].Parent := nil;
    Children[I].Free;
  end;
  Children.Free;
  Style.Free;
  Attributes.Free;
  inherited;
end;

function THTMLTag.GetAttribute(const Name: string; const Default: string): string;
begin
  if not Attributes.TryGetValue(Name.ToLower, Result) then
    Result := Default;
end;

function THTMLTag.HasAttribute(const Name: string): Boolean;
begin
  Result := Attributes.ContainsKey(Name.ToLower);
end;

// ═══════════════════════════════════════════════════════════════════════════
// TCSSRule / TCSSStyleSheet
// ═══════════════════════════════════════════════════════════════════════════

constructor TCSSRule.Create;
begin
  inherited;
  Declarations := TCSSDeclarations.Create;
end;

destructor TCSSRule.Destroy;
begin
  Declarations.Free;
  inherited;
end;

constructor TCSSStyleSheet.Create;
begin
  inherited;
  FRules := TObjectList<TCSSRule>.Create(True);
  FCustomProps := TDictionary<string, string>.Create;
  FRulesByKey := TObjectDictionary<string, TList<TCSSRule>>.Create([doOwnsValues]);
  FUniversalRules := TList<TCSSRule>.Create;
end;

destructor TCSSStyleSheet.Destroy;
begin
  FCustomProps.Free;
  FUniversalRules.Free;
  FRulesByKey.Free;
  FRules.Free;
  inherited;
end;

procedure TCSSStyleSheet.Clear;
begin
  FRules.Clear;
  FCustomProps.Clear;
  SetLength(FMediaCustom, 0);
  SetLength(FFontFaces, 0);
  FHasMediaRules := False;
  ClearRuleIndex;
end;

procedure TCSSStyleSheet.ClearRuleIndex;
begin
  FRulesByKey.Clear;
  FUniversalRules.Clear;
end;

procedure TCSSStyleSheet.ClassifyRule(Rule: TCSSRule);
// Compute the routing key for a rule based on its LAST selector part
// (the one that selects the tag itself; preceding parts are descendant
// constraints checked at match time). Index the rule under that key.
// Also pre-tokenize the selector so SelectorMatches doesn't repeat the
// Trim/ToLower/Split work on every call.
var
  Sel, LastPart, Rest: string;
  I, DotPos, HashPos, BracketPos, ColonPos, EndPos: Integer;
  List: TList<TCSSRule>;
begin
  // Pre-tokenize the selector. Lowercase once, split-by-space once.
  Rule.SelectorLower := Rule.Selector.Trim.ToLower;
  Rule.SelectorParts := Rule.SelectorLower.Split([' '], TStringSplitOptions.ExcludeEmpty);

  Sel := Rule.Selector.Trim;
  // Find the last descendant-separated part. Trim trailing combinators.
  I := Sel.LastIndexOf(' ');
  if I >= 0 then LastPart := Sel.Substring(I + 1).Trim
  else LastPart := Sel;
  if LastPart = '' then Exit;

  // Strip any trailing pseudo-class / attribute selector for routing
  // purposes — the routing key is just the tag/class/id of the last
  // simple selector. The full match (incl. pseudo / attr) still runs
  // later in MatchesSingleSelector.
  ColonPos := LastPart.IndexOf(':');
  if ColonPos >= 0 then LastPart := LastPart.Substring(0, ColonPos);
  BracketPos := LastPart.IndexOf('[');
  if BracketPos >= 0 then LastPart := LastPart.Substring(0, BracketPos);

  HashPos := LastPart.IndexOf('#');
  DotPos := LastPart.IndexOf('.');

  if (HashPos >= 0) and ((DotPos < 0) or (HashPos < DotPos)) then
  begin
    // ID first: '#X' or 'tag#X'. Routing key = '#X'.
    Rest := LastPart.Substring(HashPos + 1);
    EndPos := Rest.IndexOfAny(['.']);
    if EndPos >= 0 then Rest := Rest.Substring(0, EndPos);
    Rule.RoutingKey := '#' + Rest.ToLower;
  end
  else if DotPos >= 0 then
  begin
    // Class first: '.X', 'tag.X', '.X.Y'. Routing key = '.X' (first class).
    Rest := LastPart.Substring(DotPos + 1);
    EndPos := Rest.IndexOfAny(['.', '#']);
    if EndPos >= 0 then Rest := Rest.Substring(0, EndPos);
    Rule.RoutingKey := '.' + Rest.ToLower;
  end
  else if (LastPart <> '') and (LastPart <> '*') then
  begin
    // Plain tag: 'div', 'p'. Lowercase since HTML is case-insensitive.
    Rule.RoutingKey := LastPart.ToLower;
  end
  else
    Rule.RoutingKey := '';

  if Rule.RoutingKey = '' then
    FUniversalRules.Add(Rule)
  else
  begin
    if not FRulesByKey.TryGetValue(Rule.RoutingKey, List) then
    begin
      List := TList<TCSSRule>.Create;
      FRulesByKey.Add(Rule.RoutingKey, List);
    end;
    List.Add(Rule);
  end;
end;

procedure TCSSStyleSheet.ParseCSS(const CSSText: string);
var S: string; I, EndComment: Integer;
begin
  // Strip CSS comments /* ... */, then parse the top-level block (no @media).
  S := CSSText;
  I := S.IndexOf('/*');
  while I >= 0 do
  begin
    EndComment := S.IndexOf('*/', I + 2);
    if EndComment >= 0 then S := S.Remove(I, EndComment - I + 2)
    else S := S.Remove(I);
    I := S.IndexOf('/*');
  end;
  ParseBlock(S, '');
end;

{ Parse a block of rules. MediaCond (if non-empty) is stamped on every rule and
  scopes its :root custom props, so @media blocks recurse in with their query. }
procedure TCSSStyleSheet.ParseBlock(const CSSText, MediaCond: string);
var
  S, SelectorPart, DeclBlock, DeclStr: string;
  BraceStart, BraceEnd, I: Integer;
  Rule: TCSSRule;
  Decls: TStringArray;
  Selectors: TStringArray;
  Depth, J: Integer;
  SelStr, TrimmedSel, SelLowerTmp: string;
  IsGlobalScope: Boolean;
  D, PropName, PropVal, RestStr, InnerCond: string;
  ColonPos, ColonPos2: Integer;
begin
  S := CSSText;
  I := 0;
  while I < Length(S) do
  begin
    // Find opening brace
    BraceStart := S.IndexOf('{', I);
    if BraceStart < 0 then Break;

    // Find matching closing brace
    BraceEnd := S.IndexOf('}', BraceStart + 1);
    if BraceEnd < 0 then Break;

    SelectorPart := S.Substring(I, BraceStart - I).Trim;
    DeclBlock := S.Substring(BraceStart + 1, BraceEnd - BraceStart - 1).Trim;

    // @rules: find the matching '}' by counting nesting (blocks nest rules).
    if SelectorPart.StartsWith('@') then
    begin
      Depth := 1;
      J := BraceStart + 1;
      while (J < Length(S)) and (Depth > 0) do
      begin
        if S.Chars[J] = '{' then Inc(Depth)
        else if S.Chars[J] = '}' then Dec(Depth);
        Inc(J);
      end;
      // @media: recurse into the inner rules, tagged with the query. Other
      // @rules (keyframes/font-face/supports/import) are still skipped.
      if SelectorPart.ToLower.StartsWith('@media') then
      begin
        FHasMediaRules := True;
        InnerCond := Trim(Copy(SelectorPart, 7, MaxInt));       // after "@media"
        // inner block content between BraceStart+1 and the matching close (J-1)
        ParseBlock(S.Substring(BraceStart + 1, (J - 1) - (BraceStart + 1)),
          Trim(InnerCond));
      end
      else if SelectorPart.ToLower.StartsWith('@font-face') then
        ParseFontFace(DeclBlock);   // capture font-family + src url for download
      I := J;
      Continue;
    end;

    // Parse declarations
    if (SelectorPart <> '') and (DeclBlock <> '') then
    begin
      // Handle comma-separated selectors: "h1, h2, h3 { ... }"
      Selectors := SelectorPart.Split([',']);
      Decls := DeclBlock.Split([';']);

      for SelStr in Selectors do
      begin
        TrimmedSel := SelStr.Trim;
        if TrimmedSel = '' then Continue;

        Rule := TCSSRule.Create;
        Rule.Selector := TrimmedSel;
        Rule.MediaCond := MediaCond;   // '' unless inside an @media block

        // Check if this is a :root or * selector (global custom properties)
        IsGlobalScope := SameText(TrimmedSel, ':root') or (TrimmedSel = '*');

        for D in Decls do
        begin
          DeclStr := D.Trim;
          if DeclStr = '' then Continue;
          // Delphi used DeclStr.Split([':'], 2), which TRUNCATES at the 2nd
          // delimiter (remainder lost). Replicate that exact semantics.
          ColonPos := DeclStr.IndexOf(':');
          if ColonPos >= 0 then
          begin
            PropName := DeclStr.Substring(0, ColonPos).Trim.ToLower;
            RestStr := DeclStr.Substring(ColonPos + 1);
            ColonPos2 := RestStr.IndexOf(':');
            if ColonPos2 >= 0 then
              PropVal := RestStr.Substring(0, ColonPos2).Trim
            else
              PropVal := RestStr.Trim;
            // Strip !important (we don't track priority yet but must strip for parsing)
            if PropVal.EndsWith('!important') then
              PropVal := PropVal.Substring(0, PropVal.Length - 10).Trim;
            // Collect CSS custom properties (--var-name) from :root as globals.
            // Inside @media, they become conditional overrides (dark-mode themes).
            if PropName.StartsWith('--') then
            begin
              if IsGlobalScope and (MediaCond = '') then
                FCustomProps.AddOrSetValue(PropName, PropVal)
              else if IsGlobalScope then
              begin
                SetLength(FMediaCustom, Length(FMediaCustom) + 1);
                FMediaCustom[High(FMediaCustom)].Cond := MediaCond;
                FMediaCustom[High(FMediaCustom)].Name := PropName;
                FMediaCustom[High(FMediaCustom)].Val := PropVal;
              end
              else
                Rule.Declarations.AddOrSetValue(PropName, PropVal);
            end
            else
              Rule.Declarations.AddOrSetValue(PropName, PropVal);
          end;
        end;

        if Rule.Declarations.Count > 0 then
        begin
          Rule.SourceOrder := FRules.Count;
          FRules.Add(Rule);
          ClassifyRule(Rule);
          // Note any interactive pseudo-class so the renderer can skip
          // mouse-tracking when no rule needs it.
          SelLowerTmp := TrimmedSel.ToLower;
          if (Pos(':hover', SelLowerTmp) > 0) or
             (Pos(':active', SelLowerTmp) > 0) or
             (Pos(':focus', SelLowerTmp) > 0) or
             (Pos(':checked', SelLowerTmp) > 0) then
            FHasInteractiveSelectors := True;
        end
        else
        begin
          if Assigned(FOnParseError) then
            FOnParseError(Self, TrimmedSel,
              'rule produced no parsable declarations');
          Rule.Free;
        end;
      end;
    end;

    I := BraceEnd + 1;
  end;
end;

procedure TCSSStyleSheet.AddCSS(const CSSText: string);
begin
  ParseCSS(CSSText);
end;

procedure TCSSStyleSheet.SetMediaContext(ViewportW: Single; Dark: Boolean);
begin
  FMediaW := ViewportW;
  FMediaDark := Dark;
end;

{ Extract the first url(...) target from a `src:` declaration. Handles the CSS
  forms  src: url("x.ttf")  |  url('x.ttf') format('truetype')  |  url(x.ttf) .
  Data: URIs and local(...) names are skipped (we only fetch real URLs). }
function ExtractFontSrcUrl(const Src: string): string;
var
  p, q: Integer;
  raw: string;
begin
  Result := '';
  p := Pos('url(', LowerCase(Src));
  if p <= 0 then Exit;
  p := p + 4;                          // past "url("
  q := p;
  while (q <= Length(Src)) and (Src[q] <> ')') do Inc(q);
  raw := Trim(Copy(Src, p, q - p));
  // strip matching quotes
  if (Length(raw) >= 2) and ((raw[1] = '"') or (raw[1] = '''')) then
    raw := Copy(raw, 2, Length(raw) - 2);
  Result := Trim(raw);
end;

procedure TCSSStyleSheet.ParseFontFace(const DeclBlock: string);
var
  Decls: TStringArray;
  D, PropName, PropVal, Fam, Url: string;
  ColonPos, I: Integer;
begin
  Fam := '';
  Url := '';
  Decls := DeclBlock.Split([';']);
  for D in Decls do
  begin
    ColonPos := Pos(':', D);
    if ColonPos <= 0 then Continue;
    PropName := LowerCase(Trim(Copy(D, 1, ColonPos - 1)));
    PropVal := Trim(Copy(D, ColonPos + 1, MaxInt));
    if PropName = 'font-family' then
    begin
      Fam := PropVal;
      // dequote
      if (Length(Fam) >= 2) and ((Fam[1] = '"') or (Fam[1] = '''')) then
        Fam := Copy(Fam, 2, Length(Fam) - 2);
      Fam := Trim(Fam);
    end
    else if PropName = 'src' then
      Url := ExtractFontSrcUrl(PropVal);
  end;
  if (Fam = '') or (Url = '') then Exit;
  // de-dup on (family,url)
  for I := 0 to High(FFontFaces) do
    if SameText(FFontFaces[I].Family, Fam) and (FFontFaces[I].Url = Url) then Exit;
  SetLength(FFontFaces, Length(FFontFaces) + 1);
  FFontFaces[High(FFontFaces)].Family := Fam;
  FFontFaces[High(FFontFaces)].Url := Url;
end;

function TCSSStyleSheet.FontFaceCount: Integer;
begin
  Result := Length(FFontFaces);
end;

procedure TCSSStyleSheet.GetFontFace(Index: Integer; out Family, Url: string);
begin
  Family := '';
  Url := '';
  if (Index < 0) or (Index > High(FFontFaces)) then Exit;
  Family := FFontFaces[Index].Family;
  Url := FFontFaces[Index].Url;
end;

{ px value after the ':' in a media feature like "min-width: 768px". }
function MediaPx(const Feature: string): Single;
var p: Integer; s: string;
begin
  Result := 0;
  p := Pos(':', Feature);
  if p <= 0 then Exit;
  s := Trim(Copy(Feature, p + 1, MaxInt));
  s := StringReplace(s, 'px', '', [rfReplaceAll, rfIgnoreCase]);
  Result := StrToFloatDef(Trim(s), 0);
end;

function TCSSStyleSheet.MatchesMedia(const Cond: string): Boolean;
var c, part: string; parts: TStringArray; k: Integer;
begin
  Result := True;
  if Trim(Cond) = '' then Exit;
  c := LowerCase(Cond);
  c := StringReplace(c, ' and ', '&', [rfReplaceAll]);
  c := StringReplace(c, '(', '', [rfReplaceAll]);
  c := StringReplace(c, ')', '', [rfReplaceAll]);
  parts := c.Split(['&']);
  for k := 0 to High(parts) do
  begin
    part := Trim(parts[k]);
    if (part = '') or (part = 'screen') or (part = 'all') then Continue;
    if part = 'print' then Exit(False);             // we render to a screen
    if Pos('prefers-color-scheme', part) > 0 then
    begin
      if Pos('dark', part) > 0 then begin if not FMediaDark then Exit(False); end
      else if Pos('light', part) > 0 then begin if FMediaDark then Exit(False); end;
      Continue;
    end;
    if Pos('min-width', part) > 0 then
    begin if FMediaW < MediaPx(part) then Exit(False); Continue; end;
    if Pos('max-width', part) > 0 then
    begin if FMediaW > MediaPx(part) then Exit(False); Continue; end;
    // unknown feature → permissive (never drop styles we don't understand)
  end;
end;

function TCSSStyleSheet.ResolveVar(const Value: string): string;
var
  VarStart, VarEnd, CommaPos: Integer;
  VarExpr, VarName, Fallback, Resolved: string;
begin
  Result := Value;
  // Resolve all var() references in the value
  VarStart := Result.IndexOf('var(');
  while VarStart >= 0 do
  begin
    // Find matching closing paren
    VarEnd := Result.IndexOf(')', VarStart + 4);
    if VarEnd < 0 then Break;
    VarExpr := Result.Substring(VarStart + 4, VarEnd - VarStart - 4).Trim;
    // Check for fallback: var(--name, fallback)
    CommaPos := VarExpr.IndexOf(',');
    if CommaPos >= 0 then
    begin
      VarName := VarExpr.Substring(0, CommaPos).Trim;
      Fallback := VarExpr.Substring(CommaPos + 1).Trim;
    end
    else
    begin
      VarName := VarExpr;
      Fallback := '';
    end;
    // Look up the custom property
    if FCustomProps.TryGetValue(VarName, Resolved) then
    begin
      // Recursively resolve if the value itself contains var()
      if Resolved.Contains('var(') then
        Resolved := ResolveVar(Resolved);
      Result := Result.Substring(0, VarStart) + Resolved + Result.Substring(VarEnd + 1);
    end
    else if Fallback <> '' then
      Result := Result.Substring(0, VarStart) + Fallback + Result.Substring(VarEnd + 1)
    else
      Break; // Can't resolve, leave as-is
    VarStart := Result.IndexOf('var(');
  end;
end;

function TCSSStyleSheet.ResolveVarWith(const Value: string;
  Props: TDictionary<string, string>): string;
var
  VarStart, VarEnd, CommaPos: Integer;
  VarExpr, VarName, Fallback, Resolved: string;
begin
  Result := Value;
  VarStart := Result.IndexOf('var(');
  while VarStart >= 0 do
  begin
    VarEnd := Result.IndexOf(')', VarStart + 4);
    if VarEnd < 0 then Break;
    VarExpr := Result.Substring(VarStart + 4, VarEnd - VarStart - 4).Trim;
    CommaPos := VarExpr.IndexOf(',');
    if CommaPos >= 0 then
    begin
      VarName := VarExpr.Substring(0, CommaPos).Trim;
      Fallback := VarExpr.Substring(CommaPos + 1).Trim;
    end
    else
    begin
      VarName := VarExpr;
      Fallback := '';
    end;
    if Props.TryGetValue(VarName, Resolved) then
    begin
      if Resolved.Contains('var(') then
        Resolved := ResolveVarWith(Resolved, Props);
      Result := Result.Substring(0, VarStart) + Resolved + Result.Substring(VarEnd + 1);
    end
    else if Fallback <> '' then
      Result := Result.Substring(0, VarStart) + Fallback + Result.Substring(VarEnd + 1)
    else
      Break;
    VarStart := Result.IndexOf('var(');
  end;
end;

// Unit-level specificity so the sort comparator (a plain function in FPC —
// no anonymous methods in 3.2.2) can share it with the method.
function SelectorSpecificityOf(const Selector: string): Integer;
var
  S, T, P: string;
  C: Char;
  Parts: TStringArray;
begin
  // Simple specificity: ID=100, class/attr=10, tag=1
  Result := 0;
  S := Selector;
  for C in S do
  begin
    if C = '#' then Inc(Result, 100)
    else if C = '.' then Inc(Result, 10);
  end;
  // Count tag-level selectors (parts that don't start with # or .)
  Parts := S.Split([' ']);
  for P in Parts do
  begin
    T := P.Trim;
    if (T <> '') and not T.StartsWith('#') and not T.StartsWith('.') and not T.StartsWith(':') then
      Inc(Result, 1);
  end;
end;

function TCSSStyleSheet.SelectorSpecificity(const Selector: string): Integer;
begin
  Result := SelectorSpecificityOf(Selector);
end;

function CompareCSSRules(constref A, B: TCSSRule): Integer;
begin
  Result := SelectorSpecificityOf(A.Selector) - SelectorSpecificityOf(B.Selector);
  if Result = 0 then
    Result := A.SourceOrder - B.SourceOrder;
end;

function MatchesSingleSelector(const Sel: string; Tag: THTMLTag): Boolean;
var
  SelTag, SelClass, SelId: string;
  DotPos, HashPos: Integer;
  RequireHover, RequireActive, RequireFocus, RequireChecked: Boolean;
  S, Suffix, Inner, V, Rest, TagClass, TagId, ClsPart: string;
  ColonIdx, BracketStart, BracketEnd, EqIdx: Integer;
  AttrChecks: array of TPair<string, string>;
  APair, Check: TPair<string, string>;
  Classes: TStringArray;
  Found: Boolean;
begin
  Result := False;
  if not Assigned(Tag) or (Tag.TagName = '#text') or (Tag.TagName = 'root') then
    Exit;

  // Parse selector into tag, class, id parts
  // e.g., "div.container#main" -> tag=div, class=container, id=main
  SelTag := '';
  SelClass := '';
  SelId := '';
  RequireHover := False;
  RequireActive := False;
  RequireFocus := False;
  RequireChecked := False;
  SetLength(AttrChecks, 0);

  S := Sel;

  // Fast path: most CSS selectors are pure tag/class/id and contain
  // neither `:` nor `[`. Skip the pseudo-class suffix scan and the
  // attribute-selector scan entirely in that case.
  if S.IndexOf(':') >= 0 then
  begin
    // Strip recognised pseudo-class suffixes (`:hover`, `:active`,
    // `:focus`). Unknown pseudo-classes (`:not(...)`, `:nth-child()`)
    // are left embedded — they'll fail the class/tag compare below
    // and produce a no-match without bringing down the surrounding
    // stylesheet.
    while True do
    begin
      ColonIdx := S.LastIndexOf(':');
      if ColonIdx <= 0 then Break;
      Suffix := S.Substring(ColonIdx).ToLower;
      if Suffix = ':hover' then begin RequireHover := True; S := S.Substring(0, ColonIdx); end
      else if Suffix = ':active' then begin RequireActive := True; S := S.Substring(0, ColonIdx); end
      else if Suffix = ':focus' then begin RequireFocus := True; S := S.Substring(0, ColonIdx); end
      else if Suffix = ':checked' then begin RequireChecked := True; S := S.Substring(0, ColonIdx); end
      else Break;
    end;
  end;

  if S.IndexOf('[') >= 0 then
  begin
    // Strip attribute selectors `[name]` (presence) and `[name="value"]`
    // (exact-match). Other operators (`~=`, `^=`, `$=`, `*=`) aren't
    // honoured; they'll fall through to a no-match.
    while True do
    begin
      BracketStart := S.IndexOf('[');
      if BracketStart < 0 then Break;
      BracketEnd := S.IndexOf(']', BracketStart + 1);
      if BracketEnd < 0 then Break;
      Inner := S.Substring(BracketStart + 1, BracketEnd - BracketStart - 1).Trim;
      EqIdx := Inner.IndexOf('=');
      if EqIdx > 0 then
      begin
        APair.Key := Inner.Substring(0, EqIdx).Trim.ToLower;
        V := Inner.Substring(EqIdx + 1).Trim;
        if (V.Length >= 2) and ((V.Chars[0] = '"') or (V.Chars[0] = '''')) then
          V := V.Substring(1, V.Length - 2);
        APair.Value := V;
      end
      else
      begin
        APair.Key := Inner.ToLower;
        APair.Value := #1#1;  // sentinel meaning "presence only"
      end;
      SetLength(AttrChecks, Length(AttrChecks) + 1);
      AttrChecks[High(AttrChecks)] := APair;
      // Remove the [...] segment from S
      S := S.Remove(BracketStart, BracketEnd - BracketStart + 1);
    end;
  end;
  HashPos := S.IndexOf('#');
  DotPos := S.IndexOf('.');

  if (HashPos >= 0) and ((DotPos < 0) or (HashPos < DotPos)) then
  begin
    SelTag := S.Substring(0, HashPos);
    Rest := S.Substring(HashPos + 1);
    DotPos := Rest.IndexOf('.');
    if DotPos >= 0 then
    begin
      SelId := Rest.Substring(0, DotPos);
      SelClass := Rest.Substring(DotPos + 1);
    end
    else
      SelId := Rest;
  end
  else if DotPos >= 0 then
  begin
    SelTag := S.Substring(0, DotPos);
    Rest := S.Substring(DotPos + 1);
    HashPos := Rest.IndexOf('#');
    if HashPos >= 0 then
    begin
      SelClass := Rest.Substring(0, HashPos);
      SelId := Rest.Substring(HashPos + 1);
    end
    else
      SelClass := Rest;
  end
  else
    SelTag := S;

  // Match tag name
  if (SelTag <> '') and (SelTag <> '*') then
  begin
    if not SameText(SelTag, Tag.TagName) then Exit;
  end;

  // Match class
  if SelClass <> '' then
  begin
    TagClass := Tag.GetAttribute('class', '').ToLower;
    // Support multiple classes on element
    Classes := TagClass.Split([' ']);
    Found := False;
    for ClsPart in Classes do
      if SameText(ClsPart.Trim, SelClass) then
      begin
        Found := True;
        Break;
      end;
    if not Found then Exit;
  end;

  // Match ID
  if SelId <> '' then
  begin
    TagId := Tag.GetAttribute('id', '').ToLower;
    if not SameText(TagId, SelId) then Exit;
  end;

  // Must have matched at least something — the bare-pseudo or bare-attr
  // case (e.g. `:hover` or `[disabled]`) is allowed when one of the
  // pseudo-class flags is required or an attribute check is in play.
  if (SelTag = '') and (SelClass = '') and (SelId = '') and
     (not (RequireHover or RequireActive or RequireFocus or RequireChecked)) and
     (Length(AttrChecks) = 0) then Exit;

  // Pseudo-class state checks. All required flags must currently be set
  // on the tag for the selector to match.
  if RequireHover and (not Tag.IsHovered) then Exit;
  if RequireActive and (not Tag.IsActive) then Exit;
  if RequireFocus and (not Tag.IsFocused) then Exit;
  if RequireChecked and (not Tag.HasAttribute('checked')) then Exit;

  // Attribute checks — `[name]` requires presence, `[name="val"]` requires
  // exact value match.
  for Check in AttrChecks do
  begin
    if not Tag.HasAttribute(Check.Key) then Exit;
    if Check.Value <> #1#1 then
      if Tag.GetAttribute(Check.Key, '') <> Check.Value then Exit;
  end;

  Result := True;
end;

function TCSSStyleSheet.SelectorMatches(Rule: TCSSRule; Tag: THTMLTag): Boolean;
// Uses Rule.SelectorParts cached at parse time so we don't pay
// Trim+ToLower+Split per match: match the last simple selector against
// the tag, then walk ancestors for descendant parts.
var
  Current: THTMLTag;
  PartIdx: Integer;
begin
  Result := False;
  if not Assigned(Tag) or (Tag.TagName = '#text') or (Tag.TagName = 'root') then
    Exit;
  if Length(Rule.SelectorParts) = 0 then Exit;

  // Match the last simple selector against the tag
  if not MatchesSingleSelector(Rule.SelectorParts[High(Rule.SelectorParts)], Tag) then
    Exit;

  if Length(Rule.SelectorParts) = 1 then
    Exit(True);

  // Walk ancestors greedy-matching descendant parts in reverse
  Current := Tag.Parent;
  PartIdx := Length(Rule.SelectorParts) - 2;
  while (PartIdx >= 0) and Assigned(Current) do
  begin
    if MatchesSingleSelector(Rule.SelectorParts[PartIdx], Current) then
      Dec(PartIdx);
    Current := Current.Parent;
  end;
  Result := PartIdx < 0;
end;

procedure TCSSStyleSheet.ApplyTo(Tag: THTMLTag; Declarations: TCSSDeclarations);
var
  MatchedRules: TList<TCSSRule>;
  LocalProps: TDictionary<string, string>;
  Candidates: TList<TCSSRule>;
  Seen: TDictionary<TCSSRule, Boolean>;
  PropPair: TPair<string, string>;
  TagId, TagClassAttr, ClsTrimmed, TagName, Val, Cls: string;
  ClsParts: TStringArray;
  List: TList<TCSSRule>;
  R, Rule: TCSSRule;
  J: Integer;
begin
  // Collect matching rules and sort by specificity (lower first, so higher overrides)
  MatchedRules := TList<TCSSRule>.Create;
  // Create a local copy of global custom props for this element's scope.
  // This prevents scoped vars from one element leaking into the next.
  LocalProps := TDictionary<string, string>.Create;
  try
    // Start with global custom props (from :root and *)
    for PropPair in FCustomProps do
      LocalProps.AddOrSetValue(PropPair.Key, PropPair.Value);
    // Overlay @media-conditional :root vars whose query currently holds
    // (e.g. prefers-color-scheme: dark theme swaps) — later matches win.
    for J := 0 to High(FMediaCustom) do
      if MatchesMedia(FMediaCustom[J].Cond) then
        LocalProps.AddOrSetValue(FMediaCustom[J].Name, FMediaCustom[J].Val);

    // Indexed cascade: instead of asking every rule "do you match?", we
    // build a candidate set from rules indexed by the tag's id, classes,
    // tag name, plus the universal-rule bucket. SelectorMatches then
    // verifies (descendants, pseudo-classes, attribute filters).
    Candidates := TList<TCSSRule>.Create;
    Seen := TDictionary<TCSSRule, Boolean>.Create;
    try
      TagId := Tag.GetAttribute('id', '').ToLower;
      if TagId <> '' then
      begin
        if FRulesByKey.TryGetValue('#' + TagId, List) then
          for R in List do
            if not Seen.ContainsKey(R) then begin Candidates.Add(R); Seen.Add(R, True); end;
      end;

      TagClassAttr := Tag.GetAttribute('class', '').ToLower;
      if TagClassAttr <> '' then
      begin
        ClsParts := TagClassAttr.Split([' ']);
        for Cls in ClsParts do
        begin
          ClsTrimmed := Cls.Trim;
          if ClsTrimmed = '' then Continue;
          if FRulesByKey.TryGetValue('.' + ClsTrimmed, List) then
            for R in List do
              if not Seen.ContainsKey(R) then begin Candidates.Add(R); Seen.Add(R, True); end;
        end;
      end;

      TagName := Tag.TagName.ToLower;
      if TagName <> '' then
      begin
        if FRulesByKey.TryGetValue(TagName, List) then
          for R in List do
            if not Seen.ContainsKey(R) then begin Candidates.Add(R); Seen.Add(R, True); end;
      end;

      // Universal rules (selectors with no clear routing key — e.g. `*`,
      // `[disabled]`, anything that fell through). Always considered.
      for R in FUniversalRules do
        if not Seen.ContainsKey(R) then begin Candidates.Add(R); Seen.Add(R, True); end;

      // Verify each candidate with the full selector matcher (handles
      // descendant ancestry, pseudo-classes, attribute filters), and drop any
      // whose @media condition doesn't currently hold.
      for Rule in Candidates do
        if SelectorMatches(Rule, Tag) and
           ((Rule.MediaCond = '') or MatchesMedia(Rule.MediaCond)) then
          MatchedRules.Add(Rule);
    finally
      Seen.Free;
      Candidates.Free;
    end;

    // Sort by specificity ascending (stable: use SourceOrder as tiebreaker).
    // Later rules with equal specificity override earlier ones, matching CSS cascade.
    MatchedRules.Sort(TComparer<TCSSRule>.Construct(CompareCSSRules));

    // Pass 1: Collect ALL scoped --custom-property declarations from matching rules.
    // This must happen before resolving var() so that e.g. .btn-danger's --bs-btn-bg
    // is available when .btn's background-color: var(--bs-btn-bg) is resolved.
    for Rule in MatchedRules do
      for PropPair in Rule.Declarations do
        if PropPair.Key.StartsWith('--') then
          LocalProps.AddOrSetValue(PropPair.Key, PropPair.Value);

    // Pass 2: Resolve var() references using local scope and add to output declarations
    for Rule in MatchedRules do
      for PropPair in Rule.Declarations do
        if not PropPair.Key.StartsWith('--') then
        begin
          Val := PropPair.Value;
          if Val.Contains('var(') then
            Val := ResolveVarWith(Val, LocalProps);
          Declarations.AddOrSetValue(PropPair.Key, Val);
        end;
  finally
    LocalProps.Free;
    MatchedRules.Free;
  end;
end;

// ═══════════════════════════════════════════════════════════════════════════
// THTMLParser
// ═══════════════════════════════════════════════════════════════════════════

constructor THTMLParser.Create;
begin
  inherited;
  FRoot := THTMLTag.Create;
  FRoot.TagName := 'root';
  FStyleBlocks := TStringList.Create;
  FLinkHrefs := TStringList.Create;
end;

destructor THTMLParser.Destroy;
begin
  FRoot.Free;
  FStyleBlocks.Free;
  FLinkHrefs.Free;
  inherited;
end;

function THTMLParser.Peek: Char;
begin
  if FPos <= FLen then
    Result := FHTML[FPos]
  else
    Result := #0;
end;

function THTMLParser.PeekAt(Offset: Integer): Char;
begin
  if (FPos + Offset >= 1) and (FPos + Offset <= FLen) then
    Result := FHTML[FPos + Offset]
  else
    Result := #0;
end;

procedure THTMLParser.Advance(Count: Integer);
begin
  Inc(FPos, Count);
end;

function THTMLParser.AtEnd: Boolean;
begin
  Result := FPos > FLen;
end;

procedure THTMLParser.SkipWhitespace;
begin
  while not AtEnd and CharInSet(Peek, [' ', #9, #10, #13]) do
    Advance;
end;

procedure THTMLParser.SkipComment;
begin
  // FPos points at '<', expect '<!-- ... -->'
  Advance(4); // skip '<!--'
  while not AtEnd do
  begin
    if (Peek = '-') and (PeekAt(1) = '-') and (PeekAt(2) = '>') then
    begin
      Advance(3);
      Exit;
    end;
    Advance;
  end;
end;

procedure THTMLParser.SkipDoctype;
begin
  // Skip everything until '>'
  while not AtEnd and (Peek <> '>') do
    Advance;
  if not AtEnd then
    Advance; // skip '>'
end;

procedure THTMLParser.SkipRawContent(const TagName: string);
var
  CloseTag: string;
  Match: Boolean;
  I: Integer;
  C: Char;
begin
  CloseTag := '</' + TagName;
  while not AtEnd do
  begin
    if (Peek = '<') and (PeekAt(1) = '/') then
    begin
      Match := True;
      for I := 0 to Length(CloseTag) - 1 do
      begin
        C := PeekAt(I);
        if LowerCase(C) <> LowerCase(CloseTag[I + 1]) then
        begin
          Match := False;
          Break;
        end;
      end;
      if Match then
      begin
        // Skip to end of closing tag
        Advance(Length(CloseTag));
        while not AtEnd and (Peek <> '>') do
          Advance;
        if not AtEnd then
          Advance; // skip '>'
        Exit;
      end;
    end;
    Advance;
  end;
end;

function THTMLParser.ReadRawContent(const TagName: string): string;
var
  CloseTag: string;
  StartPos, I: Integer;
  Match: Boolean;
  C: Char;
begin
  Result := '';
  CloseTag := '</' + TagName;
  StartPos := FPos;
  while not AtEnd do
  begin
    if (Peek = '<') and (PeekAt(1) = '/') then
    begin
      Match := True;
      for I := 0 to Length(CloseTag) - 1 do
      begin
        C := PeekAt(I);
        if LowerCase(C) <> LowerCase(CloseTag[I + 1]) then
        begin
          Match := False;
          Break;
        end;
      end;
      if Match then
      begin
        Result := Copy(FHTML, StartPos, FPos - StartPos);
        Advance(Length(CloseTag));
        while not AtEnd and (Peek <> '>') do
          Advance;
        if not AtEnd then
          Advance;
        Exit;
      end;
    end;
    Advance;
  end;
  Result := Copy(FHTML, StartPos, FPos - StartPos);
end;

function THTMLParser.ReadTagName: string;
begin
  Result := '';
  while not AtEnd and not CharInSet(Peek, [' ', '/', '>', #9, #10, #13]) do
  begin
    Result := Result + Peek;
    Advance;
  end;
  Result := Result.ToLower;
end;

function THTMLParser.ReadAttributeValue: string;
var
  Quote: Char;
begin
  Result := '';
  if AtEnd then Exit;

  if CharInSet(Peek, ['"', '''']) then
  begin
    Quote := Peek;
    Advance;
    while not AtEnd and (Peek <> Quote) do
    begin
      Result := Result + Peek;
      Advance;
    end;
    if not AtEnd then
      Advance; // skip closing quote
  end
  else
  begin
    while not AtEnd and not CharInSet(Peek, [' ', '>', '/', #9, #10, #13]) do
    begin
      Result := Result + Peek;
      Advance;
    end;
  end;
end;

procedure THTMLParser.ParseAttributes(Tag: THTMLTag);
var
  Key, Value: string;
begin
  while not AtEnd do
  begin
    SkipWhitespace;
    if AtEnd or (Peek = '>') or ((Peek = '/') and (PeekAt(1) = '>')) then
      Break;

    // Read attribute name
    Key := '';
    while not AtEnd and not CharInSet(Peek, [' ', '=', '>', '/', #9, #10, #13]) do
    begin
      Key := Key + Peek;
      Advance;
    end;
    Key := Key.ToLower.Trim;
    if Key = '' then
    begin
      Advance; // avoid infinite loop on unexpected chars
      Continue;
    end;

    SkipWhitespace;

    if not AtEnd and (Peek = '=') then
    begin
      Advance; // skip '='
      SkipWhitespace;
      Value := ReadAttributeValue;
    end
    else
      Value := Key; // standalone attribute like "checked"

    if Key = 'style' then
      ParseStyleAttribute(Value, Tag.Style)
    else
      Tag.Attributes.AddOrSetValue(Key, Value);
  end;
end;

procedure THTMLParser.ParseStyleAttribute(const StyleStr: string; Dict: TDictionary<string, string>);
var
  Pairs: TList<string>;
  Start, I, ParenDepth, ColonPos: Integer;
  PairStr, S: string;
begin
  // Split on ';' but skip semicolons inside url() parentheses
  Pairs := TList<string>.Create;
  try
    Start := 1;
    ParenDepth := 0;
    for I := 1 to Length(StyleStr) do
    begin
      if StyleStr[I] = '(' then
        Inc(ParenDepth)
      else if StyleStr[I] = ')' then
      begin
        if ParenDepth > 0 then
          Dec(ParenDepth);
      end
      else if (StyleStr[I] = ';') and (ParenDepth = 0) then
      begin
        Pairs.Add(Copy(StyleStr, Start, I - Start));
        Start := I + 1;
      end;
    end;
    if Start <= Length(StyleStr) then
      Pairs.Add(Copy(StyleStr, Start, Length(StyleStr) - Start + 1));

    for PairStr in Pairs do
    begin
      S := PairStr.Trim;
      if S = '' then Continue;
      // Split on first ':' only — can't use Split([':'], 2) because
      // Delphi's Split truncates at the Nth delimiter instead of keeping
      // the remainder (e.g. 'background-image: url(https://...)' would
      // lose everything after the ':' in 'https:').
      ColonPos := S.IndexOf(':');
      if ColonPos > 0 then
        Dict.AddOrSetValue(
          S.Substring(0, ColonPos).Trim.ToLower,
          S.Substring(ColonPos + 1).Trim);
    end;
  finally
    Pairs.Free;
  end;
end;

class function THTMLParser.DecodeEntities(const S: string): string;
var
  Builder: TStringBuilder;
  I, J, CodePoint: Integer;
  Entity: string;
begin
  Builder := TStringBuilder.Create(Length(S));
  try
    I := 1;
    while I <= Length(S) do
    begin
      if S[I] = '&' then
      begin
        J := I + 1;
        while (J <= Length(S)) and (S[J] <> ';') and (J - I < 12) do
          Inc(J);
        if (J <= Length(S)) and (S[J] = ';') then
        begin
          Entity := Copy(S, I + 1, J - I - 1).ToLower;
          if Entity = 'amp' then Builder.Append('&')
          else if Entity = 'lt' then Builder.Append('<')
          else if Entity = 'gt' then Builder.Append('>')
          else if Entity = 'nbsp' then Builder.Append(CodePointToUTF8(160))
          else if Entity = 'quot' then Builder.Append('"')
          else if Entity = 'apos' then Builder.Append('''')
          else if Entity = 'copy' then Builder.Append(CodePointToUTF8(169))
          else if Entity = 'reg' then Builder.Append(CodePointToUTF8(174))
          else if Entity = 'trade' then Builder.Append(CodePointToUTF8(8482))
          else if Entity = 'mdash' then Builder.Append(CodePointToUTF8(8212))
          else if Entity = 'ndash' then Builder.Append(CodePointToUTF8(8211))
          else if Entity = 'laquo' then Builder.Append(CodePointToUTF8(171))
          else if Entity = 'raquo' then Builder.Append(CodePointToUTF8(187))
          else if Entity = 'bull' then Builder.Append(CodePointToUTF8(8226))
          else if Entity = 'hellip' then Builder.Append(CodePointToUTF8(8230))
          else if Entity = 'minus' then Builder.Append(CodePointToUTF8(8722))
          else if Entity = 'times' then Builder.Append(CodePointToUTF8(215))
          else if Entity = 'divide' then Builder.Append(CodePointToUTF8(247))
          else if Entity = 'plusmn' then Builder.Append(CodePointToUTF8(177))
          else if Entity = 'deg' then Builder.Append(CodePointToUTF8(176))
          else if Entity = 'middot' then Builder.Append(CodePointToUTF8(183))
          else if Entity = 'check' then Builder.Append(CodePointToUTF8(10003))
          else if Entity = 'larr' then Builder.Append(CodePointToUTF8(8592))
          else if Entity = 'uarr' then Builder.Append(CodePointToUTF8(8593))
          else if Entity = 'rarr' then Builder.Append(CodePointToUTF8(8594))
          else if Entity = 'darr' then Builder.Append(CodePointToUTF8(8595))
          else if Entity = 'harr' then Builder.Append(CodePointToUTF8(8596))
          else if Entity.StartsWith('#x') then
          begin
            if TryStrToInt('$' + Entity.Substring(2), CodePoint) and (CodePoint > 0) then
              Builder.Append(CodePointToUTF8(CodePoint))
            else
              Builder.Append(Copy(S, I, J - I + 1));
          end
          else if Entity.StartsWith('#') then
          begin
            if TryStrToInt(Entity.Substring(1), CodePoint) and (CodePoint > 0) then
              Builder.Append(CodePointToUTF8(CodePoint))
            else
              Builder.Append(Copy(S, I, J - I + 1));
          end
          else
            Builder.Append(Copy(S, I, J - I + 1));
          I := J + 1;
          Continue;
        end;
      end;
      Builder.Append(S[I]);
      Inc(I);
    end;
    Result := Builder.ToString;
  finally
    Builder.Free;
  end;
end;

class function THTMLParser.IsVoidTag(const Name: string): Boolean;
begin
  Result := SameText(Name, 'br') or SameText(Name, 'hr') or
    SameText(Name, 'img') or SameText(Name, 'input') or
    SameText(Name, 'meta') or SameText(Name, 'link') or
    SameText(Name, 'col') or SameText(Name, 'area') or
    SameText(Name, 'base') or SameText(Name, 'embed') or
    SameText(Name, 'source') or SameText(Name, 'track') or
    SameText(Name, 'wbr') or SameText(Name, 'include');
end;

class function THTMLParser.IsBlockTag(const Name: string): Boolean;
begin
  Result := SameText(Name, 'html') or SameText(Name, 'body') or
    SameText(Name, 'div') or SameText(Name, 'p') or
    SameText(Name, 'h1') or SameText(Name, 'h2') or SameText(Name, 'h3') or
    SameText(Name, 'h4') or SameText(Name, 'h5') or SameText(Name, 'h6') or
    SameText(Name, 'blockquote') or SameText(Name, 'pre') or
    SameText(Name, 'hr') or SameText(Name, 'ul') or SameText(Name, 'ol') or
    SameText(Name, 'li') or SameText(Name, 'table') or
    SameText(Name, 'thead') or SameText(Name, 'tbody') or SameText(Name, 'tfoot') or
    SameText(Name, 'tr') or SameText(Name, 'form') or
    SameText(Name, 'section') or SameText(Name, 'article') or
    SameText(Name, 'nav') or SameText(Name, 'header') or
    SameText(Name, 'footer') or SameText(Name, 'main') or
    SameText(Name, 'aside') or SameText(Name, 'figure') or
    SameText(Name, 'figcaption') or SameText(Name, 'dl') or
    SameText(Name, 'dt') or SameText(Name, 'dd') or
    SameText(Name, 'details') or SameText(Name, 'summary') or
    SameText(Name, 'address') or SameText(Name, 'fieldset') or
    SameText(Name, 'search') or
    SameText(Name, 'menu') or SameText(Name, 'hgroup') or
    SameText(Name, 'dialog') or SameText(Name, 'caption');
end;

class function THTMLParser.IsIgnoredTag(const Name: string): Boolean;
begin
  Result := SameText(Name, 'head') or SameText(Name, 'meta') or
    SameText(Name, 'title');
end;

procedure THTMLParser.ParseChildren(Parent: THTMLTag; const StopTag: string);
var
  TextBuf: TStringBuilder;
  TagName: string;
  ChildTag: THTMLTag;
  SelfClose: Boolean;
  OldInPre: Boolean;
  InlineWS: string;
  RawText, DecodedText, Collapsed: string;
  LastWasSpace: Boolean;
  C: Char;
  TextNode: THTMLTag;
  CSSContent, Rel, Href: string;
begin
  TextBuf := TStringBuilder.Create;
  try
    while not AtEnd do
    begin
      // Check for tags
      if Peek = '<' then
      begin
        // Flush accumulated text
        if TextBuf.Length > 0 then
        begin
          RawText := TextBuf.ToString;
          TextBuf.Clear;
          DecodedText := DecodeEntities(RawText);
          // Collapse whitespace unless in <pre>
          if not FInPre then
          begin
            Collapsed := '';
            LastWasSpace := False;
            for C in DecodedText do
            begin
              if CharInSet(C, [' ', #9, #10, #13]) then
              begin
                if not LastWasSpace then
                  Collapsed := Collapsed + ' ';
                LastWasSpace := True;
              end
              else
              begin
                Collapsed := Collapsed + C;
                LastWasSpace := False;
              end;
            end;
            DecodedText := Collapsed;
          end;
          if DecodedText <> '' then
          begin
            TextNode := THTMLTag.Create;
            TextNode.TagName := '#text';
            TextNode.Text := DecodedText;
            TextNode.Parent := Parent;
            Parent.Children.Add(TextNode);
          end;
        end;

        // Comment?
        if (PeekAt(1) = '!') and (PeekAt(2) = '-') and (PeekAt(3) = '-') then
        begin
          SkipComment;
          Continue;
        end;

        // DOCTYPE?
        if (PeekAt(1) = '!') then
        begin
          SkipDoctype;
          Continue;
        end;

        // Closing tag?
        if PeekAt(1) = '/' then
        begin
          Advance(2); // skip '</'
          TagName := ReadTagName;
          // Skip to '>'
          while not AtEnd and (Peek <> '>') do
            Advance;
          if not AtEnd then
            Advance; // skip '>'
          if (StopTag <> '') and SameText(TagName, StopTag) then
            Exit;
          // Mismatched close tag — skip
          Continue;
        end;

        // Opening tag
        Advance; // skip '<'
        TagName := ReadTagName;
        if TagName = '' then
          Continue;

        // Parse attributes
        ChildTag := THTMLTag.Create;
        ChildTag.TagName := TagName;
        ChildTag.Parent := Parent;
        ParseAttributes(ChildTag);

        // Check for self-closing '/>'
        SelfClose := False;
        if not AtEnd and (Peek = '/') then
        begin
          Advance;
          SelfClose := True;
        end;
        if not AtEnd and (Peek = '>') then
          Advance; // skip '>'

        // <style> — capture CSS content
        if SameText(TagName, 'style') and not SelfClose then
        begin
          CSSContent := ReadRawContent(TagName);
          FStyleBlocks.Add(CSSContent);
          ChildTag.Free;
          Continue;
        end;

        // <script> — skip content
        if SameText(TagName, 'script') and not SelfClose then
        begin
          SkipRawContent(TagName);
          ChildTag.Free;
          Continue;
        end;

        // <link rel="stylesheet" href="..."> — capture href
        if SameText(TagName, 'link') then
        begin
          Rel := ChildTag.GetAttribute('rel', '').ToLower;
          Href := ChildTag.GetAttribute('href', '');
          if (Rel = 'stylesheet') and (Href <> '') then
            FLinkHrefs.Add(Href);
          ChildTag.Free;
          Continue;
        end;

        // Other ignored tags (head, meta, title)
        if IsIgnoredTag(TagName) then
        begin
          ChildTag.Free;
          Continue;
        end;

        Parent.Children.Add(ChildTag);

        // Void or self-closing — no children
        if IsVoidTag(TagName) or SelfClose then
          Continue;

        // Recurse children. Preserve raw whitespace inside <pre>, and inside any
        // element whose inline style asks for a preformatted white-space mode
        // (so `<div style="white-space:pre-wrap">` keeps its newlines — the DOM
        // stays collapsed everywhere else, which the layout re-processes).
        OldInPre := FInPre;
        if SameText(TagName, 'pre') or SameText(TagName, 'textarea') or
           (ChildTag.Style.TryGetValue('white-space', InlineWS) and
            LowerCase(Trim(InlineWS)).StartsWith('pre')) then
          FInPre := True;
        ParseChildren(ChildTag, TagName);
        FInPre := OldInPre;
      end
      else
      begin
        TextBuf.Append(Peek);
        Advance;
      end;
    end;

    // Flush remaining text
    if TextBuf.Length > 0 then
    begin
      RawText := TextBuf.ToString;
      DecodedText := DecodeEntities(RawText);
      if not FInPre then
      begin
        Collapsed := '';
        LastWasSpace := False;
        for C in DecodedText do
        begin
          if CharInSet(C, [' ', #9, #10, #13]) then
          begin
            if not LastWasSpace then
              Collapsed := Collapsed + ' ';
            LastWasSpace := True;
          end
          else
          begin
            Collapsed := Collapsed + C;
            LastWasSpace := False;
          end;
        end;
        DecodedText := Collapsed;
      end;
      if DecodedText <> '' then
      begin
        TextNode := THTMLTag.Create;
        TextNode.TagName := '#text';
        TextNode.Text := DecodedText;
        TextNode.Parent := Parent;
        Parent.Children.Add(TextNode);
      end;
    end;
  finally
    TextBuf.Free;
  end;
end;

procedure THTMLParser.Parse(const HTML: string);
var
  I: Integer;
begin
  // Clear old tree. Null each child's Parent before freeing so its now self-
  // detaching destructor doesn't mutate FRoot.Children mid-iteration; the
  // explicit Clear then drops the (freed) references. Index walk, not for-in.
  for I := FRoot.Children.Count - 1 downto 0 do
  begin
    FRoot.Children[I].Parent := nil;
    FRoot.Children[I].Free;
  end;
  FRoot.Children.Clear;
  FStyleBlocks.Clear;
  FLinkHrefs.Clear;

  FHTML := HTML;
  FLen := Length(FHTML);
  FPos := 1;
  FInPre := False;

  if FLen = 0 then Exit;

  ParseChildren(FRoot);
end;

// ═══════════════════════════════════════════════════════════════════════════
// TEdgeValues
// ═══════════════════════════════════════════════════════════════════════════

procedure TEdgeValues.Clear;
begin
  Top := 0; Right := 0; Bottom := 0; Left := 0;
end;

procedure TEdgeValues.SetAll(V: Single);
begin
  Top := V; Right := V; Bottom := V; Left := V;
end;

function TEdgeValues.Horz: Single;
begin
  Result := Left + Right;
end;

function TEdgeValues.Vert: Single;
begin
  Result := Top + Bottom;
end;

function TEdgeValues.Any: Boolean;
begin
  Result := (Top > 0) or (Right > 0) or (Bottom > 0) or (Left > 0);
end;

// ═══════════════════════════════════════════════════════════════════════════
// TComputedStyle
// ═══════════════════════════════════════════════════════════════════════════

procedure TComputedStyle.SetBorderWidth(W: Single);
begin
  BorderWidths.SetAll(W);
end;

procedure TComputedStyle.SetBorderColor(C: TAlphaColor);
begin
  BorderColors[0] := C;
  BorderColors[1] := C;
  BorderColors[2] := C;
  BorderColors[3] := C;
end;

function TComputedStyle.BorderColor: TAlphaColor;
begin
  Result := BorderColors[0];  // return top color as default
end;

function TComputedStyle.CornerRadius(Index: Integer): Single;
begin
  if (Index < 0) or (Index > 3) then Exit(0);
  if BorderRadii[Index] >= 0 then
    Result := BorderRadii[Index]
  else if BorderRadius > 0 then
    Result := BorderRadius
  else
    Result := 0;
end;

function TComputedStyle.HasUniformRadius: Boolean;
var
  R0: Single;
begin
  R0 := CornerRadius(0);
  Result := SameValue(R0, CornerRadius(1)) and
            SameValue(R0, CornerRadius(2)) and
            SameValue(R0, CornerRadius(3));
end;

function TComputedStyle.MaxCornerRadius: Single;
var
  I: Integer;
  V: Single;
begin
  Result := 0;
  for I := 0 to 3 do
  begin
    V := CornerRadius(I);
    if V > Result then Result := V;
  end;
end;

class function TComputedStyle.Default: TComputedStyle;
begin
  // FPC port note: the Delphi original left a handful of numeric fields
  // uninitialised (function-result garbage): BoxShadow offsets/colour,
  // text-shadow offsets/colour, gradient colours/angle, transform
  // translate/rotate. Zero them explicitly for determinism.
  Result.BoxShadow.OffsetX := 0;
  Result.BoxShadow.OffsetY := 0;
  Result.BoxShadow.BlurRadius := 0;
  Result.BoxShadow.SpreadRadius := 0;
  Result.BoxShadow.Color := 0;
  Result.BoxShadow.Inset := False;
  Result.TextShadowOffsetX := 0;
  Result.TextShadowOffsetY := 0;
  Result.TextShadowBlur := 0;
  Result.TextShadowColor := 0;
  Result.BgGradientStart := 0;
  Result.BgGradientEnd := 0;
  Result.BgGradientAngle := 0;
  Result.TransformTranslateX := 0;
  Result.TransformTranslateY := 0;
  Result.TransformRotate := 0;

  Result.FontFamily := 'Segoe UI';
  Result.FontSize := 14;
  Result.Bold := False;
  Result.FontWeight := 400;
  Result.Italic := False;
  Result.Color := TAlphaColors.Black;
  Result.BackgroundColor := TAlphaColors.Null;
  Result.TextDecoration := 'none';
  Result.TextAlign := TTextAlign.Leading;
  Result.TextJustify := False;
  Result.LineHeight := 1.4;
  Result.VerticalAlign := 'baseline';
  Result.CaptionSide := 'top';
  Result.Margin.Clear;
  Result.Padding.Clear;
  Result.SetBorderColor(TAlphaColors.Black);
  Result.BorderWidths.Clear;
  Result.BorderStyle := 'solid';
  Result.BorderRadius := -1;
  Result.BorderRadii[0] := -1;
  Result.BorderRadii[1] := -1;
  Result.BorderRadii[2] := -1;
  Result.BorderRadii[3] := -1;
  Result.ExplicitWidth := -1;
  Result.ExplicitHeight := -1;
  Result.AspectRatio := 0;
  Result.Display := 'block';
  Result.WhiteSpace := 'normal';
  Result.BoxSizing := 'content-box';
  Result.CSSCursor := '';
  Result.TextTransform := 'none';
  Result.Opacity := 1.0;
  Result.MinWidth := -1;
  Result.MaxWidth := -1;
  Result.MinHeight := -1;
  Result.MaxHeight := -1;
  Result.LetterSpacing := 0;
  Result.WordSpacing := 0;
  Result.ListStyleInside := False;
  Result.TextIndent := 0;
  Result.Visibility := 'visible';
  Result.ListStyleType := '';
  Result.Overflow := 'visible';
  Result.OverflowX := 'visible';
  Result.OverflowY := 'visible';
  Result.WordBreak := 'normal';
  Result.OverflowWrap := 'normal';
  Result.TextOverflow := 'clip';
  Result.BoxShadow.Active := False;
  Result.ObjectFit := 'fill';
  Result.BackgroundImage := '';
  Result.BackgroundSize := 'auto';
  Result.CSSPosition := 'static';
  Result.ZIndex := 0;
  Result.CSSTop := -9999;
  Result.CSSLeft := -9999;
  Result.CSSRight := -9999;
  Result.CSSBottom := -9999;
  Result.OutlineWidth := 0;
  Result.OutlineColor := TAlphaColors.Null;
  Result.OutlineStyle := 'none';
  Result.OutlineOffset := 0;
  Result.CSSFloat := 'none';
  Result.FlexDirection := 'row';
  Result.FlexWrap := 'nowrap';
  Result.JustifyContent := 'flex-start';
  Result.AlignItems := 'stretch';
  Result.AlignContent := 'stretch';
  Result.FlexGrow := 0;
  Result.FlexShrink := 1;
  Result.FlexBasis := -1;
  Result.FlexGap := 0;
  Result.AlignSelf := ''; Result.CSSOrder := 0;
  Result.GridTemplateColumns := ''; Result.GridTemplateRows := '';
  Result.GridColumn := ''; Result.GridRow := '';
  Result.RowGap := 0; Result.ColGap := 0;
  Result.TextShadowActive := False;
  Result.BgPosX := 0;
  Result.BgPosY := 0;
  Result.BgRepeat := 'no-repeat';
  Result.BgGradientActive := False;
  Result.BgGradientRadial := False;
  Result.GradStopCount := 0;
  Result.AppearanceNone := False;
  Result.AccentColor := 0; Result.CaretColor := 0; Result.PointerEventsNone := False; Result.BorderCollapse := False; Result.BorderSpacing := 0;
  Result.TransformActive := False;
  Result.TransformScaleX := 1;
  Result.TransformScaleY := 1;
  Result.CSSClear := 'none';
end;

class function TComputedStyle.ParseColor(const S: string): TAlphaColor;
var
  Str, Inner: string;
  R, G, B, A: Byte;
  Parts: TStringArray;
begin
  Result := TAlphaColors.Black;
  Str := S.Trim.ToLower;
  if Str = '' then Exit;

  // Named colors
  if Str = 'red' then Exit(TAlphaColors.Red);
  if Str = 'blue' then Exit(TAlphaColors.Blue);
  if Str = 'green' then Exit(TAlphaColors.Green);
  if Str = 'black' then Exit(TAlphaColors.Black);
  if Str = 'white' then Exit(TAlphaColors.White);
  if Str = 'gray' then Exit(TAlphaColors.Gray);
  if Str = 'grey' then Exit(TAlphaColors.Gray);
  if Str = 'silver' then Exit(TAlphaColors.Silver);
  if Str = 'maroon' then Exit($FF800000);
  if Str = 'navy' then Exit($FF000080);
  if Str = 'olive' then Exit($FF808000);
  if Str = 'teal' then Exit($FF008080);
  if Str = 'purple' then Exit($FF800080);
  if Str = 'fuchsia' then Exit(TAlphaColors.Fuchsia);
  if Str = 'aqua' then Exit(TAlphaColors.Aqua);
  if Str = 'lime' then Exit(TAlphaColors.Lime);
  if Str = 'orange' then Exit(TAlphaColors.Orange);
  if Str = 'yellow' then Exit(TAlphaColors.Yellow);
  if Str = 'pink' then Exit($FFFFC0CB);
  if Str = 'brown' then Exit($FFA52A2A);
  if Str = 'cyan' then Exit(TAlphaColors.Cyan);
  if Str = 'magenta' then Exit(TAlphaColors.Magenta);
  if Str = 'lightgray' then Exit(TAlphaColors.Lightgray);
  if Str = 'lightgrey' then Exit(TAlphaColors.Lightgray);
  if Str = 'darkgray' then Exit(TAlphaColors.Darkgray);
  if Str = 'darkgrey' then Exit(TAlphaColors.Darkgray);
  if Str = 'transparent' then Exit(TAlphaColors.Null);

  // #RGB or #RRGGBB
  if Str.StartsWith('#') then
  begin
    Str := Str.Substring(1);
    if Length(Str) = 3 then
      Str := Str[1] + Str[1] + Str[2] + Str[2] + Str[3] + Str[3];
    if Length(Str) = 6 then
    begin
      try
        R := StrToInt('$' + Str.Substring(0, 2));
        G := StrToInt('$' + Str.Substring(2, 2));
        B := StrToInt('$' + Str.Substring(4, 2));
        Result := (TAlphaColor(255) shl 24) or (TAlphaColor(R) shl 16) or
                  (TAlphaColor(G) shl 8) or TAlphaColor(B);
      except
      end;
    end;
    Exit;
  end;

  // rgb(r, g, b) or rgba(r, g, b, a)
  if Str.StartsWith('rgb') then
  begin
    Inner := Str;
    Inner := Inner.Replace('rgba(', '').Replace('rgb(', '').Replace(')', '');
    Parts := Inner.Split([',']);
    if Length(Parts) >= 3 then
    begin
      try
        R := StrToInt(Parts[0].Trim);
        G := StrToInt(Parts[1].Trim);
        B := StrToInt(Parts[2].Trim);
        if Length(Parts) >= 4 then
          A := Round(StrToFloat(Parts[3].Trim) * 255)
        else
          A := 255;
        Result := (TAlphaColor(A) shl 24) or (TAlphaColor(R) shl 16) or
                  (TAlphaColor(G) shl 8) or TAlphaColor(B);
      except
      end;
    end;
  end;
end;

{ ---- calc() / min() / max() / clamp() length evaluator ------------------- }

var
  GCalcVpW: Single = 0;     // viewport width  (px) for vw/vmin/vmax in calc
  GCalcVpH: Single = 0;     // viewport height (px) for vh/vmin/vmax in calc
  GCalcExprs: array of string;   // deferred %-bearing exprs, keyed by the marker
                                 // returned from ParseLength ("<emSize>|<expr>")

const
  CALC_DEFER = -100000;     // ParseLength returns CALC_DEFER-idx for a deferred expr

{ Reset the deferred-calc side table and set the viewport for vw/vh resolution
  (called by the layout engine before each build). }
procedure SetCalcContext(VpW, VpH: Single);
begin
  GCalcVpW := VpW; GCalcVpH := VpH;
  SetLength(GCalcExprs, 0);
end;

{ Evaluate a calc/min/max/clamp expression to px. `+ - * /` with the usual
  precedence, parens, px/em/rem/pt/vw/vh/vmin/vmax and % (% against PctBase; when
  PctBase < 0 the % is unknown → contributes 0 and HadPct is set). NestFns lets
  min()/max()/clamp() appear anywhere. }
function EvalCalc(const Expr: string; EmSize, PctBase: Single; out HadPct: Boolean): Single;
var P: Integer; S: string;

  procedure Skip; begin while (P <= Length(S)) and (S[P] = ' ') do Inc(P); end;
  function ParseE: Single; forward;

  function UnitVal(const Num: string; const U: string): Single;
  var n: Single;
  begin
    n := StrToFloatDef(Num, 0);
    if U = 'px' then Result := n
    else if U = 'rem' then Result := n * 16
    else if U = 'em' then Result := n * EmSize
    else if U = 'pt' then Result := n * 1.333
    else if U = 'vw' then Result := n * GCalcVpW / 100
    else if U = 'vh' then Result := n * GCalcVpH / 100
    else if U = 'vmin' then Result := n * Min(GCalcVpW, GCalcVpH) / 100
    else if U = 'vmax' then Result := n * Max(GCalcVpW, GCalcVpH) / 100
    else if U = '%' then
    begin
      HadPct := True;
      if PctBase >= 0 then Result := n * PctBase / 100 else Result := 0;
    end
    else Result := n;   // unitless
  end;

  function ParseFactor: Single;
  var st, num, u: Integer; fn: string; args: array of Single; na: Integer;
  begin
    Skip;
    Result := 0;
    if P > Length(S) then Exit;
    if S[P] = '(' then
    begin Inc(P); Result := ParseE; Skip; if (P <= Length(S)) and (S[P] = ')') then Inc(P); Exit; end;
    if S[P] = '-' then begin Inc(P); Exit(-ParseFactor); end;
    if S[P] = '+' then begin Inc(P); Exit(ParseFactor); end;
    // function: min / max / clamp
    if (S[P] in ['a'..'z']) then
    begin
      st := P;
      while (P <= Length(S)) and (S[P] in ['a'..'z']) do Inc(P);
      fn := Copy(S, st, P - st);
      Skip;
      if (P <= Length(S)) and (S[P] = '(') then
      begin
        Inc(P); na := 0;
        repeat
          SetLength(args, na + 1); args[na] := ParseE; Inc(na); Skip;
          if (P <= Length(S)) and (S[P] = ',') then begin Inc(P); Continue; end;
          Break;
        until False;
        if (P <= Length(S)) and (S[P] = ')') then Inc(P);
        if (fn = 'min') and (na > 0) then
        begin Result := args[0]; for u := 1 to na - 1 do Result := Min(Result, args[u]); end
        else if (fn = 'max') and (na > 0) then
        begin Result := args[0]; for u := 1 to na - 1 do Result := Max(Result, args[u]); end
        else if (fn = 'clamp') and (na >= 3) then
          Result := Min(Max(args[0], args[1]), args[2])
        else if na > 0 then Result := args[0];
        Exit;
      end;
      Exit(0);   // bare identifier we don't know
    end;
    // number with optional unit
    st := P;
    while (P <= Length(S)) and (S[P] in ['0'..'9', '.']) do Inc(P);
    num := st;
    u := P;
    while (P <= Length(S)) and (S[P] in ['a'..'z', '%']) do Inc(P);
    Result := UnitVal(Copy(S, num, u - num), Copy(S, u, P - u));
  end;

  function ParseT: Single;
  var op: Char; rhs: Single;
  begin
    Result := ParseFactor; Skip;
    while (P <= Length(S)) and (S[P] in ['*', '/']) do
    begin
      op := S[P]; Inc(P); rhs := ParseFactor;
      if op = '*' then Result := Result * rhs
      else if rhs <> 0 then Result := Result / rhs else Result := 0;
      Skip;
    end;
  end;

  function ParseE: Single;
  var op: Char;
  begin
    Result := ParseT; Skip;
    while (P <= Length(S)) and (S[P] in ['+', '-']) do
    begin
      op := S[P]; Inc(P);
      if op = '+' then Result := Result + ParseT else Result := Result - ParseT;
      Skip;
    end;
  end;

begin
  HadPct := False;
  S := Expr; P := 1;
  Result := ParseE;
end;

{ Resolve a ParseLength result that was deferred (a %-bearing calc) now that the
  percentage base is known. Returns V unchanged when it is not a deferred marker. }
function ResolveCalc(V, PctBase: Single): Single;
var idx, bar: Integer; rec, emS, expr: string; dummy: Boolean;
begin
  Result := V;
  if V > CALC_DEFER + 1 then Exit;     // not a deferred marker
  idx := Round(CALC_DEFER - V);
  if (idx < 0) or (idx > High(GCalcExprs)) then Exit(0);
  rec := GCalcExprs[idx];
  bar := Pos('|', rec);
  emS := Copy(rec, 1, bar - 1); expr := Copy(rec, bar + 1, MaxInt);
  Result := EvalCalc(expr, StrToFloatDef(emS, 16), PctBase, dummy);
end;

class function TComputedStyle.ParseLength(const S: string; EmSize: Single): Single;
var
  Str: string;
  CalcInner: string;
  Terms: TStringArray;
  Term: string;
  I: Integer;
  HadPctDummy: Boolean;
begin
  Str := S.Trim.ToLower;
  if Str = '' then Exit(0);
  if Str = 'auto' then Exit(-1);
  // Shrink-to-fit width keywords collapse onto a single sentinel (-3).
  if (Str = 'fit-content') or (Str = 'min-content') or (Str = 'max-content') then
    Exit(-3);

  // calc() / min() / max() / clamp(): full expression eval (+ - * /, px/em/rem/
  // pt/vw/vh/vmin/vmax). A % term needs the container size, so those are deferred
  // (a marker resolved by ResolveCalc at layout time); %-free exprs resolve now.
  if Str.StartsWith('calc(') or Str.StartsWith('min(') or
     Str.StartsWith('max(') or Str.StartsWith('clamp(') then
  begin
    if Str.StartsWith('calc(') and Str.EndsWith(')') then
      CalcInner := Copy(Str, 6, Length(Str) - 6).Trim
    else
      CalcInner := Str;   // min()/max()/clamp() are themselves the expression
    if Pos('%', CalcInner) > 0 then
    begin
      I := Length(GCalcExprs); SetLength(GCalcExprs, I + 1);
      GCalcExprs[I] := FloatToStr(EmSize) + '|' + CalcInner;
      Exit(CALC_DEFER - I);
    end;
    Result := EvalCalc(CalcInner, EmSize, -1, HadPctDummy);
    if Result < 0 then Result := 0;   // a negative size collides with %-markers; clamp
    Exit;
  end;

  if Str.EndsWith('rem') then
  begin
    // rem = root em; approximate as 16px base (since we don't track root font size)
    Result := StrToFloatDef(Str.Replace('rem', ''), 0) * 16;
  end
  else if Str.EndsWith('em') then
  begin
    Result := StrToFloatDef(Str.Replace('em', ''), 0) * EmSize;
  end
  else if Str.EndsWith('px') then
  begin
    Result := StrToFloatDef(Str.Replace('px', ''), 0);
  end
  else if Str.EndsWith('pt') then
  begin
    Result := StrToFloatDef(Str.Replace('pt', ''), 0) * 1.333;
  end
  else if Str.EndsWith('%') then
  begin
    // Percentage — return negative value as marker
    Result := -StrToFloatDef(Str.Replace('%', ''), 0);
  end
  else
    Result := StrToFloatDef(Str, 0);
end;

class procedure TComputedStyle.ParseEdgeShorthand(const S: string; var E: TEdgeValues; EmSize: Single);
var
  Parts: TStringArray;
begin
  Parts := S.Trim.Split([' ']);
  case Length(Parts) of
    1: E.SetAll(ParseLength(Parts[0], EmSize));
    2: begin
         E.Top := ParseLength(Parts[0], EmSize);
         E.Bottom := E.Top;
         E.Right := ParseLength(Parts[1], EmSize);
         E.Left := E.Right;
       end;
    3: begin
         E.Top := ParseLength(Parts[0], EmSize);
         E.Right := ParseLength(Parts[1], EmSize);
         E.Left := E.Right;
         E.Bottom := ParseLength(Parts[2], EmSize);
       end;
  else
    if Length(Parts) >= 4 then
    begin
      E.Top := ParseLength(Parts[0], EmSize);
      E.Right := ParseLength(Parts[1], EmSize);
      E.Bottom := ParseLength(Parts[2], EmSize);
      E.Left := ParseLength(Parts[3], EmSize);
    end;
  end;
end;

class function TComputedStyle.ForTag(Tag: THTMLTag; const ParentStyle: TComputedStyle; StyleSheet: TCSSStyleSheet): TComputedStyle;
var
  TN, Temp, BtnClass: string;
  Level: Integer;
  BdrW: Single;
  CSSDecls: TCSSDeclarations;
begin
  // FPC port note: zero the fields the Delphi original left uninitialised
  // (see Default) for determinism.
  Result.BoxShadow.OffsetX := 0;
  Result.BoxShadow.OffsetY := 0;
  Result.BoxShadow.BlurRadius := 0;
  Result.BoxShadow.SpreadRadius := 0;
  Result.BoxShadow.Color := 0;
  Result.BoxShadow.Inset := False;
  Result.BoxShadow.Active := False;
  Result.TextShadowOffsetX := 0;
  Result.TextShadowOffsetY := 0;
  Result.TextShadowBlur := 0;
  Result.TextShadowColor := 0;
  Result.BgGradientStart := 0;
  Result.BgGradientEnd := 0;
  Result.BgGradientAngle := 0;
  Result.TransformTranslateX := 0;
  Result.TransformTranslateY := 0;
  Result.TransformRotate := 0;

  // Inherit from parent
  Result.FontFamily := ParentStyle.FontFamily;
  Result.FontSize := ParentStyle.FontSize;
  Result.Bold := ParentStyle.Bold;
  Result.FontWeight := ParentStyle.FontWeight;
  Result.Italic := ParentStyle.Italic;
  Result.Color := ParentStyle.Color;
  Result.TextAlign := ParentStyle.TextAlign;
  Result.TextJustify := ParentStyle.TextJustify;
  Result.LineHeight := ParentStyle.LineHeight;
  Result.WhiteSpace := ParentStyle.WhiteSpace;
  Result.ListStyleType := ParentStyle.ListStyleType;
  Result.TextTransform := ParentStyle.TextTransform;
  Result.LetterSpacing := ParentStyle.LetterSpacing;
  Result.WordSpacing := ParentStyle.WordSpacing;
  Result.ListStyleInside := ParentStyle.ListStyleInside;
  Result.TextIndent := ParentStyle.TextIndent;
  Result.Visibility := ParentStyle.Visibility;
  Result.WordBreak := ParentStyle.WordBreak;
  Result.OverflowWrap := ParentStyle.OverflowWrap;
  Result.CaptionSide := ParentStyle.CaptionSide;  // inherited
  Result.VerticalAlign := 'baseline';

  // Non-inherited defaults
  Result.BackgroundColor := TAlphaColors.Null;
  Result.TextDecoration := 'none';
  Result.Margin.Clear;
  Result.Padding.Clear;
  Result.SetBorderColor(TAlphaColors.Black);
  Result.BorderWidths.Clear;
  Result.BorderStyle := 'solid';
  Result.BorderRadius := -1;
  Result.BorderRadii[0] := -1;
  Result.BorderRadii[1] := -1;
  Result.BorderRadii[2] := -1;
  Result.BorderRadii[3] := -1;
  Result.ExplicitWidth := -1;
  Result.ExplicitHeight := -1;
  Result.AspectRatio := 0;
  Result.Display := 'inline';
  Result.BoxSizing := 'content-box';
  Result.CSSCursor := '';
  Result.Opacity := 1.0;
  Result.MinWidth := -1;
  Result.MaxWidth := -1;
  Result.MinHeight := -1;
  Result.MaxHeight := -1;
  Result.Overflow := 'visible';
  Result.OverflowX := 'visible';
  Result.OverflowY := 'visible';
  Result.TextOverflow := 'clip';
  Result.ObjectFit := 'fill';
  Result.BackgroundImage := '';
  Result.BackgroundSize := 'auto';
  Result.CSSPosition := 'static';
  Result.ZIndex := 0;
  Result.CSSTop := -9999;
  Result.CSSLeft := -9999;
  Result.CSSRight := -9999;
  Result.CSSBottom := -9999;
  Result.OutlineWidth := 0;
  Result.OutlineColor := TAlphaColors.Null;
  Result.OutlineStyle := 'none';
  Result.OutlineOffset := 0;
  Result.CSSFloat := 'none';
  Result.FlexDirection := 'row';
  Result.FlexWrap := 'nowrap';
  Result.JustifyContent := 'flex-start';
  Result.AlignItems := 'stretch';
  Result.AlignContent := 'stretch';
  Result.FlexGrow := 0;
  Result.FlexShrink := 1;
  Result.FlexBasis := -1;
  Result.FlexGap := 0;
  Result.AlignSelf := ''; Result.CSSOrder := 0;
  Result.GridTemplateColumns := ''; Result.GridTemplateRows := '';
  Result.GridColumn := ''; Result.GridRow := '';
  Result.RowGap := 0; Result.ColGap := 0;
  Result.TextShadowActive := False;
  Result.BgPosX := 0;
  Result.BgPosY := 0;
  Result.BgRepeat := 'no-repeat';
  Result.BgGradientActive := False;
  Result.BgGradientRadial := False;
  Result.GradStopCount := 0;
  Result.AppearanceNone := False;
  Result.AccentColor := 0; Result.CaretColor := 0; Result.PointerEventsNone := False; Result.BorderCollapse := False; Result.BorderSpacing := 0;
  Result.TransformActive := False;
  Result.TransformScaleX := 1;
  Result.TransformScaleY := 1;
  Result.CSSClear := 'none';

  if Tag = nil then Exit;
  TN := Tag.TagName.ToLower;

  // Text node — pure inline
  if TN = '#text' then
  begin
    Result.Display := 'inline';
    Exit;
  end;

  // User-agent defaults per tag
  if THTMLParser.IsBlockTag(TN) then
    Result.Display := 'block';

  // Headings
  if (Length(TN) = 2) and (TN[1] = 'h') and CharInSet(TN[2], ['1'..'6']) then
  begin
    Level := Ord(TN[2]) - Ord('0');
    case Level of
      1: Result.FontSize := 32;
      2: Result.FontSize := 24;
      3: Result.FontSize := 19;
      4: Result.FontSize := 16;
      5: Result.FontSize := 13;
      6: Result.FontSize := 11;
    end;
    Result.Bold := True;
    Result.Margin.Top := Result.FontSize * 0.67;
    Result.Margin.Bottom := Result.FontSize * 0.67;
  end
  else if TN = 'p' then
  begin
    Result.Margin.Top := ParentStyle.FontSize * 0.5;
    Result.Margin.Bottom := ParentStyle.FontSize * 0.5;
  end
  else if TN = 'blockquote' then
  begin
    Result.Margin.Top := ParentStyle.FontSize;
    Result.Margin.Bottom := ParentStyle.FontSize;
    Result.Margin.Left := 40;
    Result.Padding.Left := 10;
    Result.SetBorderWidth(3);
    Result.SetBorderColor(TAlphaColors.Lightgray);
  end
  else if TN = 'pre' then
  begin
    Result.FontFamily := 'Courier New';
    Result.BackgroundColor := $FFF5F5F5;
    Result.Padding.SetAll(8);
    Result.WhiteSpace := 'pre';
    Result.Margin.Top := ParentStyle.FontSize * 0.5;
    Result.Margin.Bottom := ParentStyle.FontSize * 0.5;
  end
  else if TN = 'code' then
  begin
    Result.FontFamily := 'Courier New';
    Result.BackgroundColor := $FFF0F0F0;
    Result.Padding.Left := 3;
    Result.Padding.Right := 3;
  end
  else if (TN = 'b') or (TN = 'strong') then
    Result.Bold := True
  else if (TN = 'i') or (TN = 'em') then
    Result.Italic := True
  else if TN = 'u' then
    Result.TextDecoration := 'underline'
  else if (TN = 'del') or (TN = 's') or (TN = 'strike') then
    Result.TextDecoration := 'line-through'
  else if TN = 'a' then
  begin
    Result.Color := $FF0066CC;
    Result.TextDecoration := 'underline';
  end
  else if TN = 'mark' then
    Result.BackgroundColor := $FFFFFF00
  else if TN = 'small' then
    Result.FontSize := ParentStyle.FontSize * 0.85
  else if TN = 'sub' then
  begin
    Result.FontSize := ParentStyle.FontSize * 0.75;
    Result.VerticalAlign := 'sub';
  end
  else if TN = 'sup' then
  begin
    Result.FontSize := ParentStyle.FontSize * 0.75;
    Result.VerticalAlign := 'super';
  end
  else if (TN = 'ul') or (TN = 'menu') then
  begin
    Result.Margin.Top := ParentStyle.FontSize * 0.5;
    Result.Margin.Bottom := ParentStyle.FontSize * 0.5;
    Result.Padding.Left := 32;
    Result.ListStyleType := 'disc';
  end
  else if TN = 'ol' then
  begin
    Result.Margin.Top := ParentStyle.FontSize * 0.5;
    Result.Margin.Bottom := ParentStyle.FontSize * 0.5;
    Result.Padding.Left := 32;
    Result.ListStyleType := 'decimal';
  end
  else if TN = 'li' then
  begin
    Result.Display := 'list-item';
    Result.Margin.Top := 2;
    Result.Margin.Bottom := 2;
  end
  else if TN = 'table' then
    Result.Display := 'table'  // no UA margin (browsers give tables none)
  else if TN = 'tr' then
    Result.Display := 'table-row'
  else if (TN = 'td') then
  begin
    Result.Display := 'table-cell';
    Result.Padding.SetAll(4);
  end
  else if (TN = 'th') then
  begin
    Result.Display := 'table-cell';
    Result.Bold := True;
    Result.TextAlign := TTextAlign.Center;
    Result.Padding.SetAll(4);
  end
  else if (TN = 'thead') or (TN = 'tbody') or (TN = 'tfoot') then
    Result.Display := 'table-row'  // group — treated as pass-through
  else if TN = 'caption' then
  begin
    Result.Display := 'block';
    Result.TextAlign := TTextAlign.Center;
    Result.Padding.SetAll(2);
  end
  else if TN = 'figure' then
  begin
    Result.Display := 'block';
    Result.Margin.Top := ParentStyle.FontSize;    // UA: 1em 40px
    Result.Margin.Bottom := ParentStyle.FontSize;
    Result.Margin.Left := 40;
    Result.Margin.Right := 40;
  end
  else if TN = 'address' then
  begin
    Result.Display := 'block';
    Result.Italic := True;                         // UA: font-style italic
  end
  else if TN = 'video' then
  begin
    // A shell-owned native player sits on top; the core reserves a correctly
    // sized box (HTML default intrinsic size 300x150). A `poster` image shows
    // through until the native player draws; otherwise a black poster area.
    Result.Display := 'inline-block';
    Result.BackgroundColor := $FF000000;
    if Tag.HasAttribute('poster') then
    begin
      Result.BackgroundImage := Tag.GetAttribute('poster');
      Result.BackgroundSize := 'cover';
    end;
    if Result.ExplicitWidth < 0 then Result.ExplicitWidth := 300;
    if Result.ExplicitHeight < 0 then Result.ExplicitHeight := 150;
  end
  else if TN = 'audio' then
  begin
    // shell-owned native audio player over a core placeholder box. Only shown
    // with `controls` (a bare <audio> is display:none, like a browser). The
    // control-bar intrinsic size is 300x54.
    if Tag.HasAttribute('controls') then
    begin
      Result.Display := 'inline-block';
      Result.BackgroundColor := $FFF1F3F4;      // light control-bar backing
      if Result.ExplicitWidth < 0 then Result.ExplicitWidth := 300;
      if Result.ExplicitHeight < 0 then Result.ExplicitHeight := 54;
    end
    else
      Result.Display := 'none';
  end
  else if TN = 'canvas' then
  begin
    // core-rendered drawing surface (Tina4Canvas2D painter); HTML default 300x150
    Result.Display := 'inline-block';
    if Result.ExplicitWidth < 0 then Result.ExplicitWidth := 300;
    if Result.ExplicitHeight < 0 then Result.ExplicitHeight := 150;
  end
  else if TN = 'lottie' then
  begin
    // Tina4 custom: a core-rendered Lottie animation (inline JSON content)
    Result.Display := 'inline-block';
    if Result.ExplicitWidth < 0 then Result.ExplicitWidth := 240;
    if Result.ExplicitHeight < 0 then Result.ExplicitHeight := 240;
  end
  else if TN = 'dialog' then
  begin
    // UA: dialog:not([open]) { display:none }. An open dialog is a bordered,
    // padded box on a white ground (modal backdrop/centering needs scripting).
    if Tag.HasAttribute('open') then
    begin
      Result.Display := 'block';
      Result.SetBorderWidth(2);
      Result.SetBorderColor($FF000000);
      Result.Padding.SetAll(12);
      Result.BackgroundColor := $FFFFFFFF;
    end
    else
      Result.Display := 'none';
  end
  else if TN = 'hr' then
  begin
    Result.Margin.Top := 8;
    Result.Margin.Bottom := 8;
    Result.ExplicitHeight := 1;        // a 1px horizontal rule …
    Result.BackgroundColor := $FFC7C7CC; // … painted as a thin grey line
  end
  else if (TN = 'template') or (TN = 'datalist') then
    Result.Display := 'none'           // inert: parsed but never rendered
  else if TN = 'br' then
    Result.Display := 'inline'
  else if TN = 'img' then
    Result.Display := 'inline'
  else if (TN = 'input') or (TN = 'button') or (TN = 'textarea') or (TN = 'select') then
    Result.Display := 'inline-block'  // UA default; .form-control etc. may set 'block'
  else if TN = 'dt' then
    Result.Bold := True
  else if TN = 'dd' then
    Result.Margin.Left := 40
  else if TN = 'kbd' then
  begin
    Result.FontFamily := 'Courier New';
    Result.FontSize := ParentStyle.FontSize * 0.9;
    Result.BackgroundColor := $FFF0F0F0;
    Result.SetBorderColor($FFCCCCCC);
    Result.SetBorderWidth(1);
    Result.BorderRadius := 3;
    Result.Padding.SetAll(2);
  end
  else if TN = 'abbr' then
    Result.TextDecoration := 'underline'
  else if TN = 'ins' then
    Result.TextDecoration := 'underline'
  else if TN = 'summary' then
  begin
    Result.Display := 'block';
    Result.Padding.Left := 18;   // room for the disclosure triangle
    Result.Bold := True;
  end
  else if (TN = 'cite') or (TN = 'dfn') then
    Result.Italic := True
  else if (TN = 'var') then
  begin
    Result.Italic := True;
    Result.FontFamily := 'Courier New';
  end
  else if TN = 'samp' then
    Result.FontFamily := 'Courier New'
  else if TN = 'fieldset' then
  begin
    Result.SetBorderColor($FF808080);
    Result.SetBorderWidth(2);
    Result.BorderRadius := 4;
    Result.Padding.SetAll(10);
    Result.Margin.Top := 8;
    Result.Margin.Bottom := 8;
  end
  else if TN = 'legend' then
  begin
    // The legend straddles the fieldset's top border and masks the segment
    // behind it (the classic notch): a negative top margin lifts it onto the
    // border line, and its own background — painted after the border — cuts the
    // gap. Inherit the parent's background so the notch matches the page; fall
    // back to white when transparent.
    Result.Bold := True;
    Result.Padding.Left := 6;
    Result.Padding.Right := 6;
    Result.Margin.Top := -(Result.FontSize * 0.6 + 2);   // lift onto the border
    if (ParentStyle.BackgroundColor shr 24) > 0 then
      Result.BackgroundColor := ParentStyle.BackgroundColor
    else
      Result.BackgroundColor := $FFFFFFFF;
  end;

  // HTML attribute overrides
  if Tag.HasAttribute('width') then
    Result.ExplicitWidth := ParseLength(Tag.GetAttribute('width'), Result.FontSize);
  if Tag.HasAttribute('height') then
    Result.ExplicitHeight := ParseLength(Tag.GetAttribute('height'), Result.FontSize);
  if Tag.HasAttribute('bgcolor') then
    Result.BackgroundColor := ParseColor(Tag.GetAttribute('bgcolor'));
  if Tag.HasAttribute('align') then
  begin
    Temp := Tag.GetAttribute('align').ToLower;
    if Temp = 'center' then Result.TextAlign := TTextAlign.Center
    else if Temp = 'right' then Result.TextAlign := TTextAlign.Trailing;
  end;
  if Tag.HasAttribute('border') then
  begin
    BdrW := StrToFloatDef(Tag.GetAttribute('border'), 0);
    Result.SetBorderWidth(BdrW);
    if BdrW > 0 then
      Result.SetBorderColor(TAlphaColors.Black);
  end;

  // Stylesheet rules (lower priority than inline)
  if Assigned(StyleSheet) then
  begin
    CSSDecls := TCSSDeclarations.Create;
    try
      StyleSheet.ApplyTo(Tag, CSSDecls);
      if CSSDecls.Count > 0 then
        ApplyDeclarations(CSSDecls, Result, ParentStyle);
    finally
      CSSDecls.Free;
    end;
  end;

  // Inline style overrides (highest priority)
  if Tag.Style.Count > 0 then
    ApplyDeclarations(Tag.Style, Result, ParentStyle);

  // the `hidden` attribute is equivalent to display:none
  if Tag.HasAttribute('hidden') then
    Result.Display := 'none';

  // Bootstrap button class fallback — for non-native elements (span, div, a)
  // that have btn classes. Always apply layout properties; only apply colors
  // when CSS variable resolution didn't provide them.
  if not SameText(TN, 'button') and not SameText(TN, 'input') and
     not SameText(TN, '#text') then
  begin
    BtnClass := Tag.GetAttribute('class', '').ToLower;
    if BtnClass.Contains('btn-primary') or BtnClass.Contains('btn-secondary') or
       BtnClass.Contains('btn-success') or BtnClass.Contains('btn-danger') or
       BtnClass.Contains('btn-warning') or BtnClass.Contains('btn-info') or
       BtnClass.Contains('btn-dark') or BtnClass.Contains('btn-light') then
    begin
      // Color fallback — only when CSS didn't provide a background
      if Result.BackgroundColor = TAlphaColors.Null then
      begin
        if BtnClass.Contains('btn-primary') then begin Result.BackgroundColor := $FF0D6EFD; Result.Color := TAlphaColors.White; end
        else if BtnClass.Contains('btn-secondary') then begin Result.BackgroundColor := $FF6C757D; Result.Color := TAlphaColors.White; end
        else if BtnClass.Contains('btn-success') then begin Result.BackgroundColor := $FF198754; Result.Color := TAlphaColors.White; end
        else if BtnClass.Contains('btn-danger') then begin Result.BackgroundColor := $FFDC3545; Result.Color := TAlphaColors.White; end
        else if BtnClass.Contains('btn-warning') then begin Result.BackgroundColor := $FFFFC107; Result.Color := TAlphaColors.Black; end
        else if BtnClass.Contains('btn-info') then begin Result.BackgroundColor := $FF0DCAF0; Result.Color := TAlphaColors.Black; end
        else if BtnClass.Contains('btn-dark') then begin Result.BackgroundColor := $FF212529; Result.Color := TAlphaColors.White; end
        else if BtnClass.Contains('btn-light') then begin Result.BackgroundColor := $FFF8F9FA; Result.Color := TAlphaColors.Black; end;
      end;
      // Layout properties — always apply as defaults
      if Result.Display <> 'inline-block' then
        Result.Display := 'inline-block';
      Result.TextAlign := TTextAlign.Center;
      if (Result.Padding.Top = 0) and (Result.Padding.Bottom = 0) then
      begin
        Result.Padding.Top := 6;    // 0.375rem ~ 6px
        Result.Padding.Bottom := 6;
        Result.Padding.Left := 12;  // 0.75rem ~ 12px
        Result.Padding.Right := 12;
      end;
      if Result.BorderRadius < 0 then
        Result.BorderRadius := 6;   // 0.375rem ~ 6px
    end;
  end;
end;

class procedure TComputedStyle.ExtractBgImageUrl(const Value: string; out Url: string);
var
  S: string;
  P1, P2: Integer;
begin
  Url := '';
  S := Value.Trim;
  P1 := S.ToLower.IndexOf('url(');
  if P1 < 0 then Exit;
  P2 := S.LastIndexOf(')');
  if P2 <= P1 + 4 then Exit;
  Url := S.Substring(P1 + 4, P2 - P1 - 4).Trim;
  // Strip quotes
  if (Url.Length >= 2) and ((Url.Chars[0] = '''') or (Url.Chars[0] = '"')) then
    Url := Url.Substring(1, Url.Length - 2);
end;

{ Split on commas that are NOT inside parentheses, so rgb(…)/var(…) stops in a
  gradient argument list survive intact. }
function SplitTopLevelCommas(const S: string): TStringArray;
var
  i, depth, start, n: Integer;
begin
  SetLength(Result, 0);
  depth := 0; start := 1; n := 0;
  for i := 1 to Length(S) do
  begin
    if S[i] = '(' then Inc(depth)
    else if S[i] = ')' then Dec(depth)
    else if (S[i] = ',') and (depth = 0) then
    begin
      SetLength(Result, n + 1);
      Result[n] := Copy(S, start, i - start); Inc(n);
      start := i + 1;
    end;
  end;
  SetLength(Result, n + 1);
  Result[n] := Copy(S, start, Length(S) - start + 1);
end;

{ Parse one gradient colour stop ("#fff", "var(--x)", "red 50%") and append it
  to the style's stop arrays (capped at 8). }
procedure ParseGradientStop(const S: string; var Style: TComputedStyle);
var
  t, colStr, posStr: string;
  sp: Integer;
  pos: Single;
begin
  if Style.GradStopCount >= 8 then Exit;
  t := Trim(S);
  if t = '' then Exit;
  pos := -1;                       // auto
  // a trailing "NN%" is the stop position; keep the rest as the colour
  sp := t.LastIndexOf(' ');
  if (sp > 0) then
  begin
    posStr := Trim(Copy(t, sp + 2, MaxInt));
    if posStr.EndsWith('%') then
    begin
      pos := StrToFloatDef(Copy(posStr, 1, Length(posStr) - 1), -1) / 100;
      colStr := Trim(Copy(t, 1, sp));
    end
    else colStr := t;
  end
  else colStr := t;
  Style.GradStopColors[Style.GradStopCount] := TComputedStyle.ParseColor(colStr);
  Style.GradStopPos[Style.GradStopCount] := pos;
  Inc(Style.GradStopCount);
end;

{ Parse an `aspect-ratio` value: "16 / 9", a bare number "1.5", or "auto" (0). }
function ParseAspectRatio(const S: string): Single;
var t: string; p: Integer; aw, ah: Single;
begin
  Result := 0;
  t := Trim(LowerCase(S));
  if (t = '') or (t = 'auto') then Exit;
  p := Pos('/', t);
  if p > 0 then
  begin
    aw := StrToFloatDef(Trim(Copy(t, 1, p - 1)), 0);
    ah := StrToFloatDef(Trim(Copy(t, p + 1, MaxInt)), 0);
    if (aw > 0) and (ah > 0) then Result := aw / ah;
  end
  else
  begin
    aw := StrToFloatDef(t, 0);
    if aw > 0 then Result := aw;
  end;
end;

class procedure TComputedStyle.ApplyDeclarations(Decls: TCSSDeclarations; var Style: TComputedStyle; const ParentStyle: TComputedStyle);
var
  Temp: string;
  BgVal, ColorPart: string;
  UrlPos: Integer;
  LH: Single;
  BParts, RParts, OvParts, SParts, OParts, FlexParts, TsParts, BgParts, GArgs, InsetParts, TfArgs: TStringArray;
  BP, BT, SP, ST, OP, OT, TsP, TsT, GArg, OvPart: string;
  R0, Ra, Rb, Rc, PL: Single;
  FParts: TStringArray;
  fi, slashp, fj: Integer;
  fLp, fSz, fLhs, fFam: string;
  Nums: array of Single;
  ShadowStr, OutlineStr, FloatStr, ClrStr, FlexStr, TsStr: string;
  InsT, InsR, InsB, InsL: string;
  GradientSrc, GSrc, GLower, GInner, GAngleStr: string;
  GP1, GP2: Integer;
  GColors: array of TAlphaColor;
  TfStr, FnName, ArgStr, AStr: string;
  TfPos, NameStart, ArgStart: Integer;

  function ShouldSkip(const V: string): Boolean;
  var TV: string;
  begin
    TV := V.Trim;
    Result := TV.Contains('var(') or SameText(TV, 'inherit') or
      SameText(TV, 'initial') or SameText(TV, 'unset') or SameText(TV, 'revert');
  end;

begin
  if Decls.TryGetValue('color', Temp) and not ShouldSkip(Temp) then
    Style.Color := ParseColor(Temp);
  if Decls.TryGetValue('background-color', Temp) and not ShouldSkip(Temp) then
    Style.BackgroundColor := ParseColor(Temp);
  if Decls.TryGetValue('background', Temp) and not ShouldSkip(Temp) then
  begin
    BgVal := Temp.Trim;
    // Extract url(...) if present
    if BgVal.ToLower.Contains('url(') then
    begin
      ExtractBgImageUrl(BgVal, Style.BackgroundImage);
      // Try to parse a color from the portion before url()
      UrlPos := BgVal.ToLower.IndexOf('url(');
      if UrlPos > 0 then
      begin
        ColorPart := BgVal.Substring(0, UrlPos).Trim;
        if ColorPart <> '' then
          Style.BackgroundColor := ParseColor(ColorPart);
      end;
    end
    else if not BgVal.ToLower.Contains('gradient(') then
      // a gradient value is handled by the gradient parser below; don't let
      // ParseColor turn it into a bogus solid colour
      Style.BackgroundColor := ParseColor(BgVal);
  end;
  if Decls.TryGetValue('font-family', Temp) and not ShouldSkip(Temp) then
    Style.FontFamily := Temp.DeQuotedString('''').DeQuotedString('"');
  if Decls.TryGetValue('font-size', Temp) and not ShouldSkip(Temp) then
  begin
    Temp := Temp.Trim;
    if Temp.EndsWith('%') then
      // font-size:% resolves against the PARENT font-size (ParseLength would
      // return a negative percentage marker that corrupts layout)
      Style.FontSize := ParentStyle.FontSize *
        StrToFloatDef(Copy(Temp, 1, Length(Temp) - 1), 100) / 100
    else
      Style.FontSize := ParseLength(Temp, ParentStyle.FontSize);
  end;
  if Decls.TryGetValue('font-weight', Temp) and not ShouldSkip(Temp) then
  begin
    Temp := Temp.Trim.ToLower;
    if Temp = 'normal' then Style.FontWeight := 400
    else if Temp = 'bold' then Style.FontWeight := 700
    else if Temp = 'bolder' then Style.FontWeight := 700
    else if Temp = 'lighter' then Style.FontWeight := 300
    else if Temp = 'light' then Style.FontWeight := 300
    else if Temp = 'medium' then Style.FontWeight := 500
    else if Temp = 'semibold' then Style.FontWeight := 600
    else if Temp = 'black' then Style.FontWeight := 900
    else Style.FontWeight := StrToIntDef(Temp, 400);
    Style.Bold := Style.FontWeight >= 600;   // legacy flag
  end;
  if Decls.TryGetValue('font-style', Temp) and not ShouldSkip(Temp) then
    Style.Italic := SameText(Temp, 'italic') or SameText(Temp, 'oblique');
  if Decls.TryGetValue('text-decoration', Temp) and not ShouldSkip(Temp) then
    Style.TextDecoration := Temp.ToLower;
  if Decls.TryGetValue('text-align', Temp) and not ShouldSkip(Temp) then
  begin
    Temp := Temp.ToLower;
    if Temp = 'center' then Style.TextAlign := TTextAlign.Center
    else if Temp = 'right' then Style.TextAlign := TTextAlign.Trailing
    else if Temp = 'justify' then Style.TextAlign := TTextAlign.Leading
    else Style.TextAlign := TTextAlign.Leading;
    Style.TextJustify := (Temp = 'justify');
  end;
  if Decls.TryGetValue('line-height', Temp) and not ShouldSkip(Temp) then
  begin
    // LineHeight is stored as a unitless multiple of the element's font-size.
    Temp := Temp.Trim.ToLower;
    if Temp.EndsWith('%') then
    begin
      // 150% -> 1.5x the font-size.
      LH := StrToFloatDef(Temp.Replace('%', ''), 0);
      if LH > 0 then Style.LineHeight := LH / 100;
    end
    else if Temp.EndsWith('rem') then
    begin
      // rem = root font-size (16px base, as ParseLength assumes).
      LH := StrToFloatDef(Temp.Replace('rem', ''), 0);
      if (LH > 0) and (Style.FontSize > 0) then
        Style.LineHeight := (LH * 16) / Style.FontSize;
    end
    else
    begin
      // px -> divide out font-size; unitless or em -> already the multiple.
      LH := StrToFloatDef(Temp.Replace('px', '').Replace('em', ''), 0);
      if LH > 0 then
      begin
        if Temp.Contains('px') then
          Style.LineHeight := LH / Style.FontSize
        else
          Style.LineHeight := LH;
      end;
    end;
  end;
  if Decls.TryGetValue('caption-side', Temp) and not ShouldSkip(Temp) then
    Style.CaptionSide := Temp.Trim.ToLower;
  if Decls.TryGetValue('margin', Temp) and not ShouldSkip(Temp) then
    ParseEdgeShorthand(Temp, Style.Margin, Style.FontSize);
  if Decls.TryGetValue('margin-top', Temp) and not ShouldSkip(Temp) then
    Style.Margin.Top := ParseLength(Temp, Style.FontSize);
  if Decls.TryGetValue('margin-right', Temp) and not ShouldSkip(Temp) then
    Style.Margin.Right := ParseLength(Temp, Style.FontSize);
  if Decls.TryGetValue('margin-bottom', Temp) and not ShouldSkip(Temp) then
    Style.Margin.Bottom := ParseLength(Temp, Style.FontSize);
  if Decls.TryGetValue('margin-left', Temp) and not ShouldSkip(Temp) then
    Style.Margin.Left := ParseLength(Temp, Style.FontSize);
  if Decls.TryGetValue('padding', Temp) and not ShouldSkip(Temp) then
    ParseEdgeShorthand(Temp, Style.Padding, Style.FontSize);
  if Decls.TryGetValue('padding-top', Temp) and not ShouldSkip(Temp) then
    Style.Padding.Top := ParseLength(Temp, Style.FontSize);
  if Decls.TryGetValue('padding-right', Temp) and not ShouldSkip(Temp) then
    Style.Padding.Right := ParseLength(Temp, Style.FontSize);
  if Decls.TryGetValue('padding-bottom', Temp) and not ShouldSkip(Temp) then
    Style.Padding.Bottom := ParseLength(Temp, Style.FontSize);
  if Decls.TryGetValue('padding-left', Temp) and not ShouldSkip(Temp) then
    Style.Padding.Left := ParseLength(Temp, Style.FontSize);
  if Decls.TryGetValue('border', Temp) and not ShouldSkip(Temp) then
  begin
    BParts := Temp.Split([' ']);
    for BP in BParts do
    begin
      BT := BP.Trim.ToLower;
      if BT = 'none' then
        Style.BorderWidths.Clear
      else if (BT.EndsWith('px')) or (StrToFloatDef(BT, -1) >= 0) then
        Style.SetBorderWidth(StrToFloatDef(BT.Replace('px', ''), 1))
      else if (BT = 'solid') or (BT = 'dashed') or (BT = 'dotted') or
              (BT = 'double') or (BT = 'groove') or (BT = 'ridge') or
              (BT = 'inset') or (BT = 'outset') then
        Style.BorderStyle := BT   // dashed/dotted/double rendered; others → solid
      else
        Style.SetBorderColor(ParseColor(BT));
    end;
  end;
  if Decls.TryGetValue('border-style', Temp) and not ShouldSkip(Temp) then
    Style.BorderStyle := Temp.Trim.ToLower;
  // Per-side border shorthands: border-top, border-right, border-bottom, border-left
  if Decls.TryGetValue('border-top', Temp) and not ShouldSkip(Temp) then
  begin
    BParts := Temp.Split([' ']);
    for BP in BParts do
    begin
      BT := BP.Trim.ToLower;
      if BT = 'none' then
        Style.BorderWidths.Top := 0
      else if (BT.EndsWith('px')) or (StrToFloatDef(BT, -1) >= 0) then
        Style.BorderWidths.Top := StrToFloatDef(BT.Replace('px', ''), 1)
      else if (BT = 'solid') or (BT = 'dashed') or (BT = 'dotted') or
              (BT = 'double') or (BT = 'groove') or (BT = 'ridge') or
              (BT = 'inset') or (BT = 'outset') then
        Style.BorderStyle := BT
      else
        Style.BorderColors[0] := ParseColor(BT);
    end;
  end;
  if Decls.TryGetValue('border-right', Temp) and not ShouldSkip(Temp) then
  begin
    BParts := Temp.Split([' ']);
    for BP in BParts do
    begin
      BT := BP.Trim.ToLower;
      if BT = 'none' then
        Style.BorderWidths.Right := 0
      else if (BT.EndsWith('px')) or (StrToFloatDef(BT, -1) >= 0) then
        Style.BorderWidths.Right := StrToFloatDef(BT.Replace('px', ''), 1)
      else if (BT = 'solid') or (BT = 'dashed') or (BT = 'dotted') or
              (BT = 'double') or (BT = 'groove') or (BT = 'ridge') or
              (BT = 'inset') or (BT = 'outset') then
        Style.BorderStyle := BT
      else
        Style.BorderColors[1] := ParseColor(BT);
    end;
  end;
  if Decls.TryGetValue('border-bottom', Temp) and not ShouldSkip(Temp) then
  begin
    BParts := Temp.Split([' ']);
    for BP in BParts do
    begin
      BT := BP.Trim.ToLower;
      if BT = 'none' then
        Style.BorderWidths.Bottom := 0
      else if (BT.EndsWith('px')) or (StrToFloatDef(BT, -1) >= 0) then
        Style.BorderWidths.Bottom := StrToFloatDef(BT.Replace('px', ''), 1)
      else if (BT = 'solid') or (BT = 'dashed') or (BT = 'dotted') or
              (BT = 'double') or (BT = 'groove') or (BT = 'ridge') or
              (BT = 'inset') or (BT = 'outset') then
        Style.BorderStyle := BT
      else
        Style.BorderColors[2] := ParseColor(BT);
    end;
  end;
  if Decls.TryGetValue('border-left', Temp) and not ShouldSkip(Temp) then
  begin
    BParts := Temp.Split([' ']);
    for BP in BParts do
    begin
      BT := BP.Trim.ToLower;
      if BT = 'none' then
        Style.BorderWidths.Left := 0
      else if (BT.EndsWith('px')) or (StrToFloatDef(BT, -1) >= 0) then
        Style.BorderWidths.Left := StrToFloatDef(BT.Replace('px', ''), 1)
      else if (BT = 'solid') or (BT = 'dashed') or (BT = 'dotted') or
              (BT = 'double') or (BT = 'groove') or (BT = 'ridge') or
              (BT = 'inset') or (BT = 'outset') then
        Style.BorderStyle := BT
      else
        Style.BorderColors[3] := ParseColor(BT);
    end;
  end;
  if Decls.TryGetValue('border-color', Temp) and not ShouldSkip(Temp) then
    Style.SetBorderColor(ParseColor(Temp));
  if Decls.TryGetValue('border-width', Temp) and not ShouldSkip(Temp) then
    Style.SetBorderWidth(ParseLength(Temp, Style.FontSize));
  if Decls.TryGetValue('border-radius', Temp) and not ShouldSkip(Temp) then
  begin
    RParts := Temp.Trim.Split([' '], TStringSplitOptions.ExcludeEmpty);
    case Length(RParts) of
      1: begin
           R0 := ParseLength(RParts[0], Style.FontSize);
           Style.BorderRadius := R0;
           Style.BorderRadii[0] := R0;
           Style.BorderRadii[1] := R0;
           Style.BorderRadii[2] := R0;
           Style.BorderRadii[3] := R0;
         end;
      2: begin
           // TL+BR | TR+BL
           Ra := ParseLength(RParts[0], Style.FontSize);
           Rb := ParseLength(RParts[1], Style.FontSize);
           Style.BorderRadii[0] := Ra;
           Style.BorderRadii[2] := Ra;
           Style.BorderRadii[1] := Rb;
           Style.BorderRadii[3] := Rb;
           Style.BorderRadius := Ra;
         end;
      3: begin
           // TL | TR+BL | BR
           Ra := ParseLength(RParts[0], Style.FontSize);
           Rb := ParseLength(RParts[1], Style.FontSize);
           Rc := ParseLength(RParts[2], Style.FontSize);
           Style.BorderRadii[0] := Ra;
           Style.BorderRadii[1] := Rb;
           Style.BorderRadii[3] := Rb;
           Style.BorderRadii[2] := Rc;
           Style.BorderRadius := Ra;
         end;
    else
      if Length(RParts) >= 4 then
      begin
        // TL | TR | BR | BL
        Style.BorderRadii[0] := ParseLength(RParts[0], Style.FontSize);
        Style.BorderRadii[1] := ParseLength(RParts[1], Style.FontSize);
        Style.BorderRadii[2] := ParseLength(RParts[2], Style.FontSize);
        Style.BorderRadii[3] := ParseLength(RParts[3], Style.FontSize);
        Style.BorderRadius := Style.BorderRadii[0];
      end;
    end;
  end;
  if Decls.TryGetValue('border-top-left-radius', Temp) and not ShouldSkip(Temp) then
    Style.BorderRadii[0] := ParseLength(Temp, Style.FontSize);
  if Decls.TryGetValue('border-top-right-radius', Temp) and not ShouldSkip(Temp) then
    Style.BorderRadii[1] := ParseLength(Temp, Style.FontSize);
  if Decls.TryGetValue('border-bottom-right-radius', Temp) and not ShouldSkip(Temp) then
    Style.BorderRadii[2] := ParseLength(Temp, Style.FontSize);
  if Decls.TryGetValue('border-bottom-left-radius', Temp) and not ShouldSkip(Temp) then
    Style.BorderRadii[3] := ParseLength(Temp, Style.FontSize);
  if Decls.TryGetValue('width', Temp) and not ShouldSkip(Temp) then
    Style.ExplicitWidth := ParseLength(Temp, Style.FontSize);
  if Decls.TryGetValue('height', Temp) and not ShouldSkip(Temp) then
    Style.ExplicitHeight := ParseLength(Temp, Style.FontSize);
  // aspect-ratio: <w> [/ <h>]  — a single number is w/1
  if Decls.TryGetValue('aspect-ratio', Temp) and not ShouldSkip(Temp) then
    Style.AspectRatio := ParseAspectRatio(Temp);
  if Decls.TryGetValue('display', Temp) and not ShouldSkip(Temp) then
    Style.Display := Temp.Trim.ToLower;  // Trim: 'display: inline-block' → no leading space
  if Decls.TryGetValue('vertical-align', Temp) and not ShouldSkip(Temp) then
    Style.VerticalAlign := Temp.ToLower;
  if Decls.TryGetValue('white-space', Temp) and not ShouldSkip(Temp) then
    Style.WhiteSpace := Temp.Trim.ToLower;
  if Decls.TryGetValue('box-sizing', Temp) and not ShouldSkip(Temp) then
    Style.BoxSizing := Temp.ToLower;
  if (Decls.TryGetValue('appearance', Temp) or Decls.TryGetValue('-webkit-appearance', Temp))
     and not ShouldSkip(Temp) then
    Style.AppearanceNone := SameText(Temp.Trim, 'none');
  if Decls.TryGetValue('cursor', Temp) and not ShouldSkip(Temp) then
    Style.CSSCursor := Temp.ToLower;
  if Decls.TryGetValue('accent-color', Temp) and not ShouldSkip(Temp) then
    Style.AccentColor := ParseColor(Temp);
  if Decls.TryGetValue('caret-color', Temp) and not ShouldSkip(Temp) then
    Style.CaretColor := ParseColor(Temp);
  if Decls.TryGetValue('pointer-events', Temp) and not ShouldSkip(Temp) then
    Style.PointerEventsNone := SameText(Trim(Temp), 'none');
  if Decls.TryGetValue('border-collapse', Temp) and not ShouldSkip(Temp) then
    Style.BorderCollapse := SameText(Trim(Temp), 'collapse');
  if Decls.TryGetValue('border-spacing', Temp) and not ShouldSkip(Temp) then
    Style.BorderSpacing := ParseLength(Trim(Temp).Split([' '])[0], Style.FontSize);

  if Decls.TryGetValue('object-fit', Temp) and not ShouldSkip(Temp) then
    Style.ObjectFit := Temp.Trim.ToLower;
  if Decls.TryGetValue('background-image', Temp) and not ShouldSkip(Temp) then
    ExtractBgImageUrl(Temp, Style.BackgroundImage);
  if Decls.TryGetValue('background-size', Temp) and not ShouldSkip(Temp) then
    Style.BackgroundSize := Temp.Trim.ToLower;

  if Decls.TryGetValue('position', Temp) and not ShouldSkip(Temp) then
    Style.CSSPosition := Temp.Trim.ToLower;
  if Decls.TryGetValue('z-index', Temp) and not ShouldSkip(Temp) then
    Style.ZIndex := StrToIntDef(Trim(Temp), 0);
  if Decls.TryGetValue('top', Temp) and not ShouldSkip(Temp) then
    Style.CSSTop := ParseLength(Temp, Style.FontSize);
  if Decls.TryGetValue('left', Temp) and not ShouldSkip(Temp) then
    Style.CSSLeft := ParseLength(Temp, Style.FontSize);
  if Decls.TryGetValue('right', Temp) and not ShouldSkip(Temp) then
    Style.CSSRight := ParseLength(Temp, Style.FontSize);
  if Decls.TryGetValue('bottom', Temp) and not ShouldSkip(Temp) then
    Style.CSSBottom := ParseLength(Temp, Style.FontSize);

  // CSS `inset` shorthand for top/right/bottom/left. Same 1-2-3-4 value
  // pattern as `margin` / `padding`. Only fills sides the longhand block
  // didn't already set, so an explicit `top: 10px` after `inset: 0`
  // keeps the 10px.
  if Decls.TryGetValue('inset', Temp) and not ShouldSkip(Temp) then
  begin
    InsetParts := Temp.Trim.Split([' '], TStringSplitOptions.ExcludeEmpty);
    case Length(InsetParts) of
      1: begin InsT := InsetParts[0]; InsR := InsetParts[0]; InsB := InsetParts[0]; InsL := InsetParts[0]; end;
      2: begin InsT := InsetParts[0]; InsB := InsetParts[0]; InsR := InsetParts[1]; InsL := InsetParts[1]; end;
      3: begin InsT := InsetParts[0]; InsR := InsetParts[1]; InsL := InsetParts[1]; InsB := InsetParts[2]; end;
    else
      InsT := InsetParts[0]; InsR := InsetParts[1]; InsB := InsetParts[2]; InsL := InsetParts[3];
    end;
    if Style.CSSTop    <= -9990 then Style.CSSTop    := ParseLength(InsT, Style.FontSize);
    if Style.CSSRight  <= -9990 then Style.CSSRight  := ParseLength(InsR, Style.FontSize);
    if Style.CSSBottom <= -9990 then Style.CSSBottom := ParseLength(InsB, Style.FontSize);
    if Style.CSSLeft   <= -9990 then Style.CSSLeft   := ParseLength(InsL, Style.FontSize);
  end;

  if Decls.TryGetValue('text-transform', Temp) and not ShouldSkip(Temp) then
    Style.TextTransform := Temp.ToLower;

  if Decls.TryGetValue('opacity', Temp) and not ShouldSkip(Temp) then
    Style.Opacity := Max(0, Min(1, StrToFloatDef(Temp, 1.0)));

  if Decls.TryGetValue('min-width', Temp) and not ShouldSkip(Temp) then
    Style.MinWidth := ParseLength(Temp, Style.FontSize);
  if Decls.TryGetValue('max-width', Temp) and not ShouldSkip(Temp) then
    Style.MaxWidth := ParseLength(Temp, Style.FontSize);
  if Decls.TryGetValue('min-height', Temp) and not ShouldSkip(Temp) then
    Style.MinHeight := ParseLength(Temp, Style.FontSize);
  if Decls.TryGetValue('max-height', Temp) and not ShouldSkip(Temp) then
    Style.MaxHeight := ParseLength(Temp, Style.FontSize);

  if Decls.TryGetValue('letter-spacing', Temp) and not ShouldSkip(Temp) then
    Style.LetterSpacing := ParseLength(Temp, Style.FontSize);

  if Decls.TryGetValue('word-spacing', Temp) and not ShouldSkip(Temp) then
    Style.WordSpacing := ParseLength(Temp, Style.FontSize);

  // font shorthand: [style] [variant] [weight] size[/line-height] family
  if Decls.TryGetValue('font', Temp) and not ShouldSkip(Temp) then
  begin
    FParts := Temp.Trim.Split([' '], TStringSplitOptions.ExcludeEmpty);
    fi := 0;
    while fi <= High(FParts) do   // leading style/variant/weight tokens
    begin
      fLp := LowerCase(FParts[fi]);
      if (fLp = 'italic') or (fLp = 'oblique') then Style.Italic := True
      else if fLp = 'bold' then begin Style.Bold := True; Style.FontWeight := 700; end
      else if (fLp = 'normal') or (fLp = 'small-caps') then  // ignored
      else if (Length(fLp) = 3) and (StrToIntDef(fLp, 0) >= 100) then
        Style.FontWeight := StrToIntDef(fLp, 400)
      else Break;   // first non-keyword token = the size
      Inc(fi);
    end;
    if fi <= High(FParts) then
    begin
      fSz := FParts[fi];
      slashp := Pos('/', fSz);
      if slashp > 0 then
      begin
        Style.FontSize := ParseLength(Copy(fSz, 1, slashp - 1), Style.FontSize);
        fLhs := Copy(fSz, slashp + 1, MaxInt);
        if (Pos('px', fLhs) > 0) or (Pos('em', fLhs) > 0) then
          Style.LineHeight := ParseLength(fLhs, Style.FontSize)
        else Style.LineHeight := StrToFloatDef(fLhs, 1.4);
      end
      else
        Style.FontSize := ParseLength(fSz, Style.FontSize);
      Inc(fi);
      if fi <= High(FParts) then
      begin
        fFam := '';
        for fj := fi to High(FParts) do fFam := fFam + FParts[fj] + ' ';
        Style.FontFamily := Trim(fFam);
      end;
    end;
  end;

  if Decls.TryGetValue('text-indent', Temp) and not ShouldSkip(Temp) then
    Style.TextIndent := ParseLength(Temp, Style.FontSize);

  if Decls.TryGetValue('visibility', Temp) and not ShouldSkip(Temp) then
    Style.Visibility := Temp.ToLower;

  if Decls.TryGetValue('list-style-type', Temp) and not ShouldSkip(Temp) then
    Style.ListStyleType := Temp.ToLower;
  if Decls.TryGetValue('list-style-position', Temp) and not ShouldSkip(Temp) then
    Style.ListStyleInside := SameText(Trim(Temp), 'inside');
  // list-style shorthand: <type> || <position> || <image>. A `position`
  // token (inside/outside) sets position; any other keyword sets the type.
  if Decls.TryGetValue('list-style', Temp) and not ShouldSkip(Temp) then
  begin
    for OvPart in Temp.Trim.ToLower.Split([' '], TStringSplitOptions.ExcludeEmpty) do
    begin
      if (OvPart = 'inside') or (OvPart = 'outside') then
        Style.ListStyleInside := (OvPart = 'inside')
      else if OvPart.StartsWith('url(') then
        // image marker not rendered
      else
        Style.ListStyleType := OvPart;
    end;
  end;

  if Decls.TryGetValue('overflow', Temp) and not ShouldSkip(Temp) then
  begin
    // overflow shorthand: `overflow: <x> <y>` or `overflow: <both>`
    OvParts := Temp.Trim.ToLower.Split([' '], TStringSplitOptions.ExcludeEmpty);
    if Length(OvParts) >= 2 then
    begin
      Style.OverflowX := OvParts[0];
      Style.OverflowY := OvParts[1];
      Style.Overflow := OvParts[0];
    end
    else if Length(OvParts) = 1 then
    begin
      Style.Overflow := OvParts[0];
      Style.OverflowX := OvParts[0];
      Style.OverflowY := OvParts[0];
    end;
  end;
  if Decls.TryGetValue('overflow-x', Temp) and not ShouldSkip(Temp) then
    Style.OverflowX := Temp.Trim.ToLower;
  if Decls.TryGetValue('overflow-y', Temp) and not ShouldSkip(Temp) then
    Style.OverflowY := Temp.Trim.ToLower;

  if Decls.TryGetValue('word-break', Temp) and not ShouldSkip(Temp) then
    Style.WordBreak := Temp.ToLower;
  if Decls.TryGetValue('overflow-wrap', Temp) and not ShouldSkip(Temp) then
    Style.OverflowWrap := Temp.ToLower;
  if Decls.TryGetValue('word-wrap', Temp) and not ShouldSkip(Temp) then
    Style.OverflowWrap := Temp.ToLower;  // word-wrap is legacy alias

  if Decls.TryGetValue('text-overflow', Temp) and not ShouldSkip(Temp) then
    Style.TextOverflow := Temp.ToLower;

  // box-shadow: offsetX offsetY [blur [spread]] color [inset]
  if Decls.TryGetValue('box-shadow', Temp) and not ShouldSkip(Temp) then
  begin
    ShadowStr := Temp.Trim.ToLower;
    if ShadowStr = 'none' then
      Style.BoxShadow.Active := False
    else
    begin
      Style.BoxShadow.Active := True;
      Style.BoxShadow.Inset := ShadowStr.Contains('inset');
      ShadowStr := ShadowStr.Replace('inset', '').Trim;
      // Parse: values are space-separated lengths then a color
      SParts := ShadowStr.Split([' ']);
      SetLength(Nums, 0);
      Style.BoxShadow.Color := $40000000;  // default: semi-transparent black
      for SP in SParts do
      begin
        ST := SP.Trim;
        if ST = '' then Continue;
        PL := ParseLength(ST, Style.FontSize);
        // ParseLength returns 0 for unknown strings, but also for "0px"
        // Check if it looks numeric
        if (ST.EndsWith('px')) or (ST.EndsWith('em')) or (ST.EndsWith('rem')) or
           (ST = '0') or (StrToFloatDef(ST, Single.MaxValue) <> Single.MaxValue) then
        begin
          SetLength(Nums, Length(Nums) + 1);
          Nums[High(Nums)] := PL;
        end
        else
          Style.BoxShadow.Color := ParseColor(ST);
      end;
      // Assign numeric values: offsetX, offsetY, [blur, [spread]]
      if Length(Nums) >= 1 then Style.BoxShadow.OffsetX := Nums[0];
      if Length(Nums) >= 2 then Style.BoxShadow.OffsetY := Nums[1];
      if Length(Nums) >= 3 then Style.BoxShadow.BlurRadius := Nums[2] else Style.BoxShadow.BlurRadius := 0;
      if Length(Nums) >= 4 then Style.BoxShadow.SpreadRadius := Nums[3] else Style.BoxShadow.SpreadRadius := 0;
    end;
  end;

  // outline: <width> [<style>] <color>   (any order, space-separated)
  if Decls.TryGetValue('outline', Temp) and not ShouldSkip(Temp) then
  begin
    OutlineStr := Temp.Trim.ToLower;
    if (OutlineStr = 'none') or (OutlineStr = '0') then
    begin
      Style.OutlineWidth := 0;
      Style.OutlineStyle := 'none';
    end
    else
    begin
      // Default: solid, current color
      Style.OutlineStyle := 'solid';
      Style.OutlineColor := Style.Color;
      Style.OutlineWidth := 0;
      OParts := OutlineStr.Split([' ']);
      for OP in OParts do
      begin
        OT := OP.Trim;
        if OT = '' then Continue;
        if (OT = 'solid') or (OT = 'dashed') or (OT = 'dotted') or
           (OT = 'double') or (OT = 'groove') or (OT = 'ridge') or
           (OT = 'inset') or (OT = 'outset') then
          Style.OutlineStyle := OT
        else if (OT.EndsWith('px')) or (OT.EndsWith('em')) or (OT.EndsWith('rem')) or
                (OT = '0') or (StrToFloatDef(OT, Single.MaxValue) <> Single.MaxValue) then
          Style.OutlineWidth := ParseLength(OT, Style.FontSize)
        else
          Style.OutlineColor := ParseColor(OT);
      end;
    end;
  end;
  if Decls.TryGetValue('outline-width', Temp) and not ShouldSkip(Temp) then
    Style.OutlineWidth := ParseLength(Temp, Style.FontSize);
  if Decls.TryGetValue('outline-color', Temp) and not ShouldSkip(Temp) then
    Style.OutlineColor := ParseColor(Temp);
  if Decls.TryGetValue('outline-style', Temp) and not ShouldSkip(Temp) then
    Style.OutlineStyle := Temp.Trim.ToLower;
  if Decls.TryGetValue('outline-offset', Temp) and not ShouldSkip(Temp) then
    Style.OutlineOffset := ParseLength(Temp, Style.FontSize);

  if Decls.TryGetValue('float', Temp) and not ShouldSkip(Temp) then
  begin
    FloatStr := Temp.Trim.ToLower;
    if (FloatStr = 'left') or (FloatStr = 'right') or (FloatStr = 'none') then
      Style.CSSFloat := FloatStr;
  end;
  if Decls.TryGetValue('clear', Temp) and not ShouldSkip(Temp) then
  begin
    ClrStr := Temp.Trim.ToLower;
    if (ClrStr = 'left') or (ClrStr = 'right') or (ClrStr = 'both') or
       (ClrStr = 'none') then
      Style.CSSClear := ClrStr;
  end;

  // Flexbox container properties
  if Decls.TryGetValue('flex-direction', Temp) and not ShouldSkip(Temp) then
    Style.FlexDirection := Temp.Trim.ToLower;
  if Decls.TryGetValue('flex-wrap', Temp) and not ShouldSkip(Temp) then
    Style.FlexWrap := Temp.Trim.ToLower;
  if Decls.TryGetValue('justify-content', Temp) and not ShouldSkip(Temp) then
    Style.JustifyContent := Temp.Trim.ToLower;
  if Decls.TryGetValue('align-items', Temp) and not ShouldSkip(Temp) then
    Style.AlignItems := Temp.Trim.ToLower;
  if Decls.TryGetValue('align-content', Temp) and not ShouldSkip(Temp) then
    Style.AlignContent := Temp.Trim.ToLower;
  if Decls.TryGetValue('align-self', Temp) and not ShouldSkip(Temp) then
    Style.AlignSelf := Temp.Trim.ToLower;
  if Decls.TryGetValue('order', Temp) and not ShouldSkip(Temp) then
    Style.CSSOrder := StrToIntDef(Trim(Temp), 0);
  if Decls.TryGetValue('gap', Temp) and not ShouldSkip(Temp) then
  begin
    // gap: <row> [<column>]  (one value = both axes)
    OvParts := Temp.Trim.Split([' '], TStringSplitOptions.ExcludeEmpty);
    Style.RowGap := ParseLength(OvParts[0], Style.FontSize);
    if Length(OvParts) >= 2 then Style.ColGap := ParseLength(OvParts[1], Style.FontSize)
    else Style.ColGap := Style.RowGap;
    Style.FlexGap := Style.RowGap;
  end;
  if Decls.TryGetValue('column-gap', Temp) and not ShouldSkip(Temp) then
  begin Style.FlexGap := ParseLength(Temp, Style.FontSize); Style.ColGap := Style.FlexGap; end;
  if Decls.TryGetValue('row-gap', Temp) and not ShouldSkip(Temp) then
  begin Style.FlexGap := ParseLength(Temp, Style.FontSize); Style.RowGap := Style.FlexGap; end;
  // CSS Grid templates + item placement
  if Decls.TryGetValue('grid-template-columns', Temp) and not ShouldSkip(Temp) then
    Style.GridTemplateColumns := Temp.Trim.ToLower;
  if Decls.TryGetValue('grid-template-rows', Temp) and not ShouldSkip(Temp) then
    Style.GridTemplateRows := Temp.Trim.ToLower;
  if Decls.TryGetValue('grid-column', Temp) and not ShouldSkip(Temp) then
    Style.GridColumn := Temp.Trim.ToLower;
  if Decls.TryGetValue('grid-row', Temp) and not ShouldSkip(Temp) then
    Style.GridRow := Temp.Trim.ToLower;

  // Flexbox item properties — `flex` is a shorthand for grow/shrink/basis.
  if Decls.TryGetValue('flex', Temp) and not ShouldSkip(Temp) then
  begin
    FlexStr := Temp.Trim.ToLower;
    if FlexStr = 'auto' then
    begin
      Style.FlexGrow := 1; Style.FlexShrink := 1; Style.FlexBasis := -1;
    end
    else if FlexStr = 'none' then
    begin
      Style.FlexGrow := 0; Style.FlexShrink := 0; Style.FlexBasis := -1;
    end
    else
    begin
      FlexParts := FlexStr.Split([' ']);
      if Length(FlexParts) >= 1 then Style.FlexGrow := StrToFloatDef(FlexParts[0], 0);
      if Length(FlexParts) >= 2 then Style.FlexShrink := StrToFloatDef(FlexParts[1], 1)
      else Style.FlexShrink := 1;
      if Length(FlexParts) >= 3 then Style.FlexBasis := ParseLength(FlexParts[2], Style.FontSize)
      else Style.FlexBasis := 0;  // single-number `flex: 1` -> basis 0
    end;
  end;
  if Decls.TryGetValue('flex-grow', Temp) and not ShouldSkip(Temp) then
    Style.FlexGrow := StrToFloatDef(Temp.Trim, 0);
  if Decls.TryGetValue('flex-shrink', Temp) and not ShouldSkip(Temp) then
    Style.FlexShrink := StrToFloatDef(Temp.Trim, 1);
  if Decls.TryGetValue('flex-basis', Temp) and not ShouldSkip(Temp) then
    Style.FlexBasis := ParseLength(Temp, Style.FontSize);

  // text-shadow: offsetX offsetY [blur] color  (similar form to box-shadow)
  if Decls.TryGetValue('text-shadow', Temp) and not ShouldSkip(Temp) then
  begin
    TsStr := Temp.Trim.ToLower;
    if (TsStr = 'none') or (TsStr = '') then
      Style.TextShadowActive := False
    else
    begin
      Style.TextShadowActive := True;
      Style.TextShadowColor := $80000000;  // default semi-transparent black
      TsParts := TsStr.Split([' ']);
      SetLength(Nums, 0);
      for TsP in TsParts do
      begin
        TsT := TsP.Trim;
        if TsT = '' then Continue;
        if TsT.EndsWith('px') or TsT.EndsWith('em') or TsT.EndsWith('rem') or
           (TsT = '0') or (StrToFloatDef(TsT, Single.MaxValue) <> Single.MaxValue) then
        begin
          SetLength(Nums, Length(Nums) + 1);
          Nums[High(Nums)] := ParseLength(TsT, Style.FontSize);
        end
        else
          Style.TextShadowColor := ParseColor(TsT);
      end;
      if Length(Nums) >= 1 then Style.TextShadowOffsetX := Nums[0];
      if Length(Nums) >= 2 then Style.TextShadowOffsetY := Nums[1];
      if Length(Nums) >= 3 then Style.TextShadowBlur    := Nums[2]
      else Style.TextShadowBlur := 0;
    end;
  end;

  // background-position: keywords (top/right/bottom/left/center) +
  // percentages + lengths. Two values: horizontal first, vertical second.
  if Decls.TryGetValue('background-position', Temp) and not ShouldSkip(Temp) then
  begin
    BgParts := Temp.Trim.ToLower.Split([' ']);
    if Length(BgParts) >= 1 then
    begin
      if BgParts[0] = 'left' then Style.BgPosX := 0
      else if BgParts[0] = 'center' then Style.BgPosX := -50  // 50% sentinel
      else if BgParts[0] = 'right' then Style.BgPosX := -100
      else Style.BgPosX := ParseLength(BgParts[0], Style.FontSize);
    end;
    if Length(BgParts) >= 2 then
    begin
      if BgParts[1] = 'top' then Style.BgPosY := 0
      else if BgParts[1] = 'center' then Style.BgPosY := -50
      else if BgParts[1] = 'bottom' then Style.BgPosY := -100
      else Style.BgPosY := ParseLength(BgParts[1], Style.FontSize);
    end
    else if (Length(BgParts) = 1) and (BgParts[0] = 'center') then
      Style.BgPosY := -50;  // single 'center' applies to both axes
  end;

  // background-repeat
  if Decls.TryGetValue('background-repeat', Temp) and not ShouldSkip(Temp) then
    Style.BgRepeat := Temp.Trim.ToLower;

  // linear-gradient / radial-gradient — from background-image OR the background
  // shorthand. All colour stops (up to 8) + positions are captured for a real
  // multi-stop gradient; Start/End/Angle are kept as a fallback.
  GradientSrc := '';
  if Decls.TryGetValue('background-image', Temp) and not ShouldSkip(Temp) then
    if Temp.ToLower.Contains('gradient(') then GradientSrc := Temp;
  if (GradientSrc = '') and Decls.TryGetValue('background', Temp) and not ShouldSkip(Temp) then
    if Temp.ToLower.Contains('gradient(') then GradientSrc := Temp;
  if GradientSrc <> '' then
  begin
    GSrc := GradientSrc;
    GLower := GSrc.ToLower;
    Style.BgGradientRadial := GLower.Contains('radial-gradient(');
    if Style.BgGradientRadial then GP1 := GLower.IndexOf('radial-gradient(') + 15
    else GP1 := GLower.IndexOf('linear-gradient(') + 15;
    GP2 := GLower.LastIndexOf(')');
    if (GP1 >= 15) and (GP2 > GP1) then
    begin
      GInner := GSrc.Substring(GP1 + 1, GP2 - GP1 - 1);
      GArgs := SplitTopLevelCommas(GInner);
      Style.BgGradientAngle := 180;  // default `to bottom` (top->bottom)
      SetLength(GColors, 0);
      Style.GradStopCount := 0;
      for GArg in GArgs do
      begin
        GAngleStr := GArg.Trim.ToLower;
        if GAngleStr.EndsWith('deg') then
          Style.BgGradientAngle := StrToFloatDef(GAngleStr.Substring(0, GAngleStr.Length - 3), 180)
        else if GAngleStr.StartsWith('to ') then
        begin
          if GAngleStr = 'to top' then Style.BgGradientAngle := 0
          else if GAngleStr = 'to right' then Style.BgGradientAngle := 90
          else if GAngleStr = 'to bottom' then Style.BgGradientAngle := 180
          else if GAngleStr = 'to left' then Style.BgGradientAngle := 270;
        end
        else if GAngleStr.StartsWith('circle') or GAngleStr.StartsWith('ellipse')
             or GAngleStr.StartsWith('at ') or GAngleStr.StartsWith('closest')
             or GAngleStr.StartsWith('farthest') then
          // radial shape/size/position keywords — accepted, not modelled yet
        else
          ParseGradientStop(GArg.Trim, Style);   // "colour [pos%]"
      end;
      if Style.GradStopCount >= 2 then
      begin
        Style.BgGradientStart := Style.GradStopColors[0];
        Style.BgGradientEnd := Style.GradStopColors[Style.GradStopCount - 1];
        Style.BgGradientActive := True;
      end;
    end;
  end;

  // CSS transform: parse a chain of translate/rotate/scale function
  // calls into the per-axis fields. Multiple transforms compose in
  // CSS order; we aggregate translate offsets, multiply scales,
  // and sum rotation. Functions we don't recognise are skipped.
  if Decls.TryGetValue('transform', Temp) and not ShouldSkip(Temp) then
  begin
    TfStr := Temp.Trim.ToLower;
    if (TfStr = 'none') or (TfStr = '') then
    begin
      Style.TransformActive := False;
      Style.TransformScaleX := 1;
      Style.TransformScaleY := 1;
    end
    else
    begin
      Style.TransformActive := True;
      TfPos := 0;
      while TfPos < TfStr.Length do
      begin
        // Skip whitespace / commas
        while (TfPos < TfStr.Length) and ((TfStr.Chars[TfPos] = ' ') or (TfStr.Chars[TfPos] = ',')) do
          Inc(TfPos);
        if TfPos >= TfStr.Length then Break;
        // Function name up to '('
        NameStart := TfPos;
        while (TfPos < TfStr.Length) and (TfStr.Chars[TfPos] <> '(') do Inc(TfPos);
        if TfPos >= TfStr.Length then Break;
        FnName := TfStr.Substring(NameStart, TfPos - NameStart).Trim;
        Inc(TfPos); // skip '('
        ArgStart := TfPos;
        while (TfPos < TfStr.Length) and (TfStr.Chars[TfPos] <> ')') do Inc(TfPos);
        ArgStr := TfStr.Substring(ArgStart, TfPos - ArgStart);
        if TfPos < TfStr.Length then Inc(TfPos);  // skip ')'
        TfArgs := ArgStr.Split([',']);

        if FnName = 'translate' then
        begin
          if Length(TfArgs) >= 1 then
            Style.TransformTranslateX := Style.TransformTranslateX + ParseLength(TfArgs[0].Trim, Style.FontSize);
          if Length(TfArgs) >= 2 then
            Style.TransformTranslateY := Style.TransformTranslateY + ParseLength(TfArgs[1].Trim, Style.FontSize);
        end
        else if FnName = 'translatex' then
        begin
          if Length(TfArgs) >= 1 then
            Style.TransformTranslateX := Style.TransformTranslateX + ParseLength(TfArgs[0].Trim, Style.FontSize);
        end
        else if FnName = 'translatey' then
        begin
          if Length(TfArgs) >= 1 then
            Style.TransformTranslateY := Style.TransformTranslateY + ParseLength(TfArgs[0].Trim, Style.FontSize);
        end
        else if FnName = 'rotate' then
        begin
          if Length(TfArgs) >= 1 then
          begin
            AStr := TfArgs[0].Trim;
            if AStr.EndsWith('deg') then AStr := AStr.Substring(0, AStr.Length - 3);
            Style.TransformRotate := Style.TransformRotate + StrToFloatDef(AStr, 0);
          end;
        end
        else if FnName = 'scale' then
        begin
          if Length(TfArgs) >= 1 then
            Style.TransformScaleX := Style.TransformScaleX * StrToFloatDef(TfArgs[0].Trim, 1);
          if Length(TfArgs) >= 2 then
            Style.TransformScaleY := Style.TransformScaleY * StrToFloatDef(TfArgs[1].Trim, 1)
          else if Length(TfArgs) >= 1 then
            Style.TransformScaleY := Style.TransformScaleY * StrToFloatDef(TfArgs[0].Trim, 1);
        end
        else if FnName = 'scalex' then
        begin
          if Length(TfArgs) >= 1 then
            Style.TransformScaleX := Style.TransformScaleX * StrToFloatDef(TfArgs[0].Trim, 1);
        end
        else if FnName = 'scaley' then
        begin
          if Length(TfArgs) >= 1 then
            Style.TransformScaleY := Style.TransformScaleY * StrToFloatDef(TfArgs[0].Trim, 1);
        end;
      end;
    end;
  end;
end;

end.
