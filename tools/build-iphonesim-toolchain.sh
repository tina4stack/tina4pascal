#!/bin/sh
# Build the FPC iOS-Simulator toolchain (aarch64-iphonesim RTL + packages +
# univint) so anyone can pull this repo and build the iOS-Simulator app.
#
# What you get: ~/fpc-watchos/units/aarch64-iphonesim/*.ppu (133 RTL/package
# units + ~40 univint CF/CG/CT units), which ios/build-sim.sh links into
# libtina4iossim.a. FPC's `iphonesim` target is UPSTREAM in trunk, so no compiler
# patch is needed to build the engine — only an RTL for the target.
#
# Prerequisites:
#   - Xcode with the iOS platform (provides the iPhoneSimulator SDK + simctl).
#   - An FPC *trunk* (3.3.1) compiler that advertises the iPhoneSim target.
#     Point $PPC at it, or install one (fpcupdeluxe "trunk", or build from the
#     source tree this script can clone). The stock FPC 3.2.2 has NO simulator
#     target and will NOT work.
#
# Usage:
#   tools/build-iphonesim-toolchain.sh
#   PPC=~/fpc-watchos/bin/ppca64 FPC_TRUNK=~/fpc-dev/fpc-trunk PREFIX=~/fpc-watchos \
#     tools/build-iphonesim-toolchain.sh
#   BUILD_COMPILER=1 ...   # also build the trunk compiler from source (+ the
#                          # iOS-sim linker patch) if $PPC is missing
#
# Note: this runs under /bin/sh; every multi-flag compiler call uses a POSIX
# positional list (set --) because zsh does NOT word-split unquoted variables.
set -eu

FPC_TRUNK="${FPC_TRUNK:-$HOME/fpc-dev/fpc-trunk}"
PREFIX="${PREFIX:-$HOME/fpc-watchos}"
PPC="${PPC:-$PREFIX/bin/ppca64}"
DEST="$PREFIX/units/aarch64-iphonesim"
TRUNK_SINCE="${TRUNK_SINCE:-2026-08-20}"   # shallow-clone window if we must fetch

say() { printf '\033[36m%s\033[0m\n' "$*"; }
die() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null || true)"
[ -n "$SDK" ] || die "iPhoneSimulator SDK not found — install the Xcode iOS platform."
MACSDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"

# --- 1. source tree ---------------------------------------------------------
if [ ! -d "$FPC_TRUNK/rtl/darwin" ]; then
  say "cloning FPC trunk → $FPC_TRUNK (shallow, since $TRUNK_SINCE)…"
  mkdir -p "$(dirname "$FPC_TRUNK")"
  git clone --quiet --single-branch --branch main --shallow-since="$TRUNK_SINCE" \
    https://gitlab.com/freepascal.org/fpc/source.git "$FPC_TRUNK"
fi

# --- 2. compiler ------------------------------------------------------------
if [ ! -x "$PPC" ]; then
  if [ "${BUILD_COMPILER:-0}" = "1" ]; then
    say "building the FPC trunk compiler from source…"
    # The iOS-sim linker patch (docs/fpc-iphonesim-linker.diff) lets `fpc
    # -Tiphonesim` link executables directly on modern ld; harmless for the
    # static-lib path ios/build-sim.sh uses. Apply if not already applied.
    HERE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
    ( cd "$FPC_TRUNK" && git apply --check "$HERE_DIR/docs/fpc-iphonesim-linker.diff" 2>/dev/null \
        && git apply "$HERE_DIR/docs/fpc-iphonesim-linker.diff" && echo "  applied linker patch" ) || true
    BOOT="${BOOTSTRAP_FPC:-$(command -v ppca64 || command -v fpc || true)}"
    [ -n "$BOOT" ] || die "no bootstrap compiler for the build — set BOOTSTRAP_FPC."
    # -XR the *Xcode* macOS SDK: the CommandLineTools SDK's newer libSystem .tbd
    # trips FPC's linker ("tapi error: malformed file / unknown architecture").
    ( cd "$FPC_TRUNK/compiler" && make compiler CPU_TARGET=aarch64 OS_TARGET=darwin \
        FPC="$BOOT" ${MACSDK:+OPT="-XR$MACSDK"} >/dev/null )
    PPC="$FPC_TRUNK/compiler/ppca64"
  else
    die "trunk compiler not found at $PPC. Install FPC trunk (fpcupdeluxe 'trunk'),
     point \$PPC at its ppca64, or re-run with BUILD_COMPILER=1 to build it here."
  fi
fi
case "$("$PPC" -iV 2>/dev/null)" in
  3.3.*) : ;;
  *) die "$PPC is not FPC trunk (3.3.x) — the iphonesim target needs trunk." ;;
esac
say "compiler: $PPC ($("$PPC" -iV))"

RTLU="$FPC_TRUNK/rtl/units/aarch64-iphonesim"

# --- 3. base RTL (standard make; iphonesim is a first-class fpcmake target) --
say "building the base iphonesim RTL…"
( cd "$FPC_TRUNK/rtl" \
  && make clean OS_TARGET=iphonesim CPU_TARGET=aarch64 FPC="$PPC" >/dev/null 2>&1 \
  && make all   OS_TARGET=iphonesim CPU_TARGET=aarch64 FPC="$PPC" OPT="-XR$SDK -Ur" >/dev/null 2>&1 )
[ -f "$RTLU/system.ppu" ] || die "base RTL build failed (no system.ppu)."

# --- 4. package units the engine pulls --------------------------------------
# Driven directly with the trunk compiler (make/fpmake would bootstrap the wrong
# on-PATH compiler). Auto-compile fills the dependency units.
say "building package units (fpjson, base64, contnrs, Generics, …)…"
pkg_dirs="rtl-generics/src fcl-base/src rtl-objpas/src/inc rtl-objpas/src fcl-json/src hash/src paszlib/src pthreads/src"
build_unit() {   # $1=mode  $2=unit
  src="$(find "$FPC_TRUNK/packages" -iname "$2.pp" -o -iname "$2.pas" 2>/dev/null \
         | grep -viE 'tests|examples' | head -1)"
  [ -n "$src" ] || return 0
  set -- -"$1" -Tiphonesim -Paarch64 -O2 "-XR$SDK" "-FE$RTLU" "-FU$RTLU" "-Fu$RTLU"
  for d in $pkg_dirs; do set -- "$@" "-Fu$FPC_TRUNK/packages/$d" "-Fi$FPC_TRUNK/packages/$d"; done
  "$PPC" "$@" "$src" >/dev/null 2>&1 || true
}
for u in md5 sha1 base64 contnrs syncobjs pthreads variants strutils dateutils \
         rtti system.timespan generics.collections fpjson jsonparser; do
  build_unit Mdelphi "$u"
done
# paszlib's zlib units want objfpc mode
for u in zbase trees infutil inftrees infcodes infblock inffast zinflate zdeflate adler; do
  build_unit Mobjfpc "$u"
done

# --- 5. univint (Core Foundation / Core Graphics / Core Text bindings) -------
# These open with macpas {$ifc} directives whose {$mode macpas} sits inside the
# first guard, so they MUST be compiled -Mmacpas from the command line.
say "building univint CF/CG/CT bindings (-Mmacpas)…"
UNIV="$FPC_TRUNK/packages/univint/src"
for u in CFBase CFString CFAttributedString CFDictionary CFURL CFError \
         CGBase CGContext CGColor CGColorSpace CGGeometry CGPath CGGradient \
         CGImage CGImageSource CGBitmapContext CGAffineTransforms CGFont CGDataProvider \
         CTFont CTFontTraits CTFontManager CTLine CTStringAttributes; do
  [ -f "$UNIV/$u.pas" ] || continue
  "$PPC" -Tiphonesim -Paarch64 -Mmacpas -O2 "-XR$SDK" \
    "-FE$RTLU" "-FU$RTLU" "-Fu$RTLU" "-Fu$UNIV" "-Fi$UNIV" "$UNIV/$u.pas" >/dev/null 2>&1 || true
done

# --- 6. install -------------------------------------------------------------
mkdir -p "$DEST"
cp "$RTLU"/*.ppu "$RTLU"/*.o "$DEST"/ 2>/dev/null || true
N="$(ls "$DEST"/*.ppu 2>/dev/null | wc -l | tr -d ' ')"
[ "$N" -ge 130 ] || die "installed only $N units (expected ~133+40) — see errors above."
say "installed $N units → $DEST"
say "done. Now:  ios/build-sim.sh   (default --native)  then open ios/sim in Xcode / xcodebuild -sdk iphonesimulator"
