# Releasing the macOS artifact

The macOS (and iOS) build/sign step runs **on a Mac** — GitHub-hosted runners
can't do the notarization/Apple signing, and we keep one GPG verification scheme
across every OS. Windows and Linux artifacts are already built + signed and
attached to the release; this covers the macOS piece.

The fast path is `tools/release-macos.sh`; the manual steps are below it.

## Prerequisites (once)

```bash
xcode-select --install          # linker + tools (full Xcode only if you also ship iOS)
brew install fpc gnupg gh
gh auth login                   # if not already authenticated
git clone git@github.com:tina4stack/tina4pascal.git && cd tina4pascal
```

Import the **release signing key** (dedicated key, RSA-4096, no passphrase).
Copy `tina4pascal-release-private.asc` from the secure backup
(`C:\Users\andre\tokens\tina4pascal-signing\` on the Windows box) over a private
channel — AirDrop / USB, **not** email — then:

```bash
gpg --import tina4pascal-release-private.asc
# delete the copy afterwards if you don't want a passphrase-less key lingering:
#   rm -P tina4pascal-release-private.asc
```

Key fingerprint: `E0B36CDD76676DD08E4F1FA641DA6E7645F494AF`
(uid: `Tina4Pascal Release Signing <andrevanzuydam@gmail.com>`).

## One command

```bash
bash tools/release-macos.sh v1.0.0
```

It builds the viewer, smoke-renders it, packages `tina4-htmlviewer-macos-<arch>.tar.gz`
(+ `.sha256`), GPG-signs it (`.asc`), verifies the signature, and uploads all
three to the release (replacing the CI-built unsigned tarball).

## Manual steps (what the script does)

```bash
# 1. build
bash tools/tina4pascal build macos            # → build/macos/htmlviewer

# 2. package (arch-named; use x86_64 on an Intel Mac)
cd build/macos
cp htmlviewer tina4-htmlviewer-macos-arm64
tar -czf tina4-htmlviewer-macos-arm64.tar.gz tina4-htmlviewer-macos-arm64
shasum -a 256 tina4-htmlviewer-macos-arm64.tar.gz > tina4-htmlviewer-macos-arm64.tar.gz.sha256

# 3. sign + verify
gpg -u E0B36CDD76676DD08E4F1FA641DA6E7645F494AF \
    --armor --detach-sign tina4-htmlviewer-macos-arm64.tar.gz
gpg --verify tina4-htmlviewer-macos-arm64.tar.gz.asc tina4-htmlviewer-macos-arm64.tar.gz

# 4. upload
gh release upload v1.0.0 \
  tina4-htmlviewer-macos-arm64.tar.gz \
  tina4-htmlviewer-macos-arm64.tar.gz.sha256 \
  tina4-htmlviewer-macos-arm64.tar.gz.asc --clobber
```

## Optional: Apple codesign + notarize (Gatekeeper)

GPG proves authorship but doesn't stop macOS quarantining a downloaded binary.
For a friction-free `.app` you need an Apple Developer ID:

```bash
codesign --force --timestamp --options runtime \
  --sign "Developer ID Application: <Name> (<TEAMID>)" build/macos/htmlviewer
xcrun notarytool submit build/macos/tina4-htmlviewer-macos-arm64.tar.gz \
  --apple-id <id> --team-id <TEAMID> --password <app-specific-pw> --wait
# staple the app bundle (not the bare binary):
# xcrun stapler staple <App>.app
```

## Optional: iOS

Needs Xcode + an Apple Developer cert & provisioning profile:

```bash
bash tools/tina4pascal setup ios          # xcodegen, libimobiledevice, …
bash tools/tina4pascal release ios        # → signed IPA (Apple-signed, not GPG)
```

## How anyone verifies a download

The release ships the public key as `tina4pascal-release-public.asc`:

```bash
gpg --import tina4pascal-release-public.asc
gpg --verify tina4-htmlviewer-macos-arm64.tar.gz.asc tina4-htmlviewer-macos-arm64.tar.gz
shasum -a 256 -c tina4-htmlviewer-macos-arm64.tar.gz.sha256
```

## Gatekeeper (un-notarized downloads)

The binary is GPG-signed, not Apple-notarized, so a browser download carries a
quarantine flag and macOS warns it "cannot be checked for malware." After
verifying the signature above, clear the flag and run it:

```bash
tar xzf tina4-htmlviewer-macos-arm64.tar.gz
xattr -dr com.apple.quarantine tina4-htmlviewer-macos-arm64
./tina4-htmlviewer-macos-arm64 page.html
```

To remove the warning entirely for end users, ship a **notarized `.app`** — see
the optional codesign + notarize section above (needs an Apple Developer ID).
