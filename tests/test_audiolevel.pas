program test_audiolevel;
{ Manual mic check for the macOS AudioLevel path (NOT in the automated suite:
  it needs a real mic + TCC permission). Arms StartAudioMeter and prints the
  live RMS level ~10x/sec for 3s — speak or clap and the bar should grow.
  If the mic is denied/absent, StartAudioMeter returns False and AudioLevel
  reads silence (the safe default), which this prints and exits cleanly. }
{$mode delphi}{$modeswitch objectivec1}
uses
  SysUtils, Tina4ShellCocoa;
var
  sh: TCocoaShell;
  i: Integer;
  lvl: Single;
begin
  sh := TCocoaShell.Create;
  try
    if not sh.StartAudioMeter then
    begin
      Writeln('StartAudioMeter = False (mic absent or permission denied).');
      Writeln('AudioLevel = ', sh.AudioLevel:0:3, '  (silence, safe default)');
      Halt(0);
    end;
    Writeln('metering armed - speak or clap:');
    for i := 1 to 30 do
    begin
      lvl := sh.AudioLevel;
      Writeln(Format('  %4.1fs  %0.3f  %s',
        [i * 0.1, lvl, StringOfChar('#', Round(lvl * 40))]));
      Sleep(100);
    end;
    sh.StopAudioMeter;
  finally
    sh.Free;
  end;
end.
