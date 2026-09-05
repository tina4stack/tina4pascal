program test_pseudo;

{ Verifies the CSS pseudo-classes :active / :hover / :focus actually change the
  computed style when the DOM flags flip — the standards path the interaction
  layer drives (SetActiveTag/TinaHover/FocusTag). No shell, no pixels. }

{$mode delphi}{$H+}

uses
  SysUtils, Tina4HTMLDom, Tina4HTMLLayout;

var Passed, Failed: Integer;

procedure Check(Cond: Boolean; const Name: string);
begin
  if Cond then Inc(Passed) else begin Inc(Failed); Writeln('  FAIL: ', Name); end;
end;

function ById(Node: THTMLTag; const Id: string): THTMLTag;
var c: THTMLTag;
begin
  Result := nil;
  if Node = nil then Exit;
  if Node.GetAttribute('id') = Id then Exit(Node);
  for c in Node.Children do
  begin
    Result := ById(c, Id);
    if Result <> nil then Exit;
  end;
end;

const HTML =
  '<style>' +
  '.b{background:#2b41e6}' +
  '.b:active{background:#ff5aa0}' +
  '.b:hover{background:#00aa00}' +
  '.b:focus{background:#ffd23c}' +
  '.b:checked{background:#112233}' +
  '</style>' +
  '<span class="b" id="s">x</span>';

var
  P: THTMLParser; Sheet: TCSSStyleSheet; el: THTMLTag;
  base, st: TComputedStyle; i: Integer;
begin
  Passed := 0; Failed := 0;
  P := THTMLParser.Create;
  Sheet := TCSSStyleSheet.Create;
  try
    P.Parse(HTML);
    for i := 0 to P.StyleBlocks.Count - 1 do Sheet.AddCSS(P.StyleBlocks[i]);
    Check(Sheet.HasInteractiveSelectors, 'sheet reports interactive selectors');

    el := ById(P.Root, 's');
    Check(el <> nil, 'found the span');

    base := TComputedStyle.ForTag(nil, Default(TComputedStyle), Sheet); // root-ish

    st := TComputedStyle.ForTag(el, base, Sheet);
    Check(st.BackgroundColor = $FF2B41E6, 'default background is blue');

    el.IsActive := True;
    st := TComputedStyle.ForTag(el, base, Sheet);
    Check(st.BackgroundColor = $FFFF5AA0, ':active background is pink');
    el.IsActive := False;

    el.IsHovered := True;
    st := TComputedStyle.ForTag(el, base, Sheet);
    Check(st.BackgroundColor = $FF00AA00, ':hover background is green');
    el.IsHovered := False;

    el.IsFocused := True;
    st := TComputedStyle.ForTag(el, base, Sheet);
    Check(st.BackgroundColor = $FFFFD23C, ':focus background is yellow');
    el.IsFocused := False;

    el.Attributes.AddOrSetValue('checked', '');
    st := TComputedStyle.ForTag(el, base, Sheet);
    Check(st.BackgroundColor = $FF112233, ':checked background applies');
    el.Attributes.Remove('checked');

    st := TComputedStyle.ForTag(el, base, Sheet);
    Check(st.BackgroundColor = $FF2B41E6, 'back to blue when flags cleared');
  finally
    Sheet.Free; P.Free;
  end;

  Writeln;
  Writeln(Passed, ' assertions passed, ', Failed, ' failed.');
  if Failed = 0 then begin Writeln('ALL TESTS PASS'); Halt(0); end else Halt(1);
end.
