{ Tina4Compositor — portable pixel math for the offscreen compositing subsystem.

  Pure Pascal, zero OS dependency: every routine works on a caller-owned RGBA
  buffer (premultiplied, planar, 0..1 Single). Both the Cocoa and iOS shells
  decode their platform bitmap into a Single buffer, call in here, and blit the
  result back — so `filter`, `mask`, `drop-shadow` and the 3D quad warp have ONE
  implementation shared across shells (three-layer law: logic in the core, not
  duplicated in each shell). }
unit Tina4Compositor;

{$mode delphi}{$H+}{$POINTERMATH ON}

interface

uses SysUtils, Classes, Math;

type
  PSingleBuf = ^Single;

{ IEEE-754 binary16 (half) <-> single, for shells whose offscreen buffer is
  16-bit float (macOS lockFocus hands one back). }
function Half2Single(h: Word): Single;
function Single2Half(s: Single): Word;

{ Apply a CSS `filter` chain and an optional `mask-image` gradient to a
  premultiplied planar RGBA Single buffer, in place. Scale = device px per CSS px
  (blur/shadow radii are multiplied by it). }
procedure ApplyFilterChainF(buf: PSingleBuf; pw, ph: Integer;
  const FilterSpec, MaskSpec: string; Scale: Single);

{ Map a CSS mix-blend-mode name to a CoreGraphics CGBlendMode integer (both
  shells use CoreGraphics; '' / 'normal' -> 0 = kCGBlendModeNormal). }
function CGBlendForMode(const Mode: string): LongInt;

{ Perspective-warp a premultiplied source texture (pw x ph) onto a quad given in
  destination-buffer pixel coords ([TLx,TLy, TRx,TRy, BRx,BRy, BLx,BLy]). Writes
  8-bit premultiplied RGBA into dst (dpw x dph, dpw*4 bytes/row). }
procedure WarpQuad(src: PSingleBuf; pw, ph: Integer;
  const Quad: array of Single; dst: PByte; dpw, dph: Integer);

{ Extra padding (px) a filter layer needs so a blur / drop-shadow isn't clipped
  at the box edge (reads blur radius + drop-shadow blur/offset). }
function FilterLayerPad(const Spec: string): Single;

implementation

function Half2Single(h: Word): Single;
var sgn, exp, man: LongWord; f: LongWord;
begin
  sgn := (h and $8000) shl 16;
  exp := (h shr 10) and $1F;
  man := h and $3FF;
  if exp = 0 then
  begin
    if man = 0 then f := sgn
    else
    begin
      exp := 127 - 15 + 1;
      while (man and $400) = 0 do begin man := man shl 1; Dec(exp); end;
      man := man and $3FF;
      f := sgn or (exp shl 23) or (man shl 13);
    end;
  end
  else if exp = $1F then f := sgn or $7F800000 or (man shl 13)
  else f := sgn or ((exp - 15 + 127) shl 23) or (man shl 13);
  Result := PSingle(@f)^;
end;

function Single2Half(s: Single): Word;
var f, sgn, man: LongWord; exp: LongInt;
begin
  f := PLongWord(@s)^;
  sgn := (f shr 16) and $8000;
  exp := LongInt((f shr 23) and $FF) - 127 + 15;
  man := f and $7FFFFF;
  if exp <= 0 then
  begin
    if exp < -10 then Exit(Word(sgn));
    man := man or $800000;
    man := man shr (1 - exp + 13);
    Exit(Word(sgn or man));
  end
  else if exp >= $1F then Exit(Word(sgn or $7C00))
  else Result := Word(sgn or (LongWord(exp) shl 10) or (man shr 13));
end;

function CGBlendForMode(const Mode: string): LongInt;
begin
  // CoreGraphics CGBlendMode enum values (stable): Normal=0, Multiply=1, …
  if Mode = 'multiply' then Result := 1
  else if Mode = 'screen' then Result := 2
  else if Mode = 'overlay' then Result := 3
  else if Mode = 'darken' then Result := 4
  else if Mode = 'lighten' then Result := 5
  else if Mode = 'color-dodge' then Result := 6
  else if Mode = 'color-burn' then Result := 7
  else if Mode = 'soft-light' then Result := 8
  else if Mode = 'hard-light' then Result := 9
  else if Mode = 'difference' then Result := 10
  else if Mode = 'exclusion' then Result := 11
  else if Mode = 'hue' then Result := 12
  else if Mode = 'saturation' then Result := 13
  else if Mode = 'color' then Result := 14
  else if Mode = 'luminosity' then Result := 15
  else Result := 0;   // normal
end;

function FilterArg(const S: string; DefV: Single): Single;
var t, num: string; i: Integer; pct: Boolean;
begin
  t := Trim(S); num := ''; pct := False;
  for i := 1 to Length(t) do
    if t[i] in ['0'..'9', '.', '-'] then num := num + t[i]
    else if t[i] = '%' then pct := True;
  if num = '' then Exit(DefV);
  Result := StrToFloatDef(num, DefV);
  if pct then Result := Result / 100;
end;

function FilterLayerPad(const Spec: string): Single;
var s, num: string; p, q, i: Integer; r: Single;
begin
  Result := 0;
  s := LowerCase(Spec);
  p := Pos('blur(', s);
  if p > 0 then
  begin
    q := p + 5; num := '';
    while (q <= Length(s)) and (s[q] in ['0'..'9', '.']) do begin num := num + s[q]; Inc(q); end;
    r := StrToFloatDef(num, 0);
    if r * 3 + 2 > Result then Result := r * 3 + 2;
  end;
  p := Pos('drop-shadow(', s);
  if p > 0 then
  begin
    q := p + 12;
    for i := 1 to 3 do
    begin
      while (q <= Length(s)) and (s[q] = ' ') do Inc(q);
      num := '';
      while (q <= Length(s)) and (s[q] in ['0'..'9', '.', '-']) do begin num := num + s[q]; Inc(q); end;
      while (q <= Length(s)) and (s[q] in ['a'..'z', '%']) do Inc(q);
      r := Abs(StrToFloatDef(num, 0));
      if i = 3 then r := r * 3;
      if r + 2 > Result then Result := r + 2;
    end;
  end;
end;

function SplitTopLevel(const S: string): TStringArray;
var i, depth, start, cnt: Integer;
begin
  SetLength(Result, 0); depth := 0; start := 1; cnt := 0;
  for i := 1 to Length(S) do
  begin
    if S[i] = '(' then Inc(depth)
    else if S[i] = ')' then Dec(depth)
    else if (S[i] = ',') and (depth = 0) then
    begin
      SetLength(Result, cnt + 1); Result[cnt] := Copy(S, start, i - start); Inc(cnt);
      start := i + 1;
    end;
  end;
  SetLength(Result, cnt + 1); Result[cnt] := Copy(S, start, Length(S) - start + 1);
end;

procedure ParseCssColor(const S: string; out r, g, b, a: Single);
var t, body: string; p, q: Integer; parts: TStringArray;
begin
  r := 0; g := 0; b := 0; a := 1;
  t := LowerCase(Trim(S));
  if t = '' then Exit;
  if t = 'transparent' then begin a := 0; Exit; end;
  if t[1] = '#' then
  begin
    Delete(t, 1, 1);
    if Length(t) = 3 then t := t[1]+t[1]+t[2]+t[2]+t[3]+t[3];
    if Length(t) >= 6 then
    begin
      r := StrToIntDef('$' + Copy(t,1,2), 0) / 255;
      g := StrToIntDef('$' + Copy(t,3,2), 0) / 255;
      b := StrToIntDef('$' + Copy(t,5,2), 0) / 255;
    end;
  end
  else if t.StartsWith('rgb') then
  begin
    p := Pos('(', t); q := Pos(')', t);
    if (p > 0) and (q > p) then
    begin
      body := Copy(t, p + 1, q - p - 1);
      parts := body.Split([',']);
      if Length(parts) >= 3 then
      begin
        r := StrToFloatDef(Trim(parts[0]), 0) / 255;
        g := StrToFloatDef(Trim(parts[1]), 0) / 255;
        b := StrToFloatDef(Trim(parts[2]), 0) / 255;
      end;
      if Length(parts) >= 4 then a := StrToFloatDef(Trim(parts[3]), 1);
    end;
  end
  else if t = 'white' then begin r := 1; g := 1; b := 1; end
  else if t = 'red' then r := 1
  else if t = 'green' then g := 0.5
  else if t = 'blue' then b := 1;
end;

procedure BoxBlurFloat(buf: PSingleBuf; pw, ph, radius: Integer);
var tmp: PSingleBuf; pass, y, x, c, i0, i1, k, row: Integer; win, acc: Single;
begin
  if radius < 1 then Exit;
  win := radius * 2 + 1;
  GetMem(tmp, pw * ph * 4 * SizeOf(Single));
  try
    for pass := 1 to 3 do
    begin
      for y := 0 to ph - 1 do
      begin
        row := y * pw * 4;
        for c := 0 to 3 do
        begin
          acc := 0;
          for k := -radius to radius do
          begin i0 := k; if i0 < 0 then i0 := 0; if i0 > pw - 1 then i0 := pw - 1;
            acc := acc + buf[row + i0 * 4 + c]; end;
          for x := 0 to pw - 1 do
          begin
            tmp[row + x * 4 + c] := acc / win;
            i0 := x - radius;    if i0 < 0 then i0 := 0; if i0 > pw - 1 then i0 := pw - 1;
            i1 := x + radius + 1; if i1 < 0 then i1 := 0; if i1 > pw - 1 then i1 := pw - 1;
            acc := acc + buf[row + i1 * 4 + c] - buf[row + i0 * 4 + c];
          end;
        end;
      end;
      for x := 0 to pw - 1 do
        for c := 0 to 3 do
        begin
          acc := 0;
          for k := -radius to radius do
          begin i0 := k; if i0 < 0 then i0 := 0; if i0 > ph - 1 then i0 := ph - 1;
            acc := acc + tmp[(i0 * pw + x) * 4 + c]; end;
          for y := 0 to ph - 1 do
          begin
            buf[(y * pw + x) * 4 + c] := acc / win;
            i0 := y - radius;    if i0 < 0 then i0 := 0; if i0 > ph - 1 then i0 := ph - 1;
            i1 := y + radius + 1; if i1 < 0 then i1 := 0; if i1 > ph - 1 then i1 := ph - 1;
            acc := acc + tmp[(i1 * pw + x) * 4 + c] - tmp[(i0 * pw + x) * 4 + c];
          end;
        end;
    end;
  finally
    FreeMem(tmp);
  end;
end;

procedure BoxBlurFloat1(buf: PSingleBuf; pw, ph, radius: Integer);
var tmp: PSingleBuf; pass, y, x, i0, i1, k: Integer; win, acc: Single;
begin
  if radius < 1 then Exit;
  win := radius * 2 + 1;
  GetMem(tmp, pw * ph * SizeOf(Single));
  try
    for pass := 1 to 3 do
    begin
      for y := 0 to ph - 1 do
      begin
        acc := 0;
        for k := -radius to radius do
        begin i0 := k; if i0 < 0 then i0 := 0; if i0 > pw - 1 then i0 := pw - 1;
          acc := acc + buf[y * pw + i0]; end;
        for x := 0 to pw - 1 do
        begin
          tmp[y * pw + x] := acc / win;
          i0 := x - radius;    if i0 < 0 then i0 := 0; if i0 > pw - 1 then i0 := pw - 1;
          i1 := x + radius + 1; if i1 < 0 then i1 := 0; if i1 > pw - 1 then i1 := pw - 1;
          acc := acc + buf[y * pw + i1] - buf[y * pw + i0];
        end;
      end;
      for x := 0 to pw - 1 do
      begin
        acc := 0;
        for k := -radius to radius do
        begin i0 := k; if i0 < 0 then i0 := 0; if i0 > ph - 1 then i0 := ph - 1;
          acc := acc + tmp[i0 * pw + x]; end;
        for y := 0 to ph - 1 do
        begin
          buf[y * pw + x] := acc / win;
          i0 := y - radius;    if i0 < 0 then i0 := 0; if i0 > ph - 1 then i0 := ph - 1;
          i1 := y + radius + 1; if i1 < 0 then i1 := 0; if i1 > ph - 1 then i1 := ph - 1;
          acc := acc + tmp[(i1 * pw + x)] - tmp[(i0 * pw + x)];
        end;
      end;
    end;
  finally
    FreeMem(tmp);
  end;
end;

procedure ColorOp(buf: PSingleBuf; pw, ph, Kind: Integer; A: Single);
var j, k2: Integer; r, g, b, al, nr, ng, nb, lum, cs2, sn: Single;
begin
  for j := 0 to pw * ph - 1 do
  begin
    k2 := j * 4; al := buf[k2 + 3];
    if al <= 0 then
    begin
      if Kind = 7 then buf[k2 + 3] := al * A;
      Continue;
    end;
    r := buf[k2] / al; g := buf[k2 + 1] / al; b := buf[k2 + 2] / al;
    case Kind of
      0: begin lum := 0.2126*r + 0.7152*g + 0.0722*b;
           r := r + (lum - r)*A; g := g + (lum - g)*A; b := b + (lum - b)*A; end;
      1: begin r := r*A; g := g*A; b := b*A; end;
      2: begin r := (r-0.5)*A+0.5; g := (g-0.5)*A+0.5; b := (b-0.5)*A+0.5; end;
      3: begin r := r*(1-A) + (1-r)*A; g := g*(1-A) + (1-g)*A; b := b*(1-A) + (1-b)*A; end;
      4: begin lum := 0.2126*r + 0.7152*g + 0.0722*b;
           r := lum + (r-lum)*A; g := lum + (g-lum)*A; b := lum + (b-lum)*A; end;
      5: begin nr := 0.393*r + 0.769*g + 0.189*b; ng := 0.349*r + 0.686*g + 0.168*b;
           nb := 0.272*r + 0.534*g + 0.131*b;
           r := r + (nr-r)*A; g := g + (ng-g)*A; b := b + (nb-b)*A; end;
      6: begin cs2 := Cos(A); sn := Sin(A);
           nr := (0.213+cs2*0.787-sn*0.213)*r + (0.715-cs2*0.715-sn*0.715)*g + (0.072-cs2*0.072+sn*0.928)*b;
           ng := (0.213-cs2*0.213+sn*0.143)*r + (0.715+cs2*0.285+sn*0.140)*g + (0.072-cs2*0.072-sn*0.283)*b;
           nb := (0.213-cs2*0.213-sn*0.787)*r + (0.715-cs2*0.715+sn*0.715)*g + (0.072+cs2*0.928+sn*0.072)*b;
           r := nr; g := ng; b := nb; end;
      7: al := al * A;
    end;
    if r < 0 then r := 0; if r > 1 then r := 1;
    if g < 0 then g := 0; if g > 1 then g := 1;
    if b < 0 then b := 0; if b > 1 then b := 1;
    if al < 0 then al := 0; if al > 1 then al := 1;
    buf[k2] := r*al; buf[k2+1] := g*al; buf[k2+2] := b*al; buf[k2+3] := al;
  end;
end;

procedure DropShadow(buf: PSingleBuf; pw, ph, dx, dy, blur: Integer; r, g, b, a: Single);
var sa: PSingleBuf; j, x, y, sx, sy: Integer; ea, sr, sg, sb, sav: Single;
begin
  GetMem(sa, pw * ph * SizeOf(Single));
  try
    for y := 0 to ph - 1 do
      for x := 0 to pw - 1 do
      begin
        sx := x - dx; sy := y - dy;
        if (sx >= 0) and (sx < pw) and (sy >= 0) and (sy < ph) then
          sa[y * pw + x] := buf[(sy * pw + sx) * 4 + 3]
        else sa[y * pw + x] := 0;
      end;
    if blur > 0 then BoxBlurFloat1(sa, pw, ph, blur);
    for j := 0 to pw * ph - 1 do
    begin
      sav := sa[j] * a;
      sr := r * sav; sg := g * sav; sb := b * sav;
      ea := buf[j*4+3];
      buf[j*4]   := buf[j*4]   + sr * (1 - ea);
      buf[j*4+1] := buf[j*4+1] + sg * (1 - ea);
      buf[j*4+2] := buf[j*4+2] + sb * (1 - ea);
      buf[j*4+3] := ea + sav * (1 - ea);
    end;
  finally
    FreeMem(sa);
  end;
end;

procedure ApplyGradientMask(buf: PSingleBuf; pw, ph: Integer; const M: string);
var
  inner, dir, stopStr: string; body: TStringArray;
  x, y, j, si, nstops: Integer;
  dirDx, dirDy, t, mv, r2, g2, b2, a2, prevPos, prevA, segT, angDeg: Single;
  stopA, stopP: array of Single; hasPos: array of Boolean;
  p2, q2, o: Integer;
begin
  j := Pos('(', M); if j = 0 then Exit;
  inner := Copy(M, j + 1, MaxInt);
  j := LastDelimiter(')', inner); if j > 0 then inner := Copy(inner, 1, j - 1);
  body := SplitTopLevel(inner);
  if Length(body) = 0 then Exit;
  dirDx := 0; dirDy := 1; si := 0;
  dir := LowerCase(Trim(body[0]));
  if dir.StartsWith('to ') or dir.EndsWith('deg') then
  begin
    si := 1;
    if dir.EndsWith('deg') then
    begin
      angDeg := StrToFloatDef(Trim(Copy(dir, 1, Length(dir) - 3)), 180);
      dirDx := Sin(angDeg * Pi / 180); dirDy := -Cos(angDeg * Pi / 180);
    end
    else if Pos('right', dir) > 0 then begin dirDx := 1; dirDy := 0; end
    else if Pos('left', dir) > 0 then begin dirDx := -1; dirDy := 0; end
    else if Pos('top', dir) > 0 then begin dirDx := 0; dirDy := -1; end
    else begin dirDx := 0; dirDy := 1; end;
  end;
  nstops := Length(body) - si;
  if nstops < 1 then Exit;
  SetLength(stopA, nstops); SetLength(stopP, nstops); SetLength(hasPos, nstops);
  for j := 0 to nstops - 1 do
  begin
    stopStr := Trim(body[si + j]);
    p2 := Pos('%', stopStr);
    hasPos[j] := p2 > 0;
    if hasPos[j] then
    begin
      q2 := p2 - 1; while (q2 > 1) and (stopStr[q2] <> ' ') do Dec(q2);
      stopP[j] := StrToFloatDef(Trim(Copy(stopStr, q2, p2 - q2)), 0) / 100;
      stopStr := Trim(Copy(stopStr, 1, q2));
    end;
    ParseCssColor(stopStr, r2, g2, b2, a2);
    stopA[j] := a2;
  end;
  if not hasPos[0] then begin stopP[0] := 0; hasPos[0] := True; end;
  if not hasPos[nstops - 1] then begin stopP[nstops - 1] := 1; hasPos[nstops - 1] := True; end;
  for j := 1 to nstops - 2 do
    if not hasPos[j] then stopP[j] := j / (nstops - 1);
  for y := 0 to ph - 1 do
    for x := 0 to pw - 1 do
    begin
      t := ((x / pw - 0.5) * dirDx + (y / ph - 0.5) * dirDy) + 0.5;
      if t < 0 then t := 0; if t > 1 then t := 1;
      mv := stopA[0]; prevPos := stopP[0]; prevA := stopA[0];
      for si := 1 to nstops - 1 do
      begin
        if t <= stopP[si] then
        begin
          if stopP[si] > prevPos then segT := (t - prevPos) / (stopP[si] - prevPos) else segT := 0;
          mv := prevA + (stopA[si] - prevA) * segT;
          Break;
        end;
        prevPos := stopP[si]; prevA := stopA[si]; mv := stopA[si];
      end;
      o := (y * pw + x) * 4;
      buf[o] := buf[o] * mv; buf[o+1] := buf[o+1] * mv;
      buf[o+2] := buf[o+2] * mv; buf[o+3] := buf[o+3] * mv;
    end;
end;

procedure ApplyFilterChainF(buf: PSingleBuf; pw, ph: Integer;
  const FilterSpec, MaskSpec: string; Scale: Single);
var
  s, fn, arg: string; p, q, depth: Integer;
  toks: TStringArray; sdx, sdy, sblur, i2: Integer; sr, sg, sb, sa2: Single; col: string;
begin
  s := LowerCase(FilterSpec); p := 1;
  while p <= Length(s) do
  begin
    if not (s[p] in ['a'..'z', '-']) then begin Inc(p); Continue; end;
    q := p;
    while (q <= Length(s)) and (s[q] in ['a'..'z', '-']) do Inc(q);
    fn := Copy(s, p, q - p);
    if (q > Length(s)) or (s[q] <> '(') then begin p := q; Continue; end;
    Inc(q); depth := 1; arg := '';
    while (q <= Length(s)) and (depth > 0) do
    begin
      if s[q] = '(' then Inc(depth)
      else if s[q] = ')' then begin Dec(depth); if depth = 0 then Break; end;
      arg := arg + s[q]; Inc(q);
    end;
    p := q + 1;
    if fn = 'blur' then BoxBlurFloat(buf, pw, ph, Round(FilterArg(arg, 0) * Scale))
    else if fn = 'grayscale' then ColorOp(buf, pw, ph, 0, FilterArg(arg, 1))
    else if fn = 'brightness' then ColorOp(buf, pw, ph, 1, FilterArg(arg, 1))
    else if fn = 'contrast' then ColorOp(buf, pw, ph, 2, FilterArg(arg, 1))
    else if fn = 'invert' then ColorOp(buf, pw, ph, 3, FilterArg(arg, 1))
    else if fn = 'saturate' then ColorOp(buf, pw, ph, 4, FilterArg(arg, 1))
    else if fn = 'sepia' then ColorOp(buf, pw, ph, 5, FilterArg(arg, 1))
    else if fn = 'hue-rotate' then ColorOp(buf, pw, ph, 6, FilterArg(arg, 0) * Pi / 180)
    else if fn = 'opacity' then ColorOp(buf, pw, ph, 7, FilterArg(arg, 1))
    else if fn = 'drop-shadow' then
    begin
      toks := Trim(arg).Split([' '], TStringSplitOptions.ExcludeEmpty);
      sdx := 0; sdy := 0; sblur := 0; sr := 0; sg := 0; sb := 0; sa2 := 1;
      if Length(toks) >= 1 then sdx := Round(FilterArg(toks[0], 0) * Scale);
      if Length(toks) >= 2 then sdy := Round(FilterArg(toks[1], 0) * Scale);
      if Length(toks) >= 3 then sblur := Round(FilterArg(toks[2], 0) * Scale);
      if Length(toks) >= 4 then
      begin
        col := toks[3]; for i2 := 4 to High(toks) do col := col + toks[i2];
        ParseCssColor(col, sr, sg, sb, sa2);
      end;
      DropShadow(buf, pw, ph, sdx, sdy, sblur, sr, sg, sb, sa2);
    end;
  end;
  if (MaskSpec <> '') and (Pos('gradient(', LowerCase(MaskSpec)) > 0) then
    ApplyGradientMask(buf, pw, ph, MaskSpec);
end;

procedure WarpQuad(src: PSingleBuf; pw, ph: Integer;
  const Quad: array of Single; dst: PByte; dpw, dph: Integer);
var
  qx, qy: array[0..3] of Single;
  sx, sy, dx1, dx2, dy1, dy2, den, ga, hb, aa, bb, cc, dd, ee, ff: Single;
  det, ia, ib, ic, id, ie, ig, ih, ii, idd, idd2: Single;
  x, y, sxi, syi, i: Integer;
  u, v, wv, fx, fy, tx0, ty0, wx, wy: Single;
  r0, g0, b0, a0, r1, g1, b1, a1: Single;

  function Samp(bx, by, ch: Integer): Single;
  begin
    if bx < 0 then bx := 0; if bx > pw - 1 then bx := pw - 1;
    if by < 0 then by := 0; if by > ph - 1 then by := ph - 1;
    Samp := src[(by * pw + bx) * 4 + ch];
  end;

begin
  for i := 0 to 3 do begin qx[i] := Quad[i*2]; qy[i] := Quad[i*2+1]; end;
  sx := qx[0] - qx[1] + qx[2] - qx[3];
  sy := qy[0] - qy[1] + qy[2] - qy[3];
  if (Abs(sx) < 1e-6) and (Abs(sy) < 1e-6) then
  begin
    aa := qx[1]-qx[0]; bb := qx[3]-qx[0]; cc := qx[0];
    dd := qy[1]-qy[0]; ee := qy[3]-qy[0]; ff := qy[0]; ga := 0; hb := 0;
  end
  else
  begin
    dx1 := qx[1]-qx[2]; dx2 := qx[3]-qx[2]; dy1 := qy[1]-qy[2]; dy2 := qy[3]-qy[2];
    den := dx1*dy2 - dy1*dx2; if Abs(den) < 1e-9 then den := 1e-9;
    ga := (sx*dy2 - sy*dx2)/den; hb := (dx1*sy - dy1*sx)/den;
    aa := qx[1]-qx[0]+ga*qx[1]; bb := qx[3]-qx[0]+hb*qx[3]; cc := qx[0];
    dd := qy[1]-qy[0]+ga*qy[1]; ee := qy[3]-qy[0]+hb*qy[3]; ff := qy[0];
  end;
  det := aa*(ee - ff*hb) - bb*(dd - ff*ga) + cc*(dd*hb - ee*ga);
  if Abs(det) < 1e-12 then det := 1e-12;
  idd2 := 1/det;
  ia := (ee - ff*hb)*idd2;  ib := -(bb - cc*hb)*idd2; ic := (bb*ff - cc*ee)*idd2;
  id := -(dd - ff*ga)*idd2; ie := (aa - cc*ga)*idd2;  ig := -(aa*ff - cc*dd)*idd2;
  ih := (dd*hb - ee*ga)*idd2; ii := -(aa*hb - bb*ga)*idd2; idd := (aa*ee - bb*dd)*idd2;
  for y := 0 to dph - 1 do
    for x := 0 to dpw - 1 do
    begin
      fx := x + 0.5; fy := y + 0.5;
      wv := ih*fx + ii*fy + idd;
      if Abs(wv) < 1e-9 then Continue;
      u := (ia*fx + ib*fy + ic) / wv;
      v := (id*fx + ie*fy + ig) / wv;
      if (u < 0) or (u > 1) or (v < 0) or (v > 1) then Continue;
      tx0 := u * (pw - 1); ty0 := v * (ph - 1);
      sxi := Trunc(tx0); syi := Trunc(ty0); wx := tx0 - sxi; wy := ty0 - syi;
      r0 := Samp(sxi,syi,0)*(1-wx)+Samp(sxi+1,syi,0)*wx;
      g0 := Samp(sxi,syi,1)*(1-wx)+Samp(sxi+1,syi,1)*wx;
      b0 := Samp(sxi,syi,2)*(1-wx)+Samp(sxi+1,syi,2)*wx;
      a0 := Samp(sxi,syi,3)*(1-wx)+Samp(sxi+1,syi,3)*wx;
      r1 := Samp(sxi,syi+1,0)*(1-wx)+Samp(sxi+1,syi+1,0)*wx;
      g1 := Samp(sxi,syi+1,1)*(1-wx)+Samp(sxi+1,syi+1,1)*wx;
      b1 := Samp(sxi,syi+1,2)*(1-wx)+Samp(sxi+1,syi+1,2)*wx;
      a1 := Samp(sxi,syi+1,3)*(1-wx)+Samp(sxi+1,syi+1,3)*wx;
      i := (y*dpw + x)*4;
      dst[i]   := Round((r0*(1-wy)+r1*wy)*255);
      dst[i+1] := Round((g0*(1-wy)+g1*wy)*255);
      dst[i+2] := Round((b0*(1-wy)+b1*wy)*255);
      dst[i+3] := Round((a0*(1-wy)+a1*wy)*255);
    end;
end;

end.
