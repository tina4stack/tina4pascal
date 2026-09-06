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

function Ensure-Fpc {
  $fpc = Find-Fpc
  if ($fpc) { return $fpc }
  Write-Host "FPC not found - downloading Free Pascal 3.2.2 (one-time)..." -ForegroundColor Cyan
  $url = 'https://sourceforge.net/projects/freepascal/files/Win32/3.2.2/fpc-3.2.2.i386-win32.exe/download'
  $inst = Join-Path $env:TEMP 'fpc-3.2.2-setup.exe'
  try {
    Invoke-WebRequest -Uri $url -OutFile $inst -UseBasicParsing
    Write-Host "Installing to C:\FPC\3.2.2 (silent)..."
    Start-Process -FilePath $inst -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/DIR=C:\FPC\3.2.2','/NORESTART' -Wait
  } catch {
    Write-Host "Automatic install failed: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "Install FPC 3.2.2 manually from https://www.freepascal.org/download.html, then re-run." -ForegroundColor Yellow
    return $null
  }
  return Find-Fpc
}

function Make-Ico($png, $ico) {
  Add-Type -AssemblyName System.Drawing
  $src = [System.Drawing.Bitmap]::FromFile($png)
  $sizes = 16,32,48,64,128,256; $pngs = @()
  foreach ($s in $sizes) {
    $bmp = New-Object System.Drawing.Bitmap $s, $s
    $g = [System.Drawing.Graphics]::FromImage($bmp); $g.InterpolationMode='HighQualityBicubic'; $g.SmoothingMode='AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent); $g.DrawImage($src,0,0,$s,$s); $g.Dispose()
    $ms = New-Object System.IO.MemoryStream; $bmp.Save($ms,[System.Drawing.Imaging.ImageFormat]::Png); $pngs += ,($ms.ToArray()); $bmp.Dispose()
  }
  $src.Dispose()
  $fs = New-Object System.IO.MemoryStream; $bw = New-Object System.IO.BinaryWriter $fs
  $bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]$sizes.Count)
  $off = 6 + 16*$sizes.Count
  for ($i=0;$i -lt $sizes.Count;$i++){ $s=$sizes[$i];$d=$pngs[$i];$wb=if($s -ge 256){0}else{$s}
    $bw.Write([Byte]$wb);$bw.Write([Byte]$wb);$bw.Write([Byte]0);$bw.Write([Byte]0);$bw.Write([UInt16]1);$bw.Write([UInt16]32);$bw.Write([UInt32]$d.Length);$bw.Write([UInt32]$off);$off+=$d.Length }
  foreach ($d in $pngs){ $bw.Write($d) }
  $bw.Flush(); [System.IO.File]::WriteAllBytes($ico,$fs.ToArray()); $bw.Dispose(); $fs.Dispose()
}

function Write-File($path, $content) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
  [System.IO.File]::WriteAllText($path, $content)
}

function Invoke-Init($name) {
  if (-not $name -or $name -eq 'win64') { Write-Host "usage: tina4pascal.ps1 init <projectname>" -ForegroundColor Red; return }
  $fpc = Ensure-Fpc
  if (-not $fpc) { return }
  $proj = Join-Path (Get-Location) $name
  if (Test-Path $proj) { Write-Host "'$proj' already exists" -ForegroundColor Red; return }
  Write-Host "Scaffolding $name ..." -ForegroundColor Cyan
  $Title = (Get-Culture).TextInfo.ToTitleCase($name)

  Write-File (Join-Path $proj 'tina4.json') @"
{
  "name": "$name",
  "title": "$Title",
  "bundleId": "com.tina4.$name",
  "window": { "width": 900, "height": 640 },
  "entry": "src/templates/index.twig",
  "targets": ["win64", "linux", "macos", "android", "ios"]
}
"@
  Write-File (Join-Path $proj '.gitignore') "build/`n*.o`n*.ppu`n*.exe`n"
  Write-File (Join-Path $proj 'README.md') "# $Title`n`nA Tina4Pascal native app.`n`n``````tina4pascal.ps1 run`` builds and launches it.`n"
  Write-File (Join-Path $proj 'migrations\0001_init.sql') "-- 0001_init: first migration`n-- CREATE TABLE example (id INTEGER PRIMARY KEY, name TEXT);`n"
  Write-File (Join-Path $proj 'src\orm\.gitkeep') ""
  Write-File (Join-Path $proj 'src\services\.gitkeep') ""
  Write-File (Join-Path $proj 'src\routes\home.pas') @"
unit home;
{ Route handlers for semantic events, e.g. onclick="Home:hello".
  Register with the engine's action dispatcher as the data layer lands. }
{$mode objfpc}{$H+}
interface
implementation
end.
"@
  Write-File (Join-Path $proj 'src\templates\layout.twig') @"
<body style="margin:0;font-family:Segoe UI,Helvetica,sans-serif;background:#fbfaf7">
  {% block content %}{% endblock %}
</body>
"@
  Write-File (Join-Path $proj 'src\templates\index.twig') @"
<body style="margin:0;font-family:Segoe UI,Helvetica,sans-serif;background:#fbfaf7;text-align:center;padding-top:140px">
  <img src="assets/icon.png" width="96" height="96" style="border-radius:22px">
  <h1 style="color:#2b41e6;margin:18px 0 4px;font-size:34px">Hello {{ name }}!</h1>
  <p style="color:#5b5c78;margin:0">Your Tina4Pascal app is running natively.</p>
</body>
"@
  Write-File (Join-Path $proj 'src\app\app.rc') "MAINICON ICON `"assets/icon.ico`"`n"
  Write-File (Join-Path $proj 'src\app\main.pas') @"
program $name;
{`$mode objfpc}{`$H+}
{`$R app.rc}
uses Tina4App;
begin
  RunApp('$Title', 'src/templates', 'index.twig', '{"name":"World"}', 'assets/icon.png', 900, 640);
end.
"@
  # app icon: copy the framework brand as a starter, generate the .ico for the exe
  $brand = Join-Path $Root 'branding\icon.png'
  if (Test-Path $brand) {
    New-Item -ItemType Directory -Force -Path (Join-Path $proj 'assets') | Out-Null
    Copy-Item $brand (Join-Path $proj 'assets\icon.png') -Force
    Make-Ico (Join-Path $proj 'assets\icon.png') (Join-Path $proj 'assets\icon.ico')
  }
  Ok "scaffolded: $proj"
  # build + run
  $exe = Build-Project $proj 'win64'
  if ($exe) {
    Write-Host ""
    Write-Host "  App:      $exe" -ForegroundColor Green
    Write-Host "  Project:  $proj" -ForegroundColor Green
    Write-Host "  Build/run again:  cd $name; ..\tools\tina4pascal.ps1 run" -ForegroundColor DarkGray
    Write-Host "  MCP (AI-drivable): cd tools/mcp; uv sync; tina4 serve  ->  http://localhost:7146/tina4pascal" -ForegroundColor DarkGray
    Start-Process -FilePath $exe -WorkingDirectory $proj
  }
}

function Build-Project($proj, $t) {
  $fpc = Find-Fpc
  if (-not $fpc) { Write-Host "fpc.exe not found - run doctor" -ForegroundColor Red; return $null }
  $flags = @('-Twin64','-Px86_64'); if ($t -eq 'win32') { $flags=@() }
  $out = Join-Path $proj "build\$t"
  New-Item -ItemType Directory -Force -Path $out | Out-Null
  $name = Split-Path -Leaf $proj
  Write-Host "Building $name for $t ..."
  Push-Location $proj
  try {
    $fa = @('-Mdelphi','-O2','-XX','-CX','-Xs') + $flags + @("-Fu$Src","-Fusrc\app","-Fusrc\routes","-FE$out","-FU$out","-o$name.exe","src\app\main.pas")
    & $fpc @fa 2>&1 | Where-Object { $_ -match 'Error|Fatal|Linking' } | ForEach-Object { Write-Host $_ }
  } finally { Pop-Location }
  $exe = Join-Path $out "$name.exe"
  if (Test-Path $exe) { Ok "built: $exe ($([math]::Round((Get-Item $exe).Length/1KB)) KB)"; return $exe }
  Write-Host "build failed" -ForegroundColor Red; return $null
}

if ($cmd -eq 'doctor') {
  Invoke-Doctor
} elseif ($cmd -eq 'init') {
  Invoke-Init $target
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
