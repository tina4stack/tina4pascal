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

echo "3/6 linking resources + manifest…"
# inject the package into the manifest for aapt2 (Gradle uses namespace instead)
sed 's/<manifest /<manifest package="com.tina4.pascal" /' \
  "$APPDIR/AndroidManifest.xml" > "$OUT/AndroidManifest.xml"
"$BT/aapt2" link -o "$OUT/base.apk" -I "$ANDROID_JAR" \
  --manifest "$OUT/AndroidManifest.xml" \
  --min-sdk-version 21 --target-sdk-version 34 \
  -A "$APPDIR/assets"

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
KS="$HERE/debug.keystore"
if [ ! -f "$KS" ]; then
  "$JAVA_HOME/bin/keytool" -genkeypair -keystore "$KS" -alias androiddebugkey \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -storepass android -keypass android -dname "CN=Android Debug,O=Android,C=US"
fi
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
  --out "$HERE/tina4pascal-debug.apk" "$OUT/aligned.apk"

echo
echo "APK: $HERE/tina4pascal-debug.apk"
ls -la "$HERE/tina4pascal-debug.apk" | awk '{print "size: "$5" bytes"}'
echo "install:  adb install -r \"$HERE/tina4pascal-debug.apk\""
echo "launch:   adb shell am start -n com.tina4.pascal/.MainActivity"
