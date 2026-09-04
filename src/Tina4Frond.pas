unit Tina4Frond;

(* Frond — Tina4's zero-dependency, Twig-compatible template engine, ported to
  Pascal. Renders template text against a JSON context (fpjson), which lines up
  with the document store and HTTP/API responses: build a context object, hand
  it to a template, get HTML.

  Implemented features:
    • output            {{ user.name }}   dotted paths, array[index], globals
    • filters           {{ x | upper }}   {{ p | number_format(2) }}  | default(..)
    • comments          {# ... #}
    • conditionals      {% if a %}…{% elseif b %}…{% else %}…{% endif %}
    • loops             {% for item in items %}…{% endfor %}
                        {% for k, v in obj %}   with loop.index/index0/first/last/length
    • assignment        {% set name = expr %}     {% set name %}…{% endset %}
    • includes          {% include "partials/x.twig" %}
    • inheritance       {% extends "base.twig" %} + {% block name %}…{% endblock %}
    • whitespace ctrl   {%- -%}  {{- -}}  {#- -#}
    • auto-escaping     {{ x }} escapes HTML; {{ x | raw }} does not
    • expressions       and/or/not, == != < > <= >=, in, +-*/, ( ), literals
    • extensibility      AddFilter / AddGlobal

  Built-in filters: upper lower capitalize title trim length default(v) join(sep)
  first last reverse keys values number_format(dec) round abs replace(a,b)
  truncate(n) nl2br escape/e raw string abs slug. *)

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, Generics.Collections, fpjson, jsonparser;

type
  TFrondFilter = function(const Args: array of string): string;

  TFrond = class
  private
    FDir: string;
    FGlobals: TJSONObject;                       // owned
    FFilters: TDictionary<string, TFrondFilter>;
    FCache: TDictionary<string, string>;         // {% cache %} fragments
    FCacheExp: TDictionary<string, TDateTime>;
    function ReadFile(const Name: string): string;
    function CacheFetch(const Key: string; out Content: string): Boolean;
    procedure CacheStore(const Key, Content: string; TTLSeconds: Double);
  public
    constructor Create(const TemplateDir: string = '');
    destructor Destroy; override;
    { Render a template FILE (relative to TemplateDir) against Context. }
    function Render(const TemplateName: string; Context: TJSONObject): string;
    { Render template TEXT directly (includes/extends still resolve via dir). }
    function RenderString(const Template: string; Context: TJSONObject): string;
    procedure AddGlobal(const Name: string; Value: TJSONData);   // takes a copy
    procedure AddGlobalStr(const Name, Value: string);
    procedure AddFilter(const Name: string; Fn: TFrondFilter);
  end;

implementation

{ ===================================================================== AST == }

type
  TNodeKind = (nkText, nkOutput, nkIf, nkFor, nkSet, nkSetBlock, nkInclude,
    nkBlock, nkExtends, nkMacro, nkImport, nkFrom, nkCache);

  TNode = class;
  TNodeList = TObjectList<TNode>;

  TBranch = class
    Cond: string;          // '' = else
    Body: TNodeList;
    constructor Create;
    destructor Destroy; override;
  end;

  TNode = class
    Kind: TNodeKind;
    S: string;             // text / expr / template name / block name
    KeyVar, ValVar: string;// for: {% for k, v in .. %}
    ListExpr: string;      // for: the iterable expression
    Body: TNodeList;       // for / block / setblock body
    Branches: TObjectList<TBranch>;  // if
    constructor Create(AKind: TNodeKind);
    destructor Destroy; override;
  end;

constructor TBranch.Create;
begin Body := TNodeList.Create(True); end;
destructor TBranch.Destroy;
begin Body.Free; inherited; end;

constructor TNode.Create(AKind: TNodeKind);
begin Kind := AKind; end;
destructor TNode.Destroy;
begin Body.Free; Branches.Free; inherited; end;

{ ================================================================== lexer === }

type
  TTokKind = (ttText, ttOutput, ttTag, ttComment);
  TToken = record
    Kind: TTokKind;
    Text: string;          // inner content (trimmed of the delimiters)
    TrimL, TrimR: Boolean; // whitespace-control markers
  end;

{ split a template into text, output, tag and comment tokens }
function Lex(const Src: string): TList<TToken>;
var
  i, n: Integer; tk: TToken; ch2: Char;

  procedure PushText(const T: string);
  begin
    if T = '' then Exit;
    tk.Kind := ttText; tk.Text := T; tk.TrimL := False; tk.TrimR := False;
    Result.Add(tk);
  end;

var start: Integer; open, close: string; inner: string;
begin
  Result := TList<TToken>.Create;
  n := Length(Src); i := 1; start := 1;
  while i <= n do
  begin
    if (i < n) and (Src[i] = '{') and (Src[i+1] in ['{', '%', '#']) then
    begin
      PushText(Copy(Src, start, i - start));
      ch2 := Src[i+1];
      case ch2 of
        '{': begin open := '{{'; close := '}}'; tk.Kind := ttOutput; end;
        '%': begin open := '{%'; close := '%}'; tk.Kind := ttTag; end;
      else    begin open := '{#'; close := '#}'; tk.Kind := ttComment; end;
      end;
      i := i + 2;
      tk.TrimL := (i <= n) and (Src[i] = '-');
      if tk.TrimL then Inc(i);
      // find the matching close
      start := i;
      while (i <= n) and not ((Src[i] = close[1]) and (i < n) and (Src[i+1] = close[2]))
            and not ((i > 1) and (Src[i-1] = '-') and (Src[i] = close[1]) and (i < n) and (Src[i+1] = close[2])) do
        Inc(i);
      inner := Copy(Src, start, i - start);
      tk.TrimR := (Length(inner) > 0) and (inner[Length(inner)] = '-');
      if tk.TrimR then SetLength(inner, Length(inner) - 1);
      tk.Text := Trim(inner);
      Result.Add(tk);
      i := i + 2;           // skip close delimiter
      start := i;
    end
    else Inc(i);
  end;
  PushText(Copy(Src, start, n - start + 1));
end;

{ apply whitespace-control: a token with TrimR trims trailing ws of the PRIOR
  text token; TrimL trims leading ws of the NEXT text token }
procedure ApplyTrim(Toks: TList<TToken>);
var i: Integer; t: TToken;
begin
  for i := 0 to Toks.Count - 1 do
    if Toks[i].Kind <> ttText then
    begin
      if Toks[i].TrimL and (i > 0) and (Toks[i-1].Kind = ttText) then
      begin t := Toks[i-1]; t.Text := TrimRight(t.Text); Toks[i-1] := t; end;
      if Toks[i].TrimR and (i < Toks.Count - 1) and (Toks[i+1].Kind = ttText) then
      begin t := Toks[i+1]; t.Text := TrimLeft(t.Text); Toks[i+1] := t; end;
    end;
end;

{ ================================================================= parser === }

type
  TParser = class
    Toks: TList<TToken>;
    Cur: Integer;
    function Peek: TToken;
    function Next: TToken;
    function Done: Boolean;
    { parse a node list until one of the given end-tags (returns the end word) }
    function ParseList(const Enders: array of string; out Ender: string): TNodeList;
    function TagWord(const S: string): string;
  end;

{ first-space position (0 if none) }
function Pos1Space(const S: string): Integer;
var i: Integer;
begin
  Result := 0;
  for i := 1 to Length(S) do
    if S[i] = ' ' then Exit(i);
end;

{ strip surrounding quotes from a string literal }
function Unquote(const S: string): string;
begin
  Result := Trim(S);
  if (Length(Result) >= 2) and
     (((Result[1] = '"') and (Result[Length(Result)] = '"')) or
      ((Result[1] = '''') and (Result[Length(Result)] = ''''))) then
    Result := Copy(Result, 2, Length(Result) - 2);
end;

function IsEnder(const W: string; const Enders: array of string): Boolean;
var i: Integer;
begin
  Result := False;
  for i := Low(Enders) to High(Enders) do
    if SameText(W, Enders[i]) then Exit(True);
end;

function TParser.Peek: TToken; begin Result := Toks[Cur]; end;
function TParser.Next: TToken; begin Result := Toks[Cur]; Inc(Cur); end;
function TParser.Done: Boolean; begin Result := Cur >= Toks.Count; end;

function TParser.TagWord(const S: string): string;
var p: Integer;
begin
  p := Pos1Space(S);
  if p = 0 then Result := S else Result := Copy(S, 1, p - 1);
end;

function TParser.ParseList(const Enders: array of string; out Ender: string): TNodeList;
var
  t: TToken; node, forNode, ifNode: TNode; word, rest, e2: string;
  branch: TBranch; inBody: TNodeList; p: Integer;

  function After(const Src, Kw: string): string;  // text after the keyword
  begin Result := Trim(Copy(Src, Length(Kw) + 1, MaxInt)); end;

begin
  Result := TNodeList.Create(True);
  Ender := '';
  while not Done do
  begin
    t := Peek;
    if t.Kind = ttComment then begin Next; Continue; end;
    if t.Kind = ttText then
    begin
      Next; node := TNode.Create(nkText); node.S := t.Text; Result.Add(node); Continue;
    end;
    if t.Kind = ttOutput then
    begin
      Next; node := TNode.Create(nkOutput); node.S := t.Text; Result.Add(node); Continue;
    end;
    // a tag
    word := LowerCase(TagWord(t.Text));
    if IsEnder(word, Enders) then begin Ender := word; Next; Exit; end;
    Next;   // consume the opening tag
    rest := t.Text;
    if word = 'if' then
    begin
      ifNode := TNode.Create(nkIf);
      ifNode.Branches := TObjectList<TBranch>.Create(True);
      branch := TBranch.Create; branch.Cond := After(rest, 'if');
      branch.Body.Free; branch.Body := ParseList(['elseif','else','endif'], e2);
      ifNode.Branches.Add(branch);
      while (e2 = 'elseif') or (e2 = 'else') do
      begin
        branch := TBranch.Create;
        if e2 = 'elseif' then branch.Cond := After(Toks[Cur-1].Text, 'elseif')
        else branch.Cond := '';
        branch.Body.Free;
        if e2 = 'else' then branch.Body := ParseList(['endif'], e2)
        else branch.Body := ParseList(['elseif','else','endif'], e2);
        ifNode.Branches.Add(branch);
      end;
      Result.Add(ifNode);
    end
    else if word = 'for' then
    begin
      forNode := TNode.Create(nkFor);
      rest := After(rest, 'for');
      p := Pos(' in ', rest);
      if p > 0 then
      begin
        forNode.ListExpr := Trim(Copy(rest, p + 4, MaxInt));
        rest := Trim(Copy(rest, 1, p - 1));
      end;
      p := Pos(',', rest);
      if p > 0 then
      begin
        forNode.KeyVar := Trim(Copy(rest, 1, p - 1));
        forNode.ValVar := Trim(Copy(rest, p + 1, MaxInt));
      end
      else forNode.ValVar := rest;
      forNode.Body := ParseList(['endfor'], e2);
      Result.Add(forNode);
    end
    else if word = 'set' then
    begin
      rest := After(rest, 'set');
      p := Pos('=', rest);
      if p > 0 then
      begin
        node := TNode.Create(nkSet);
        node.KeyVar := Trim(Copy(rest, 1, p - 1));
        node.S := Trim(Copy(rest, p + 1, MaxInt));
        Result.Add(node);
      end
      else
      begin
        node := TNode.Create(nkSetBlock);
        node.KeyVar := Trim(rest);
        node.Body := ParseList(['endset'], e2);
        Result.Add(node);
      end;
    end
    else if word = 'include' then
    begin
      node := TNode.Create(nkInclude);
      node.S := Unquote(After(rest, 'include'));
      Result.Add(node);
    end
    else if word = 'block' then
    begin
      node := TNode.Create(nkBlock);
      node.S := Trim(After(rest, 'block'));
      node.Body := ParseList(['endblock'], e2);
      Result.Add(node);
    end
    else if word = 'extends' then
    begin
      node := TNode.Create(nkExtends);
      node.S := Unquote(After(rest, 'extends'));
      Result.Add(node);
    end
    else if word = 'macro' then
    begin
      // {% macro name(a, b) %} … {% endmacro %}
      node := TNode.Create(nkMacro);
      rest := After(rest, 'macro');
      p := Pos('(', rest);
      if p > 0 then
      begin
        node.S := Trim(Copy(rest, 1, p - 1));
        node.ListExpr := Trim(Copy(rest, p + 1, MaxInt));
        p := Pos(')', node.ListExpr);
        if p > 0 then node.ListExpr := Trim(Copy(node.ListExpr, 1, p - 1));
      end
      else node.S := Trim(rest);
      node.Body := ParseList(['endmacro'], e2);
      Result.Add(node);
    end
    else if word = 'import' then
    begin
      // {% import "file" as ns %}
      node := TNode.Create(nkImport);
      rest := After(rest, 'import');
      p := Pos(' as ', rest);
      if p > 0 then
      begin
        node.S := Unquote(Trim(Copy(rest, 1, p - 1)));
        node.KeyVar := Trim(Copy(rest, p + 4, MaxInt));
      end
      else node.S := Unquote(rest);
      Result.Add(node);
    end
    else if word = 'from' then
    begin
      // {% from "file" import a, b %}
      node := TNode.Create(nkFrom);
      rest := After(rest, 'from');
      p := Pos(' import ', rest);
      if p > 0 then
      begin
        node.S := Unquote(Trim(Copy(rest, 1, p - 1)));
        node.ListExpr := Trim(Copy(rest, p + 8, MaxInt));
      end;
      Result.Add(node);
    end
    else if word = 'cache' then
    begin
      // {% cache "key" 300 %} … {% endcache %}   (key expr, ttl seconds)
      node := TNode.Create(nkCache);
      rest := Trim(After(rest, 'cache'));
      p := Pos1Space(rest);
      if p > 0 then
      begin
        node.S := Trim(Copy(rest, 1, p - 1));
        node.ListExpr := Trim(Copy(rest, p + 1, MaxInt));
      end
      else node.S := rest;
      node.Body := ParseList(['endcache'], e2);
      Result.Add(node);
    end;
    // unknown tags are ignored
  end;
end;

{ =========================================================== expressions === }
{ A value the evaluator passes around. JSON nodes are BORROWED (never freed);
  scalars carry their own string/number/bool. }

type
  TValKind = (vkNull, vkBool, vkNum, vkStr, vkJSON);
  TVal = record
    Kind: TValKind;
    B: Boolean;
    N: Double;
    S: string;
    J: TJSONData;          // borrowed
    Safe: Boolean;         // already-safe HTML (macro / parent output) — don't escape
  end;

function VNull: TVal;  begin Result.Kind := vkNull; Result.Safe := False; end;
function VBool(B: Boolean): TVal; begin Result.Kind := vkBool; Result.B := B; Result.Safe := False; end;
function VNum(N: Double): TVal;   begin Result.Kind := vkNum; Result.N := N; Result.Safe := False; end;
function VStr(const S: string): TVal; begin Result.Kind := vkStr; Result.S := S; Result.Safe := False; end;
function VStrSafe(const S: string): TVal; begin Result.Kind := vkStr; Result.S := S; Result.Safe := True; end;
function VJSON(J: TJSONData): TVal; begin Result.Kind := vkJSON; Result.J := J; Result.Safe := False; end;

{ format a number: whole values as plain integers, else a fixed decimal
  (fpjson's float AsString uses scientific notation, which we don't want). }
function NumStr(N: Double): string;
begin
  if Frac(N) = 0 then Result := IntToStr(Round(N))
  else begin Result := Format('%.10f', [N]);
    while (Result <> '') and (Result[Length(Result)] = '0') do SetLength(Result, Length(Result) - 1);
    if (Result <> '') and (Result[Length(Result)] = '.') then SetLength(Result, Length(Result) - 1);
  end;
end;

function ValToStr(const V: TVal): string;
begin
  case V.Kind of
    vkNull: Result := '';
    vkBool: if V.B then Result := 'true' else Result := 'false';
    vkNum:  Result := NumStr(V.N);
    vkStr:  Result := V.S;
    vkJSON:
      case V.J.JSONType of
        jtNull:    Result := '';
        jtBoolean: if V.J.AsBoolean then Result := 'true' else Result := 'false';
        jtNumber:  Result := NumStr(V.J.AsFloat);
        jtString:  Result := V.J.AsString;
      else Result := V.J.AsJSON;    // array/object → JSON text
      end;
  end;
end;

function ValToNum(const V: TVal): Double;
begin
  case V.Kind of
    vkNum:  Result := V.N;
    vkBool: if V.B then Result := 1 else Result := 0;
    vkStr:  Result := StrToFloatDef(V.S, 0);
    vkJSON: if V.J.JSONType = jtNumber then Result := V.J.AsFloat
            else Result := StrToFloatDef(ValToStr(V), 0);
  else Result := 0;
  end;
end;

function ValToBool(const V: TVal): Boolean;
begin
  case V.Kind of
    vkNull: Result := False;
    vkBool: Result := V.B;
    vkNum:  Result := V.N <> 0;
    vkStr:  Result := (V.S <> '') and (V.S <> '0') and not SameText(V.S, 'false');
    vkJSON:
      case V.J.JSONType of
        jtNull:    Result := False;
        jtBoolean: Result := V.J.AsBoolean;
        jtNumber:  Result := V.J.AsFloat <> 0;
        jtString:  Result := V.J.AsString <> '';
        jtArray:   Result := TJSONArray(V.J).Count > 0;
        jtObject:  Result := TJSONObject(V.J).Count > 0;
      else Result := True;
      end;
  else Result := False;
  end;
end;

{ HTML-escape for auto-escaping output }
function HtmlEscape(const S: string): string;
begin
  Result := StringReplace(S, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
  Result := StringReplace(Result, '''', '&#39;', [rfReplaceAll]);
end;

{ resolve a dotted path (a.b.c or a.0.b) against the context object }
function ResolvePath(const Path: string; Ctx: TJSONObject): TJSONData;
var parts: TStringList; i, idx: Integer; cur: TJSONData; part: string;
begin
  Result := nil;
  parts := TStringList.Create;
  try
    parts.Delimiter := '.'; parts.StrictDelimiter := True; parts.DelimitedText := Path;
    cur := Ctx;
    for i := 0 to parts.Count - 1 do
    begin
      part := parts[i];
      if cur = nil then Exit(nil);
      if cur.JSONType = jtObject then
        cur := TJSONObject(cur).Find(part)
      else if cur.JSONType = jtArray then
      begin
        idx := StrToIntDef(part, -1);
        if (idx >= 0) and (idx < TJSONArray(cur).Count) then cur := TJSONArray(cur).Items[idx]
        else cur := nil;
      end
      else cur := nil;
    end;
    Result := cur;
  finally
    parts.Free;
  end;
end;

{ number_format style }
function NumberFormat(N: Double; Dec: Integer): string;
begin
  Result := FormatFloat('0.' + StringOfChar('0', Dec), N);
  if Dec = 0 then Result := IntToStr(Round(N));
end;

{ apply one filter (name + optional string args) to a value }
function ApplyBuiltinFilter(const Name: string; const V: TVal;
  const Args: array of string; out Handled: Boolean): TVal;
var s: string; i, cnt: Integer; a: TJSONArray;
begin
  Handled := True;
  s := ValToStr(V);
  if Name = 'upper' then Result := VStr(UpperCase(s))
  else if Name = 'lower' then Result := VStr(LowerCase(s))
  else if (Name = 'capitalize') then
  begin if s <> '' then s[1] := UpCase(s[1]); Result := VStr(s); end
  else if Name = 'trim' then Result := VStr(Trim(s))
  else if Name = 'length' then
  begin
    if (V.Kind = vkJSON) and (V.J.JSONType = jtArray) then Result := VNum(TJSONArray(V.J).Count)
    else if (V.Kind = vkJSON) and (V.J.JSONType = jtObject) then Result := VNum(TJSONObject(V.J).Count)
    else Result := VNum(Length(s));
  end
  else if Name = 'default' then
  begin
    if (V.Kind = vkNull) or (s = '') then
    begin if Length(Args) > 0 then Result := VStr(Args[0]) else Result := VStr(''); end
    else Result := V;
  end
  else if Name = 'number_format' then
  begin
    if Length(Args) > 0 then cnt := StrToIntDef(Args[0], 0) else cnt := 0;
    Result := VStr(NumberFormat(ValToNum(V), cnt));
  end
  else if Name = 'round' then Result := VNum(Round(ValToNum(V)))
  else if Name = 'abs' then Result := VNum(Abs(ValToNum(V)))
  else if Name = 'string' then Result := VStr(s)
  else if (Name = 'escape') or (Name = 'e') then Result := VStr(HtmlEscape(s))
  else if Name = 'raw' then Result := V   // handled specially in output (no escape)
  else if Name = 'nl2br' then Result := VStr(StringReplace(HtmlEscape(s), #10, '<br>', [rfReplaceAll]))
  else if Name = 'replace' then
  begin
    if Length(Args) >= 2 then Result := VStr(StringReplace(s, Args[0], Args[1], [rfReplaceAll]))
    else Result := V;
  end
  else if Name = 'truncate' then
  begin
    if Length(Args) > 0 then cnt := StrToIntDef(Args[0], 255) else cnt := 255;
    if Length(s) > cnt then Result := VStr(Copy(s, 1, cnt) + '...') else Result := VStr(s);
  end
  else if Name = 'join' then
  begin
    s := '';
    if (V.Kind = vkJSON) and (V.J.JSONType = jtArray) then
    begin
      a := TJSONArray(V.J);
      for i := 0 to a.Count - 1 do
      begin
        if (i > 0) and (Length(Args) > 0) then s := s + Args[0];
        s := s + a.Items[i].AsString;
      end;
    end;
    Result := VStr(s);
  end
  else if Name = 'first' then
  begin
    if (V.Kind = vkJSON) and (V.J.JSONType = jtArray) and (TJSONArray(V.J).Count > 0) then
      Result := VJSON(TJSONArray(V.J).Items[0])
    else if s <> '' then Result := VStr(s[1]) else Result := VStr('');
  end
  else if Name = 'last' then
  begin
    if (V.Kind = vkJSON) and (V.J.JSONType = jtArray) and (TJSONArray(V.J).Count > 0) then
      Result := VJSON(TJSONArray(V.J).Items[TJSONArray(V.J).Count - 1])
    else if s <> '' then Result := VStr(s[Length(s)]) else Result := VStr('');
  end
  else
    Handled := False;
  if not Handled then Result := V;
end;

{ ---- expression evaluator (recursive descent over a small token list) ---- }

type
  TMacro = class
    Params: TStringList;
    Body: TNodeList;                       // borrowed (kept alive via OwnedLists)
    constructor Create;
    destructor Destroy; override;
  end;

  TExec = class
    Owner: TFrond;
    Blocks: TDictionary<string, TNode>;    // child block overrides (for extends)
    Macros: TObjectDictionary<string, TMacro>;  // name / ns.name → macro
    OwnedLists: TObjectList<TNodeList>;    // keep imported/base ASTs alive
    ParentStack: TList<TNode>;             // base block bodies, for parent()
    constructor Create;
    destructor Destroy; override;
    function Run(Nodes: TNodeList; Ctx: TJSONObject): string;
    procedure CollectBlocks(Nodes: TNodeList);
    procedure CollectMacros(Nodes: TNodeList; const NS: string);
    procedure LoadMacroFile(const FileName, NS: string);
    function CallMacro(const Name: string; const Args: array of string): string;
    function RenderParent(Ctx: TJSONObject): string;
    function RunCache(N: TNode; Ctx: TJSONObject): string;
  end;

  TExprEval = class
    Src: string;
    P: Integer;
    Ctx: TJSONObject;
    Owner: TFrond;
    Exec: TExec;
    function EvalOr: TVal;
    function EvalAnd: TVal;
    function EvalNot: TVal;
    function EvalCompare: TVal;
    function EvalAdd: TVal;
    function EvalMul: TVal;
    function EvalFilter: TVal;
    function EvalPrimary: TVal;
    procedure SkipWs;
    function PeekCh: Char;
    function MatchKw(const Kw: string): Boolean;
    function ReadIdent: string;
    function ReadStringLit: string;
  end;

procedure TExprEval.SkipWs;
begin while (P <= Length(Src)) and (Src[P] = ' ') do Inc(P); end;

function TExprEval.PeekCh: Char;
begin SkipWs; if P <= Length(Src) then Result := Src[P] else Result := #0; end;

function TExprEval.MatchKw(const Kw: string): Boolean;
var save: Integer; id: string;
begin
  save := P; SkipWs;
  id := ReadIdent;
  if SameText(id, Kw) then Result := True
  else begin Result := False; P := save; end;
end;

function TExprEval.ReadIdent: string;
begin
  SkipWs; Result := '';
  while (P <= Length(Src)) and (Src[P] in ['a'..'z','A'..'Z','0'..'9','_','.']) do
  begin Result := Result + Src[P]; Inc(P); end;
end;

function TExprEval.ReadStringLit: string;
var q: Char;
begin
  Result := ''; SkipWs; q := Src[P]; Inc(P);
  while (P <= Length(Src)) and (Src[P] <> q) do begin Result := Result + Src[P]; Inc(P); end;
  if P <= Length(Src) then Inc(P);
end;

function TExprEval.EvalOr: TVal;
var l, r: TVal;
begin
  l := EvalAnd;
  while MatchKw('or') do begin r := EvalAnd; l := VBool(ValToBool(l) or ValToBool(r)); end;
  Result := l;
end;

function TExprEval.EvalAnd: TVal;
var l, r: TVal;
begin
  l := EvalNot;
  while MatchKw('and') do begin r := EvalNot; l := VBool(ValToBool(l) and ValToBool(r)); end;
  Result := l;
end;

function TExprEval.EvalNot: TVal;
begin
  if MatchKw('not') then Result := VBool(not ValToBool(EvalNot))
  else Result := EvalCompare;
end;

function TExprEval.EvalCompare: TVal;
var l, r: TVal; op, test: string; c: Char; i: Integer; neg, b: Boolean;
begin
  l := EvalAdd;
  SkipWs;
  // tests:  x is [not] defined|empty|null|none|even|odd|iterable
  if MatchKw('is') then
  begin
    neg := MatchKw('not');
    test := LowerCase(ReadIdent);
    if test = 'defined' then b := l.Kind <> vkNull
    else if (test = 'null') or (test = 'none') then b := l.Kind = vkNull
    else if test = 'empty' then b := ValToStr(l) = ''
    else if test = 'even' then b := (Round(ValToNum(l)) mod 2) = 0
    else if test = 'odd' then b := (Round(ValToNum(l)) mod 2) <> 0
    else if test = 'iterable' then b := (l.Kind = vkJSON) and (l.J.JSONType in [jtArray, jtObject])
    else b := ValToBool(l);
    if neg then b := not b;
    Exit(VBool(b));
  end;
  op := '';
  c := PeekCh;
  if c in ['=','!','<','>'] then
  begin
    op := Src[P]; Inc(P);
    if (P <= Length(Src)) and (Src[P] = '=') then begin op := op + '='; Inc(P); end;
  end
  else if MatchKw('in') then op := 'in';
  if op = '' then Exit(l);
  r := EvalAdd;
  if op = 'in' then
  begin
    // membership: string-in-string, or value-in-array
    if (r.Kind = vkJSON) and (r.J.JSONType = jtArray) then
    begin
      Result := VBool(False);
      // linear scan by string equality
      for i := 0 to TJSONArray(r.J).Count - 1 do
        if TJSONArray(r.J).Items[i].AsString = ValToStr(l) then Exit(VBool(True));
    end
    else Result := VBool(Pos(ValToStr(l), ValToStr(r)) > 0);
    Exit;
  end;
  // numeric compare when both look numeric, else string compare
  if op = '==' then Result := VBool(ValToStr(l) = ValToStr(r))
  else if op = '!=' then Result := VBool(ValToStr(l) <> ValToStr(r))
  else if op = '<' then Result := VBool(ValToNum(l) < ValToNum(r))
  else if op = '>' then Result := VBool(ValToNum(l) > ValToNum(r))
  else if op = '<=' then Result := VBool(ValToNum(l) <= ValToNum(r))
  else if op = '>=' then Result := VBool(ValToNum(l) >= ValToNum(r))
  else Result := l;
end;

function TExprEval.EvalAdd: TVal;
var l, r: TVal; c: Char;
begin
  l := EvalMul;
  repeat
    c := PeekCh;
    if c = '+' then begin Inc(P); r := EvalMul; l := VNum(ValToNum(l) + ValToNum(r)); end
    else if (c = '~') then begin Inc(P); r := EvalMul; l := VStr(ValToStr(l) + ValToStr(r)); end
    else if c = '-' then begin Inc(P); r := EvalMul; l := VNum(ValToNum(l) - ValToNum(r)); end
    else Break;
  until False;
  Result := l;
end;

function TExprEval.EvalMul: TVal;
var l, r: TVal; c: Char;
begin
  l := EvalFilter;
  repeat
    c := PeekCh;
    if c = '*' then begin Inc(P); r := EvalFilter; l := VNum(ValToNum(l) * ValToNum(r)); end
    else if c = '/' then begin Inc(P); r := EvalFilter;
      if ValToNum(r) <> 0 then l := VNum(ValToNum(l) / ValToNum(r)) else l := VNum(0); end
    else Break;
  until False;
  Result := l;
end;

function TExprEval.EvalFilter: TVal;
var v: TVal; fname: string; args, callArgs: array of string; c: Char; a: string;
    handled: Boolean; fn: TFrondFilter; i: Integer;
begin
  v := EvalPrimary;
  while PeekCh = '|' do
  begin
    Inc(P);
    fname := LowerCase(ReadIdent);
    SetLength(args, 0);
    if PeekCh = '(' then
    begin
      Inc(P);
      while PeekCh <> ')' do
      begin
        c := PeekCh;
        if (c = '"') or (c = '''') then a := ReadStringLit
        else begin a := ''; while (P <= Length(Src)) and not (Src[P] in [',',')']) do begin a := a + Src[P]; Inc(P); end; a := Trim(a); end;
        SetLength(args, Length(args) + 1); args[High(args)] := a;
        if PeekCh = ',' then Inc(P);
      end;
      if PeekCh = ')' then Inc(P);
    end;
    // custom filters (string in/out) take precedence when registered
    if (Owner <> nil) and Owner.FFilters.TryGetValue(fname, fn) then
    begin
      SetLength(callArgs, Length(args) + 1);
      callArgs[0] := ValToStr(v);
      for i := 0 to High(args) do callArgs[i+1] := args[i];
      v := VStr(fn(callArgs));
    end
    else
    begin
      v := ApplyBuiltinFilter(fname, v, args, handled);
      // |raw is a no-op value-wise; the output node checks for it separately
    end;
  end;
  Result := v;
end;

function TExprEval.EvalPrimary: TVal;
var c: Char; id: string; node: TJSONData; num: string; callArgs: array of string;
begin
  c := PeekCh;
  if c = '(' then
  begin Inc(P); Result := EvalOr; if PeekCh = ')' then Inc(P); Exit; end;
  if (c = '"') or (c = '''') then Exit(VStr(ReadStringLit));
  if (c in ['0'..'9']) or ((c = '-') and (P < Length(Src)) and (Src[P+1] in ['0'..'9'])) then
  begin
    num := '';
    if c = '-' then begin num := '-'; Inc(P); end;
    while (P <= Length(Src)) and (Src[P] in ['0'..'9','.']) do begin num := num + Src[P]; Inc(P); end;
    Exit(VNum(StrToFloatDef(num, 0)));
  end;
  id := ReadIdent;
  if SameText(id, 'true') then Exit(VBool(True));
  if SameText(id, 'false') then Exit(VBool(False));
  if SameText(id, 'null') or SameText(id, 'none') then Exit(VNull);
  // a call: parent()  or  a macro name(args) — args evaluated to strings
  if PeekCh = '(' then
  begin
    Inc(P);
    SetLength(callArgs, 0);
    while PeekCh <> ')' do
    begin
      SetLength(callArgs, Length(callArgs) + 1);
      callArgs[High(callArgs)] := ValToStr(EvalOr);
      if PeekCh = ',' then Inc(P);
    end;
    if PeekCh = ')' then Inc(P);
    if SameText(id, 'parent') and (Exec <> nil) then Exit(VStrSafe(Exec.RenderParent(Ctx)));
    if Exec <> nil then Exit(VStrSafe(Exec.CallMacro(id, callArgs)));  // macro HTML is safe
    Exit(VStr(''));
  end;
  node := ResolvePath(id, Ctx);
  if node = nil then Result := VNull else Result := VJSON(node);
end;

function MergeGlobals(Globals, Context: TJSONObject): TJSONObject; forward;

function EvalExpr(const Expr: string; Ctx: TJSONObject; Owner: TFrond; Exec: TExec): TVal;
var e: TExprEval;
begin
  e := TExprEval.Create;
  try
    e.Src := Expr; e.P := 1; e.Ctx := Ctx; e.Owner := Owner; e.Exec := Exec;
    Result := e.EvalOr;
  finally e.Free; end;
end;

{ does an output expression end in a |raw filter? (skip escaping) }
function EndsRaw(const Expr: string): Boolean;
var s: string; p, i: Integer;
begin
  p := 0;
  for i := Length(Expr) downto 1 do
    if Expr[i] = '|' then begin p := i; Break; end;
  Result := False;
  if p > 0 then
  begin s := LowerCase(Trim(Copy(Expr, p + 1, MaxInt))); Result := (s = 'raw'); end;
end;

{ ================================================================ execute === }

constructor TMacro.Create;
begin Params := TStringList.Create; end;
destructor TMacro.Destroy;
begin Params.Free; inherited; end;

constructor TExec.Create;
begin
  Blocks := TDictionary<string, TNode>.Create;
  Macros := TObjectDictionary<string, TMacro>.Create([doOwnsValues]);
  OwnedLists := TObjectList<TNodeList>.Create(True);
  ParentStack := TList<TNode>.Create;
end;

destructor TExec.Destroy;
begin
  Blocks.Free; Macros.Free; OwnedLists.Free; ParentStack.Free;
  inherited;
end;

{ register macro definitions found in Nodes under an optional namespace }
procedure TExec.CollectMacros(Nodes: TNodeList; const NS: string);
var n: TNode; m: TMacro; parts: TStringList; i: Integer; key: string;
begin
  for n in Nodes do
    if n.Kind = nkMacro then
    begin
      m := TMacro.Create;
      m.Body := n.Body;
      parts := TStringList.Create;
      try
        parts.CommaText := n.ListExpr;                 // "a, b" → params
        for i := 0 to parts.Count - 1 do m.Params.Add(Trim(parts[i]));
      finally parts.Free; end;
      if NS <> '' then key := NS + '.' + n.S else key := n.S;
      Macros.AddOrSetValue(LowerCase(key), m);
    end;
end;

{ call a macro by name with positional string args; renders its body in a fresh
  scope (globals + params only, like Twig) }
function TExec.CallMacro(const Name: string; const Args: array of string): string;
var m: TMacro; ctx: TJSONObject; i: Integer;
begin
  Result := '';
  if not Macros.TryGetValue(LowerCase(Name), m) then Exit;
  ctx := MergeGlobals(Owner.FGlobals, nil);
  try
    for i := 0 to m.Params.Count - 1 do
    begin
      ctx.Delete(m.Params[i]);
      if i < Length(Args) then ctx.Add(m.Params[i], Args[i])
      else ctx.Add(m.Params[i], TJSONNull.Create);
    end;
    Result := Run(m.Body, ctx);
  finally
    ctx.Free;
  end;
end;

{ render the parent block body (used by the parent() call in an override) }
function TExec.RenderParent(Ctx: TJSONObject): string;
begin
  if ParentStack.Count > 0 then
    Result := Run(ParentStack[ParentStack.Count - 1].Body, Ctx)
  else
    Result := '';
end;

{ import/from — parse a macro file and register its macros (under NS, or
  unprefixed). The AST is kept alive so the macro bodies stay valid. }
procedure TExec.LoadMacroFile(const FileName, NS: string);
var src, e: string; t: TList<TToken>; par: TParser; nl: TNodeList;
begin
  src := Owner.ReadFile(FileName);
  if src = '' then Exit;
  t := Lex(src); ApplyTrim(t);
  par := TParser.Create; par.Toks := t; par.Cur := 0;
  nl := par.ParseList([], e);
  OwnedLists.Add(nl);            // keep alive; macro bodies point into it
  CollectMacros(nl, NS);
  par.Free; t.Free;
end;

{ cache tag — return the cached fragment if fresh, else render + store }
function TExec.RunCache(N: TNode; Ctx: TJSONObject): string;
var key, content: string; ttl: Double;
begin
  key := ValToStr(EvalExpr(N.S, Ctx, Owner, Self));
  ttl := ValToNum(EvalExpr(N.ListExpr, Ctx, Owner, Self));
  if Owner.CacheFetch(key, content) then Exit(content);
  content := Run(N.Body, Ctx);
  Owner.CacheStore(key, content, ttl);
  Result := content;
end;

procedure TExec.CollectBlocks(Nodes: TNodeList);
var n: TNode;
begin
  for n in Nodes do
  begin
    if n.Kind = nkBlock then
      if not Blocks.ContainsKey(n.S) then Blocks.Add(n.S, n);
    if n.Body <> nil then CollectBlocks(n.Body);
  end;
end;

function TExec.Run(Nodes: TNodeList; Ctx: TJSONObject): string;
var
  n: TNode; sb: TStringBuilder; v: TVal; i, cnt: Integer;
  branch: TBranch; matched: Boolean;
  arr: TJSONArray; obj, loop, childCtx: TJSONObject; it: TJSONData;
  blk: TNode; inc: TNodeList; e2, incSrc: string;
  itemName, keyName: string;

  procedure SetCtx(C: TJSONObject; const Nm: string; D: TJSONData);
  begin C.Delete(Nm); if D <> nil then C.Add(Nm, D.Clone) else C.Add(Nm, TJSONNull.Create); end;

begin
  sb := TStringBuilder.Create;
  try
    for n in Nodes do
    begin
      case n.Kind of
        nkText: sb.Append(n.S);
        nkOutput:
          begin
            v := EvalExpr(n.S, Ctx, Owner, Self);
            if v.Safe or EndsRaw(n.S) then sb.Append(ValToStr(v))
            else sb.Append(HtmlEscape(ValToStr(v)));
          end;
        nkIf:
          begin
            matched := False;
            for branch in n.Branches do
            begin
              if (branch.Cond = '') or ValToBool(EvalExpr(branch.Cond, Ctx, Owner, Self)) then
              begin sb.Append(Run(branch.Body, Ctx)); matched := True; Break; end;
            end;
          end;
        nkFor:
          begin
            v := EvalExpr(n.ListExpr, Ctx, Owner, Self);
            itemName := n.ValVar; keyName := n.KeyVar;
            if (v.Kind = vkJSON) and (v.J.JSONType = jtArray) then
            begin
              arr := TJSONArray(v.J); cnt := arr.Count;
              for i := 0 to cnt - 1 do
              begin
                SetCtx(Ctx, itemName, arr.Items[i]);
                if keyName <> '' then SetCtx(Ctx, keyName, TJSONIntegerNumber.Create(i));
                loop := TJSONObject.Create;
                loop.Add('index', i + 1); loop.Add('index0', i);
                loop.Add('first', i = 0); loop.Add('last', i = cnt - 1);
                loop.Add('length', cnt);
                Ctx.Delete('loop'); Ctx.Add('loop', loop);
                sb.Append(Run(n.Body, Ctx));
              end;
              Ctx.Delete('loop');
            end
            else if (v.Kind = vkJSON) and (v.J.JSONType = jtObject) then
            begin
              obj := TJSONObject(v.J); cnt := obj.Count;
              for i := 0 to cnt - 1 do
              begin
                SetCtx(Ctx, itemName, obj.Items[i]);
                if keyName <> '' then SetCtx(Ctx, keyName, TJSONString.Create(obj.Names[i]));
                loop := TJSONObject.Create;
                loop.Add('index', i + 1); loop.Add('index0', i);
                loop.Add('first', i = 0); loop.Add('last', i = cnt - 1);
                loop.Add('length', cnt);
                Ctx.Delete('loop'); Ctx.Add('loop', loop);
                sb.Append(Run(n.Body, Ctx));
              end;
              Ctx.Delete('loop');
            end;
          end;
        nkSet:
          begin
            v := EvalExpr(n.S, Ctx, Owner, Self);
            Ctx.Delete(n.KeyVar);
            case v.Kind of
              vkNum:  Ctx.Add(n.KeyVar, v.N);
              vkBool: Ctx.Add(n.KeyVar, v.B);
              vkJSON: Ctx.Add(n.KeyVar, v.J.Clone);
              vkNull: Ctx.Add(n.KeyVar, TJSONNull.Create);
            else Ctx.Add(n.KeyVar, v.S);
            end;
          end;
        nkSetBlock:
          begin
            Ctx.Delete(n.KeyVar);
            Ctx.Add(n.KeyVar, Run(n.Body, Ctx));
          end;
        nkInclude:
          begin
            incSrc := Owner.ReadFile(n.S);
            if incSrc <> '' then sb.Append(Owner.RenderString(incSrc, Ctx));
          end;
        nkBlock:
          begin
            // a child override renders instead of the base; the base body is
            // pushed so {{ parent() }} inside the override can reach it
            if (Blocks <> nil) and Blocks.TryGetValue(n.S, blk) and (blk <> n) then
            begin
              ParentStack.Add(n);
              sb.Append(Run(blk.Body, Ctx));
              ParentStack.Delete(ParentStack.Count - 1);
            end
            else
              sb.Append(Run(n.Body, Ctx));
          end;
        nkExtends: ;  // handled by RenderString
        nkMacro: ;    // definition only — collected up front, emits nothing
        nkImport:
          begin
            LoadMacroFile(n.S, n.KeyVar);
          end;
        nkFrom:
          begin
            LoadMacroFile(n.S, '');   // names imported unprefixed
          end;
        nkCache:
          begin
            sb.Append(RunCache(n, Ctx));
          end;
      end;
    end;
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

{ ================================================================== TFrond == }

constructor TFrond.Create(const TemplateDir: string);
begin
  FDir := TemplateDir;
  FGlobals := TJSONObject.Create;
  FFilters := TDictionary<string, TFrondFilter>.Create;
  FCache := TDictionary<string, string>.Create;
  FCacheExp := TDictionary<string, TDateTime>.Create;
end;

destructor TFrond.Destroy;
begin
  FGlobals.Free; FFilters.Free; FCache.Free; FCacheExp.Free;
  inherited;
end;

function TFrond.CacheFetch(const Key: string; out Content: string): Boolean;
var exp: TDateTime;
begin
  Content := '';
  Result := FCache.TryGetValue(Key, Content);
  if not Result then Exit;
  if FCacheExp.TryGetValue(Key, exp) and (exp <> 0) and (Now >= exp) then
  begin FCache.Remove(Key); FCacheExp.Remove(Key); Content := ''; Exit(False); end;
end;

procedure TFrond.CacheStore(const Key, Content: string; TTLSeconds: Double);
begin
  FCache.AddOrSetValue(Key, Content);
  if TTLSeconds > 0 then FCacheExp.AddOrSetValue(Key, Now + TTLSeconds / 86400.0)
  else FCacheExp.AddOrSetValue(Key, 0);
end;

function TFrond.ReadFile(const Name: string): string;
var st: TFileStream; p: string; bytes: TBytes;
begin
  Result := '';
  if FDir = '' then Exit;
  p := IncludeTrailingPathDelimiter(FDir) + Name;
  if not FileExists(p) then Exit;
  st := TFileStream.Create(p, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(bytes, st.Size);
    if st.Size > 0 then st.ReadBuffer(bytes[0], st.Size);
    Result := TEncoding.UTF8.GetString(bytes);   // exact content, no added newline
  finally
    st.Free;
  end;
end;

procedure TFrond.AddGlobal(const Name: string; Value: TJSONData);
begin
  FGlobals.Delete(Name);
  if Value <> nil then FGlobals.Add(Name, Value.Clone);
end;

procedure TFrond.AddGlobalStr(const Name, Value: string);
begin
  FGlobals.Delete(Name); FGlobals.Add(Name, Value);
end;

procedure TFrond.AddFilter(const Name: string; Fn: TFrondFilter);
begin
  FFilters.AddOrSetValue(LowerCase(Name), Fn);
end;

{ merge globals into a working copy of the context (globals lose to context) }
function MergeGlobals(Globals, Context: TJSONObject): TJSONObject;
var i: Integer;
begin
  Result := TJSONObject.Create;
  for i := 0 to Globals.Count - 1 do Result.Add(Globals.Names[i], Globals.Items[i].Clone);
  if Context <> nil then
    for i := 0 to Context.Count - 1 do
    begin
      Result.Delete(Context.Names[i]);
      Result.Add(Context.Names[i], Context.Items[i].Clone);
    end;
end;

function TFrond.RenderString(const Template: string; Context: TJSONObject): string;
var
  toks: TList<TToken>; parser: TParser; nodes: TNodeList; ender: string;
  exec: TExec; ctx: TJSONObject; extendsName: string; n: TNode; baseSrc: string;
  btoks: TList<TToken>; bparser: TParser; bnodes: TNodeList; be: string;
begin
  toks := Lex(Template);
  ApplyTrim(toks);
  parser := TParser.Create;
  parser.Toks := toks; parser.Cur := 0;
  nodes := parser.ParseList([], ender);

  // template inheritance: if this template extends a base, render the base with
  // this template's blocks collected as overrides
  extendsName := '';
  for n in nodes do if n.Kind = nkExtends then begin extendsName := n.S; Break; end;

  ctx := MergeGlobals(FGlobals, Context);
  exec := TExec.Create;
  exec.Owner := Self;
  exec.CollectMacros(nodes, '');           // macros defined in THIS template
  try
    if extendsName <> '' then
    begin
      exec.CollectBlocks(nodes);            // child block overrides
      baseSrc := ReadFile(extendsName);
      // parse the base and run it with the overrides in scope
      btoks := Lex(baseSrc); ApplyTrim(btoks);
      bparser := TParser.Create; bparser.Toks := btoks; bparser.Cur := 0;
      bnodes := bparser.ParseList([], be);
      exec.OwnedLists.Add(bnodes);          // keep base AST alive
      exec.CollectMacros(bnodes, '');
      try
        Result := exec.Run(bnodes, ctx);
      finally
        bparser.Free; btoks.Free;
      end;
    end
    else
      Result := exec.Run(nodes, ctx);
  finally
    exec.Free;
    nodes.Free; parser.Free; toks.Free; ctx.Free;
  end;
end;

function TFrond.Render(const TemplateName: string; Context: TJSONObject): string;
begin
  Result := RenderString(ReadFile(TemplateName), Context);
end;

end.
