unit Tina4Builtins;

{ Built-in semantic actions for interactivity that needs no app code and no JS
  engine — just DOM mutation driven by the existing Tina4Events dispatch:

    <button onclick="dialog.showModal('info')">      → opens <dialog id=info>
    <button onclick="dialog.close('info')">          → closes it
    <input oninput="output.recalc()">                → recomputes <output> formulas

  A modal dialog is marked with `_modal`; the layer paints a backdrop and centres
  it. An <output formula="a + b"> is recomputed from the current values of the
  named form fields (a tiny arithmetic evaluator — numbers, + - * / and parens).

  The registry is DOM-root-scoped via BuiltinsRoot; a built-in that mutates the
  tree sets BuiltinsDirty so the host knows to relayout. Pure Pascal, shared by
  every shell. }

{$mode delphi}{$H+}

interface

uses Tina4HTMLDom;

var
  { The DOM root the built-ins act on. The host sets it after each parse. }
  BuiltinsRoot: THTMLTag = nil;
  { Set True by any built-in that changed the DOM — the host relayouts and clears it. }
  BuiltinsDirty: Boolean = False;

{ Register dialog.* and output.* with Tina4Events. Call once at startup. }
procedure RegisterBuiltinActions;

{ Recompute every <output formula="..."> under Root from current field values. }
procedure RecalcOutputs(Root: THTMLTag);

{ Depth-first lookups used by the built-ins (exposed for hosts/tests). }
function FindById(Root: THTMLTag; const Id: string): THTMLTag;
function FindByName(Root: THTMLTag; const Name: string): THTMLTag;

implementation

uses SysUtils, Tina4Events, Tina4RenderBackend;

function FindById(Root: THTMLTag; const Id: string): THTMLTag;
var c: THTMLTag;
begin
  Result := nil;
  if Root = nil then Exit;
  if SameText(Root.GetAttribute('id'), Id) then Exit(Root);
  for c in Root.Children do
  begin
    Result := FindById(c, Id);
    if Result <> nil then Exit;
  end;
end;

function FindByName(Root: THTMLTag; const Name: string): THTMLTag;
var c: THTMLTag;
begin
  Result := nil;
  if Root = nil then Exit;
  if SameText(Root.GetAttribute('name'), Name) and (Root.GetAttribute('name') <> '') then
    Exit(Root);
  for c in Root.Children do
  begin
    Result := FindByName(c, Name);
    if Result <> nil then Exit;
  end;
end;

{ Strip surrounding quotes/space from an action argument ('info' → info). }
function Unquote(const S: string): string;
begin
  Result := Trim(S);
  if (Length(Result) >= 2) and (Result[1] in ['''', '"']) and
     (Result[Length(Result)] = Result[1]) then
    Result := Copy(Result, 2, Length(Result) - 2);
end;

{ ---- tiny arithmetic evaluator over field names -------------------------- }
{ Grammar: expr := term (('+'|'-') term)* ; term := factor (('*'|'/') factor)*
  factor := number | '(' expr ')' | '-' factor | ident   (ident = a field name,
  resolved to its current numeric value; unknown/blank = 0). }

type
  TExprCtx = record
    S: string;
    Pos: Integer;
    Root: THTMLTag;
  end;

procedure SkipSpace(var C: TExprCtx);
begin
  while (C.Pos <= Length(C.S)) and (C.S[C.Pos] = ' ') do Inc(C.Pos);
end;

function FieldValue(Root: THTMLTag; const Name: string): Double;
var t: THTMLTag; v: string;
begin
  Result := 0;
  t := FindByName(Root, Name);
  if t = nil then Exit;
  v := t.GetAttribute('value');
  if v = '' then v := t.GetAttribute('_value');   // an <output>'s own computed value
  Result := StrToFloatDef(Trim(v), 0);
end;

function ParseExpr(var C: TExprCtx): Double; forward;

function ParseFactor(var C: TExprCtx): Double;
var start: Integer; ident: string;
begin
  SkipSpace(C);
  Result := 0;
  if C.Pos > Length(C.S) then Exit;
  if C.S[C.Pos] = '(' then
  begin
    Inc(C.Pos);
    Result := ParseExpr(C);
    SkipSpace(C);
    if (C.Pos <= Length(C.S)) and (C.S[C.Pos] = ')') then Inc(C.Pos);
  end
  else if C.S[C.Pos] = '-' then
  begin
    Inc(C.Pos);
    Result := -ParseFactor(C);
  end
  else if C.S[C.Pos] in ['0'..'9', '.'] then
  begin
    start := C.Pos;
    while (C.Pos <= Length(C.S)) and (C.S[C.Pos] in ['0'..'9', '.']) do Inc(C.Pos);
    Result := StrToFloatDef(Copy(C.S, start, C.Pos - start), 0);
  end
  else if C.S[C.Pos] in ['A'..'Z', 'a'..'z', '_'] then
  begin
    start := C.Pos;
    while (C.Pos <= Length(C.S)) and
          (C.S[C.Pos] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '-']) do Inc(C.Pos);
    ident := Copy(C.S, start, C.Pos - start);
    Result := FieldValue(C.Root, ident);
  end;
end;

function ParseTerm(var C: TExprCtx): Double;
var op: Char; rhs: Double;
begin
  Result := ParseFactor(C);
  SkipSpace(C);
  while (C.Pos <= Length(C.S)) and (C.S[C.Pos] in ['*', '/']) do
  begin
    op := C.S[C.Pos]; Inc(C.Pos);
    rhs := ParseFactor(C);
    if op = '*' then Result := Result * rhs
    else if rhs <> 0 then Result := Result / rhs
    else Result := 0;
    SkipSpace(C);
  end;
end;

function ParseExpr(var C: TExprCtx): Double;
var op: Char;
begin
  Result := ParseTerm(C);
  SkipSpace(C);
  while (C.Pos <= Length(C.S)) and (C.S[C.Pos] in ['+', '-']) do
  begin
    op := C.S[C.Pos]; Inc(C.Pos);
    if op = '+' then Result := Result + ParseTerm(C)
    else Result := Result - ParseTerm(C);
    SkipSpace(C);
  end;
end;

function EvalExpr(Root: THTMLTag; const Formula: string): Double;
var C: TExprCtx;
begin
  C.S := Formula; C.Pos := 1; C.Root := Root;
  Result := ParseExpr(C);
end;

{ Format a result without a trailing ".0" for whole numbers. }
function FormatNum(V: Double): string;
begin
  if Frac(V) = 0 then Result := IntToStr(Round(V))
  else Result := Trim(Format('%.4f', [V]));
end;

{ Set an element's rendered text: reuse its first #text child, else create one. }
procedure SetElementText(T: THTMLTag; const S: string);
var i: Integer; tn: THTMLTag;
begin
  for i := 0 to T.Children.Count - 1 do
    if T.Children[i].TagName = '#text' then
    begin
      T.Children[i].Text := S;
      Exit;
    end;
  tn := THTMLTag.Create;
  tn.TagName := '#text';
  tn.Text := S;
  tn.Parent := T;
  T.Children.Add(tn);
end;

procedure RecalcOutputs(Root: THTMLTag);
var c: THTMLTag; s: string;
begin
  if Root = nil then Exit;
  if SameText(Root.TagName, 'output') and Root.HasAttribute('formula') then
  begin
    s := FormatNum(EvalExpr(BuiltinsRoot, Root.GetAttribute('formula')));
    Root.Attributes.AddOrSetValue('_value', s);   // for formulas that read outputs
    SetElementText(Root, s);                        // what the user sees
  end;
  for c in Root.Children do RecalcOutputs(c);
end;

{ ---- built-in actions ---------------------------------------------------- }

{ Close every open <dialog> (used by dialog.close() with no id). }
procedure CloseAllDialogs(Root: THTMLTag);
var c: THTMLTag;
begin
  if Root = nil then Exit;
  if SameText(Root.TagName, 'dialog') then
  begin
    Root.Attributes.Remove('open');
    Root.Attributes.Remove('_modal');
  end;
  for c in Root.Children do CloseAllDialogs(c);
end;

procedure ActDialogShow(const Args: string);
var d: THTMLTag;
begin
  d := FindById(BuiltinsRoot, Unquote(Args));
  if (d <> nil) and SameText(d.TagName, 'dialog') then
  begin
    d.Attributes.AddOrSetValue('open', 'open');
    d.Attributes.Remove('_modal');
    BuiltinsDirty := True;
  end;
end;

procedure ActDialogShowModal(const Args: string);
var d: THTMLTag;
begin
  d := FindById(BuiltinsRoot, Unquote(Args));
  if (d <> nil) and SameText(d.TagName, 'dialog') then
  begin
    d.Attributes.AddOrSetValue('open', 'open');
    d.Attributes.AddOrSetValue('_modal', '1');
    BuiltinsDirty := True;
  end;
end;

procedure ActDialogClose(const Args: string);
var d: THTMLTag; id: string;
begin
  id := Unquote(Args);
  if id = '' then
    CloseAllDialogs(BuiltinsRoot)
  else
  begin
    d := FindById(BuiltinsRoot, id);
    if (d <> nil) and SameText(d.TagName, 'dialog') then
    begin
      d.Attributes.Remove('open');
      d.Attributes.Remove('_modal');
    end;
  end;
  BuiltinsDirty := True;
end;

procedure ActOutputRecalc(const Args: string);
begin
  RecalcOutputs(BuiltinsRoot);
  BuiltinsDirty := True;
end;

{ first #text child's text, joined — reads what SetElementText writes }
function ElemText(T: THTMLTag): string;
var i: Integer;
begin
  Result := '';
  if T = nil then Exit;
  for i := 0 to T.Children.Count - 1 do
    if T.Children[i].TagName = '#text' then Result := Result + T.Children[i].Text;
end;

{ notify.show('Title', 'Body') — post a local OS notification through the host's
  registered handler. One arg = title only; the id of an element resolves to its
  text if unquoted (so notify.show(msg) can surface a live SSE value). }
procedure ActNotifyShow(const Args: string);
var s, a0, a1, title, body: string; depth, i, comma: Integer; inq: Char; el: THTMLTag;
begin
  s := Trim(Args);
  // split on the first top-level comma (respect quotes)
  comma := 0; depth := 0; inq := #0;
  for i := 1 to Length(s) do
  begin
    if inq <> #0 then begin if s[i] = inq then inq := #0; end
    else if (s[i] = '''') or (s[i] = '"') then inq := s[i]
    else if s[i] = '(' then Inc(depth)
    else if s[i] = ')' then Dec(depth)
    else if (s[i] = ',') and (depth = 0) then begin comma := i; Break; end;
  end;
  if comma > 0 then begin a0 := Trim(Copy(s, 1, comma - 1)); a1 := Trim(Copy(s, comma + 1, MaxInt)); end
  else begin a0 := s; a1 := ''; end;

  // a quoted arg is a literal; a bare identifier is an element id → its text
  if (a0 <> '') and (a0[1] in ['''', '"']) then title := Unquote(a0)
  else begin el := FindById(BuiltinsRoot, a0); if el <> nil then title := ElemText(el) else title := a0; end;
  if (a1 <> '') and (a1[1] in ['''', '"']) then body := Unquote(a1)
  else if a1 <> '' then begin el := FindById(BuiltinsRoot, a1); if el <> nil then body := ElemText(el) else body := a1; end
  else body := '';

  Tina4Notify(title, body, '');
end;

procedure RegisterBuiltinActions;
begin
  RegisterAction('dialog.show', @ActDialogShow);
  RegisterAction('dialog.showModal', @ActDialogShowModal);
  RegisterAction('notify.show', @ActNotifyShow);
  RegisterAction('dialog.close', @ActDialogClose);
  RegisterAction('output.recalc', @ActOutputRecalc);
end;

end.
