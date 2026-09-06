program test_pdf;

{ Regression test for the headless HTML->PDF canvas (Tina4CanvasPdf). Drives the
  canvas directly (no engine), writes a PDF to memory, and verifies BOTH the PDF
  file structure (header, catalog/pages/page tree, MediaBox = page size, xref,
  trailer, EOF, font resource) AND the drawing itself by inflating the
  FlateDecode content stream and checking the emitted operators. Deterministic,
  no external fixtures. Prints ALL TESTS PASS / exits non-zero on any failure. }

{$mode delphi}{$H+}

uses SysUtils, Classes, StrUtils, ZStream, Tina4RenderBackend, Tina4CanvasPdf;

var failed: Integer = 0;

procedure Check(Cond: Boolean; const Msg: string);
begin
  if Cond then WriteLn('  ok   ', Msg)
  else begin WriteLn('  FAIL ', Msg); Inc(failed); end;
end;

function Has(const Hay, Needle: string): Boolean;
begin Result := Pos(Needle, Hay) > 0; end;

{ Inflate the first FlateDecode stream (the page content) from the PDF bytes so
  the emitted operators can be asserted. Returns '' if it can't be located. }
function ContentOps(const Pdf: RawByteString): string;
var
  p, sPos, len, code, n: Integer;
  ls: string;
  ms: TMemoryStream;
  ds: TDecompressionStream;
  buf: TBytes;
begin
  Result := '';
  p := Pos('/Length ', Pdf);
  if p = 0 then Exit;
  Inc(p, Length('/Length '));
  ls := '';
  while (p <= Length(Pdf)) and (Pdf[p] in ['0'..'9']) do begin ls := ls + Pdf[p]; Inc(p); end;
  Val(ls, len, code);
  if (code <> 0) or (len <= 0) then Exit;
  sPos := PosEx('stream'#10, Pdf, p);
  if sPos = 0 then Exit;
  Inc(sPos, Length('stream'#10));
  if sPos + len - 1 > Length(Pdf) then Exit;
  ms := TMemoryStream.Create;
  try
    ms.Write(Pdf[sPos], len);
    ms.Position := 0;
    ds := TDecompressionStream.Create(ms);
    try
      SetLength(buf, len * 40 + 512);
      n := ds.Read(buf[0], Length(buf));
      if n > 0 then SetString(Result, PAnsiChar(@buf[0]), n);
    finally ds.Free; end;
  finally ms.Free; end;
end;

var
  pdf: TTina4CanvasPdf;
  ms: TMemoryStream;
  s: RawByteString;
  ops: string;
begin
  WriteLn('== Tina4 PDF canvas tests ==');

  pdf := TTina4CanvasPdf.Create(200, 100);
  try
    pdf.SetPageSize(200, 200);          // page height set before drawing (Y-flip)
    pdf.FillRect(10, 10, 120, 60, TTina4Color($FFCC3355));
    pdf.StrokeRect(10, 80, 120, 40, 2, TTina4Color($FF3355CC));
    pdf.DrawText(20, 150, 'Hello PDF', 14, [], TTina4Color($FF000000));
    ms := TMemoryStream.Create;
    try
      pdf.SaveToStream(ms);
      SetString(s, PAnsiChar(ms.Memory), ms.Size);
    finally ms.Free; end;
  finally pdf.Free; end;

  WriteLn('file structure');
  Check(Copy(s, 1, 7) = '%PDF-1.', 'PDF header');
  Check(Has(s, '/Type /Catalog'), 'catalog object');
  Check(Has(s, '/Type /Pages'), 'pages object');
  Check(Has(s, '/Type /Page '), 'page object');
  Check(Has(s, '/MediaBox [0 0 200.00 200.00]'), 'MediaBox = page size');
  Check(Has(s, '/Filter /FlateDecode'), 'content stream compressed');
  Check(Has(s, '/Type /Font'), 'font resource (from DrawText)');
  Check(Has(s, 'xref'), 'xref table');
  Check(Has(s, 'trailer'), 'trailer');
  Check(Has(s, '%%EOF'), 'EOF marker');

  WriteLn('content operators (inflated)');
  ops := ContentOps(s);
  Check(ops <> '', 'content stream inflates');
  Check(Has(ops, ' re'), 'rectangle path op (re)');
  Check(Has(ops, 'f'), 'fill op (f)');
  Check(Has(ops, 'S'), 'stroke op (S)');
  Check(Has(ops, 'BT') and Has(ops, 'ET'), 'text object (BT/ET)');
  Check(Has(ops, '(Hello PDF) Tj'), 'exact text show operator');

  WriteLn;
  if failed = 0 then begin WriteLn('ALL TESTS PASS'); Halt(0); end
  else begin WriteLn(failed, ' FAILURE(S)'); Halt(1); end;
end.
