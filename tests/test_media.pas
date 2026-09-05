program test_media;

{ @media support: min-width/max-width breakpoints and prefers-color-scheme dark
  (incl. :root custom-property overrides — the dark-theme color-vars path).
  Verified at the computed-style level against a live media context. }

{$mode delphi}{$H+}

uses SysUtils, Tina4RenderBackend, Tina4HTMLDom, Tina4HTMLLayout;

var Passed, Failed: Integer;

procedure Check(Cond: Boolean; const Name: string);
begin if Cond then Inc(Passed) else begin Inc(Failed); Writeln('  FAIL: ', Name); end; end;

function ById(N: THTMLTag; const Id: string): THTMLTag;
var c: THTMLTag;
begin
  Result := nil; if N = nil then Exit;
  if N.GetAttribute('id') = Id then Exit(N);
  for c in N.Children do begin Result := ById(c, Id); if Result <> nil then Exit; end;
end;

const HTML =
  '<style>' +
  ':root{--c:#2b41e6}' +
  '.x{color:var(--c);background:#111111}' +
  '@media (prefers-color-scheme: dark){:root{--c:#ff0000}}' +
  '@media (min-width: 768px){.x{background:#00ff00}}' +
  '@media (max-width: 400px){.x{background:#0000ff}}' +
  '</style><span class="x" id="s">hi</span>';

var
  P: THTMLParser; S: TCSSStyleSheet; el: THTMLTag; base, st: TComputedStyle; i: Integer;

function BgAt(W: Single; dark: Boolean): TTina4Color;
begin S.SetMediaContext(W, dark); st := TComputedStyle.ForTag(el, base, S); Result := st.BackgroundColor; end;
function ColorAt(W: Single; dark: Boolean): TTina4Color;
begin S.SetMediaContext(W, dark); st := TComputedStyle.ForTag(el, base, S); Result := st.Color; end;

begin
  Passed := 0; Failed := 0;
  P := THTMLParser.Create; S := TCSSStyleSheet.Create;
  P.Parse(HTML);
  for i := 0 to P.StyleBlocks.Count - 1 do S.AddCSS(P.StyleBlocks[i]);
  el := ById(P.Root, 's'); base := TComputedStyle.ForTag(nil, Default(TComputedStyle), S);

  Check(S.HasMediaRules, 'sheet reports @media rules');
  Check(ColorAt(700, False) = $FF2B41E6, 'light: color var = blue');
  Check(ColorAt(700, True)  = $FFFF0000, 'dark: :root var override = red (color-vars fix)');
  Check(BgAt(500, False) = $FF111111, 'mid width: base background (no breakpoint)');
  Check(BgAt(1000, False) = $FF00FF00, 'min-width:768 applies at 1000');
  Check(BgAt(700, False) = $FF111111, 'min-width:768 does NOT apply at 700');
  Check(BgAt(360, False) = $FF0000FF, 'max-width:400 applies at 360');

  Writeln; Writeln(Passed, ' assertions passed, ', Failed, ' failed.');
  if Failed = 0 then begin Writeln('ALL TESTS PASS'); Halt(0); end else Halt(1);
end.
