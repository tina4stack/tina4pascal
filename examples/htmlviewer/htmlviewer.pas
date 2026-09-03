program htmlviewer;

{ Tina4 native-pascal HTML viewer — macOS shell.
  Usage: htmlviewer [file.html] [--snapshot out.png]
  HTML drives everything: no widget components. Form controls are drawn by
  the renderer; state lives in the DOM; interaction surfaces as semantic
  events (printed to stdout and mirrored in the window title). }

{$mode delphi}{$H+}

uses
  SysUtils, Classes, Math, Generics.Collections,
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
    HoverTag: THTMLTag;
    FocusTag: THTMLTag;
    ActiveTag: THTMLTag;
    OpenSelect: THTMLTag;         // dropdown currently expanded, nil = none
    HoverOpt: Integer;            // hovered option row in the open dropdown, -1 none
    Script: TStringList;          // --script: one driver command per tick
    ScriptPos: Integer;
    procedure Paint(Canvas: TTina4Canvas; W, H: Single);
    procedure Scroll(X, Y, DX, DY: Single);
    procedure MouseDown(X, Y: Single);
    procedure MouseUp(X, Y: Single);
    procedure MouseMove(X, Y: Single);
    procedure KeyDown(const Chars: string; KeyCode: Integer);
    procedure Tick;
    procedure Rebuild;
    procedure Event(const S: string);
    procedure SetFocus(T: THTMLTag);
    procedure SubmitForm(FromTag: THTMLTag);
    procedure CollectTags(T: THTMLTag; const TagNames: array of string; L: TList<THTMLTag>);
    function OptionAt(X, Y: Single; out OptText, OptValue: string): Boolean;
  end;

var
  Viewer: TViewer;
  ViewH: Single = 0;

{ UTF-8 stepping over byte indices (i is a byte offset, 0..Length(s)) }
function Utf8StepBack(const S: string; I: Integer): Integer;
begin
  Result := I;
  while (Result > 0) and ((Ord(S[Result]) and $C0) = $80) do Dec(Result);
  if Result > 0 then Dec(Result);
end;

function Utf8StepFwd(const S: string; I: Integer): Integer;
begin
  Result := I;
  if Result < Length(S) then
  begin
    Inc(Result);
    while (Result < Length(S)) and ((Ord(S[Result + 1]) and $C0) = $80) do
      Inc(Result);
  end;
end;

function CaretOf(T: THTMLTag; const V: string): Integer;
begin
  Result := StrToIntDef(T.GetAttribute('_caret'), Length(V));
  if Result > Length(V) then Result := Length(V);
  if Result < 0 then Result := 0;
end;

procedure SetChain(T: THTMLTag; Hover, Active: Boolean; Value: Boolean);
begin
  while T <> nil do
  begin
    if Hover then T.IsHovered := Value;
    if Active then T.IsActive := Value;
    T := T.Parent;
  end;
end;

procedure TViewer.Event(const S: string);
begin
  WriteLn('[event] ', S);
  Flush(Output);
  Shell.SetTitle('Tina4 — ' + S);
end;

{ Scripted driver: click X Y | key TEXT | enter|tab|backspace|esc |
  wheel X Y DY | snap PATH | quit — one command per tick. This is the seed
  of headless GUI automation: same events, no human. }
procedure TViewer.Tick;
var
  line, cmd, a, b, c: string;
  parts: TStringList;
begin
  if (Script = nil) or (ScriptPos >= Script.Count) then Exit;
  line := Trim(Script[ScriptPos]);
  Inc(ScriptPos);
  if (line = '') or (line[1] = '#') then Exit;
  parts := TStringList.Create;
  try
    parts.Delimiter := ' ';
    parts.StrictDelimiter := False;
    parts.DelimitedText := line;
    cmd := LowerCase(parts[0]);
    a := ''; b := ''; c := '';
    if parts.Count > 1 then a := parts[1];
    if parts.Count > 2 then b := parts[2];
    if parts.Count > 3 then c := parts[3];
    WriteLn('[script] ', line);
    Flush(Output);
    if cmd = 'click' then
    begin
      MouseDown(StrToFloatDef(a, 0), StrToFloatDef(b, 0));
      MouseUp(StrToFloatDef(a, 0), StrToFloatDef(b, 0));
    end
    else if cmd = 'key' then
      KeyDown(Copy(line, 5, MaxInt), TK_NONE)
    else if cmd = 'enter' then KeyDown('', TK_RETURN)
    else if cmd = 'tab' then KeyDown('', TK_TAB)
    else if cmd = 'backspace' then KeyDown('', TK_BACKSPACE)
    else if cmd = 'esc' then KeyDown('', TK_ESCAPE)
    else if cmd = 'wheel' then
      Scroll(StrToFloatDef(a, 0), StrToFloatDef(b, 0), 0, StrToFloatDef(c, 0))
    else if cmd = 'snap' then
    begin
      Shell.SnapshotPath := a;
      Shell.Invalidate;
    end
    else if cmd = 'quit' then
      Shell.Quit;
  finally
    parts.Free;
  end;
end;

procedure TViewer.Rebuild;
begin
  FreeAndNil(RootBox);
  Shell.Invalidate;
end;

procedure TViewer.CollectTags(T: THTMLTag; const TagNames: array of string; L: TList<THTMLTag>);
var
  c: THTMLTag;
  n: string;
begin
  for n in TagNames do
    if SameText(T.TagName, n) then
    begin
      L.Add(T);
      Break;
    end;
  for c in T.Children do
    CollectTags(c, TagNames, L);
end;

procedure TViewer.SetFocus(T: THTMLTag);
begin
  if FocusTag = T then Exit;
  if FocusTag <> nil then FocusTag.IsFocused := False;
  FocusTag := T;
  if FocusTag <> nil then FocusTag.IsFocused := True;
  Rebuild;
end;

procedure TViewer.SubmitForm(FromTag: THTMLTag);
var
  form, t: THTMLTag;
  fields: TList<THTMLTag>;
  parts, nm, v, typ: string;
begin
  form := FromTag;
  while (form <> nil) and not SameText(form.TagName, 'form') do
    form := form.Parent;
  fields := TList<THTMLTag>.Create;
  try
    if form <> nil then
      CollectTags(form, ['input', 'textarea', 'select'], fields)
    else
      CollectTags(Parser.Root, ['input', 'textarea', 'select'], fields);
    parts := '';
    for t in fields do
    begin
      nm := t.GetAttribute('name');
      if nm = '' then Continue;
      typ := LowerCase(t.GetAttribute('type'));
      if (typ = 'checkbox') or (typ = 'radio') then
      begin
        if not t.HasAttribute('checked') then Continue;
        v := t.GetAttribute('value', 'on');
      end
      else if typ = 'submit' then
        Continue
      else if SameText(t.TagName, 'textarea') then
        v := t.GetAttribute('value', InnerText(t))
      else
        v := t.GetAttribute('value');
      if parts <> '' then parts := parts + '&';
      parts := parts + nm + '=' + v;
    end;
    if form <> nil then
      nm := form.GetAttribute('name', '(form)')
    else
      nm := '(document)';
    Event('submit ' + nm + ': ' + parts);
  finally
    fields.Free;
  end;
end;

{ dropdown overlay geometry: options listed under the select's box }
function TViewer.OptionAt(X, Y: Single; out OptText, OptValue: string): Boolean;
var
  sb: TLayoutBox;
  oy, oh: Single;
  opt: THTMLTag;
begin
  Result := False;
  if (OpenSelect = nil) or (RootBox = nil) then Exit;
  sb := FindBoxForTag(RootBox, OpenSelect);
  if sb = nil then Exit;
  oh := 28;
  oy := sb.Y + sb.H - ScrollY;
  for opt in OpenSelect.Children do
  begin
    if not SameText(opt.TagName, 'option') then Continue;
    if (X >= sb.X) and (X <= sb.X + Max(sb.W, 160)) and (Y >= oy) and (Y < oy + oh) then
    begin
      OptText := InnerText(opt);
      OptValue := opt.GetAttribute('value', OptText);
      Exit(True);
    end;
    oy := oy + oh;
  end;
end;

function CountOptions(T: THTMLTag): Integer;
var opt: THTMLTag;
begin
  Result := 0;
  for opt in T.Children do
    if SameText(opt.TagName, 'option') then Inc(Result);
end;

procedure TViewer.Paint(Canvas: TTina4Canvas; W, H: Single);
var
  maxScroll, thumbH, thumbY, oy, oh, ow: Single;
  sb: TLayoutBox;
  opt: THTMLTag;
  txt, cur: string;
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

  // expanded dropdown paints last (top layer)
  if OpenSelect <> nil then
  begin
    sb := FindBoxForTag(RootBox, OpenSelect);
    if sb <> nil then
    begin
      oh := 28;
      ow := Max(sb.W, 160);
      oy := sb.Y + sb.H - ScrollY;
      cur := OpenSelect.GetAttribute('value');
      // drop shadow + panel
      Canvas.FillRect(sb.X + 2, oy + 2, ow, CountOptions(OpenSelect) * oh, $22000000);
      for opt in OpenSelect.Children do
      begin
        if not SameText(opt.TagName, 'option') then Continue;
        txt := InnerText(opt);
        if (opt.GetAttribute('value', txt) = cur) or (txt = cur) then
          Canvas.FillRect(sb.X, oy, ow, oh, $FF0D6EFD)   // selected row
        else if (HoverOpt >= 0) and (HoverOpt = Round((oy - (sb.Y + sb.H - ScrollY)) / oh)) then
          Canvas.FillRect(sb.X, oy, ow, oh, $FFEFF3FF)    // hovered row
        else
          Canvas.FillRect(sb.X, oy, ow, oh, $FFFFFFFF);
        Canvas.StrokeRect(sb.X, oy, ow, oh, 1, $FFD1D5DB);
        if (opt.GetAttribute('value', txt) = cur) or (txt = cur) then
          Canvas.DrawText(sb.X + 10, oy + 5, txt, 15, [], $FFFFFFFF)
        else
          Canvas.DrawText(sb.X + 10, oy + 5, txt, 15, [], $FF1F2937);
        oy := oy + oh;
      end;
    end;
  end;

  if RootBox.H > H then
  begin
    maxScroll := RootBox.H - H;
    thumbH := H * (H / RootBox.H);
    thumbY := (ScrollY / maxScroll) * (H - thumbH);
    Canvas.FillRect(W - 8, thumbY, 6, thumbH, $60000000);
  end;
end;

procedure TViewer.Scroll(X, Y, DX, DY: Single);
var
  maxScroll: Single;
  sb: TLayoutBox;
begin
  if RootBox = nil then Exit;
  // inner scroller under the cursor wins
  sb := FindScrollBox(RootBox, X, Y + ScrollY);
  if sb <> nil then
  begin
    if sb.Scrollable and (sb.MaxScroll > 0) then
      sb.ScrollTop := Max(0, Min(sb.MaxScroll, sb.ScrollTop - DY));
    if sb.ScrollableX and (sb.MaxScrollX > 0) then
      // horizontal wheel delta, or vertical delta when there's no vertical scroll
      if DX <> 0 then
        sb.ScrollLeft := Max(0, Min(sb.MaxScrollX, sb.ScrollLeft - DX))
      else if not (sb.Scrollable and (sb.MaxScroll > 0)) then
        sb.ScrollLeft := Max(0, Min(sb.MaxScrollX, sb.ScrollLeft - DY));
    Shell.Invalidate;
    Exit;
  end;
  maxScroll := Max(0, RootBox.H - ViewH);
  ScrollY := Max(0, Min(maxScroll, ScrollY - DY));
  Shell.Invalidate;
end;

procedure TViewer.MouseMove(X, Y: Single);
var
  hit: THTMLTag;
  sb: TLayoutBox;
  ho: Integer;
begin
  if RootBox = nil then Exit;
  // hovered option while a dropdown is open
  if OpenSelect <> nil then
  begin
    sb := FindBoxForTag(RootBox, OpenSelect);
    if sb <> nil then
    begin
      ho := -1;
      if (X >= sb.X) and (X <= sb.X + Max(sb.W, 160)) then
        ho := Trunc((Y - (sb.Y + sb.H - ScrollY)) / 28);
      if (ho < 0) or (ho >= CountOptions(OpenSelect)) then ho := -1;
      if ho <> HoverOpt then begin HoverOpt := ho; Shell.Invalidate; end;
    end;
    Exit;
  end;
  hit := HitTest(RootBox, X, Y + ScrollY);
  if hit = HoverTag then Exit;
  SetChain(HoverTag, True, False, False);
  HoverTag := hit;
  SetChain(HoverTag, True, False, True);
  if Sheet.HasInteractiveSelectors and (Engine <> nil) then
  begin // style-only pass: no relayout, no flicker
    Engine.RefreshStyles(RootBox);
    Shell.Invalidate;
  end;
end;

procedure TViewer.MouseDown(X, Y: Single);
var
  hit: THTMLTag;
begin
  if RootBox = nil then Exit;
  hit := HitTest(RootBox, X, Y + ScrollY);
  SetChain(ActiveTag, False, True, False);
  ActiveTag := hit;
  SetChain(ActiveTag, False, True, True);
  if Sheet.HasInteractiveSelectors and (Engine <> nil) then
  begin
    Engine.RefreshStyles(RootBox);
    Shell.Invalidate;
  end;
end;

procedure TViewer.MouseUp(X, Y: Single);
var
  hit, t, g: THTMLTag;
  typ, ot, ov, v: string;
  radios: TList<THTMLTag>;
  cb: TLayoutBox;
  tx, mw: Single;
  ci, ni: Integer;
begin
  if RootBox = nil then Exit;
  SetChain(ActiveTag, False, True, False);
  ActiveTag := nil;

  // an open dropdown eats the click first
  if OpenSelect <> nil then
  begin
    if OptionAt(X, Y, ot, ov) then
    begin
      OpenSelect.Attributes.AddOrSetValue('value', ov);
      Event('change ' + OpenSelect.GetAttribute('name', 'select') + '=' + ov);
    end;
    OpenSelect := nil;
    Rebuild;
    Exit;
  end;

  hit := HitTest(RootBox, X, Y + ScrollY);

  // form controls first
  t := hit;
  while (t <> nil) and not IsFormControlTag(t.TagName) do t := t.Parent;
  if t <> nil then
  begin
    typ := LowerCase(t.GetAttribute('type', 'text'));
    if SameText(t.TagName, 'select') then
    begin
      SetFocus(t);
      OpenSelect := t;
      Rebuild;
      Exit;
    end;
    if typ = 'checkbox' then
    begin
      if t.HasAttribute('checked') then t.Attributes.Remove('checked')
      else t.Attributes.AddOrSetValue('checked', 'checked');
      Event('change ' + t.GetAttribute('name', 'checkbox') + '=' +
        BoolToStr(t.HasAttribute('checked'), 'on', 'off'));
      Rebuild;
      Exit;
    end;
    if typ = 'radio' then
    begin
      radios := TList<THTMLTag>.Create;
      try
        CollectTags(Parser.Root, ['input'], radios);
        for g in radios do
          if SameText(g.GetAttribute('type'), 'radio') and
             SameText(g.GetAttribute('name'), t.GetAttribute('name')) then
            g.Attributes.Remove('checked');
      finally
        radios.Free;
      end;
      t.Attributes.AddOrSetValue('checked', 'checked');
      Event('change ' + t.GetAttribute('name', 'radio') + '=' + t.GetAttribute('value', 'on'));
      Rebuild;
      Exit;
    end;
    if (typ = 'submit') or (SameText(t.TagName, 'button') and
       SameText(t.GetAttribute('type', 'submit'), 'submit')) then
    begin
      SubmitForm(t);
      Exit;
    end;
    if SameText(t.TagName, 'input') or SameText(t.TagName, 'textarea') then
    begin
      SetFocus(t);
      // click-to-position the caret (single-line inputs)
      if SameText(t.TagName, 'input') then
      begin
        cb := FindBoxForTag(RootBox, t);
        if cb <> nil then
        begin
          v := t.GetAttribute('value');
          tx := cb.X + cb.Style.BorderWidths.Left + cb.Style.Padding.Left;
          ci := 0;
          while ci < Length(v) do
          begin
            ni := Utf8StepFwd(v, ci);
            mw := Shell.GetMeasuringCanvas.MeasureText(Copy(v, 1, ni),
              cb.Style.FontSize, []).Width;
            if tx + mw - (mw - Shell.GetMeasuringCanvas.MeasureText(Copy(v, 1, ci),
              cb.Style.FontSize, []).Width) / 2 > X then Break;
            ci := ni;
          end;
          t.Attributes.AddOrSetValue('_caret', IntToStr(ci));
          Rebuild;
        end;
      end;
      Exit;
    end;
  end
  else if FocusTag <> nil then
    SetFocus(nil); // clicked empty space: blur

  // semantic events: onclick handlers and links, walking up the tree
  t := hit;
  while t <> nil do
  begin
    if t.HasAttribute('onclick') then
    begin
      Event('onclick -> ' + t.GetAttribute('onclick'));
      Exit;
    end;
    if SameText(t.TagName, 'a') and t.HasAttribute('href') then
    begin
      Event('link -> ' + t.GetAttribute('href'));
      Exit;
    end;
    t := t.Parent;
  end;
end;

procedure TViewer.KeyDown(const Chars: string; KeyCode: Integer);
var
  v: string;
  focusables: TList<THTMLTag>;
  i, idx, caret, np: Integer;
  isArea: Boolean;
begin
  if FocusTag = nil then Exit;
  isArea := SameText(FocusTag.TagName, 'textarea');
  if isArea then
    v := FocusTag.GetAttribute('value', InnerText(FocusTag))
  else
    v := FocusTag.GetAttribute('value');

  caret := CaretOf(FocusTag, v);
  case KeyCode of
    TK_BACKSPACE:
      if (v <> '') and (caret > 0) then
      begin
        np := Utf8StepBack(v, caret);
        Delete(v, np + 1, caret - np);
        FocusTag.Attributes.AddOrSetValue('value', v);
        FocusTag.Attributes.AddOrSetValue('_caret', IntToStr(np));
        Rebuild;
      end;
    TK_DELETE:
      if caret < Length(v) then
      begin
        np := Utf8StepFwd(v, caret);
        Delete(v, caret + 1, np - caret);
        FocusTag.Attributes.AddOrSetValue('value', v);
        Rebuild;
      end;
    TK_LEFT:
      begin
        FocusTag.Attributes.AddOrSetValue('_caret', IntToStr(Utf8StepBack(v, caret)));
        Rebuild;
      end;
    TK_RIGHT:
      begin
        FocusTag.Attributes.AddOrSetValue('_caret', IntToStr(Utf8StepFwd(v, caret)));
        Rebuild;
      end;
    TK_UP:
      begin
        FocusTag.Attributes.AddOrSetValue('_caret', '0'); // home
        Rebuild;
      end;
    TK_DOWN:
      begin
        FocusTag.Attributes.AddOrSetValue('_caret', IntToStr(Length(v))); // end
        Rebuild;
      end;
    TK_RETURN:
      if isArea then
      begin
        FocusTag.Attributes.AddOrSetValue('value', v + sLineBreak);
        Rebuild;
      end
      else
        SubmitForm(FocusTag);
    TK_TAB:
      begin
        focusables := TList<THTMLTag>.Create;
        try
          CollectTags(Parser.Root, ['input', 'textarea', 'select'], focusables);
          for i := focusables.Count - 1 downto 0 do
            if SameText(focusables[i].GetAttribute('type'), 'checkbox') or
               SameText(focusables[i].GetAttribute('type'), 'radio') or
               SameText(focusables[i].GetAttribute('type'), 'submit') then
              focusables.Delete(i);
          idx := focusables.IndexOf(FocusTag);
          if focusables.Count > 0 then
            SetFocus(focusables[(idx + 1) mod focusables.Count]);
        finally
          focusables.Free;
        end;
      end;
    TK_ESCAPE:
      begin
        OpenSelect := nil;
        SetFocus(nil);
      end;
  else
    if Chars <> '' then
    begin
      Insert(Chars, v, caret + 1);
      FocusTag.Attributes.AddOrSetValue('value', v);
      FocusTag.Attributes.AddOrSetValue('_caret', IntToStr(caret + Length(Chars)));
      Rebuild;
    end;
  end;
end;

var
  FileName, SnapPath, HTML, CSSFile, ScriptPath: string;
  SL: TStringList;
  i: Integer;
  autof: TList<THTMLTag>;
begin
  FileName := ExpandFileName(ExtractFilePath(ParamStr(0)) + 'bootstrap_test.html');
  SnapPath := '';
  i := 1;
  ScriptPath := '';
  while i <= ParamCount do
  begin
    if ParamStr(i) = '--snapshot' then
    begin
      Inc(i);
      SnapPath := ParamStr(i);
    end
    else if ParamStr(i) = '--script' then
    begin
      Inc(i);
      ScriptPath := ParamStr(i);
    end
    else
      FileName := ExpandFileName(ParamStr(i));
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

  { Linked stylesheets: remote URLs from the local cache dir (prefetched),
    relative hrefs from beside the HTML file. }
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
  Viewer.Shell.OnMouseDown := Viewer.MouseDown;
  Viewer.Shell.OnMouseUp := Viewer.MouseUp;
  Viewer.Shell.OnMouseMove := Viewer.MouseMove;
  Viewer.Shell.OnKeyDown := Viewer.KeyDown;
  Viewer.Shell.SnapshotPath := SnapPath;

  // autofocus: first control asking for it
  autof := TList<THTMLTag>.Create;
  try
    Viewer.CollectTags(Viewer.Parser.Root, ['input', 'textarea', 'select'], autof);
    for i := 0 to autof.Count - 1 do
      if autof[i].HasAttribute('autofocus') then
      begin
        autof[i].IsFocused := True;
        Viewer.FocusTag := autof[i];
        Break;
      end;
  finally
    autof.Free;
  end;

  if ScriptPath <> '' then
  begin
    Viewer.Script := TStringList.Create;
    Viewer.Script.LoadFromFile(ScriptPath);
    Viewer.ScriptPos := 0;
    Viewer.Shell.OnTick := Viewer.Tick;
  end;

  Viewer.Shell.Initialize(1024, 800, 'Tina4 HTMLRender — Free Pascal');
  if ScriptPath <> '' then Viewer.Shell.StartTicker(400);
  Viewer.Shell.Run;
end.
