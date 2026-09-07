program test_barcode;

{ Round-trip test for the desktop barcode decoder (Tina4Barcode → libzbar):
  encode a string as a QR with the engine's own Tina4QR, rasterise it to an
  8-bit grayscale frame (with a quiet zone), decode it back, and assert the
  value + symbology. Deterministic, self-contained (no camera, no fixture).

  libzbar is loaded dynamically; on a host without it the test prints SKIP and
  exits 0 (so it never false-fails where scanning isn't installed) — but where
  zbar is present it is a real decode. }

{$mode delphi}{$H+}

uses SysUtils, FPImage, FPWritePNG, Tina4QR, Tina4Barcode;

var failed: Integer = 0;

procedure Check(Cond: Boolean; const Msg: string);
begin
  if Cond then WriteLn('  ok   ', Msg)
  else begin WriteLn('  FAIL ', Msg); Inc(failed); end;
end;

{ Rasterise a QR matrix into an 8-bit grayscale buffer: each module → sc×sc px,
  dark = 0, light = 255, with a `qz`-module quiet zone all around (zbar needs it). }
function RenderQR(const M: TQRMatrix; sc, qzMod: Integer; out W, H: Integer): TBytes;
var n, i, j, px, py, x0, y0: Integer; dark: Boolean;
begin
  n := M.Size;
  W := (n + 2 * qzMod) * sc; H := W;
  SetLength(Result, W * H);
  FillChar(Result[0], Length(Result), 255);      // all light
  for i := 0 to n - 1 do
    for j := 0 to n - 1 do
    begin
      dark := M.Modules[i][j];
      if not dark then Continue;
      x0 := (qzMod + j) * sc; y0 := (qzMod + i) * sc;
      for py := y0 to y0 + sc - 1 do
        for px := x0 to x0 + sc - 1 do
          Result[py * W + px] := 0;
    end;
end;

{ Write a grayscale buffer to a PNG and decode the barcode back from the file. }
procedure ScanFileRoundTrip(const Gray: TBytes; W, H: Integer; const Expect: string);
var img: TFPMemoryImage; x, y: Integer; g: Word; c: TFPColor; fn, v, f: string;
begin
  img := TFPMemoryImage.Create(W, H);
  try
    for y := 0 to H - 1 do
      for x := 0 to W - 1 do
      begin
        g := Word(Gray[y * W + x]) shl 8;                 // 8 → 16-bit channel
        c.red := g; c.green := g; c.blue := g; c.alpha := $FFFF;
        img.Colors[x, y] := c;
      end;
    fn := IncludeTrailingPathDelimiter(GetTempDir) + 'tina4_qr_roundtrip.png';
    img.SaveToFile(fn);                                    // FPWritePNG (by extension)
    Check(Tina4ScanImageFile(fn, v, f), 'decoded a barcode from the PNG file');
    Check(v = Expect, 'file-decoded value matches the payload');
    DeleteFile(fn);
  finally
    img.Free;
  end;
end;

var
  m: TQRMatrix; gray: TBytes; w, h: Integer;
  value, fmt, payload: string;
begin
  WriteLn('== Tina4 barcode decode (Tina4QR -> zbar round-trip) ==');

  if not Tina4BarcodeAvailable then
  begin
    WriteLn('  SKIP libzbar not available on this host — decode path not exercised');
    WriteLn('ALL TESTS PASS');
    Halt(0);
  end;

  payload := 'HELLO-123 (tina4) https://tina4.com?x=1';   // parens + url: proves raw passthrough
  Check(QREncode(payload, m), 'QREncode produced a matrix');
  gray := RenderQR(m, 8, 4, w, h);
  WriteLn('  rendered QR ', w, 'x', h, ' (', m.Size, ' modules)');

  Check(Tina4DecodeBarcode(@gray[0], w, h, value, fmt), 'zbar decoded a symbol');
  WriteLn('  decoded: "', value, '"  format=', fmt);
  Check(value = payload, 'decoded value matches the exact payload');
  Check(Pos('QR', fmt) > 0, 'symbology reported as QR');

  WriteLn('scan from an image FILE (Tina4ScanImageFile)');
  ScanFileRoundTrip(gray, w, h, payload);

  WriteLn;
  if failed = 0 then begin WriteLn('ALL TESTS PASS'); Halt(0); end
  else begin WriteLn(failed, ' FAILURE(S)'); Halt(1); end;
end.
