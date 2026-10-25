#!/bin/sh
# Build the <iframe> example as a macOS .app. The web view is the OS's own
# WKWebView (WebKit.framework ships with macOS) — nothing is bundled.
#   sh examples/iframe/build.sh          build
#   sh examples/iframe/build.sh --run    build and open
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
PROJECT="$ROOT/examples/iframe"
BUILD="$PROJECT/build/macos-iframe"
APP="$BUILD/IframeDemo.app"
FPC="${FPC:-$HOME/fpc/bin/fpc}"

rm -rf "$BUILD"
mkdir -p "$BUILD/bin" "$APP/Contents/MacOS" "$APP/Contents/Resources"

"$FPC" -Mdelphi -O2 \
  -Fu"$ROOT/src" \
  -FE"$BUILD/bin" -FU"$BUILD/bin" \
  -o"$BUILD/bin/IframeDemo" "$PROJECT/main.pas"

cp "$BUILD/bin/IframeDemo" "$APP/Contents/MacOS/IframeDemo"
cp "$PROJECT/app.html" "$APP/Contents/Resources/app.html"

# NSAllowsLocalNetworking: let the web view load plain http:// from 127.0.0.1 /
# localhost (a dev server) without opening App Transport Security to the internet.
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>IframeDemo</string>
  <key>CFBundleIdentifier</key><string>com.tina4.pascal.iframe</string>
  <key>CFBundleName</key><string>Tina4 iframe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSMinimumSystemVersion</key><string>10.13</string>
  <key>NSAppTransportSecurity</key><dict>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
</dict></plist>
PLIST

echo "iframe macOS app: $APP"
case "${1:-}" in
  --run|run|open) open "$APP" ;;
esac
