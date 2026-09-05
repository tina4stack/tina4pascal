#!/bin/sh
# Package the Tina4Pascal Android app into a signed debug APK using the SDK
# build-tools directly (no Gradle). Assumes ./build.sh already produced the
# native libtina4.so. Set ANDROID_SDK if yours lives elsewhere.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ANDROID_SDK="${ANDROID_SDK:-/opt/homebrew/share/android-commandlinetools}"
BT="$ANDROID_SDK/build-tools/34.0.0"
ANDROID_JAR="$ANDROID_SDK/platforms/android-34/android.jar"
JAVA_HOME="${JAVA_HOME:-$(/usr/libexec/java_home)}"; export JAVA_HOME

APPDIR="$HERE/app/src/main"
OUT="$HERE/out"; rm -rf "$OUT"; mkdir -p "$OUT/classes"

# gather every ABI that ./build.sh produced
ABIS="$(ls "$APPDIR/jniLibs" 2>/dev/null)"
[ -n "$ABIS" ] || { echo "no jniLibs — run ./build.sh first"; exit 1; }

echo "1/6 compiling Java…"
"$JAVA_HOME/bin/javac" --release 17 -classpath "$ANDROID_JAR" \
  -d "$OUT/classes" $(find "$APPDIR/java" -name '*.java')

echo "2/6 dexing…"
"$BT/d8" --min-api 21 --lib "$ANDROID_JAR" --output "$OUT" \
  $(find "$OUT/classes" -name '*.class')

echo "3/6 compiling + linking resources + manifest…"
# compile res/ (icons, colors) into a flat archive for the linker
RESFLAGS=""
if [ -d "$APPDIR/res" ]; then
  "$BT/aapt2" compile --dir "$APPDIR/res" -o "$OUT/res.zip"
  RESFLAGS="$OUT/res.zip"
fi
# inject the package into the manifest for aapt2 (Gradle uses namespace instead)
sed 's/<manifest /<manifest package="com.tina4.pascal" /' \
  "$APPDIR/AndroidManifest.xml" > "$OUT/AndroidManifest.xml"
"$BT/aapt2" link -o "$OUT/base.apk" -I "$ANDROID_JAR" \
  --manifest "$OUT/AndroidManifest.xml" \
  --min-sdk-version 21 --target-sdk-version 34 \
  -A "$APPDIR/assets" $RESFLAGS

echo "4/6 adding dex + native libs ($ABIS)…"
for abi in $ABIS; do
  [ -f "$APPDIR/jniLibs/$abi/libtina4.so" ] || continue
  mkdir -p "$OUT/lib/$abi"
  cp "$APPDIR/jniLibs/$abi/libtina4.so" "$OUT/lib/$abi/libtina4.so"
done
( cd "$OUT" && zip -qr base.apk classes.dex lib )

echo "5/6 zipalign…"
"$BT/zipalign" -f -p 4 "$OUT/base.apk" "$OUT/aligned.apk"

echo "6/6 signing…"
# Release signing when a real keystore is supplied (env), else a throwaway debug
# key. For release set: TINA4_KEYSTORE (path), TINA4_KEY_ALIAS, TINA4_KS_PASS,
# and optionally TINA4_KEY_PASS (defaults to the store pass). Make one with
# `tina4pascal keygen`.
if [ -n "${TINA4_KEYSTORE:-}" ]; then
  [ -f "$TINA4_KEYSTORE" ] || { echo "TINA4_KEYSTORE not found: $TINA4_KEYSTORE"; exit 1; }
  : "${TINA4_KEY_ALIAS:?set TINA4_KEY_ALIAS for release signing}"
  : "${TINA4_KS_PASS:?set TINA4_KS_PASS for release signing}"
  KP="${TINA4_KEY_PASS:-$TINA4_KS_PASS}"
  APK="$HERE/tina4pascal-release.apk"
  "$BT/apksigner" sign --ks "$TINA4_KEYSTORE" --ks-pass "pass:$TINA4_KS_PASS" \
    --ks-key-alias "$TINA4_KEY_ALIAS" --key-pass "pass:$KP" \
    --out "$APK" "$OUT/aligned.apk"
  echo "signed RELEASE with $TINA4_KEYSTORE (alias $TINA4_KEY_ALIAS)"
else
  KS="$HERE/debug.keystore"
  if [ ! -f "$KS" ]; then
    "$JAVA_HOME/bin/keytool" -genkeypair -keystore "$KS" -alias androiddebugkey \
      -keyalg RSA -keysize 2048 -validity 10000 \
      -storepass android -keypass android -dname "CN=Android Debug,O=Android,C=US"
  fi
  APK="$HERE/tina4pascal-debug.apk"
  "$BT/apksigner" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
    --out "$APK" "$OUT/aligned.apk"
fi
# prove the signature + show the signing certificate fingerprint
"$BT/apksigner" verify --print-certs "$APK" 2>/dev/null \
  | grep -iE "Signer #1 certificate (DN|SHA-256)" | head -2 || true

echo
echo "APK: $APK"
ls -la "$APK" | awk '{print "size: "$5" bytes"}'
echo "install:  adb install -r \"$APK\""
echo "launch:   adb shell am start -n com.tina4.pascal/.MainActivity"
