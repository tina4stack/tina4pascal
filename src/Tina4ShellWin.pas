unit Tina4ShellWin;

{ Windows desktop shell for the Tina4 native renderer.

  Implements the TTina4Canvas contract on GDI (the Win32 graphics API) through
  FPC's `Windows` unit — the same idea as the Cocoa shell on AppKit. The window
  host (examples drive it) hands the canvas a device context per frame via
  BeginFrame; the engine then paints through GDI: solid/rounded rects, lines,
  ClearType text, clipping and an affine world transform for CSS transforms.

  A memory DC created once backs text measurement outside a paint cycle (the
  layout pass needs MeasureText). Coordinates are CSS pixels, top-left; colours
  are $AARRGGBB (GDI is opaque RGB in v1 — per-pixel alpha and the offscreen
  filter/3D compositing land on a 32-bit DIB section next). }

{$mode delphi}{$H+}

interface

uses
  Windows, SysUtils, Classes, Tina4RenderBackend;

type
  TWinCanvas = class(TTina4Canvas)
  private
    FDC: HDC;              // current frame device context (set by BeginFrame)
    FMeasDC: HDC;          // memory DC for text measurement between frames
    FClipSaved: Boolean;   // a SetClip pushed a SaveDC we must RestoreDC
    function FaceFor(const Family: string): WideString;
    function MakeFont(SizePx: Single; Styles: TTina4FontStyles): HFONT;
    function DC: HDC;      // FDC if painting, else the measuring DC
  public
    constructor Create;
    destructor Destroy; override;
    procedure BeginFrame(ADC: HDC);
    procedure FillRect(X, Y, W, H: Single; Color: TTina4Color); override;
    procedure StrokeRect(X, Y, W, H, Thickness: Single; Color: TTina4Color); override;
    procedure FillRoundRect(X, Y, W, H, Radius: Single; Color: TTina4Color); override;
    procedure StrokeRoundRect(X, Y, W, H, Radius, Thickness: Single; Color: TTina4Color); override;
    procedure DrawLine(X1, Y1, X2, Y2, Thickness: Single; Color: TTina4Color); override;
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
  end;

implementation

const
  CLEARTYPE_QUALITY = 5;

function ColorRefOf(C: TTina4Color): COLORREF;
begin
  // $AARRGGBB -> GDI 0x00BBGGRR
  Result := ((C shr 16) and $FF) or (((C shr 8) and $FF) shl 8) or ((C and $FF) shl 16);
end;

constructor TWinCanvas.Create;
begin
  inherited Create;
  FMeasDC := CreateCompatibleDC(0);
  SetBkMode(FMeasDC, TRANSPARENT);
end;

destructor TWinCanvas.Destroy;
begin
  if FMeasDC <> 0 then DeleteDC(FMeasDC);
  inherited Destroy;
end;

procedure TWinCanvas.BeginFrame(ADC: HDC);
begin
  FDC := ADC;
  SetBkMode(FDC, TRANSPARENT);
  SetGraphicsMode(FDC, GM_ADVANCED);   // enable world transforms for CSS transforms
end;

function TWinCanvas.DC: HDC;
begin
  if FDC <> 0 then Result := FDC else Result := FMeasDC;
end;

{ Map a CSS font-family list to a concrete Windows face. }
function TWinCanvas.FaceFor(const Family: string): WideString;
var f, first: string; p: Integer;
begin
  f := LowerCase(Trim(Family));
  p := Pos(',', f); if p > 0 then first := Trim(Copy(f, 1, p - 1)) else first := f;
  first := StringReplace(first, '"', '', [rfReplaceAll]);
  first := StringReplace(first, '''', '', [rfReplaceAll]);
  if (first = '') or (first = 'sans-serif') or (first = 'system-ui') then Result := 'Segoe UI'
  else if first = 'serif' then Result := 'Times New Roman'
  else if (first = 'monospace') or (first = 'mono') then Result := 'Consolas'
  else Result := UTF8Decode(Trim(Family).Split([','])[0].Trim);
end;

function TWinCanvas.MakeFont(SizePx: Single; Styles: TTina4FontStyles): HFONT;
var lf: LOGFONTW; face: WideString; i, n: Integer;
begin
  FillChar(lf, SizeOf(lf), 0);
  lf.lfHeight := -Round(SizePx);            // negative => em height in device px
  if (tfsBold in Styles) or (FontWeight >= 600) then lf.lfWeight := FW_BOLD
  else lf.lfWeight := FW_NORMAL;
  if tfsItalic in Styles then lf.lfItalic := 1;
  if tfsUnderline in Styles then lf.lfUnderline := 1;
  if tfsStrike in Styles then lf.lfStrikeOut := 1;
  lf.lfQuality := CLEARTYPE_QUALITY;
  lf.lfCharSet := DEFAULT_CHARSET;
  face := FaceFor(FontFamily);
  n := Length(face); if n > 31 then n := 31;
  for i := 1 to n do lf.lfFaceName[i - 1] := WideChar(face[i]);
  lf.lfFaceName[n] := #0;
  Result := CreateFontIndirectW(@lf);
end;

procedure TWinCanvas.FillRect(X, Y, W, H: Single; Color: TTina4Color);
var r: Windows.RECT; br: HBRUSH;
begin
  if (W <= 0) or (H <= 0) then Exit;
  r.Left := Round(X); r.Top := Round(Y); r.Right := Round(X + W); r.Bottom := Round(Y + H);
  br := CreateSolidBrush(ColorRefOf(Color));
  Windows.FillRect(DC, r, br);
  DeleteObject(br);
end;

procedure TWinCanvas.StrokeRect(X, Y, W, H, Thickness: Single; Color: TTina4Color);
var pen, old: HGDIOBJ; oldBr: HGDIOBJ;
begin
  pen := CreatePen(PS_SOLID, Round(Thickness), ColorRefOf(Color));
  old := SelectObject(DC, pen);
  oldBr := SelectObject(DC, GetStockObject(NULL_BRUSH));
  Windows.Rectangle(DC, Round(X), Round(Y), Round(X + W), Round(Y + H));
  SelectObject(DC, oldBr);
  SelectObject(DC, old); DeleteObject(pen);
end;

procedure TWinCanvas.FillRoundRect(X, Y, W, H, Radius: Single; Color: TTina4Color);
var br, old, oldPen: HGDIOBJ; d: Integer;
begin
  if (W <= 0) or (H <= 0) then Exit;
  d := Round(Radius * 2);
  br := CreateSolidBrush(ColorRefOf(Color));
  old := SelectObject(DC, br);
  oldPen := SelectObject(DC, GetStockObject(NULL_PEN));
  Windows.RoundRect(DC, Round(X), Round(Y), Round(X + W) + 1, Round(Y + H) + 1, d, d);
  SelectObject(DC, oldPen);
  SelectObject(DC, old); DeleteObject(br);
end;

procedure TWinCanvas.StrokeRoundRect(X, Y, W, H, Radius, Thickness: Single; Color: TTina4Color);
var pen, old, oldBr: HGDIOBJ; d: Integer;
begin
  d := Round(Radius * 2);
  pen := CreatePen(PS_SOLID, Round(Thickness), ColorRefOf(Color));
  old := SelectObject(DC, pen);
  oldBr := SelectObject(DC, GetStockObject(NULL_BRUSH));
  Windows.RoundRect(DC, Round(X), Round(Y), Round(X + W), Round(Y + H), d, d);
  SelectObject(DC, oldBr);
  SelectObject(DC, old); DeleteObject(pen);
end;

procedure TWinCanvas.DrawLine(X1, Y1, X2, Y2, Thickness: Single; Color: TTina4Color);
var pen, old: HGDIOBJ;
begin
  pen := CreatePen(PS_SOLID, Round(Thickness), ColorRefOf(Color));
  old := SelectObject(DC, pen);
  Windows.MoveToEx(DC, Round(X1), Round(Y1), nil);
  Windows.LineTo(DC, Round(X2), Round(Y2));
  SelectObject(DC, old); DeleteObject(pen);
end;

procedure TWinCanvas.DrawText(X, Y: Single; const Text: string; FontSize: Single;
  Styles: TTina4FontStyles; Color: TTina4Color);
var f, old: HGDIOBJ; w: WideString;
begin
  if Text = '' then Exit;
  f := MakeFont(FontSize, Styles);
  old := SelectObject(DC, f);
  SetTextColor(DC, ColorRefOf(Color));
  SetBkMode(DC, TRANSPARENT);
  if LetterSpacing <> 0 then SetTextCharacterExtra(DC, Round(LetterSpacing));
  w := UTF8Decode(Text);
  Windows.TextOutW(DC, Round(X), Round(Y), PWideChar(w), Length(w));
  if LetterSpacing <> 0 then SetTextCharacterExtra(DC, 0);
  SelectObject(DC, old); DeleteObject(f);
end;

function TWinCanvas.MeasureText(const Text: string; FontSize: Single;
  Styles: TTina4FontStyles): TTina4TextMetrics;
var f, old: HGDIOBJ; w: WideString; sz: SIZE; tm: TEXTMETRICW; d: HDC;
begin
  d := DC;
  f := MakeFont(FontSize, Styles);
  old := SelectObject(d, f);
  w := UTF8Decode(Text);
  sz.cx := 0; sz.cy := 0;
  if w <> '' then Windows.GetTextExtentPoint32W(d, PWideChar(w), Length(w), sz);
  if LetterSpacing <> 0 then sz.cx := sz.cx + Round(LetterSpacing) * Length(w);
  GetTextMetricsW(d, @tm);
  SelectObject(d, old); DeleteObject(f);
  Result.Width := sz.cx;
  Result.Ascent := tm.tmAscent;
  Result.Descent := tm.tmDescent;
  Result.LineHeight := tm.tmHeight;
end;

procedure TWinCanvas.SetClip(X, Y, W, H: Single);
begin
  // one level deep: SaveDC, intersect; ClearClip does RestoreDC
  SaveDC(DC); FClipSaved := True;
  IntersectClipRect(DC, Round(X), Round(Y), Round(X + W), Round(Y + H));
end;

procedure TWinCanvas.ClearClip;
begin
  if FClipSaved then begin RestoreDC(DC, -1); FClipSaved := False; end;
end;

procedure TWinCanvas.SaveState;
begin
  SaveDC(DC);
end;

procedure TWinCanvas.RestoreState;
begin
  RestoreDC(DC, -1);
end;

procedure TWinCanvas.Translate(DX, DY: Single);
var xf: XFORM;
begin
  xf.eM11 := 1; xf.eM12 := 0; xf.eM21 := 0; xf.eM22 := 1; xf.eDx := DX; xf.eDy := DY;
  ModifyWorldTransform(DC, xf, MWT_LEFTMULTIPLY);
end;

procedure TWinCanvas.Scale(SX, SY: Single);
var xf: XFORM;
begin
  xf.eM11 := SX; xf.eM12 := 0; xf.eM21 := 0; xf.eM22 := SY; xf.eDx := 0; xf.eDy := 0;
  ModifyWorldTransform(DC, xf, MWT_LEFTMULTIPLY);
end;

procedure TWinCanvas.Rotate(Degrees: Single);
var xf: XFORM; a, c, s: Single;
begin
  a := Degrees * Pi / 180; c := Cos(a); s := Sin(a);
  xf.eM11 := c; xf.eM12 := s; xf.eM21 := -s; xf.eM22 := c; xf.eDx := 0; xf.eDy := 0;
  ModifyWorldTransform(DC, xf, MWT_LEFTMULTIPLY);
end;

end.
