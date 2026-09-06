unit Tina4CanvasPdf;

{ A TTina4Canvas that renders into a PDF instead of a screen — so the SAME engine
  (parse → layout → paint) exports HTML to a real PDF, headless, on every platform,
  with NO GUI toolkit. The canvas contract is the only surface, so anything the
  engine draws it can write to PDF.

  One page sized to the laid-out document (width × content height). PDF's origin is
  bottom-left / y-up; the engine is top-left / y-down, so the content starts with a
  flip CTM and everything else is emitted in engine points. Text uses the base-14
  fonts (Helvetica / Times / Courier) with their standard metrics for MeasureText
  and a per-run flip text matrix so glyphs stay upright. Vector fills/strokes map to
  path operators; the Lottie/<canvas> raster (DrawRGBA) embeds as an image XObject
  with a soft-mask for alpha. Filters / blend / 3D degrade to a flat draw; external
  <img> is skipped in v1 (a pure-Pascal PNG/WebP decoder can feed LoadImage later). }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, Math, zstream, Tina4RenderBackend;

type
  TTina4CanvasPdf = class(TTina4Canvas)
  private
    FW, FH: Single;                    // page size in points
    FBuf: TStringList;                 // content-stream fragments
    FImgW, FImgH: array of Integer;    // embedded image pixel sizes (from DrawRGBA)
    FImgData: array of TBytes;         // embedded image RGBA (straight)
    FAlphas: array of Single;          // distinct alphas → ExtGState
    function AlphaGS(A: Single): Integer;
    procedure Emit(const S: string);
    procedure EmitColor(Color: TTina4Color; Stroke: Boolean);
    procedure PathRect(X, Y, W, H: Single);
    procedure PathRound(X, Y, W, H, R: Single);
    function EscapeStr(const S: string): string;
    function EmbedRGBA(const RGBA: TBytes; W, H: Integer): Integer;  // → image slot (1-based)
  public
    constructor Create(WidthPt, HeightPt: Single);
    destructor Destroy; override;
    procedure SetPageSize(WidthPt, HeightPt: Single);   // set after layout (content height)
    procedure SaveToFile(const Path: string);
    procedure SaveToStream(Stream: TStream);
    procedure FillRect(X, Y, W, H: Single; Color: TTina4Color); override;
    procedure StrokeRect(X, Y, W, H, Thickness: Single; Color: TTina4Color); override;
    procedure FillRoundRect(X, Y, W, H, Radius: Single; Color: TTina4Color); override;
    procedure StrokeRoundRect(X, Y, W, H, Radius, Thickness: Single; Color: TTina4Color); override;
    procedure DrawLine(X1, Y1, X2, Y2, Thickness: Single; Color: TTina4Color); override;
    procedure FillPolygon(const Contours: array of TTina4PointArray;
      Color: TTina4Color; EvenOdd: Boolean = False); override;
    procedure StrokePolyline(const Pts: TTina4PointArray; Width: Single;
      Color: TTina4Color; Closed: Boolean); override;
    procedure DrawText(X, Y: Single; const Text: string; FontSize: Single;
      Styles: TTina4FontStyles; Color: TTina4Color); override;
    function MeasureText(const Text: string; FontSize: Single;
      Styles: TTina4FontStyles): TTina4TextMetrics; override;
    procedure SetClip(X, Y, W, H: Single); override;
    procedure ClearClip; override;
    procedure SaveState; override;
    procedure RestoreState; override;
    procedure Translate(DX, DY: Single); override;
    procedure Scale(SX, SY: Single); override;
    procedure Rotate(Degrees: Single); override;
    procedure TransformMatrix(A, B, C, D, E, F: Single); override;
    { DrawText/MeasureText are text; images: only the raster path embeds in v1 }
    function SupportsRGBA: Boolean; override;
    procedure DrawRGBA(Buf: Pointer; BW, BH: Integer; DX, DY, DW, DH: Single); override;
  end;

implementation

{ Base-14 Helvetica advance widths (AFM, /1000 em) for WinAnsi 32..126; the rest
  default to 556. Courier is monospace 600. Enough for faithful line breaking. }
const
  HELV: array[32..126] of Integer = (
    278,278,355,556,556,889,667,191,333,333,389,584,278,333,278,278,
    556,556,556,556,556,556,556,556,556,556,278,278,584,584,584,556,
    1015,667,667,722,722,667,611,778,722,278,500,667,556,833,722,778,
    667,778,722,667,611,722,667,944,667,667,611,333,278,333,469,556,
    333,556,556,500,556,556,278,556,556,222,222,500,222,833,556,556,
    556,556,333,500,278,556,500,722,500,500,500,334,260,334,584);
  HELVB: array[32..126] of Integer = (
    278,333,474,556,556,889,722,238,333,333,389,584,278,333,278,278,
    556,556,556,556,556,556,556,556,556,556,333,333,584,584,584,611,
    975,722,722,722,722,667,611,778,722,278,556,722,611,833,722,778,
    667,778,722,667,611,722,667,944,667,667,611,333,278,333,584,556,
    333,556,611,556,611,556,333,611,611,278,278,556,278,889,611,611,
    611,611,389,556,333,611,556,778,556,556,500,389,280,389,584);

function CharW(c: Integer; mono, bold: Boolean): Integer;
begin
  if mono then Exit(600);
  if (c >= 32) and (c <= 126) then
  begin
    if bold then Result := HELVB[c] else Result := HELV[c];
  end
  else Result := 556;
end;

function Octal3(v: Integer): string;
begin
  Result := IntToStr((v shr 6) and 7) + IntToStr((v shr 3) and 7) + IntToStr(v and 7);
end;

{ pick base-14 resource name: sans→He, serif→Ti, monospace→Co + bold/italic }
function FontRes(const Family: string; Styles: TTina4FontStyles; out mono: Boolean): string;
var f: string; bold, ital: Boolean;
begin
  f := LowerCase(Family); mono := False;
  bold := tfsBold in Styles; ital := tfsItalic in Styles;
  if (Pos('mono', f) > 0) or (Pos('courier', f) > 0) or (Pos('consol', f) > 0) then
  begin
    mono := True;
    if bold and ital then Result := 'CoBI' else if bold then Result := 'CoB'
    else if ital then Result := 'CoOb' else Result := 'Co';
  end
  else if ((Pos('serif', f) > 0) and (Pos('sans', f) = 0)) or (Pos('times', f) > 0)
       or (Pos('georgia', f) > 0) then
  begin
    if bold and ital then Result := 'TiBI' else if bold then Result := 'TiB'
    else if ital then Result := 'TiI' else Result := 'Ti';
  end
  else
  begin
    if bold and ital then Result := 'HeBO' else if bold then Result := 'HeB'
    else if ital then Result := 'HeO' else Result := 'He';
  end;
end;

function Base14For(const Res: string): string;
begin
  if Res = 'He' then Result := 'Helvetica'
  else if Res = 'HeB' then Result := 'Helvetica-Bold'
  else if Res = 'HeO' then Result := 'Helvetica-Oblique'
  else if Res = 'HeBO' then Result := 'Helvetica-BoldOblique'
  else if Res = 'Ti' then Result := 'Times-Roman'
  else if Res = 'TiB' then Result := 'Times-Bold'
  else if Res = 'TiI' then Result := 'Times-Italic'
  else if Res = 'TiBI' then Result := 'Times-BoldItalic'
  else if Res = 'Co' then Result := 'Courier'
  else if Res = 'CoB' then Result := 'Courier-Bold'
  else if Res = 'CoOb' then Result := 'Courier-Oblique'
  else if Res = 'CoBI' then Result := 'Courier-BoldOblique'
  else Result := 'Helvetica';
end;

const FONT_RES: array[0..11] of string =
  ('He','HeB','HeO','HeBO','Ti','TiB','TiI','TiBI','Co','CoB','CoOb','CoBI');

{ ---- construction ------------------------------------------------------ }

constructor TTina4CanvasPdf.Create(WidthPt, HeightPt: Single);
begin
  inherited Create;
  FW := WidthPt; FH := HeightPt;
  FBuf := TStringList.Create;
  // the page-flip (top-left y-down → PDF bottom-left y-up) is prepended at save
  // time, so the height can be set after layout (SetPageSize).
end;

procedure TTina4CanvasPdf.SetPageSize(WidthPt, HeightPt: Single);
begin
  if WidthPt > 0 then FW := WidthPt;
  if HeightPt > 0 then FH := HeightPt;
end;

destructor TTina4CanvasPdf.Destroy;
begin
  FBuf.Free;
  inherited Destroy;
end;

procedure TTina4CanvasPdf.Emit(const S: string); begin FBuf.Add(S); end;

{ ---- colours + alpha --------------------------------------------------- }

function TTina4CanvasPdf.AlphaGS(A: Single): Integer;
var i: Integer;
begin
  if A > 1 then A := 1; if A < 0 then A := 0;
  for i := 0 to High(FAlphas) do if Abs(FAlphas[i] - A) < 0.002 then Exit(i);
  SetLength(FAlphas, Length(FAlphas) + 1); FAlphas[High(FAlphas)] := A;
  Result := High(FAlphas);
end;

procedure TTina4CanvasPdf.EmitColor(Color: TTina4Color; Stroke: Boolean);
var r, g, b, a: Single;
begin
  a := ((Color shr 24) and $FF) / 255;
  r := ((Color shr 16) and $FF) / 255;
  g := ((Color shr 8) and $FF) / 255;
  b := (Color and $FF) / 255;
  Emit(Format('/GS%d gs', [AlphaGS(a)]));
  if Stroke then Emit(Format('%.3f %.3f %.3f RG', [r, g, b]))
  else Emit(Format('%.3f %.3f %.3f rg', [r, g, b]));
end;

{ ---- paths ------------------------------------------------------------- }

procedure TTina4CanvasPdf.PathRect(X, Y, W, H: Single);
begin Emit(Format('%.2f %.2f %.2f %.2f re', [X, Y, W, H])); end;

procedure TTina4CanvasPdf.PathRound(X, Y, W, H, R: Single);
const K = 0.5522847498;
var x2, y2, kr: Single;
begin
  if R > W / 2 then R := W / 2; if R > H / 2 then R := H / 2;
  if R <= 0 then begin PathRect(X, Y, W, H); Exit; end;
  x2 := X + W; y2 := Y + H; kr := R * K;
  Emit(Format('%.2f %.2f m', [X + R, Y]));
  Emit(Format('%.2f %.2f l', [x2 - R, Y]));
  Emit(Format('%.2f %.2f %.2f %.2f %.2f %.2f c', [x2 - R + kr, Y, x2, Y + R - kr, x2, Y + R]));
  Emit(Format('%.2f %.2f l', [x2, y2 - R]));
  Emit(Format('%.2f %.2f %.2f %.2f %.2f %.2f c', [x2, y2 - R + kr, x2 - R + kr, y2, x2 - R, y2]));
  Emit(Format('%.2f %.2f l', [X + R, y2]));
  Emit(Format('%.2f %.2f %.2f %.2f %.2f %.2f c', [X + R - kr, y2, X, y2 - R + kr, X, y2 - R]));
  Emit(Format('%.2f %.2f l', [X, Y + R]));
  Emit(Format('%.2f %.2f %.2f %.2f %.2f %.2f c', [X, Y + R - kr, X + R - kr, Y, X + R, Y]));
  Emit('h');
end;

{ ---- shapes ------------------------------------------------------------ }

procedure TTina4CanvasPdf.FillRect(X, Y, W, H: Single; Color: TTina4Color);
begin EmitColor(Color, False); PathRect(X, Y, W, H); Emit('f'); end;

procedure TTina4CanvasPdf.StrokeRect(X, Y, W, H, Thickness: Single; Color: TTina4Color);
begin
  EmitColor(Color, True); Emit(Format('%.2f w', [Thickness]));
  PathRect(X + Thickness / 2, Y + Thickness / 2, W - Thickness, H - Thickness); Emit('S');
end;

procedure TTina4CanvasPdf.FillRoundRect(X, Y, W, H, Radius: Single; Color: TTina4Color);
begin EmitColor(Color, False); PathRound(X, Y, W, H, Radius); Emit('f'); end;

procedure TTina4CanvasPdf.StrokeRoundRect(X, Y, W, H, Radius, Thickness: Single; Color: TTina4Color);
begin
  EmitColor(Color, True); Emit(Format('%.2f w', [Thickness]));
  PathRound(X + Thickness / 2, Y + Thickness / 2, W - Thickness, H - Thickness, Radius); Emit('S');
end;

procedure TTina4CanvasPdf.DrawLine(X1, Y1, X2, Y2, Thickness: Single; Color: TTina4Color);
begin
  EmitColor(Color, True); Emit(Format('%.2f w', [Thickness]));
  Emit(Format('%.2f %.2f m %.2f %.2f l S', [X1, Y1, X2, Y2]));
end;

procedure TTina4CanvasPdf.FillPolygon(const Contours: array of TTina4PointArray;
  Color: TTina4Color; EvenOdd: Boolean);
var i, j: Integer;
begin
  EmitColor(Color, False);
  for i := 0 to High(Contours) do
  begin
    if Length(Contours[i]) < 2 then Continue;
    Emit(Format('%.2f %.2f m', [Contours[i][0].X, Contours[i][0].Y]));
    for j := 1 to High(Contours[i]) do Emit(Format('%.2f %.2f l', [Contours[i][j].X, Contours[i][j].Y]));
    Emit('h');
  end;
  if EvenOdd then Emit('f*') else Emit('f');
end;

procedure TTina4CanvasPdf.StrokePolyline(const Pts: TTina4PointArray; Width: Single;
  Color: TTina4Color; Closed: Boolean);
var i: Integer;
begin
  if Length(Pts) < 2 then Exit;
  EmitColor(Color, True); Emit(Format('%.2f w 1 J 1 j', [Width]));
  Emit(Format('%.2f %.2f m', [Pts[0].X, Pts[0].Y]));
  for i := 1 to High(Pts) do Emit(Format('%.2f %.2f l', [Pts[i].X, Pts[i].Y]));
  if Closed then Emit('s') else Emit('S');
end;

{ ---- text -------------------------------------------------------------- }

procedure TTina4CanvasPdf.DrawText(X, Y: Single; const Text: string; FontSize: Single;
  Styles: TTina4FontStyles; Color: TTina4Color);
var mono: Boolean; res: string; baseline: Single; m: TTina4TextMetrics;
begin
  if Text = '' then Exit;
  res := FontRes(FontFamily, Styles, mono);
  m := MeasureText(Text, FontSize, Styles);
  baseline := Y + m.Ascent;
  EmitColor(Color, False);
  Emit('BT');
  Emit(Format('/%s %.2f Tf', [res, FontSize]));
  Emit(Format('1 0 0 -1 %.2f %.2f Tm', [X, baseline]));   // upright under the page flip
  Emit('(' + EscapeStr(Text) + ') Tj');
  Emit('ET');
end;

function TTina4CanvasPdf.MeasureText(const Text: string; FontSize: Single;
  Styles: TTina4FontStyles): TTina4TextMetrics;
var mono, bold: Boolean; i, wsum, cp: Integer;
begin
  FontRes(FontFamily, Styles, mono);
  bold := tfsBold in Styles;
  wsum := 0;
  i := 1;
  while i <= Length(Text) do
  begin
    cp := Ord(Text[i]);
    if cp < 128 then begin wsum := wsum + CharW(cp, mono, bold); Inc(i); end
    else
    begin
      // one UTF-8 codepoint ≈ one average glyph
      wsum := wsum + CharW(Ord('n'), mono, bold);
      if (cp and $E0) = $C0 then Inc(i, 2)
      else if (cp and $F0) = $E0 then Inc(i, 3)
      else if (cp and $F8) = $F0 then Inc(i, 4)
      else Inc(i);
    end;
  end;
  Result.Width := wsum / 1000 * FontSize;
  Result.Ascent := 0.718 * FontSize;
  Result.Descent := 0.207 * FontSize;
  Result.LineHeight := 1.16 * FontSize;
end;

function TTina4CanvasPdf.EscapeStr(const S: string): string;
var i, b, cp: Integer; ch: Char;
begin
  Result := ''; i := 1;
  while i <= Length(S) do
  begin
    ch := S[i]; b := Ord(ch);
    if b < 128 then
    begin
      case ch of
        '(', ')', '\': Result := Result + '\' + ch;
        #13: Result := Result + '\r';
        #10: Result := Result + '\n';
        #9:  Result := Result + '\t';
      else Result := Result + ch;
      end;
      Inc(i);
    end
    else
    begin
      cp := 0;
      if (b and $E0) = $C0 then begin if i+1 <= Length(S) then cp := ((b and $1F) shl 6) or (Ord(S[i+1]) and $3F); Inc(i, 2); end
      else if (b and $F0) = $E0 then begin if i+2 <= Length(S) then cp := ((b and $0F) shl 12) or ((Ord(S[i+1]) and $3F) shl 6) or (Ord(S[i+2]) and $3F); Inc(i, 3); end
      else if (b and $F8) = $F0 then begin cp := $3F; Inc(i, 4); end
      else Inc(i);
      // map common Unicode punctuation to its WinAnsi (CP1252) code
      case cp of
        $2022: cp := 149;   // • bullet
        $2018: cp := 145; $2019: cp := 146;   // ‘ ’
        $201C: cp := 147; $201D: cp := 148;   // “ ”
        $2013: cp := 150; $2014: cp := 151;   // – —
        $2026: cp := 133;                      // …
        $2122: cp := 153; $20AC: cp := 128;   // ™ €
        $00A0: cp := 32;                       // nbsp → space
      end;
      if (cp >= 128) and (cp <= 255) then Result := Result + '\' + Octal3(cp)
      else if cp = 32 then Result := Result + ' '
      else Result := Result + '?';
    end;
  end;
end;

{ ---- state / transforms ------------------------------------------------ }

procedure TTina4CanvasPdf.SaveState;  begin Emit('q'); end;
procedure TTina4CanvasPdf.RestoreState; begin Emit('Q'); end;
procedure TTina4CanvasPdf.Translate(DX, DY: Single); begin Emit(Format('1 0 0 1 %.2f %.2f cm', [DX, DY])); end;
procedure TTina4CanvasPdf.Scale(SX, SY: Single);     begin Emit(Format('%.4f 0 0 %.4f 0 0 cm', [SX, SY])); end;
procedure TTina4CanvasPdf.Rotate(Degrees: Single);
var r, c, s: Single;
begin
  r := Degrees * Pi / 180; c := Cos(r); s := Sin(r);
  Emit(Format('%.5f %.5f %.5f %.5f 0 0 cm', [c, s, -s, c]));
end;
procedure TTina4CanvasPdf.TransformMatrix(A, B, C, D, E, F: Single);
begin Emit(Format('%.5f %.5f %.5f %.5f %.2f %.2f cm', [A, B, C, D, E, F])); end;

procedure TTina4CanvasPdf.SetClip(X, Y, W, H: Single);
begin Emit('q'); PathRect(X, Y, W, H); Emit('W n'); end;
procedure TTina4CanvasPdf.ClearClip; begin Emit('Q'); end;

{ ---- raster image (Lottie / <canvas>) → image XObject ------------------ }

function TTina4CanvasPdf.EmbedRGBA(const RGBA: TBytes; W, H: Integer): Integer;
var i: Integer;
begin
  i := Length(FImgData);
  SetLength(FImgData, i + 1); SetLength(FImgW, i + 1); SetLength(FImgH, i + 1);
  FImgData[i] := RGBA; FImgW[i] := W; FImgH[i] := H;
  Result := i + 1;   // 1-based slot = /ImN
end;

function TTina4CanvasPdf.SupportsRGBA: Boolean; begin Result := True; end;

procedure TTina4CanvasPdf.DrawRGBA(Buf: Pointer; BW, BH: Integer; DX, DY, DW, DH: Single);
var i, slot: Integer; b: PByte; rgba: TBytes;
begin
  if (Buf = nil) or (BW <= 0) or (BH <= 0) then Exit;
  SetLength(rgba, BW * BH * 4); b := PByte(Buf);
  for i := 0 to BW * BH - 1 do
  begin
    rgba[i*4+0] := b[i*4+2];   // source $AARRGGBB LE = bytes B,G,R,A → R
    rgba[i*4+1] := b[i*4+1];   // G
    rgba[i*4+2] := b[i*4+0];   // B
    rgba[i*4+3] := b[i*4+3];   // A
  end;
  slot := EmbedRGBA(rgba, BW, BH);
  Emit('q');
  Emit(Format('%.2f 0 0 %.2f %.2f %.2f cm', [DW, -DH, DX, DY + DH]));  // upright, scaled
  Emit(Format('/Im%d Do', [slot]));
  Emit('Q');
end;

{ ---- PDF assembly ------------------------------------------------------ }

function FlateBytes(const Data: TBytes): TBytes;
var ms: TMemoryStream; cs: TCompressionStream;
begin
  ms := TMemoryStream.Create;
  cs := TCompressionStream.Create(clDefault, ms);
  try
    if Length(Data) > 0 then cs.WriteBuffer(Data[0], Length(Data));
    cs.Free;
    SetLength(Result, ms.Size);
    if ms.Size > 0 then begin ms.Position := 0; ms.ReadBuffer(Result[0], ms.Size); end;
  finally
    ms.Free;
  end;
end;

procedure TTina4CanvasPdf.SaveToStream(Stream: TStream);
var
  outp: TMemoryStream;
  offs: array of Int64;
  procedure W(const S: string); begin if Length(S) > 0 then outp.WriteBuffer(S[1], Length(S)); end;
  procedure WB(const B: TBytes);  begin if Length(B) > 0 then outp.WriteBuffer(B[0], Length(B)); end;
var
  nFonts, nGS, nImg, nObj: Integer;
  catObj, pagesObj, pageObj, contentObj, fontBase, gsBase, imgBase, i: Integer;
  s, resDict, fontDict, gsD, xobjD: string;
  content, flat, rgb, smask: TBytes;
  wi, hi, pix, xrefPos, imgObjNum: Integer;
begin
  // prepend the page-flip now that FH is final
  s := Format('1 0 0 -1 0 %.2f cm'#10, [FH]) + FBuf.Text;
  SetLength(content, Length(s));
  if Length(s) > 0 then Move(s[1], content[0], Length(s));

  nFonts := 12; nGS := Length(FAlphas); nImg := Length(FImgData);
  // object numbers: 1 cat, 2 pages, 3 page, 4 content, fonts, gstates, then each
  // image uses TWO objects (image + smask), assigned contiguously.
  catObj := 1; pagesObj := 2; pageObj := 3; contentObj := 4;
  fontBase := 5;
  gsBase := fontBase + nFonts;
  imgBase := gsBase + nGS;                     // image object N = imgBase + 2*i, smask = +1
  nObj := imgBase + 2 * nImg - 1;
  if nImg = 0 then nObj := gsBase + nGS - 1;

  // resource dicts
  fontDict := '';
  for i := 0 to nFonts - 1 do
    fontDict := fontDict + Format('/%s %d 0 R ', [FONT_RES[i], fontBase + i]);
  gsD := '';
  for i := 0 to nGS - 1 do gsD := gsD + Format('/GS%d %d 0 R ', [i, gsBase + i]);
  xobjD := '';
  for i := 0 to nImg - 1 do xobjD := xobjD + Format('/Im%d %d 0 R ', [i + 1, imgBase + 2 * i]);
  resDict := '<< /Font << ' + fontDict + '>> ';
  if gsD <> '' then resDict := resDict + '/ExtGState << ' + gsD + '>> ';
  if xobjD <> '' then resDict := resDict + '/XObject << ' + xobjD + '>> ';
  resDict := resDict + '>>';

  outp := TMemoryStream.Create;
  try
    SetLength(offs, nObj + 1);
    W('%PDF-1.5'#10'%'#$E2#$E3#$CF#$D3#10);

    offs[catObj] := outp.Size;
    W(Format('%d 0 obj'#10'<< /Type /Catalog /Pages %d 0 R >>'#10'endobj'#10, [catObj, pagesObj]));

    offs[pagesObj] := outp.Size;
    W(Format('%d 0 obj'#10'<< /Type /Pages /Kids [%d 0 R] /Count 1 >>'#10'endobj'#10, [pagesObj, pageObj]));

    offs[pageObj] := outp.Size;
    W(Format('%d 0 obj'#10'<< /Type /Page /Parent %d 0 R /MediaBox [0 0 %.2f %.2f] /Resources %s /Contents %d 0 R >>'#10'endobj'#10,
      [pageObj, pagesObj, FW, FH, resDict, contentObj]));

    flat := FlateBytes(content);
    offs[contentObj] := outp.Size;
    W(Format('%d 0 obj'#10'<< /Length %d /Filter /FlateDecode >>'#10'stream'#10, [contentObj, Length(flat)]));
    WB(flat); W(#10'endstream'#10'endobj'#10);

    for i := 0 to nFonts - 1 do
    begin
      offs[fontBase + i] := outp.Size;
      W(Format('%d 0 obj'#10'<< /Type /Font /Subtype /Type1 /BaseFont /%s /Encoding /WinAnsiEncoding >>'#10'endobj'#10,
        [fontBase + i, Base14For(FONT_RES[i])]));
    end;

    for i := 0 to nGS - 1 do
    begin
      offs[gsBase + i] := outp.Size;
      W(Format('%d 0 obj'#10'<< /Type /ExtGState /ca %.3f /CA %.3f >>'#10'endobj'#10,
        [gsBase + i, FAlphas[i], FAlphas[i]]));
    end;

    for i := 0 to nImg - 1 do
    begin
      wi := FImgW[i]; hi := FImgH[i];
      imgObjNum := imgBase + 2 * i;
      SetLength(rgb, wi * hi * 3); SetLength(smask, wi * hi);
      for pix := 0 to wi * hi - 1 do
      begin
        rgb[pix*3+0] := FImgData[i][pix*4+0];
        rgb[pix*3+1] := FImgData[i][pix*4+1];
        rgb[pix*3+2] := FImgData[i][pix*4+2];
        smask[pix]   := FImgData[i][pix*4+3];
      end;
      // image XObject (references its SMask = imgObjNum+1)
      offs[imgObjNum] := outp.Size;
      flat := FlateBytes(rgb);
      W(Format('%d 0 obj'#10'<< /Type /XObject /Subtype /Image /Width %d /Height %d '
        + '/ColorSpace /DeviceRGB /BitsPerComponent 8 /SMask %d 0 R /Filter /FlateDecode /Length %d >>'#10'stream'#10,
        [imgObjNum, wi, hi, imgObjNum + 1, Length(flat)]));
      WB(flat); W(#10'endstream'#10'endobj'#10);
      // SMask (grayscale alpha)
      offs[imgObjNum + 1] := outp.Size;
      flat := FlateBytes(smask);
      W(Format('%d 0 obj'#10'<< /Type /XObject /Subtype /Image /Width %d /Height %d '
        + '/ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode /Length %d >>'#10'stream'#10,
        [imgObjNum + 1, wi, hi, Length(flat)]));
      WB(flat); W(#10'endstream'#10'endobj'#10);
    end;

    // xref
    xrefPos := outp.Size;
    W(Format('xref'#10'0 %d'#10'0000000000 65535 f '#10, [nObj + 1]));
    for i := 1 to nObj do W(Format('%.10d 00000 n '#10, [offs[i]]));
    W(Format('trailer'#10'<< /Size %d /Root %d 0 R >>'#10'startxref'#10'%d'#10'%%%%EOF'#10,
      [nObj + 1, catObj, xrefPos]));

    outp.Position := 0;
    Stream.CopyFrom(outp, outp.Size);
  finally
    outp.Free;
  end;
end;

procedure TTina4CanvasPdf.SaveToFile(const Path: string);
var fs: TFileStream;
begin
  fs := TFileStream.Create(Path, fmCreate);
  try SaveToStream(fs); finally fs.Free; end;
end;

end.
