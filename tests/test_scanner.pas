program test_scanner;

{ Headless test for the <barcode-scanner> element (Phase 1: core + contract).
  Drives Tina4Interact with a no-op measuring canvas (no shell), lays out a page
  with a <barcode-scanner>, and asserts it surfaces as a shell embed of kind 2
  with its formats, and that a decoded value reported via TinaScanResult fires
  the element's `onscan` action with the exact decoded string (parens and all —
  proving the by-name dispatch never parses the value as call syntax).
  Camera capture + decoding are per-shell and out of scope here. }

{$mode delphi}{$H+}

uses SysUtils, Classes, Tina4RenderBackend, Tina4Events, Tina4Interact;

type
  TStubCanvas = class(TTina4Canvas)
  public
    procedure FillRect(X, Y, W, H: Single; Color: TTina4Color); override;
    procedure StrokeRect(X, Y, W, H, Thickness: Single; Color: TTina4Color); override;
    procedure DrawLine(X1, Y1, X2, Y2, Thickness: Single; Color: TTina4Color); override;
    procedure DrawText(X, Y: Single; const Text: string; FontSize: Single;
      Styles: TTina4FontStyles; Color: TTina4Color); override;
    function MeasureText(const Text: string; FontSize: Single;
      Styles: TTina4FontStyles): TTina4TextMetrics; override;
    procedure SetClip(X, Y, W, H: Single); override;
    procedure ClearClip; override;
  end;

procedure TStubCanvas.FillRect(X, Y, W, H: Single; Color: TTina4Color); begin end;
procedure TStubCanvas.StrokeRect(X, Y, W, H, Thickness: Single; Color: TTina4Color); begin end;
procedure TStubCanvas.DrawLine(X1, Y1, X2, Y2, Thickness: Single; Color: TTina4Color); begin end;
procedure TStubCanvas.DrawText(X, Y: Single; const Text: string; FontSize: Single;
  Styles: TTina4FontStyles; Color: TTina4Color); begin end;
function TStubCanvas.MeasureText(const Text: string; FontSize: Single;
  Styles: TTina4FontStyles): TTina4TextMetrics;
begin
  Result.Width := Length(Text) * FontSize * 0.5;
  Result.Ascent := FontSize * 0.8; Result.Descent := FontSize * 0.2;
  Result.LineHeight := FontSize * 1.4;
end;
procedure TStubCanvas.SetClip(X, Y, W, H: Single); begin end;
procedure TStubCanvas.ClearClip; begin end;

var
  failed: Integer = 0;
  gGot: string = '';
  gCalls: Integer = 0;

procedure Check(Cond: Boolean; const Msg: string);
begin
  if Cond then WriteLn('  ok   ', Msg)
  else begin WriteLn('  FAIL ', Msg); Inc(failed); end;
end;

procedure OnScan(const Args: string);
begin gGot := Args; Inc(gCalls); end;

const
  PAGE =
    '<body>' +
    '<barcode-scanner id="s" onscan="Scan:Got" formats="qr,ean13" torch ' +
    'style="display:block;width:300px;height:280px"></barcode-scanner>' +
    '</body>';

var
  canvas: TStubCanvas;
  x, y, w, h: Single;
begin
  WriteLn('== Tina4 <barcode-scanner> tests ==');
  canvas := TStubCanvas.Create;
  TinaInit(canvas);
  RegisterAction('Scan:Got', @OnScan);
  TinaSetHtml(PAGE);
  TinaLayoutOnly(360, 1.0);        // build the layout tree, no painting

  WriteLn('element surfaces as a shell embed (kind 2)');
  Check(TinaEmbedCount = 1, 'one embed collected');
  Check(TinaEmbedKind(0) = 2, 'kind = 2 (barcode-scanner)');
  Check(TinaEmbedFormats(0) = 'qr,ean13', 'formats attribute captured');
  Check((TinaEmbedFlags(0) and 1) = 1, 'torch flag set');
  TinaEmbedRect(0, x, y, w, h);
  Check((w > 290) and (w < 310), 'embed width ~= css 300px');
  Check((h > 270) and (h < 290), 'embed height ~= css 280px');

  WriteLn('a decoded value fires onscan with the exact value');
  Check(TinaScanResult(0, 'HELLO)123(X', 'qr'), 'scan dispatched to onscan');
  Check(gGot = 'HELLO)123(X', 'handler received the exact decoded value (parens intact)');
  Check(gCalls = 1, 'handler invoked once');

  WriteLn('robustness');
  Check(not TinaScanResult(9, 'x', 'qr'), 'out-of-range index is a safe no-op');
  Check(gCalls = 1, 'no extra dispatch from the bad index');

  WriteLn;
  if failed = 0 then begin WriteLn('ALL TESTS PASS'); Halt(0); end
  else begin WriteLn(failed, ' FAILURE(S)'); Halt(1); end;
end.
