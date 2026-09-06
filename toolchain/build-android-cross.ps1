<#
  build-android-cross.ps1 - build the FPC -> Android cross toolchain on a
  Windows host and emit a version-locked, drop-in pack.

  Stock FPC ships no Android cross-compiler. This script builds one from FPC
  source against an Android NDK, then assembles a pack that a plain
  `fpc -Tandroid -P{aarch64|arm}` can use with no source tree:

      ppcrossa64.exe / ppcrossarm.exe        (host i386-win32 exes, target ARM)
      units/{aarch64,arm}-android/rtl/*      (cross RTL)
      units/{aarch64,arm}-android/jni/*      (JNI bindings)
      units/{aarch64,arm}-android/fpkg/*     (DateUtils, fpjson, generics, ...)

  Everything here is version-locked to the FPC that builds it (.ppu carry an
  FPC-version stamp), so THIS SCRIPT IS THE "build on each release" step: run it
  in CI on a Windows runner whenever the pinned FPC changes, and publish the zip
  as a release asset named tina4-fpc-android-cross-<fpcver>-win64.zip.

  Why NDK r21e: it is the last NDK that still ships the GNU binutils
  (aarch64-linux-android-as / -ld) FPC 3.2.2 drives directly. r23+ went
  LLVM-only and would need assembler/linker wrapper shims.

  Usage:
    toolchain\build-android-cross.ps1 [-FpcSource <dir>] [-Ndk <dir>]
                                      [-Out <dir>] [-Install] [-Zip]
      -FpcSource  FPC source tree at the matching version (default: clone
                  release_3_2_2 into <Out>\fpc-src).
      -Ndk        Android NDK r21x dir (default: resolve/download r21e).
      -Out        work dir (default: <repo>\build\android-cross).
      -Install    drop the pack into the active FPC install (C:\FPC\<ver>).
      -Zip        emit the release zip under <Out>.
#>
[CmdletBinding()]
param(
  [string]$FpcSource = '',
  [string]$Ndk = '',
  [string]$Out = '',
  [switch]$Install,
  [switch]$Zip
)
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $Out) { $Out = Join-Path $RepoRoot 'build\android-cross' }
New-Item -ItemType Directory -Force -Path $Out | Out-Null

$NDK_VER  = 'r21e'
$NDK_URL  = "https://dl.google.com/android/repository/android-ndk-$NDK_VER-windows-x86_64.zip"
$FPC_TAG  = 'release_3_2_2'
$FPC_GIT  = 'https://gitlab.com/freepascal.org/fpc/source.git'

function Say($m)  { Write-Host $m -ForegroundColor Cyan }
function Die($m)  { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

# ── locate the host FPC (the starting compiler) ───────────────────────
function Find-Fpc {
  $c = Get-Command fpc.exe -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  $hit = Get-ChildItem 'C:\FPC' -Recurse -Filter fpc.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($hit) { return $hit.FullName }
  Die "host FPC not found (install FPC 3.2.2 first)"
}
$FpcExe  = Find-Fpc
$FpcBin  = Split-Path -Parent $FpcExe
$Ppc386  = Join-Path $FpcBin 'ppc386.exe'
$MakeExe = Join-Path $FpcBin 'make.exe'
$ZipExe  = Join-Path $FpcBin 'zip.exe'
$FpcVer  = (& $FpcExe -iV).Trim()
Say "host FPC $FpcVer at $FpcBin"
if (-not (Test-Path $Ppc386))  { Die "ppc386.exe missing next to fpc.exe" }
if (-not (Test-Path $MakeExe)) { Die "make.exe missing (FPC bundles it)" }

# ── resolve / fetch the NDK ───────────────────────────────────────────
if (-not $Ndk) {
  $sdk = @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, (Join-Path $env:LOCALAPPDATA 'Android\Sdk')) |
         Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
  if ($sdk) {
    $cand = Get-ChildItem (Join-Path $sdk 'ndk') -Directory -Filter 'android-ndk-r21*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cand) { $Ndk = $cand.FullName }
  }
}
if (-not $Ndk -or -not (Test-Path (Join-Path $Ndk 'toolchains\aarch64-linux-android-4.9'))) {
  $zip = Join-Path $Out "android-ndk-$NDK_VER.zip"
  if (-not (Test-Path $zip)) { Say "downloading NDK $NDK_VER (~1 GB)"; & curl.exe -L -o $zip $NDK_URL; if ($LASTEXITCODE -ne 0) { Die "NDK download failed" } }
  Say "extracting NDK"
  & $ZipExe -q $zip -d $Out 2>$null   # zip.exe cannot unzip; fall back to Expand-Archive
  if (-not (Test-Path (Join-Path $Out "android-ndk-$NDK_VER"))) { Expand-Archive -Path $zip -DestinationPath $Out -Force }
  $Ndk = Join-Path $Out "android-ndk-$NDK_VER"
}
if (-not (Test-Path (Join-Path $Ndk 'toolchains\aarch64-linux-android-4.9'))) { Die "NDK r21x with GNU binutils required at $Ndk" }
Say "NDK: $Ndk"

# ── FPC source at the matching version ────────────────────────────────
if (-not $FpcSource) { $FpcSource = Join-Path $Out 'fpc-src' }
if (-not (Test-Path (Join-Path $FpcSource 'compiler\pp.pas'))) {
  Say "cloning FPC source ($FPC_TAG)"
  & git.exe clone --depth 1 --branch $FPC_TAG $FPC_GIT $FpcSource
  if ($LASTEXITCODE -ne 0) { Die "FPC source clone failed" }
}
Say "FPC source: $FpcSource"

# ── per-ABI build ─────────────────────────────────────────────────────
# We build the cross compiler via `make buildbase` (compiler_cycle builds
# ppcross<cpu> as a byproduct; its final native-compiler link fails for lack of
# an android sysroot, which we do not need), then build the RTL directly with
# that cross compiler (RTL only assembles -> no link), then the jni + fpkg units
# by compiling the JNI bridge with the FPC-source package dirs on the unit path.
$env:MSYS_NO_PATHCONV = '1'; $env:MSYS2_ARG_CONV_EXCL = '*'
$Pack = Join-Path $Out 'pack'
Remove-Item $Pack -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path (Join-Path $Pack 'bin\i386-win32') | Out-Null

$FPKG = @('contnrs','dateutils','fpjson','generics.collections','generics.defaults',
          'generics.hashes','generics.helpers','generics.memoryexpanders','generics.strings',
          'jsonparser','jsonreader','jsonscanner','syncobjs','variants','varutils')

function Build-Abi($cpu, $target, $suf, $tc, $prefix, $abiOpt, $abiFlags) {
  Say "=== building $target ($cpu) cross ==="
  $crossbin = Join-Path $Ndk "toolchains\$tc\prebuilt\windows-x86_64\bin"
  $ppcross  = Join-Path $FpcSource "compiler\ppcross$suf.exe"
  $u        = "$target-android"

  # 1. cross compiler (byproduct of buildbase; native stage is expected to fail)
  Push-Location $FpcSource
  try {
    & $MakeExe buildbase "CPU_TARGET=$cpu" OS_TARGET=android "FPC=$Ppc386" `
        "CROSSBINDIR=$crossbin" "BINUTILSPREFIX=$prefix" OVERRIDEVERSIONCHECK=1 *> (Join-Path $Out "log-compiler-$suf.txt")
  } catch {} finally { Pop-Location }
  if (-not (Test-Path $ppcross)) { Die "cross compiler ppcross$suf.exe not produced (see log-compiler-$suf.txt)" }

  # 2. cross RTL
  Push-Location $FpcSource
  try {
    $rtlArgs = @('-C','rtl','clean','all',"CPU_TARGET=$cpu",'OS_TARGET=android',"FPC=$ppcross",
                 "CROSSBINDIR=$crossbin","BINUTILSPREFIX=$prefix",'OVERRIDEVERSIONCHECK=1')
    if ($abiOpt) { $rtlArgs += "CROSSOPT=$abiOpt" }
    & $MakeExe @rtlArgs *> (Join-Path $Out "log-rtl-$suf.txt")
  } finally { Pop-Location }
  $rtlU = Join-Path $FpcSource "rtl\units\$u"
  if (-not (Test-Path (Join-Path $rtlU 'system.ppu'))) { Die "cross RTL for $u not produced (see log-rtl-$suf.txt)" }

  # 3. jni + fpkg: compile the JNI bridge with FPC-source package dirs so the
  #    compiler auto-builds every used unit; harvest what we need.
  $crossbinLib = Join-Path $Ndk ("toolchains\llvm\prebuilt\windows-x86_64\sysroot\usr\lib\" + `
                 $(if ($cpu -eq 'arm') {'arm-linux-androideabi'} else {'aarch64-linux-android'}) + "\21")
  $harvest = Join-Path $Out "harvest-$suf"; Remove-Item $harvest -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force -Path $harvest | Out-Null
  $P = Join-Path $FpcSource 'packages'
  $fu = @("-Fu$RepoRoot\src","-Fu$P\jni\src","-Fu$P\rtl-objpas\src\inc","-Fu$P\rtl-objpas\src\common",
          "-Fu$P\rtl-generics\src","-Fu$P\fcl-json\src","-Fu$P\fcl-base\src","-Fu$P\fcl-base\src\unix",
          "-Fu$P\fcl-image\src","-Fu$P\paszlib\src","-Fu$P\hash\src","-Fu$rtlU")
  $fi = @("-Fi$P\rtl-objpas\src\inc","-Fi$P\rtl-generics\src","-Fi$P\fcl-json\src","-Fi$P\fcl-base\src","-Fi$P\fcl-image\src","-Fi$P\paszlib\src")
  $args = @('-Mdelphi','-Tandroid') + $abiFlags + @('-O2','-Xs',"-XP$prefix","-FD$crossbin","-Fl$crossbinLib") + $fu + $fi + @("-FE$harvest","-FU$harvest","-o$harvest\libtina4.so",(Join-Path $RepoRoot 'android\jni\tina4jni.pas'))
  & $ppcross @args *> (Join-Path $Out "log-units-$suf.txt")
  if (-not (Test-Path (Join-Path $harvest 'jni.ppu'))) { Die "jni/fpkg units for $u not produced (see log-units-$suf.txt)" }

  # 4. assemble this ABI into the pack
  Copy-Item $ppcross (Join-Path $Pack "bin\i386-win32\ppcross$suf.exe") -Force
  foreach ($sub in 'rtl','jni','fpkg') { New-Item -ItemType Directory -Force -Path (Join-Path $Pack "units\$u\$sub") | Out-Null }
  Copy-Item (Join-Path $rtlU '*.ppu') (Join-Path $Pack "units\$u\rtl") -Force
  Copy-Item (Join-Path $rtlU '*.o')   (Join-Path $Pack "units\$u\rtl") -Force
  Copy-Item (Join-Path $harvest 'jni.ppu') (Join-Path $Pack "units\$u\jni") -Force
  Copy-Item (Join-Path $harvest 'jni.o')   (Join-Path $Pack "units\$u\jni") -Force
  foreach ($f in $FPKG) {
    Copy-Item (Join-Path $harvest "$f.ppu") (Join-Path $Pack "units\$u\fpkg") -Force -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $harvest "$f.o")   (Join-Path $Pack "units\$u\fpkg") -Force -ErrorAction SilentlyContinue
  }
  Say "  $u: ppcross$suf.exe + $((Get-ChildItem (Join-Path $Pack "units\$u") -Recurse -Filter *.ppu).Count) units"
}

Build-Abi 'aarch64' 'aarch64' 'a64' 'aarch64-linux-android-4.9' 'aarch64-linux-android-' '' @('-Paarch64')
Build-Abi 'arm'     'arm'     'arm' 'arm-linux-androideabi-4.9' 'arm-linux-androideabi-' '-CpARMV7A -CfVFPV3' @('-Parm','-CpARMV7A','-CfVFPV3')

# manifest for provenance
@{ fpc = $FpcVer; ndk = $NDK_VER; host = 'win64'; abis = @('arm64-v8a','armeabi-v7a'); built = (Get-Date -Format o) } |
  ConvertTo-Json | Set-Content (Join-Path $Pack 'tina4-android-cross.json') -Encoding utf8

Say "pack assembled at $Pack"

if ($Install) {
  $fpcInstallRoot = Split-Path -Parent $FpcBin        # ...\bin
  $fpcInstallRoot = Split-Path -Parent $fpcInstallRoot # FPC root
  Say "installing pack into $fpcInstallRoot"
  Copy-Item (Join-Path $Pack 'bin\i386-win32\*') (Join-Path $fpcInstallRoot 'bin\i386-win32') -Force
  Copy-Item (Join-Path $Pack 'units\*') (Join-Path $fpcInstallRoot 'units') -Recurse -Force
  Say "installed."
}

if ($Zip) {
  $zipOut = Join-Path $Out "tina4-fpc-android-cross-$FpcVer-win64.zip"
  Remove-Item $zipOut -Force -ErrorAction SilentlyContinue
  Compress-Archive -Path (Join-Path $Pack '*') -DestinationPath $zipOut
  Say "release asset: $zipOut ($([math]::Round((Get-Item $zipOut).Length/1MB,1)) MB)"
}
