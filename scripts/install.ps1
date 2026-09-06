<#
  Tina4Pascal one-line bootstrap (Windows).

    irm https://raw.githubusercontent.com/tina4stack/tina4pascal/main/scripts/install.ps1 | iex

  Fetches the framework, puts the CLI on your PATH, and runs doctor. FPC itself
  is fetched on your first `tina4pascal init` (or run `tina4pascal setup`).
  Override the location with $env:TINA4_HOME before running.
#>
$ErrorActionPreference = 'Stop'
$Repo = 'https://github.com/tina4stack/tina4pascal'
$Dir  = if ($env:TINA4_HOME) { $env:TINA4_HOME } else { Join-Path $env:LOCALAPPDATA 'tina4pascal' }

Write-Host "Installing Tina4Pascal -> $Dir" -ForegroundColor Cyan

# 1. get the source (git if present, else the branch zip)
if (Test-Path (Join-Path $Dir '.git')) {
  git -C $Dir pull --ff-only
} elseif (Get-Command git -ErrorAction SilentlyContinue) {
  git clone --depth 1 "$Repo.git" $Dir
} else {
  $zip = Join-Path $env:TEMP 'tina4pascal-main.zip'
  Invoke-WebRequest "$Repo/archive/refs/heads/main.zip" -OutFile $zip -UseBasicParsing
  $tmp = Join-Path $env:TEMP ('t4p-' + [guid]::NewGuid().ToString('N'))
  Expand-Archive $zip -DestinationPath $tmp -Force
  if (Test-Path $Dir) { Remove-Item $Dir -Recurse -Force }
  Move-Item (Join-Path $tmp 'tina4pascal-main') $Dir
  Remove-Item $zip,$tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# 2. a `tina4pascal` command on PATH: a .cmd shim that forwards to the .ps1
$binDir = Join-Path $Dir 'bin'
New-Item -ItemType Directory -Force -Path $binDir | Out-Null
$shim = Join-Path $binDir 'tina4pascal.cmd'
@"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\tina4pascal.ps1" %*
"@ | Set-Content $shim -Encoding ascii

$userPath = [Environment]::GetEnvironmentVariable('Path','User')
if (($userPath -split ';') -notcontains $binDir) {
  [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $binDir), 'User')
  $env:Path += ';' + $binDir
  Write-Host "Added $binDir to your PATH (open a new terminal to pick it up)." -ForegroundColor DarkGray
}

# 3. report the toolchain
& (Join-Path $Dir 'tools\tina4pascal.ps1') doctor

Write-Host ""
Write-Host "Tina4Pascal installed. Get started:" -ForegroundColor Green
Write-Host "  tina4pascal init hello    # scaffold + build + run (installs FPC on first run)" -ForegroundColor Green
Write-Host "  tina4pascal setup android # optional: NDK + FPC Android cross" -ForegroundColor DarkGray
