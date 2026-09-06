#!/usr/bin/env bash
# Build, package, GPG-sign and upload the macOS Tina4Pascal viewer to a release.
#
# Run on a Mac. See docs/RELEASE-MACOS.md for prerequisites (brew install fpc
# gnupg gh; Xcode CLT; import the release signing key; gh auth login).
#
#   bash tools/release-macos.sh [tag]        # tag defaults to v1.0.0
set -euo pipefail

TAG="${1:-v1.0.0}"
KEY="E0B36CDD76676DD08E4F1FA641DA6E7645F494AF"   # Tina4Pascal Release Signing
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

case "$(uname -m)" in
  arm64|aarch64) ARCH=arm64 ;;
  x86_64)        ARCH=x86_64 ;;
  *)             ARCH="$(uname -m)" ;;
esac
ASSET="tina4-htmlviewer-macos-${ARCH}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1 — $2"; exit 1; }; }
need fpc "brew install fpc"
need gpg "brew install gnupg"
need gh  "brew install gh && gh auth login"
gpg --list-secret-keys "$KEY" >/dev/null 2>&1 || {
  echo "release signing key $KEY not in keyring."
  echo "  gpg --import tina4pascal-release-private.asc   (see docs/RELEASE-MACOS.md)"
  exit 1
}

echo "== build macOS viewer =="
bash tools/tina4pascal build macos
BIN="build/macos/htmlviewer"
[ -f "$BIN" ] || { echo "build failed: $BIN missing"; exit 1; }

echo "== smoke render (best effort) =="
if "$BIN" examples/pages/bootstrap_test.html --snapshot build/macos/smoke.png >/dev/null 2>&1 \
   && [ -f build/macos/smoke.png ]; then
  echo "  rendered build/macos/smoke.png"
else
  echo "  (snapshot skipped)"
fi

echo "== Apple codesign (Developer ID) =="
# Apple codesign makes the binary attributable to the Developer ID team and is a
# prerequisite for notarization. The FPC build is only ad-hoc signed. GPG signing
# below is kept regardless (the one cross-platform verification scheme).
SIGN_ID="${TINA4_MACOS_SIGN_ID:-Developer ID Application: Code Infinity (Pty) Ltd (5CSH5U4F8F)}"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_ID"; then
  codesign --force --timestamp --options runtime --sign "$SIGN_ID" "$BIN"
  codesign -dvv "$BIN" 2>&1 | grep -E "Authority=Developer ID|TeamIdentifier" | head -2 || true
  # Notarize so Gatekeeper accepts a downloaded copy. notarytool takes a .zip;
  # a bare CLI binary cannot be stapled, so the ticket is verified online.
  NZIP="build/macos/${ASSET}-notarize.zip"
  if [ -n "${TINA4_NOTARY_PROFILE:-}" ]; then
    echo "== notarize (keychain profile: $TINA4_NOTARY_PROFILE) =="
    /usr/bin/ditto -c -k "$BIN" "$NZIP"
    xcrun notarytool submit "$NZIP" --keychain-profile "$TINA4_NOTARY_PROFILE" --wait
    rm -f "$NZIP"
  elif [ -n "${TINA4_ASC_KEY:-}" ] && [ -n "${TINA4_ASC_KEY_ID:-}" ] && [ -n "${TINA4_ASC_ISSUER:-}" ]; then
    echo "== notarize (ASC API key) =="
    /usr/bin/ditto -c -k "$BIN" "$NZIP"
    xcrun notarytool submit "$NZIP" --key "$TINA4_ASC_KEY" --key-id "$TINA4_ASC_KEY_ID" \
      --issuer "$TINA4_ASC_ISSUER" --wait
    rm -f "$NZIP"
  else
    echo "  (notarization skipped: set TINA4_NOTARY_PROFILE, or TINA4_ASC_KEY/KEY_ID/ISSUER)"
    echo "   store once: xcrun notarytool store-credentials tina4-notary \\"
    echo "     --apple-id <id> --team-id 5CSH5U4F8F --password <app-specific-pw>"
  fi
else
  echo "  (Developer ID identity not in keychain — skipping Apple codesign; GPG sig still applied)"
fi

echo "== package ($ASSET) =="
cd build/macos
cp -f htmlviewer "$ASSET"
chmod +x "$ASSET"
tar -czf "${ASSET}.tar.gz" "$ASSET"
shasum -a 256 "${ASSET}.tar.gz" > "${ASSET}.tar.gz.sha256"

echo "== sign + verify =="
gpg --batch --yes -u "$KEY" --armor --detach-sign "${ASSET}.tar.gz"
gpg --verify "${ASSET}.tar.gz.asc" "${ASSET}.tar.gz"

echo "== upload to release $TAG =="
gh release upload "$TAG" \
  "${ASSET}.tar.gz" "${ASSET}.tar.gz.sha256" "${ASSET}.tar.gz.asc" --clobber

echo "done: ${ASSET}.tar.gz built, signed, and uploaded to $TAG"
