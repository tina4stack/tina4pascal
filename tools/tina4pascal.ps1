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
  Write-Host "Native debug (gdb):"
  $g = Get-Command gdb -ErrorAction SilentlyContinue
  if ($g) { Ok "gdb ($($g.Source)) - tina4pascal debug" }
  elseif ($fpc -and (Test-Path (Join-Path (Split-Path -Parent $fpc) 'gdb.exe'))) { Ok "gdb (FPC bundled)" }
  else { Miss "gdb not found - 'choco install mingw' to use tina4pascal debug" }
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
  Write-Host "Android (native APK from Windows):"
  if ($fpc) {
    if (Test-AndroidCross 'arm64-v8a')   { Ok "FPC cross arm64-v8a (ppcrossa64 + aarch64-android RTL)" } else { Miss "FPC arm64-v8a cross missing - tools\tina4pascal.ps1 setup android" }
    if (Test-AndroidCross 'armeabi-v7a') { Ok "FPC cross armeabi-v7a (ppcrossarm + arm-android RTL)" } else { Miss "FPC armeabi-v7a cross missing - tools\tina4pascal.ps1 setup android" }
  }
  $sdk = Resolve-AndroidSdk
  if ($sdk) {
    Ok "Android SDK ($sdk)"
    $bt = Resolve-BuildTools $sdk; if ($bt) { Ok "build-tools ($(Split-Path -Leaf $bt))" } else { Miss "build-tools missing (aapt2/d8/apksigner) - install via sdkmanager" }
    $jar = Resolve-PlatformJar $sdk; if ($jar) { Ok "platform ($(Split-Path -Leaf (Split-Path -Parent $jar)))" } else { Miss "no android.jar platform - install one via sdkmanager" }
    $ndk = Resolve-AndroidNdk $sdk; if ($ndk) { Ok "NDK ($(Split-Path -Leaf $ndk))" } else { Miss "NDK r21x missing - tools\tina4pascal.ps1 setup android" }
  } else { Miss "Android SDK not found - set ANDROID_HOME (Android Studio / cmdline-tools)" }
  $jdk = Resolve-Jdk; if ($jdk) { Ok "JDK ($jdk)" } else { Miss "JDK 17+ not found - set JAVA_HOME" }
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

function Invoke-Init($name, $norun) {
  if (-not $name -or $name -eq 'win64') { Write-Host "usage: tina4pascal.ps1 init <projectname> [--no-run]" -ForegroundColor Red; return }
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
  "main": "app.pas",
  "bundleId": "com.tina4.$name",
  "window": { "width": 900, "height": 640 },
  "entry": "src/templates/index.twig",
  "targets": ["macos", "windows", "linux", "android", "ios"]
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
  Write-File (Join-Path $proj 'app.pas') @"
program $name;
{`$mode objfpc}{`$H+}
uses Tina4App;
begin
  // window/taskbar icon + the on-screen logo both come from assets/icon.png,
  // so the project builds on any host for any target with no icon tooling.
  RunApp('$Title', 'src/templates', 'index.twig', '{"name":"World"}', 'assets/icon.png', 900, 640);
end.
"@
  # app icon: copy the framework brand as a starter (used at runtime + in the UI)
  $brand = Join-Path $Root 'branding\icon.png'
  if (Test-Path $brand) {
    New-Item -ItemType Directory -Force -Path (Join-Path $proj 'assets') | Out-Null
    Copy-Item $brand (Join-Path $proj 'assets\icon.png') -Force
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
    if (-not $norun) { Start-Process -FilePath $exe -WorkingDirectory $proj }
  }
}

# Read a top-level "key": "value" from a project's tina4.json (matches the sh CLI's jget).
function Get-T4($proj, $key, $default) {
  $f = Join-Path $proj 'tina4.json'
  if (-not (Test-Path $f)) { return $default }
  $m = [regex]::Match((Get-Content $f -Raw), '"' + [regex]::Escape($key) + '"\s*:\s*"([^"]*)"')
  if ($m.Success) { return $m.Groups[1].Value } else { return $default }
}

function Build-ProjectLinux($proj) {
  # cross to Linux through WSL (the desktop X11 target)
  if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { Write-Host "wsl not available for the linux target" -ForegroundColor Red; return $null }
  $name = Get-T4 $proj 'name' (Split-Path -Leaf $proj)
  $main = (Get-T4 $proj 'main' 'app.pas')
  $wproj = '/mnt/' + ($proj -replace '^([A-Za-z]):','$1').Substring(0,1).ToLower() + ($proj.Substring(2) -replace '\\','/')
  $wfw   = '/mnt/' + ($Src  -replace '^([A-Za-z]):','$1').Substring(0,1).ToLower() + ($Src.Substring(2)  -replace '\\','/')
  $sh = @"
export PATH=`$HOME/fpc/bin:`$PATH
mkdir -p `$HOME/xstublibs; [ -e `$HOME/xstublibs/libX11.so ] || ln -s /usr/lib/x86_64-linux-gnu/libX11.so.6 `$HOME/xstublibs/libX11.so
cd '$wproj'; mkdir -p build/linux
fpc -Mdelphi -O2 -Xs -Fu'$wfw' -Fu. -Fusrc/routes -Fusrc/orm -Fusrc/services -Fl`$HOME/xstublibs -k-L`$HOME/xstublibs -FEbuild/linux -FUbuild/linux -o$name '$main' 2>&1 | grep -iE 'error|fatal|linking' | tail -6
[ -x build/linux/$name ] && echo "OK build/linux/$name" || echo "FAILED"
"@
  $tmp = Join-Path $env:TEMP 't4p_linux.sh'; [System.IO.File]::WriteAllText($tmp, ($sh -replace "`r`n","`n"))
  $wtmp = '/mnt/c' + ($tmp.Substring(2) -replace '\\','/')
  & wsl.exe -e bash $wtmp
  $exe = Join-Path $proj "build\linux\$name"
  if (Test-Path $exe) { Ok "built (linux): $exe"; return $exe }
  return $null
}

# Compile a project for a Windows target. $dbg=$true → DWARF symbols into build\<t>-debug\.
function Build-ProjectWin($proj, $t, $dbg) {
  $fpc = Find-Fpc
  if (-not $fpc) { Write-Host "fpc.exe not found - run doctor" -ForegroundColor Red; return $null }
  $flags = @('-Twin64','-Px86_64'); if ($t -eq 'win32') { $flags=@() }
  $name = Get-T4 $proj 'name' (Split-Path -Leaf $proj)
  $main = ((Get-T4 $proj 'main' 'app.pas') -replace '/','\')
  if ($dbg) { $opt = @('-gw','-gl','-O-'); $sub = "$t-debug" } else { $opt = @('-O2','-XX','-CX','-Xs'); $sub = $t }
  $out = Join-Path $proj "build\$sub"
  New-Item -ItemType Directory -Force -Path $out | Out-Null
  Write-Host "Building $name for $t$(if($dbg){' (debug)'}) ..."
  Push-Location $proj
  try {
    $fa = @('-Mdelphi') + $opt + $flags + @("-Fu$Src","-Fu.","-Fusrc\routes","-Fusrc\orm","-Fusrc\services","-FE$out","-FU$out","-o$name.exe",$main)
    & $fpc @fa 2>&1 | Where-Object { $_ -match 'Error|Fatal|Linking' } | ForEach-Object { Write-Host $_ }
  } finally { Pop-Location }
  $exe = Join-Path $out "$name.exe"
  if (Test-Path $exe) { Ok "built: $exe ($([math]::Round((Get-Item $exe).Length/1KB)) KB)"; return $exe }
  Write-Host "build failed" -ForegroundColor Red; return $null
}

function Build-Project($proj, $t) {
  if ($t -eq 'linux') { return Build-ProjectLinux $proj }
  if ($t -eq 'android') { return Build-ProjectAndroid $proj }
  if ($t -eq 'all') {
    Build-Project $proj 'win64'   | Out-Null
    Build-Project $proj 'linux'   | Out-Null
    Build-Project $proj 'android' | Out-Null
    Write-Host "(macos / ios build from a Mac via tools/tina4pascal - full cross toolchain)" -ForegroundColor DarkGray
    return $null
  }
  return Build-ProjectWin $proj $t $false
}

# Build with DWARF symbols (no optimise/strip) into build\<t>-debug\ for gdb.
function Build-ProjectDebug($proj, $t) { return Build-ProjectWin $proj $t $true }

# ── Android (native, from Windows) ────────────────────────────────────
# Every path below is resolved explicitly (env var, then well-known location) so
# the build never depends on what happens to be on PATH. The one thing stock FPC
# lacks is the android cross-compiler + RTL; that ships as a version-locked pack
# dropped into the FPC tree (see toolchain\build-android-cross.ps1 / 'setup android').

function Fpc-Root { $f = Find-Fpc; if (-not $f) { return $null }; return (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $f))) }
function Fpc-Bin  { $f = Find-Fpc; if (-not $f) { return $null }; return (Split-Path -Parent $f) }

# Is the FPC android cross toolchain (compiler + RTL units) installed?
function Test-AndroidCross([string]$abi) {
  $bin = Fpc-Bin; $root = Fpc-Root
  if (-not $bin) { return $false }
  switch ($abi) {
    'armeabi-v7a' { return (Test-Path (Join-Path $bin 'ppcrossarm.exe')) -and (Test-Path (Join-Path $root 'units\arm-android\rtl\system.ppu')) }
    'x86_64'      { return (Test-Path (Join-Path $bin 'ppcrossx64.exe')) -and (Test-Path (Join-Path $root 'units\x86_64-android\rtl\system.ppu')) }
    default       { return (Test-Path (Join-Path $bin 'ppcrossa64.exe')) -and (Test-Path (Join-Path $root 'units\aarch64-android\rtl\system.ppu')) }
  }
}

function Resolve-AndroidSdk {
  foreach ($c in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, (Join-Path $env:LOCALAPPDATA 'Android\Sdk'))) {
    if ($c -and (Test-Path (Join-Path $c 'platform-tools'))) { return $c }
  }
  return $null
}
function Resolve-AndroidNdk($sdk) {
  foreach ($c in @($env:ANDROID_NDK_HOME, $env:ANDROID_NDK)) {
    if ($c -and (Test-Path (Join-Path $c 'source.properties'))) { return $c }
  }
  if ($sdk) {
    $nd = Join-Path $sdk 'ndk'
    if (Test-Path $nd) {
      $r21 = Get-ChildItem $nd -Directory -Filter 'android-ndk-r21*' -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($r21) { return $r21.FullName }
      # any NDK that still ships the gcc binutils FPC 3.2.2 needs
      $any = Get-ChildItem $nd -Directory -ErrorAction SilentlyContinue |
             Where-Object { Test-Path (Join-Path $_.FullName 'toolchains\aarch64-linux-android-4.9') } | Select-Object -First 1
      if ($any) { return $any.FullName }
    }
  }
  return $null
}
function Resolve-Jdk {
  if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME 'bin\javac.exe'))) { return $env:JAVA_HOME }
  $bases = @("$env:ProgramFiles\Java", "$env:ProgramFiles\Eclipse Adoptium",
             "$env:ProgramFiles\Microsoft", "$env:ProgramFiles\Android\Android Studio\jbr")
  foreach ($base in $bases) {
    if (Test-Path (Join-Path $base 'bin\javac.exe')) { return $base }
    $j = Get-ChildItem $base -Directory -ErrorAction SilentlyContinue |
         Where-Object { Test-Path (Join-Path $_.FullName 'bin\javac.exe') } | Sort-Object Name -Descending | Select-Object -First 1
    if ($j) { return $j.FullName }
  }
  return $null
}
function Resolve-BuildTools($sdk) {
  $bt = Join-Path $sdk 'build-tools'; if (-not (Test-Path $bt)) { return $null }
  Get-ChildItem $bt -Directory | Sort-Object Name -Descending |
    Where-Object { Test-Path (Join-Path $_.FullName 'aapt2.exe') } | Select-Object -First 1 -ExpandProperty FullName
}
function Resolve-PlatformJar($sdk) {
  $pl = Join-Path $sdk 'platforms'; if (-not (Test-Path $pl)) { return $null }
  Get-ChildItem $pl -Directory | Sort-Object Name -Descending |
    ForEach-Object { Join-Path $_.FullName 'android.jar' } | Where-Object { Test-Path $_ } | Select-Object -First 1
}

# Per-ABI NDK bits + FPC codegen flags. (x86_64 is for emulators; the NDK names
# its x86_64 gcc toolchain 'x86_64-4.9', not the -linux-android- form.)
function Ndk-BinDir($ndk, $abi) {
  $tc = switch ($abi) { 'armeabi-v7a' { 'arm-linux-androideabi-4.9' } 'x86_64' { 'x86_64-4.9' } default { 'aarch64-linux-android-4.9' } }
  Join-Path $ndk "toolchains\$tc\prebuilt\windows-x86_64\bin"
}
function Ndk-Prefix($abi) { switch ($abi) { 'armeabi-v7a' { 'arm-linux-androideabi-' } 'x86_64' { 'x86_64-linux-android-' } default { 'aarch64-linux-android-' } } }
function Ndk-SysLib($ndk, $abi, $api) {
  $triple = switch ($abi) { 'armeabi-v7a' { 'arm-linux-androideabi' } 'x86_64' { 'x86_64-linux-android' } default { 'aarch64-linux-android' } }
  Join-Path $ndk "toolchains\llvm\prebuilt\windows-x86_64\sysroot\usr\lib\$triple\$api"
}
function Fpc-AbiFlags($abi) { switch ($abi) { 'armeabi-v7a' { @('-Parm','-CpARMV7A','-CfVFPV3') } 'x86_64' { @('-Px86_64') } default { @('-Paarch64') } } }

# numeric key from tina4.json (Get-T4 only does strings)
function Get-T4Num($proj, $key, $default) {
  $f = Join-Path $proj 'tina4.json'; if (-not (Test-Path $f)) { return $default }
  $m = [regex]::Match((Get-Content $f -Raw), '"' + [regex]::Escape($key) + '"\s*:\s*([0-9]+)')
  if ($m.Success) { return [int]$m.Groups[1].Value } else { return $default }
}

# Ensure a debug keystore exists (each host makes its own; it is gitignored).
function Ensure-DebugKeystore($jdk) {
  $ks = Join-Path $Root 'android\debug.keystore'
  if (Test-Path $ks) { return $ks }
  $kt = Join-Path $jdk 'bin\keytool.exe'
  if (-not (Test-Path $kt)) { return $null }
  & $kt -genkeypair -keystore $ks -storepass android -keypass android -alias androiddebugkey `
        -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Android Debug,O=Android,C=US" 2>&1 | Out-Null
  if (Test-Path $ks) { return $ks } else { return $null }
}

# Build a scaffolded project into a signed APK, entirely on Windows.
function Build-ProjectAndroid($proj) {
  $fpc = Find-Fpc
  if (-not $fpc) { Write-Host "fpc.exe not found - run doctor" -ForegroundColor Red; return $null }
  # 0. toolchain resolution (explicit; nothing from PATH)
  $sdk = Resolve-AndroidSdk
  if (-not $sdk) { Write-Host "Android SDK not found - set ANDROID_HOME or install it (Android Studio / cmdline-tools)." -ForegroundColor Red; return $null }
  $ndk = Resolve-AndroidNdk $sdk
  if (-not $ndk) { Write-Host "Android NDK r21x not found - run: tools\tina4pascal.ps1 setup android" -ForegroundColor Red; return $null }
  $jdk = Resolve-Jdk
  if (-not $jdk) { Write-Host "JDK (javac) not found - set JAVA_HOME or install a JDK 17+." -ForegroundColor Red; return $null }
  $bt  = Resolve-BuildTools $sdk
  if (-not $bt) { Write-Host "Android build-tools not found under $sdk\build-tools." -ForegroundColor Red; return $null }
  $jar = Resolve-PlatformJar $sdk
  if (-not $jar) { Write-Host "No android.jar platform found under $sdk\platforms." -ForegroundColor Red; return $null }

  $name   = Get-T4 $proj 'name' (Split-Path -Leaf $proj)
  $title  = Get-T4 $proj 'title' $name
  $bundle = Get-T4 $proj 'bundleId' "com.tina4.$name"
  $minsdk = Get-T4Num $proj 'androidMinSdk' 21
  $tgtsdk = Get-T4Num $proj 'androidTargetSdk' 34
  # default = real-device ABIs; override via tina4.json "androidAbis" or
  # $env:TINA4_ANDROID_ABIS (e.g. add x86_64 to run on an emulator).
  $abis   = @('arm64-v8a','armeabi-v7a')
  $cfgAbis = Get-T4 $proj 'androidAbis' ''
  if ($env:TINA4_ANDROID_ABIS) { $abis = @($env:TINA4_ANDROID_ABIS -split '[,; ]+' | Where-Object { $_ }) }
  elseif ($cfgAbis) { $abis = @($cfgAbis -split '[,; ]+' | Where-Object { $_ }) }

  # every ABI needs its cross installed
  foreach ($abi in $abis) {
    if (-not (Test-AndroidCross $abi)) {
      Write-Host "FPC android cross for $abi not installed - run: tools\tina4pascal.ps1 setup android" -ForegroundColor Red; return $null
    }
  }

  Write-Host "Building $name -> APK ($bundle) for $($abis -join ', ')" -ForegroundColor Cyan
  $work = Join-Path $proj 'build\android'
  $host_ = Join-Path $work 'host'; $aout = Join-Path $work 'out'
  Remove-Item $host_,$aout -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $work,(Join-Path $aout 'classes') | Out-Null

  # 1. render the project UI -> showcase.html (build the win host, then --dump-html)
  $winexe = Build-ProjectWin $proj 'win64' $false
  if (-not $winexe) { Write-Host "could not build desktop host to render UI" -ForegroundColor Red; return $null }
  $idx = Join-Path $work 'index.html'
  & $winexe --dump-html $idx | Out-Null
  if (-not (Test-Path $idx)) { Write-Host "could not render entry template (--dump-html)" -ForegroundColor Red; return $null }

  # 2. stage the reference android host + overlay project bits
  New-Item -ItemType Directory -Force -Path $host_ | Out-Null
  Copy-Item -Path (Join-Path $Root 'android\*') -Destination $host_ -Recurse -Force
  $appdir = Join-Path $host_ 'app\src\main'
  Remove-Item (Join-Path $appdir 'jniLibs') -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path (Join-Path $appdir 'assets') | Out-Null
  Copy-Item $idx (Join-Path $appdir 'assets\showcase.html') -Force
  if (Test-Path (Join-Path $proj 'assets')) { Copy-Item (Join-Path $proj 'assets\*') (Join-Path $appdir 'assets') -Recurse -Force -ErrorAction SilentlyContinue }
  $picon = Join-Path $proj 'assets\icon.png'
  if (Test-Path $picon) { Get-ChildItem (Join-Path $appdir 'res') -Recurse -Filter 'ic_launcher*.png' | ForEach-Object { Copy-Item $picon $_.FullName -Force } }

  # 3. native lib per ABI: fpc cross -> libtina4.so
  foreach ($abi in $abis) {
    $o = Join-Path $appdir "jniLibs\$abi"; New-Item -ItemType Directory -Force -Path $o | Out-Null
    $bindir = Ndk-BinDir $ndk $abi; $prefix = Ndk-Prefix $abi; $syslib = Ndk-SysLib $ndk $abi $minsdk
    Write-Host "  fpc $abi -> libtina4.so" -ForegroundColor DarkGray
    $fa = @('-Mdelphi') + (Fpc-AbiFlags $abi) + @('-Tandroid','-O2','-Xs',
           "-XP$prefix","-FD$bindir","-Fl$syslib","-Fu$Src",
           "-FE$o","-FU$o","-o$o\libtina4.so",(Join-Path $host_ 'jni\tina4jni.pas'))
    & $fpc @fa 2>&1 | Where-Object { $_ -match 'Error|Fatal|Can''t find' } | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    if (-not (Test-Path (Join-Path $o 'libtina4.so'))) { Write-Host "native build produced no .so ($abi)" -ForegroundColor Red; return $null }
  }

  # 4. java -> dex
  Write-Host "  javac + d8" -ForegroundColor DarkGray
  $javac = Join-Path $jdk 'bin\javac.exe'
  $javas = Get-ChildItem (Join-Path $appdir 'java') -Recurse -Filter '*.java' | ForEach-Object { $_.FullName }
  & $javac --release 21 -classpath $jar -d (Join-Path $aout 'classes') @javas 2>&1 | Where-Object { $_ -match 'error:' } | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
  $classes = Get-ChildItem (Join-Path $aout 'classes') -Recurse -Filter '*.class' | ForEach-Object { $_.FullName }
  & (Join-Path $bt 'd8.bat') --min-api $minsdk --lib $jar --output $aout @classes 2>&1 | Where-Object { $_ -match 'error|Exception' } | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
  if (-not (Test-Path (Join-Path $aout 'classes.dex'))) { Write-Host "d8 produced no dex" -ForegroundColor Red; return $null }

  # 5. resources + manifest (rename applicationId to the project bundleId)
  $res = @()
  if (Test-Path (Join-Path $appdir 'res')) { & (Join-Path $bt 'aapt2.exe') compile --dir (Join-Path $appdir 'res') -o (Join-Path $aout 'res.zip') | Out-Null; $res = @((Join-Path $aout 'res.zip')) }
  $manifest = Get-Content (Join-Path $appdir 'AndroidManifest.xml') -Raw
  $manifest = $manifest -replace '<manifest ', '<manifest package="com.tina4.pascal" '
  $manifest = $manifest -replace 'android:name="\.MainActivity"', 'android:name="com.tina4.pascal.MainActivity"'
  $manifest = $manifest -replace 'android:label="[^"]*"', "android:label=`"$title`""
  $pm = Join-Path $aout 'AndroidManifest.xml'; [System.IO.File]::WriteAllText($pm, $manifest)
  & (Join-Path $bt 'aapt2.exe') link -o (Join-Path $aout 'base.apk') -I $jar --manifest $pm `
      --rename-manifest-package $bundle --custom-package com.tina4.pascal `
      --min-sdk-version $minsdk --target-sdk-version $tgtsdk -A (Join-Path $appdir 'assets') @res 2>&1 |
      Where-Object { $_ -match 'error' } | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
  if (-not (Test-Path (Join-Path $aout 'base.apk'))) { Write-Host "aapt2 link failed" -ForegroundColor Red; return $null }

  # 6. add dex + native libs, align, sign
  Push-Location $aout
  try {
    New-Item -ItemType Directory -Force -Path 'lib' | Out-Null
    foreach ($abi in $abis) { $s = Join-Path $appdir "jniLibs\$abi\libtina4.so"; if (Test-Path $s) { New-Item -ItemType Directory -Force -Path "lib\$abi" | Out-Null; Copy-Item $s "lib\$abi\" -Force } }
    $zip = Join-Path (Fpc-Bin) 'zip.exe'
    & $zip -qr 'base.apk' 'classes.dex' 'lib' | Out-Null
  } finally { Pop-Location }
  & (Join-Path $bt 'zipalign.exe') -f -p 4 (Join-Path $aout 'base.apk') (Join-Path $aout 'aligned.apk') | Out-Null

  $apk = Join-Path $work "$name.apk"
  $ks = Ensure-DebugKeystore $jdk
  if ($env:TINA4_KEYSTORE) {
    & (Join-Path $bt 'apksigner.bat') sign --ks $env:TINA4_KEYSTORE --ks-pass "pass:$env:TINA4_KS_PASS" `
        --ks-key-alias $env:TINA4_KEY_ALIAS --key-pass ("pass:" + $(if ($env:TINA4_KEY_PASS) { $env:TINA4_KEY_PASS } else { $env:TINA4_KS_PASS })) `
        --out $apk (Join-Path $aout 'aligned.apk') 2>&1 | Where-Object { $_ -match 'error|Exception' } | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
  } elseif ($ks) {
    & (Join-Path $bt 'apksigner.bat') sign --ks $ks --ks-pass pass:android --key-pass pass:android --out $apk (Join-Path $aout 'aligned.apk') 2>&1 |
        Where-Object { $_ -match 'error|Exception' } | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
  } else { Write-Host "no keystore and no keytool to make one" -ForegroundColor Red; return $null }

  if (Test-Path $apk) {
    Ok "APK -> $apk ($([math]::Round((Get-Item $apk).Length/1KB)) KB)"
    Write-Host "  applicationId $bundle" -ForegroundColor DarkGray
    Write-Host "  install:  adb install -r `"$apk`"" -ForegroundColor DarkGray
    Write-Host "  launch:   adb shell am start -n $bundle/com.tina4.pascal.MainActivity" -ForegroundColor DarkGray
    return $apk
  }
  Write-Host "APK signing failed" -ForegroundColor Red; return $null
}

# Is the current directory a Tina4Pascal project?
function Project-Root { if (Test-Path (Join-Path (Get-Location) 'tina4.json')) { return (Get-Location).Path } else { return $null } }

if ($cmd -eq 'doctor') {
  Invoke-Doctor
} elseif ($cmd -eq 'setup') {
  if ($target -eq 'android') {
    # Provision the Android cross toolchain: build it from FPC source + NDK and
    # install into the FPC tree. (A future release will fetch a prebuilt,
    # version-matched pack first and only build as a fallback.)
    $builder = Join-Path $PSScriptRoot '..\toolchain\build-android-cross.ps1'
    if (-not (Test-Path $builder)) { Write-Host "builder not found: $builder" -ForegroundColor Red }
    else {
      Write-Host "Provisioning the FPC -> Android cross toolchain (first run downloads the NDK and builds the cross; ~15 min)..." -ForegroundColor Cyan
      & $builder -Install
    }
  } else {
    Write-Host "usage: tina4pascal.ps1 setup android" -ForegroundColor Yellow
  }
} elseif ($cmd -eq 'init') {
  Invoke-Init $target ($page -eq '--no-run')
} elseif ($cmd -eq 'build') {
  $pr = Project-Root
  if ($pr) { Build-Project $pr $target | Out-Null }   # inside a project: build the app
  else { Invoke-Build $target | Out-Null }             # inside the framework: build the viewer
} elseif ($cmd -eq 'run') {
  $pr = Project-Root
  if ($pr) {
    $exe = Build-Project $pr $target
    if ($exe) { Write-Host "-> running"; Start-Process -FilePath $exe -WorkingDirectory $pr }
  } else {
    $exe = Invoke-Build $target
    if ($exe) {
      if (-not $page) { $page = Join-Path $View 'win-test.html' }
      Write-Host "-> $page"
      Start-Process -FilePath $exe -ArgumentList $page -WorkingDirectory $View
    }
  }
} elseif ($cmd -eq 'where') {
  $pr = Project-Root
  if ($pr) { Write-Host (Join-Path (Join-Path $pr "build\$target") ((Split-Path -Leaf $pr) + '.exe')) }
  else { Write-Host (Join-Path (Join-Path $Build $target) 'htmlviewer_win.exe') }
} elseif ($cmd -eq 'render') {
  $pr = Project-Root
  if (-not $pr) { Write-Host "render: run inside a project dir" -ForegroundColor Red }
  else {
    $t = if ($target) { $target } else { 'win64' }
    $exe = Build-Project $pr $t
    if ($exe) {
      $img = if ($page) { $page } else { Join-Path $pr 'shot.png' }
      & $exe --snapshot $img --width 900 --height 640
      Start-Sleep -Milliseconds 600
      if (Test-Path $img) { Ok "rendered: $img"; Write-Host $img } else { Write-Host "no snapshot" -ForegroundColor Red }
    }
  }
} elseif ($cmd -eq 'dom' -or $cmd -eq 'boxes' -or $cmd -eq 'inspect') {
  $pr = Project-Root
  if (-not $pr) { Write-Host "${cmd}: run inside a project dir" -ForegroundColor Red }
  else {
    $exe = Build-Project $pr 'win64'
    if ($exe) {
      $out = Join-Path $pr ".tina4-$cmd.json"
      if ($cmd -eq 'inspect') { & $exe --inspect $target $page $out --width 1024 --height 800 }
      elseif ($cmd -eq 'boxes') { & $exe --boxes $out --width 1024 --height 800 }
      else { & $exe --dom $out --width 1024 --height 800 }
      Start-Sleep -Milliseconds 400
      if (Test-Path $out) { Get-Content $out -Raw } else { Write-Host "no output" -ForegroundColor Red }
    }
  }
} elseif ($cmd -eq 'debug') {
  $pr = Project-Root
  if (-not $pr) { Write-Host "debug: run inside a project dir" -ForegroundColor Red }
  else {
    $exe = Build-ProjectDebug $pr 'win64'
    if ($exe) {
      $gdb = (Get-Command gdb -ErrorAction SilentlyContinue).Source
      if (-not $gdb) {
        $fg = Join-Path (Split-Path -Parent (Find-Fpc)) 'gdb.exe'
        if (Test-Path $fg) { $gdb = $fg }
      }
      if (-not $gdb) { Write-Host "gdb not found - install one (choco install mingw) " -ForegroundColor Red }
      else {
        $img = Join-Path $env:TEMP 'tina4-dbg.png'
        $lines = @('set pagination off','set confirm off')
        if ($target -and $target -ne 'win64' -and $target -ne 'win32') { $lines += "break $target" }
        $lines += @('run','bt full','info locals','quit')
        $gcmd = Join-Path $env:TEMP 'tina4.gdb'
        [System.IO.File]::WriteAllText($gcmd, ($lines -join "`n") + "`n")
        Write-Host "gdb: run (headless) -> backtrace on crash"
        $ep = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
        $g = (& $gdb -q -batch -x $gcmd --args $exe --snapshot $img --width 1024 --height 800 2>&1 | Out-String)
        $ErrorActionPreference = $ep
        if ($g -match 'SIGSEGV|received signal|EAccessViolation|RunError|Access violation') {
          Write-Host $g
          Write-Host "-> crash caught (backtrace above)" -ForegroundColor Yellow
        } else {
          Ok "ran clean under gdb (no crash)"
        }
      }
    }
  }
} elseif ($cmd -eq 'script') {
  $pr = Project-Root
  if (-not $pr) { Write-Host "script: run inside a project dir" -ForegroundColor Red }
  elseif (-not $target -or -not (Test-Path $target)) { Write-Host "usage: tina4pascal.ps1 script <scriptfile>" -ForegroundColor Red }
  else {
    $sf = (Resolve-Path $target).Path
    $exe = Build-Project $pr 'win64'
    if ($exe) {
      & $exe --script $sf --width 1024 --height 800
      Ok "ran script $sf (snaps written to the paths its 'snap' lines name)"
    }
  }
} else {
  Write-Host "unknown command '$cmd' (doctor | setup android | init | build [win64|win32|linux|android|all] | run | render | dom | boxes | inspect | debug | script | where)"
}
