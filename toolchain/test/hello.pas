program hello;
begin
  writeln('Hello from FPC on ', {$I %FPCTARGETOS%}, '-', {$I %FPCTARGETCPU%});
end.
