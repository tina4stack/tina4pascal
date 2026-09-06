# Code signing (Windows release)

Notes on signing the Windows deliverables — the FPC→Android cross pack and the
CLI — with the project's **Certum EV** code-signing certificate via
**SimplySign** (Certum's cloud key). The goal is to remove Windows SmartScreen /
Defender friction on downloaded binaries and satisfy PowerShell execution
policy for the script, and to let anyone verify a download is intact and ours.

## What gets signed (and what can't)

Authenticode signs **PE files** (`.exe`/`.dll`) and, via a signature block,
**PowerShell scripts** (`.ps1`). It does **not** sign `.zip` or FPC `.ppu`/`.o`.

| Artifact | Method | Note |
|---|---|---|
| `ppcrossa64.exe`, `ppcrossarm.exe`, `ppcrossx64.exe` (pack) | `signtool` Authenticode | the compiler binaries we ship |
| `tina4pascal.ps1` (CLI) | `Set-AuthenticodeSignature` | sign a **release copy**, not the git source (a later edit invalidates the block) |
| `tina4-fpc-android-cross-<ver>-win64.zip` | **not signable** | integrity via the `.sha256` beside it; the `.exe` inside carry the signature |
| the app's `.so` inside an APK | — | covered by the **APK** signature (`apksigner`), no separate step |
| the end-user APK | `apksigner` | debug key installs/runs anywhere; release key only for Play Store |

## Prerequisite — unlock the cloud key (manual, one-time per session)

SimplySign keeps the private key in Certum's cloud HSM. You must authenticate
before any signing tool can use it — this cannot be scripted (it needs the
mobile OTP):

1. Start **SimplySign Desktop** and log in (card ID + mobile one-time code).
2. It mounts the certificate as a virtual smart card, so it appears in
   `Cert:\CurrentUser\My` and `signtool` can select it.

Confirm it is available:

```powershell
Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Select Thumbprint, Subject, NotAfter
# → CN=Code Infinity (Pty) Ltd … Certum Extended Validation Code Signing 2021 CA
```

The signing scripts never see the credentials or OTP — they only drive
`signtool` / `Set-AuthenticodeSignature` against the already-unlocked cert.

## Signing a release

```powershell
# 1. build (and install) the cross pack — produces the .exe to sign
toolchain\build-android-cross.ps1 -Zip

# 2. sign the pack binaries + a staged CLI copy, then (re)zip + checksum
toolchain\sign-release.ps1 -PackDir build\android-cross\pack `
                           -Cli   build\release\tina4pascal.ps1 `
                           -Zip
```

`sign-release.ps1` uses, per binary:

```
signtool sign /fd sha256 /sha1 <thumbprint> /tr http://time.certum.pl /td sha256 /d "<desc>" <file>
signtool verify /pa <file>
```

- `/fd sha256` — SHA-256 file digest.
- `/tr … /td sha256` — **RFC3161 timestamp** from Certum, so signatures stay
  valid after the certificate expires. Always timestamp.
- `/sha1 <thumbprint>` — selects the EV cert (thumbprint
  `5F8628C6E64209D196553B09A272779458DB951A`); no PFX on disk, the key lives in
  SimplySign.
- The `.ps1` is signed with `Set-AuthenticodeSignature … -TimestampServer http://time.certum.pl`.

## Verify

```powershell
signtool verify /pa /v .\ppcrossa64.exe          # PE
Get-AuthenticodeSignature .\tina4pascal.ps1       # Status must be Valid
Get-FileHash .\tina4-fpc-android-cross-3.2.2-win64.zip -Algorithm SHA256   # match the .sha256
```

A good PE result shows the chain `Code Infinity (Pty) Ltd → Certum EV Code
Signing 2021 CA → …` and `The signature is timestamped`.

## Rules of thumb

- **Sign on every release.** The pack is rebuilt per FPC version (`.ppu` are
  version-stamped) and re-signed; keep the two steps together in CI.
- **Never commit signed binaries or a signed source `.ps1`** — signing is a
  packaging step, its outputs are release assets.
- **Always timestamp**, so artifacts outlive the cert.
- EV keys are non-exportable and cloud-held; there is no `.pfx` to leak — but it
  also means CI needs an authenticated SimplySign session (an interactive
  unlock, or Certum's automated/CI signing offering).
