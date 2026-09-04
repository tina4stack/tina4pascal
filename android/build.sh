#!/bin/sh
# Build the native Tina4 renderer (libtina4.so) with the FPC Android
# cross-compilers and drop it where Gradle / build-apk.sh pick it up. Builds
# every ABI in ABIS below. Run this whenever the Pascal core or the Android
# shell changes; then package with build-apk.sh (or Gradle).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../src"

export PPC_CONFIG_PATH="${PPC_CONFIG_PATH:-$HOME/fpc/etc}"
export PATH="$HOME/fpc/bin:$PATH"

# ABI  →  FPC flags  (arm64 = every modern phone; armv7 = 32-bit devices)
abi_flags() {
  case "$1" in
    arm64-v8a)   echo "-Tandroid -Paarch64" ;;
    armeabi-v7a) echo "-Tandroid -Parm -CpARMV7A -CfVFPV3" ;;
    *) return 1 ;;
  esac
}
ABIS="${ABIS:-arm64-v8a armeabi-v7a}"

for abi in $ABIS; do
  flags="$(abi_flags "$abi")" || { echo "unknown ABI $abi"; exit 1; }
  out="$HERE/app/src/main/jniLibs/$abi"
  work="$(mktemp -d)"
  mkdir -p "$out"
  echo "compiling libtina4.so ($abi)…"
  # shellcheck disable=SC2086
  fpc -Mdelphi $flags -O2 -Xs -Fu"$SRC" -FE"$work" -FU"$work" \
      -o"$out/libtina4.so" "$HERE/jni/tina4jni.pas" \
      2>&1 | grep -Ei "error|fatal" && { echo "BUILD FAILED ($abi)"; exit 1; } || true
  [ -f "$out/libtina4.so" ] || { echo "BUILD FAILED ($abi): no .so"; exit 1; }
  echo "  ok → $out/libtina4.so ($(wc -c < "$out/libtina4.so") bytes)"
  rm -rf "$work"
done

cat <<'NOTE'

Native libraries built (all ABIs). Package + install with:
  cd android && ./build-apk.sh && adb install -r tina4pascal-debug.apk
Or open android/ in Android Studio and Run.
NOTE
