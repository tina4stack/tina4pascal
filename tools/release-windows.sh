#!/usr/bin/env bash
# Build, Authenticode-sign, package, GPG-sign and (optionally) upload the Windows
# Tina4Pascal viewer to a GitHub release.
#
# Runs on the Mac: `tina4pascal build win64` cross-compiles the exe, embeds the
# app icon (fpcres), and Authenticode-signs it via SimplySign / a PKCS#11 token
# (log into SimplySign Desktop first) or a .p12 — see docs and sign_windows_exe
# in tools/tina4pascal. This script then packages + GPG-signs the exe the same
# way the macOS/Linux assets are, for a consistent, verifiable release.
#
#   bash tools/release-windows.sh [tag]        # omit tag = package only, no upload
#
# Prereqs: brew install fpc osslsigncode libp11 gnupg gh; the release GPG key in
# the keyring; an active SimplySign session (or TINA4_WIN_CERT); gh auth login.
set -euo pipefail

TAG="${1:-}"
KEY="E0B36CDD76676DD08E4F1FA641DA6E7645F494AF"   # Tina4Pascal Release Signing
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ASSET="tina4-htmlviewer-win64.exe"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1 — $2"; exit 1; }; }
need fpc "brew install fpc"
need osslsigncode "brew install osslsigncode"
need gpg "brew install gnupg"
gpg --list-secret-keys "$KEY" >/dev/null 2>&1 || {
  echo "release signing key $KEY not in keyring (see docs/RELEASE-MACOS.md)"; exit 1; }

echo "== build + Authenticode-sign win64 =="
bash tools/tina4pascal build win64
EXE="build/windows/htmlviewer_win.exe"
[ -f "$EXE" ] || { echo "build failed: $EXE missing"; exit 1; }

echo "== require an Authenticode signature (a release must be signed) =="
# The certificate table is data-directory entry 4; empty => unsigned.
python3 - "$EXE" <<'PY'
import struct,sys
d=open(sys.argv[1],'rb').read()
e=struct.unpack_from('<I',d,0x3C)[0]; opt=e+24; magic=struct.unpack_from('<H',d,opt)[0]
dd=opt+(0x70 if magic==0x20b else 0x60)
_,size=struct.unpack_from('<II',d,dd+4*8)
sys.exit(0 if size>0 else "UNSIGNED — log into SimplySign Desktop (or set TINA4_WIN_CERT) and rebuild")
PY
osslsigncode verify -in "$EXE" 2>&1 | grep -E "Subject:|Timestamp time" | head -2 || true

echo "== package ($ASSET) =="
cd build/windows
cp -f htmlviewer_win.exe "$ASSET"
shasum -a 256 "$ASSET" > "$ASSET.sha256"

echo "== GPG detached signature =="
gpg --batch --yes -u "$KEY" --armor --detach-sign "$ASSET"
gpg --verify "$ASSET.asc" "$ASSET"

echo "== artifacts =="
ls -la "$ASSET" "$ASSET.sha256" "$ASSET.asc"

if [ -z "$TAG" ]; then
  echo "packaged (no tag given — skipping upload). To publish:"
  echo "  bash tools/release-windows.sh <tag>"
  exit 0
fi

need gh "brew install gh && gh auth login"
echo "== upload to release $TAG =="
gh release upload "$TAG" "$ASSET" "$ASSET.sha256" "$ASSET.asc" --clobber
echo "done: $ASSET signed, packaged, and uploaded to $TAG"
