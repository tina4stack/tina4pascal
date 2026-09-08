program test_pseudo_rebuild;
{ Regression: InjectPseudo must survive a SECOND Build on a DOM that already
  carries injected 'tina4::' pseudo children. The strip loop used to Free AND
  Delete(i), but THTMLTag.Destroy self-detaches from its parent — the extra
  Delete double-removed and raised EArgumentOutOfRangeException on the 2nd build
  (reproduced by opening a <select>, which rebuilds the layout). No headless
  test rebuilt a pseudo page before, so it slipped through. }
{$mode delphi}{$H+}

uses SysUtils, Tina4HTMLDom, Tina4RenderBackend, Tina4RasterCanvas, Tina4HTMLLayout;

var Fails: Integer = 0; Total: Integer = 0;
procedure Check(Cond: Boolean; const Msg: string);
begin
  Inc(Total);
  if Cond then WriteLn('  ok   ', Msg) else begin WriteLn('  FAIL ', Msg); Inc(Fails); end;
end;

function CountPseudo(T: THTMLTag): Integer;
var c: THTMLTag;
begin
  Result := 0;
  if T = nil then Exit;
  if Copy(T.TagName, 1, 7) = 'tina4::' then Inc(Result);
  for c in T.Children do Result := Result + CountPseudo(c);
end;

const HTML =
  '<body><style>' +
  '.a::before{content:"* "}.a::after{content:" !"}' +
  '.b::before{content:"x"}' +
  '</style>' +
  '<div class="a">one</div><div class="b">two</div><p class="a">three</p></body>';

var
  Parser: THTMLParser;
  Sheet: TCSSStyleSheet;
  Canvas: TTina4RasterCanvas;
  Engine: TLayoutEngine;
  Root: TLayoutBox;
  n1, n2, n3: Integer;
begin
  WriteLn('=== pseudo rebuild regression ===');
  Parser := THTMLParser.Create;
  Sheet := TCSSStyleSheet.Create;
  Canvas := TTina4RasterCanvas.Create(400, 300);
  try
    Parser.Parse(HTML);
    Sheet.AddCSS(Parser.StyleBlocks[0]);
    Engine := TLayoutEngine.Create(Canvas, Sheet);

    Root := Engine.Build(Parser.Root, 400, 300);   // 1st build injects pseudos
    n1 := CountPseudo(Parser.Root);
    Root.Free;
    Check(n1 = 5, 'first build injects 5 pseudo nodes (a: 2, b: 1, a: 2)');

    Root := Engine.Build(Parser.Root, 400, 300);   // 2nd build strips + re-injects (was the crash)
    n2 := CountPseudo(Parser.Root);
    Root.Free;
    Check(n2 = 5, 'second build re-injects exactly 5 (no leak, no crash)');

    Root := Engine.Build(Parser.Root, 400, 300);   // 3rd for good measure
    n3 := CountPseudo(Parser.Root);
    Root.Free;
    Check(n3 = 5, 'third build stable at 5');

    Engine.Free;
  finally
    Canvas.Free; Sheet.Free; Parser.Free;
  end;

  WriteLn(Total - Fails, '/', Total, ' assertions passed.');
  if Fails = 0 then WriteLn('ALL TESTS PASS') else begin WriteLn('FAILURES: ', Fails); Halt(1); end;
end.
