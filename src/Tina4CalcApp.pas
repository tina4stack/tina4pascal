unit Tina4CalcApp;

{ The calculator's logic, as a portable unit.

  It holds no widgets and no window — only arithmetic state and the named
  actions the UI's onclick handlers dispatch to (calc.digit / calc.op / calc.eq
  / …). On each action it updates its state and writes the new value straight
  into the <div id="display"> / <div id="expr"> nodes of whatever document the
  engine is showing, then flags the layout dirty so the shell repaints.

  Because the registration happens in `initialization`, ANY shell that `uses`
  this unit gets the calculator: the desktop host (Tina4App.RunApp) and the
  Android JNI library alike. The UI itself is calculator.html — the same file
  drives every platform. }

{$mode delphi}{$H+}

interface

{ Registration is automatic (see initialization); call this only if a shell
  wants to (re)install the actions explicitly. }
procedure RegisterCalcActions;

implementation

uses
  SysUtils,
  Tina4HTMLDom,        // THTMLTag
  Tina4Events,         // RegisterAction
  Tina4Builtins;       // BuiltinsRoot, FindById, SetElementText, BuiltinsDirty

var
  Cur:        string  = '0';    // the number currently shown / being typed
  ExprStr:    string  = '';     // the faint line above (e.g. "12 ×")
  Stored:     Double  = 0;      // the left-hand operand
  PendOp:     Char    = ' ';    // pending operator: + - * /  (' ' = none)
  FreshEntry: Boolean = True;   // next digit starts a new number
  ErrState:   Boolean = False;  // divide-by-zero etc.
  FS:         TFormatSettings;  // '.' decimals regardless of OS locale

{ ---- helpers ------------------------------------------------------------- }

function FormatNum(V: Double): string;
begin
  Result := FloatToStrF(V, ffGeneral, 12, 0, FS);   // 12 sig digits, trimmed
end;

function CurVal: Double;
begin
  if not TryStrToFloat(Cur, Result, FS) then Result := 0;
end;

function OpGlyph(Op: Char): string;
begin
  case Op of
    '+': Result := '+';
    '-': Result := #$E2#$88#$92;   // − minus
    '*': Result := #$C3#$97;       // × times
    '/': Result := #$C3#$B7;       // ÷ divide
  else   Result := '';
  end;
end;

procedure Show;
var t: THTMLTag;
begin
  t := FindById(BuiltinsRoot, 'display');
  if t <> nil then SetElementText(t, Cur);
  t := FindById(BuiltinsRoot, 'expr');
  if t <> nil then
    if ExprStr = '' then SetElementText(t, #$C2#$A0)   // &nbsp; keeps the line height
    else SetElementText(t, ExprStr);
  BuiltinsDirty := True;                                // → engine relayouts + repaints
end;

procedure DoClear;
begin
  Cur := '0'; ExprStr := ''; Stored := 0; PendOp := ' ';
  FreshEntry := True; ErrState := False;
end;

procedure SetError;
begin
  ErrState := True; Cur := 'Error'; ExprStr := '';
end;

procedure Compute;
var b, r: Double;
begin
  b := CurVal;
  case PendOp of
    '+': r := Stored + b;
    '-': r := Stored - b;
    '*': r := Stored * b;
    '/': begin if b = 0 then begin SetError; Exit; end; r := Stored / b; end;
  else   r := b;
  end;
  Stored := r;
  Cur := FormatNum(r);
end;

{ ---- actions ------------------------------------------------------------- }

procedure ActDigit(const A: string);
begin
  if ErrState then DoClear;
  if FreshEntry then begin Cur := A; FreshEntry := False; end
  else if Cur = '0' then Cur := A
  else if Length(Cur) < 12 then Cur := Cur + A;
  Show;
end;

procedure ActDot(const A: string);
begin
  if ErrState then DoClear;
  if FreshEntry then begin Cur := '0.'; FreshEntry := False; end
  else if Pos('.', Cur) = 0 then Cur := Cur + '.';
  Show;
end;

procedure ActOp(const A: string);
begin
  if ErrState or (A = '') then Exit;
  if (PendOp <> ' ') and (not FreshEntry) then Compute   // chain a running total
  else Stored := CurVal;                                 // seed with what's shown
  if ErrState then begin Show; Exit; end;
  PendOp := A[1];
  FreshEntry := True;
  ExprStr := FormatNum(Stored) + ' ' + OpGlyph(PendOp);
  Show;
end;

procedure ActEq(const A: string);
begin
  if ErrState then Exit;
  if PendOp <> ' ' then
  begin
    ExprStr := FormatNum(Stored) + ' ' + OpGlyph(PendOp) + ' ' + Cur + ' =';
    Compute;
    PendOp := ' ';
    FreshEntry := True;
  end;
  Show;
end;

procedure ActClear(const A: string);
begin
  DoClear; Show;
end;

procedure ActNeg(const A: string);
begin
  if ErrState or (Cur = '0') then Exit;
  if Cur[1] = '-' then Delete(Cur, 1, 1) else Cur := '-' + Cur;
  Show;
end;

procedure ActPct(const A: string);
begin
  if ErrState then Exit;
  Cur := FormatNum(CurVal / 100);
  FreshEntry := False;
  Show;
end;

procedure RegisterCalcActions;
begin
  RegisterAction('calc.digit', @ActDigit);
  RegisterAction('calc.dot',   @ActDot);
  RegisterAction('calc.op',    @ActOp);
  RegisterAction('calc.eq',    @ActEq);
  RegisterAction('calc.clear', @ActClear);
  RegisterAction('calc.neg',   @ActNeg);
  RegisterAction('calc.pct',   @ActPct);
end;

initialization
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  FS.ThousandSeparator := #0;
  RegisterCalcActions;
end.
