unit Tina4Elements;

(* Custom-element registry — the "drop-in tag" mechanism.

   A designer invents a tag (<nicebutton>, <ratingstars>, ...) and registers it
   ONCE; the engine then handles it everywhere without any core SameText edits.
   Two tiers. Note: this header uses star-paren delimiters, and the placeholders
   below are shown with SQUARE brackets, because a real right-brace would close a
   brace-style Pascal comment early — the actual template syntax uses braces.

   TIER 1 — template expansion (composition over existing HTML/CSS).
     RegisterElement('nicebutton', '<button class="nb nb-[variant]">[children]</button>', CSS)
     At Build time ExpandCustomElements
     replaces each <nicebutton ...>kids</nicebutton> with the template: the
     bracketed attr placeholders are filled from the element's attributes and the
     children placeholder is the element's original inner HTML. Everything
     downstream (layout, paint, events, every shell, snapshots) sees a plain
     <button> — zero new core paths. The pass is idempotent and runs every Build
     (like InjectPseudo): the authored inner HTML is stashed once in a
     'data-tina4-src' attribute and the children are re-derived from it each time,
     so a later attribute change re-expands correctly.

   TIER 2 — native element (paint + tap the primitives can't express).
     RegisterNativeElement('sparkline', @PaintSpark, @TapSpark, CSS)
     The element sizes via its registered CSS (normal cascade), the core calls the
     Paint hook inside PaintBox (clipped to the box, same path as <canvas>), and a
     tap on it calls the OnTap hook in Tina4Interact. No template — the element
     keeps its own tag and draws itself.

   This unit depends ONLY on Tina4HTMLDom + Tina4RenderBackend (never the layout
   box tree), so it sits cleanly below Tina4HTMLLayout/Tina4Interact with no
   circular dependency. The hooks are typed against the abstract engine types
   (THTMLTag, TComputedStyle, TTina4Canvas) and receive plain box geometry. *)

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, Tina4HTMLDom, Tina4RenderBackend;

type
  { Tier-2 paint hook: draw the element's content into its box. X/Y/W/H is the
    content box in CSS px (origin already includes scroll); the canvas is clipped
    to it before the call. St is the element's resolved style. }
  TElemPaintProc = procedure(const Tag: THTMLTag; X, Y, W, H: Single;
    Canvas: TTina4Canvas; const St: TComputedStyle);
  { Tier-2 tap hook: the element was tapped. Return True if handled (the engine
    then relays out). The hook may mutate the tag and/or fire an action itself. }
  TElemTapProc = function(const Tag: THTMLTag): Boolean;

  TTina4ElementDef = record
    Name: string;         // tag name, lower-case
    Template: string;     // Tier-1 template ('' for a Tier-2 native element)
    DefaultCSS: string;   // registered into every document's sheet (both tiers)
    Paint: TElemPaintProc;// Tier-2 only
    OnTap: TElemTapProc;  // Tier-2 only
  end;

{ ---- registration ------------------------------------------------------ }

{ Tier 1: a template element. Name is case-insensitive. DefaultCSS (optional) is
  folded into every document's stylesheet — style the expanded markup there. }
procedure RegisterElement(const Name, Template: string; const DefaultCSS: string = '');
{ Tier 2: a native element with paint and/or tap hooks (either may be nil). }
procedure RegisterNativeElement(const Name: string; Paint: TElemPaintProc;
  OnTap: TElemTapProc; const DefaultCSS: string = '');
{ Drop every registration (used by tests for isolation). }
procedure ClearElements;

{ ---- lookup (the seams consult these) ---------------------------------- }

function IsRegisteredElement(const Name: string): Boolean;
function IsTemplateElement(const Name: string): Boolean;   // Tier 1
function ElementPaintProc(const Name: string): TElemPaintProc;   // nil if none
function ElementTapProc(const Name: string): TElemTapProc;       // nil if none
{ Every registered element's DefaultCSS, concatenated — the engine adds this to
  the sheet so registered tags get their default sizing/appearance. }
function ElementsDefaultCSS: string;

{ ---- Tier-1 build-time expansion --------------------------------------- }

{ True if the tree contains at least one registered TEMPLATE element (gate the
  pass, like HasPseudo). }
function HasCustomElements(Root: THTMLTag): Boolean;
{ Replace every registered template element in the tree with its expanded
  subtree. Idempotent — safe to call on every Build. Returns the count expanded. }
function ExpandCustomElements(Root: THTMLTag): Integer;

implementation

var
  GElems: TList<TTina4ElementDef>;

function LowerName(const S: string): string;
begin
  Result := LowerCase(Trim(S));
end;

function IndexOfElem(const Name: string): Integer;
var i: Integer; ln: string;
begin
  Result := -1;
  if GElems = nil then Exit;
  ln := LowerName(Name);
  for i := 0 to GElems.Count - 1 do
    if GElems[i].Name = ln then Exit(i);
end;

procedure PutElem(const Def: TTina4ElementDef);
var idx: Integer;
begin
  if GElems = nil then GElems := TList<TTina4ElementDef>.Create;
  idx := IndexOfElem(Def.Name);
  if idx >= 0 then GElems[idx] := Def else GElems.Add(Def);
end;

procedure RegisterElement(const Name, Template: string; const DefaultCSS: string);
var d: TTina4ElementDef;
begin
  d.Name := LowerName(Name);
  d.Template := Template;
  d.DefaultCSS := DefaultCSS;
  d.Paint := nil;
  d.OnTap := nil;
  PutElem(d);
end;

procedure RegisterNativeElement(const Name: string; Paint: TElemPaintProc;
  OnTap: TElemTapProc; const DefaultCSS: string);
var d: TTina4ElementDef;
begin
  d.Name := LowerName(Name);
  d.Template := '';        // native, not expanded
  d.DefaultCSS := DefaultCSS;
  d.Paint := Paint;
  d.OnTap := OnTap;
  PutElem(d);
end;

procedure ClearElements;
begin
  if GElems <> nil then GElems.Clear;
end;

function IsRegisteredElement(const Name: string): Boolean;
begin
  Result := IndexOfElem(Name) >= 0;
end;

function IsTemplateElement(const Name: string): Boolean;
var idx: Integer;
begin
  Result := False;
  idx := IndexOfElem(Name);
  if idx >= 0 then Result := GElems[idx].Template <> '';
end;

function ElementPaintProc(const Name: string): TElemPaintProc;
var idx: Integer;
begin
  Result := nil;
  idx := IndexOfElem(Name);
  if idx >= 0 then Result := GElems[idx].Paint;
end;

function ElementTapProc(const Name: string): TElemTapProc;
var idx: Integer;
begin
  Result := nil;
  idx := IndexOfElem(Name);
  if idx >= 0 then Result := GElems[idx].OnTap;
end;

function ElementsDefaultCSS: string;
var i: Integer;
begin
  Result := '';
  if GElems = nil then Exit;
  for i := 0 to GElems.Count - 1 do
    if Trim(GElems[i].DefaultCSS) <> '' then
      Result := Result + GElems[i].DefaultCSS + #10;
end;

{ ---- HTML (de)serialisation for the children slot --------------------- }

function EscapeText(const S: string): string;
begin
  Result := StringReplace(S, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
end;

function EscapeAttr(const S: string): string;
begin
  Result := StringReplace(S, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
end;

function IsVoidTag(const Name: string): Boolean;
const V = ' area base br col embed hr img input link meta param source track wbr ';
begin
  Result := Pos(' ' + LowerCase(Name) + ' ', V) > 0;
end;

{ Serialise one node back to HTML (attributes + reconstructed inline style). }
function SerializeNode(T: THTMLTag): string;
var k, v, sty: string; i: Integer;
begin
  if T = nil then Exit('');
  if T.TagName = '#text' then Exit(EscapeText(T.Text));
  Result := '<' + T.TagName;
  for k in T.Attributes.Keys do
  begin
    v := T.Attributes[k];
    Result := Result + ' ' + k + '="' + EscapeAttr(v) + '"';
  end;
  // the parser lifts style="" into T.Style — put it back so slotted markup keeps
  // its inline styling across a round-trip
  sty := '';
  for k in T.Style.Keys do sty := sty + k + ':' + T.Style[k] + ';';
  if sty <> '' then Result := Result + ' style="' + EscapeAttr(sty) + '"';
  if IsVoidTag(T.TagName) then Exit(Result + '>');
  Result := Result + '>';
  for i := 0 to T.Children.Count - 1 do Result := Result + SerializeNode(T.Children[i]);
  Result := Result + '</' + T.TagName + '>';
end;

function SerializeChildren(T: THTMLTag): string;
var i: Integer;
begin
  Result := '';
  for i := 0 to T.Children.Count - 1 do Result := Result + SerializeNode(T.Children[i]);
end;

{ Fill brace-attr placeholders from the element's attributes (HTML-escaped) and
  the brace-children placeholder from the pre-serialised inner HTML (raw splice). }
function Interpolate(const Tpl: string; Host: THTMLTag; const Children: string): string;
var i, n, j: Integer; token: string;
begin
  Result := '';
  i := 1; n := Length(Tpl);
  while i <= n do
  begin
    if Tpl[i] = '{' then
    begin
      j := i + 1;
      while (j <= n) and (Tpl[j] <> '}') do Inc(j);
      if j <= n then
      begin
        token := Copy(Tpl, i + 1, j - i - 1);
        if SameText(token, 'children') then Result := Result + Children
        else Result := Result + EscapeAttr(Host.GetAttribute(token));
        i := j + 1;
        Continue;
      end;
    end;
    Result := Result + Tpl[i];
    Inc(i);
  end;
end;

{ The content nodes of a parsed template, descending past any implicit
  html/head/body the parser wrapped a bare fragment in. }
function ContentBase(Root: THTMLTag): THTMLTag;
var c, b: THTMLTag;
begin
  Result := Root;
  if Root = nil then Exit;
  for c in Root.Children do
    if SameText(c.TagName, 'html') then
    begin
      for b in c.Children do
        if SameText(b.TagName, 'body') then Exit(b);
      Exit(c);
    end
    else if SameText(c.TagName, 'body') then Exit(c);
end;

{ Replace Host (at Parent.Children[Index]) with its expanded template, spliced
  in at the same position; Host is consumed. Returns the number of nodes
  inserted. The Host's original inner HTML fills the children placeholder, its
  attributes fill the brace placeholders, and its id (if any) is carried onto the
  first inserted node that lacks one — so #id reactive bindings keep working. }
function ReplaceWithTemplate(Parent: THTMLTag; Index: Integer; Host: THTMLTag;
  const Tpl: string): Integer;
var
  src, html: string;
  tmp: THTMLParser;
  base, node: THTMLTag;
  moved: TList<THTMLTag>;
  i: Integer;
begin
  Result := 0;
  src := SerializeChildren(Host);
  html := Interpolate(Tpl, Host, src);
  tmp := THTMLParser.Create;
  moved := TList<THTMLTag>.Create;
  try
    tmp.Parse(html);
    base := ContentBase(tmp.Root);
    if base <> nil then
      for i := 0 to base.Children.Count - 1 do moved.Add(base.Children[i]);
    // carry the host id onto the first real element that has none
    if Host.HasAttribute('id') then
      for node in moved do
        if (node.TagName <> '#text') and not node.HasAttribute('id') then
        begin node.Attributes.AddOrSetValue('id', Host.GetAttribute('id')); Break; end;
    // drop the host from its parent, then splice the template nodes in its place
    Parent.Children.Delete(Index);
    Host.Parent := nil;
    Host.Free;                    // frees the host + its original children (now serialised)
    for i := 0 to moved.Count - 1 do
    begin
      node := moved[i];
      if (node.Parent <> nil) and (node.Parent.Children <> nil) then
        node.Parent.Children.Remove(node);   // detach without freeing (owned move)
      node.Parent := Parent;
      Parent.Children.Insert(Index + i, node);
    end;
    Result := moved.Count;
  finally
    moved.Free;
    tmp.Free;   // safe: moved nodes are no longer in tmp's tree
  end;
end;

function HasCustomElements(Root: THTMLTag): Boolean;
var c: THTMLTag;
begin
  Result := False;
  if Root = nil then Exit;
  if IsTemplateElement(Root.TagName) then Exit(True);
  for c in Root.Children do
    if HasCustomElements(c) then Exit(True);
end;

{ Walk a parent's child list, replacing each registered template element with its
  expansion; recurse into the inserted subtree (nested custom elements) and into
  ordinary children. Depth-guarded against a self-referential template. }
function ExpandInParent(Parent: THTMLTag; Depth: Integer): Integer;
var i, idx, cnt, j: Integer; child: THTMLTag;
begin
  Result := 0;
  if (Parent = nil) or (Depth > 16) then Exit;
  i := 0;
  while i < Parent.Children.Count do
  begin
    child := Parent.Children[i];
    idx := IndexOfElem(child.TagName);
    if (idx >= 0) and (GElems[idx].Template <> '') then
    begin
      cnt := ReplaceWithTemplate(Parent, i, child, GElems[idx].Template);
      Inc(Result);
      for j := i to i + cnt - 1 do
        Result := Result + ExpandInParent(Parent.Children[j], Depth + 1);
      i := i + cnt;    // past the freshly-inserted (already recursed) nodes
    end
    else
    begin
      Result := Result + ExpandInParent(child, Depth + 1);
      Inc(i);
    end;
  end;
end;

function ExpandCustomElements(Root: THTMLTag): Integer;
begin
  Result := ExpandInParent(Root, 0);
end;

initialization
  GElems := TList<TTina4ElementDef>.Create;
finalization
  GElems.Free;
end.
