program test_dom;

{
  Real (no-mock) console test for the FPC port of the Tina4Delphi HTML
  DOM / CSS core (fpc/Tina4HTMLDom.pas).

  Parses a nontrivial HTML sample, dumps the DOM tree, applies the parsed
  stylesheet, and asserts on the actual parsed structure and computed
  declarations. Exits 0 with 'ALL TESTS PASS' on success; halts 1 with a
  message on the first failing assertion.
}

{$mode delphi}{$H+}

uses
  SysUtils, Classes, Generics.Collections, Tina4HTMLDom;

const
  // ™ in UTF-8
  UTF8Trade = #$E2#$84#$A2;

type
  TErrCounter = class
  public
    Count: Integer;
    LastSelector: string;
    procedure OnErr(Sender: TObject; const Selector, Reason: string);
  end;

procedure TErrCounter.OnErr(Sender: TObject; const Selector, Reason: string);
begin
  Inc(Count);
  LastSelector := Selector;
  Writeln('  (parse notice) selector "', Selector, '": ', Reason);
end;

var
  PassCount: Integer = 0;

procedure Check(Cond: Boolean; const Msg: string);
begin
  if not Cond then
  begin
    Writeln('FAIL: ', Msg);
    Halt(1);
  end;
  Inc(PassCount);
end;

procedure CheckEqualsStr(const Expected, Actual, Msg: string);
begin
  if Expected <> Actual then
  begin
    Writeln('FAIL: ', Msg);
    Writeln('  expected: "', Expected, '"');
    Writeln('  actual:   "', Actual, '"');
    Halt(1);
  end;
  Inc(PassCount);
end;

procedure CheckEqualsF(Expected, Actual: Single; const Msg: string);
begin
  if Abs(Expected - Actual) > 0.001 then
  begin
    Writeln('FAIL: ', Msg);
    Writeln('  expected: ', Expected: 0: 3);
    Writeln('  actual:   ', Actual: 0: 3);
    Halt(1);
  end;
  Inc(PassCount);
end;

procedure CheckEqualsHex(Expected, Actual: TAlphaColor; const Msg: string);
begin
  if Expected <> Actual then
  begin
    Writeln('FAIL: ', Msg);
    Writeln('  expected: $', IntToHex(Expected, 8));
    Writeln('  actual:   $', IntToHex(Actual, 8));
    Halt(1);
  end;
  Inc(PassCount);
end;

function FindById(Tag: THTMLTag; const Id: string): THTMLTag;
var
  I: Integer;
begin
  if Tag.GetAttribute('id') = Id then
    Exit(Tag);
  for I := 0 to Tag.Children.Count - 1 do
  begin
    Result := FindById(Tag.Children[I], Id);
    if Assigned(Result) then Exit;
  end;
  Result := nil;
end;

function FindByClass(Tag: THTMLTag; const ClassName: string): THTMLTag;
var
  I: Integer;
begin
  if Tag.GetAttribute('class') = ClassName then
    Exit(Tag);
  for I := 0 to Tag.Children.Count - 1 do
  begin
    Result := FindByClass(Tag.Children[I], ClassName);
    if Assigned(Result) then Exit;
  end;
  Result := nil;
end;

function FindFirstTag(Tag: THTMLTag; const Name: string): THTMLTag;
var
  I: Integer;
begin
  if SameText(Tag.TagName, Name) then
    Exit(Tag);
  for I := 0 to Tag.Children.Count - 1 do
  begin
    Result := FindFirstTag(Tag.Children[I], Name);
    if Assigned(Result) then Exit;
  end;
  Result := nil;
end;

function CountTag(Tag: THTMLTag; const Name: string): Integer;
var
  I: Integer;
begin
  Result := 0;
  if SameText(Tag.TagName, Name) then
    Inc(Result);
  for I := 0 to Tag.Children.Count - 1 do
    Inc(Result, CountTag(Tag.Children[I], Name));
end;

function CountElementChildren(Tag: THTMLTag): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to Tag.Children.Count - 1 do
    if Tag.Children[I].TagName <> '#text' then
      Inc(Result);
end;

function FirstTextChild(Tag: THTMLTag): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to Tag.Children.Count - 1 do
    if Tag.Children[I].TagName = '#text' then
      Exit(Tag.Children[I].Text);
end;

function AllText(Tag: THTMLTag): string;
var
  I: Integer;
begin
  Result := Tag.Text;
  for I := 0 to Tag.Children.Count - 1 do
    Result := Result + AllText(Tag.Children[I]);
end;

procedure DumpTree(Tag: THTMLTag; Indent: Integer);
var
  I: Integer;
  Line: string;
  P: TPair<string, string>;
begin
  Line := StringOfChar(' ', Indent * 2);
  if Tag.TagName = '#text' then
    Line := Line + '#text "' +
      StringReplace(Tag.Text, #10, '\n', [rfReplaceAll]) + '"'
  else
  begin
    Line := Line + '<' + Tag.TagName;
    for P in Tag.Attributes do
      Line := Line + ' ' + P.Key + '="' + P.Value + '"';
    for P in Tag.Style do
      Line := Line + ' {' + P.Key + ': ' + P.Value + '}';
    Line := Line + '>';
  end;
  Writeln(Line);
  for I := 0 to Tag.Children.Count - 1 do
    DumpTree(Tag.Children[I], Indent + 1);
end;

const
  SampleHTML =
    '<!DOCTYPE html>' + #10 +
    '<html>' + #10 +
    '<head>' + #10 +
    '  <meta charset="utf-8">' + #10 +
    '  <link rel="stylesheet" href="theme.css">' + #10 +
    '  <style>' + #10 +
    '    /* comment inside CSS */' + #10 +
    '    :root { --main-color: #ff0000; --pad: 4px; }' + #10 +
    '    p { color: navy; margin-top: 10px; }' + #10 +
    '    .note { color: green; }' + #10 +
    '    div p.note { font-style: italic; }' + #10 +
    '    #headline { color: #00ff00; font-size: 24px; }' + #10 +
    '    .title { color: yellow; }' + #10 +
    '    .card { background-color: var(--main-color); padding: var(--pad, 8px); }' + #10 +
    '    .btn:hover { background-color: lime; }' + #10 +
    '    input[type="email"] { border-color: purple; }' + #10 +
    '    h1, h2 { letter-spacing: 2px; }' + #10 +
    '    @media (max-width: 600px) { .card { display: none; } }' + #10 +
    '  </style>' + #10 +
    '</head>' + #10 +
    '<body>' + #10 +
    '  <!-- a comment that must vanish -->' + #10 +
    '  <div id="container" class="wrapper main" data-role="app">' + #10 +
    '    <h1 id="headline" class="title">Hello &amp; welcome</h1>' + #10 +
    '    <p class="note">Nested   note with' + #10 +
    '    collapsed    whitespace</p>' + #10 +
    '    <div class="card" style="color: white; background-image: url(http://x/y.png)">' + #10 +
    '      Card text &lt;tag&gt; &#65;&#x42; &trade; &bogus;' + #10 +
    '      <br/>' + #10 +
    '      <img src=pic.png width=100>' + #10 +
    '      <input type="email" value="a@b.c" required>' + #10 +
    '      <input type="text" id="plain">' + #10 +
    '      <a class="btn" href="https://tina4.com">Click</a>' + #10 +
    '    </div>' + #10 +
    '    <pre>  line one' + #10 +
    '  line two   spaced</pre>' + #10 +
    '    <script>var x = "<p>not parsed</p>";</script>' + #10 +
    '  </div>' + #10 +
    '  <p class="note" id="outside">outside note</p>' + #10 +
    '</body>' + #10 +
    '</html>';

var
  Parser: THTMLParser;
  Sheet: TCSSStyleSheet;
  Err: TErrCounter;
  Container, Headline, NoteP, OutsideP, CardDiv, BtnA, EmailInput,
    PlainInput, PreTag, ImgTag, BrTag: THTMLTag;
  Decls: TCSSDeclarations;
  Val, CardText, PreText: string;
  ParentStyle, CardStyle, H1Style, BtnStyle: TComputedStyle;
  Edges: TEdgeValues;
  DeclPair: TPair<string, string>;
begin
  Parser := THTMLParser.Create;
  Sheet := TCSSStyleSheet.Create;
  Err := TErrCounter.Create;
  Err.Count := 0;
  Sheet.OnParseError := Err.OnErr;
  try
    // ── Parse ────────────────────────────────────────────────────────────
    Parser.Parse(SampleHTML);

    Writeln('=== DOM tree =========================================================');
    DumpTree(Parser.Root, 0);
    Writeln;

    // ── Parser structure assertions ──────────────────────────────────────
    Check(Parser.StyleBlocks.Count = 1, 'exactly one <style> block collected');
    Check(Pos(':root', Parser.StyleBlocks[0]) > 0, 'style block contains the raw CSS');
    Check(Parser.LinkHrefs.Count = 1, 'one stylesheet <link> href collected');
    CheckEqualsStr('theme.css', Parser.LinkHrefs[0], 'link href value');

    Container := FindById(Parser.Root, 'container');
    Check(Assigned(Container), '#container found');
    CheckEqualsStr('div', Container.TagName, '#container is a div');
    CheckEqualsStr('wrapper main', Container.GetAttribute('class'), 'class attribute preserved');
    CheckEqualsStr('app', Container.GetAttribute('data-role'), 'data-role attribute');
    Check(Container.HasAttribute('id'), 'HasAttribute(id) positive');
    Check(not Container.HasAttribute('missing'), 'HasAttribute negative');
    CheckEqualsStr('fallback', Container.GetAttribute('missing', 'fallback'), 'GetAttribute default value');
    Check(CountElementChildren(Container) = 4,
      '#container has 4 element children (h1, p, div.card, pre; script skipped)');

    Headline := FindById(Parser.Root, 'headline');
    Check(Assigned(Headline), '#headline found');
    CheckEqualsStr('h1', Headline.TagName, '#headline is an h1');
    Check(Headline.Parent = Container, 'parent pointer wired');
    CheckEqualsStr('Hello & welcome', FirstTextChild(Headline), '&amp; decoded in h1 text');

    NoteP := FindFirstTag(Container, 'p');
    Check(Assigned(NoteP) and (NoteP.GetAttribute('class') = 'note'), 'p.note found inside container');
    CheckEqualsStr('Nested note with collapsed whitespace',
      FirstTextChild(NoteP), 'whitespace collapsed outside <pre>');

    CardDiv := FindByClass(Parser.Root, 'card');
    Check(Assigned(CardDiv), 'div.card found');
    CheckEqualsStr('div', CardDiv.TagName, 'card is a div');

    // Inline style attribute parsed into the Style dictionary
    Check(CardDiv.Style.TryGetValue('color', Val) and (Val = 'white'),
      'inline style color:white parsed');
    Check(CardDiv.Style.TryGetValue('background-image', Val) and
      (Val = 'url(http://x/y.png)'),
      'inline background-image url(...) survives the colon in http://');

    // Entities in the card text
    CardText := FirstTextChild(CardDiv);
    Check(Pos('Card text <tag> AB', CardText) > 0,
      '&lt; &gt; &#65; &#x42; decoded in card text');
    Check(Pos(UTF8Trade, CardText) > 0, '&trade; decoded to UTF-8 TM sign');
    Check(Pos('&bogus;', CardText) > 0, 'unknown entity &bogus; left untouched');

    // Void / self-closing tags
    BrTag := FindFirstTag(CardDiv, 'br');
    Check(Assigned(BrTag) and (BrTag.Children.Count = 0), 'self-closing <br/> parsed, no children');
    ImgTag := FindFirstTag(CardDiv, 'img');
    Check(Assigned(ImgTag) and (ImgTag.Children.Count = 0), 'void <img> parsed, no children');
    CheckEqualsStr('pic.png', ImgTag.GetAttribute('src'), 'unquoted attribute value src=pic.png');
    CheckEqualsStr('100', ImgTag.GetAttribute('width'), 'unquoted attribute value width=100');

    // Boolean attribute
    EmailInput := nil;
    PlainInput := FindById(Parser.Root, 'plain');
    Check(Assigned(PlainInput), 'input#plain found');
    // the email input is the first input inside the card
    EmailInput := FindFirstTag(CardDiv, 'input');
    Check(Assigned(EmailInput) and (EmailInput.GetAttribute('type') = 'email'),
      'input[type=email] found');
    Check(EmailInput.HasAttribute('required'), 'boolean attribute present');
    CheckEqualsStr('required', EmailInput.GetAttribute('required'),
      'boolean attribute value = its own name');

    BtnA := FindByClass(Parser.Root, 'btn');
    Check(Assigned(BtnA) and (BtnA.TagName = 'a'), 'a.btn found');
    CheckEqualsStr('https://tina4.com', BtnA.GetAttribute('href'), 'href attribute');

    // <pre> keeps whitespace verbatim
    PreTag := FindFirstTag(Container, 'pre');
    Check(Assigned(PreTag), '<pre> found');
    PreText := FirstTextChild(PreTag);
    CheckEqualsStr('  line one' + #10 + '  line two   spaced', PreText,
      '<pre> whitespace and newline preserved verbatim');

    // Comment and script content must not appear anywhere in the tree
    Check(Pos('a comment that must vanish', AllText(Parser.Root)) = 0, 'HTML comment skipped');
    Check(Pos('not parsed', AllText(Parser.Root)) = 0, '<script> content skipped');
    Check(CountTag(Parser.Root, 'p') = 2, 'exactly 2 <p> elements (script''s "<p>" not parsed)');
    Check(CountTag(Parser.Root, 'script') = 0, 'no script node in the DOM');
    Check(CountTag(Parser.Root, 'head') = 0, '<head> ignored');
    Check(CountTag(Parser.Root, 'link') = 0, '<link> consumed, not a DOM node');

    OutsideP := FindById(Parser.Root, 'outside');
    Check(Assigned(OutsideP), 'p#outside found');

    // ── DecodeEntities direct (positive + negative) ──────────────────────
    CheckEqualsStr('a & b Hi', THTMLParser.DecodeEntities('a &amp; b &#72;&#x69;'),
      'DecodeEntities named + decimal + hex');
    CheckEqualsStr('&nope; &', THTMLParser.DecodeEntities('&nope; &'),
      'DecodeEntities leaves unknown entity and bare ampersand');
    CheckEqualsStr('"q" ''a''', THTMLParser.DecodeEntities('&quot;q&quot; &apos;a&apos;'),
      'DecodeEntities quot/apos');

    // ── Stylesheet ───────────────────────────────────────────────────────
    Sheet.AddCSS(Parser.StyleBlocks[0]);

    Check(Sheet.Rules.Count = 11,
      '11 rules parsed (10 top-level + the .card rule inside @media, now parsed with its condition)');
    Check(Sheet.CustomProps.Count = 2, ':root custom properties collected as globals');
    Check(Sheet.CustomProps.TryGetValue('--main-color', Val) and (Val = '#ff0000'),
      '--main-color captured');
    Check(Sheet.HasInteractiveSelectors, ':hover rule sets HasInteractiveSelectors');
    Check(Err.Count = 1, 'OnParseError fired exactly once (:root rule has only custom props)');
    CheckEqualsStr(':root', Err.LastSelector, 'OnParseError reported the :root selector');

    // var() resolution helpers
    CheckEqualsStr('#ff0000', Sheet.ResolveVar('var(--main-color)'), 'ResolveVar hit');
    CheckEqualsStr('9px', Sheet.ResolveVar('var(--nope, 9px)'), 'ResolveVar fallback');
    CheckEqualsStr('var(--nope)', Sheet.ResolveVar('var(--nope)'), 'ResolveVar unresolvable left as-is');

    // ApplyTo: h1#headline — id beats class beats tag
    Decls := TCSSDeclarations.Create;
    try
      Sheet.ApplyTo(Headline, Decls);
      Writeln('=== matched declarations for h1#headline.title =======================');
      for DeclPair in Decls do
        Writeln('  ', DeclPair.Key, ': ', DeclPair.Value);
      Writeln;
      Check(Decls.TryGetValue('color', Val) and (Val = '#00ff00'),
        '#headline (specificity 100) beats .title (10) even though .title is later in source');
      Check(Decls.TryGetValue('font-size', Val) and (Val = '24px'), 'font-size from #headline');
      Check(Decls.TryGetValue('letter-spacing', Val) and (Val = '2px'), 'letter-spacing from comma-split h1 rule');
    finally
      Decls.Free;
    end;

    // ApplyTo: p.note inside div — descendant selector matches
    Decls := TCSSDeclarations.Create;
    try
      Sheet.ApplyTo(NoteP, Decls);
      Check(Decls.TryGetValue('color', Val) and (Val = 'green'),
        '.note (10) beats p (1) for inner note');
      Check(Decls.TryGetValue('margin-top', Val) and (Val = '10px'),
        'p rule margin-top still applies to inner note');
      Check(Decls.TryGetValue('font-style', Val) and (Val = 'italic'),
        'descendant selector "div p.note" matches note inside div');
    finally
      Decls.Free;
    end;

    // ApplyTo: p#outside — NOT inside a div, descendant selector must not match
    Decls := TCSSDeclarations.Create;
    try
      Sheet.ApplyTo(OutsideP, Decls);
      Check(Decls.TryGetValue('color', Val) and (Val = 'green'),
        '.note applies to outside note');
      Check(not Decls.ContainsKey('font-style'),
        'NEGATIVE: "div p.note" does not match p.note outside a div');
    finally
      Decls.Free;
    end;

    // ApplyTo: .card — var() resolution from :root scope
    Decls := TCSSDeclarations.Create;
    try
      Sheet.SetMediaContext(1024, False);   // wide → the max-width:600 rule must NOT match
      Sheet.ApplyTo(CardDiv, Decls);
      Writeln('=== matched declarations for div.card ================================');
      for DeclPair in Decls do
        Writeln('  ', DeclPair.Key, ': ', DeclPair.Value);
      Writeln;
      Check(Decls.TryGetValue('background-color', Val) and (Val = '#ff0000'),
        'background-color: var(--main-color) resolved to #ff0000');
      Check(Decls.TryGetValue('padding', Val) and (Val = '4px'),
        'padding: var(--pad, 8px) resolved to 4px (definition wins over fallback)');
      Check(not Decls.ContainsKey('display'),
        'NEGATIVE: @media(max-width:600) rule not applied at 1024px width');
    finally
      Decls.Free;
    end;

    // ApplyTo: :hover pseudo-class gated on the tag state flag
    Decls := TCSSDeclarations.Create;
    try
      Sheet.ApplyTo(BtnA, Decls);
      Check(not Decls.ContainsKey('background-color'),
        'NEGATIVE: .btn:hover does not match while IsHovered=False');
    finally
      Decls.Free;
    end;
    BtnA.IsHovered := True;
    Decls := TCSSDeclarations.Create;
    try
      Sheet.ApplyTo(BtnA, Decls);
      Check(Decls.TryGetValue('background-color', Val) and (Val = 'lime'),
        '.btn:hover matches once IsHovered=True');
    finally
      Decls.Free;
    end;
    BtnA.IsHovered := False;

    // ApplyTo: attribute selector positive + negative
    Decls := TCSSDeclarations.Create;
    try
      Sheet.ApplyTo(EmailInput, Decls);
      Check(Decls.TryGetValue('border-color', Val) and (Val = 'purple'),
        'input[type="email"] matches the email input');
    finally
      Decls.Free;
    end;
    Decls := TCSSDeclarations.Create;
    try
      Sheet.ApplyTo(PlainInput, Decls);
      Check(not Decls.ContainsKey('border-color'),
        'NEGATIVE: input[type="email"] does not match input[type=text]');
    finally
      Decls.Free;
    end;

    // ── Computed style ───────────────────────────────────────────────────
    ParentStyle := TComputedStyle.Default;
    CheckEqualsHex(TAlphaColors.Black, ParentStyle.Color, 'Default color is black');
    CheckEqualsF(14, ParentStyle.FontSize, 'Default font size 14');
    CheckEqualsStr('block', ParentStyle.Display, 'Default display block');

    CardStyle := TComputedStyle.ForTag(CardDiv, ParentStyle, Sheet);
    CheckEqualsHex(TAlphaColors.White, CardStyle.Color,
      'inline color:white overrides everything');
    CheckEqualsHex($FFFF0000, CardStyle.BackgroundColor,
      'stylesheet var-resolved background-color applied');
    CheckEqualsF(4, CardStyle.Padding.Top, 'padding var resolved to 4px (top)');
    CheckEqualsF(4, CardStyle.Padding.Left, 'padding var resolved to 4px (left)');
    CheckEqualsStr('http://x/y.png', CardStyle.BackgroundImage,
      'inline background-image URL extracted');
    CheckEqualsStr('block', CardStyle.Display, 'div UA default display block');

    H1Style := TComputedStyle.ForTag(Headline, ParentStyle, Sheet);
    CheckEqualsF(24, H1Style.FontSize, 'CSS font-size 24px overrides h1 UA default 32');
    Check(H1Style.Bold, 'h1 UA default bold');
    CheckEqualsF(2, H1Style.LetterSpacing, 'letter-spacing 2px applied');
    CheckEqualsHex($FF00FF00, H1Style.Color, '#headline color computed');

    BtnStyle := TComputedStyle.ForTag(BtnA, ParentStyle, Sheet);
    CheckEqualsHex($FF0066CC, BtnStyle.Color, 'anchor UA colour');
    CheckEqualsStr('underline', BtnStyle.TextDecoration, 'anchor UA underline');
    CheckEqualsHex(TAlphaColors.Null, BtnStyle.BackgroundColor,
      'NEGATIVE: no hover background while IsHovered=False');
    BtnA.IsHovered := True;
    BtnStyle := TComputedStyle.ForTag(BtnA, ParentStyle, Sheet);
    CheckEqualsHex(TAlphaColors.Lime, BtnStyle.BackgroundColor,
      ':hover background lime once IsHovered=True');
    BtnA.IsHovered := False;

    // ── Parsing helpers (positive + negative) ────────────────────────────
    CheckEqualsHex($FFFF0000, TComputedStyle.ParseColor('#f00'), 'ParseColor #f00 short hex');
    CheckEqualsHex($FF00FF00, TComputedStyle.ParseColor('#00ff00'), 'ParseColor #00ff00');
    CheckEqualsHex($FF010203, TComputedStyle.ParseColor('rgb(1, 2, 3)'), 'ParseColor rgb()');
    CheckEqualsHex($80000000, TComputedStyle.ParseColor('rgba(0,0,0,0.5)'), 'ParseColor rgba() alpha');
    CheckEqualsHex(TAlphaColors.Null, TComputedStyle.ParseColor('transparent'), 'ParseColor transparent');
    CheckEqualsHex(TAlphaColors.Black, TComputedStyle.ParseColor('no-such-colour'),
      'NEGATIVE: unknown colour falls back to black');

    CheckEqualsF(10, TComputedStyle.ParseLength('10px'), 'ParseLength px');
    CheckEqualsF(28, TComputedStyle.ParseLength('2em', 14), 'ParseLength em uses EmSize');
    CheckEqualsF(24, TComputedStyle.ParseLength('1.5rem'), 'ParseLength rem = 16px base');
    CheckEqualsF(-50, TComputedStyle.ParseLength('50%'), 'ParseLength % negative sentinel');
    CheckEqualsF(-1, TComputedStyle.ParseLength('auto'), 'ParseLength auto sentinel');
    CheckEqualsF(-3, TComputedStyle.ParseLength('fit-content'), 'ParseLength fit-content sentinel');
    CheckEqualsF(38, TComputedStyle.ParseLength('calc(10px + 2em)', 14), 'ParseLength calc addition');
    CheckEqualsF(6, TComputedStyle.ParseLength('calc(10px - 4px)', 14), 'ParseLength calc subtraction');
    CheckEqualsF(0, TComputedStyle.ParseLength('gibberish'), 'NEGATIVE: unknown length is 0');

    Edges.Clear;
    TComputedStyle.ParseEdgeShorthand('1px 2px 3px 4px', Edges, 14);
    CheckEqualsF(1, Edges.Top, 'edge shorthand 4-value top');
    CheckEqualsF(2, Edges.Right, 'edge shorthand 4-value right');
    CheckEqualsF(3, Edges.Bottom, 'edge shorthand 4-value bottom');
    CheckEqualsF(4, Edges.Left, 'edge shorthand 4-value left');
    TComputedStyle.ParseEdgeShorthand('5px 10px', Edges, 14);
    CheckEqualsF(5, Edges.Top, 'edge shorthand 2-value top');
    CheckEqualsF(10, Edges.Left, 'edge shorthand 2-value left');
    CheckEqualsF(10, Edges.Vert, 'TEdgeValues.Vert (5 top + 5 bottom)');
    CheckEqualsF(20, Edges.Horz, 'TEdgeValues.Horz');
    Check(Edges.Any, 'TEdgeValues.Any positive');
    Edges.Clear;
    Check(not Edges.Any, 'TEdgeValues.Any negative after Clear');

    Writeln;
    Writeln(PassCount, ' assertions passed.');
    Writeln('ALL TESTS PASS');
  finally
    Err.Free;
    Sheet.Free;
    Parser.Free;
  end;
end.
