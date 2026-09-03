program test_qr;

{ Mutation-proof tests for the pure-Pascal QR encoder (Tina4QR).
  Checks mask-independent invariants: the Reed-Solomon vector from the
  ISO/IEC 18004 worked example, version sizing, and the three finder
  patterns + timing runs that every valid symbol must carry.

  These survive changes to mask selection (which legitimately alters
  individual modules) while still catching real regressions in the RS
  maths, version table, or matrix assembly. Payloads used here are also
  verified end-to-end against a real scanner in tools/ during development. }

{$mode delphi}{$H+}

uses SysUtils, Tina4QR;

var
  Failures: Integer = 0;

procedure Check(Cond: Boolean; const Msg: string);
begin
  if Cond then
    WriteLn('  ok   ', Msg)
  else
  begin
    WriteLn('  FAIL ', Msg);
    Inc(Failures);
  end;
end;

{ a 7x7 finder has a solid 3x3 core, a ring of light, and a dark border }
function FinderAt(const M: TQRMatrix; r, c: Integer): Boolean;
var dr, dc: Integer; want, got: Boolean;
begin
  Result := True;
  for dr := 0 to 6 do
    for dc := 0 to 6 do
    begin
      want := (dr = 0) or (dr = 6) or (dc = 0) or (dc = 6) or
              ((dr >= 2) and (dr <= 4) and (dc >= 2) and (dc <= 4));
      got := M.Modules[r + dr][c + dc];
      if got <> want then Exit(False);
    end;
end;

procedure TestRS;
const
  { ISO/IEC 18004 Annex example: "01234567" at 1-M, 16 data codewords → the
    10 error-correction codewords below. Pins GF(256) + generator polynomial. }
  D: array[0..15] of Byte =
    (16, 32, 12, 86, 97, 128, 236, 17, 236, 17, 236, 17, 236, 17, 236, 17);
begin
  WriteLn('Reed-Solomon vector');
  Check(QRTestEC(D, 10) = '165 36 212 193 237 54 199 135 44 85',
    'canonical 1-M EC codewords');
end;

procedure TestVersions;
var M: TQRMatrix;
begin
  WriteLn('version selection (size = 17 + 4*version)');
  Check(QREncode('HI', M) and (M.Size = 21), 'short → v1 (21)');
  Check(QREncode('https://tina4.com/pascal', M) and (M.Size = 25), '24 bytes → v2 (25)');
  Check(QREncode(StringOfChar('A', 200), M) and (M.Size = 53), '200 bytes → v9 (53)');
  Check(not QREncode(StringOfChar('A', 400), M), '400 bytes → rejected (over v10-L)');
end;

procedure TestStructure;
var M: TQRMatrix; i: Integer; timingOK: Boolean;
begin
  WriteLn('structural invariants (HELLO, v1)');
  Check(QREncode('HELLO', M), 'encodes');
  Check(FinderAt(M, 0, 0), 'top-left finder');
  Check(FinderAt(M, 0, M.Size - 7), 'top-right finder');
  Check(FinderAt(M, M.Size - 7, 0), 'bottom-left finder');
  { horizontal timing row alternates between the finders }
  timingOK := True;
  for i := 8 to M.Size - 9 do
    if M.Modules[6][i] <> ((i mod 2) = 0) then timingOK := False;
  Check(timingOK, 'timing pattern alternates');
  { the mandatory dark module at (4*v+9, 8) = (13, 8) for v1 }
  Check(M.Modules[M.Size - 8][8], 'dark module present');
end;

begin
  WriteLn('== Tina4QR tests ==');
  TestRS;
  TestVersions;
  TestStructure;
  WriteLn;
  if Failures = 0 then
  begin
    WriteLn('ALL TESTS PASS');
    Halt(0);
  end
  else
  begin
    WriteLn(Failures, ' FAILURE(S)');
    Halt(1);
  end;
end.
