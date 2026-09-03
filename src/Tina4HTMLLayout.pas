unit Tina4HTMLLayout;

{ Minimal block/inline/table layout engine over Tina4HTMLDom, painting
  through the TTina4Canvas contract only (see ARCHITECTURE.md).
  Scope: enough to render Example/bootstrap_test.html — block stacking,
  margins/padding/borders, inline text flow with wrapping, inline-blocks
  (.btn, styled spans), tables, image placeholders. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, Math, Generics.Collections,
  Tina4HTMLDom, Tina4RenderBackend;

type
  TTextRun = record
    Text: string;
    X, Y: Single; // absolute document coords, top-left of text
    FontSize: Single;
    Styles: TTina4FontStyles;
    Color: TTina4Color;
  end;

  TLayoutBox = class
  public
    Tag: THTMLTag;                 // may be nil for anonymous boxes
    Style: TComputedStyle;
    X, Y, W, H: Single;            // border box, absolute document coords
    Children: TObjectList<TLayoutBox>;
    Runs: TList<TTextRun>;
    IsImagePlaceholder: Boolean;
    ImageHandle: Integer;          // canvas image handle, -1 = none/failed
    constructor Create;
    destructor Destroy; override;
  end;

  TLayoutEngine = class
  private
    FCanvas: TTina4Canvas;
    FSheet: TCSSStyleSheet;
    function FontStylesOf(const St: TComputedStyle): TTina4FontStyles;
    function LineHeightOf(const St: TComputedStyle): Single;
    procedure LayoutChildren(Box: TLayoutBox; Tag: THTMLTag;
      const ParentStyle: TComputedStyle; CX, CY, CW: Single; out UsedH: Single);
    function LayoutBlock(Parent: TLayoutBox; Tag: THTMLTag;
      const ParentStyle: TComputedStyle; X, Y, AvailW: Single): Single;
    function LayoutTable(Parent: TLayoutBox; Tag: THTMLTag;
      const Style: TComputedStyle; X, Y, AvailW: Single): Single;
    function MakeInlineBlock(Tag: THTMLTag; const St: TComputedStyle): TLayoutBox;
    procedure CollectInlineText(Tag: THTMLTag; SB: TStringBuilder);
  public
    constructor Create(Canvas: TTina4Canvas; Sheet: TCSSStyleSheet);
    function Build(Root: THTMLTag; ViewportW: Single): TLayoutBox;
  end;

procedure PaintBox(Canvas: TTina4Canvas; Box: TLayoutBox; OffsetY: Single);
function HitTest(Box: TLayoutBox; X, Y: Single): THTMLTag;

implementation

const
  IMG_PLACEHOLDER_BG: TTina4Color = $FFE9ECEF;
  IMG_PLACEHOLDER_FG: TTina4Color = $FF6C757D;

{ TLayoutBox }

constructor TLayoutBox.Create;
begin
  Children := TObjectList<TLayoutBox>.Create(True);
  Runs := TList<TTextRun>.Create;
  ImageHandle := -1;
end;

destructor TLayoutBox.Destroy;
begin
  Children.Free;
  Runs.Free;
  inherited;
end;

{ helpers }

function IsTextNode(Tag: THTMLTag): Boolean;
begin
  Result := Tag.TagName = '#text';
end;

function DisplayOf(Tag: THTMLTag; const St: TComputedStyle): string;
begin
  if IsTextNode(Tag) then Exit('inline');
  Result := LowerCase(St.Display);
  if Result = '' then Result := 'block';
end;

{ Resolve an ExplicitWidth/Height value against the containing size.
  >=0 absolute px; -1 auto; <-1.5 percentage marker (-50 = 50%); -3 fit-content. }
function ResolveSize(V, Avail: Single): Single;
begin
  if V >= 0 then Result := V
  else if (V < -1.5) and (V > -1000) and (V <> -3) then Result := Avail * (-V) / 100
  else Result := -1; // auto
end;

function CollapseWS(const S: string): string;
var
  i: Integer;
  prevSpace: Boolean;
  ch: Char;
  sb: TStringBuilder;
begin
  sb := TStringBuilder.Create;
  try
    prevSpace := False;
    for i := 1 to Length(S) do
    begin
      ch := S[i];
      if ch in [' ', #9, #10, #13] then
      begin
        if not prevSpace then sb.Append(' ');
        prevSpace := True;
      end
      else
      begin
        sb.Append(ch);
        prevSpace := False;
      end;
    end;
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

{ TLayoutEngine }

constructor TLayoutEngine.Create(Canvas: TTina4Canvas; Sheet: TCSSStyleSheet);
begin
  FCanvas := Canvas;
  FSheet := Sheet;
end;

function TLayoutEngine.FontStylesOf(const St: TComputedStyle): TTina4FontStyles;
begin
  Result := [];
  if St.Bold then Include(Result, tfsBold);
  if St.Italic then Include(Result, tfsItalic);
  if Pos('underline', LowerCase(St.TextDecoration)) > 0 then Include(Result, tfsUnderline);
end;

function TLayoutEngine.LineHeightOf(const St: TComputedStyle): Single;
begin
  if St.LineHeight > 4 then       // absolute px
    Result := St.LineHeight
  else if St.LineHeight > 0 then  // multiplier
    Result := St.FontSize * St.LineHeight
  else
    Result := St.FontSize * 1.4;
end;

procedure TLayoutEngine.CollectInlineText(Tag: THTMLTag; SB: TStringBuilder);
var
  c: THTMLTag;
begin
  if IsTextNode(Tag) then
    SB.Append(Tag.Text)
  else
    for c in Tag.Children do
      CollectInlineText(c, SB);
end;

{ Atomic inline-block: measure single-line content, apply padding/border. }
function TLayoutEngine.MakeInlineBlock(Tag: THTMLTag; const St: TComputedStyle): TLayoutBox;
var
  sb: TStringBuilder;
  txt: string;
  m: TTina4TextMetrics;
  run: TTextRun;
  padH, padV: Single;
begin
  Result := TLayoutBox.Create;
  Result.Tag := Tag;
  Result.Style := St;
  sb := TStringBuilder.Create;
  try
    CollectInlineText(Tag, sb);
    txt := Trim(CollapseWS(sb.ToString));
  finally
    sb.Free;
  end;
  m := FCanvas.MeasureText(txt, St.FontSize, FontStylesOf(St));
  padH := St.Padding.Horz + St.BorderWidths.Horz;
  padV := St.Padding.Vert + St.BorderWidths.Vert;
  if ResolveSize(St.ExplicitWidth, 0) >= 0 then
    Result.W := St.ExplicitWidth + padH
  else
    Result.W := m.Width + padH;
  if ResolveSize(St.ExplicitHeight, 0) >= 0 then
    Result.H := St.ExplicitHeight + padV
  else
    Result.H := LineHeightOf(St) + padV;
  if txt <> '' then
  begin
    run.Text := txt;
    run.X := St.BorderWidths.Left + St.Padding.Left; // relative for now
    run.Y := St.BorderWidths.Top + St.Padding.Top;
    run.FontSize := St.FontSize;
    run.Styles := FontStylesOf(St);
    run.Color := St.Color;
    Result.Runs.Add(run);
  end;
end;

type
  TInlineItem = record
    Text: string;          // '' for atomic boxes
    Box: TLayoutBox;       // nil for words
    W, H: Single;
    FontSize: Single;
    Styles: TTina4FontStyles;
    Color: TTina4Color;
    SpaceBefore: Boolean;
  end;

{ Lay out the mixed inline/block children of Tag into Box.
  CX,CY = content origin (absolute), CW = content width. }
procedure TLayoutEngine.LayoutChildren(Box: TLayoutBox; Tag: THTMLTag;
  const ParentStyle: TComputedStyle; CX, CY, CW: Single; out UsedH: Single);
var
  y: Single;
  items: TList<TInlineItem>;

  procedure GatherInline(T: THTMLTag; const St: TComputedStyle);
  var
    c: THTMLTag;
    cs: TComputedStyle;
    words: TStringList;
    i: Integer;
    it: TInlineItem;
    m: TTina4TextMetrics;
    disp, txt: string;
    leadingSpace: Boolean;
    iw, ih: Single;
  begin
    if IsTextNode(T) then
    begin
      txt := CollapseWS(T.Text);
      if Trim(txt) = '' then Exit;
      leadingSpace := (txt <> '') and (txt[1] = ' ');
      words := TStringList.Create;
      try
        words.Delimiter := ' ';
        words.StrictDelimiter := True;
        words.DelimitedText := Trim(txt);
        for i := 0 to words.Count - 1 do
        begin
          if words[i] = '' then Continue;
          m := FCanvas.MeasureText(words[i], St.FontSize, FontStylesOf(St));
          it.Text := words[i];
          it.Box := nil;
          it.W := m.Width;
          it.H := LineHeightOf(St);
          it.FontSize := St.FontSize;
          it.Styles := FontStylesOf(St);
          it.Color := St.Color;
          it.SpaceBefore := (items.Count > 0) and ((i > 0) or leadingSpace);
          items.Add(it);
        end;
      finally
        words.Free;
      end;
      Exit;
    end;
    cs := TComputedStyle.ForTag(T, St, FSheet);
    if LowerCase(cs.Display) = 'none' then Exit;
    if cs.Margin.Left > 0 then
    begin // inline margin-left becomes a spacer in the flow
      it.Text := ''; it.Box := nil;
      it.W := cs.Margin.Left; it.H := 0;
      it.FontSize := cs.FontSize; it.Styles := []; it.Color := 0;
      it.SpaceBefore := False;
      items.Add(it);
    end;
    if SameText(T.TagName, 'img') then
    begin
      it.Text := '';
      it.Box := TLayoutBox.Create;
      it.Box.Tag := T;
      it.Box.Style := cs;
      it.Box.IsImagePlaceholder := True;
      it.Box.ImageHandle := FCanvas.LoadImage(T.GetAttribute('src'));
      if cs.ExplicitWidth >= 0 then it.Box.W := cs.ExplicitWidth else it.Box.W := 120;
      if cs.ExplicitHeight >= 0 then it.Box.H := cs.ExplicitHeight else it.Box.H := 80;
      // no width/height attributes: fall back to the image's intrinsic size
      if ((cs.ExplicitWidth < 0) or (cs.ExplicitHeight < 0)) and
         FCanvas.ImageSize(it.Box.ImageHandle, iw, ih) and (iw > 0) and (ih > 0) then
      begin
        if (cs.ExplicitWidth < 0) and (cs.ExplicitHeight < 0) then
        begin
          it.Box.W := iw; it.Box.H := ih;
        end
        else if cs.ExplicitWidth < 0 then
          it.Box.W := iw * (it.Box.H / ih)   // keep aspect from given height
        else
          it.Box.H := ih * (it.Box.W / iw);  // keep aspect from given width
      end;
      if it.Box.W > CW then
      begin // scale down to fit
        it.Box.H := it.Box.H * (CW / it.Box.W);
        it.Box.W := CW;
      end;
      it.W := it.Box.W; it.H := it.Box.H;
      it.SpaceBefore := False;
      Box.Children.Add(it.Box);
      items.Add(it);
      Exit;
    end;
    { An inline element with visible box styling (background, border,
      padding) is treated as an atomic inline-block so its box paints —
      covers Bootstrap badges and styled <span>s. }
    if (LowerCase(cs.Display) = 'inline-block') or SameText(T.TagName, 'button')
      or ((cs.BackgroundColor shr 24 > 0) or cs.Padding.Any or (cs.BorderWidths.Top > 0)) then
    begin
      it.Text := '';
      it.Box := MakeInlineBlock(T, cs);
      it.W := it.Box.W; it.H := it.Box.H;
      it.SpaceBefore := items.Count > 0;
      Box.Children.Add(it.Box);
      items.Add(it);
      Exit;
    end;
    // plain inline (b, i, span, a, small...) — recurse with its style
    for c in T.Children do
      GatherInline(c, cs);
  end;

  procedure FlushLine(startIdx: Integer; var lineItems: TList<Integer>;
    lineTop, lineH: Single);
  var
    idx, k: Integer;
    lineW, xShift, x: Single;
    it: TInlineItem;
    run: TTextRun;
    r: TTextRun;
    j: Integer;
  begin
    if lineItems.Count = 0 then Exit;
    // width used
    lineW := 0;
    for k := 0 to lineItems.Count - 1 do
    begin
      it := items[lineItems[k]];
      if it.SpaceBefore and (k > 0) then
        lineW := lineW + FCanvas.MeasureText(' ', it.FontSize, it.Styles).Width;
      lineW := lineW + it.W;
    end;
    case ParentStyle.TextAlign of
      TTextAlign.Center:   xShift := Max(0, (CW - lineW) / 2);
      TTextAlign.Trailing: xShift := Max(0, CW - lineW);
    else
      xShift := 0;
    end;
    x := CX + xShift;
    for k := 0 to lineItems.Count - 1 do
    begin
      it := items[lineItems[k]];
      if it.SpaceBefore and (k > 0) then
        x := x + FCanvas.MeasureText(' ', it.FontSize, it.Styles).Width;
      if it.Box <> nil then
      begin
        it.Box.X := x;
        it.Box.Y := lineTop + (lineH - it.H); // bottom-align atoms
        // shift its relative runs to absolute
        for j := 0 to it.Box.Runs.Count - 1 do
        begin
          r := it.Box.Runs[j];
          r.X := r.X + it.Box.X;
          r.Y := r.Y + it.Box.Y;
          it.Box.Runs[j] := r;
        end;
      end
      else
      begin
        run.Text := it.Text;
        run.X := x;
        run.Y := lineTop + (lineH - it.H) + (it.H - it.FontSize * 1.2) / 2;
        run.FontSize := it.FontSize;
        run.Styles := it.Styles;
        run.Color := it.Color;
        Box.Runs.Add(run);
      end;
      x := x + it.W;
    end;
    lineItems.Clear;
  end;

  procedure FlowInlineItems;
  var
    i: Integer;
    it: TInlineItem;
    curW, lineH, spaceW: Single;
    lineItems: TList<Integer>;
  begin
    if items.Count = 0 then Exit;
    lineItems := TList<Integer>.Create;
    try
      curW := 0; lineH := 0;
      for i := 0 to items.Count - 1 do
      begin
        it := items[i];
        spaceW := 0;
        if it.SpaceBefore and (lineItems.Count > 0) then
          spaceW := FCanvas.MeasureText(' ', it.FontSize, it.Styles).Width;
        if (lineItems.Count > 0) and (curW + spaceW + it.W > CW) then
        begin
          FlushLine(i, lineItems, y, lineH);
          y := y + lineH;
          curW := 0; lineH := 0;
          spaceW := 0;
        end;
        lineItems.Add(i);
        curW := curW + spaceW + it.W;
        lineH := Max(lineH, it.H);
      end;
      FlushLine(items.Count, lineItems, y, lineH);
      y := y + lineH;
    finally
      lineItems.Free;
    end;
    items.Clear;
  end;

var
  c: THTMLTag;
  cs: TComputedStyle;
  disp: string;
  prevMB, mTc: Single;
  hadInline: Boolean;
begin
  y := CY;
  prevMB := 0;
  hadInline := False;
  items := TList<TInlineItem>.Create;
  try
    for c in Tag.Children do
    begin
      if IsTextNode(c) then
      begin
        GatherInline(c, ParentStyle);
        hadInline := True;
        Continue;
      end;
      cs := TComputedStyle.ForTag(c, ParentStyle, FSheet);
      disp := DisplayOf(c, cs);
      if disp = 'none' then Continue;
      if (disp = 'inline') or (disp = 'inline-block') or SameText(c.TagName, 'img')
        or SameText(c.TagName, 'button') then
      begin
        GatherInline(c, ParentStyle);
        hadInline := True;
      end
      else
      begin
        FlowInlineItems; // finish pending inline line(s)
        if hadInline then begin prevMB := 0; hadInline := False; end;
        // collapse adjacent vertical margins: gap = max(prevBottom, thisTop)
        mTc := cs.Margin.Top; if mTc = -1 then mTc := 0;
        if (prevMB > 0) and (mTc > 0) then
          y := y - Min(prevMB, mTc);
        if SameText(c.TagName, 'table') then
          y := y + LayoutTable(Box, c, cs, CX, y, CW)
        else
          y := y + LayoutBlock(Box, c, ParentStyle, CX, y, CW);
        prevMB := cs.Margin.Bottom; if prevMB = -1 then prevMB := 0;
      end;
    end;
    FlowInlineItems;
  finally
    items.Free;
  end;
  UsedH := y - CY;
end;

function TLayoutEngine.LayoutBlock(Parent: TLayoutBox; Tag: THTMLTag;
  const ParentStyle: TComputedStyle; X, Y, AvailW: Single): Single;
var
  st: TComputedStyle;
  box: TLayoutBox;
  contentX, contentY, contentW, usedH: Single;
  edgeL, edgeT, edgeR, edgeB: Single;
  mL, mR, mT, mB, ew, eh, availInner: Single;
  autoL, autoR: Boolean;
begin
  st := TComputedStyle.ForTag(Tag, ParentStyle, FSheet);
  if LowerCase(st.Display) = 'none' then Exit(0);

  box := TLayoutBox.Create;
  box.Tag := Tag;
  box.Style := st;
  Parent.Children.Add(box);

  // margins: -1 is the 'auto' marker from ParseLength; real negatives pass through
  mL := st.Margin.Left;  autoL := mL = -1; if autoL then mL := 0;
  mR := st.Margin.Right; autoR := mR = -1; if autoR then mR := 0;
  mT := st.Margin.Top;    if mT = -1 then mT := 0;
  mB := st.Margin.Bottom; if mB = -1 then mB := 0;

  availInner := AvailW - mL - mR;
  box.X := X + mL;
  box.Y := Y + mT;
  box.W := availInner;
  ew := ResolveSize(st.ExplicitWidth, availInner);
  if ew >= 0 then
  begin
    if SameText(st.BoxSizing, 'border-box') then
      box.W := Min(ew, availInner)
    else
      box.W := Min(ew + st.Padding.Horz + st.BorderWidths.Horz, availInner);
    if autoL and autoR then
      box.X := X + mL + Max(0, (availInner - box.W) / 2); // margin:0 auto centering
  end;

  edgeL := st.BorderWidths.Left + st.Padding.Left;
  edgeT := st.BorderWidths.Top + st.Padding.Top;
  edgeR := st.BorderWidths.Right + st.Padding.Right;
  edgeB := st.BorderWidths.Bottom + st.Padding.Bottom;
  contentX := box.X + edgeL;
  contentY := box.Y + edgeT;
  contentW := box.W - edgeL - edgeR;

  LayoutChildren(box, Tag, st, contentX, contentY, contentW, usedH);
  eh := ResolveSize(st.ExplicitHeight, 0);
  if eh >= 0 then
  begin
    if SameText(st.BoxSizing, 'border-box') then
      usedH := Max(0, eh - edgeT - edgeB)
    else
      usedH := eh;
  end;
  box.H := usedH + edgeT + edgeB;

  Result := box.H + mT + mB;
end;

function TLayoutEngine.LayoutTable(Parent: TLayoutBox; Tag: THTMLTag;
  const Style: TComputedStyle; X, Y, AvailW: Single): Single;
var
  rows: TList<THTMLTag>;
  prefW: array of Single;
  ncols, i, ci: Integer;
  r, cell: THTMLTag;
  tbox, rbox, cbox: TLayoutBox;
  cs, rs: TComputedStyle;
  sb: TStringBuilder;
  m: TTina4TextMetrics;
  total, scale, cx, rowY, rowH, usedH, cw, tableW: Single;
  hasBorder: Boolean;

  procedure CollectRows(T: THTMLTag);
  var c: THTMLTag;
  begin
    for c in T.Children do
      if SameText(c.TagName, 'tr') then rows.Add(c)
      else if SameText(c.TagName, 'thead') or SameText(c.TagName, 'tbody') or
              SameText(c.TagName, 'tfoot') then CollectRows(c);
  end;

begin
  rows := TList<THTMLTag>.Create;
  try
    CollectRows(Tag);
    if rows.Count = 0 then Exit(0);
    ncols := 0;
    for r in rows do
    begin
      i := 0;
      for cell in r.Children do
        if SameText(cell.TagName, 'td') or SameText(cell.TagName, 'th') then Inc(i);
      ncols := Max(ncols, i);
    end;
    if ncols = 0 then Exit(0);

    hasBorder := Tag.HasAttribute('border');
    tableW := AvailW - Style.Margin.Horz;
    if Style.ExplicitWidth >= 0 then tableW := Min(Style.ExplicitWidth, tableW);

    tbox := TLayoutBox.Create;
    tbox.Tag := Tag;
    tbox.Style := Style;
    Parent.Children.Add(tbox);
    tbox.X := X + Style.Margin.Left;
    tbox.Y := Y + Style.Margin.Top;
    tbox.W := tableW;

    // preferred column widths (single-line measurement)
    SetLength(prefW, ncols);
    for i := 0 to ncols - 1 do prefW[i] := 30;
    for r in rows do
    begin
      ci := 0;
      for cell in r.Children do
      begin
        if not (SameText(cell.TagName, 'td') or SameText(cell.TagName, 'th')) then Continue;
        cs := TComputedStyle.ForTag(cell, Style, FSheet);
        sb := TStringBuilder.Create;
        try
          CollectInlineText(cell, sb);
          m := FCanvas.MeasureText(Trim(CollapseWS(sb.ToString)), cs.FontSize, FontStylesOf(cs));
        finally
          sb.Free;
        end;
        cw := m.Width + cs.Padding.Horz + 8;
        if cell.HasAttribute('width') then
          cw := Max(cw, TComputedStyle.ParseLength(cell.GetAttribute('width'), cs.FontSize));
        // images in cells
        if cs.ExplicitWidth > 0 then cw := Max(cw, cs.ExplicitWidth);
        if ci < ncols then prefW[ci] := Max(prefW[ci], cw);
        Inc(ci);
      end;
    end;
    total := 0;
    for i := 0 to ncols - 1 do total := total + prefW[i];
    scale := tableW / total;
    for i := 0 to ncols - 1 do prefW[i] := prefW[i] * scale;

    rowY := tbox.Y;
    for r in rows do
    begin
      rs := TComputedStyle.ForTag(r, Style, FSheet);
      rbox := TLayoutBox.Create;
      rbox.Tag := r;
      rbox.Style := rs;
      tbox.Children.Add(rbox);
      rbox.X := tbox.X; rbox.Y := rowY; rbox.W := tableW;
      cx := tbox.X;
      rowH := 0;
      ci := 0;
      for cell in r.Children do
      begin
        if not (SameText(cell.TagName, 'td') or SameText(cell.TagName, 'th')) then Continue;
        cs := TComputedStyle.ForTag(cell, rs, FSheet);
        if hasBorder and (cs.BorderWidths.Top <= 0) then
        begin
          cs.SetBorderWidth(1);
          cs.SetBorderColor(Style.BorderColor);
        end;
        cbox := TLayoutBox.Create;
        cbox.Tag := cell;
        cbox.Style := cs;
        rbox.Children.Add(cbox);
        cbox.X := cx; cbox.Y := rowY; cbox.W := prefW[ci];
        LayoutChildren(cbox, cell, cs,
          cx + cs.BorderWidths.Left + cs.Padding.Left,
          rowY + cs.BorderWidths.Top + cs.Padding.Top,
          prefW[ci] - cs.Padding.Horz - cs.BorderWidths.Horz, usedH);
        cbox.H := usedH + cs.Padding.Vert + cs.BorderWidths.Vert;
        rowH := Max(rowH, cbox.H);
        cx := cx + prefW[ci];
        Inc(ci);
      end;
      for i := 0 to rbox.Children.Count - 1 do
        rbox.Children[i].H := rowH; // uniform row height
      rbox.H := rowH;
      rowY := rowY + rowH;
    end;
    tbox.H := rowY - tbox.Y;
    Result := tbox.H + Style.Margin.Vert;
  finally
    rows.Free;
  end;
end;

function TLayoutEngine.Build(Root: THTMLTag; ViewportW: Single): TLayoutBox;
var
  base: TComputedStyle;
  usedH: Single;
  body: THTMLTag;

  function FindBody(T: THTMLTag): THTMLTag;
  var c, r: THTMLTag;
  begin
    if SameText(T.TagName, 'body') then Exit(T);
    for c in T.Children do
    begin
      r := FindBody(c);
      if r <> nil then Exit(r);
    end;
    Result := nil;
  end;

begin
  base := TComputedStyle.Default;
  base.FontFamily := 'Helvetica';
  base.FontSize := 16;       // web default; Delphi default is 14
  base.LineHeight := 1.5;    // bootstrap body line-height
  body := FindBody(Root);
  if body = nil then body := Root;
  Result := TLayoutBox.Create;
  Result.Tag := body;
  Result.Style := TComputedStyle.ForTag(body, base, FSheet);
  Result.X := 0; Result.Y := 0; Result.W := ViewportW;
  LayoutChildren(Result, body, Result.Style,
    Result.Style.Padding.Left + Result.Style.Margin.Left,
    Result.Style.Padding.Top + Result.Style.Margin.Top,
    ViewportW - Result.Style.Padding.Horz - Result.Style.Margin.Horz, usedH);
  Result.H := usedH + Result.Style.Padding.Vert + Result.Style.Margin.Vert;
end;

{ painting }

procedure PaintBox(Canvas: TTina4Canvas; Box: TLayoutBox; OffsetY: Single);
var
  i: Integer;
  r: TTextRun;
  st: TComputedStyle;
  y: Single;
  sizeTxt: string;
  m: TTina4TextMetrics;
begin
  st := Box.Style;
  y := Box.Y - OffsetY;
  if Box.IsImagePlaceholder then
  begin
    if Box.ImageHandle >= 0 then
    begin
      Canvas.DrawImage(Box.ImageHandle, Box.X, y, Box.W, Box.H);
      Exit;
    end;
    Canvas.FillRect(Box.X, y, Box.W, Box.H, IMG_PLACEHOLDER_BG);
    Canvas.StrokeRect(Box.X, y, Box.W, Box.H, 1, IMG_PLACEHOLDER_FG);
    Canvas.DrawLine(Box.X, y, Box.X + Box.W, y + Box.H, 1, IMG_PLACEHOLDER_FG);
    Canvas.DrawLine(Box.X + Box.W, y, Box.X, y + Box.H, 1, IMG_PLACEHOLDER_FG);
    if (Box.Tag <> nil) then
    begin
      sizeTxt := Format('img %dx%d', [Round(Box.W), Round(Box.H)]);
      m := Canvas.MeasureText(sizeTxt, 11, []);
      Canvas.DrawText(Box.X + (Box.W - m.Width) / 2, y + (Box.H - 14) / 2,
        sizeTxt, 11, [], IMG_PLACEHOLDER_FG);
    end;
    Exit;
  end;
  if (st.BackgroundColor shr 24) > 0 then
  begin
    if st.MaxCornerRadius > 0 then
      Canvas.FillRoundRect(Box.X, y, Box.W, Box.H, st.MaxCornerRadius, st.BackgroundColor)
    else
      Canvas.FillRect(Box.X, y, Box.W, Box.H, st.BackgroundColor);
  end;
  if st.BorderWidths.Top > 0 then
  begin
    if st.MaxCornerRadius > 0 then
      Canvas.StrokeRoundRect(Box.X, y, Box.W, Box.H, st.MaxCornerRadius,
        st.BorderWidths.Top, st.BorderColor)
    else
      Canvas.StrokeRect(Box.X, y, Box.W, Box.H, st.BorderWidths.Top, st.BorderColor);
  end;
  for i := 0 to Box.Runs.Count - 1 do
  begin
    r := Box.Runs[i];
    Canvas.DrawText(r.X, r.Y - OffsetY, r.Text, r.FontSize, r.Styles, r.Color);
  end;
  for i := 0 to Box.Children.Count - 1 do
    PaintBox(Canvas, Box.Children[i], OffsetY);
end;

function HitTest(Box: TLayoutBox; X, Y: Single): THTMLTag;
var
  i: Integer;
  r: THTMLTag;
begin
  Result := nil;
  if (X < Box.X) or (X > Box.X + Box.W) or (Y < Box.Y) or (Y > Box.Y + Box.H) then
  begin
    // children may overflow the parent box (inline atoms); still search them
    for i := Box.Children.Count - 1 downto 0 do
    begin
      r := HitTest(Box.Children[i], X, Y);
      if r <> nil then Exit(r);
    end;
    Exit;
  end;
  for i := Box.Children.Count - 1 downto 0 do
  begin
    r := HitTest(Box.Children[i], X, Y);
    if r <> nil then Exit(r);
  end;
  if Box.Tag <> nil then Result := Box.Tag;
end;

end.
