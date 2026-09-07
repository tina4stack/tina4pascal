#!/bin/sh
# Build the walkable office macOS app (ThreePascal, pure software 3D).
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
export PPC_CONFIG_PATH="${PPC_CONFIG_PATH:-$HOME/fpc/etc}"; export PATH="$HOME/fpc/bin:$PATH"
OUT="${TMPDIR:-/tmp}/office3d"; mkdir -p "$OUT"
fpc -Mdelphi -Fu"$HERE/../../3d" -FE"$OUT" -FU"$OUT" -k-ld_classic "$HERE/officeapp.pas"
APP="$OUT/Office3D.app"; rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$OUT/officeapp" "$APP/Contents/MacOS/officeapp"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Office3D</string>
  <key>CFBundleIdentifier</key><string>com.tina4.office3d</string>
  <key>CFBundleExecutable</key><string>officeapp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "built $APP"; echo "run:  open \"$APP\"   (click window; WASD move, arrows look, Esc quit)"
