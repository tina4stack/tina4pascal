#!/bin/sh
# Build the walking-ram macOS app (ThreePascal, pure software 3D).
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
export PPC_CONFIG_PATH="${PPC_CONFIG_PATH:-$HOME/fpc/etc}"; export PATH="$HOME/fpc/bin:$PATH"
OUT="${TMPDIR:-/tmp}/sheep3d"; mkdir -p "$OUT"
# -ld_classic: macOS 26's new linker (ld-prime) asserts on FPC 3.2.2 Obj-C metadata.
fpc -Mdelphi -Fu"$HERE/../../3d" -Fu"$HERE/../common" -FE"$OUT" -FU"$OUT" -k-ld_classic "$HERE/sheepapp.pas"
APP="$OUT/Sheep3D.app"; rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$OUT/sheepapp" "$APP/Contents/MacOS/sheepapp"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Sheep3D</string>
  <key>CFBundleIdentifier</key><string>com.tina4.sheep3d</string>
  <key>CFBundleExecutable</key><string>sheepapp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "built $APP"
echo "run:  open \"$APP\""
