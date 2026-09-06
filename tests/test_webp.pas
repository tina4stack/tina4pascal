program test_webp;
{ Hermetic regression test for the pure-Pascal WebP decoder (Tina4WebP).
  Embeds two small VP8L WebP files + their expected RGBA (bytes verified
  bit-exact against Google's dwebp) so a decode regression fails loudly with
  no external fixtures. Prints ALL TESTS PASS / exits non-zero on any diff. }
{$mode delphi}{$H+}
uses SysUtils, Tina4WebP;
var failed: Integer = 0;

procedure Check(const Name: string; const Data: array of Byte;
  const Expect: array of Byte; EW, EH: Integer);
var rgba: TBytes; w, h, i: Integer; ok: Boolean;
begin
  if not Tina4DecodeWebP(@Data[0], Length(Data), rgba, w, h) then
  begin Writeln('FAIL ', Name, ': decode returned false'); Inc(failed); Exit; end;
  if (w <> EW) or (h <> EH) then
  begin Writeln('FAIL ', Name, ': dims ', w, 'x', h, ' expected ', EW, 'x', EH); Inc(failed); Exit; end;
  if Length(rgba) <> Length(Expect) then
  begin Writeln('FAIL ', Name, ': len ', Length(rgba), ' expected ', Length(Expect)); Inc(failed); Exit; end;
  ok := True;
  for i := 0 to High(Expect) do
    if rgba[i] <> Expect[i] then
    begin Writeln('FAIL ', Name, ': byte ', i, ' = ', rgba[i], ' expected ', Expect[i]); ok := False; Inc(failed); Break; end;
  if ok then Writeln('ok   ', Name, ' (', w, 'x', h, ', bit-exact)');
end;

const SOLID_DATA: array[0..37] of Byte = (
    82,73,70,70,30,0,0,0,87,69,66,80,86,80,56,76,17,0,0,0,
    47,7,192,1,0,7,80,153,34,23,170,255,129,136,232,127,0,0);
const SOLID_RGBA: array[0..255] of Byte = (
    200,50,80,255,200,50,80,255,200,50,80,255,200,50,80,255,200,50,80,255,
    200,50,80,255,200,50,80,255,200,50,80,255,200,50,80,255,200,50,80,255,
    200,50,80,255,200,50,80,255,200,50,80,255,200,50,80,255,200,50,80,255,
    200,50,80,255,200,50,80,255,200,50,80,255,200,50,80,255,200,50,80,255,
    200,50,80,255,200,50,80,255,200,50,80,255,200,50,80,255,200,50,80,255,
    200,50,80,255,200,50,80,255,200,50,80,255,200,50,80,255,200,50,80,255,
    200,50,80,255,200,50,80,255,200,50,80,255,200,50,80,255,200,50,80,255,
    200,50,80,255,200,50,80,255,200,50,80,255,200,50,80,255,200,50,80,255,
    200,50,80,255,200,50,80,255,200,50,80,255,200,50,80,255,200,50,80,255,
    200,50,80,255,200,50,80,255,200,50,80,255,200,50,80,255,200,50,80,255,
    200,50,80,255,200,50,80,255,200,50,80,255,200,50,80,255,200,50,80,255,
    200,50,80,255,200,50,80,255,200,50,80,255,200,50,80,255,200,50,80,255,
    200,50,80,255,200,50,80,255,200,50,80,255,200,50,80,255);

const ALPHA_DATA: array[0..55] of Byte = (
    82,73,70,70,48,0,0,0,87,69,66,80,86,80,56,76,35,0,0,0,
    47,7,192,1,16,63,32,16,72,242,39,27,108,136,136,1,201,120,16,102,
    27,41,140,101,44,99,57,255,239,25,68,244,63,176,125,0);
const ALPHA_RGBA: array[0..255] of Byte = (
    0,200,0,0,0,200,0,32,0,200,0,64,0,200,0,96,0,200,0,128,
    0,200,0,160,0,200,0,192,0,200,0,224,0,200,0,0,0,200,0,32,
    0,200,0,64,0,200,0,96,0,200,0,128,0,200,0,160,0,200,0,192,
    0,200,0,224,0,200,0,0,0,200,0,32,0,200,0,64,0,200,0,96,
    0,200,0,128,0,200,0,160,0,200,0,192,0,200,0,224,0,200,0,0,
    0,200,0,32,0,200,0,64,0,200,0,96,0,200,0,128,0,200,0,160,
    0,200,0,192,0,200,0,224,0,200,0,0,0,200,0,32,0,200,0,64,
    0,200,0,96,0,200,0,128,0,200,0,160,0,200,0,192,0,200,0,224,
    0,200,0,0,0,200,0,32,0,200,0,64,0,200,0,96,0,200,0,128,
    0,200,0,160,0,200,0,192,0,200,0,224,0,200,0,0,0,200,0,32,
    0,200,0,64,0,200,0,96,0,200,0,128,0,200,0,160,0,200,0,192,
    0,200,0,224,0,200,0,0,0,200,0,32,0,200,0,64,0,200,0,96,
    0,200,0,128,0,200,0,160,0,200,0,192,0,200,0,224);

begin
  Check('solid', SOLID_DATA, SOLID_RGBA, 8, 8);
  Check('alpha', ALPHA_DATA, ALPHA_RGBA, 8, 8);
  if failed = 0 then Writeln('ALL TESTS PASS')
  else begin Writeln(failed, ' FAILURES'); Halt(1); end;
end.