<#
  tina4pascal.ps1 - Windows developer CLI for the Tina4Pascal native HTML renderer.

    tools\tina4pascal.ps1 <command> [target] [page]

  Commands:
    doctor            check the toolchain (FPC win32/win64, Delphi, WSL/Linux) and
                      report what is present, what is missing, and how to fix it.
    build [target]    build the viewer into build\<target>\ and print the .exe path.
                      targets: win64 (default) | win32
    run  [target] [pg] build + launch the viewer (default win64, page win-test.html).
    where [target]    print where the built .exe is / would be.

  One entry point so nobody has to remember fpc flags or hunt for the .exe.
#>
[CmdletBinding()]
param(
  [string]$cmd = 'doctor',
  [string]$target = 'win64',
  [string]$page = ''
)
$ErrorActionPreference = 'Continue'
$Root  = Split-Path -Parent $PSScriptRoot
$Src   = Join-Path $Root 'src'
$View  = Join-Path $Root 'examples\htmlviewer'
$Build = Join-Path $Root 'build'

function Find-Fpc {
  $c = Get-Command fpc.exe -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  $hit = Get-ChildItem 'C:\FPC' -Recurse -Filter fpc.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($hit) { return $hit.FullName }
  return $null
}
function Ok($m)   { Write-Host "  [ok]   $m" -ForegroundColor Green }
function Miss($m) { Write-Host "  [MISS] $m" -ForegroundColor Yellow }

function Invoke-Doctor {
  Write-Host "Tina4Pascal doctor (Windows)"
  Write-Host "repo: $Root"
  Write-Host ""
  Write-Host "Free Pascal (native + win64 cross):"
  $fpc = Find-Fpc
  if ($fpc) {
    $ver = & $fpc -iV 2>$null
    Ok "fpc $ver  ($fpc)"
    $bin = Split-Path -Parent $fpc
    if (Test-Path (Join-Path $bin 'ppcrossx64.exe')) { Ok "win64 cross (ppcrossx64.exe)" } else { Miss "win64 cross missing - reinstall FPC with the win64 cross" }
    if (Test-Path (Join-Path $bin 'windres.exe')) { Ok "windres.exe (exe icon resource)" } else { Miss "windres.exe missing - the app-icon resource will not compile" }
  } else {
    Miss "fpc.exe not found. Install FPC 3.2.2: https://www.freepascal.org/download.html (default C:\FPC\3.2.2), or via the pascal-dev MCP setup_fpc."
  }
  Write-Host ""
  Write-Host "Windows graphics (always present):"
  Ok "GDI + GDI+ (gdiplus.dll): shapes, AA rounded rects, images"
  Ok "urlmon.dll: http(s) image fetch"
  Write-Host ""
  Write-Host "Linux target via WSL:"
  if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
    Ok "wsl.exe present"
    $lfpc = & wsl.exe -e bash -lc 'command -v fpc || (test -x $HOME/fpc/bin/fpc && echo $HOME/fpc/bin/fpc)' 2>$null
    if ($lfpc) { Ok "Linux FPC: $lfpc" } else { Miss "no FPC in WSL - 'sudo apt install fpc' or the user-local tarball (see docs)" }
    $x = & wsl.exe -e bash -lc 'ls /usr/lib/x86_64-linux-gnu/libX11.so.6 2>/dev/null' 2>$null
    if ($x) { Ok "libX11 in WSL (X11 viewer)" } else { Miss "libX11 missing in WSL - 'sudo apt install libx11-6'" }
  } else {
    Miss "wsl.exe not found - Linux target unavailable from here"
  }
  Write-Host ""
  Write-Host "Build output: build\<target>\htmlviewer_win.exe"
  if ($fpc) { Write-Host "Ready. Try:  tools\tina4pascal.ps1 run win64" } else { Write-Host "Install FPC first, then re-run doctor." }
}

function Invoke-Build([string]$t) {
  $fpc = Find-Fpc
  if (-not $fpc) { Write-Host "fpc.exe not found - run 'doctor' for install steps." -ForegroundColor Red; return $null }
  $flags = @()
  if ($t -eq 'win64') { $flags = @('-Twin64','-Px86_64') }
  elseif ($t -eq 'win32') { $flags = @() }
  else { Write-Host "unknown target '$t' (win64 | win32)" -ForegroundColor Red; return $null }
  $out = Join-Path $Build $t
  New-Item -ItemType Directory -Force -Path $out | Out-Null
  $prog = Join-Path $View 'htmlviewer_win.pas'
  Write-Host "fpc -Mdelphi $($flags -join ' ') htmlviewer_win.pas"
  Push-Location $View
  try {
    $fa = @('-Mdelphi','-O2','-XX','-CX','-Xs') + $flags + @("-FE$out","-FU$out","-Fu$Src",$prog)
    & $fpc @fa 2>&1 | Where-Object { $_ -match 'Error|Fatal|Linking' } | ForEach-Object { Write-Host $_ }
  } finally { Pop-Location }
  $exe = Join-Path $out 'htmlviewer_win.exe'
  if (Test-Path $exe) { Ok "built: $exe  ($([math]::Round((Get-Item $exe).Length/1KB)) KB)"; return $exe }
  Write-Host "build failed (see errors above)" -ForegroundColor Red; return $null
}

if ($cmd -eq 'doctor') {
  Invoke-Doctor
} elseif ($cmd -eq 'build') {
  Invoke-Build $target | Out-Null
} elseif ($cmd -eq 'run') {
  $exe = Invoke-Build $target
  if ($exe) {
    if (-not $page) { $page = Join-Path $View 'win-test.html' }
    Write-Host "-> $page"
    Start-Process -FilePath $exe -ArgumentList $page -WorkingDirectory $View
  }
} elseif ($cmd -eq 'where') {
  Write-Host (Join-Path (Join-Path $Build $target) 'htmlviewer_win.exe')
} else {
  Write-Host "unknown command '$cmd' (doctor | build | run | where)"
}
