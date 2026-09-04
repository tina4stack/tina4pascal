program test_picture;

{ Tests responsive-image selection: srcset density + width descriptors,
  <picture>/<source> media + type filtering, and sizes resolution. Pure
  string/number logic — deterministic and mutation-proof. }

{$mode delphi}{$H+}

uses SysUtils, Classes, Generics.Collections,
  Tina4HTMLDom, Tina4RenderBackend, Tina4HTMLLayout;

var
  Failures: Integer = 0;

procedure Check(Cond: Boolean; const Msg: string);
begin
  if Cond then WriteLn('  ok   ', Msg)
  else begin WriteLn('  FAIL ', Msg); Inc(Failures); end;
end;

{ find the first <img> under a parsed fragment }
function FirstImg(P: THTMLParser): THTMLTag;
  function Walk(n: THTMLTag): THTMLTag;
  var c: THTMLTag;
  begin
    Result := nil;
    if SameText(n.TagName, 'img') then Exit(n);
    for c in n.Children do begin Result := Walk(c); if Result <> nil then Exit; end;
  end;
begin
  Result := Walk(P.Root);
end;

function ResolveHTML(const HTML: string; ViewportW, ElemW: Single): string;
var P: THTMLParser; img: THTMLTag;
begin
  P := THTMLParser.Create;
  try
    P.Parse(HTML);
    img := FirstImg(P);
    if img = nil then Exit('');
    Result := ResolveImgSrc(img, ViewportW, ElemW);
  finally
    P.Free;
  end;
end;

begin
  WriteLn('== Tina4 picture/srcset tests ==');

  WriteLn('srcset density descriptors → prefer 1x');
  Check(PickFromSrcset('a.png 1x, b.png 2x, c.png 3x', 0) = 'a.png', '1x/2x/3x picks 1x');
  Check(PickFromSrcset('hi.png 2x, lo.png 1x', 0) = 'lo.png', 'order-independent 1x');
  Check(PickFromSrcset('only.png', 0) = 'only.png', 'bare candidate (implicit 1x)');

  WriteLn('srcset width descriptors → smallest >= target');
  Check(PickFromSrcset('s.png 400w, m.png 800w, l.png 1200w', 500) = 'm.png',
    'target 500 → 800w');
  Check(PickFromSrcset('s.png 400w, m.png 800w, l.png 1200w', 800) = 'm.png',
    'target 800 → 800w (exact)');
  Check(PickFromSrcset('s.png 400w, m.png 800w, l.png 1200w', 2000) = 'l.png',
    'target beyond max → largest (1200w)');
  Check(PickFromSrcset('s.png 400w, m.png 800w', 100) = 's.png',
    'small target → smallest (400w)');

  WriteLn('media queries');
  Check(EvalMediaQuery('(max-width: 600px)', 500) = True, 'max-width 600 @ 500 → match');
  Check(EvalMediaQuery('(max-width: 600px)', 700) = False, 'max-width 600 @ 700 → no');
  Check(EvalMediaQuery('(min-width: 800px)', 900) = True, 'min-width 800 @ 900 → match');
  Check(EvalMediaQuery('(min-width: 480px) and (max-width: 900px)', 700) = True,
    'range 480..900 @ 700 → match');
  Check(EvalMediaQuery('(min-width: 480px) and (max-width: 900px)', 1000) = False,
    'range 480..900 @ 1000 → no');
  Check(EvalMediaQuery('', 500) = True, 'empty media → match');

  WriteLn('<picture> source selection');
  Check(ResolveHTML(
    '<picture>' +
    '<source media="(max-width: 600px)" srcset="small.png">' +
    '<source media="(min-width: 601px)" srcset="big.png">' +
    '<img src="fallback.png"></picture>', 500, -1) = 'small.png',
    'narrow viewport → small source');
  Check(ResolveHTML(
    '<picture>' +
    '<source media="(max-width: 600px)" srcset="small.png">' +
    '<source media="(min-width: 601px)" srcset="big.png">' +
    '<img src="fallback.png"></picture>', 1000, -1) = 'big.png',
    'wide viewport → big source');

  WriteLn('<picture> type filtering (unsupported skipped)');
  Check(ResolveHTML(
    '<picture>' +
    '<source type="image/svg+xml" srcset="vector.svg">' +
    '<source type="image/png" srcset="raster.png">' +
    '<img src="fallback.png"></picture>', 800, -1) = 'raster.png',
    'svg+xml skipped → png source');

  WriteLn('<picture> falls back to <img> when no source matches');
  Check(ResolveHTML(
    '<picture>' +
    '<source media="(max-width: 100px)" srcset="tiny.png">' +
    '<img src="fallback.png"></picture>', 800, -1) = 'fallback.png',
    'no source matches → img src');

  WriteLn('plain <img srcset> without <picture>');
  Check(ResolveHTML('<img srcset="a.png 1x, b.png 2x" src="c.png">', 800, -1) = 'a.png',
    'img srcset density → 1x');
  Check(ResolveHTML('<img src="only.png">', 800, -1) = 'only.png',
    'plain src passes through');

  WriteLn;
  if Failures = 0 then begin WriteLn('ALL TESTS PASS'); Halt(0); end
  else begin WriteLn(Failures, ' FAILURE(S)'); Halt(1); end;
end.
