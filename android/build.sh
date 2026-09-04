#!/bin/sh
# Build the native Tina4 renderer (libtina4.so, arm64) with the FPC Android
# cross-compiler and drop it where Gradle picks it up. Run this whenever the
# Pascal core or the Android shell changes; then build the APK with Gradle.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../src"
OUT="$HERE/app/src/main/jniLibs/arm64-v8a"
WORK="$(mktemp -d)"

export PPC_CONFIG_PATH="$HOME/fpc/etc"
export PATH="$HOME/fpc/bin:$PATH"

mkdir -p "$OUT"
echo "compiling libtina4.so (aarch64-android)…"
fpc -Mdelphi -Tandroid -Paarch64 -O2 -Xs \
    -Fu"$SRC" -FE"$WORK" -FU"$WORK" \
    -o"$OUT/libtina4.so" "$HERE/jni/tina4jni.pas" \
    | grep -Ei "error|fatal" && { echo "BUILD FAILED"; exit 1; } || true

if [ -f "$OUT/libtina4.so" ]; then
  echo "ok → $OUT/libtina4.so"
  ls -la "$OUT/libtina4.so"
else
  echo "BUILD FAILED (no .so produced)"; exit 1
fi
rm -rf "$WORK"

cat <<'NOTE'

Native library built. To put it on your phone:

  cd android
  ./gradlew installDebug          # needs the Android SDK (Android Studio)
  adb shell am start -n com.tina4.pascal/.MainActivity

Or open the android/ folder in Android Studio and press Run. The prebuilt
libtina4.so is bundled from src/main/jniLibs — Gradle does not rebuild it.
NOTE
