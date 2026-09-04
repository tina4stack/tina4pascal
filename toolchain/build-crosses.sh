#!/bin/sh
# Build FPC 3.2.2 cross-compilers on macOS arm64 → win64, linux x64/a64, android a64, darwin x64, ios a64
# Key insight: OPT applies to the NATIVE compiler rebuild too (needs mac SDK via -XR),
# while CROSSOPT applies only to target RTL/packages.
set -u
SRC=$HOME/fpc-dev/fpc-3.2.2
PREFIX=$HOME/fpc
PP=$PREFIX/lib/fpc/3.2.2/ppca64
MACSDK=$(xcrun --show-sdk-path)
IOSSDK=$(xcrun --sdk iphoneos --show-sdk-path)
CROSS=$PREFIX/cross

build() {
  name=$1; os=$2; cpu=$3; bindir=$4; binprefix=$5; crossopt=$6
  log=/private/tmp/fpc-cross-$name.log
  cd "$SRC" || exit 1
  make clean OS_TARGET=$os CPU_TARGET=$cpu > /dev/null 2>&1
  if make crossall crossinstall OS_TARGET=$os CPU_TARGET=$cpu PP=$PP \
      INSTALL_PREFIX=$PREFIX OVERRIDEVERSIONCHECK=1 OPT="-XR$MACSDK" \
      ${bindir:+CROSSBINDIR=$bindir} ${binprefix:+BINUTILSPREFIX=$binprefix} \
      ${crossopt:+CROSSOPT="$crossopt"} > "$log" 2>&1; then
    echo "OK   $name"
  else
    echo "FAIL $name (see $log)"
  fi
}

echo "== FPC cross builds started $(date) =="
build win64          win64   x86_64  ""                           ""                           ""
build linux-x64      linux   x86_64  "$CROSS/bin/x86_64-linux"    "x86_64-linux-"              ""
build linux-a64      linux   aarch64 "$CROSS/bin/aarch64-linux"   "aarch64-unknown-linux-gnu-" ""
build android-a64    android aarch64 "$CROSS/bin/aarch64-android" "aarch64-linux-android-"     ""
# 32-bit ARM (armeabi-v7a) — needs GNU as+ld wrappers and armv7/VFP flags.
# Prereq: brew install arm-linux-gnueabihf-binutils; wrappers in
# $CROSS/bin/arm-android/ (as→GNU as, ld→GNU ld). See docs/ANDROID.md.
build android-arm    android arm     "$CROSS/bin/arm-android"     "arm-linux-androideabi-"    "-CpARMV7A -CfVFPV3"
build darwin-x64     darwin  x86_64  ""                           ""                           ""
build ios-a64        ios     aarch64 ""                           ""                           "-XR$IOSSDK"
echo "== done $(date) =="
