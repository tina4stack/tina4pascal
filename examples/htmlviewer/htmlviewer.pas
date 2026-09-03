program htmlviewer;

{ Tina4 native-pascal HTML viewer — macOS shell.
  Usage: htmlviewer [file.html] [--snapshot out.png]
  Renders the file (default: ../Example/bootstrap_test.html), scrolls with
  trackpad/wheel, and reports semantic events (onclick / links / buttons)
  to stdout — the HTML-drives-everything model, no widget components. }

{$mode delphi}{$H+}

uses
  SysUtils, Classes,
  Tina4HTMLDom, Tina4RenderBackend, Tina4ShellCocoa, Tina4HTMLLayout;

type
  TViewer = class
  public
    Shell: TCocoaShell;
    Parser: THTMLParser;
    Sheet: TCSSStyleSheet;
    RootBox: TLayoutBox;
    Engine: TLayoutEngine;
    ScrollY: Single;
    LastW: Single;
    procedure Paint(Canvas: TTina4Canvas; W, H: Single);
    procedure Scroll(DX, DY: Single);
    procedure MouseUp(X, Y: Single);
  end;

var
  Viewer: TViewer;
  ViewH: Single = 0;

procedure TViewer.Paint(Canvas: TTina4Canvas; W, H: Single);
var
  maxScroll, thumbH, thumbY: Single;
begin
  ViewH := H;
  if (RootBox = nil) or (Abs(W - LastW) > 0.5) then
  begin
    LastW := W;
    FreeAndNil(RootBox);
    FreeAndNil(Engine);
    Engine := TLayoutEngine.Create(Canvas, Sheet);
    RootBox := Engine.Build(Parser.Root, W);
  end;
  Canvas.FillRect(0, 0, W, H, $FFFFFFFF);
  PaintBox(Canvas, RootBox, ScrollY);
  // minimal scrollbar
  if RootBox.H > H then
  begin
    maxScroll := RootBox.H - H;
    thumbH := H * (H / RootBox.H);
    thumbY := (ScrollY / maxScroll) * (H - thumbH);
    Canvas.FillRect(W - 8, thumbY, 6, thumbH, $60000000);
  end;
end;

procedure TViewer.Scroll(DX, DY: Single);
var
  maxScroll: Single;
begin
  if RootBox = nil then Exit;
  maxScroll := RootBox.H - ViewH;
  if maxScroll < 0 then maxScroll := 0;
  ScrollY := ScrollY - DY; // natural scrolling: content follows fingers
  if ScrollY < 0 then ScrollY := 0;
  if ScrollY > maxScroll then ScrollY := maxScroll;
  Shell.Invalidate;
end;

procedure TViewer.MouseUp(X, Y: Single);
var
  hit, t: THTMLTag;
begin
  if RootBox = nil then Exit;
  hit := HitTest(RootBox, X, Y + ScrollY);
  t := hit;
  while t <> nil do
  begin
    if t.HasAttribute('onclick') then
    begin
      WriteLn('[event] onclick -> ', t.GetAttribute('onclick'),
        '  (<', t.TagName, '> "', Copy(Trim(t.GetAttribute('class')), 1, 40), '")');
      Exit;
    end;
    if SameText(t.TagName, 'a') and t.HasAttribute('href') then
    begin
      WriteLn('[event] link -> ', t.GetAttribute('href'));
      Exit;
    end;
    t := t.Parent;
  end;
  if hit <> nil then
    WriteLn('[event] click on <', hit.TagName, '>');
end;

var
  FileName, SnapPath, HTML, CSSFile: string;
  SL: TStringList;
  i: Integer;
begin
  FileName := ExpandFileName(ExtractFilePath(ParamStr(0)) + 'bootstrap_test.html');
  SnapPath := '';
  i := 1;
  while i <= ParamCount do
  begin
    if ParamStr(i) = '--snapshot' then
    begin
      Inc(i);
      SnapPath := ParamStr(i);
    end
    else
      FileName := ParamStr(i);
    Inc(i);
  end;
  if not FileExists(FileName) then
  begin
    WriteLn('File not found: ', FileName);
    Halt(1);
  end;

  SL := TStringList.Create;
  SL.LoadFromFile(FileName);
  HTML := SL.Text;
  SL.Free;

  Viewer := TViewer.Create;
  Viewer.Parser := THTMLParser.Create;
  Viewer.Parser.Parse(HTML);
  Viewer.Sheet := TCSSStyleSheet.Create;

  { Linked stylesheets. Remote URLs come from a local cache dir (prefetched;
    the HTTP client is part of the upcoming data layer) — cache key is the
    URL's file name. Relative hrefs load next to the HTML file. }
  for i := 0 to Viewer.Parser.LinkHrefs.Count - 1 do
  begin
    CSSFile := Viewer.Parser.LinkHrefs[i];
    if (Pos('http://', LowerCase(CSSFile)) = 1) or (Pos('https://', LowerCase(CSSFile)) = 1) then
    begin
      CSSFile := ExtractFilePath(ParamStr(0)) + 'csscache/' +
        ExtractFileName(StringReplace(CSSFile, '?', '_', [rfReplaceAll]));
      if not FileExists(CSSFile) then
      begin
        WriteLn('[css] not cached, skipping: ', Viewer.Parser.LinkHrefs[i]);
        Continue;
      end;
    end
    else if not FileExists(CSSFile) then
      CSSFile := ExtractFilePath(FileName) + CSSFile;
    if FileExists(CSSFile) then
    begin
      SL := TStringList.Create;
      SL.LoadFromFile(CSSFile);
      Viewer.Sheet.AddCSS(SL.Text);
      SL.Free;
      WriteLn('[css] loaded ', CSSFile);
    end;
  end;

  for i := 0 to Viewer.Parser.StyleBlocks.Count - 1 do
    Viewer.Sheet.AddCSS(Viewer.Parser.StyleBlocks[i]);

  WriteLn('Loaded ', FileName);
  Viewer.Shell := TCocoaShell.Create;
  Viewer.Shell.OnPaint := Viewer.Paint;
  Viewer.Shell.OnScroll := Viewer.Scroll;
  Viewer.Shell.OnMouseUp := Viewer.MouseUp;
  Viewer.Shell.SnapshotPath := SnapPath;
  Viewer.Shell.Initialize(1024, 800, 'Tina4 HTMLRender — Free Pascal');
  Viewer.Shell.Run;
end.
