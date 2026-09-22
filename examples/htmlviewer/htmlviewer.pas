program htmlviewer;

{ Tina4 native-pascal HTML viewer — macOS shell.
  Usage: htmlviewer [file.html] [--snapshot out.png]
  HTML drives everything: no widget components. Form controls are drawn by
  the renderer; state lives in the DOM; interaction surfaces as semantic
  events (printed to stdout and mirrored in the window title). }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}   // SSE/WS worker threads (Tina4Live) need a thread driver
  SysUtils, StrUtils, Classes, Math, DateUtils, Generics.Collections,
  Tina4HTMLDom, Tina4RenderBackend, Tina4ShellCocoa, Tina4HTMLLayout, Tina4Canvas2D,
  Tina4Lottie, Tina4Events, Tina4Builtins, Tina4Live, Tina4Elements, Tina4LinkOpen;

var
  GLottie: TTina4Lottie = nil;

{ Demo Lottie painter — loads the JSON at $TINA4_LOTTIE once and renders a frame
  ($TINA4_LOTTIE_FRAME, default 0) for <canvas id="lottie">. }
procedure LottiePainter(ctx: TTina4Canvas2D);
var sl: TStringList; p: string; sc: Single;
begin
  if GLottie = nil then
  begin
    p := GetEnvironmentVariable('TINA4_LOTTIE');
    if p = '' then Exit;
    sl := TStringList.Create;
    try
      sl.LoadFromFile(p);
      GLottie := TTina4Lottie.Create;
      if not GLottie.LoadFromString(sl.Text) then FreeAndNil(GLottie);
    finally sl.Free; end;
  end;
  if (GLottie <> nil) and (GLottie.Width > 0) and (GLottie.Height > 0) then
  begin
    // contain-fit + centre (full composition size)
    sc := Min(ctx.Width / GLottie.Width, ctx.Height / GLottie.Height);
    ctx.Translate((ctx.Width - GLottie.Width * sc) / 2,
                  (ctx.Height - GLottie.Height * sc) / 2);
    ctx.Scale(sc, sc);
    GLottie.Render(ctx, StrToFloatDef(GetEnvironmentVariable('TINA4_LOTTIE_FRAME'), 0));
  end;
end;

{ Demo <canvas> painter (pure Pascal, no JS) — registered for id="demo" so a page
  with <canvas id="demo"> draws this scene. }
{ Tier-2 custom element demo: <ratingstars value="N"> paints five dots, the
  first N gold. Registered via RegisterNativeElement — no core edit. }
procedure DrawRating(const Tag: THTMLTag; X, Y, W, H: Single;
  Canvas: TTina4Canvas; const St: TComputedStyle);
var i, val: Integer; sz, gap, dx, dy: Single;
begin
  val := StrToIntDef(Tag.GetAttribute('value'), 0);
  sz := H * 0.6;
  gap := (W - 5 * sz) / 6; if gap < 2 then gap := 2;
  dy := Y + (H - sz) / 2;
  for i := 0 to 4 do
  begin
    dx := X + gap + i * (sz + gap);
    if i < val then Canvas.FillRoundRect(dx, dy, sz, sz, sz * 0.3, $FFFFD23C)
    else Canvas.FillRoundRect(dx, dy, sz, sz, sz * 0.3, $FFE6E5F0);
  end;
end;

{ Tap cycles the rating 0..5. }
function TapRating(const Tag: THTMLTag): Boolean;
var val: Integer;
begin
  val := (StrToIntDef(Tag.GetAttribute('value'), 0) + 1) mod 6;
  Tag.Attributes.AddOrSetValue('value', IntToStr(val));
  Result := True;
end;

procedure CanvasDemo(ctx: TTina4Canvas2D);
var i: Integer; bh: Single;
const bars: array[0..4] of Single = (0.5, 0.8, 0.35, 0.95, 0.6);
begin
  ctx.SetFillColor($FF2B41E6);
  for i := 0 to 4 do
  begin bh := 150 * bars[i]; ctx.FillRect(24 + i * 44, 200 - bh, 30, bh); end;
  ctx.SetGlobalAlpha(0.85); ctx.SetFillColor($FFFF5AA0);
  ctx.BeginPath; ctx.Arc(280, 90, 46, 0, 2 * Pi); ctx.Fill;
  ctx.SetGlobalAlpha(1);
  ctx.SetStrokeColor($FFFFD23C); ctx.SetLineWidth(4);
  ctx.BeginPath; ctx.MoveTo(24, 40);
  ctx.BezierCurveTo(120, -10, 220, 90, 336, 30); ctx.Stroke;
  ctx.SetFillColor($FF15162E); ctx.SetFont(15, True, False); ctx.SetTextAlign('left');
  ctx.FillText('Q1  Q2  Q3  Q4  Q5', 24, 224);
  ctx.SetFont(13, False, False); ctx.SetTextAlign('center'); ctx.SetFillColor($FFFFFFFF);
  ctx.FillText('87%', 280, 95);
end;

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
    OpenDate: THTMLTag;           // <input type=date> calendar open, nil = none
    CalYear, CalMonth: Integer;   // month the open calendar is showing
    CalX, CalW: Single;           // overlay geometry (screen CSS px), set in Paint
    CalHdrY, CalHdrH: Single;     // header band (‹ Month YYYY ›)
    CalGridY, CalCellW, CalCellH: Single;   // 6×7 day grid
    CalTodayY, CalTodayH: Single; // Today footer button
    CalDays, CalFirstDow: Integer;// days in month, weekday of the 1st (0=Sun)
    CalYearMinusMs, CalYearPlusMs: QWord;   // « / » decade double-tap timing
    DragBox: TLayoutBox;          // scroller being drag-scrolled, nil = none
    DragStartX, DragStartY: Single;
    DragStartLeft, DragStartTop: Single;
    LastDragX, LastDragY: Single;
    MomentumBox: TLayoutBox;      // flick inertia target, nil = none
    MomVX, MomVY: Single;         // velocity (px per tick)
    AudioTag: THTMLTag;           // <audio controls> currently playing, nil = none
    HoverOpt: Integer;            // hovered option row in the open dropdown, -1 none
    Script: TStringList;          // --script: one driver command per tick
    ScriptPos: Integer;
    procedure Paint(Canvas: TTina4Canvas; W, H: Single);
    procedure Scroll(X, Y, DX, DY: Single);
    procedure MouseDown(X, Y: Single);
    procedure MouseUp(X, Y: Single);
    procedure MouseMove(X, Y: Single);
    procedure MouseDrag(X, Y: Single);
    procedure MomentumTick;
    procedure KeyDown(const Chars: string; KeyCode: Integer);
    procedure Tick;
    procedure Rebuild;
    procedure Event(const S: string);
    procedure FireInput(T: THTMLTag);
    procedure SetFocus(T: THTMLTag);
    procedure OpenDatePicker(T: THTMLTag);
    procedure PaintDateOverlay(Canvas: TTina4Canvas; W, H: Single);
    procedure HandleDateTap(X, Y: Single);
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

{ Textarea line math (offsets are 0-based, between bytes; newline = #10).
  LineStartOffset: offset just after the newline that begins the caret's line
  (or 0). LineEndOffset: offset just before the next newline (or end). }
function LineStartOffset(const V: string; Caret: Integer): Integer;
begin
  Result := Caret;
  while (Result > 0) and (V[Result] <> #10) do Dec(Result);
end;

function LineEndOffset(const V: string; Caret: Integer): Integer;
begin
  Result := Caret;
  while (Result < Length(V)) and (V[Result + 1] <> #10) do Inc(Result);
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

{ Fire an element's oninput/onchange handler (built-in or app action). The
  caller has already mutated the value + rebuilt; this runs the reactive hook
  (e.g. output.recalc) and rebuilds again if the DOM changed. }
procedure TViewer.FireInput(T: THTMLTag);
begin
  if T = nil then Exit;
  if T.HasAttribute('oninput') then DispatchAction(T.GetAttribute('oninput'))
  else if T.HasAttribute('onchange') then DispatchAction(T.GetAttribute('onchange'));
  if BuiltinsDirty then begin BuiltinsDirty := False; Rebuild; end;
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
    else if cmd = 'drag' then
    begin // drag X0 Y0 X1 Y1 — press, drag across, release
      MouseDown(StrToFloatDef(a, 0), StrToFloatDef(b, 0));
      MouseDrag((StrToFloatDef(a, 0) + StrToFloatDef(c, 0)) / 2, StrToFloatDef(b, 0));
      MouseDrag(StrToFloatDef(c, 0), StrToFloatDef(b, 0));
      MouseUp(StrToFloatDef(c, 0), StrToFloatDef(b, 0));
    end
    else if cmd = 'key' then
      KeyDown(Copy(line, 5, MaxInt), TK_NONE)
    else if cmd = 'enter' then KeyDown('', TK_RETURN)
    else if cmd = 'tab' then KeyDown('', TK_TAB)
    else if cmd = 'backspace' then KeyDown('', TK_BACKSPACE)
    else if cmd = 'hover' then MouseMove(StrToFloatDef(a, 0), StrToFloatDef(b, 0))
    else if cmd = 'clock' then AnimAdvance(StrToFloatDef(a, 0) - AnimClock)
    else if cmd = 'left' then KeyDown('', TK_LEFT)
    else if cmd = 'right' then KeyDown('', TK_RIGHT)
    else if cmd = 'up' then KeyDown('', TK_UP)
    else if cmd = 'down' then KeyDown('', TK_DOWN)
    else if cmd = 'esc' then KeyDown('', TK_ESCAPE)
    else if cmd = 'wheel' then
      Scroll(StrToFloatDef(a, 0), StrToFloatDef(b, 0), 0, StrToFloatDef(c, 0))
    else if cmd = 'dumpval' then
    begin
      if FocusTag = nil then WriteLn('[dumpval] no focus')
      else
        WriteLn('[dumpval] caret=', FocusTag.GetAttribute('_caret', '?'), ' value=[',
          StringReplace(FocusTag.GetAttribute('value', InnerText(FocusTag)), #10, '\n', [rfReplaceAll]), ']');
      Flush(Output);
    end
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

{ ---- native <input type=date> calendar overlay ----------------------------
  Ported from the shared Tina4Interact engine so the desktop viewer opens the
  same canvas-drawn calendar the mobile shells do (rather than treating a date
  field as a plain text input). Same overlay model as the <select> dropdown:
  Paint draws it last (top layer) and MouseUp routes taps to it while open. }

function CalMonthName(M: Integer): string;
const N: array[1..12] of string = ('January','February','March','April','May',
  'June','July','August','September','October','November','December');
begin
  if (M >= 1) and (M <= 12) then Result := N[M] else Result := '';
end;

{ Open the calendar for a date control, starting on the value's month (or today). }
procedure TViewer.OpenDatePicker(T: THTMLTag);
var iso: string; y, mo, e: Integer;
begin
  // focus the field (ring) without the SetFocus Rebuild — the caller Rebuilds
  if FocusTag <> nil then FocusTag.IsFocused := False;
  FocusTag := T; T.IsFocused := True;
  OpenDate := T;
  iso := Trim(T.GetAttribute('value'));
  y := 0; mo := 0;
  if Length(iso) >= 10 then
  begin
    Val(Copy(iso, 1, 4), y, e); if e <> 0 then y := 0;
    Val(Copy(iso, 6, 2), mo, e); if (e <> 0) or (mo < 1) or (mo > 12) then mo := 0;
  end;
  if (y = 0) or (mo = 0) then begin y := YearOf(Date); mo := MonthOf(Date); end;
  CalYear := y; CalMonth := mo;
end;

{ Paint the month calendar on top of the page. Header ‹ Month YYYY ›, weekday
  row, a 6×7 day grid (today ringed, selected filled), and a Today button. }
procedure TViewer.PaintDateOverlay(Canvas: TTina4Canvas; W, H: Single);
const
  INK=$FF15162E; BLUE=$FF2B41E6; TINT=$FFEFF1FE; BORDER=$FFE6E5F0;
  MUTED=$FF9698B4; PAPER=$FFFFFFFF;
  DOW: array[0..6] of string = ('Su','Mo','Tu','We','Th','Fr','Sa');
var
  box: TLayoutBox; bx, by, pad, w2, h2, titleY, aY, cx, cy: Single;
  i, col, row, day, selY, selMo, selD, e, tY, tMo, tD: Integer;
  title, iso, cell: string; isToday, isSel: Boolean;
begin
  if (OpenDate = nil) or (RootBox = nil) then Exit;
  box := FindBoxForTag(RootBox, OpenDate);
  if box = nil then begin OpenDate := nil; Exit; end;

  pad := 12; CalCellW := 46; CalCellH := 44;    // finger-friendly tap targets
  w2 := 7 * CalCellW + 2 * pad;                  // 346
  CalHdrH := 52;
  h2 := CalHdrH + 26 + 6 * CalCellH + 48 + pad;  // header + dow + 6 rows + footer
  bx := box.X; by := box.Y - ScrollY + box.H + 6;
  if bx + w2 > W then bx := W - w2 - 6;
  if bx < 6 then bx := 6;
  if by + h2 > H then by := box.Y - ScrollY - h2 - 6;   // flip above
  if by < 6 then by := 6;
  CalX := bx; CalW := w2;

  CalDays := DaysInAMonth(CalYear, CalMonth);
  CalFirstDow := DayOfWeek(EncodeDate(CalYear, CalMonth, 1)) - 1;   // 0=Sun

  // panel + soft shadow (rounded to match the fill)
  Canvas.FillRoundRect(bx - 1, by + 8, w2 + 2, h2, 18, $14000000);
  Canvas.FillRoundRect(bx, by, w2, h2, 18, PAPER);
  Canvas.StrokeRoundRect(bx, by, w2, h2, 18, 1, BORDER);

  // header: « year‹ month  Title  month› year »
  CalHdrY := by;
  titleY := by + (CalHdrH - 16) / 2;
  aY := by + (CalHdrH - 19) / 2;
  Canvas.DrawText(bx + 14, aY, #$C2#$AB, 19, [tfsBold], BLUE);          // « year prev
  Canvas.DrawText(bx + 38, aY, #$E2#$80#$B9, 19, [tfsBold], BLUE);      // ‹ month prev
  Canvas.DrawText(bx + w2 - 40, aY, #$E2#$80#$BA, 19, [tfsBold], BLUE); // › month next
  Canvas.DrawText(bx + w2 - 26, aY, #$C2#$BB, 19, [tfsBold], BLUE);     // » year next
  title := CalMonthName(CalMonth) + ' ' + IntToStr(CalYear);
  Canvas.DrawText(bx + (w2 - Canvas.MeasureText(title, 16, [tfsBold]).Width) / 2,
    titleY, title, 16, [tfsBold], INK);

  // weekday labels
  for i := 0 to 6 do
    Canvas.DrawText(bx + pad + i * CalCellW + (CalCellW - 16) / 2,
      by + CalHdrH, DOW[i], 12, [tfsBold], MUTED);

  // selected + today
  selY := 0; selMo := 0; selD := 0;
  iso := Trim(OpenDate.GetAttribute('value'));
  if Length(iso) >= 10 then
  begin
    Val(Copy(iso,1,4), selY, e); Val(Copy(iso,6,2), selMo, e); Val(Copy(iso,9,2), selD, e);
  end;
  tY := YearOf(Date); tMo := MonthOf(Date); tD := DayOf(Date);

  CalGridY := by + CalHdrH + 26;
  for day := 1 to CalDays do
  begin
    i := CalFirstDow + day - 1;
    col := i mod 7; row := i div 7;
    cx := bx + pad + col * CalCellW;
    cy := CalGridY + row * CalCellH;
    isSel := (selY = CalYear) and (selMo = CalMonth) and (selD = day);
    isToday := (tY = CalYear) and (tMo = CalMonth) and (tD = day);
    if isSel then
      Canvas.FillRoundRect(cx + 3, cy + 2, CalCellW - 6, CalCellH - 6, 9, BLUE)
    else if isToday then
      Canvas.StrokeRoundRect(cx + 3, cy + 2, CalCellW - 6, CalCellH - 6, 9, 1.5, BLUE);
    cell := IntToStr(day);
    if isSel then
      Canvas.DrawText(cx + (CalCellW - Canvas.MeasureText(cell,15,[tfsBold]).Width)/2,
        cy + 10, cell, 15, [tfsBold], PAPER)
    else
      Canvas.DrawText(cx + (CalCellW - Canvas.MeasureText(cell,15,[]).Width)/2,
        cy + 10, cell, 15, [], INK);
  end;

  // footer: Today
  CalTodayH := 34;
  CalTodayY := by + h2 - CalTodayH - 8;
  Canvas.FillRoundRect(bx + pad, CalTodayY, w2 - 2 * pad, CalTodayH, 9, TINT);
  Canvas.DrawText(bx + (w2 - Canvas.MeasureText('Today', 14, [tfsBold]).Width) / 2,
    CalTodayY + 9, 'Today', 14, [tfsBold], BLUE);
end;

{ A tap while the calendar is open: nav arrows keep it open; a day / Today picks. }
procedure TViewer.HandleDateTap(X, Y: Single);
var i, col, row, day: Integer; iso: string;
begin
  if OpenDate = nil then Exit;
  // header arrows: « year- | ‹ month- (left) … month+ › | » year+ (right)
  if (Y >= CalHdrY) and (Y < CalHdrY + CalHdrH) then
  begin
    if (X >= CalX) and (X < CalX + 28) then                      // « year prev
    begin
      if GetTickCount64 - CalYearMinusMs < 400 then
        begin CalYear := CalYear - 9; CalYearMinusMs := 0; end   // 2nd tap → −10 total
      else begin Dec(CalYear); CalYearMinusMs := GetTickCount64; end;
      Rebuild; Exit;
    end;
    if (X >= CalX + 28) and (X < CalX + 56) then                 // ‹ month prev
    begin Dec(CalMonth); if CalMonth < 1 then begin CalMonth := 12; Dec(CalYear); end;
      Rebuild; Exit; end;
    if (X >= CalX + CalW - 56) and (X < CalX + CalW - 28) then   // › month next
    begin Inc(CalMonth); if CalMonth > 12 then begin CalMonth := 1; Inc(CalYear); end;
      Rebuild; Exit; end;
    if (X >= CalX + CalW - 28) and (X < CalX + CalW) then        // » year next
    begin
      if GetTickCount64 - CalYearPlusMs < 400 then
        begin CalYear := CalYear + 9; CalYearPlusMs := 0; end    // 2nd tap → +10 total
      else begin Inc(CalYear); CalYearPlusMs := GetTickCount64; end;
      Rebuild; Exit;
    end;
  end;
  // Today
  if (Y >= CalTodayY) and (Y < CalTodayY + CalTodayH) and
     (X >= CalX) and (X <= CalX + CalW) then
  begin
    OpenDate.Attributes.AddOrSetValue('value', FormatDateTime('yyyy-mm-dd', Date));
    Event('change ' + OpenDate.GetAttribute('name', 'date') + '=' + OpenDate.GetAttribute('value'));
    OpenDate := nil; Rebuild; Exit;
  end;
  // a day cell
  if (X >= CalX + 12) and (X < CalX + 12 + 7 * CalCellW) and
     (Y >= CalGridY) and (Y < CalGridY + 6 * CalCellH) then
  begin
    col := Trunc((X - CalX - 12) / CalCellW);
    row := Trunc((Y - CalGridY) / CalCellH);
    i := row * 7 + col;
    day := i - CalFirstDow + 1;
    if (day >= 1) and (day <= CalDays) then
    begin
      iso := Format('%.4d-%.2d-%.2d', [CalYear, CalMonth, day]);
      OpenDate.Attributes.AddOrSetValue('value', iso);
      Event('change ' + OpenDate.GetAttribute('name', 'date') + '=' + iso);
      OpenDate := nil; Rebuild; Exit;
    end;
  end;
  OpenDate := nil; Rebuild;   // tap elsewhere dismisses
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
  oh := 30;                          // must match the dropdown paint (30px rows, 4px gap)
  oy := sb.Y + sb.H - ScrollY + 4;
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
  dropTop, dropR, dropH: Single;
  sb: TLayoutBox;
  opt: THTMLTag;
  txt, cur: string;
begin
  ViewH := H;
  // snapshot testing: TINA4_ANIM_CLOCK forces the animation clock to a fixed time
  if GetEnvironmentVariable('TINA4_ANIM_CLOCK') <> '' then
    AnimAdvance(StrToFloatDef(GetEnvironmentVariable('TINA4_ANIM_CLOCK'), 0) - AnimClock);
  AnimResetActive;   // paint re-marks it if animated content is on screen
  if (RootBox = nil) or (Abs(W - LastW) > 0.5) then
  begin
    LastW := W;
    FreeAndNil(RootBox);
    FreeAndNil(Engine);
    Sheet.SetMediaContext(W, False);   // @media evaluates against the real viewport width
    Engine := TLayoutEngine.Create(Canvas, Sheet);
    RootBox := Engine.Build(Parser.Root, W, ViewH);
  end;
  Canvas.FillRect(0, 0, W, H, $FFFFFFFF);
  PaintBox(Canvas, RootBox, ScrollY);

  // a modal <dialog> (dialog.showModal) paints centred over a dimmed backdrop
  PaintModalOverlay(Canvas, RootBox, W, H);

  // expanded dropdown paints last (top layer): a rounded, soft-shadowed panel
  // (matching the rounded select), rows clipped to the panel so the first/last
  // highlight corners follow the radius; hover/selected rows tinted, no per-row
  // hairlines. Radius follows the select's own border-radius.
  if OpenSelect <> nil then
  begin
    sb := FindBoxForTag(RootBox, OpenSelect);
    if sb <> nil then
    begin
      oh := 30;
      ow := Max(sb.W, 160);
      oy := sb.Y + sb.H - ScrollY + 4;                       // small gap under the select
      dropTop := oy;
      dropR := Max(6, Min(sb.Style.MaxCornerRadius, 12));    // match the select's rounding
      dropH := CountOptions(OpenSelect) * oh;
      cur := OpenSelect.GetAttribute('value');
      Canvas.FillSoftShadow(sb.X, oy + 3, ow, dropH, dropR, 14, $30151622);   // soft drop shadow
      Canvas.SaveState;
      Canvas.ClipRoundRect(sb.X, oy, ow, dropH, dropR);      // clip rows to the rounded panel
      Canvas.FillRect(sb.X, oy, ow, dropH, $FFFFFFFF);
      for opt in OpenSelect.Children do
      begin
        if not SameText(opt.TagName, 'option') then Continue;
        txt := InnerText(opt);
        if (opt.GetAttribute('value', txt) = cur) or (txt = cur) then
        begin
          Canvas.FillRect(sb.X, oy, ow, oh, $FF2B41E6);      // selected row (Tina4 blue)
          Canvas.DrawText(sb.X + 12, oy + 6, txt, 15, [], $FFFFFFFF);
        end
        else
        begin
          if (HoverOpt >= 0) and (HoverOpt = Round((oy - dropTop) / oh)) then
            Canvas.FillRect(sb.X, oy, ow, oh, $FFE4E8FF);    // hovered row (blue-soft)
          Canvas.DrawText(sb.X + 12, oy + 6, txt, 15, [], $FF15162E);
        end;
        oy := oy + oh;
      end;
      Canvas.RestoreState;
      Canvas.StrokeRoundRect(sb.X, dropTop, ow, dropH, dropR, 1, $FFE6E5F0);  // crisp outline on top
    end;
  end;

  // open <input type=date> calendar paints last (top layer)
  if OpenDate <> nil then PaintDateOverlay(Canvas, W, H);

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
        ho := Trunc((Y - (sb.Y + sb.H - ScrollY + 4)) / 30);   // panel: 4px gap, 30px rows
      if (ho < 0) or (ho >= CountOptions(OpenSelect)) then ho := -1;
      if ho <> HoverOpt then begin HoverOpt := ho; Shell.Invalidate; end;
    end;
    Exit;
  end;
  // OS pointer shape from the hovered element's CSS `cursor`
  Shell.SetCursor(CursorAt(RootBox, X, Y + ScrollY));
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

procedure TViewer.MouseDrag(X, Y: Single);
begin
  if DragBox = nil then Exit;
  // click-hold drag: content follows the cursor (opposite of a scrollbar)
  if DragBox.ScrollableX and (DragBox.MaxScrollX > 0) then
    DragBox.ScrollLeft := Max(0, Min(DragBox.MaxScrollX,
      DragStartLeft - (X - DragStartX)));
  if DragBox.Scrollable and (DragBox.MaxScroll > 0) then
    DragBox.ScrollTop := Max(0, Min(DragBox.MaxScroll,
      DragStartTop - (Y - DragStartY)));
  // velocity = last frame's delta (drives flick momentum on release)
  MomVX := X - LastDragX; MomVY := Y - LastDragY;
  LastDragX := X; LastDragY := Y;
  Shell.Invalidate;
end;

{ Inertial deceleration after a flick; runs on the 16ms interactive ticker. }
procedure TViewer.MomentumTick;
const
  DECAY = 0.92;
var
  AudioProgFrac: Single;
  AudioProgPlaying: Boolean;
begin
  // live data (SSE/WS): fire queued messages onto their DOM elements, relayout
  LiveDrain;
  if BuiltinsDirty then begin BuiltinsDirty := False; Rebuild; Shell.Invalidate; end;
  // CSS animation / <lottie>: advance the shared clock + repaint while active
  if AnimActive then begin AnimAdvance(1 / 60); Shell.Invalidate; end;
  // <audio controls>: advance the played fraction from the shell player; when the
  // clip ends the shell reports Playing=False and the glyph resets to ▶.
  if AudioTag <> nil then
  begin
    AudioProgFrac := Shell.AudioProgress(AudioProgPlaying);
    AudioTag.Attributes.AddOrSetValue('progress', FloatToStr(AudioProgFrac));
    if not AudioProgPlaying then
    begin AudioTag.Attributes.Remove('playing'); AudioTag := nil; end;
    Rebuild; Shell.Invalidate;
  end;
  if MomentumBox = nil then Exit;
  if MomentumBox.ScrollableX and (MomentumBox.MaxScrollX > 0) then
    MomentumBox.ScrollLeft := Max(0, Min(MomentumBox.MaxScrollX,
      MomentumBox.ScrollLeft - MomVX));
  if MomentumBox.Scrollable and (MomentumBox.MaxScroll > 0) then
    MomentumBox.ScrollTop := Max(0, Min(MomentumBox.MaxScroll,
      MomentumBox.ScrollTop - MomVY));
  MomVX := MomVX * DECAY; MomVY := MomVY * DECAY;
  if (Abs(MomVX) < 0.4) and (Abs(MomVY) < 0.4) then MomentumBox := nil;
  Shell.Invalidate;
end;

procedure TViewer.MouseDown(X, Y: Single);
var
  hit: THTMLTag;
begin
  if RootBox = nil then Exit;
  // start a drag-scroll if the press is over a scrollable box
  MomentumBox := nil;  // a new press stops any inertial glide
  DragBox := FindScrollBox(RootBox, X, Y + ScrollY);
  if DragBox <> nil then
  begin
    DragStartX := X; DragStartY := Y;
    DragStartLeft := DragBox.ScrollLeft; DragStartTop := DragBox.ScrollTop;
    LastDragX := X; LastDragY := Y;
    MomVX := 0; MomVY := 0;
  end;
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

{ First element (depth-first) with the given id, or nil. }
function FindTagById(T: THTMLTag; const Id: string): THTMLTag;
var c: THTMLTag;
begin
  Result := nil;
  if T = nil then Exit;
  if T.GetAttribute('id') = Id then Exit(T);
  for c in T.Children do
  begin
    Result := FindTagById(c, Id);
    if Result <> nil then Exit;
  end;
end;

{ The form control a <label> resolves to: one nested inside it, else its `for`
  target. Lets a click on the label text toggle the checkbox/radio it labels. }
function LabelControl(Root, Node: THTMLTag): THTMLTag;
  function NestedControl(T: THTMLTag): THTMLTag;
  var c, r: THTMLTag;
  begin
    Result := nil;
    for c in T.Children do
    begin
      if IsFormControlTag(c.TagName) then Exit(c);
      r := NestedControl(c); if r <> nil then Exit(r);
    end;
  end;
  function ById(T: THTMLTag; const Id: string): THTMLTag;
  var c, r: THTMLTag;
  begin
    Result := nil;
    if T.GetAttribute('id') = Id then Exit(T);
    for c in T.Children do begin r := ById(c, Id); if r <> nil then Exit(r); end;
  end;
var lbl: THTMLTag;
begin
  Result := nil;
  lbl := Node;
  while (lbl <> nil) and not SameText(lbl.TagName, 'label') do lbl := lbl.Parent;
  if lbl = nil then Exit;
  Result := NestedControl(lbl);
  if (Result = nil) and lbl.HasAttribute('for') then
    Result := ById(Root, lbl.GetAttribute('for'));
end;

procedure TViewer.MouseUp(X, Y: Single);
var
  hit, t, g, au: THTMLTag;
  typ, ot, ov, v, picked: string;
  radios: TList<THTMLTag>;
  cb: TLayoutBox;
  tx, mw, stepv, curv, topY, lineH, wPrev, wNext: Single;
  ci, ni, lstart, lend, curline, tline: Integer;
  wasDragging: Boolean;
begin
  if RootBox = nil then Exit;
  wasDragging := (DragBox <> nil) and
    ((Abs(X - DragStartX) > 3) or (Abs(Y - DragStartY) > 3));
  // release with residual velocity → inertial glide
  if wasDragging and ((Abs(MomVX) > 1.5) or (Abs(MomVY) > 1.5)) then
    MomentumBox := DragBox;
  DragBox := nil;
  SetChain(ActiveTag, False, True, False);
  ActiveTag := nil;
  if wasDragging then Exit;  // a drag isn't a click

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

  // an open date calendar eats the click too (arrows re-navigate, a day picks)
  if OpenDate <> nil then
  begin
    HandleDateTap(X, Y);
    Exit;
  end;

  hit := HitTest(RootBox, X, Y + ScrollY);

  // Tier-2 custom element: a registered native element with an OnTap hook
  // handles the tap itself (walk up to the nearest one).
  t := hit;
  while t <> nil do
  begin
    if Assigned(ElementTapProc(t.TagName)) then
    begin
      if ElementTapProc(t.TagName)(t) then begin Rebuild; Exit; end;
      Break;
    end;
    t := t.Parent;
  end;

  // a click on a <label> acts on the control it labels
  t := LabelControl(Parser.Root, hit);
  if t <> nil then hit := t;

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
    if SameText(t.TagName, 'audio') and t.HasAttribute('controls') then
    begin
      // engine-drawn <audio controls>: a stateful play/pause toggle driven by
      // the shell's AVAudioPlayer. The 'playing'/'progress' attributes drive the
      // control's glyph + bar (progress is polled from the shell each tick).
      if t.HasAttribute('playing') then
      begin
        t.Attributes.Remove('playing');
        Shell.AudioPause;
        AudioTag := nil;
      end
      else
      begin
        v := t.GetAttribute('src');
        if v = '' then
          for au in t.Children do
            if SameText(au.TagName, 'source') and (v = '') then v := au.GetAttribute('src');
        if Shell.AudioPlay(v) then
        begin
          t.Attributes.AddOrSetValue('playing', 'playing');
          AudioTag := t;            // the tick loop polls its progress
        end;
      end;
      Rebuild;
      Exit;
    end;
    if SameText(t.TagName, 'recorder') then
    begin
      // stateful mic toggle (the audio analogue of <camera>): arm on first
      // click, stop + stamp the file on the next.
      if t.HasAttribute('recording') then
      begin
        t.Attributes.Remove('recording');
        picked := Shell.StopAudioCapture;
        if picked <> '' then
        begin
          t.Attributes.AddOrSetValue('value', picked);
          // route the clip into an <audio id="rec"> player so it can be played
          // back, then fire the element's onrecord action
          au := FindTagById(Parser.Root, 'rec');
          if (au <> nil) and SameText(au.TagName, 'audio') then
            au.Attributes.AddOrSetValue('src', picked);
          if t.HasAttribute('onrecord') then DispatchAction(t.GetAttribute('onrecord'));
          Event('record ' + t.GetAttribute('name', 'recorder') + '=' + picked);
        end;
      end
      else if Shell.StartAudioCapture then
        t.Attributes.AddOrSetValue('recording', 'recording');
      Rebuild;
      Exit;
    end;
    if (typ = 'file') or SameText(t.TagName, 'camera') then
    begin
      SetFocus(t);
      if SameText(t.TagName, 'camera') then
        picked := Shell.CaptureCamera
      else
        picked := Shell.PickFile;
      if picked <> '' then
      begin
        t.Attributes.AddOrSetValue('value', picked);
        Event('change ' + t.GetAttribute('name',
          IfThen(SameText(t.TagName, 'camera'), 'camera', 'file')) + '=' + picked);
        Rebuild;
      end;
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
    // <input type=date>: open the canvas-drawn calendar overlay (Paint draws it,
    // a follow-up click routes to HandleDateTap) rather than a text caret.
    if SameText(t.TagName, 'input') and (typ = 'date') then
    begin
      OpenDatePicker(t);
      Rebuild;
      Exit;
    end;
    // A submit control submits — but a <button onclick=...> runs its handler
    // instead (the common "plain button" use), falling through to onclick below.
    if ((typ = 'submit') or (SameText(t.TagName, 'button') and
        SameText(t.GetAttribute('type', 'submit'), 'submit')))
       and not t.HasAttribute('onclick') then
    begin
      SubmitForm(t);
      Exit;
    end;
    // <input type=number>: a click in the right-edge spinner strip steps the
    // value by `step` (default 1), clamped to min/max — no keyboard needed.
    if SameText(t.TagName, 'input') and SameText(typ, 'number') then
    begin
      cb := FindBoxForTag(RootBox, t);
      if (cb <> nil) and (X >= cb.X + cb.W - 20) then
      begin
        stepv := StrToFloatDef(t.GetAttribute('step'), 1);
        if stepv <= 0 then stepv := 1;
        curv := StrToFloatDef(t.GetAttribute('value'), 0);
        if Y < (cb.Y - ScrollY) + cb.H / 2 then curv := curv + stepv
        else curv := curv - stepv;
        if t.HasAttribute('min') then
          curv := Max(curv, StrToFloatDef(t.GetAttribute('min'), curv));
        if t.HasAttribute('max') then
          curv := Min(curv, StrToFloatDef(t.GetAttribute('max'), curv));
        if Frac(curv) = 0 then t.Attributes.AddOrSetValue('value', IntToStr(Round(curv)))
        else t.Attributes.AddOrSetValue('value', FloatToStr(curv));
        Event('change ' + t.GetAttribute('name', 'number') + '=' + t.GetAttribute('value'));
        Rebuild;
        FireInput(t);          // reactive: oninput → output.recalc etc.
        Exit;
      end;
    end;
    if SameText(t.TagName, 'input') or SameText(t.TagName, 'textarea') then
    begin
      // Use the laid-out box for caret positioning BEFORE SetFocus — SetFocus
      // Rebuilds, which FREES the box tree (cb would dangle → use-after-free).
      cb := FindBoxForTag(RootBox, t);
      // click-to-position the caret (single-line inputs)
      if SameText(t.TagName, 'input') then
      begin
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
        end;
      end
      // click-to-position the caret (multi-line textarea): pick the line by Y,
      // then the column by X within that line
      else if SameText(t.TagName, 'textarea') then
      begin
        if cb <> nil then
        begin
          v := t.GetAttribute('value', InnerText(t));
          if cb.Style.LineHeight > 4 then lineH := cb.Style.LineHeight
          else if cb.Style.LineHeight > 0 then lineH := cb.Style.FontSize * cb.Style.LineHeight
          else lineH := cb.Style.FontSize * 1.4;
          topY := (cb.Y - ScrollY) + cb.Style.BorderWidths.Top + cb.Style.Padding.Top;
          tline := Trunc((Y - topY) / lineH);
          if tline < 0 then tline := 0;
          // offset at the start of the clicked line
          lstart := 0; curline := 0; ci := 0;
          while (curline < tline) and (ci < Length(v)) do
          begin
            Inc(ci);
            if v[ci] = #10 then begin Inc(curline); lstart := ci; end;
          end;
          lend := LineEndOffset(v, lstart);
          // column by X, at the nearest character gap
          tx := cb.X + cb.Style.BorderWidths.Left + cb.Style.Padding.Left;
          ci := lstart;
          while ci < lend do
          begin
            ni := Utf8StepFwd(v, ci);
            wPrev := Shell.GetMeasuringCanvas.MeasureText(
              Copy(v, lstart + 1, ci - lstart), cb.Style.FontSize, []).Width;
            wNext := Shell.GetMeasuringCanvas.MeasureText(
              Copy(v, lstart + 1, ni - lstart), cb.Style.FontSize, []).Width;
            if tx + (wPrev + wNext) / 2 > X then Break;
            ci := ni;
          end;
          t.Attributes.AddOrSetValue('_caret', IntToStr(ci));
        end;
      end;
      SetFocus(t);   // focus AFTER cb is done being read (SetFocus frees the box tree)
      Rebuild;       // reflect the new _caret even when focus didn't change
      Exit;
    end;
  end
  else if FocusTag <> nil then
    SetFocus(nil); // clicked empty space: blur

  // <summary> click toggles its <details> open state
  t := hit;
  while t <> nil do
  begin
    if SameText(t.TagName, 'summary') and (t.Parent <> nil) and
       SameText(t.Parent.TagName, 'details') then
    begin
      if t.Parent.HasAttribute('open') then t.Parent.Attributes.Remove('open')
      else t.Parent.Attributes.AddOrSetValue('open', 'open');
      Event('toggle details');
      Rebuild;
      Exit;
    end;
    t := t.Parent;
  end;

  // semantic events: onclick handlers and links, walking up the tree
  t := hit;
  while t <> nil do
  begin
    if t.HasAttribute('onclick') then
    begin
      Event('onclick -> ' + t.GetAttribute('onclick'));
      DispatchAction(t.GetAttribute('onclick'));   // built-in dialog.*/output.* + app actions
      if BuiltinsDirty then begin BuiltinsDirty := False; Rebuild; end;
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
  i, idx, caret, np, ls, col, pls, le: Integer;
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
        FireInput(FocusTag);
      end;
    TK_DELETE:
      if caret < Length(v) then
      begin
        np := Utf8StepFwd(v, caret);
        Delete(v, caret + 1, np - caret);
        FocusTag.Attributes.AddOrSetValue('value', v);
        Rebuild;
        FireInput(FocusTag);
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
        if isArea then
        begin
          ls := LineStartOffset(v, caret);
          if ls > 0 then                       // move to the same column one line up
          begin
            col := caret - ls;
            pls := LineStartOffset(v, ls - 1);
            np := Min(pls + col, ls - 1);
          end
          else np := 0;                        // first line → home
          FocusTag.Attributes.AddOrSetValue('_caret', IntToStr(np));
        end
        else
          FocusTag.Attributes.AddOrSetValue('_caret', '0'); // single-line: home
        Rebuild;
      end;
    TK_DOWN:
      begin
        if isArea then
        begin
          le := LineEndOffset(v, caret);
          if le < Length(v) then               // move to the same column one line down
          begin
            ls := LineStartOffset(v, caret);
            col := caret - ls;
            np := Min(le + 1 + col, LineEndOffset(v, le + 1));
          end
          else np := Length(v);                // last line → end
          FocusTag.Attributes.AddOrSetValue('_caret', IntToStr(np));
        end
        else
          FocusTag.Attributes.AddOrSetValue('_caret', IntToStr(Length(v))); // single-line: end
        Rebuild;
      end;
    TK_RETURN:
      if isArea then
      begin
        Insert(#10, v, caret + 1);             // split the line at the caret
        FocusTag.Attributes.AddOrSetValue('value', v);
        FocusTag.Attributes.AddOrSetValue('_caret', IntToStr(caret + 1));
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
        OpenDate := nil;
        SetFocus(nil);
      end;
  else
    if Chars <> '' then
    begin
      Insert(Chars, v, caret + 1);
      FocusTag.Attributes.AddOrSetValue('value', v);
      FocusTag.Attributes.AddOrSetValue('_caret', IntToStr(caret + Length(Chars)));
      Rebuild;
      FireInput(FocusTag);        // reactive: oninput → output.recalc etc.
    end;
  end;
end;

{ bridge the decoupled Tina4Notify hook to the Cocoa shell's native banner }
procedure NotifyBridge(const Title, Body, Tag: string);
begin
  if (Viewer <> nil) and (Viewer.Shell <> nil) then Viewer.Shell.Notify(Title, Body, Tag);
end;

var
  FileName, SnapPath, HTML, CSSFile, CSSCacheDir, ScriptPath, FontFam, FontUrl: string;
  SL: TStringList;
  i, WinW, WinH: Integer;
  autof: TList<THTMLTag>;
begin
  WinW := 1024; WinH := 800;
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
    else if ParamStr(i) = '--height' then
    begin
      Inc(i);
      WinH := StrToIntDef(ParamStr(i), 800);
    end
    else if ParamStr(i) = '--width' then
    begin
      Inc(i);
      WinW := StrToIntDef(ParamStr(i), 1024);
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
  // built-in dialog.*/output.* actions dispatch against this DOM
  RegisterBuiltinActions;
  RegisterLiveActions;    // sse.connect / ws.connect / live.close
  BuiltinsRoot := Viewer.Parser.Root;
  RecalcOutputs(BuiltinsRoot);            // seed <output> values before first paint
  // custom-element registry demos: a Tier-1 template button and a Tier-2 native
  // element. Registered ONCE here; the engine expands/paints/dispatches them.
  RegisterElement('nicebutton',
    '<button class="nb nb-{variant}" onclick="{onclick}">{children}</button>',
    '.nb{display:inline-block;padding:10px 18px;border:0;border-radius:11px;' +
    'font-weight:700;color:#fff;background:#2b41e6;cursor:pointer}' +
    '.nb-pink{background:#ff5aa0}.nb-ghost{background:#f3f2fb;color:#2b41e6}');
  RegisterNativeElement('ratingstars', @DrawRating, @TapRating,
    'ratingstars{display:inline-block;width:150px;height:32px;cursor:pointer}');

  Viewer.Sheet := TCSSStyleSheet.Create;
  if ElementsDefaultCSS <> '' then Viewer.Sheet.AddCSS(ElementsDefaultCSS);  // UA-like defaults first
  Viewer.Shell := TCocoaShell.Create;            // created early: fetches remote <link> CSS
  Tina4SetNotifyHandler(@NotifyBridge);          // notify.show(...) → native banner
  Tina4InstallLinkOpener;                        // <a href=tel:/mailto:/http…> → the OS
  Tina4InstallClipboard;                         // Cmd+C on a user-select:text drag → pbcopy
  RegisterCanvasPainter('demo', @CanvasDemo);   // <canvas id="demo"> → the Pascal painter
  RegisterCanvasPainter('lottie', @LottiePainter);

  { Linked stylesheets: relative hrefs from beside the HTML file; remote URLs
    fetched (once) into a local cache via the shell, then loaded from there. }
  for i := 0 to Viewer.Parser.LinkHrefs.Count - 1 do
  begin
    CSSFile := Viewer.Parser.LinkHrefs[i];
    if (Pos('http://', LowerCase(CSSFile)) = 1) or (Pos('https://', LowerCase(CSSFile)) = 1) then
    begin
      CSSCacheDir := ExtractFilePath(ParamStr(0)) + 'csscache/';
      ForceDirectories(CSSCacheDir);
      CSSFile := CSSCacheDir +
        ExtractFileName(StringReplace(Viewer.Parser.LinkHrefs[i], '?', '_', [rfReplaceAll]));
      if not FileExists(CSSFile) then
        if Viewer.Shell.FetchToFile(Viewer.Parser.LinkHrefs[i], CSSFile) then
          WriteLn('[css] fetched ', Viewer.Parser.LinkHrefs[i])
        else
        begin
          WriteLn('[css] fetch failed, skipping: ', Viewer.Parser.LinkHrefs[i]);
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

  // @import: fetch each imported sheet like a <link> and AddCSS it. Draining by
  // index (not a for) picks up nested @imports added while parsing earlier ones.
  i := 0;
  while i < Viewer.Sheet.ImportHrefs.Count do
  begin
    CSSFile := Viewer.Sheet.ImportHrefs[i];
    if (Pos('http://', LowerCase(CSSFile)) = 1) or (Pos('https://', LowerCase(CSSFile)) = 1) then
    begin
      CSSCacheDir := ExtractFilePath(ParamStr(0)) + 'csscache/';
      ForceDirectories(CSSCacheDir);
      CSSFile := CSSCacheDir +
        ExtractFileName(StringReplace(Viewer.Sheet.ImportHrefs[i], '?', '_', [rfReplaceAll]));
      if not FileExists(CSSFile) then
        if not Viewer.Shell.FetchToFile(Viewer.Sheet.ImportHrefs[i], CSSFile) then
        begin Inc(i); Continue; end;
    end
    else if not FileExists(CSSFile) then
      CSSFile := ExtractFilePath(FileName) + CSSFile;
    if FileExists(CSSFile) then
    begin
      SL := TStringList.Create;
      SL.LoadFromFile(CSSFile);
      Viewer.Sheet.AddCSS(SL.Text);
      SL.Free;
      WriteLn('[css] @import ', CSSFile);
    end;
    Inc(i);
  end;

  WriteLn('Loaded ', FileName);

  { @font-face: register downloadable fonts before the first layout so text
    measurement uses the real face. RegisterFont fetches + disk-caches URLs. }
  for i := 0 to Viewer.Sheet.FontFaceCount - 1 do
  begin
    Viewer.Sheet.GetFontFace(i, FontFam, FontUrl);
    if (FontFam <> '') and (FontUrl <> '') then
    begin
      if Viewer.Shell.GetMeasuringCanvas.RegisterFont(FontFam, FontUrl) then
        WriteLn('[font] registered "', FontFam, '" from ', FontUrl)
      else
        WriteLn('[font] FAILED to register "', FontFam, '" from ', FontUrl);
    end;
  end;

  Viewer.Shell.OnPaint := Viewer.Paint;
  Viewer.Shell.OnScroll := Viewer.Scroll;
  Viewer.Shell.OnMouseDown := Viewer.MouseDown;
  Viewer.Shell.OnMouseUp := Viewer.MouseUp;
  Viewer.Shell.OnMouseMove := Viewer.MouseMove;
  Viewer.Shell.OnMouseDrag := Viewer.MouseDrag;
  Viewer.Shell.OnKeyDown := Viewer.KeyDown;
  // --snapshot / --script run headless: off-screen render, no window, no focus steal
  Viewer.Shell.Headless := (SnapPath <> '') or (ScriptPath <> '');

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
  end
  else
    Viewer.Shell.OnTick := Viewer.MomentumTick;  // flick inertia

  Viewer.Shell.Initialize(WinW, WinH, 'Tina4 HTMLRender — Free Pascal');

  // one-shot --snapshot: render off-screen and exit, no run loop / no window
  if (SnapPath <> '') and (ScriptPath = '') then
  begin
    Viewer.Shell.Snapshot(SnapPath);
    Exit;
  end;

  if ScriptPath <> '' then
    Viewer.Shell.StartTicker(400)   // script step cadence
  else
    Viewer.Shell.StartTicker(16);   // ~60fps momentum
  Viewer.Shell.Run;
end.
