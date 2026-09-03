program leakcheck;

{ Headless memory-leak check: parse HTML, build the stylesheet and the full
  layout tree, then free everything — repeated — so heaptrc (compile with
  -gh) reports any unfreed blocks at the clean exit the GUI never has.
  Uses a no-op measuring canvas so no platform shell is needed. }

{$mode delphi}{$H+}

uses
  SysUtils, Classes,
  Tina4HTMLDom, Tina4RenderBackend, Tina4HTMLLayout;

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
  Result.Ascent := FontSize * 0.8;
  Result.Descent := FontSize * 0.2;
  Result.LineHeight := FontSize * 1.4;
end;
procedure TStubCanvas.SetClip(X, Y, W, H: Single); begin end;
procedure TStubCanvas.ClearClip; begin end;

const
  SAMPLE =
    '<html><head><style>' +
    '.card{display:inline-block;width:120px;padding:8px;background:#eee;border:1px solid #ccc;border-radius:6px}' +
    '.card:hover{background:#ddd}' +
    'ul li{color:#333}' +
    '</style></head><body style="padding:20px">' +
    '<h1>Heading</h1><p>Some <b>bold</b> and <i>italic</i> text with a ' +
    '<a href="#">link</a>.</p>' +
    '<div class="card">A</div><div class="card">B</div><div class="card">C</div>' +
    '<ul><li>one</li><li>two</li><li>three</li></ul>' +
    '<ol><li>alpha</li><li>beta</li></ol>' +
    '<table border="1"><tr><td>r1c1</td><td>r1c2</td></tr>' +
    '<tr><td>r2c1</td><td>r2c2</td></tr></table>' +
    '<div style="display:flex;justify-content:center">' +
    '<div style="width:60px;height:40px;background:#c33"></div>' +
    '<div style="width:60px;height:40px;background:#3c3"></div></div>' +
    '<form><input type="text" value="hello"><input type="checkbox" checked>' +
    '<select><option>x</option><option>y</option></select>' +
    '<textarea>note</textarea><input type="submit" value="Go"></form>' +
    '<div style="height:80px;overflow-y:auto"><p>a</p><p>b</p><p>c</p><p>d</p><p>e</p></div>' +
    '</body></html>';

procedure RunOnce;
var
  canvas: TStubCanvas;
  parser: THTMLParser;
  sheet: TCSSStyleSheet;
  engine: TLayoutEngine;
  root: TLayoutBox;
  i: Integer;
begin
  canvas := TStubCanvas.Create;
  parser := THTMLParser.Create;
  sheet := TCSSStyleSheet.Create;
  try
    parser.Parse(SAMPLE);
    for i := 0 to parser.StyleBlocks.Count - 1 do
      sheet.AddCSS(parser.StyleBlocks[i]);
    engine := TLayoutEngine.Create(canvas, sheet);
    try
      root := engine.Build(parser.Root, 1024);
      // simulate a hover restyle + relayout (mimics interaction churn)
      engine.RefreshStyles(root);
      root.Free;
    finally
      engine.Free;
    end;
  finally
    sheet.Free;
    parser.Free;
    canvas.Free;
  end;
end;

{ Optionally cycle a real HTML file passed as argv[1] (its <style> blocks
  only; linked CSS is ignored here). Otherwise use the synthetic SAMPLE. }
procedure RunFile(const FileName: string; Cycles: Integer);
var
  canvas: TStubCanvas;
  parser: THTMLParser;
  sheet: TCSSStyleSheet;
  engine: TLayoutEngine;
  root: TLayoutBox;
  sl: TStringList;
  html: string;
  i, n: Integer;
begin
  sl := TStringList.Create;
  try
    sl.LoadFromFile(FileName);
    html := sl.Text;
  finally
    sl.Free;
  end;
  for n := 1 to Cycles do
  begin
    canvas := TStubCanvas.Create;
    parser := THTMLParser.Create;
    sheet := TCSSStyleSheet.Create;
    try
      parser.Parse(html);
      for i := 0 to parser.StyleBlocks.Count - 1 do
        sheet.AddCSS(parser.StyleBlocks[i]);
      engine := TLayoutEngine.Create(canvas, sheet);
      try
        root := engine.Build(parser.Root, 1024);
        engine.RefreshStyles(root);
        root.Free;
      finally
        engine.Free;
      end;
    finally
      sheet.Free;
      parser.Free;
      canvas.Free;
    end;
  end;
end;

var
  i: Integer;
begin
  if ParamCount >= 1 then
  begin
    RunFile(ParamStr(1), 30);
    WriteLn('leakcheck: 30 cycles of ', ParamStr(1), ' complete');
  end
  else
  begin
    for i := 1 to 50 do
      RunOnce;
    WriteLn('leakcheck: 50 parse/layout/free cycles complete');
  end;
  { With -gh, heaptrc prints an unfreed-block dump here ONLY if leaks exist;
    silence == clean. }
end.
