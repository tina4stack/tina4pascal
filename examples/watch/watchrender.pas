program watchrender;
{ Render a watch HTML file with the SAME pure-Pascal software rasterizer the
  watch uses (Tina4RasterCanvas), headless on macOS. Emits the raw RGBA buffer
  ($AARRGGBB, top-left origin) — a companion script encodes it to PNG.

  This is the render half of the physical-watch mirror: the Mac produces the
  exact frames the native watchOS engine would (fonts, shapes, WebP images),
  and pushes them to a thin display app on the real watch (which can't run the
  arm64_32 engine yet — FPC phase 2).

  Usage: watchrender <html-file> <w> <h> <out.rgba> }
{$mode delphi}{$H+}
uses
  SysUtils, Classes,
  Tina4RenderBackend, Tina4RasterCanvas, Tina4Interact;
var
  canvas: TTina4RasterCanvas;
  html: TStringList;
  w, h: Integer;
  buf: Pointer;
  fs: TFileStream;
begin
  if ParamCount < 4 then
  begin
    Writeln('usage: watchrender <html> <w> <h> <out.rgba>');
    Halt(2);
  end;
  w := StrToInt(ParamStr(2));
  h := StrToInt(ParamStr(3));
  html := TStringList.Create;
  html.LoadFromFile(ParamStr(1));
  canvas := TTina4RasterCanvas.Create(w, h);
  TinaInit(canvas);
  TinaSetHtml(html.Text);
  TinaFrame(w, h, 1.0);
  buf := canvas.Bits;
  fs := TFileStream.Create(ParamStr(4), fmCreate);
  try
    fs.WriteBuffer(buf^, w * h * 4);
  finally
    fs.Free;
  end;
  Writeln('rendered ', w, 'x', h, ' -> ', ParamStr(4));
end.
