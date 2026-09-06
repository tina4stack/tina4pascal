<#
  sign-release.ps1 - Authenticode-sign the Tina4Pascal Windows release artifacts
  with the Certum EV code-signing certificate via SimplySign.

  Signs:
    - the FPC->Android cross-pack compiler binaries (ppcross*.exe)
    - the Windows CLI script(s) (.ps1)  [signs staged copies, see note]

  PRECONDITION (cannot be automated — it needs YOU):
    Start SimplySign Desktop and authenticate (mobile OTP). That mounts the
    cloud EV certificate as a virtual smart card so it appears in
    Cert:\CurrentUser\My and signtool can use it. This script never sees your
    credentials; it only drives signtool/Set-AuthenticodeSignature against the
    already-unlocked cert.

  NOTE on the CLI: we sign a *release copy*, not the source-controlled .ps1.
  Set-AuthenticodeSignature appends a signature block to the file, which any
  later edit invalidates — so signing belongs at packaging time, not in git.

  What Authenticode canNOT sign: .zip and .ppu/.o are not PE files. The pack zip
  is covered by its .sha256 (build-android-cross.ps1 -Zip); the *.exe inside it
  carry the Authenticode signature.

  Usage:
    toolchain\sign-release.ps1 -PackDir <dir> [-Cli <path.ps1>[,<path2>]]
                               [-Thumbprint <hex>] [-TimestampUrl <url>] [-Zip]
#>
[CmdletBinding()]
param(
  [string]$PackDir = '',
  [string[]]$Cli = @(),
  [string]$Thumbprint = '',
  [string]$TimestampUrl = 'http://time.certum.pl',
  [switch]$Zip
)
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot

function Say($m) { Write-Host $m -ForegroundColor Cyan }
function Die($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

# ── locate signtool (Windows SDK) ─────────────────────────────────────
$signtool = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -match '\\x64\\' } | Sort-Object FullName -Descending | Select-Object -First 1
if (-not $signtool) { Die "signtool.exe not found - install the Windows 10/11 SDK" }
$signtool = $signtool.FullName

# ── resolve the EV code-signing cert (must be unlocked via SimplySign) ─
if (-not $Thumbprint) {
  $cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $cert) { Die "no code-signing cert in Cert:\CurrentUser\My - start SimplySign Desktop and authenticate first" }
  $Thumbprint = $cert.Thumbprint
} else {
  $cert = Get-Item "Cert:\CurrentUser\My\$Thumbprint" -ErrorAction SilentlyContinue
  if (-not $cert) { Die "cert $Thumbprint not found - is SimplySign Desktop authenticated?" }
}
Say "signing identity: $($cert.Subject)"
Say "thumbprint: $Thumbprint"
Say "timestamp:  $TimestampUrl"

function Sign-Pe($file, $desc) {
  & $signtool sign /fd sha256 /sha1 $Thumbprint /tr $TimestampUrl /td sha256 /d $desc $file
  if ($LASTEXITCODE -ne 0) { Die "signtool failed on $file" }
  & $signtool verify /pa /q $file
  if ($LASTEXITCODE -ne 0) { Die "signature verify failed on $file" }
  Say "  signed + verified: $(Split-Path -Leaf $file)"
}

# ── sign the pack's compiler binaries ─────────────────────────────────
if ($PackDir) {
  if (-not (Test-Path $PackDir)) { Die "pack dir not found: $PackDir" }
  $exes = Get-ChildItem $PackDir -Recurse -Filter '*.exe'
  if (-not $exes) { Die "no .exe found under $PackDir" }
  Say "=== signing $($exes.Count) pack binaries ==="
  foreach ($e in $exes) { Sign-Pe $e.FullName "Tina4Pascal FPC Android cross" }
}

# ── sign CLI script(s) — staged copies ────────────────────────────────
if ($Cli.Count) {
  Say "=== signing $($Cli.Count) CLI script(s) ==="
  foreach ($c in $Cli) {
    if (-not (Test-Path $c)) { Die "CLI not found: $c" }
    $sig = Set-AuthenticodeSignature -FilePath $c -Certificate $cert -HashAlgorithm SHA256 -TimestampServer $TimestampUrl
    if ($sig.Status -ne 'Valid') { Die "Set-AuthenticodeSignature: $($sig.Status) - $($sig.StatusMessage) ($c)" }
    Say "  signed + valid: $(Split-Path -Leaf $c)"
  }
}

# ── (re)zip the signed pack + checksum ────────────────────────────────
if ($Zip -and $PackDir) {
  $fpcVer = '3.2.2'
  $mani = Join-Path $PackDir 'tina4-android-cross.json'
  if (Test-Path $mani) { try { $fpcVer = (Get-Content $mani -Raw | ConvertFrom-Json).fpc } catch {} }
  $zipOut = Join-Path (Split-Path -Parent $PackDir) "tina4-fpc-android-cross-$fpcVer-win64.zip"
  Remove-Item $zipOut -Force -ErrorAction SilentlyContinue
  Compress-Archive -Path (Join-Path $PackDir '*') -DestinationPath $zipOut
  $sha = (Get-FileHash $zipOut -Algorithm SHA256).Hash.ToLower()
  "$sha  $(Split-Path -Leaf $zipOut)" | Set-Content "$zipOut.sha256" -Encoding ascii
  Say "release asset: $zipOut"
  Say "sha256: $sha"
}

Say "done."
